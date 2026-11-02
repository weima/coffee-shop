package host

// Gate 5.9 reads `<state>/host/<request>/workers/<shot>.resource`. These tests pin the file
// it reads, the shape it parses, and the rule that a peak only grows.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/weima/coffee-shop/go/internal/state"
)

func TestSamplerWritesTheRecordGateFiveNineReads(t *testing.T) {
	if !samplingSupported() {
		t.Skip("this platform has no per-process reader; the record would be all-unknown")
	}
	root := shortRoot(t)
	sampler := newStationSampler(root)

	// A Station that is a real process, so the reading is real.
	process, err := os.StartProcess("/bin/sh", []string{"sh", "-c", "sleep 30"}, &os.ProcAttr{})
	if err != nil {
		t.Fatalf("start a stand-in Station: %v", err)
	}
	defer func() { _ = process.Kill(); _, _ = process.Wait() }()

	sampler.track("req-1", "shot-a", process.Pid)
	sampler.sample()
	sampler.finish("req-1", "shot-a")

	path := resourcePath(root, "req-1", "shot-a")
	if want := filepath.Join(state.RequestDir(root, "req-1"), "workers", "shot-a.resource"); path != want {
		t.Fatalf("the gates walker looks for %s, sampler writes %s", want, path)
	}
	data, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatalf("read the resource record: %v", readErr)
	}
	var record ResourceRecord
	if err := json.Unmarshal(data, &record); err != nil {
		t.Fatalf("the record must be the JSON the gates parse: %v", err)
	}
	if record.Samples == 0 {
		t.Fatalf("a live Station must be sampled at least once: %s", data)
	}
	// The field names the report reads: a rename here would silently blank the table.
	for _, field := range []string{"station_start", "station_peak", "tree_start", "tree_peak", `"known"`, `"value"`, `"cpu_ms"`, `"rss"`, `"fds"`, `"children"`} {
		if !jsonFieldPresent(data, field) {
			t.Fatalf("record is missing %s: %s", field, data)
		}
	}
	if !record.StationPeak.RSS.Known || record.StationPeak.RSS.Value == 0 {
		t.Fatalf("a live process has a resident size: %+v", record.StationPeak.RSS)
	}
	if !record.TreePeak.CPUms.Known {
		t.Fatalf("cpu time is readable on this platform: %+v", record.TreePeak.CPUms)
	}
}

func jsonFieldPresent(data []byte, field string) bool {
	var value any
	if json.Unmarshal(data, &value) != nil {
		return false
	}
	object, ok := value.(map[string]any)
	if !ok {
		return false
	}
	if _, found := object[field]; found {
		return true
	}
	for _, nested := range object {
		if inner, isObject := nested.(map[string]any); isObject {
			if _, found := inner[field]; found {
				return true
			}
		}
	}
	return false
}

func TestSamplerPeakOnlyGrowsAndStartIsKept(t *testing.T) {
	sampler := newStationSampler(t.TempDir())
	sampler.track("req-1", "shot-a", 1)

	key := stationKey("req-1", "shot-a")
	record := &ResourceRecord{}
	foldSample(record, ProcSample{RSS: Metric{Known: true, Value: 100}, FDs: Metric{Known: true, Value: 4}}, ProcSample{RSS: Metric{Known: true, Value: 300}})
	foldSample(record, ProcSample{RSS: Metric{Known: true, Value: 50}}, ProcSample{RSS: Metric{Known: true, Value: 900}, CPUms: Metric{Known: true, Value: 7}})

	if record.Samples != 2 {
		t.Fatalf("want two samples, got %d", record.Samples)
	}
	if record.StationStart.RSS.Value != 100 {
		t.Fatalf("the start sample must stay the first reading, got %d", record.StationStart.RSS.Value)
	}
	if record.StationPeak.RSS.Value != 100 {
		t.Fatalf("a smaller later reading must not lower the peak, got %d", record.StationPeak.RSS.Value)
	}
	if record.TreePeak.RSS.Value != 900 {
		t.Fatalf("a larger later reading must raise the peak, got %d", record.TreePeak.RSS.Value)
	}
	if record.TreePeak.CPUms.Value != 7 {
		t.Fatalf("an unknown earlier value must be replaced by a known one, got %+v", record.TreePeak.CPUms)
	}
	if record.StationPeak.FDs.Value != 4 {
		t.Fatalf("an unknown later value must not erase a known one, got %+v", record.StationPeak.FDs)
	}
	_ = key
}

func TestSamplerStopsTrackingAFinishedStation(t *testing.T) {
	if !samplingSupported() {
		t.Skip("no per-process reader on this platform")
	}
	root := shortRoot(t)
	sampler := newStationSampler(root)

	process, err := os.StartProcess("/bin/sh", []string{"sh", "-c", "true"}, &os.ProcAttr{})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	_, _ = process.Wait() // it is gone before the first sample

	sampler.track("req-1", "shot-b", process.Pid)
	sampler.sample()
	sampler.mu.Lock()
	_, stillTracked := sampler.targets[stationKey("req-1", "shot-b")]
	sampler.mu.Unlock()
	if stillTracked {
		t.Fatal("a Station whose process is gone must stop being sampled")
	}
	// Nothing was measured, so nothing is claimed on disk.
	if _, statErr := os.Stat(resourcePath(root, "req-1", "shot-b")); statErr == nil {
		t.Fatal("a Station that was never read must not leave a record")
	}
}

func TestSamplerDoesNotDelayTheHostWhenNoStationRuns(t *testing.T) {
	// A sample with nothing tracked is the common case, and must not touch the disk.
	root := shortRoot(t)
	sampler := newStationSampler(root)
	started := time.Now()
	sampler.sample()
	if elapsed := time.Since(started); elapsed > 50*time.Millisecond {
		t.Fatalf("an empty sample took %s", elapsed)
	}
	entries, _ := os.ReadDir(state.HostDir(root))
	if len(entries) != 0 {
		t.Fatalf("an empty sample wrote state: %v", entries)
	}
}

// The parser is the risky half of the Linux reader: a command name may contain spaces and
// parentheses, which is exactly where field counting from the start of the line breaks.
func TestProcStatFieldsCountsFromTheCommandName(t *testing.T) {
	line := `4242 (a (weird) name) S 4200 4242 4242 0 -1 4194560 1000 0 0 0 ` +
		`11 22 0 0 20 0 1 0 12345 1000000 500 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 0 0`
	ppid, utime, stime, rss, ok := procStatFields(line)
	if !ok {
		t.Fatalf("a real stat line must parse: %s", line)
	}
	if ppid != 4200 || utime != 11 || stime != 22 || rss != 500 {
		t.Fatalf("parsed ppid=%d utime=%d stime=%d rss=%d", ppid, utime, stime, rss)
	}

	for _, bad := range []string{"", "1 (x", "1 (x) S 0 0"} {
		if _, _, _, _, ok := procStatFields(bad); ok {
			t.Fatalf("%q must not parse", bad)
		}
	}
}
