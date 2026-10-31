// Package host is the Go implementation of the Coffee Shop foreground host.
//
// This is the first vertical slice: it speaks the wire contract's scaffolding — ready,
// received, error, stopped — and nothing else yet. Dispatch, the sockets, slots and the
// Station process arrive in later slices, each behind the same conformance suite, so the
// contract is proven before behaviour is added.
package host

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/weima/coffee-shop/go/internal/proto"
	"github.com/weima/coffee-shop/go/internal/state"
)

// Protocol is the value of the `ready` event's `protocol` field.
const Protocol = 1

// MaxLineBytes is the request-line limit, matching the Odin host's scanner limit.
const MaxLineBytes = 1 << 20

// Options is everything one host run needs. In and Out are the wire; Now is injectable so
// timestamps in tests are predictable without freezing the clock.
type Options struct {
	In  io.Reader
	Out io.Writer
	Now func() time.Time
	// StateRoot enables the host-owned artifacts: the activity socket, the spool and
	// per-request history. Empty keeps the host a pure stdin/stdout loop, which is what
	// the contract tests use.
	StateRoot string
}

// Run serves one foreground host until shutdown or the end of input.
func Run(ctx context.Context, opts Options) error {
	if opts.In == nil || opts.Out == nil {
		return fmt.Errorf("host: In and Out are required")
	}
	now := opts.Now
	if now == nil {
		now = time.Now
	}
	w := &writer{out: opts.Out, now: now, root: opts.StateRoot}

	var server *activityServer
	if opts.StateRoot != "" {
		if err := state.EnsureDir(state.HostDir(opts.StateRoot), true); err != nil {
			return fmt.Errorf("create host directory: %w", err)
		}
		if err := state.EnsureDir(state.SpoolDir(opts.StateRoot), true); err != nil {
			return fmt.Errorf("create report spool: %w", err)
		}
		listening, err := listenActivity(opts.StateRoot, w)
		if err != nil {
			return err
		}
		server = listening
		defer func() { _ = server.Close() }()
	}

	// ready has no request_id in the contract (the Odin host writes only type and
	// protocol), so it is written as its own shape rather than through proto.Event.
	if err := w.raw(fmt.Sprintf(`{"type":"ready","protocol":%d,"at":%q}`, Protocol, stamp(now()))); err != nil {
		return err
	}

	if server != nil {
		// Reports a previous host spooled but never announced are relayed before this
		// host accepts a new one, so recovery cannot race a live report.
		ReplaySpool(opts.StateRoot, w)
		go func() {
			if err := server.Serve(ctx); err != nil && ctx.Err() == nil {
				fmt.Fprintf(os.Stderr, "csd: activity: %v\n", err)
			}
		}()
	}

	scanner := bufio.NewScanner(opts.In)
	scanner.Buffer(make([]byte, 0, 64*1024), MaxLineBytes)
	for scanner.Scan() {
		if err := ctx.Err(); err != nil {
			return err
		}
		line := scanner.Text()
		if line == "" {
			continue
		}
		stop, err := w.handle(line)
		if err != nil {
			return err
		}
		if stop {
			return nil
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("host: read stdin: %w", err)
	}
	return nil
}

// stamp formats the contract timestamp: RFC 3339 UTC with exactly three fraction digits.
func stamp(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z")
}

type writer struct {
	out  io.Writer
	now  func() time.Time
	root string
}

// relayReport records a report and announces it, in that order. A report that cannot be
// recorded is still announced: a reader seeing it twice is better than a completion
// nobody sees.
func (w *writer) relayReport(message proto.Message) {
	if message.Kind == StationPIDKind {
		return
	}
	_ = w.appendHistory(message)
	_ = w.emit(proto.Event{
		Type:        "station_report",
		RequestID:   message.BrewID,
		ShotID:      message.ShotID,
		Kind:        message.Kind,
		Description: reportText(message.Description),
	})
}

// appendHistory writes the report to <host>/<request>/history.ndjson.
func (w *writer) appendHistory(message proto.Message) error {
	if w.root == "" {
		return nil
	}
	dir := state.RequestDir(w.root, message.BrewID)
	if err := state.EnsureDir(dir, true); err != nil {
		return err
	}
	entry := proto.Event{
		Type:        "station_report",
		RequestID:   message.BrewID,
		ShotID:      message.ShotID,
		Kind:        message.Kind,
		Description: reportText(message.Description),
		At:          stamp(w.now()),
	}
	line, err := proto.EventLine(entry)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(state.HistoryPath(w.root, message.BrewID), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer func() { _ = file.Close() }()
	_, err = file.Write(line)
	return err
}

// handle acknowledges one line and then acts on it. Every line is acknowledged before it
// is handled, so a caller can tell an unanswered request from one never read.
func (w *writer) handle(line string) (stop bool, err error) {
	var request struct {
		Type      string `json:"type"`
		RequestID string `json:"request_id"`
	}
	// A malformed line still reports its byte length; it is not fatal.
	_ = json.Unmarshal([]byte(line), &request)

	requestID := ""
	if validShotID(request.RequestID) {
		requestID = request.RequestID
	}
	received := proto.Event{Type: "received", RequestID: requestID}
	count := len(line)
	received.Bytes = &count
	if err := w.emit(received); err != nil {
		return false, err
	}

	switch request.Type {
	case "shutdown":
		id := requestID
		if id == "" {
			id = request.RequestID
		}
		return true, w.emit(proto.Event{Type: "stopped", RequestID: id})
	case "":
		return false, w.emit(proto.Event{Type: "error", Reason: "invalid json"})
	default:
		return false, w.emit(proto.Event{Type: "error", RequestID: requestID, Reason: "unknown request type"})
	}
}

func (w *writer) emit(e proto.Event) error {
	e.At = stamp(w.now())
	line, err := proto.EventLine(e)
	if err != nil {
		return err
	}
	_, err = w.out.Write(line)
	return err
}

func (w *writer) raw(line string) error {
	_, err := io.WriteString(w.out, line+"\n")
	return err
}

// validShotID mirrors the contract's identifier rule: 1 to 64 characters, starting with a
// letter or digit, then letters, digits, '-' or '_'.
func validShotID(id string) bool {
	if len(id) == 0 || len(id) > 64 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
			continue
		case (c == '-' || c == '_') && i > 0:
			continue
		}
		return false
	}
	return true
}
