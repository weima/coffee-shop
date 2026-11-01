//go:build unix

package host

// The v0.5 sustained five-Slot overlap gate, made deterministic in Go.
//
// v0.5 could not prove that five Stations genuinely hold five Slots for a sustained
// duration while a sixth Shot waits on a real free. Two attempts failed: in the first
// the "sleeping" agents backgrounded their sleeps and exited immediately, so the six
// Shots never overlapped; in the second, a rerun that queued a `sleep 90` Taste never
// produced the sixth Shot's terminal report within 30 minutes. Both failures share the
// same root: the test let the CHILD decide when its Slot freed. This gate takes that
// decision away from the child: the fake Stations report one turn and then wait, and
// the TEST frees each Slot by deleting its release marker. Sleep timing, backgrounding
// and agent run-time cannot move the evidence.
//
// Shape of the proof:
//  1. one dispatch of six Shots: exactly five session_started, one dispatch_queued —
//     the queued Shot is the host's own black-box admission that five Slots are in use;
//  2. no Station may exit while its marker is held, so the five Slots stay held — the
//     queued Shot cannot start before the first release;
//  3. release the Slots in a known order, 300 ms apart: each free relays exactly one
//     agent_exited, the queued Shot starts only after the first free, and the queue
//     drains with exactly six agent_exited reports in total;
//  4. from the first session_started to the last station_report at least the sum of the
//     per-marker holds elapsed, so the overlap was sustained, not momentary.

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

// fakeOverlapStationEnv turns this test binary into the fake Odin CLI, under its own
// TestMain mode. The 0700 script is the seam; the socket logic lives in Go because
// netcat and python3 cannot be assumed on every platform the suite runs on.
const fakeOverlapStationEnv = "CS_OVERLAP_FAKE_STATION"

// overlapHold is one marker's hold: how long the test keeps a Slot from freeing.
const overlapHold = 300 * time.Millisecond

// overlapHoldTolerance absorbs `at` timestamp quantization (ms) and scheduler jitter in
// the release path. The holds themselves start after the first session_started, so the
// assertion stays well above the measured elapsed time.
const overlapHoldTolerance = 150 * time.Millisecond

// writeOverlapCLI writes the seam the dispatcher drives: a 0700 shell script that
// re-executes this test binary in fake-overlap-station mode.
func writeOverlapCLI(t *testing.T) string {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatalf("resolve test binary: %v", err)
	}
	path := filepath.Join(t.TempDir(), "cs-overlap-fake-odin")
	script := fmt.Sprintf("#!/bin/sh\nexec env %s=1 %q \"$@\"\n", fakeOverlapStationEnv, self)
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatalf("write fake CLI: %v", err)
	}
	return path
}

// fakeOverlapStation is the fake Odin CLI. `prepare` mirrors the seam; `station` sends
// ONE turn_done, creates its release marker, and holds its Slot until the marker is
// deleted — the test, not the child, decides when the Slot frees.
func fakeOverlapStation(argv []string) {
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
		marker := overlapReleaseMarker(hostDir, shot)

		// The PID frees a stray when the test fails before the marker is deleted.
		if err := os.WriteFile(overlapStationPID(hostDir, shot),
			[]byte(fmt.Sprintf("%d\n", os.Getpid())), 0o600); err != nil {
			os.Exit(1)
		}

		conn, err := net.Dial("unix", socket)
		if err != nil {
			os.Exit(1)
		}
		send := func(kind, description string, stamp int64) {
			line, _ := json.Marshal(proto.Message{
				BrewID: brew, ShotID: shot, Kind: kind, Description: description, TimestampNS: stamp,
			})
			if _, err := fmt.Fprintf(conn, "%s\n", line); err != nil {
				os.Exit(1)
			}
		}
		// kind turn_done: src/station.odin relays non-terminal kinds unchanged, so this
		// is the known path the Gate needs — a report that does NOT free the Slot.
		send("turn_done", "slot held", 1)
		if err := os.WriteFile(marker, []byte("held"), 0o600); err != nil {
			os.Exit(1)
		}

		// Hold until the test deletes the marker, then report the agent's exit and go.
		for {
			if _, err := os.Stat(marker); os.IsNotExist(err) {
				send("agent_exited", "done", 2)
				_ = conn.Close()
				os.Exit(0)
			}
			time.Sleep(2 * time.Millisecond)
		}
	}
	// The dispatcher only drives prepare and station.
	os.Exit(2)
}

// overlapReleaseMarker names one Station's release marker in the host directory.
func overlapReleaseMarker(hostDir, shot string) string {
	return filepath.Join(hostDir, "release-"+shot+".marker")
}

func overlapStationPID(hostDir, shot string) string {
	return filepath.Join(hostDir, "overlap-station-"+shot+".pid")
}

// overlapEvents decodes every event line the host wrote.
func overlapEvents(t *testing.T, out *syncBuilder) []proto.Event {
	t.Helper()
	var events []proto.Event
	for _, line := range strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n") {
		var e proto.Event
		if json.Unmarshal([]byte(line), &e) == nil && e.Type != "" {
			events = append(events, e)
		}
	}
	return events
}

func overlapCount(out *syncBuilder, substr string) int {
	return strings.Count(out.String(), substr)
}

// waitForReportCount polls the host's stdout until substr appears at least n times.
func waitForReportCount(t *testing.T, out *syncBuilder, want string, n int) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if overlapCount(out, want) >= n {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("never saw %q %d times in:\n%s", want, n, out.String())
}

// waitForOverlapMarkers waits until every Station has created its release marker, so a
// deletion cannot happen before the Slot is held.
func waitForOverlapMarkers(t *testing.T, hostDir string, shots []string) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		held := true
		for _, shot := range shots {
			if _, err := os.Stat(overlapReleaseMarker(hostDir, shot)); err != nil {
				held = false
				break
			}
		}
		if held {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("release markers never all appeared in %s", hostDir)
}

// freeOverlapSlot deletes one Station's release marker, which is its release signal.
func freeOverlapSlot(shotID string, hostDir string) {
	_ = os.Remove(overlapReleaseMarker(hostDir, shotID))
}

// killOverlapStations ends any fake Station the host started but a failed test left
// running, found through its PID marker the way the durability test does.
func killOverlapStations(t *testing.T, root string) {
	t.Helper()
	entries, err := os.ReadDir(state.HostDir(root))
	if err != nil {
		return
	}
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), "overlap-station-") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(state.HostDir(root), entry.Name()))
		if err != nil {
			continue
		}
		var pid int
		if _, err := fmt.Sscanf(strings.TrimSpace(string(data)), "%d", &pid); err != nil || pid <= 0 {
			continue
		}
		if process, err := os.FindProcess(pid); err == nil {
			if process.Signal(syscall.Signal(0)) == nil {
				_ = process.Kill()
			}
		}
		_ = os.Remove(filepath.Join(state.HostDir(root), entry.Name()))
	}
}

// TestOverlapGateSustainedFiveSlotOverlap is the gate: one dispatch of six Shots holds
// five Slots for a controlled duration; the sixth Shot starts only when the test frees a
// Slot, and every free relays exactly one agent_exited.
func TestOverlapGateSustainedFiveSlotOverlap(t *testing.T) {
	if _, err := exec.LookPath("odin"); err != nil {
		t.Skipf("odin is not on PATH: %v", err)
	}
	if _, err := exec.LookPath("go"); err != nil {
		t.Skipf("go is not on PATH: %v", err)
	}

	cliPath := writeOverlapCLI(t)
	repo := shortRoot(t)
	root := shortRoot(t) // short: the unix socket path must fit the platform limit
	if err := os.MkdirAll(filepath.Join(state.HostDir(root), "extensions"), 0o700); err != nil {
		t.Fatalf("extension dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(state.HostDir(root), "extensions", "coffee-shop.ts"), []byte("// stand-in"), 0o600); err != nil {
		t.Fatalf("write extension: %v", err)
	}

	shots := []string{"shot-1", "shot-2", "shot-3", "shot-4", "shot-5", "shot-6"}

	_, out, writeIn := startHostProcess(t, cliPath, root)
	t.Cleanup(func() { killOverlapStations(t, root) })
	waitForLine(t, out, 30*time.Second, `{"type":"ready"`)

	// One request, six Shots: five start, the sixth queues.
	var recipe []string
	for i, shot := range shots {
		recipe = append(recipe, fmt.Sprintf(`{"id":"%s","prompt":"hold shot %d until the releases begin"}`, shot, i+1))
	}
	request := fmt.Sprintf(`{"type":"dispatch","request_id":"overlap-1","repo":"%s","recipe":{"shots":[%s]}}`+"\n", repo, strings.Join(recipe, ","))
	if _, err := io.WriteString(writeIn, request); err != nil {
		t.Fatalf("dispatch: %v", err)
	}

	// Five Slots in use, asserted from events only: five session_started and one
	// dispatch_queued on a six-Shot request is the host's own black-box admission that
	// the count of in-use Slots is the queue's full boundary, five.
	waitForReportCount(t, out, `"kind":"turn_done","description":"slot held"`, 5)
	waitForLine(t, out, 30*time.Second, `"type":"dispatch_queued","request_id":"overlap-1","shot_id":"shot-6"`)
	hostDir := state.HostDir(root)
	waitForOverlapMarkers(t, hostDir, shots[:5])

	// A Station must not free its Slot while its marker is held: the queued Shot has
	// nowhere to start, and it did not silently double-run.
	started := overlapEvents(t, out)
	sessionStarts := 0
	for _, e := range started {
		switch {
		case e.Type == "session_started":
			if e.ShotID == "shot-6" {
				t.Fatalf("the queued Shot must not start while all five Slots are held:\n%s", out.String())
			}
			sessionStarts++
		case e.Type == "warning" || e.Type == "session_failed":
			t.Fatalf("unexpected %s event (shot %s): %s", e.Type, e.ShotID, e.Reason)
		}
	}
	if sessionStarts != 5 {
		t.Fatalf("want exactly 5 session_started before any free, have %d:\n%s", sessionStarts, out.String())
	}
	if n := overlapCount(out, `"kind":"agent_exited"`); n != 0 {
		t.Fatalf("no Station may exit while its marker is held, saw %d agent_exited:\n%s", n, out.String())
	}
	if overlapCount(out, `"type":"dispatch_queued"`) != 1 {
		t.Fatalf("want exactly one dispatch_queued:\n%s", out.String())
	}

	// Free the Slots one at a time, a hold apart, in a known order. The first free
	// starts the queued Shot; each later free just relays the exiting Station.
	var firstFreeAt time.Time
	for i, shot := range shots[:5] {
		if i == 0 {
			firstFreeAt = time.Now()
		}
		time.Sleep(overlapHold)
		freeOverlapSlot(shot, hostDir)
		waitForReportCount(t, out, `"kind":"agent_exited","description":"done"`, i+1)
		if i == 0 {
			waitForLine(t, out, 30*time.Second, `"type":"session_started","request_id":"overlap-1","shot_id":"shot-6"`)
		}
		if got := overlapCount(out, fmt.Sprintf(`"shot_id":"%s","kind":"agent_exited"`, shot)); got != 1 {
			t.Fatalf("%s must free exactly once, saw %d:\n%s", shot, got, out.String())
		}
	}

	// The queued Shot is now running and holding the sixth Slot on its own marker.
	waitForReportCount(t, out, `"kind":"turn_done","description":"slot held"`, 6)
	queuedAt := time.Time{}
	for _, e := range overlapEvents(t, out) {
		if e.Type == "session_started" && e.ShotID == "shot-6" {
			queuedAt, _ = time.Parse(time.RFC3339, e.At)
		}
	}
	if queuedAt.IsZero() {
		t.Fatalf("no session_started for the queued Shot:\n%s", out.String())
	}
	// The queued Shot can only start after the process it displaces released its Slot,
	// and that process could not exit before the first marker deletion.
	if !queuedAt.After(firstFreeAt.Add(-15 * time.Millisecond)) {
		t.Fatalf("the queued Shot started %s before the first free %s:\n%s", queuedAt, firstFreeAt, out.String())
	}
	waitForOverlapMarkers(t, hostDir, shots[5:])

	// The queued Shot's Slot frees the same way, and the queue is empty afterwards.
	time.Sleep(overlapHold)
	freeOverlapSlot(shots[5], hostDir)
	waitForReportCount(t, out, `"kind":"agent_exited","description":"done"`, 6)

	// Final accounting: six starts, six exits, one queued-and-drained Shot, nothing
	// else in the stream.
	final := overlapEvents(t, out)
	counts := map[string]int{}
	agentExitedByShot := map[string]int{}
	for _, e := range final {
		counts[e.Type]++
		if e.Type == "station_report" && e.Kind == "agent_exited" {
			agentExitedByShot[e.ShotID]++
		}
	}
	if counts["session_started"] != 6 {
		t.Fatalf("want exactly 6 session_started, have %d:\n%s", counts["session_started"], out.String())
	}
	if n := overlapCount(out, `"kind":"agent_exited","description":"done"`); n != 6 {
		t.Fatalf("want exactly 6 agent_exited reports, have %d:\n%s", n, out.String())
	}
	for _, shot := range shots {
		if agentExitedByShot[shot] != 1 {
			t.Fatalf("%s must relay exactly one agent_exited, have %d:\n%s", shot, agentExitedByShot[shot], out.String())
		}
	}
	if counts["dispatch_queued"] != 1 || overlapCount(out, `"type":"dispatch_dequeued"`) != 1 {
		t.Fatalf("want one queued Shot dequeued exactly once:\n%s", out.String())
	}
	if counts["warning"] != 0 || counts["session_failed"] != 0 {
		t.Fatalf("no Shot may fail or warn, counts %v:\n%s", counts, out.String())
	}

	// Sustained, not momentary: from the first session_started to the last
	// station_report at least the six per-marker holds elapsed.
	firstStart, lastReport := "", ""
	for _, e := range final {
		switch {
		case e.Type == "session_started" && firstStart == "":
			firstStart = e.At
		case e.Type == "station_report":
			lastReport = e.At
		}
	}
	start, err := time.Parse(time.RFC3339, firstStart)
	if err != nil {
		t.Fatalf("first session_started timestamp %q: %v", firstStart, err)
	}
	end, err := time.Parse(time.RFC3339, lastReport)
	if err != nil {
		t.Fatalf("last station_report timestamp %q: %v", lastReport, err)
	}
	elapsed := end.Sub(start)
	minimum := 6*overlapHold - overlapHoldTolerance
	if elapsed < minimum {
		t.Fatalf("the overlap was at most %s; want at least %s (six 300ms holds):\n%s", elapsed, minimum, out.String())
	}
}
