package conformance

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The fake CLI seam below is a POSIX shell script the test writes into a temporary
// directory and hands to the real host through CS_CLI, exactly as a user's Odin CLI would
// be handed over. It implements only the two seam subcommands dispatch drives:
//
//	prepare  --repo R --branch B --dir D  	mkdir -p D
//	station  --report S --station N --brew R ... 	one pulled report over the socket
const fakeCLI = `#!/bin/sh
# Fake Odin CLI seam for the golden dispatch test: do not use outside a test.
set -u
if [ $# -eq 0 ]; then
  echo '{"reason":"fake seam: no subcommand"}' >&2
  exit 2
fi
cmd="$1"
shift

repo=""; branch=""; dir=""; report=""; station=""; brew=""
# Parse --name value pairs generically; the first "--" ends the flags, the rest is the
# agent argv this fake never launches.
while [ $# -gt 1 ]; do
  name="$1"
  case "$name" in
    --) break;;
    -*) ;;
    *) break;;
  esac
  value="$2"
  shift 2
  case "$name" in
    --repo) repo="$value";;
    --branch) branch="$value";;
    --dir) dir="$value";;
    --report) report="$value";;
    --station) station="$value";;
    --brew) brew="$value";;
  esac
done

case "$cmd" in
  prepare)
    if [ -z "$dir" ]; then echo '{"reason":"fake seam: prepare needs --dir"}' >&2; exit 2; fi
    mkdir -p -- "$dir" || exit 2
    ;;
  station)
    if [ -z "$report" ] || [ -z "$station" ] || [ -z "$brew" ]; then
      echo '{"reason":"fake seam: station needs --report, --station and --brew"}' >&2
      exit 2
    fi
    line=$(printf '{"brew_id":"%s","shot_id":"%s","kind":"pulled","description":"fake pulled","timestamp_ns":1}\n' "$brew" "$station")
    if command -v python3 >/dev/null 2>&1; then
      printf '%s' "$line" | python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.stdin.buffer.read()); s.close()' "$report"
    else
      printf '%s' "$line" | nc -U "$report"
    fi
    ;;
  *)
    echo "{\"reason\":\"fake seam: unknown subcommand $cmd\"}" >&2
    exit 2
    ;;
esac
`

// TestGoldenDispatchStream proves the Go host's dispatch contract end to end: it runs
// `go run ./cmd/csd` against a fake CLI seam and compares the events on stdout, byte for
// byte after normalizing only the `at` value, against testdata/golden-dispatch.ndjson.
//
// Run with -update to rewrite the golden after a deliberate contract change.
func TestGoldenDispatchStream(t *testing.T) {
	modRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("module root: %v", err)
	}

	// The state root doubles as the Beans repository, so one temp directory stands for
	// both. A short root keeps the two socket paths under the 104-byte unix limit.
	root, err := os.MkdirTemp("", "csd")
	if err != nil {
		t.Fatalf("state root: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })

	extensionDir := filepath.Join(root, "host", "extensions")
	if err := os.MkdirAll(extensionDir, 0o700); err != nil {
		t.Fatalf("extension dir: %v", err)
	}
	// Dispatch refuses to launch without the extension the Odin host writes at start.
	if err := os.WriteFile(filepath.Join(extensionDir, "coffee-shop.ts"), []byte("// stand-in\n"), 0o600); err != nil {
		t.Fatalf("extension file: %v", err)
	}

	cli := filepath.Join(root, "fake-cli")
	if err := os.WriteFile(cli, []byte(fakeCLI), 0o700); err != nil {
		t.Fatalf("fake CLI: %v", err)
	}
	agent := filepath.Join(root, "agent")
	if err := os.WriteFile(agent, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatalf("agent: %v", err)
	}

	if len(filepath.Join(root, "host", "activity.sock")) > 103 {
		t.Fatalf("state root %s is too deep for the activity socket path", root)
	}

	// The `received` event carries the request line's byte count, and a temp path's
	// length varies per run. Padding the line to a fixed length keeps that count
	// deterministic, so normalization can stay restricted to the `at` value.
	const requestLen = 256
	request := fmt.Sprintf(`{"type":"dispatch","request_id":"g1","repo":"%s","recipe":{"shots":[{"id":"s1","prompt":"p"}],"pad":"%s"}}`, root, padding(requestLen, root))
	shutdown := `{"type":"shutdown","request_id":"g1"}` + "\n"

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	got := runGoldenHost(ctx, t, modRoot, root, cli, agent, request, shutdown)

	if *update {
		if err := os.WriteFile("testdata/golden-dispatch.ndjson", []byte(strings.Join(got, "\n")+"\n"), 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		t.Log("rewrote testdata/golden-dispatch.ndjson")
	}
	golden, err := os.ReadFile("testdata/golden-dispatch.ndjson")
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	if err := Compare(got, Expected(string(golden))); err != nil {
		t.Fatalf("event stream no longer matches the golden: %v", err)
	}
}

// padding returns the pad string that brings request to exactly want bytes.
func padding(want int, root string) string {
	base := fmt.Sprintf(`{"type":"dispatch","request_id":"g1","repo":"%s","recipe":{"shots":[{"id":"s1","prompt":"p"}],"pad":""}}`, root)
	deficit := want - len(base)
	if deficit < 0 {
		panic(fmt.Sprintf("state root %s makes the request longer than the fixed %d bytes", root, want))
	}
	return strings.Repeat("x", deficit)
}

// runGoldenHost runs `go run ./cmd/csd`, sends the dispatch request, waits until the
// Station's report is relayed before shutting down, and returns the normalized events.
// The deliberate wait for the report makes the stream deterministic: without it, the
// station_report of a slow seam could arrive after `stopped` or not at all.
func runGoldenHost(ctx context.Context, t *testing.T, modRoot, root, cli, agent, request, shutdown string) []string {
	t.Helper()

	cmd := exec.CommandContext(ctx, "go", "run", "./cmd/csd")
	cmd.Dir = modRoot
	cmd.Env = append(os.Environ(),
		"CS_STATE_DIR="+root,
		"CS_CLI="+cli,
		"CS_AGENT="+agent,
	)

	var stderr strings.Builder
	cmd.Stderr = &stderr

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start host: %v", err)
	}
	defer func() { _ = stdin.Close() }()
	if _, err := io.WriteString(stdin, request+"\n"); err != nil {
		t.Fatalf("send dispatch: %v", err)
	}

	lines := make([]string, 0, 8)
	scanner := bufio.NewScanner(stdout)
	shutdownSent := false
	for scanner.Scan() {
		line := scanner.Text()
		lines = append(lines, line)
		if !shutdownSent && strings.Contains(line, `"type":"station_report"`) && strings.Contains(line, `"kind":"pulled"`) {
			_, _ = io.WriteString(stdin, shutdown)
			_ = stdin.Close()
			shutdownSent = true
		}
	}
	if waitErr := cmd.Wait(); waitErr != nil {
		t.Fatalf("host failed: %v\nstderr: %.2000s", waitErr, stderr.String())
	}
	return SplitLines(strings.Join(lines, "\n") + "\n")
}
