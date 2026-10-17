package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// One reading. known is false when the platform cannot expose the value or the
// process cannot be read; an unknown value is never zero and never guessed.
Metric :: struct {
	known: bool,
	value: u64,
}

// Resource use of one process. cpu is milliseconds of user plus system time.
Sample :: struct {
	cpu_ms:   Metric,
	rss:      Metric, // resident bytes
	fds:      Metric, // open file descriptors
	children: Metric, // direct children
}

// What one Shot's Station used: the Station itself, and the sum over its
// descendants (Pi and what Pi starts). The peak holds the largest value seen
// for each field, so it can only grow.
Resource_Record :: struct {
	station_start: Sample,
	station_peak:  Sample,
	tree_start:    Sample,
	tree_peak:     Sample,
	samples:       int,
}

Process_Edge :: struct {
	pid, ppid: int,
}

MAX_TREE :: 256

sample_process :: proc(pid: int) -> Sample {
	sample := platform_sample(pid)
	if sample.rss.known || sample.fds.known || sample.cpu_ms.known {
		sample.children = Metric{true, 0}
		for edge in platform_process_table(context.temp_allocator) {
			if edge.ppid == pid {
				sample.children.value += 1
			}
		}
	}
	return sample
}

// Samples pid and every descendant. The tree is discovered here, from the
// operating system's process table.
sample_tree :: proc(pid: int) -> (station, tree: Sample) {
	station = sample_process(pid)
	table := platform_process_table(context.temp_allocator)
	queue := make([dynamic]int, 0, 16, context.temp_allocator)
	append(&queue, pid)
	for head := 0; head < len(queue) && len(queue) < MAX_TREE; head += 1 {
		for edge in table {
			if edge.ppid == queue[head] && edge.pid != pid {
				append(&queue, edge.pid)
			}
		}
	}
	for descendant in queue[1:] {
		add_sample(&tree, platform_sample(descendant))
	}
	if len(queue) > 1 {
		tree.children = Metric{true, u64(len(queue) - 1)}
	} else if station.rss.known {
		tree.children = Metric{true, 0}
	}
	return
}

// Sums known values; a field stays unknown only while nothing has reported it.
add_sample :: proc(total: ^Sample, other: Sample) {
	add_metric(&total.cpu_ms, other.cpu_ms)
	add_metric(&total.rss, other.rss)
	add_metric(&total.fds, other.fds)
}

add_metric :: proc(total: ^Metric, other: Metric) {
	if other.known {
		total.known = true
		total.value += other.value
	}
}

max_metric :: proc(peak: ^Metric, later: Metric) {
	if later.known && (!peak.known || later.value > peak.value) {
		peak^ = later
	}
}

merge_peak :: proc(peak: ^Sample, later: Sample) {
	max_metric(&peak.cpu_ms, later.cpu_ms)
	max_metric(&peak.rss, later.rss)
	max_metric(&peak.fds, later.fds)
	max_metric(&peak.children, later.children)
}

// The first call stores the start sample; every call folds into the peak.
record_sample :: proc(record: ^Resource_Record, station, tree: Sample) {
	if record.samples == 0 {
		record.station_start = station
		record.tree_start = tree
	}
	merge_peak(&record.station_peak, station)
	merge_peak(&record.tree_peak, tree)
	record.samples += 1
}

resource_path :: proc(directory, shot_id: string) -> string {
	workers_dir := state_file_path(directory, "workers")
	defer delete(workers_dir)
	filename := strings.concatenate({shot_id, ".resource"})
	defer delete(filename)
	return state_file_path(workers_dir, filename)
}

// Samples a live Station and folds the reading into the Shot's record.
// An unreadable process adds nothing, so the record keeps its last peak.
record_resource_use :: proc(directory, shot_id: string, pid: int) {
	station, tree := sample_tree(pid)
	if !station.rss.known && !station.fds.known && !station.cpu_ms.known {
		return
	}
	path := resource_path(directory, shot_id)
	defer delete(path)
	record, _ := read_resource_record(path)
	record_sample(&record, station, tree)
	if data, err := json.marshal(record); err == nil {
		_ = write_file_atomic(path, data)
		delete(data)
	}
}

// The host's equivalent of a Brew directory: workers/ lives under host/<request>,
// where tools/gates finds <state>/**/workers/<shot>.resource.
record_host_resource_use :: proc(state_root, request_id, shot_id: string, pid: int) {
	directory := state_file_path(state_root, "host", context.temp_allocator)
	directory = state_file_path(directory, request_id, context.temp_allocator)
	workers := state_file_path(directory, "workers", context.temp_allocator)
	_ = os.make_directory_all(workers)
	record_resource_use(directory, shot_id, pid)
}

read_resource_record :: proc(path: string) -> (record: Resource_Record, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	return record, json.unmarshal(data, &record, .JSON, context.temp_allocator) == nil
}

// The recorded peak as one readable line, or false when nothing was recorded.
resource_line :: proc(directory, shot_id: string) -> (line: string, ok: bool) {
	path := resource_path(directory, shot_id)
	defer delete(path)
	record := read_resource_record(path) or_return
	return fmt.tprintf(
		"resources %s: Station peak %s; Pi tree peak %s; %d samples",
		shot_id, describe_sample(record.station_peak), describe_sample(record.tree_peak), record.samples,
	), true
}

describe_sample :: proc(s: Sample) -> string {
	rss := "rss to be verified"
	if s.rss.known {
		rss = fmt.tprintf("rss %.1f MiB", f64(s.rss.value) / (1024 * 1024))
	}
	cpu := "cpu to be verified"
	if s.cpu_ms.known {
		cpu = fmt.tprintf("cpu %.2fs", f64(s.cpu_ms.value) / 1000)
	}
	return fmt.tprintf("%s, %s, fds %s, children %s", rss, cpu, metric_text(s.fds), metric_text(s.children))
}

metric_text :: proc(m: Metric) -> string {
	return fmt.tprintf("%d", m.value) if m.known else "to be verified"
}
