//go:build unix

package host

// The durability gate, end to end: kill the host mid-run, then prove the state it left
// behind carries the terminal report it never announced, without reading a log.
//
// The gate is "kill the host mid-run; every terminal report is still relayed or
// recoverable after restart, without reading a log". This test drives real processes:
// the host is `go run ./cmd/csd`, and the Station is a fake Odin CLI (a 0700 shell script
// that re-executes this test binary in fake-station mode, the same seam Go drives).
//
// Two lines over the socket were considered and rejected. The spool copy is written by
// the Station before it sends, and the socket line binds its durable copy through the
// `spool` field, which the host removes only after relaying; a host that relayed pulled
// therefore always removes that copy, and a station that sends both reports before the
// kill is a race against the relay, not a gate. So the fake Station does what a real one
// does before every send — write the durable copy — and it sends only the first report.
// The second exists on disk alone, which is exactly the state a host killed mid-run
// leaves behind. An unbound socket line that would make both replay was rejected too:
// it is not a shape a real Station sends, and a test fed by an invalid report proves
// less, not more.
//
// Shape of the proof:
//  1. host 1 relays pulled (its stdout) and removes that report's spool copy;
//  2. the host is SIGKILLed with the spool still holding agent_exited's durable copy;
//  3. host 2, started on the same state root, relays agent_exited from the spool and
//     leaves the spool empty.
//
// One report delivered, the other recovered: every terminal report is accounted for.

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/weima/coffee-shop/go/internal/proto"
	"github.com/weima/coffee-shop/go/internal/state"
)

// fakeDurabilityStationEnv turns this test binary into the fake Odin CLI. Only the
// re-executed children set it, through the seam script.
const fakeDurabilityStationEnv = "CS_DURABILITY_FAKE_STATION"

// writeFakeCLI writes the seam the dispatcher drives: a 0700 shell script that
// re-executes this test binary in fake-station mode. The socket logic lives in Go
// because netcat and python3 cannot be assumed on every platform the suite runs on.
func writeDurabilityFakeCLI(t *testing.T) string {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatalf("resolve test binary: %v", err)
	}
	path := filepath.Join(t.TempDir(), "cs-fake-odin")
	script := fmt.Sprintf("#!/bin/sh\nexec env %s=1 %q \"$@\"\n", fakeDurabilityStationEnv, self)
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatalf("write fake CLI: %v", err)
	}
	return path
}

// fakeDurabilityStation is the test binary's fake Odin CLI. `prepare` mirrors the seam;
// `station` reports the first shot event over the socket and leaves the second only as
// a durable spool copy, then never exits.
func fakeDurabilityStation(argv []string) {
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
		brew := flagValue(argv, "--brew")
		shot := flagValue(argv, "--station")
		hostDir := filepath.Dir(socket)
		spoolDir := filepath.Join(hostDir, "spool")
		if info, err := os.Stat(spoolDir); err != nil || !info.IsDir() {
			fmt.Fprintf(os.Stderr, "fake station: no spool directory at %s\n", spoolDir)
			os.Exit(1)
		}

		report := func(name, kind, description string) proto.Message {
			message := proto.Message{
				BrewID:      brew,
				ShotID:      shot,
				Kind:        kind,
				Description: description,
				TimestampNS: time.Now().UnixNano(),
				Spool:       name,
			}
			data, err := json.Marshal(message)
			if err != nil {
				os.Exit(1)
			}
			if err := os.WriteFile(filepath.Join(spoolDir, name), data, 0o600); err != nil {
				os.Exit(1)
			}
			return message
		}

		// The first report: durably written, bound, then announced like any real report.
		first := report("00000000000000000001-pulled.json", "pulled", "pulled before the crash")
		line, _ := json.Marshal(first)
		conn, err := net.Dial("unix", socket)
		if err != nil {
			os.Exit(1)
		}
		if _, err := fmt.Fprintf(conn, "%s\n", line); err != nil {
			os.Exit(1)
		}
		_ = conn.Close()

		// The second report: durably written, never announced. A host killed mid-run is
		// what leaves a report exactly this far out of the relay.
		report("00000000000000000002-agent-exit.json", "agent_exited", "agent exited before the host could announce it")

		// Tell the test the durable copy is on disk. The PID lets the test kill this
		// never-exiting Station when it is done with it.
		marker := filepath.Join(hostDir, "cs-durability-station-ready")
		if err := os.WriteFile(marker, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0o600); err != nil {
			os.Exit(1)
		}
		time.Sleep(900 * time.Second)
		os.Exit(0)
	}
	// The dispatcher only drives prepare and station.
	os.Exit(2)
}

// TestDurabilityGateSpoolCarriesReportsAcrossAHostCrash is the gate: a host is killed
// mid-run and the next host recovers the terminal report it never announced.
func TestDurabilityGateSpoolCarriesReportsAcrossAHostCrash(t *testing.T) {
	if _, err := exec.LookPath("odin"); err != nil {
		t.Skipf("odin is not on PATH: %v", err)
	}
	if _, err := exec.LookPath("go"); err != nil {
		t.Skipf("go is not on PATH: %v", err)
	}

	// The replay reads the spool oldest first, so entry names sort by timestamp, as the
	// real Station names them.
	cliPath := writeDurabilityFakeCLI(t)
	repo := shortRoot(t)

	// The state root is the killed host's state and the restarted host's state: the gate
	// is about what the first run leaves behind, so both run on the root. The host dir
	// pre-holds the Pi extension, whose absence dispatch refuses to launch without.
	root := shortRoot(t)
	if err := os.MkdirAll(filepath.Join(state.HostDir(root), "extensions"), 0o700); err != nil {
		t.Fatalf("extension dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(state.HostDir(root), "extensions", "coffee-shop.ts"), []byte("// stand-in"), 0o600); err != nil {
		t.Fatalf("write extension: %v", err)
	}

	// Host 1: the run that dies.
	cmd1, out1, writeIn1 := startHostProcess(t, cliPath, root)
	waitForLine(t, out1, 30*time.Second, `{"type":"ready"`)
	if _, err := fmt.Fprintf(writeIn1, `{"type":"dispatch","request_id":"req-1","repo":"%s","recipe":{"shots":[{"id":"shot-a","prompt":"prove the durability gate"}]}}`+"\n", repo); err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	waitForLine(t, out1, 30*time.Second, `"type":"station_report","request_id":"req-1","shot_id":"shot-a","kind":"pulled"`)

	// The relay removed pulled's copy once it was announced; wait for that, so the killed
	// host's spool holds exactly what it never announced.
	firstEntry := "00000000000000000001-pulled.json"
	secondEntry := "00000000000000000002-agent-exit.json"
	waitForSpool(t, root, 10*time.Second, func(entries []string) bool {
		return !contains(entries, firstEntry) && contains(entries, secondEntry)
	})

	// Crash the host mid-run, with the Station still alive. SIGKILL, not shutdown: the
	// point is a host that never got to announce the second report or clean up.
	if err := cmd1.cmd.Process.Kill(); err != nil {
		t.Fatalf("kill host: %v", err)
	}
	<-cmd1.WaitDone()

	// The condition being tested: the state the killed host left behind holds the
	// terminal report it never announced.
	entries, err := os.ReadDir(state.SpoolDir(root))
	if err != nil {
		t.Fatalf("read spool after kill: %v", err)
	}
	names := entryNames(entries)
	if !contains(names, secondEntry) {
		t.Fatalf("the killed host's spool must hold the unannounced durable copy %s, has %v", secondEntry, names)
	}
	if contains(names, firstEntry) {
		t.Fatalf("the announced report's copy must be gone, spool still has %v", names)
	}

	// Host 2: the restart, fed a shutdown immediately, so nothing but the replay runs.
	cmd2, out2, writeIn2 := startHostProcess(t, cliPath, root)
	waitForLine(t, out2, 30*time.Second, `{"type":"ready"`)
	if _, err := fmt.Fprintf(writeIn2, `{"type":"shutdown","request_id":"shutdown-1"}`+"\n"); err != nil {
		t.Fatalf("shutdown: %v", err)
	}
	waitForLine(t, out2, 30*time.Second, `"type":"station_report","request_id":"req-1","shot_id":"shot-a","kind":"agent_exited"`)
	waitForLine(t, out2, 30*time.Second, `"type":"stopped"`)
	<-cmd2.WaitDone()

	// The recovered copy left the spool on relay, and the already-announced report is
	// not announced twice.
	if entries, err := os.ReadDir(state.SpoolDir(root)); err != nil {
		t.Fatalf("read spool after restart: %v", err)
	} else if left := entryNames(entries); len(left) != 0 {
		t.Fatalf("a relayed spool entry must be removed, %d left: %v", len(left), left)
	}
	if got := out2.String(); strings.Contains(got, `"kind":"pulled"`) {
		t.Fatalf("the report host 1 announced must not be replayed:\n%s", got)
	}
}

// hostProcess is one live host: a real `go run ./cmd/csd`, never a built binary. Its
// process group is its own so the test's kill reaches `go run` and the host together.
func startHostProcess(t *testing.T, cliPath, stateRoot string) (*hostProcess, *syncBuilder, io.WriteCloser) {
	t.Helper()
	moduleRoot, err := goModuleRoot()
	if err != nil {
		t.Fatalf("find go module: %v", err)
	}
	// The state root must be short: the unix socket path has to fit the platform limit.
	cmd := exec.Command("go", "run", "./cmd/csd")
	cmd.Dir = moduleRoot
	cmd.Env = hostEnvironment(cliPath, stateRoot)
	setProcessGroup(cmd)

	in, writeIn, err := os.Pipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	cmd.Stdin = in
	stdoutRead, stdoutWrite, err := os.Pipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	cmd.Stdout = stdoutWrite
	cmd.Stderr = stdoutWrite
	out := &syncBuilder{}
	go func() {
		_, _ = io.Copy(out, stdoutRead)
		_ = stdoutRead.Close()
	}()

	if err := cmd.Start(); err != nil {
		t.Fatalf("start host: %v", err)
	}
	waited := make(chan struct{})
	go func() {
		defer close(waited)
		_ = cmd.Wait()
		_ = writeIn.Close()
		_ = stdoutWrite.Close()
	}()

	h := &hostProcess{cmd: cmd, waited: waited}
	// Whatever happens in the test — failure, kill, success — nothing outlives it except
	// what the spool proves. The never-exiting fake Station is found through its marker.
	t.Cleanup(func() {
		select {
		case <-waited:
		default:
			_ = killProcessGroupHard(cmd)
			<-waited
		}
		killStation(t, stateRoot)
	})
	return h, out, writeIn
}

// hostProcess packages what a test does to a running host.
type hostProcess struct {
	cmd    *exec.Cmd
	waited chan struct{}
}

// WaitDone closes when the host's process is gone.
func (h *hostProcess) WaitDone() <-chan struct{} { return h.waited }

// hostEnvironment hands the child a clean CS_ surface: a stray CS_STATE_DIR or CS_CLI in
// the shell running the suite would point the host at the wrong state or seam.
func hostEnvironment(cliPath, stateRoot string) []string {
	env := make([]string, 0, len(os.Environ())+3)
	for _, entry := range os.Environ() {
		if strings.HasPrefix(entry, "CS_") {
			continue
		}
		env = append(env, entry)
	}
	return append(env,
		"CS_STATE_DIR="+stateRoot,
		"CS_CLI="+cliPath,
		// csd's dispatcher passes CS_AGENT through to the Station command; a fake Station
		// ignores it, but the argv must stay valid.
		"CS_AGENT=dummy",
	)
}

// goModuleRoot walks up from the running test to the directory with go.mod, so
// `go run ./cmd/csd` is launched from where it resolves.
func goModuleRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, statErr := os.Stat(filepath.Join(dir, "go.mod")); statErr == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("no go.mod above %s", dir)
		}
		dir = parent
	}
}

// killStation ends the never-exiting fake Station a host started (the host was killed,
// so no cancel path can reach it). Its PID is written with the ready marker.
func killStation(t *testing.T, stateRoot string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(state.HostDir(stateRoot), "cs-durability-station-ready"))
	if err != nil {
		return // no Station was started
	}
	var pid int
	if _, err := fmt.Sscanf(strings.TrimSpace(string(data)), "%d", &pid); err != nil || pid <= 0 {
		return
	}
	_ = syscall.Kill(pid, syscall.SIGKILL)
	_ = os.Remove(filepath.Join(state.HostDir(stateRoot), "cs-durability-station-ready"))
}

// waitForLine polls the host's stdout for one sentence rather than sleeping.
func waitForLine(t *testing.T, out *syncBuilder, timeout time.Duration, want string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if strings.Contains(out.String(), want) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("never saw %q in:\n%s", want, out.String())
}

// waitForSpool polls the killed host's spool until the entries match the condition.
func waitForSpool(t *testing.T, root string, timeout time.Duration, ok func([]string) bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		entries, err := os.ReadDir(state.SpoolDir(root))
		if err != nil {
			t.Fatalf("read spool: %v", err)
		}
		if ok(entryNames(entries)) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	entries, err := os.ReadDir(state.SpoolDir(root))
	if err != nil {
		t.Fatalf("read spool: %v", err)
	}
	t.Fatalf("spool never matched: %v", entryNames(entries))
}

func entryNames(entries []os.DirEntry) []string {
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	return names
}

func contains(names []string, want string) bool {
	for _, name := range names {
		if name == want {
			return true
		}
	}
	return false
}
