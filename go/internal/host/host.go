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
	"path/filepath"
	"sync"
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
	// CLI is the argv prefix for the Odin CLI: the seam dispatch drives. Empty derives it
	// from CS_CLI, and a host without one refuses a dispatch rather than guessing.
	CLI []string
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
	// The ledger is rebuilt from history so a restarted host still warns about a Station
	// that was waiting for a reply or had gone quiet before the restart.
	if opts.StateRoot != "" {
		w.ledger = newProgressLedger(now)
		w.ledger.rebuild(opts.StateRoot)
		defer w.watchProgress(ctx)()
	}

	var server *activityServer
	if opts.StateRoot != "" {
		if err := state.EnsureDir(state.HostDir(opts.StateRoot), true); err != nil {
			return fmt.Errorf("create host directory: %w", err)
		}
		lock, err := acquireHostLock(opts.StateRoot)
		if err != nil {
			return err
		}
		defer lock.release()
		if err := state.EnsureDir(state.SpoolDir(opts.StateRoot), true); err != nil {
			return fmt.Errorf("create report spool: %w", err)
		}
		listening, err := listenActivity(opts.StateRoot, w)
		if err != nil {
			return err
		}
		server = listening
		defer server.stop()
	}

	// ready has no request_id in the contract (the Odin host writes only type and
	// protocol), so it is written as its own shape rather than through proto.Event.
	if err := w.raw(fmt.Sprintf(`{"type":"ready","protocol":%d,"at":%q}`, Protocol, stamp(now()))); err != nil {
		return err
	}

	cli := opts.CLI
	if len(cli) == 0 {
		if value := os.Getenv("CS_CLI"); value != "" {
			cli = []string{value}
		}
	}
	var dispatch *dispatcher
	if opts.StateRoot != "" && len(cli) > 0 {
		extension := filepath.Join(state.HostDir(opts.StateRoot), "extensions", "coffee-shop.ts")
		dispatch = newDispatcher(opts.StateRoot, cli, state.ActivitySocket(opts.StateRoot), extension, os.Getenv("CS_STATION_MODEL"), w)
		w.onTerminal = dispatch.terminalReport
		defer dispatch.shutdown()

		requests, err := listenRequests(opts.StateRoot, dispatch, w)
		if err != nil {
			return err
		}
		defer requests.stop()
		requests.start(ctx)
	}

	if server != nil {
		// Reports a previous host spooled but never announced are relayed before this
		// host accepts a new one, so recovery cannot race a live report.
		ReplaySpool(opts.StateRoot, w)
		server.start(ctx, w)
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
		stop, err := w.handleWith(line, dispatch)
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
	// mu serializes stdout and history writes. Reports are relayed on one goroutine, but
	// the staleness ticker emits from another, and a torn event line is unrecoverable.
	mu sync.Mutex
	// onTerminal frees a Shot's Slot as soon as its terminal report arrives, without
	// waiting for the process to exit, so a queued Shot can start sooner.
	onTerminal func(requestID, shotID string)
	// ledger holds the host's progress supervision, nil in a host with no state root.
	ledger *progressLedger
}

// watchProgress checks for staleness on a ticker until the host stops. Reports are
// checked as they arrive, so the ticker only bounds a quiet Station's delay.
func (w *writer) watchProgress(ctx context.Context) func() {
	stop := make(chan struct{})
	go func() {
		ticker := time.NewTicker(LedgerPollInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-stop:
				return
			case <-ticker.C:
				w.checkLedger()
			}
		}
	}()
	return func() { close(stop) }
}

// stationStarted and stationFinished keep the ledger's view of live Stations in step with
// the dispatcher, so a released Station can never warn afterwards.
func (w *writer) stationStarted(requestID, shotID, paneID string) {
	if w.ledger != nil {
		w.ledger.addStation(requestID, shotID, paneID)
	}
}

func (w *writer) stationFinished(requestID, shotID string) {
	if w.ledger != nil {
		w.ledger.finish(requestID, shotID)
	}
}

func (w *writer) checkLedger() {
	if w.ledger != nil {
		w.ledger.checkAndEmit(w.emit)
	}
}

// terminalReportKinds mirrors the Odin host's is_terminal_report. taste_passed is not
// here: a Station that passed its Taste is released when its process exits.
func terminalReportKinds(kind string) bool {
	switch kind {
	case "pulled", "taste_failed", "incomplete", "session_failed":
		return true
	}
	return false
}

// relayReport records a report and announces it, in that order. A report that cannot be
// recorded is still announced: a reader seeing it twice is better than a completion
// nobody sees.
func (w *writer) relayReport(message proto.Message) {
	if message.Kind == StationPIDKind {
		return
	}
	// Record the report before releasing the Slot: a `needs_input` is a question, and a
	// released Station must not alert after its report has been answered by the exit path.
	if w.ledger != nil {
		w.ledger.report(message.BrewID, message.ShotID, message.Kind)
	}
	if w.onTerminal != nil && terminalReportKinds(message.Kind) {
		w.onTerminal(message.BrewID, message.ShotID)
	}
	_ = w.emit(proto.Event{
		Type:        "station_report",
		RequestID:   message.BrewID,
		ShotID:      message.ShotID,
		Kind:        message.Kind,
		Description: reportText(message.Description),
	})
	w.checkLedger()
}

// handle acknowledges one line and then acts on it. Every line is acknowledged before it
// is handled, so a caller can tell an unanswered request from one never read.
func (w *writer) handleWith(line string, dispatch *dispatcher) (stop bool, err error) {
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
	case "dispatch":
		if dispatch == nil {
			return false, w.emit(proto.Event{Type: "error", RequestID: requestID, Reason: "this host has no CLI seam configured, so it cannot dispatch"})
		}
		dispatch.dispatch(context.Background(), request.RequestID, json.RawMessage(line))
		return false, nil
	case "cancel":
		if dispatch == nil {
			return false, w.emit(proto.Event{Type: "error", RequestID: requestID, Reason: "this host has no CLI seam configured, so it cannot cancel"})
		}
		var shotID string
		var root map[string]json.RawMessage
		if json.Unmarshal([]byte(line), &root) == nil {
			_ = json.Unmarshal(root["shot_id"], &shotID)
		}
		dispatch.cancel(request.RequestID, shotID)
		return false, nil
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
	w.mu.Lock()
	defer w.mu.Unlock()
	e.At = stamp(w.now())
	// History first, then stdout: a reader that sees an event can rely on it being
	// recorded, and `status --stations` rebuilds liveness from this file.
	if historyEvent(e.Type) {
		_ = w.appendEvent(e)
	}
	line, err := proto.EventLine(e)
	if err != nil {
		return err
	}
	_, err = w.out.Write(line)
	return err
}

// historyEvent is the set of events the durable history keeps, matching the Odin host.
func historyEvent(eventType string) bool {
	switch eventType {
	case "dispatch_accepted", "session_started", "session_failed", "station_report", "reply_sent", "blended", "blend_failed":
		return true
	}
	return false
}

// appendEvent writes one event to <host>/<request>/history.ndjson.
func (w *writer) appendEvent(e proto.Event) error {
	if w.root == "" || !validShotID(e.RequestID) {
		return nil
	}
	dir := state.RequestDir(w.root, e.RequestID)
	if err := state.EnsureDir(dir, true); err != nil {
		return err
	}
	line, err := proto.EventLine(e)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(state.HistoryPath(w.root, e.RequestID), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer func() { _ = file.Close() }()
	_, err = file.Write(line)
	return err
}

func (w *writer) raw(line string) error {
	w.mu.Lock()
	defer w.mu.Unlock()
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
