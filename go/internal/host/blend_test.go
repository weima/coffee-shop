package host

// The host's half of a Blend: it hands the request to the Odin seam as a file and relays
// the events the seam prints, so a Blend looks the same on the wire as it did when the
// Odin host ran it itself.

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/weima/coffee-shop/go/internal/state"
)

func TestBlendRequestIsRelayedFromTheSeam(t *testing.T) {
	t.Setenv("CS_FAKE_BLEND", "ok")
	root, out, writeIn, stop := dispatchHostWithInput(t)
	defer stop()

	request := `{"type":"blend","request_id":"blend-1","repo":"/tmp/beans","base":"abcdef1","commits":["1111111","2222222"],"branch":"blend-out","message":"Blend two Pulls"}`
	if _, err := io.WriteString(writeIn, request+"\n"); err != nil {
		t.Fatalf("send request: %v", err)
	}
	waitFor(t, out, `"type":"blended","request_id":"blend-1","branch":"blend-out","commit":"abc1234"`)

	// The request reached the seam as a file, which is what keeps it out of a shell.
	sent, err := os.ReadFile(filepath.Join(state.RequestDir(root, "blend-1"), "blend-request.json"))
	if err != nil {
		t.Fatalf("the seam should have been given the request file: %v", err)
	}
	if !strings.Contains(string(sent), `"branch":"blend-out"`) {
		t.Fatalf("the request file should hold the request the host received: %s", sent)
	}

	// A relayed Blend is recorded, as every other terminal event is.
	history, readErr := os.ReadFile(state.HistoryPath(root, "blend-1"))
	if readErr != nil {
		t.Fatalf("read history: %v", readErr)
	}
	if !strings.Contains(string(history), `"type":"blended"`) {
		t.Fatalf("a blended event must be recorded:\n%s", history)
	}
}

func TestBlendSeamFailureBecomesAnErrorEvent(t *testing.T) {
	t.Setenv("CS_FAKE_BLEND", "fail")
	_, out, writeIn, stop := dispatchHostWithInput(t)
	defer stop()

	request := `{"type":"blend","request_id":"blend-2","repo":"/tmp/beans","base":"abcdef1","commits":["1111111","2222222"],"branch":"blend-out","message":"m"}`
	if _, err := io.WriteString(writeIn, request+"\n"); err != nil {
		t.Fatalf("send request: %v", err)
	}
	// A seam that dies without an event must still tell the caller why.
	waitFor(t, out, `"type":"error","request_id":"blend-2"`)
	waitFor(t, out, "the seam could not run")
}

func TestBlendNeedsTheCLISeam(t *testing.T) {
	// A host with no state root has no seam, so a Blend is refused rather than ignored.
	out := &syncBuilder{}
	w := &writer{out: out, now: fixedClock()}
	if _, err := w.handleWith(`{"type":"blend","request_id":"blend-3"}`, nil); err != nil {
		t.Fatalf("handle: %v", err)
	}
	if !strings.Contains(out.String(), "cannot blend") {
		t.Fatalf("a host without a seam must say so:\n%s", out.String())
	}
}

// A seam's rejection event is relayed unchanged, not turned into a generic failure.
func TestBlendRejectionIsRelayed(t *testing.T) {
	t.Setenv("CS_FAKE_BLEND", "reject")
	_, out, writeIn, stop := dispatchHostWithInput(t)
	defer stop()

	request := `{"type":"blend","request_id":"blend-4","repo":"/tmp/beans","base":"abcdef1","commits":["1111111"],"branch":"blend-out","message":"m"}`
	if _, err := io.WriteString(writeIn, request+"\n"); err != nil {
		t.Fatalf("send request: %v", err)
	}
	waitFor(t, out, `"type":"error","request_id":"blend-4","reason":"commits must list 2 to 20 commit hashes"`)
}
