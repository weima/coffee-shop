package main

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_log_timestamp_is_rfc3339_utc_milliseconds :: proc(t: ^testing.T) {
	testing.expect_value(t, log_timestamp(time.unix(1793474401, 123_456_789)), "2026-10-31T19:20:01.123Z")
	testing.expect_value(t, log_timestamp(time.unix(1793474401, 810_000_000)), "2026-10-31T19:20:01.810Z")
	testing.expect_value(t, log_timestamp(time.unix(1793474401, 80_000_000)), "2026-10-31T19:20:01.080Z")
	testing.expect_value(t, log_timestamp(time.unix(1793474401, 0)), "2026-10-31T19:20:01.000Z")
}

// Host events append `at` as the final field. Strip only a valid, exact-shape UTC
// millisecond suffix, preserving all other event bytes and their order.
strip_event_timestamp :: proc(line: string) -> string {
	marker := `,"at":"`
	start := strings.last_index(line, marker)
	if start < 0 || !strings.has_suffix(line, "Z\"}") { return line }
	stamp_start := start + len(marker)
	stamp := line[stamp_start:len(line)-2]
	if len(stamp) != len("2026-10-31T19:20:01.123Z") || stamp[10] != 'T' || stamp[19] != '.' || stamp[23] != 'Z' {
		return line
	}
	stamp_end := stamp_start + len(stamp)
	if start == 1 {
		return strings.concatenate({"{", line[stamp_end + 2:]}, context.temp_allocator)
	}
	return strings.concatenate({line[:start], line[stamp_end + 1:]}, context.temp_allocator)
}

strip_all_event_timestamps :: proc(out: string) -> string {
	lines := strings.split_lines(out, context.temp_allocator)
	stripped := make([dynamic]string, 0, len(lines), context.temp_allocator)
	for line in lines { append(&stripped, strip_event_timestamp(line)) }
	return strings.join(stripped[:], "\n", context.temp_allocator)
}

host_output_contains :: proc(out, expected: string) -> bool {
	return strings.contains(strip_all_event_timestamps(out), expected)
}

host_output_count :: proc(out, expected: string) -> int {
	return strings.count(strip_all_event_timestamps(out), expected)
}

host_output_has_event :: proc(out, expected: string) -> bool {
	for line in strings.split_lines(out, context.temp_allocator) {
		if strings.trim_space(strip_event_timestamp(line)) == expected { return true }
	}
	return false
}

// Compatibility-format test: timestamp addition must not alter event fields/order.
@(test)
test_host_timestamp_suffix_preserves_event_json :: proc(t: ^testing.T) {
	stamp := log_timestamp(time.unix(1793474401, 123_456_789))
	event := Host_Event{type = "error", reason = "probe", at = stamp}
	data, err := json.marshal(event, {}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	want := strings.concatenate({`"at":"`, stamp, `"`}, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), want), string(data))
	line := strings.concatenate({`{"type":"ready","protocol":1,"at":"`, stamp, `"}`}, context.temp_allocator)
	testing.expect_value(t, strip_event_timestamp(line), `{"type":"ready","protocol":1}`)
}
