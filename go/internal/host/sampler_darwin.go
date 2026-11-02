//go:build darwin && cgo

package host

// Reading a process on macOS needs libproc: the resident size lives in
// `proc_pid_rusage` and the descriptor list in `proc_pidinfo`. Neither the standard
// library nor `x/sys` exposes them (its `Vmspace` is a stub), so this file is the one
// place Coffee Shop uses cgo. Linux needs none of it.

/*
#include <libproc.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <sys/resource.h>

// Wrapped so Go never has to name a C union or a C array type.
static int cs_rusage(int pid, struct rusage_info_v2 *ri) {
	return proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)ri);
}

static int cs_fd_count(int pid) {
	int size = 64 * (int)sizeof(struct proc_fdinfo);
	struct proc_fdinfo *buf = malloc(size);
	if (buf == NULL) { return -1; }
	int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf, size);
	if (bytes == size) {
		// It filled the buffer; ask for room proportional to the descriptors found.
		free(buf);
		size = 4096 * (int)sizeof(struct proc_fdinfo);
		buf = malloc(size);
		if (buf == NULL) { return -1; }
		bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf, size);
	}
	if (bytes <= 0) { free(buf); return -1; } // unreadable is unknown, not zero
	int count = bytes / (int)sizeof(struct proc_fdinfo);
	free(buf);
	return count;
}

static int cs_children(int pid, int *pids, int capacity) {
	int bytes = proc_listchildpids(pid, pids, capacity * (int)sizeof(int));
	return bytes > 0 ? bytes / (int)sizeof(int) : 0;
}
*/
import "C"

// sampleTree reads the Station and every descendant. `alive` is false once the Station
// process is gone, which ends sampling for that Shot.
func sampleTree(pid int) (station, tree ProcSample, alive bool) {
	station, alive = readDarwinProcess(pid)
	if !alive {
		return ProcSample{}, ProcSample{}, false
	}
	descendants := darwinDescendants(pid)
	tree = station
	tree.Children = Metric{Known: true, Value: uint64(len(descendants))}
	for _, child := range descendants {
		sample, ok := readDarwinProcess(child)
		if !ok {
			continue
		}
		tree.CPUms = addMetric(tree.CPUms, sample.CPUms)
		tree.RSS = addMetric(tree.RSS, sample.RSS)
		tree.FDs = addMetric(tree.FDs, sample.FDs)
	}
	return station, tree, true
}

// readDarwinProcess reads cpu time, resident size and descriptor count for one process.
func readDarwinProcess(pid int) (sample ProcSample, alive bool) {
	var usage C.struct_rusage_info_v2
	if C.cs_rusage(C.int(pid), &usage) != 0 {
		return ProcSample{}, false // gone, or not ours to read: either way, no reading
	}
	// Both rusage times and ri_resident_size are nanoseconds and bytes.
	cpuNanos := uint64(usage.ri_user_time) + uint64(usage.ri_system_time)
	sample.CPUms = Metric{Known: true, Value: cpuNanos / 1_000_000}
	sample.RSS = Metric{Known: true, Value: uint64(usage.ri_resident_size)}
	// Listing another process's descriptors is not guaranteed: macOS answers with no
	// entries for some processes the caller may still read cpu time and memory for. An
	// unavailable list stays unknown; recording it as zero would claim a fact.
	if fds := C.cs_fd_count(C.int(pid)); fds > 0 {
		sample.FDs = Metric{Known: true, Value: uint64(fds)}
	}
	return sample, true
}

// darwinDescendants walks the child list breadth-first, bounded so a broken tree cannot
// loop and a huge one cannot cost the host its frame.
func darwinDescendants(pid int) []int {
	const maxProcesses = 256
	capacity := 64
	buffer := make([]C.int, capacity)
	result := make([]int, 0, 8)
	queue := []int{pid}
	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		count := int(C.cs_children(C.int(current), &buffer[0], C.int(capacity)))
		for index := 0; index < count && index < capacity; index++ {
			child := int(buffer[index])
			if child <= 0 || child == pid {
				continue
			}
			result = append(result, child)
			queue = append(queue, child)
			if len(result) >= maxProcesses {
				return result
			}
		}
	}
	return result
}

// samplingSupported is true where a per-process reading exists.
func samplingSupported() bool { return true }
