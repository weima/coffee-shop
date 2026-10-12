package main

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_station_block_matches_the_supplied_cat_and_its_mirror :: proc(t: ^testing.T) {
	// The supplied art, byte for byte, padded to STATION_SPRITE_WIDTH.
	want_right := [3]string{"     /\\_/\\   ", "  ___( o.o)  ", " /   >  ^  > "}
	// Mirrored: each line reversed, with / and \, ( and ), and < and > swapped.
	want_left := [3]string{" /\\_/\\       ", " (o.o )___   ", " <  ^  <   \\ "}
	right := station_block_lines(0, 0, true, "")
	left := station_block_lines(0, 0, false, "")
	for line, i in want_right {
		testing.expect_value(t, len(line), STATION_SPRITE_WIDTH)
		testing.expect_value(t, len(want_left[i]), STATION_SPRITE_WIDTH)
		testing.expect_value(t, right[i + 1], line)
		testing.expect_value(t, left[i + 1], want_left[i])
		testing.expect_value(t, len(right[i + 1]), STATION_SPRITE_WIDTH)
		testing.expect_value(t, len(left[i + 1]), STATION_SPRITE_WIDTH)
		testing.expect(t, right[i + 1] != left[i + 1], "directions should differ")
	}
}

@(test)
test_station_block_indents_the_cat_and_keeps_the_status :: proc(t: ^testing.T) {
	lines := station_block_lines(5, 0, true, "Running tool: read")
	want_ears := "     /\\_/\\   " // the supplied ears row, padded to STATION_SPRITE_WIDTH
	testing.expect_value(t, lines[1], fmt.tprintf("     %s", want_ears))
	testing.expect_value(t, lines[4], "Running tool: read")
}

@(test)
test_station_block_cat_is_static_while_steam_alternates :: proc(t: ^testing.T) {
	first := station_block_lines(0, 0, true, "")
	next := station_block_lines(0, 1, true, "")
	testing.expect_value(t, first[3], next[3])
	testing.expect_value(t, first[2], next[2])
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
test_station_progress_steps_describe_tool_calls :: proc(t: ^testing.T) {
	command := "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
	bash_line := fmt.tprintf(`{{"type":"tool_execution_start","toolName":"bash","args":{{"command":"%s"}}}}`, command)
	cases := []struct{ line, want: string }{
		{`{"type":"tool_execution_start","toolName":"read","args":{"path":"src/main.odin"}}`, "reading src/main.odin"},
		{bash_line, fmt.tprintf("running %s", command[:STATION_BASH_COMMAND_MAX])},
		{`{"type":"tool_execution_start","toolName":"edit","args":{"path":"src/station.odin"}}`, "editing src/station.odin"},
		{`{"type":"tool_execution_start","toolName":"grep","args":{"pattern":"status"}}`, "searching"},
		{`{"type":"tool_execution_start","toolName":"custom","args":{}}`, "running custom"},
	}
	for c in cases {
		_, step, ok := station_progress_event(c.line)
		testing.expect(t, ok, c.line)
		testing.expect_value(t, step, c.want)
	}
}

@(test)
test_station_progress_counts_turns_and_tools :: proc(t: ^testing.T) {
	display := Station_Display{started_at_ns = 1_000_000_000}
	defer delete(display.status)
	for line in ([]string{
		`{"type":"turn_start"}`,
		`{"type":"tool_execution_start","toolName":"read","args":{"path":"a"}}`,
		`{"type":"tool_execution_end","toolName":"read"}`,
		`{"type":"turn_start"}`,
		`{"type":"tool_execution_start","toolName":"write","args":{"path":"b"}}`,
		`{"type":"tool_execution_end","toolName":"write"}`,
	}) {
		event_type, step, ok := station_progress_event(line)
		if ok {
			station_display_progress(&display, event_type, step)
		}
	}
	status := station_display_status_line(&display, 81_000_000_000)
	defer delete(status)
	testing.expect_value(t, display.turn_count, 2)
	testing.expect_value(t, display.tool_count, 2)
	testing.expect_value(t, display.active_tool_count, 0)
	testing.expect_value(t, status, "thinking · turn 2 · 2 tools · 1m20s")
}

@(test)
test_station_elapsed_label_formats_minutes_and_seconds :: proc(t: ^testing.T) {
	label := station_elapsed_label(1_000_000_000, 81_000_000_000)
	defer delete(label)
	testing.expect_value(t, label, "1m20s")
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
