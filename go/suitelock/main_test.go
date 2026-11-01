package main

// Port of tests/test-suite-lock.sh: exercises the Coffee Shop test-suite lock
// through a sandboxed git repository with a fake odin on PATH. The runner
// binary is built from the current source at the start of the test — never a
// previously built artifact.

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

const fakeOdinScript = `#!/bin/sh
: "${ODIN_STARTED:?}"
: "${ODIN_RELEASE:?}"
: "${ODIN_STATUS:?}"
: "${ODIN_PID_FILE:?}"
: "${ODIN_FINISHED:?}"
: "${ODIN_SIGNAL:?}"
printf '%s\n' "$$" >"$ODIN_PID_FILE"
trap 'printf finished >"$ODIN_FINISHED"' 0
trap 'printf HUP >"$ODIN_SIGNAL"; exit 129' HUP
trap 'printf INT >"$ODIN_SIGNAL"; exit 130' INT
trap 'printf TERM >"$ODIN_SIGNAL"; exit 143' TERM
printf 'started\n' >>"$ODIN_STARTED"
if [ "$ODIN_STATUS" -eq 0 ]; then
    while [ ! -e "$ODIN_RELEASE" ]; do sleep 0.02; done
fi
exit "$ODIN_STATUS"
`

// Fixture state shared by the scenarios, set up in runFixture (TestMain).
var (
	fixtureDir   string
	runnerBin    string
	repoDir      string
	otherDir     string
	sandboxLock  string // the .coffee-shop-test.lock inside the sandbox repo
	guardGlobal  string // the guard lock, removed at the end
	odinStarted  string
	odinRelease  string
	odinPidFile  string
	odinFinished string
	odinSignal   string
)

func resolvedGitCommon(repo string) (string, error) {
	out, err := exec.Command("git", "-C", repo, "rev-parse", "--git-common-dir").Output()
	if err != nil {
		return "", err
	}
	common := strings.TrimSpace(string(out))
	if common == "" {
		return "", io.ErrUnexpectedEOF
	}
	if !filepath.IsAbs(common) {
		common = filepath.Join(repo, common)
	}
	return filepath.EvalSymlinks(common)
}

// acquireGuardE takes the lock-test guard: a separate mkdir lock outside any
// git repository which never touches the suite lock, so it does not depend
// on the mechanism under test. Same rename reclaim as the shell guard, with
// a missing pid file reclaimed instead of granted its 2 s grace, since the
// test binary alone controls this path.
func acquireGuardE(guard string) error {
	deadline := time.Now().Add(60 * time.Second)
	for {
		err := os.Mkdir(guard, 0o755)
		if err == nil {
			if os.WriteFile(filepath.Join(guard, "pid"), []byte(strconv.Itoa(os.Getpid())+"\n"), 0o644) != nil ||
				os.WriteFile(filepath.Join(guard, "start"), []byte(procStart(os.Getpid())+"\n"), 0o644) != nil {
				return err
			}
			return nil
		}
		pidRaw := readTrim(filepath.Join(guard, "pid"))
		pid, _ := strconv.Atoi(pidRaw)
		start := readTrim(filepath.Join(guard, "start"))
		if pidRaw == "" || procStart(pid) == "" ||
			(start != "" && procStart(pid) != start) {
			os.Rename(guard, guard+".stale."+strconv.Itoa(os.Getpid()))
			continue
		}
		if time.Now().After(deadline) {
			return err
		}
		time.Sleep(time.Second)
	}
}

// suiteRun is one background runner invocation, writing its combined output
// to its own file so failure diagnostics can show it.
type suiteRun struct {
	cmd     *exec.Cmd
	wait    chan error
	outPath string
	started time.Time
}

// startSuite launches the runner binary as a fresh child process. dir is the
// git checkout it runs against; timeoutValue applies
// COFFEE_SHOP_TEST_LOCK_TIMEOUT ("" keeps the default 300); statusValue sets
// ODIN_STATUS for the fake odin.
func startSuite(t *testing.T, dir, timeoutValue, statusValue string) *suiteRun {
	t.Helper()
	env := append(os.Environ(),
		"PATH="+filepath.Join(fixtureDir, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"),
		"ODIN_STARTED="+odinStarted,
		"ODIN_RELEASE="+odinRelease,
		"ODIN_STATUS="+statusValue,
		"ODIN_PID_FILE="+odinPidFile,
		"ODIN_FINISHED="+odinFinished,
		"ODIN_SIGNAL="+odinSignal,
	)
	if timeoutValue != "" {
		env = append(env, "COFFEE_SHOP_TEST_LOCK_TIMEOUT="+timeoutValue)
	}
	outPath := filepath.Join(fixtureDir, "suite-out-"+time.Now().Format("15-04-05.000000")+".txt")
	out, err := os.Create(outPath)
	if err != nil {
		t.Fatalf("create %s: %v", outPath, err)
	}
	cmd := exec.Command(runnerBin, dir)
	cmd.Env = env
	cmd.Stdout = out
	cmd.Stderr = out
	if err := cmd.Start(); err != nil {
		out.Close()
		t.Fatalf("start the runner: %v", err)
	}
	r := &suiteRun{cmd: cmd, wait: make(chan error, 1), outPath: outPath, started: time.Now()}
	go func() {
		err := cmd.Wait()
		out.Close()
		r.wait <- err
	}()
	return r
}

func (r *suiteRun) output() string {
	data, err := os.ReadFile(r.outPath)
	if err != nil {
		return ""
	}
	return string(data)
}

func (r *suiteRun) dump(t *testing.T) {
	t.Helper()
	t.Logf("runner output (%s):\n%s", r.outPath, r.output())
}

func (r *suiteRun) finished() (int, bool) {
	select {
	case err := <-r.wait:
		return exitStatus(err), true
	default:
		return 0, false
	}
}

func mustFail(t *testing.T, r *suiteRun, wantSubstrings ...string) int {
	t.Helper()
	deadline := time.After(30 * time.Second)
	for {
		select {
		case err := <-r.wait:
			if err == nil {
				r.dump(t)
				t.Fatalf("suite in %s unexpectedly succeeded", r.cmd.Dir)
			}
			got := strings.ToLower(r.output())
			for _, want := range wantSubstrings {
				if !strings.Contains(got, strings.ToLower(want)) {
					r.dump(t)
					t.Fatalf("suite did not report %q", want)
				}
			}
			return exitStatus(err)
		case <-deadline:
			r.dump(t)
			t.Fatal("suite did not end")
			return 0
		}
	}
}

func mustSucceed(t *testing.T, r *suiteRun, timeout time.Duration) {
	t.Helper()
	select {
	case err := <-r.wait:
		if err != nil {
			r.dump(t)
			t.Fatalf("suite in %s failed: %v", r.cmd.Dir, err)
		}
	case <-time.After(timeout):
		r.dump(t)
		t.Fatal("suite did not finish in time")
	}
}

func countStarted(t *testing.T) int {
	t.Helper()
	data, err := os.ReadFile(odinStarted)
	if err != nil {
		t.Fatalf("read %s: %v", odinStarted, err)
	}
	n := 0
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) != "" {
			n++
		}
	}
	return n
}

func pollFile(path string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for {
		if _, err := os.Stat(path); err == nil {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func expectStarted(t *testing.T, timeout time.Duration) string {
	t.Helper()
	if !pollFile(odinStarted, timeout) {
		t.Fatalf("test suite did not start its odin runner within %v", timeout)
	}
	pid, err := strconv.Atoi(readTrim(filepath.Join(sandboxLock, "pid")))
	if err != nil {
		t.Fatalf("no holder pid recorded under %s: %v", sandboxLock, err)
	}
	return strconv.Itoa(pid)
}

func rmFile(t *testing.T, path string) {
	t.Helper()
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
}

func touchEmpty(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
}

func startRun(t *testing.T, dir, timeoutValue, statusValue string) *suiteRun {
	rmFile(t, odinStarted)
	rmFile(t, odinRelease)
	rmFile(t, odinPidFile)
	rmFile(t, odinFinished)
	rmFile(t, odinSignal)
	return startSuite(t, dir, timeoutValue, statusValue)
}

func TestMain(m *testing.M) {
	code := runFixture(m)
	if guardGlobal != "" {
		os.RemoveAll(guardGlobal)
	}
	os.Exit(code)
}

// runFixture builds the runner from the current source, prepares the sandbox
// git repository with a second worktree, writes the fake odin and the ODIN_*
// file paths, and takes the guard — the shell original's preamble, line for
// line.
func runFixture(m *testing.M) int {
	tmp, err := os.MkdirTemp("", "coffee-suite-lock-test.")
	if err != nil {
		return 9
	}
	fixtureDir = tmp
	bin := filepath.Join(tmp, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		return 9
	}
	runnerBin = filepath.Join(bin, "suitelock")
	if out, err := exec.Command("go", "build", "-o", runnerBin, ".").CombinedOutput(); err != nil {
		os.Stderr.WriteString("go build: " + err.Error() + "\n" + string(out) + "\n")
		return 9
	}
	if err := os.WriteFile(filepath.Join(bin, "odin"), []byte(fakeOdinScript), 0o755); err != nil {
		return 9
	}

	odinStarted = filepath.Join(tmp, "odin.started")
	odinRelease = filepath.Join(tmp, "odin.release")
	odinPidFile = filepath.Join(tmp, "odin.pid")
	odinFinished = filepath.Join(tmp, "odin.finished")
	odinSignal = filepath.Join(tmp, "odin.signal")

	repoDir = filepath.Join(tmp, "repo")
	if err := exec.Command("git", "init", "-q", repoDir).Run(); err != nil {
		return 9
	}
	gitQuiet("-C", repoDir, "config", "user.name", "test")
	gitQuiet("-C", repoDir, "config", "user.email", "test@example.com")
	if out, err := exec.Command("git", "-C", repoDir, "commit", "-q", "--allow-empty", "-m", "test").CombinedOutput(); err != nil {
		os.Stderr.WriteString("git commit: " + err.Error() + "\n" + string(out) + "\n")
		return 9
	}
	otherDir = filepath.Join(tmp, "other")
	if out, err := exec.Command("git", "-C", repoDir, "worktree", "add", "-q", otherDir, "-b", "other").CombinedOutput(); err != nil {
		os.Stderr.WriteString("git worktree add: " + err.Error() + "\n" + string(out) + "\n")
		return 9
	}

	common, err := resolvedGitCommon(repoDir)
	if err != nil {
		return 9
	}
	sandboxLock = filepath.Join(common, ".coffee-shop-test.lock")

	guard := filepath.Join(tmp, "guard")
	guardGlobal = guard
	if err := acquireGuardE(guard); err != nil {
		os.Stderr.WriteString("guard: " + err.Error() + "\n")
		return 9
	}

	return m.Run()
}

func gitQuiet(args ...string) {
	_ = exec.Command("git", args...).Run()
}

// TestLockSemantics runs every scenario of the shell original, in order:
// sandbox proof, exclusion, bounded wait, timeout reporting, waiter, failure
// exit-code propagation, HUP/INT/TERM forwarding, signal- and
// SIGKILL-holder release, pid reuse, and live-holder refusal.
func TestLockSemantics(t *testing.T) {
	// Sandbox proof: the lock under test must not be the real suite's lock.
	repoRoot, err := filepath.EvalSymlinks(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	if realCommon, err := resolvedGitCommon(repoRoot); err == nil {
		if realCommon == filepath.Dir(sandboxLock) {
			t.Fatal("lock test is not sandboxed")
		}
	}

	// Two concurrent suites: the second waits for the lock, then times out
	// with the recorded holder named; the first keeps it and ran one odin.
	first := startSuite(t, repoDir, "", "0")
	holderPID := expectStarted(t, 2*time.Second)
	second := startSuite(t, otherDir, "1", "0")
	mustFail(t, second,
		"another coffee shop test suite is running",
		"pid "+holderPID,
		sandboxLock,
		"timed out")
	if _, err := os.Stat(sandboxLock); err != nil {
		t.Fatal("first suite lost its lock")
	}
	if n := countStarted(t); n != 1 {
		t.Fatalf("more than one underlying test runner started (%d)", n)
	}

	// A waiting second suite must run once the first finishes.
	waiter := startSuite(t, otherDir, "30", "0")
	time.Sleep(500 * time.Millisecond)
	if _, fin := waiter.finished(); fin {
		waiter.dump(t)
		t.Fatal("waiting suite did not wait")
	}
	if n := countStarted(t); n != 1 {
		t.Fatal("waiter ran while the lock was held")
	}
	touchEmpty(t, odinRelease)
	mustSucceed(t, first, 40*time.Second)
	mustSucceed(t, waiter, 60*time.Second)
	if n := countStarted(t); n != 2 {
		t.Fatal("waiting suite never ran its tests")
	}
	if _, err := os.Stat(sandboxLock); !os.IsNotExist(err) {
		t.Fatal("successful suite left its lock")
	}

	// A failing suite propagates the fake odin's exit code and frees the lock.
	failing := startRun(t, repoDir, "", "23")
	if code := mustFail(t, failing); code != 23 {
		t.Fatalf("failing suite exited %d, want 23", code)
	}
	if _, err := os.Stat(sandboxLock); !os.IsNotExist(err) {
		t.Fatal("failed suite left its lock")
	}

	// HUP, INT and TERM forwarded to the running odin child; the runner
	// exits with the shell-mapped 128+signal status and releases the lock.
	for _, sigCase := range []struct {
		name string
		sig  syscall.Signal
		code int
	}{
		{"SIGHUP", syscall.SIGHUP, 129},
		{"SIGINT", syscall.SIGINT, 130},
		{"SIGTERM", syscall.SIGTERM, 143},
	} {
		victim := startRun(t, repoDir, "", "0")
		_ = expectStarted(t, 2*time.Second)
		wrapperPID := readTrim(filepath.Join(sandboxLock, "pid"))
		wrapper, _ := strconv.Atoi(wrapperPID)
		if p, err := os.FindProcess(wrapper); err == nil {
			_ = p.Signal(sigCase.sig)
		}
		pollFile(odinSignal, 3*time.Second)
		touchEmpty(t, odinRelease)
		if code := mustFail(t, victim); code != sigCase.code {
			t.Fatalf("%s-interrupted suite exited %d, want %d", sigCase.name, code, sigCase.code)
		}
		if got := readTrim(odinSignal); got != "TERM" {
			t.Fatalf("%s did not stop the underlying test runner (signal file: %q)", sigCase.name, got)
		}
		if _, err := os.Stat(odinFinished); err != nil {
			t.Fatalf("%s left the test runner unfinished", sigCase.name)
		}
		// A stopped runner is a runner whose start time is gone.
		runner := readTrim(odinPidFile)
		if pid, err := strconv.Atoi(runner); err == nil && procStart(pid) != "" {
			t.Fatalf("%s left test runner PID %d running", sigCase.name, pid)
		}
		if _, err := os.Stat(sandboxLock); !os.IsNotExist(err) {
			t.Fatalf("%s-interrupted suite left its lock", sigCase.name)
		}
	}

	// A holder killed by a signal releases the lock for a new acquirer.
	dying := startRun(t, repoDir, "", "0")
	expectStarted(t, 2*time.Second)
	if p, err := os.FindProcess(dying.cmd.Process.Pid); err == nil {
		_ = p.Signal(syscall.SIGTERM)
	}
	select {
	case err := <-dying.wait:
		if err == nil {
			t.Fatal("TERM-ed holder unexpectedly succeeded")
		}
	case <-time.After(15 * time.Second):
		dying.dump(t)
		t.Fatal("TERM-ed holder kept running")
	}
	if _, err := os.Stat(sandboxLock); !os.IsNotExist(err) {
		t.Fatal("dead holder left its lock")
	}
	rmFile(t, odinStarted)
	touchEmpty(t, odinRelease)
	newOwner := startSuite(t, otherDir, "5", "0")
	mustSucceed(t, newOwner, 60*time.Second)
	if _, err := os.Stat(odinStarted); err != nil {
		t.Fatal("suite did not run after the holder died")
	}

	// A killed holder (SIGKILL: no trap runs) leaves its lock; the next run
	// reclaims it fast and reports the dead pid.
	killed := startRun(t, repoDir, "", "0")
	expectStarted(t, 2*time.Second)
	killedPID := killed.cmd.Process.Pid
	_ = killed.cmd.Process.Kill() // SIGKILL: no trap runs
	<-killed.wait                 // reap the wrapper
	if child := readTrim(odinPidFile); child != "" {
		// The fake odin trap does not run under SIGKILL: kill it directly.
		if cp, err := strconv.Atoi(child); err == nil {
			if p, err := os.FindProcess(cp); err == nil {
				_ = p.Kill()
			}
		}
	}
	rmFile(t, odinStarted)
	touchEmpty(t, odinRelease)
	reclaim := startSuite(t, otherDir, "60", "0")
	mustSucceed(t, reclaim, 40*time.Second)
	if reclaim.started.Sub(killed.started) > 10*time.Second {
		t.Fatalf("reclaiming a dead holder waited too long (%v)", reclaim.started.Sub(killed.started))
	}
	if !strings.Contains(reclaim.output(), "dead PID "+strconv.Itoa(killedPID)) {
		reclaim.dump(t)
		t.Fatal("reclaim not reported")
	}
	if _, err := os.Stat(odinStarted); err != nil {
		t.Fatal("suite did not run after reclaim")
	}
	if _, err := os.Stat(sandboxLock); !os.IsNotExist(err) {
		t.Fatal("reclaiming suite left its lock")
	}

	// A reused pid: a live pid whose start time differs from the recorded
	// one is not the holder.
	sleeper := exec.Command("sleep", "30")
	if err := sleeper.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sleeper.Process.Kill(); _ = sleeper.Wait() }()
	if err := os.Mkdir(sandboxLock, 0o755); err != nil {
		t.Fatal(err)
	}
	if os.WriteFile(filepath.Join(sandboxLock, "pid"), []byte(strconv.Itoa(sleeper.Process.Pid)+"\n"), 0o644) != nil ||
		os.WriteFile(filepath.Join(sandboxLock, "start"), []byte("Thu Jan  1 00:00:00 1970\n"), 0o644) != nil {
		t.Fatal("cannot seed a reused-pid lock")
	}
	rmFile(t, odinStarted)
	past := startSuite(t, otherDir, "60", "0")
	mustSucceed(t, past, 40*time.Second)
	if _, err := os.Stat(odinStarted); err != nil {
		t.Fatal("suite did not run past a reused pid")
	}
	os.RemoveAll(sandboxLock)

	// A live holder with a matching start time is refused and reported,
	// never stolen.
	alive := exec.Command("sleep", "30")
	if err := alive.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = alive.Process.Kill(); _ = alive.Wait() }()
	if err := os.Mkdir(sandboxLock, 0o755); err != nil {
		t.Fatal(err)
	}
	if os.WriteFile(filepath.Join(sandboxLock, "start"), []byte(procStart(alive.Process.Pid)+"\n"), 0o644) != nil ||
		os.WriteFile(filepath.Join(sandboxLock, "pid"), []byte(strconv.Itoa(alive.Process.Pid)+"\n"), 0o644) != nil {
		t.Fatal("cannot seed a live-holder lock")
	}
	rmFile(t, odinStarted)
	liveRun := startSuite(t, otherDir, "1", "0")
	mustFail(t, liveRun, "timed out", strconv.Itoa(alive.Process.Pid))
	if _, err := os.Stat(sandboxLock); err != nil {
		t.Fatal("live holder's lock was disturbed")
	}
	if _, err := os.Stat(odinStarted); err == nil {
		t.Fatal("a suite ran while a live holder held the lock")
	}
	os.RemoveAll(sandboxLock)
}
