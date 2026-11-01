// The Coffee Shop test-suite runner, replacing scripts/test-suite.sh.
//
// It takes a mkdir lock in the repository's git common directory, runs the
// Odin test suite, releases the lock, and forwards HUP, INT and TERM to the
// running odin child. The lock's holder is identified by a pid plus its
// recorded start time, so a reused pid cannot impersonate a live holder; a
// dead holder's lock is reclaimed by rename.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	tickTime         = 100 * time.Millisecond
	graceMissingPids = 20 // ticks with no pid file before the lock counts as dead
)

var (
	lockPath string    // …/git-common-dir/.coffee-shop-test.lock
	ourLock  bool      // the lock was acquired by this process
	buildDir string    // scratch checkout for the odin build, removed on exit
	testCmd  *exec.Cmd // the running odin child, nil before start
)

func readTrim(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// procStart is the start time of a pid, or "" when the process does not
// exist. A pid plus its start time names one process: a reused pid starts at
// a different time. Matches shell `LC_ALL=C ps -o lstart=` output.
func procStart(pid int) string {
	if pid <= 0 {
		return ""
	}
	cmd := exec.Command("ps", "-o", "lstart=", "-p", strconv.Itoa(pid))
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.Join(strings.Fields(string(out)), " ")
}

// reclaim frees a lock judged holder-gone. The rename keeps two reclaimers
// from both deleting it; if what we renamed is not the holder we judged
// dead, a live suite re-locked meanwhile and the lock goes back.
func reclaim(holderPID string) {
	stale := lockPath + ".stale." + strconv.Itoa(os.Getpid())
	if err := os.Rename(lockPath, stale); err != nil {
		return // another reclaimer was faster
	}
	if readTrim(filepath.Join(stale, "pid")) == holderPID {
		os.RemoveAll(stale)
	} else if err := os.Rename(stale, lockPath); err != nil {
		os.RemoveAll(stale)
	}
}

// holderIsDead mirrors the original holder_is_dead. A lock with no pid file
// is a holder between mkdir and its first write; only graceMissingPids ticks
// of that count as dead. A pid that no longer exists, or whose start time
// differs from the recorded one, is dead. A live pid with no recorded start
// (lock from an older script) is trusted.
func holderIsDead(pidRaw string, nopid *int) (dead bool, owner string) {
	if pidRaw == "" {
		*nopid++
		if *nopid >= graceMissingPids {
			return true, "unknown"
		}
		return false, "unknown"
	}
	pid, err := strconv.Atoi(pidRaw)
	if err != nil || pid <= 0 {
		return true, pidRaw // unparseable pid names no process
	}
	nowStart := procStart(pid)
	if nowStart == "" {
		return true, pidRaw
	}
	recorded := readTrim(filepath.Join(lockPath, "start"))
	return recorded != "" && nowStart != recorded, pidRaw
}

func pidOrUnknown(pidRaw string) string {
	if pidRaw == "" {
		return "unknown"
	}
	return pidRaw
}

// acquireLock mirrors the original wait loop: 0.1 s ticks, dead-holder
// reclaim, and a bounded wait for a live holder. It returns nil when this
// process owns the lock.
func acquireLock(path string, waitSecs int) error {
	lockPath = path
	waited, nopid := 0, 0
	for {
		err := os.Mkdir(lockPath, 0o755)
		if err == nil {
			if os.WriteFile(filepath.Join(lockPath, "start"), []byte(procStart(os.Getpid())+"\n"), 0o644) != nil ||
				os.WriteFile(filepath.Join(lockPath, "pid"), []byte(strconv.Itoa(os.Getpid())+"\n"), 0o644) != nil {
				cleanup()
				return fmt.Errorf("failed to record ownership of %s", lockPath)
			}
			ourLock = true
			return nil
		}
		pidRaw := readTrim(filepath.Join(lockPath, "pid"))
		if dead, holder := holderIsDead(pidRaw, &nopid); dead {
			fmt.Fprintf(os.Stderr, "Reclaiming the Coffee Shop test lock from dead PID %s.\n", holder)
			reclaim(holder)
			nopid = 0
			continue
		}
		if waited == 0 {
			fmt.Fprintf(os.Stderr, "Waiting up to %ds for the Coffee Shop test suite held by PID %s (lock: %s).\n", waitSecs, pidOrUnknown(pidRaw), lockPath)
		}
		if waited >= waitSecs*10 {
			fmt.Fprintf(os.Stderr, "Another Coffee Shop test suite is running (PID %s; lock: %s). Timed out after %ds waiting for it. If no suite is running, remove the stale lock directory.\n", pidOrUnknown(pidRaw), lockPath, waitSecs)
			return fmt.Errorf("timed out waiting for the Coffee Shop test lock")
		}
		waited++
		time.Sleep(tickTime)
	}
}

// cleanup mirrors the original shell cleanup(): the build directory goes,
// and the lock is removed only while the pid file still names this process.
func cleanup() {
	if buildDir != "" {
		os.RemoveAll(buildDir)
		buildDir = ""
	}
	if ourLock {
		ourLock = false
		if readTrim(filepath.Join(lockPath, "pid")) == strconv.Itoa(os.Getpid()) {
			os.Remove(filepath.Join(lockPath, "pid"))
			os.Remove(filepath.Join(lockPath, "start"))
			os.Remove(lockPath) // rmdir semantics: leave extra entries alone
		}
	}
}

// exitStatus maps a cmd.Wait error the way `sh wait` does: an exit code
// passes through, a signal-killed child reports 128+signal.
func exitStatus(err error) int {
	if err == nil {
		return 0
	}
	ee, ok := err.(*exec.ExitError)
	if !ok {
		return 1
	}
	if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + saidSignal(ws.Signal())
	}
	return ee.ExitCode()
}

func saidSignal(sig syscall.Signal) int {
	switch sig {
	case syscall.SIGHUP:
		return 129
	case syscall.SIGINT:
		return 130
	case syscall.SIGTERM:
		return 143
	}
	return int(sig)
}

func gitCommonDir(repo string) (string, error) {
	out, err := exec.Command("git", "-C", repo, "rev-parse", "--git-common-dir").Output()
	if err != nil || len(strings.TrimSpace(string(out))) == 0 {
		return "", err
	}
	common := strings.TrimSpace(string(out))
	if !filepath.IsAbs(common) {
		common = filepath.Join(repo, common)
	}
	// Physical path, like the shell `cd … && pwd -P` did.
	return filepath.EvalSymlinks(common)
}

func main() {
	repo := "."
	if len(os.Args) > 1 {
		repo = os.Args[1]
	}
	repo, err := filepath.Abs(repo)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot resolve the repository path %q: %v\n", repo, err)
		os.Exit(1)
	}
	common, err := gitCommonDir(repo)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Cannot locate the Git common directory for the Coffee Shop test lock.")
		os.Exit(1)
	}
	lockPath = filepath.Join(common, ".coffee-shop-test.lock")

	waitSecs := 300
	if v := os.Getenv("COFFEE_SHOP_TEST_LOCK_TIMEOUT"); v != "" {
		whole, err := strconv.Atoi(v)
		if err != nil || whole < 0 {
			fmt.Fprintln(os.Stderr, "COFFEE_SHOP_TEST_LOCK_TIMEOUT must be whole seconds.")
			os.Exit(1)
		}
		waitSecs = whole
	}

	if err := acquireLock(lockPath, waitSecs); err != nil {
		os.Exit(1)
	}

	var status int
	runnerDone := make(chan error, 1)
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGHUP, syscall.SIGINT, syscall.SIGTERM)

	buildDir, err = os.MkdirTemp(os.TempDir(), "coffee-shop-test.")
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot create a build directory: %v\n", err)
		cleanup()
		os.Exit(1)
	}
	testCmd = exec.Command("odin", "test", "src",
		"-out:"+filepath.Join(buildDir, "src.bin"),
		"-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true")
	testCmd.Dir = repo
	testCmd.Env = append(os.Environ(), "TZ=UTC")
	testCmd.Stdout = os.Stdout
	testCmd.Stderr = os.Stderr
	if err := testCmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "cannot start the Odin test runner: %v\n", err)
		cleanup()
		os.Exit(1)
	}
	go func() { runnerDone <- testCmd.Wait() }()

waiting:
	for {
		select {
		case err := <-runnerDone:
			status = exitStatus(err)
			break waiting
		case sig := <-sigs:
			// Forward as TERM; the child's own trap decides its signal file.
			if testCmd.Process != nil {
				testCmd.Process.Signal(syscall.SIGTERM)
			}
			<-runnerDone
			switch sig {
			case syscall.SIGHUP:
				status = 129
			case syscall.SIGINT:
				status = 130
			default:
				status = 143
			}
			break waiting
		}
	}

	cleanup()
	os.Exit(status)
}
