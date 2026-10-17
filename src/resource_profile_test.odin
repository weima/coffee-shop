package main

import "core:os"
import "core:testing"

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
