//go:build unix

package host

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/weima/coffee-shop/go/internal/state"
)

// The one gap in the cancel tests is the real cross-language boundary: a REAL Odin
// Station (`odin run src -- station ...`) whose agent ignores its input close and stays
// blocked where a model reply would be — exactly the v0.4 defect. This test drives the
// compiled host with the compiled Station through real processes only (`go run`,
// `odin run`; never a built binary) and proves a cancel ends the agent and leaves no
// Station process behind.
//
// The fake agent ignores SIGTERM on purpose, so a graceful stop cannot end it: only a
// hard kill can. Whichever half of the cancel delivers that kill — the Station's own
// agent stop (PR #143) or the host's escalation into the process group — the blocked
// agent must be gone within seconds.

// writeFakeAgent writes the blocked agent script and returns its pid file, which lets
// the test watch the agent the Go host never sees.
func writeFakeAgent(dir string) (fakeAgent, error) {
	path := filepath.Join(dir, "agent.sh")
	agent := fakeAgent{script: path, pidFile: filepath.Join(dir, "agent.pid")}
	script := fmt.Sprintf(`#!/bin/bash
echo $$ > '%s'
IFS= read -r line || true
trap '' TERM INT
sleep 600 &
wait
`, agent.pidFile)
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		return fakeAgent{}, err
	}
	return agent, nil
}

type fakeAgent struct {
	script  string
	pidFile string
}

// writeFakeCLI writes the fake Odin CLI seam. `prepare` does what the real seam does
// for this Shot; `station` swallows the agent argv the host appended and starts the
// real Odin Station instead. The pipeline under test is host → fake CLI →
// `odin run src` → compiled station binary → agent, all in one process group.
func writeFakeCLI(dir, repoRoot, agent string) (string, error) {
	script := fmt.Sprintf(`#!/bin/bash
mode="$1"; shift
case "$mode" in
  prepare)
    dir=""
    while [ $# -gt 1 ]; do
      case "$1" in
        --dir) dir="$2" ;;
      esac
      shift 2
    done
    mkdir -p "$dir"
    ;;
  station)
    kind="execute"; report=""; shot=""; brew=""; prompt_file=""
    while [ $# -gt 1 ]; do
      case "$1" in
        --kind) kind="$2" ;;
        --report) report="$2" ;;
        --station) shot="$2" ;;
        --brew) brew="$2" ;;
        --prompt-file) prompt_file="$2" ;;
      esac
      shift 2
    done
    exec odin run '%s' -- station --kind "$kind" --report "$report" \
      --station "$shot" --brew "$brew" --prompt-file "$prompt_file" -- sh '%s'
    ;;
  *) exit 2 ;;
esac
`, filepath.Join(repoRoot, "src"), agent)
	path := filepath.Join(dir, "fake-cli")
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		return "", err
	}
	return path, nil
}

// cancelIntegrationHost starts the real Go host (`go run ./cmd/csd`) with the fake CLI
// seam and returns its input, a captured stdout and a cleanup that never leaves the
// host or any child behind.
func cancelIntegrationHost(t *testing.T, root, fakeCLI string) (in io.WriteCloser, out *syncBuilder, stop func()) {
	t.Helper()
	cmd := exec.Command("go", "run", "./cmd/csd")
	cmd.Dir = filepath.Join(repoRoot(t), "go")
	// CS_AGENT stays unset: the CLI's station argv supplies the agent, and the fake CLI
	// swaps it for the blocked one.
	env := make([]string, 0, len(os.Environ()))
	for _, entry := range os.Environ() {
		if strings.HasPrefix(entry, "CS_AGENT=") || strings.HasPrefix(entry, "CS_STATION_MODEL=") {
			continue
		}
		env = append(env, entry)
	}
	cmd.Env = append(env, "CS_CLI="+fakeCLI, "CS_STATE_DIR="+root)
	setProcessGroup(cmd) // cleanup group-kills the whole `go run` tree; a pid kill would strand csd

	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	cmd.Stderr = os.Stderr
	out = &syncBuilder{}

	if err := cmd.Start(); err != nil {
		t.Fatalf("start csd: %v", err)
	}
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
		for scanner.Scan() {
			out.Write(scanner.Bytes())
			out.Write([]byte("\n"))
		}
	}()
	stopped := make(chan error, 1)
	go func() {
		stopped <- cmd.Wait()
	}()

	waitForSocketNoErr(t, state.ActivitySocket(root))
	return stdin, out, func() {
		_ = stdin.Close()
		select {
		case <-stopped:
		case <-time.After(3 * time.Second):
			_ = killProcessGroupHard(cmd)
			select {
			case <-stopped:
			case <-time.After(2 * time.Second):
				_ = cmd.Process.Kill() // last resort: the pid itself
				<-stopped
			}
		}
		<-readerDone
	}
}

// repoRoot is the worktree root that holds src and go.
func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "src", "station.odin")); err != nil {
		t.Fatalf("repo root %s does not look like the coffee-shop worktree: %v", root, err)
	}
	return root
}

// eventually polls until check says done or the deadline passes, then fails. Polling
// rather than sleeping keeps the test robust: the Odin compile can take seconds on a
// cold cache and every other step lands within a couple of seconds.
func eventually(t *testing.T, timeout time.Duration, describe string, check func() (done bool, detail string)) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	detail := ""
	for time.Now().Before(deadline) {
		if done, why := check(); done {
			return
		} else if why != "" {
			detail = why
		}
		time.Sleep(50 * time.Millisecond)
	}
	if _, why := check(); why != "" {
		detail = why
	}
	if detail != "" {
		t.Fatalf("%s: not satisfied within %s: %s", describe, timeout, detail)
	}
	t.Fatalf("%s: not satisfied within %s", describe, timeout)
}

// readPid waits for the agent's pid file and returns the pid it contains.
func (a fakeAgent) readPid(t *testing.T, timeout time.Duration) int {
	t.Helper()
	var pid int
	eventually(t, timeout, "the agent's pid file", func() (bool, string) {
		data, err := os.ReadFile(a.pidFile)
		if err != nil {
			return false, fmt.Sprintf(" (%v)", err)
		}
		value, err := strconv.Atoi(strings.TrimSpace(string(data)))
		if err != nil || value <= 1 {
			return false, fmt.Sprintf(" (pid file holds %q)", data)
		}
		pid = value
		return true, ""
	})
	return pid
}

// pidAlive reports whether the pid still exists, in the shell's `kill -0` sense.
func pidAlive(pid int) bool {
	return syscall.Kill(pid, syscall.Signal(0)) == nil
}

// stationProcesses lists live commands still carrying the Shot's --brew argument.
func stationProcesses(brewArg string) (lines []string, err error) {
	out, err := exec.Command("ps", "ax", "-o", "pid=", "-o", "command=").Output()
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.Contains(line, brewArg) {
			lines = append(lines, line)
		}
	}
	return lines, nil
}

func TestCancelStopsARealOdinStationEvenWhenItsAgentBlockedOnAReply(t *testing.T) {
	if _, err := exec.LookPath("odin"); err != nil {
		t.Skip("odin is not on PATH")
	}
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go is not on PATH")
	}

	root := shortRoot(t) // keeps the socket paths inside the sun_path limit
	dir := t.TempDir()
	agent, err := writeFakeAgent(dir)
	if err != nil {
		t.Fatalf("write agent: %v", err)
	}
	brew := "req-real"
	fakeCLI, err := writeFakeCLI(dir, repoRoot(t), agent.script)
	if err != nil {
		t.Fatalf("write fake CLI: %v", err)
	}

	// The Pi extension stand-in: dispatch refuses to launch without it.
	extensionDir := filepath.Join(root, "host", "extensions")
	if err := os.MkdirAll(extensionDir, 0o700); err != nil {
		t.Fatalf("extension dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(extensionDir, "coffee-shop.ts"), []byte("// stand-in"), 0o600); err != nil {
		t.Fatalf("extension file: %v", err)
	}
	// The Shot's repo path only feeds the seam; the fake prepare creates directories
	// rather than worktrees, so any existing path works.
	repo := dir
	if err := os.MkdirAll(repo, 0o700); err != nil {
		t.Fatalf("repo dir: %v", err)
	}

	in, out, stop := cancelIntegrationHost(t, root, fakeCLI)
	defer stop()

	dispatch := fmt.Sprintf(`{"type":"dispatch","request_id":%q,"repo":%q,"recipe":{"shots":[{"id":"shot-real","prompt":"block forever"}]}}`, brew, repo)
	if _, err := fmt.Fprintf(in, "%s\n", dispatch); err != nil {
		t.Fatalf("send dispatch: %v", err)
	}
	eventually(t, 60*time.Second, "session_started", func() (bool, string) {
		return strings.Contains(out.String(), `"type":"session_started","request_id":"`+brew+`","shot_id":"shot-real"`), ""
	})

	// The blocked agent must be up before the cancel: its pid exists and is alive.
	pid := agent.readPid(t, 30*time.Second)
	if !pidAlive(pid) {
		t.Fatalf("agent pid %d must be alive before the cancel", pid)
	}

	cancel := fmt.Sprintf(`{"type":"cancel","request_id":%q,"shot_id":"shot-real"}`, brew)
	if _, err := fmt.Fprintf(in, "%s\n", cancel); err != nil {
		t.Fatalf("send cancel: %v", err)
	}
	eventually(t, 10*time.Second, "the cancelled event", func() (bool, string) {
		return strings.Contains(out.String(), fmt.Sprintf(`"type":"cancelled","request_id":"%s","shot_id":"shot-real"`, brew)), ""
	})

	// The proof: the blocked agent is stopped even though it ignored its input close
	// and SIGTERM. The Go host cannot see this pid at all — only the pipeline can.
	eventually(t, 10*time.Second, "the agent's pid is gone", func() (bool, string) {
		if !pidAlive(pid) {
			return true, ""
		}
		return false, fmt.Sprintf(" (pid %d still alive)", pid)
	})

	// No orphan Station: nothing carrying this Shot's --brew argument survives.
	leftover := make([]string, 0)
	eventually(t, 10*time.Second, "no Station process for the Brew remains", func() (bool, string) {
		lines, err := stationProcesses("--brew " + brew)
		if err != nil {
			return true, "" // ps is unavailable: the check is best effort
		}
		if len(lines) == 0 {
			return true, ""
		}
		leftover = append(leftover, lines...)
		return false, fmt.Sprintf(" (%d left)\n%s", len(lines), strings.Join(lines, "\n"))
	})
	if len(leftover) > 0 {
		t.Errorf("Station processes still alive after the cancel:\n%s", strings.Join(leftover, "\n"))
	}
}
