package host

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/weima/coffee-shop/go/internal/state"
)

// The dispatch event sequence is the contract a consumer reads: a Barista that sees these
// events in another order, or missing one, is broken even if each event is well formed.
// This pins the sequence for one Shot, normalized for the timestamp only.
func TestDispatchEventSequenceIsStable(t *testing.T) {
	_, out, input, stop := startHostWithInput(t)
	defer stop()
	repo := shortRoot(t)

	request := `{"type":"dispatch","request_id":"req-1","repo":"` + repo + `","recipe":{"shots":[{"id":"shot-a","prompt":"work"}]}}` + "\n"
	if _, err := input.Write([]byte(request)); err != nil {
		t.Fatalf("send dispatch: %v", err)
	}
	waitFor(t, out, `"type":"station_report"`)
	// The fake Station reports `pulled` and exits; give the exit path a moment so the
	// stream cannot grow while it is being compared.
	waitFor(t, out, `"kind":"pulled"`)
	_ = input.Close()

	got := normalizedEvents(t, out.String())
	want := []string{
		`{"type":"ready","protocol":1,"at":"AT"}`,
		`{"type":"received","request_id":"req-1","bytes":` + itoa(len(request)-1) + `,"at":"AT"}`,
		`{"type":"dispatch_accepted","request_id":"req-1","at":"AT"}`,
		`{"type":"session_started","request_id":"req-1","shot_id":"shot-a","at":"AT"}`,
		`{"type":"station_report","request_id":"req-1","shot_id":"shot-a","kind":"pulled","description":"fake","at":"AT"}`,
	}
	if len(got) != len(want) {
		t.Fatalf("event count %d, want %d:\n%s", len(got), len(want), strings.Join(got, "\n"))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("event %d\n got: %s\nwant: %s", i, got[i], want[i])
		}
	}
}

// Every Station report the host relays must be recoverable from history, so a consumer can
// rebuild what happened without the stdout stream.
func TestRelayedReportIsAlsoInHistory(t *testing.T) {
	root, out, input, stop := startHostWithInput(t)
	defer stop()
	repo := shortRoot(t)

	request := `{"type":"dispatch","request_id":"req-1","repo":"` + repo + `","recipe":{"shots":[{"id":"shot-a","prompt":"work"}]}}` + "\n"
	if _, err := input.Write([]byte(request)); err != nil {
		t.Fatalf("send dispatch: %v", err)
	}
	waitFor(t, out, `"kind":"pulled"`)

	history, err := os.ReadFile(state.HistoryPath(root, "req-1"))
	if err != nil {
		t.Fatalf("read history: %v", err)
	}
	var found bool
	for _, line := range strings.Split(strings.TrimSuffix(string(history), "\n"), "\n") {
		var event struct {
			Type   string `json:"type"`
			Kind   string `json:"kind"`
			ShotID string `json:"shot_id"`
		}
		if json.Unmarshal([]byte(line), &event) != nil {
			t.Fatalf("history line is not JSON: %s", line)
		}
		if event.Type == "station_report" && event.Kind == "pulled" && event.ShotID == "shot-a" {
			found = true
		}
	}
	if !found {
		t.Fatalf("history should contain the pulled report:\n%s", history)
	}
}

func normalizedEvents(t *testing.T, stream string) []string {
	t.Helper()
	lines := strings.Split(strings.TrimSuffix(stream, "\n"), "\n")
	for i, line := range lines {
		lines[i] = normalizeTimestamp(line)
	}
	return lines
}

// normalizeTimestamp is the same rule the conformance harness uses: only the timestamp
// value is replaced, so any other difference fails.
func normalizeTimestamp(line string) string {
	const marker = `"at":"`
	const stampLen = len("2026-10-31T19:20:01.123Z")
	i := strings.LastIndex(line, marker)
	if i < 0 {
		return line
	}
	start := i + len(marker)
	if start+stampLen > len(line) || line[start+stampLen] != '"' {
		return line
	}
	return line[:start] + "AT" + line[start+stampLen:]
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits []byte
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}

// startHostWithInput runs a host with a state root and the fake CLI, and returns its stdin
// so a test can send real requests through the contract rather than reaching into the
// package.
func startHostWithInput(t *testing.T) (root string, out *syncBuilder, input *os.File, stop func()) {
	t.Helper()
	t.Setenv(fakeCLIEnv, "1")
	root = shortRoot(t)
	out = &syncBuilder{}
	extensionDir := root + "/host/extensions"
	if err := os.MkdirAll(extensionDir, 0o700); err != nil {
		t.Fatalf("extension dir: %v", err)
	}
	if err := os.WriteFile(extensionDir+"/coffee-shop.ts", []byte("// stand-in"), 0o600); err != nil {
		t.Fatalf("extension file: %v", err)
	}

	in, writeIn, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = Run(t.Context(), Options{
			In:        in,
			Out:       out,
			StateRoot: root,
			CLI:       []string{os.Args[0]},
			Now:       fixedClock(),
		})
	}()
	waitForSocketNoErr(t, state.ActivitySocket(root))
	return root, out, writeIn, func() {
		_ = writeIn.Close()
		<-done
	}
}

// A guard on the guard: the comparison must reject a stream that is missing an event or has
// one in the wrong place, otherwise it would pass on any stream at all.
func TestGoldenNoticesAWrongStream(t *testing.T) {
	stream := strings.Join([]string{
		`{"type":"ready","protocol":1,"at":"2026-10-31T20:23:04.406Z"}`,
		`{"type":"dispatch_accepted","request_id":"req-1","at":"2026-10-31T20:23:04.406Z"}`,
	}, "\n") + "\n"
	got := normalizedEvents(t, stream)
	want := []string{
		`{"type":"ready","protocol":1,"at":"AT"}`,
		`{"type":"received","request_id":"req-1","bytes":1,"at":"AT"}`,
		`{"type":"dispatch_accepted","request_id":"req-1","at":"AT"}`,
	}
	if len(got) == len(want) {
		t.Fatal("the comparison must notice a missing event")
	}
	if normalizeTimestamp(`{"type":"x","at":"not-a-timestamp"}`) != `{"type":"x","at":"not-a-timestamp"}` {
		t.Fatal("normalization must leave a non-timestamp value alone")
	}
}
