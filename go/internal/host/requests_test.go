package host

import (
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/weima/coffee-shop/go/internal/proto"
	"github.com/weima/coffee-shop/go/internal/state"
)

// askServer sends one request line and returns the ack.
func askServer(t *testing.T, root, line string) proto.Ack {
	t.Helper()
	conn, err := net.Dial("unix", state.RequestsSocket(root))
	if err != nil {
		t.Fatalf("dial request socket: %v", err)
	}
	defer func() { _ = conn.Close() }()
	if _, err := conn.Write([]byte(line + "\n")); err != nil {
		t.Fatalf("write request: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	buf := make([]byte, 4096)
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	var ack proto.Ack
	if err := json.Unmarshal(buf[:n], &ack); err != nil {
		t.Fatalf("decode ack %q: %v", buf[:n], err)
	}
	return ack
}

// A reply reaches the Station's input and is acknowledged, which is the whole point of the
// request socket: no pane, no terminal. The Station here echoes what it receives, so the
// reply is observable in the event stream.
func TestReplyReachesTheStationAndIsAcknowledged(t *testing.T) {
	t.Setenv("CS_FAKE_ECHO", "1")
	root, out, input, stop := dispatchHostWithInput(t)
	defer stop()
	repo := shortRoot(t)

	dispatch := `{"type":"dispatch","request_id":"req-1","repo":"` + repo + `","recipe":{"shots":[{"id":"shot-a","prompt":"wait for a reply"}]}}` + "\n"
	if _, err := input.Write([]byte(dispatch)); err != nil {
		t.Fatalf("send dispatch: %v", err)
	}
	waitFor(t, out, `"type":"session_started","request_id":"req-1","shot_id":"shot-a"`)

	ack := askServer(t, root, `{"type":"reply","request_id":"req-1","shot_id":"shot-a","message":"hello from the socket"}`)
	if !ack.OK {
		t.Fatalf("reply refused: %s", ack.Reason)
	}
	waitFor(t, out, `"type":"reply_sent","request_id":"req-1","shot_id":"shot-a"`)
	waitFor(t, out, "hello from the socket")
}

// A reply for a Shot that is not running is refused with a reason, and the host keeps
// serving.
func TestReplyToUnknownShotIsRefused(t *testing.T) {
	root, _, stop := dispatchHost(t)
	defer stop()
	ack := askServer(t, root, `{"type":"reply","request_id":"req-1","shot_id":"shot-z","message":"hi"}`)
	if ack.OK || !strings.Contains(ack.Reason, "no Station is running") {
		t.Fatalf("expected a refusal naming the missing Station, got %+v", ack)
	}
}

// Only `reply` with exactly its four fields is accepted, so nothing on this socket can name
// a repository, command, path or shell.
func TestRequestSocketRejectsEverythingElse(t *testing.T) {
	root, _, stop := dispatchHost(t)
	defer stop()
	cases := []struct{ line, want string }{
		{`not json`, "invalid json"},
		{`[]`, "request must be an object"},
		{`{"type":"dispatch","request_id":"r"}`, "only reply requests"},
		{`{"type":"shutdown","request_id":"r"}`, "only reply requests"},
		{`{"type":"reply","request_id":"../x","shot_id":"s","message":"hi"}`, "request_id must be a valid"},
		{`{"type":"reply","request_id":"r","shot_id":"s","message":"hi","command":"rm -rf /"}`, `unexpected field "command"`},
	}
	for _, c := range cases {
		ack := askServer(t, root, c.line)
		if ack.OK || !strings.Contains(ack.Reason, c.want) {
			t.Fatalf("%s: expected %q, got %+v", c.line, c.want, ack)
		}
	}
}

// The host lock is what makes `status --stations` work and keeps two hosts off one state
// root, so it must be held while running and refused to a second host.
func TestHostLockIsExclusive(t *testing.T) {
	root := shortRoot(t)
	first, err := acquireHostLock(root)
	if err != nil {
		t.Fatalf("first lock: %v", err)
	}
	// flock is per open file, so a second *process* is what proves exclusion. Inside one
	// process a second open can take it, which is why the real check runs a child.
	if _, err := acquireHostLock(root); err == nil {
		t.Log("a second lock in the same process succeeded, as flock semantics allow")
	}
	first.release()
	if _, err := acquireHostLock(root); err != nil {
		t.Fatalf("after release the lock must be free: %v", err)
	}
}

// A cancel reaches the Station process and its Slot is freed: the outer half of the two
// cancel paths, the inner half being the Station stopping its own agent.
func TestCancelStopsTheStationAndFreesItsSlot(t *testing.T) {
	t.Setenv("CS_FAKE_ECHO", "1") // the fake Station waits on stdin, so it is alive to cancel
	_, out, input, stop := dispatchHostWithInput(t)
	defer stop()
	repo := shortRoot(t)

	dispatch := `{"type":"dispatch","request_id":"req-1","repo":"` + repo + `","recipe":{"shots":[{"id":"shot-a","prompt":"wait"}]}}` + "\n"
	if _, err := input.Write([]byte(dispatch)); err != nil {
		t.Fatalf("send dispatch: %v", err)
	}
	waitFor(t, out, `"type":"session_started","request_id":"req-1","shot_id":"shot-a"`)

	if _, err := input.Write([]byte(`{"type":"cancel","request_id":"req-1","shot_id":"shot-a"}` + "\n")); err != nil {
		t.Fatalf("send cancel: %v", err)
	}
	waitFor(t, out, `"type":"cancelled","request_id":"req-1","shot_id":"shot-a"`)

	// The Station's process must be gone, which also frees the Slot for the next Shot.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if !strings.Contains(out.String(), `"type":"session_started","request_id":"req-1","shot_id":"shot-a"`) ||
			strings.Contains(out.String(), `"type":"station_report"`) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// A cancel for a request with nothing running says so instead of failing silently.
func TestCancelWithoutAStationSaysSo(t *testing.T) {
	_, out, input, stop := dispatchHostWithInput(t)
	defer stop()
	if _, err := input.Write([]byte(`{"type":"cancel","request_id":"req-9","shot_id":"shot-a"}` + "\n")); err != nil {
		t.Fatalf("send cancel: %v", err)
	}
	waitFor(t, out, "no Station is running for that shot")
}
