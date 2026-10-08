package main

import "core:os"
import "core:testing"

@(test)
test_activity_state_round_trips_record_and_worker_start_time :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "coffee-shop-activity-state-*", context.allocator)
	testing.expect_value(t, err, os.Error(nil))
	defer os.remove_all(directory)
	defer delete(directory)
	workers := state_file_path(directory, "workers")
	defer delete(workers)
	testing.expect_value(
		t,
		os.make_directory_all(workers, os.Permissions{.Read_User, .Write_User, .Execute_User}),
		os.Error(nil),
	)

	message := Activity_Message{
		brew_id = "brew-1", shot_id = "shot-a", kind = "tool_start",
		description = "Running tool: read", timestamp_ns = 123_000_000_000,
	}
	testing.expect(t, write_activity_record(directory, message))
	record, ok := read_activity_record(directory, "shot-a")
	defer destroy_struct(&record)
	testing.expect(t, ok)
	testing.expect_value(t, record.kind, "tool_start")
	testing.expect_value(t, record.description, "Running tool: read")
	testing.expect_value(t, record.observed_at_ns, i64(123_000_000_000))

	testing.expect(t, write_worker_started_at(directory, "shot-a", 100_000_000_000))
	started_at, started := read_worker_started_at(directory, "shot-a")
	testing.expect(t, started)
	testing.expect_value(t, started_at, i64(100_000_000_000))
}

@(test)
test_activity_age_clamps_future_times_and_marks_twelve_minutes_quiet :: proc(t: ^testing.T) {
	testing.expect_value(t, activity_age_seconds(12_000_000_000, 10_000_000_000), i64(2))
	testing.expect_value(t, activity_age_seconds(10_000_000_000, 12_000_000_000), i64(0))
	testing.expect(t, !activity_is_quiet(100_000_000_000, 819_000_000_000))
	testing.expect(t, activity_is_quiet(100_000_000_000, 820_000_000_000))
}
