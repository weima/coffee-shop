package main

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
resource_sample_of_self_is_plausible :: proc(t: ^testing.T) {
	sample := sample_process(int(os.get_pid()))
	testing.expect(t, sample.rss.known && sample.rss.value > 0, "resident size must be known and non-zero")
	testing.expect(t, sample.fds.known && sample.fds.value >= 3 && sample.fds.value < 1_000_000, "fd count must be plausible")
}

@(test)
resource_sample_of_missing_pid_is_unknown :: proc(t: ^testing.T) {
	for pid in ([]int{DEAD_IDENTITY.pid, 0, -1}) {
		sample := sample_process(pid)
		testing.expect(t, !sample.rss.known && !sample.fds.known && !sample.cpu_ms.known && !sample.children.known, "an unreadable pid must be unknown")
	}
}

@(test)
resource_peak_never_decreases :: proc(t: ^testing.T) {
	peak: Sample
	highest: u64
	for value in ([]u64{5, 9, 3, 9, 1}) {
		before := peak.rss.value
		merge_peak(&peak, Sample{rss = Metric{true, value}})
		highest = max(highest, value)
		testing.expect(t, peak.rss.value >= before, "peak decreased")
		testing.expect_value(t, peak.rss.value, highest)
	}
	kept := peak
	merge_peak(&peak, Sample{})
	testing.expect_value(t, peak, kept)
}

@(test)
resource_record_keeps_start_and_peak :: proc(t: ^testing.T) {
	record: Resource_Record
	readings := []u64{10, 40, 20}
	highest: u64
	for value, i in readings {
		reading := Sample{rss = Metric{true, value}, children = Metric{true, value}}
		record_sample(&record, reading, reading)
		highest = max(highest, value)
		testing.expect_value(t, record.station_start.rss.value, readings[0])
		testing.expect_value(t, record.tree_start.rss.value, readings[0])
		testing.expect_value(t, record.station_peak.rss.value, highest)
		testing.expect_value(t, record.tree_peak.children.value, highest)
		testing.expect_value(t, record.samples, i + 1)
	}
}

@(test)
host_station_record_lands_where_gates_look :: proc(t: ^testing.T) {
	root, _ := os.make_directory_temp("", "cs-hostres", context.temp_allocator)
	defer os.remove_all(root)
	record_host_resource_use(root, "req-1", "shot-1", int(os.get_pid()))
	path := resource_path(state_file_path(root, "host/req-1", context.temp_allocator), "shot-1")
	defer delete(path)
	record, ok := read_resource_record(path)
	testing.expect(t, ok, "record must exist under <state>/host/<request>/workers/<shot>.resource")
	testing.expect(t, record.station_peak.rss.known && record.station_peak.rss.value > 0, "resident size must be non-zero")
	testing.expect(t, record.station_peak.fds.known && record.station_peak.fds.value >= 3 && record.station_peak.fds.value < 1_000_000, "descriptor count must be plausible")
	testing.expect(t, record.station_peak.children.known, "child count must be recorded")
	when ODIN_OS == .Darwin {
		testing.expect(t, !record.station_peak.cpu_ms.known, "cpu is unobtainable on macOS: unknown, never zero")
	}
	before := record.station_peak.rss.value
	record_host_resource_use(root, "req-1", "shot-1", int(os.get_pid()))
	again, _ := read_resource_record(path)
	testing.expect_value(t, again.samples, 2)
	testing.expect(t, again.station_peak.rss.value >= before, "peak must not decrease")
}

@(test)
host_unreadable_station_records_nothing :: proc(t: ^testing.T) {
	root, _ := os.make_directory_temp("", "cs-hostres", context.temp_allocator)
	defer os.remove_all(root)
	record_host_resource_use(root, "req-1", "shot-1", DEAD_IDENTITY.pid)
	path := resource_path(state_file_path(root, "host/req-1", context.temp_allocator), "shot-1")
	defer delete(path)
	_, ok := read_resource_record(path)
	testing.expect(t, !ok, "an unreadable Station must not leave a zero record")
}

SAMPLE_BOUND :: 2 * time.Second

@(test)
station_sampling_returns_promptly_and_records :: proc(t: ^testing.T) {
	root, _ := os.make_directory_temp("", "cs-hostres", context.temp_allocator)
	defer os.remove_all(root)
	took := sample_station(root, "req-2", "shot-2", int(os.get_pid()))
	testing.expectf(t, took < SAMPLE_BOUND, "sampling took %v, bound %v", took, SAMPLE_BOUND)
	path := resource_path(state_file_path(root, "host/req-2", context.temp_allocator), "shot-2")
	defer delete(path)
	record, ok := read_resource_record(path)
	testing.expect(t, ok, "record must exist at <state>/host/<request>/workers/<shot>.resource")
	testing.expect(t, record.station_peak.rss.known && record.station_peak.rss.value > 0, "resident size must be real")
	testing.expect(t, record.station_peak.fds.known && record.station_peak.fds.value >= 3 && record.station_peak.fds.value < 1_000_000, "descriptor count must be plausible")
}

@(test)
station_lookup_by_arguments_needs_no_child :: proc(t: ^testing.T) {
	started := time.tick_now()
	// Another process may hold this exact text, but never this one: it is excluded as the host.
	testing.expect_value(t, find_pid_by_args(station_needle("no-such-shot", "no-such-brew")), 0)
	buffer: [dynamic]u8
	defer delete(buffer)
	testing.expect(t, platform_process_args(int(os.get_pid()), &buffer) && len(buffer) > 0, "own arguments must be readable")
	testing.expect(t, strings.contains(string(buffer[:]), os.args[0]), "arguments must hold argv[0]")
	testing.expect(t, time.tick_since(started) < SAMPLE_BOUND, "lookup must return within the bound")
}

@(test)
unfindable_station_records_nothing_and_returns_promptly :: proc(t: ^testing.T) {
	root, _ := os.make_directory_temp("", "cs-hostres", context.temp_allocator)
	defer os.remove_all(root)
	took := sample_station(root, "req-3", "shot-3", 0)
	testing.expect(t, took < SAMPLE_BOUND, "must return within the bound")
	path := resource_path(state_file_path(root, "host/req-3", context.temp_allocator), "shot-3")
	defer delete(path)
	_, ok := read_resource_record(path)
	testing.expect(t, !ok, "an unfound Station must leave no record")
}
