package host

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/weima/coffee-shop/go/internal/proto"
	"github.com/weima/coffee-shop/go/internal/state"
)

// serveStateHost starts a host with a state root and returns its root, the output
// builder to inspect, and a stop function.
func serveStateHost(t *testing.T) (root string, out *syncBuilder, stop func()) {
	t.Helper()
	root = shortRoot(t)
	out = &syncBuilder{}
	ctx, cancel := context.WithCancel(context.Background())
	in, writeIn, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	done := make(chan struct{})
	runErr := make(chan error, 1)
	go func() {
		defer close(done)
		runErr <- Run(ctx, Options{In: in, Out: out, StateRoot: root, Now: fixedClock()})
	}()
	waitForSocket(t, state.ActivitySocket(root), runErr)
	return root, out, func() {
		cancel()
		_ = writeIn.Close()
		<-done
	}
}

// syncBuilder is a strings.Builder safe for the host goroutine and the test.
type syncBuilder struct {
	mu   sync.Mutex
	data strings.Builder
}

func (b *syncBuilder) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.Write(p)
}

func (b *syncBuilder) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.String()
}

// shortRoot keeps the socket path inside the platform's sun_path limit. A test temp
// directory under /var/folders is long enough that bind fails on macOS.
func shortRoot(t *testing.T) string {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "csgo-")
	if err != nil {
		t.Fatalf("temp root: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	return root
}

func waitForSocket(t *testing.T, path string, runErr chan error) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if _, err := os.Stat(path); err == nil {
			return
		}
		select {
		case err := <-runErr:
			t.Fatalf("host stopped before listening: %v", err)
		default:
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("socket %s never appeared", path)
}

func sendReport(t *testing.T, root, line string) {
	t.Helper()
	conn, err := net.Dial("unix", state.ActivitySocket(root))
	if err != nil {
		t.Fatalf("dial activity socket: %v", err)
	}
	defer func() { _ = conn.Close() }()
	if _, err := conn.Write([]byte(line + "\n")); err != nil {
		t.Fatalf("write report: %v", err)
	}
}

func waitFor(t *testing.T, out *syncBuilder, want string) {
	t.Helper()
	for i := 0; i < 400; i++ {
		if strings.Contains(out.String(), want) {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("never saw %q in:\n%s", want, out.String())
}

// A report reaches stdout, is written to history and its spool copy is removed.
func TestActivityRelaysReportAndRemovesSpool(t *testing.T) {
	root, out, stop := serveStateHost(t)
	defer stop()

	if err := state.EnsureDir(state.SpoolDir(root), true); err != nil {
		t.Fatalf("spool dir: %v", err)
	}
	spool := "00000000000000000001-abc.json"
	spooled := `{"brew_id":"req-1","shot_id":"shot-a","kind":"turn_done","description":"pending shot-a","timestamp_ns":1,"spool":"` + spool + `"}`
	if err := os.WriteFile(filepath.Join(state.SpoolDir(root), spool), []byte(spooled), 0o600); err != nil {
		t.Fatalf("write spool: %v", err)
	}

	sendReport(t, root, spooled)
	waitFor(t, out, `{"type":"station_report","request_id":"req-1","shot_id":"shot-a","kind":"turn_done","description":"pending shot-a","at":"2026-10-31T20:23:04.406Z"}`)

	if _, err := os.Stat(filepath.Join(state.SpoolDir(root), spool)); !os.IsNotExist(err) {
		t.Fatalf("the spooled copy should be gone after relay, stat err: %v", err)
	}
	history, err := os.ReadFile(state.HistoryPath(root, "req-1"))
	if err != nil {
		t.Fatalf("read history: %v", err)
	}
	if !strings.Contains(string(history), `"kind":"turn_done"`) {
		t.Fatalf("history should record the report:\n%s", history)
	}
}

// A Station's self-report is recorded but never relayed as a station_report.
func TestActivityDoesNotRelayStationPID(t *testing.T) {
	root, out, stop := serveStateHost(t)
	defer stop()
	sendReport(t, root, `{"brew_id":"req-1","shot_id":"shot-a","kind":"station_pid","description":"pid=1 start=2 agent=3","timestamp_ns":1}`)
	// Give the server a moment to handle it, then look at what was announced.
	time.Sleep(150 * time.Millisecond)
	if got := out.String(); strings.Contains(got, `"kind":"station_pid"`) {
		t.Fatalf("station_pid must not be relayed:\n%s", got)
	}
}

// A malformed or invalid report is dropped without ending the host.
func TestActivityDropsInvalidReports(t *testing.T) {
	root, out, stop := serveStateHost(t)
	defer stop()
	for _, line := range []string{
		`not json`,
		`{"brew_id":"../x","shot_id":"shot-a","kind":"turn_done","description":"d","timestamp_ns":1}`,
		`{"brew_id":"req-1","shot_id":"shot-a","kind":"","description":"d","timestamp_ns":1}`,
		`{"brew_id":"req-1","shot_id":"shot-a","kind":"turn_done","description":"d","timestamp_ns":0}`,
		`{"brew_id":"req-1","shot_id":"shot-a","kind":"turn_done","description":"d","timestamp_ns":1,"spool":"../escape"}`,
	} {
		sendReport(t, root, line)
	}
	sendReport(t, root, `{"brew_id":"req-1","shot_id":"shot-a","kind":"turn_done","description":"valid","timestamp_ns":1}`)
	waitFor(t, out, `"description":"valid"`)
	if strings.Contains(out.String(), "not json") {
		t.Fatalf("a malformed line must not be relayed:\n%s", out.String())
	}
}

// Reports spooled by a previous host are relayed on start, oldest first, and removed.
func TestReplaySpoolRelaysUnrelayedReportsInOrder(t *testing.T) {
	root := shortRoot(t)
	if err := state.EnsureDir(state.SpoolDir(root), true); err != nil {
		t.Fatalf("spool dir: %v", err)
	}
	names := []string{"00000000000000000001-a.json", "00000000000000000002-b.json"}
	for i, name := range names {
		line := fmt.Sprintf(`{"brew_id":"order-1","shot_id":"shot-%c","kind":"turn_done","description":"pending %c","timestamp_ns":%d,"spool":"%s"}`, 'a'+i, 'a'+i, i+1, name)
		if err := os.WriteFile(filepath.Join(state.SpoolDir(root), name), []byte(line), 0o600); err != nil {
			t.Fatalf("write spool %s: %v", name, err)
		}
	}
	out := &syncBuilder{}
	w := &writer{out: out, now: fixedClock(), root: root}
	if got := ReplaySpool(root, w); got != 2 {
		t.Fatalf("replayed %d reports, want 2", got)
	}
	stream := out.String()
	first := strings.Index(stream, `"shot_id":"shot-a"`)
	second := strings.Index(stream, `"shot_id":"shot-b"`)
	if first < 0 || second < 0 || first > second {
		t.Fatalf("reports should be relayed oldest first:\n%s", stream)
	}
	entries, err := os.ReadDir(state.SpoolDir(root))
	if err != nil {
		t.Fatalf("read spool: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("relayed spool entries must be removed, %d left", len(entries))
	}
}

// A report that is already valid JSON but not a report stays on disk for inspection.
func TestReplaySpoolKeepsUnreadableEntries(t *testing.T) {
	root := shortRoot(t)
	if err := state.EnsureDir(state.SpoolDir(root), true); err != nil {
		t.Fatalf("spool dir: %v", err)
	}
	name := "00000000000000000003-bad.json"
	if err := os.WriteFile(filepath.Join(state.SpoolDir(root), name), []byte(`{"brew_id":"","shot_id":"","kind":"","description":"","timestamp_ns":0}`), 0o600); err != nil {
		t.Fatalf("write spool: %v", err)
	}
	out := &syncBuilder{}
	w := &writer{out: out, now: fixedClock(), root: root}
	if got := ReplaySpool(root, w); got != 0 {
		t.Fatalf("an invalid entry must not be relayed, replayed %d", got)
	}
	if _, err := os.Stat(filepath.Join(state.SpoolDir(root), name)); err != nil {
		t.Fatalf("an invalid entry must stay on disk: %v", err)
	}
}

var _ = proto.Message{}

// A Station keeps one connection for its whole life and sends several reports on it, so
// the host must read every line rather than one. This is the bug the first cross-language
// run found: the first report was a station_pid, and closing after it stranded the rest
// in the spool.
func TestActivityRelaysEveryReportOnOneConnection(t *testing.T) {
	root, out, stop := serveStateHost(t)
	defer stop()

	conn, err := net.Dial("unix", state.ActivitySocket(root))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	lines := []string{
		`{"brew_id":"req-1","shot_id":"shot-a","kind":"station_pid","description":"station=1 start=2 agent=3","timestamp_ns":1}`,
		`{"brew_id":"req-1","shot_id":"shot-a","kind":"turn_done","description":"first","timestamp_ns":2}`,
		`{"brew_id":"req-1","shot_id":"shot-a","kind":"agent_exited","description":"Agent exited","timestamp_ns":3}`,
	}
	for _, line := range lines {
		if _, err := conn.Write([]byte(line + "\n")); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	_ = conn.Close()

	waitFor(t, out, `"kind":"turn_done"`)
	waitFor(t, out, `"kind":"agent_exited"`)
	if strings.Contains(out.String(), `"kind":"station_pid"`) {
		t.Fatalf("station_pid must not be relayed:\n%s", out.String())
	}
}

// Two Stations reporting at the same time must not interleave on stdout: the relay is the
// single writer, and the channel is the only path to it. A torn event line is a wire bug a
// consumer cannot recover from.
func TestConcurrentStationsNeverTearAnEventLine(t *testing.T) {
	root, out, stop := serveStateHost(t)
	defer stop()

	const stations = 8
	done := make(chan struct{}, stations)
	for i := 0; i < stations; i++ {
		go func(n int) {
			defer func() { done <- struct{}{} }()
			conn, err := net.Dial("unix", state.ActivitySocket(root))
			if err != nil {
				return
			}
			defer func() { _ = conn.Close() }()
			shot := fmt.Sprintf("shot-%d", n)
			for j := 0; j < 20; j++ {
				line := fmt.Sprintf(`{"brew_id":"req-1","shot_id":"%s","kind":"turn_done","description":"report %d from %s","timestamp_ns":%d}`, shot, j, shot, j+1)
				if _, err := conn.Write([]byte(line + "\n")); err != nil {
					return
				}
			}
		}(i)
	}
	for i := 0; i < stations; i++ {
		<-done
	}
	waitFor(t, out, `"shot_id":"shot-7"`)

	for _, line := range strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n") {
		if !strings.HasPrefix(line, `{"type":"`) || !strings.HasSuffix(line, "}") {
			t.Fatalf("torn event line: %q", line)
		}
	}
}
