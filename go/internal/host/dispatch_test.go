package host

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/weima/coffee-shop/go/internal/extension"
	"github.com/weima/coffee-shop/go/internal/state"
)

// The fake Odin CLI. A test binary re-executes itself with CS_FAKE_CLI_MODE set, which is
// the standard way to fake a subprocess without building one.
const fakeCLIEnv = "CS_FAKE_CLI_MODE"

func TestMain(m *testing.M) {
	if os.Getenv(fakeCLIEnv) != "" {
		fakeCLI(os.Args[1:])
		return
	}
	// The durability test's fake Station is the same re-exec seam, under its own mode.
	if os.Getenv(fakeDurabilityStationEnv) != "" {
		fakeDurabilityStation(os.Args[1:])
		return
	}
	os.Exit(m.Run())
}

// fakeCLI implements the two seam commands the dispatcher drives.
func fakeCLI(argv []string) {
	if len(argv) == 0 {
		os.Exit(2)
	}
	switch argv[0] {
	case "prepare":
		dir := flagValue(argv, "--dir")
		if dir == "" || os.MkdirAll(dir, 0o700) != nil {
			os.Exit(1)
		}
		os.Exit(0)
	case "station":
		socket := flagValue(argv, "--report")
		shot := flagValue(argv, "--station")
		request := flagValue(argv, "--brew")
		kind := flagValue(argv, "--kind")
		if kind == "" {
			kind = "execute"
		}
		// A Station reports, then exits, which is all dispatch needs to observe. With
		// CS_FAKE_ECHO it first waits for one line on stdin and reports it, so a reply can
		// be observed crossing the process boundary.
		description := "fake"
		if os.Getenv("CS_FAKE_ECHO") == "1" {
			line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
			description = strings.TrimSpace(line)
		}
		conn, err := net.Dial("unix", socket)
		if err != nil {
			os.Exit(1)
		}
		report := map[string]any{
			"brew_id": request, "shot_id": shot, "kind": "pulled",
			"description": description, "timestamp_ns": time.Now().UnixNano(),
		}
		data, _ := json.Marshal(report)
		_, _ = conn.Write(append(data, '\n'))
		_ = conn.Close()
		os.Exit(0)
	}
	os.Exit(2)
}

func flagValue(argv []string, flag string) string {
	for i := 0; i+1 < len(argv); i++ {
		if argv[i] == flag {
			return argv[i+1]
		}
	}
	return ""
}

// installedExtension installs the real Pi extension through csd's install path, so the
// dispatcher tests use the file the production install writes.
func installedExtension(t *testing.T, root string) string {
	t.Helper()
	path, err := extension.Install(root)
	if err != nil {
		t.Fatalf("install extension: %v", err)
	}
	return path
}

// dispatchHost starts a host with a state root and the fake CLI, and returns it.
func dispatchHost(t *testing.T) (root string, out *syncBuilder, stop func()) {
	root, out, _, stop = dispatchHostWithInput(t)
	return
}

// dispatchHostWithInput also returns the host's stdin, so a test can send real requests.
func dispatchHostWithInput(t *testing.T) (root string, out *syncBuilder, input io.WriteCloser, stop func()) {
	t.Helper()
	t.Setenv(fakeCLIEnv, "1")
	root = shortRoot(t)
	out = &syncBuilder{}
	// The Odin host installs the Pi extension at start; a fake Station does not read it,
	// but dispatch refuses to launch without it.
	extensionDir := filepath.Join(root, "host", "extensions")
	if err := os.MkdirAll(extensionDir, 0o700); err != nil {
		t.Fatalf("extension dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(extensionDir, "coffee-shop.ts"), []byte("// stand-in"), 0o600); err != nil {
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

func waitForSocketNoErr(t *testing.T, path string) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("socket %s never appeared", path)
}

func dispatchRequestJSON(repo string, shots ...string) string {
	quoted := make([]string, len(shots))
	for i, shot := range shots {
		quoted[i] = `{"id":"` + shot + `","prompt":"do the thing"}`
	}
	return `{"type":"dispatch","request_id":"req-1","repo":"` + repo + `","recipe":{"shots":[` + strings.Join(quoted, ",") + `]}}`
}

// A dispatch creates the worktree through the seam, writes the prompt, starts the Station
// and logs its output.
func TestDispatchPreparesPromptAndLogAndStartsStation(t *testing.T) {
	root, _, stop := dispatchHost(t)
	defer stop()
	repo := shortRoot(t)

	d := newDispatcher(root, []string{os.Args[0]}, state.ActivitySocket(root), installedExtension(t, root), "", &writer{out: &syncBuilder{}, now: fixedClock(), root: root})
	d.dispatch(t.Context(), "req-1", json.RawMessage(dispatchRequestJSON(repo, "shot-a")))

	station := state.StationDir(root, "req-1", "shot-a")
	if _, err := os.Stat(station); err != nil {
		t.Fatalf("the seam should have created the worktree: %v", err)
	}
	prompt, err := os.ReadFile(state.PromptPath(root, "req-1", "shot-a"))
	if err != nil {
		t.Fatalf("read prompt: %v", err)
	}
	if !strings.HasPrefix(string(prompt), ReplyStyle) || !strings.Contains(string(prompt), "do the thing") {
		t.Fatalf("prompt should carry the reply style and the Shot text:\n%s", prompt)
	}
	if _, err := os.Stat(state.LogPath(root, "req-1", "shot-a")); err != nil {
		t.Fatalf("a per-Shot log should exist: %v", err)
	}
}

// A Shot waits for a Slot rather than failing, and starts when one frees. The Slots are
// pre-filled so the test does not depend on how fast a child process runs.
func TestDispatchQueuesBeyondCapacityAndStartsOnRelease(t *testing.T) {
	root, out, stop := dispatchHost(t)
	defer stop()
	repo := shortRoot(t)

	d := newDispatcher(root, []string{os.Args[0]}, state.ActivitySocket(root), installedExtension(t, root), "", &writer{out: out, now: fixedClock(), root: root})
	for i := 0; i < SlotCapacity; i++ {
		if !d.slots.acquire("busy", fmt.Sprintf("shot-%d", i)) {
			t.Fatalf("filling slot %d should succeed", i)
		}
	}

	d.dispatch(t.Context(), "req-1", json.RawMessage(dispatchRequestJSON(repo, "shot-a")))
	waitFor(t, out, `"type":"dispatch_queued","request_id":"req-1","shot_id":"shot-a"`)
	if strings.Contains(out.String(), `"type":"session_started"`) {
		t.Fatalf("a queued Shot must not start while the host is full:\n%s", out.String())
	}

	// Freeing one Slot starts the waiting Shot, which then reports like any other.
	d.release("busy", "shot-0")
	waitFor(t, out, `"type":"dispatch_dequeued","request_id":"req-1","shot_id":"shot-a"`)
	waitFor(t, out, `"type":"session_started","request_id":"req-1","shot_id":"shot-a"`)
}

// Capability: a request that fails validation touches nothing.
func TestDispatchRejectsInvalidRequestsBeforeAnyWork(t *testing.T) {
	root, out, stop := dispatchHost(t)
	defer stop()

	d := newDispatcher(root, []string{os.Args[0]}, state.ActivitySocket(root), installedExtension(t, root), "", &writer{out: out, now: fixedClock(), root: root})
	cases := []struct{ name, request, want string }{
		{"relative repo", `{"repo":"beans","recipe":{"shots":[{"id":"a","prompt":"p"}]}}`, `"reason":"repo must be an absolute path"`},
		{"no shots", `{"repo":"/tmp/beans","recipe":{"shots":[]}}`, `"reason":"recipe needs at least one shot"`},
		{"bad id", `{"repo":"/tmp/beans","recipe":{"shots":[{"id":"-x","prompt":"p"}]}}`, `"each shot needs a valid id and a prompt"`},
		{"duplicate", `{"repo":"/tmp/beans","recipe":{"shots":[{"id":"a","prompt":"p"},{"id":"a","prompt":"q"}]}}`, `"shot ids must be unique"`},
		{"bad kind", `{"repo":"/tmp/beans","recipe":{"shots":[{"id":"a","prompt":"p","kind":"write"}]}}`, `"shot kind must be execute or research"`},
		{"taste on research", `{"repo":"/tmp/beans","recipe":{"shots":[{"id":"a","prompt":"p","kind":"research","taste":"true","message":"m"}]}}`, `"shot taste needs an execute kind"`},
		{"taste without message", `{"repo":"/tmp/beans","recipe":{"shots":[{"id":"a","prompt":"p","taste":"true"}]}}`, `"shot message is required with a taste`},
	}
	for _, c := range cases {
		d.dispatch(t.Context(), "req-"+c.name, json.RawMessage(c.request))
		if !strings.Contains(out.String(), c.want) {
			t.Fatalf("%s: expected %s in:\n%s", c.name, c.want, out.String())
		}
		if strings.Contains(out.String(), `"type":"session_started"`) {
			t.Fatalf("%s: nothing should have started", c.name)
		}
	}
}

// The Station command is an argv, so no quoting and no shell: a path with a space and a
// quote stays one argument.
func TestStationArgvNeedsNoQuoting(t *testing.T) {
	d := newDispatcher("/state", []string{"coffee-shop"}, "/state/host/activity.sock", "/state/host/extensions/coffee-shop.ts", "", &writer{})
	shot := ShotRequest{ID: "shot-a", Model: DefaultStationModel, Kind: ShotExecute, Codemode: true}
	argv := d.stationArgv("req-1", shot, `/state/host/req-1/prompts/shot a.md`)

	joined := strings.Join(argv, "\x00")
	for _, want := range []string{
		"station\x00--kind\x00execute",
		"--report\x00/state/host/activity.sock",
		"--prompt-file\x00/state/host/req-1/prompts/shot a.md",
		"--\x00pi\x00--mode\x00rpc",
		"--tools\x00+codemode",
		"--model\x00opencode-go/deepseek-v4.1-flash",
		"-e\x00/state/host/extensions/coffee-shop.ts",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("argv missing %q:\n%v", want, argv)
		}
	}
}

// A bounded log keeps the newest bytes and rotates one generation aside, so a reader sees
// how a run ended rather than how it began.
func TestBoundedLogKeepsTheNewestBytes(t *testing.T) {
	dir := shortRoot(t)
	path := dir + "/shot.log"
	log, err := openBoundedLog(path, 32)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	// One write larger than the whole bound: the tail is what must survive.
	if _, err := log.Write([]byte("0123456789" + "HEAD-TAIL-MARKER-TAIL")); err != nil {
		t.Fatalf("write: %v", err)
	}
	_ = log.Close()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if len(data) > 32 {
		t.Fatalf("log exceeds the bound: %d bytes", len(data))
	}
	if !strings.Contains(string(data), "TAIL-MARKER") {
		t.Fatalf("the newest bytes must be kept, got %q", data)
	}

	// A second overflow rotates the first generation aside.
	log, err = openBoundedLog(path, 32)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	_, _ = log.Write([]byte("aaaaaaaaaaaaaaaaaaaa"))
	_, _ = log.Write([]byte("bbbbbbbbbbbbbbbbbbbb"))
	_ = log.Close()
	if _, err := os.Stat(path + ".1"); err != nil {
		t.Fatalf("an overflow should leave the previous generation in .1: %v", err)
	}
}
