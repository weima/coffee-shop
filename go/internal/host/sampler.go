package host

// Station resource sampling: what each Station and its descendants actually used.
//
// The gates' 5.9 report reads `<state>/host/<request>/workers/<shot>.resource`, and the
// Odin host was the last writer. The Go host owns the Station process, so it can sample
// the tree directly — no extra process, no `ps` (whose setuid wait is skipped and leaves
// zombies). A field the platform cannot read stays `known: false`, never zero: an unknown
// value that looks like zero is worse than a gap.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/weima/coffee-shop/go/internal/state"
)

// SampleInterval is how often a live Station is sampled. Two seconds is the Odin host's
// interval: often enough to catch a peak, rare enough to cost nothing.
const SampleInterval = 2 * time.Second

// Metric is one reading. `known` is false when the platform cannot supply it or the
// process is gone, so a consumer can tell a gap from a zero.
type Metric struct {
	Known bool   `json:"known"`
	Value uint64 `json:"value"`
}

// ProcSample is one process tree's use: the Station alone, and the tree under it.
type ProcSample struct {
	CPUms    Metric `json:"cpu_ms"`
	RSS      Metric `json:"rss"`
	FDs      Metric `json:"fds"`
	Children Metric `json:"children"`
}

// ResourceRecord is the file `tools/gates` reads. The field names and order match the
// record the Odin host wrote, so the report needs no change.
type ResourceRecord struct {
	StationStart ProcSample `json:"station_start"`
	StationPeak  ProcSample `json:"station_peak"`
	TreeStart    ProcSample `json:"tree_start"`
	TreePeak     ProcSample `json:"tree_peak"`
	Samples      int        `json:"samples"`
}

// stationSampler keeps one record per live Station and rewrites it as samples arrive.
type stationSampler struct {
	root    string
	mu      sync.Mutex
	records map[string]*ResourceRecord
	targets map[string]stationTarget
}

type stationTarget struct {
	requestID string
	shotID    string
	pid       int
}

func newStationSampler(root string) *stationSampler {
	return &stationSampler{root: root, records: make(map[string]*ResourceRecord), targets: make(map[string]stationTarget)}
}

// track starts recording a Station. A Shot that is re-tracked keeps its history, so a
// restarted Station does not erase a peak that was already measured.
func (s *stationSampler) track(requestID, shotID string, pid int) {
	if pid <= 0 {
		return
	}
	key := stationKey(requestID, shotID)
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.records[key]; !ok {
		s.records[key] = &ResourceRecord{}
	}
	s.targets[key] = stationTarget{requestID: requestID, shotID: shotID, pid: pid}
}

// sample reads every tracked Station, folds the reading into its peak and rewrites the
// record. A Station whose process is gone is dropped: its peak is already on disk.
func (s *stationSampler) sample() {
	s.mu.Lock()
	targets := make([]stationTarget, 0, len(s.targets))
	for key, target := range s.targets {
		_ = key
		targets = append(targets, target)
	}
	s.mu.Unlock()

	for _, target := range targets {
		station, tree, alive := sampleTree(target.pid)
		if !alive {
			s.finish(target.requestID, target.shotID)
			continue
		}
		s.mu.Lock()
		record, ok := s.records[stationKey(target.requestID, target.shotID)]
		if ok {
			foldSample(record, station, tree)
		}
		s.mu.Unlock()
		if ok {
			s.write(target.requestID, target.shotID)
		}
	}
}

// finish takes one last reading, writes the record and stops sampling that Station.
func (s *stationSampler) finish(requestID, shotID string) {
	key := stationKey(requestID, shotID)
	s.mu.Lock()
	target, tracked := s.targets[key]
	delete(s.targets, key)
	s.mu.Unlock()
	if tracked {
		if station, tree, alive := sampleTree(target.pid); alive {
			s.mu.Lock()
			if record, ok := s.records[key]; ok {
				foldSample(record, station, tree)
			}
			s.mu.Unlock()
		}
	}
	s.write(requestID, shotID)
}

// foldSample keeps the largest value seen for each field, so a peak can only grow.
func foldSample(record *ResourceRecord, station, tree ProcSample) {
	if record.Samples == 0 {
		record.StationStart = station
		record.TreeStart = tree
	}
	record.StationPeak = peakOf(record.StationPeak, station)
	record.TreePeak = peakOf(record.TreePeak, tree)
	record.Samples++
}

func peakOf(peak, later ProcSample) ProcSample {
	return ProcSample{
		CPUms:    maxMetric(peak.CPUms, later.CPUms),
		RSS:      maxMetric(peak.RSS, later.RSS),
		FDs:      maxMetric(peak.FDs, later.FDs),
		Children: maxMetric(peak.Children, later.Children),
	}
}

func maxMetric(a, b Metric) Metric {
	if !b.Known {
		return a
	}
	if !a.Known || b.Value > a.Value {
		return b
	}
	return a
}

// write publishes one record where `tools/gates` looks for it.
func (s *stationSampler) write(requestID, shotID string) {
	s.mu.Lock()
	record, ok := s.records[stationKey(requestID, shotID)]
	copied := ResourceRecord{}
	if ok {
		copied = *record
	}
	s.mu.Unlock()
	if !ok || copied.Samples == 0 {
		return
	}
	path := resourcePath(s.root, requestID, shotID)
	if err := state.EnsureDir(filepath.Dir(path), true); err != nil {
		return
	}
	data, err := json.Marshal(copied)
	if err != nil {
		return
	}
	// Write-then-rename: a reader never sees half a record.
	tmp := path + ".tmp"
	if os.WriteFile(tmp, data, 0o600) != nil {
		return
	}
	_ = os.Rename(tmp, path)
}

// resourcePath is `<state>/host/<request>/workers/<shot>.resource`, the path the gates
// walker looks for.
func resourcePath(root, requestID, shotID string) string {
	return filepath.Join(state.RequestDir(root, requestID), "workers", shotID+".resource")
}
