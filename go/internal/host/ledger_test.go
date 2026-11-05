package host

// The progress-supervision contract: a Station that asks a question alerts once, a
// Station that goes quiet warns once after ten minutes, and neither survives release.

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/weima/coffee-shop/go/internal/proto"
	"github.com/weima/coffee-shop/go/internal/state"
)

// fakeClock is a ledger clock the test moves by hand, so no assertion waits on real time.
type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time          { return c.t }
func (c *fakeClock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newTestLedger() (*progressLedger, *fakeClock) {
	clock := &fakeClock{t: time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)}
	return newProgressLedger(clock.now), clock
}

// emitted collects the events a check produced.
func check(l *progressLedger) []proto.Event {
	var events []proto.Event
	l.checkAndEmit(func(e proto.Event) error {
		events = append(events, e)
		return nil
	})
	return events
}

func TestControlledRunDeadlinesPersistFailuresAndCompletionDoesNotExpire(t *testing.T) {
	root := t.TempDir()
	out := &syncBuilder{}
	w := &writer{out: out, now: fixedClock(), root: root}
	d := newDispatcher(root, nil, "", "", "", w)
	now := time.Now()

	d.queue = append(d.queue, queuedShot{requestID: "req-1", shot: ShotRequest{ID: "queued"}, queuedAt: now.Add(-QueuedDeadline)})
	if !d.slots.acquire("req-1", "starting") || !d.slots.acquire("req-1", "active") {
		t.Fatal("reserve test slots")
	}
	d.starting[slotKey("req-1", "starting")] = now.Add(-StartingDeadline)
	cmd := exec.Command("sleep", "10")
	setProcessGroup(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	d.running[slotKey("req-1", "active")] = &stationRun{
		requestID: "req-1", shotID: "active", cmd: cmd, activeAt: now.Add(-ActiveDeadline),
	}
	if !d.slots.acquire("req-1", "completed") {
		t.Fatal("reserve completion slot")
	}
	d.running[slotKey("req-1", "completed")] = &stationRun{requestID: "req-1", shotID: "completed", activeAt: now}
	d.running[slotKey("req-1", "completed")].terminal = true

	d.expireDeadlines(now)
	for shot, want := range map[string]string{
		"queued":   "queued phase expired after 10 minutes",
		"starting": "starting phase expired after 2 minutes",
		"active":   "active phase expired after 35 minutes",
	} {
		if !strings.Contains(out.String(), `"type":"session_failed","request_id":"req-1","shot_id":"`+shot+`","reason":"`+want+`"`) {
			t.Fatalf("%s must produce explicit failure, got:\n%s", shot, out.String())
		}
	}
	if strings.Contains(out.String(), `"shot_id":"completed","reason":"active phase expired`) {
		t.Fatalf("a normally completed run must not expire:\n%s", out.String())
	}
	history, err := os.ReadFile(state.HistoryPath(root, "req-1"))
	if err != nil || strings.Count(string(history), `"type":"session_failed"`) != 3 {
		t.Fatalf("all expiries must be durable failures: %v\n%s", err, history)
	}
}

func eventsOfType(events []proto.Event, kind string) []proto.Event {
	filtered := make([]proto.Event, 0, len(events))
	for _, event := range events {
		if event.Type == kind {
			filtered = append(filtered, event)
		}
	}
	return filtered
}

func TestLedgerNeedsInputAlertsOncePerQuestion(t *testing.T) {
	l, _ := newTestLedger()
	l.addStation("req-1", "shot-a", "req-1/shot-a")
	l.updatePhase("req-1", "shot-a", phaseRunning)

	l.report("req-1", "shot-a", "needs_input")
	first := check(l)
	if len(first) != 1 || first[0].Type != "needs_input_alert" {
		t.Fatalf("want one needs_input_alert, got %v", first)
	}
	if first[0].RequestID != "req-1" || first[0].ShotID != "shot-a" || first[0].PaneID != "req-1/shot-a" {
		t.Fatalf("alert must name the Station and its session: %+v", first[0])
	}

	// Still unanswered: the alert must not repeat on every poll.
	if repeat := check(l); len(repeat) != 0 {
		t.Fatalf("a pending question must alert once, got %v", repeat)
	}

	// Answered, then asked again: the new question is its own alert.
	l.report("req-1", "shot-a", "turn_done")
	if len(check(l)) != 0 {
		t.Fatal("a answered Station must not alert")
	}
	l.report("req-1", "shot-a", "needs_input")
	if again := check(l); len(again) != 1 || again[0].Type != "needs_input_alert" {
		t.Fatalf("a second question must alert again, got %v", again)
	}
}

func TestLedgerStaleWarnsOnceAndProgressResetsIt(t *testing.T) {
	l, clock := newTestLedger()
	l.addStation("req-1", "shot-a", "req-1/shot-a")
	l.updatePhase("req-1", "shot-a", phaseRunning)

	clock.advance(StaleThreshold - time.Second)
	if early := eventsOfType(check(l), "stale_warning"); len(early) != 0 {
		t.Fatalf("a Station under the threshold must not warn, got %v", early)
	}

	clock.advance(time.Second)
	warned := eventsOfType(check(l), "stale_warning")
	if len(warned) != 1 {
		t.Fatalf("want one stale_warning at the threshold, got %v", warned)
	}
	if warned[0].Reason != "10 minutes without progress" {
		t.Fatalf("warning must say how long: %q", warned[0].Reason)
	}
	if repeat := eventsOfType(check(l), "stale_warning"); len(repeat) != 0 {
		t.Fatalf("a stale Station warns once, got %v", repeat)
	}

	// Any report restarts the quiet period, so the next warning comes a full threshold later.
	l.report("req-1", "shot-a", "turn_done")
	clock.advance(StaleThreshold - time.Second)
	if early := eventsOfType(check(l), "stale_warning"); len(early) != 0 {
		t.Fatalf("progress must reset the warning, got %v", early)
	}
	clock.advance(time.Second)
	if again := eventsOfType(check(l), "stale_warning"); len(again) != 1 {
		t.Fatalf("want a second warning after another quiet period, got %v", again)
	}
}

func TestLedgerPollsEveryThreeSecondsWithoutResettingStaleness(t *testing.T) {
	l, clock := newTestLedger()
	l.addStation("req-1", "shot-a", "req-1/shot-a")
	l.addStation("req-1", "shot-b", "req-1/shot-b")
	l.report("req-1", "shot-b", "needs_input")

	clock.advance(StationUpdateInterval - time.Nanosecond)
	if updates := eventsOfType(check(l), "station_update"); len(updates) != 0 {
		t.Fatalf("must not poll before three seconds: %v", updates)
	}
	clock.advance(time.Nanosecond)
	updates := eventsOfType(check(l), "station_update")
	byShot := map[string]proto.Event{}
	for _, update := range updates {
		byShot[update.ShotID] = update
	}
	if len(byShot) != 2 || byShot["shot-a"].Kind != string(phaseRunning) || byShot["shot-b"].Kind != string(phaseNeedsInput) {
		t.Fatalf("poll should identify every live Station and phase: %v", updates)
	}
	if byShot["shot-a"].RequestID != "req-1" || byShot["shot-a"].Description != "last Station report 3s ago" {
		t.Fatalf("poll should include the Station identity and report age: %+v", byShot["shot-a"])
	}
	if repeated := eventsOfType(check(l), "station_update"); len(repeated) != 0 {
		t.Fatalf("poll repeated before its interval: %v", repeated)
	}

	clock.advance(StaleThreshold - StationUpdateInterval)
	if warnings := eventsOfType(check(l), "stale_warning"); len(warnings) != 2 {
		t.Fatalf("polling must not reset either Station's stale tracking: %v", warnings)
	}
}

func TestLedgerReleasedStationNeverWarnsOrAlerts(t *testing.T) {
	l, clock := newTestLedger()
	l.addStation("req-1", "shot-a", "req-1/shot-a")
	l.report("req-1", "shot-a", "needs_input")
	l.finish("req-1", "shot-a")

	clock.advance(2 * StaleThreshold)
	if events := check(l); len(events) != 0 {
		t.Fatalf("a released Station must stay silent, got %v", events)
	}

	// A late report cannot resurrect it either.
	l.report("req-1", "shot-a", "needs_input")
	if events := check(l); len(events) != 0 {
		t.Fatalf("a late report must not resurrect a released Station, got %v", events)
	}
}

func TestLedgerIgnoresReportsFromUnknownStations(t *testing.T) {
	l, _ := newTestLedger()
	l.report("req-1", "shot-unknown", "needs_input")
	if events := check(l); len(events) != 0 {
		t.Fatalf("an unknown Station must not alert, got %v", events)
	}
}

func TestLedgerRebuildsWaitingAndQuietStationsFromHistory(t *testing.T) {
	root := t.TempDir()
	requestDir := state.RequestDir(root, "req-1")
	if err := os.MkdirAll(requestDir, 0o700); err != nil {
		t.Fatal(err)
	}
	history := "" +
		`{"type":"session_started","request_id":"req-1","shot_id":"shot-a","at":"2026-11-02T12:00:00.000Z"}` + "\n" +
		`{"type":"station_report","request_id":"req-1","shot_id":"shot-a","kind":"needs_input","description":"which one?","at":"2026-11-02T12:00:01.000Z"}` + "\n" +
		`{"type":"session_started","request_id":"req-1","shot_id":"shot-b","at":"2026-11-02T12:00:02.000Z"}` + "\n" +
		`{"type":"session_started","request_id":"req-1","shot_id":"shot-c","at":"2026-11-02T12:00:03.000Z"}` + "\n" +
		`{"type":"station_report","request_id":"req-1","shot_id":"shot-c","kind":"pulled","description":"abc1234","at":"2026-11-02T12:00:04.000Z"}` + "\n"
	if err := os.WriteFile(filepath.Join(requestDir, "history.ndjson"), []byte(history), 0o600); err != nil {
		t.Fatal(err)
	}

	l, clock := newTestLedger()
	l.rebuild(root)

	// shot-a asked a question before the restart: it must alert again, naming its session.
	events := check(l)
	if len(events) != 1 || events[0].Type != "needs_input_alert" || events[0].ShotID != "shot-a" {
		t.Fatalf("want the rebuilt waiting Station to alert, got %v", events)
	}
	if events[0].PaneID != "req-1/shot-a" {
		t.Fatalf("a rebuilt Station's session key is its reply address, got %q", events[0].PaneID)
	}

	// shot-b was silent since 12:00:02 and shot-c reported at 12:00:04, so one second
	// past shot-a's ten minutes only shot-a is quiet enough to warn. Using the restart
	// time instead would have warned about all three.
	clock.advance(StaleThreshold + time.Second)
	events = eventsOfType(check(l), "stale_warning")
	if len(events) != 1 || events[0].ShotID != "shot-a" {
		t.Fatalf("want only the Station quiet since 12:00:01 to warn, got %v", events)
	}

	// Three seconds later the other two cross their own thresholds.
	clock.advance(3 * time.Second)
	warned := map[string]bool{}
	for _, e := range eventsOfType(check(l), "stale_warning") {
		warned[e.ShotID] = true
	}
	if !warned["shot-b"] || !warned["shot-c"] {
		t.Fatalf("both remaining Stations must warn, got %v", warned)
	}
}

// A Station that asks a question must reach the reader as needs_input_alert through a
// real host run, not only through the ledger: this is the event the Barista acts on.
func TestNeedsInputAlertReachesTheHostStream(t *testing.T) {
	t.Setenv("CS_FAKE_REPORT_KIND", "needs_input")
	_, out, writeIn, stop := dispatchHostWithInput(t)
	defer stop()

	repo := committedDispatchRepo(t)
	if _, err := io.WriteString(writeIn, dispatchRequestJSON(repo, "shot-a")+"\n"); err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	waitFor(t, out, `"type":"session_started","request_id":"req-1","shot_id":"shot-a"`)
	waitFor(t, out, `"kind":"needs_input"`)
	waitFor(t, out, `{"type":"needs_input_alert","request_id":"req-1","shot_id":"shot-a","pane_id":"req-1/shot-a"`)
}
