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
	"time"

	"github.com/weima/coffee-shop/go/internal/proto"
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
	w := &writer{out: opts.Out, now: now}

	// ready has no request_id in the contract (the Odin host writes only type and
	// protocol), so it is written as its own shape rather than through proto.Event.
	if err := w.raw(fmt.Sprintf(`{"type":"ready","protocol":%d,"at":%q}`, Protocol, stamp(now()))); err != nil {
		return err
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
	out io.Writer
	now func() time.Time
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
