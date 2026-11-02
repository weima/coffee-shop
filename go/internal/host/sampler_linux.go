//go:build linux

package host

// Reading a process on Linux: everything comes from /proc, so sampling costs one read per
// process and starts nothing.

import (
	"os"
	"strconv"
)

// linuxUserHz is the kernel's clock tick for /proc: 100 everywhere on Linux.
const linuxUserHz = 100

// sampleTree reads the Station and every descendant. `alive` is false once the Station
// process is gone, which ends sampling for that Shot.
func sampleTree(pid int) (station, tree ProcSample, alive bool) {
	station, alive = readProcess(pid)
	if !alive {
		return ProcSample{}, ProcSample{}, false
	}
	table := parentTable()
	descendants := descendantsOf(pid, table)

	tree = station
	tree.Children = Metric{Known: true, Value: uint64(len(descendants))}
	for _, child := range descendants {
		sample, ok := readProcess(child)
		if !ok {
			continue
		}
		tree.CPUms = addMetric(tree.CPUms, sample.CPUms)
		tree.RSS = addMetric(tree.RSS, sample.RSS)
		tree.FDs = addMetric(tree.FDs, sample.FDs)
	}
	return station, tree, true
}

func addMetric(a, b Metric) Metric {
	if !b.Known {
		return a
	}
	if !a.Known {
		return b
	}
	return Metric{Known: true, Value: a.Value + b.Value}
}

// readProcess parses /proc/<pid>/stat for cpu time, resident pages and descriptors.
func readProcess(pid int) (sample ProcSample, alive bool) {
	raw, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return ProcSample{}, false
	}
	_, utime, stime, rssPages, fieldsOK := procStatFields(string(raw))
	if !fieldsOK {
		return ProcSample{}, false
	}
	// USER_HZ is 100 on Linux regardless of arch, which is why /proc reports ticks.
	sample.CPUms = Metric{Known: true, Value: (utime + stime) * (1000 / linuxUserHz)}
	sample.RSS = Metric{Known: true, Value: rssPages * uint64(os.Getpagesize())}
	if count, err := os.ReadDir("/proc/" + strconv.Itoa(pid) + "/fd"); err == nil {
		sample.FDs = Metric{Known: true, Value: uint64(len(count))}
	}
	return sample, true
}

// parentTable maps pid to its parent, from one pass over /proc.
func parentTable() map[int]int {
	table := make(map[int]int, 256)
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return table
	}
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		raw, readErr := os.ReadFile("/proc/" + entry.Name() + "/stat")
		if readErr != nil {
			continue
		}
		ppid, _, _, _, ok := procStatFields(string(raw))
		if !ok {
			continue
		}
		table[pid] = int(ppid)
	}
	return table
}

func descendantsOf(pid int, table map[int]int) []int {
	result := make([]int, 0, 8)
	queue := []int{pid}
	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		for candidate, parent := range table {
			if parent != current || candidate == pid {
				continue
			}
			result = append(result, candidate)
			queue = append(queue, candidate)
			if len(result) > 256 {
				return result
			}
		}
	}
	return result
}

// samplingSupported is true where a per-process reading exists.
func samplingSupported() bool { return true }
