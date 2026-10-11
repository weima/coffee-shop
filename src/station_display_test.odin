package main

import "core:strings"
import "core:testing"

@(test)
test_station_block_walks_with_the_mug_on_the_facing_side :: proc(t: ^testing.T) {
	right := station_block_lines(5, 0, true, "Running tool: read")
	testing.expect(t, strings.has_prefix(right[2], "     ( o.o )[_]"), right[2])
	testing.expect(t, strings.has_prefix(right[1], "      /\\_/\\"), right[1])
	testing.expect_value(t, right[4], "Running tool: read")

	left := station_block_lines(5, 0, false, "Waiting for your reply")
	testing.expect(t, strings.has_prefix(left[2], "     [_] ( o.o )"), left[2])
	testing.expect_value(t, left[4], "Waiting for your reply")
}

@(test)
test_station_block_legs_and_steam_alternate :: proc(t: ^testing.T) {
	first := station_block_lines(0, 0, true, "")
	next := station_block_lines(0, 1, true, "")
	testing.expect(t, first[3] != next[3], "legs should change every frame")
	testing.expect(t, first[2] == next[2], "the face and mug stay put")
	later := station_block_lines(0, 2, true, "")
	testing.expect(t, first[0] != later[0], "steam should change every two frames")
}

@(test)
test_station_block_truncates_long_status :: proc(t: ^testing.T) {
	long := strings.repeat("x", STATION_STATUS_MAX + 20, context.temp_allocator)
	lines := station_block_lines(0, 0, true, long)
	testing.expect_value(t, len(lines[4]), STATION_STATUS_MAX)
}

@(test)
test_station_walker_turns_at_both_ends :: proc(t: ^testing.T) {
	display: Station_Display
	display.dir = 1
	for i := 0; display.dir == 1 && i < 4 * STATION_TRACK; i += 1 {
		station_display_advance_locked(&display)
	}
	testing.expect_value(t, display.dir, -1)
	testing.expect_value(t, display.x, STATION_TRACK - STATION_SPRITE_WIDTH)
	for i := 0; display.dir == -1 && i < 4 * STATION_TRACK; i += 1 {
		station_display_advance_locked(&display)
	}
	testing.expect_value(t, display.dir, 1)
	testing.expect_value(t, display.x, 0)
}
