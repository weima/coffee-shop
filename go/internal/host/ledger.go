package host

// Progress supervision: which Stations are live, whether one is waiting for a human,
// and whether one has stopped making progress. The Odin host kept this in
// src/progress_ledger.odin and src/progress_supervision.odin; the Go host is the
// default, so the same two events must come from here: `needs_input_alert` when a
// Station asks a question, and `stale_warning` when it has said nothing for ten
// minutes.
//
// The ledger is host state, not durable state: it is rebuilt from each request's
// history at start, so a restart still knows which Stations were live.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/weima/coffee-shop/go/internal/proto"
	"github.com/weima/coffee-shop/go/internal/state"
)

// StaleThreshold is how long a Station may go without a report before the host warns.
// It is a warning, never a cancel: a long Taste is legitimate.
const StaleThreshold = 10 * time.Minute

// LedgerPollInterval is how often the host checks for staleness. Reports are checked
// immediately when they arrive, so this only bounds the warning's delay.
const LedgerPollInterval = time.Second

// stationPhase is the ledger's view of a Station, matching the Odin host's phases.
type stationPhase string

const (
	phaseDispatched stationPhase = "dispatched"
	phaseRunning    stationPhase = "running"
	phaseNeedsInput stationPhase = "needs_input"
	phaseDone       stationPhase = "done"
)

type progressStation struct {
	requestID    string
	shotID       string
	paneID       string
	phase        stationPhase
	lastProgress time.Time
	lastReport   string
	staleWarned  bool // the stale warning was emitted for this quiet period
	alerted      bool // needs_input_alert was emitted for this question
	terminal     bool
}

type progressLedger struct {
	mu       sync.Mutex
	stations map[string]*progressStation
	now      func() time.Time
}

func newProgressLedger(now func() time.Time) *progressLedger {
	if now == nil {
		now = time.Now
	}
	return &progressLedger{stations: make(map[string]*progressStation), now: now}
}

// stationKey is the ledger key: a Station is its request and Shot, never its slot.
func stationKey(requestID, shotID string) string { return requestID + "/" + shotID }

// addStation records a Station that just started. Re-adding one replaces it, so a
// restarted Shot begins with a clean quiet period.
func (l *progressLedger) addStation(requestID, shotID, paneID string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.stations[stationKey(requestID, shotID)] = &progressStation{
		requestID:    requestID,
		shotID:       shotID,
		paneID:       paneID,
		phase:        phaseDispatched,
		lastProgress: l.now(),
	}
}

// updatePhase moves a Station between phases and counts as progress.
func (l *progressLedger) updatePhase(requestID, shotID string, phase stationPhase) {
	l.mu.Lock()
	defer l.mu.Unlock()
	station, ok := l.stations[stationKey(requestID, shotID)]
	if !ok || station.terminal {
		return
	}
	station.phase = phase
	station.lastProgress = l.now()
	if phase != phaseNeedsInput {
		station.alerted = false
		station.staleWarned = false
	}
}

// report records a Station's report. A `needs_input` report opens a question, so the
// alert fires from here; the Odin host never set that phase, which is why its alert
// could not fire. Any other report means the Station moved on: the question is closed
// and the quiet period restarts.
func (l *progressLedger) report(requestID, shotID, kind string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	station, ok := l.stations[stationKey(requestID, shotID)]
	if !ok {
		return
	}
	station.lastReport = kind
	if station.terminal {
		return
	}
	station.lastProgress = l.now()
	station.staleWarned = false
	switch kind {
	case "needs_input":
		station.phase = phaseNeedsInput
		station.alerted = false // a new question deserves its own alert
	case "session_failed", "blended", "blend_failed":
		station.phase = phaseDone
		station.terminal = true
	default:
		station.phase = phaseRunning
		station.alerted = false
	}
}

// finish marks a Station done once the host has released its slot: it can no longer
// go stale or ask anything.
func (l *progressLedger) finish(requestID, shotID string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	station, ok := l.stations[stationKey(requestID, shotID)]
	if !ok {
		return
	}
	station.phase = phaseDone
	station.terminal = true
}

// checkAndEmit emits one warning per condition, never one per poll: a stale Station
// warns once until it reports again, and a question alerts once until it is answered.
func (l *progressLedger) checkAndEmit(emit func(proto.Event) error) {
	l.mu.Lock()
	events := make([]proto.Event, 0, 2)
	for _, station := range l.stations {
		if station.terminal {
			continue
		}
		if !station.staleWarned && l.now().Sub(station.lastProgress) >= StaleThreshold {
			station.staleWarned = true
			events = append(events, proto.Event{
				Type:      "stale_warning",
				RequestID: station.requestID,
				ShotID:    station.shotID,
				Reason:    "10 minutes without progress",
			})
		}
		if station.phase == phaseNeedsInput && !station.alerted {
			station.alerted = true
			events = append(events, proto.Event{
				Type:      "needs_input_alert",
				RequestID: station.requestID,
				ShotID:    station.shotID,
				PaneID:    station.paneID,
			})
		}
	}
	l.mu.Unlock()

	for _, event := range events {
		if err := emit(event); err != nil {
			return
		}
	}
}

// touchAt restores a Station's quiet period from its history timestamp, so a Station
// that was already quiet before a restart warns on time rather than a full threshold
// after it. An unparseable timestamp keeps the restart time.
func (l *progressLedger) touchAt(requestID, shotID, at string) {
	stamp, err := time.Parse("2006-01-02T15:04:05.000Z", at)
	if err != nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if station, ok := l.stations[stationKey(requestID, shotID)]; ok {
		station.lastProgress = stamp
	}
}

// rebuild reads every request's history and restores what it says about live Stations,
// so a host that restarted still warns about a Station that was waiting or silent.
func (l *progressLedger) rebuild(root string) {
	if root == "" {
		return
	}
	entries, err := os.ReadDir(state.HostDir(root))
	if err != nil {
		return
	}
	for _, entry := range entries {
		if !entry.IsDir() || !validShotID(entry.Name()) {
			continue
		}
		requestID := entry.Name()
		data, readErr := os.ReadFile(filepath.Join(state.HostDir(root), requestID, "history.ndjson"))
		if readErr != nil {
			continue
		}
		for _, line := range splitHistoryLines(data) {
			var event proto.Event
			if json.Unmarshal(line, &event) != nil {
				continue
			}
			switch event.Type {
			case "session_started":
				if validShotID(event.ShotID) {
					// The Go host addresses a Station by its session key, so a history line
					// without a pane id still names the Station a reply would reach.
					paneID := event.PaneID
					if paneID == "" {
						paneID = stationKey(requestID, event.ShotID)
					}
					l.addStation(requestID, event.ShotID, paneID)
					l.updatePhase(requestID, event.ShotID, phaseRunning)
					l.touchAt(requestID, event.ShotID, event.At)
				}
			case "station_report":
				if validShotID(event.ShotID) && event.Kind != "" {
					l.report(requestID, event.ShotID, event.Kind)
					l.touchAt(requestID, event.ShotID, event.At)
				}
			}
		}
	}
}

func splitHistoryLines(data []byte) [][]byte {
	lines := make([][]byte, 0, 8)
	start := 0
	for i, b := range data {
		if b != '\n' {
			continue
		}
		if i > start {
			lines = append(lines, data[start:i])
		}
		start = i + 1
	}
	if start < len(data) {
		lines = append(lines, data[start:])
	}
	return lines
}
