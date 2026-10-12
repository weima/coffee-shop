package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal/ansi"
import "core:testing"

// Mirrors a sprite row the way the left-facing cat is built: reverse the padded
// row, then swap / and \, ( and ), and < and >.
mirror_sprite_row :: proc(row: string) -> string {
	flipped := make([dynamic]u8, 0, len(row), context.temp_allocator)
	for i := len(row); i > 0; i -= 1 {
		append(&flipped, row[i - 1])
	}
	for &c in flipped {
		switch c {
		case '/': c = '\\'
		case '\\': c = '/'
		case '(': c = ')'
		case ')': c = '('
		case '<': c = '>'
		case '>': c = '<'
		}
	}
	return string(flipped[:])
}

@(test)
test_station_block_matches_the_supplied_cat_and_its_mirror :: proc(t: ^testing.T) {
	// The supplied art, byte for byte, padded to STATION_SPRITE_WIDTH.
	want_right := [3]string{"     /\\_/\\   ", "  ___( o.o)  ", " /   >  ^  > "}
	right := station_block_lines(0, 0, true, "")
	left := station_block_lines(0, 0, false, "")
	for line, i in want_right {
		testing.expect_value(t, len(line), STATION_SPRITE_WIDTH)
		testing.expect_value(t, right[i], line)
		// The left-facing line must be the true mirror, so editing one side and
		// forgetting the other fails here rather than shifting the cat.
		testing.expect_value(t, left[i], mirror_sprite_row(line))
		testing.expect_value(t, len(right[i]), STATION_SPRITE_WIDTH)
		testing.expect_value(t, len(left[i]), STATION_SPRITE_WIDTH)
		testing.expect(t, right[i] != left[i], "directions should differ")
	}
}

@(test)
test_station_block_indents_the_cat_and_keeps_the_status :: proc(t: ^testing.T) {
	lines := station_block_lines(5, 0, true, "Running tool: read")
	want_ears := "     /\\_/\\   " // the supplied ears row, padded to STATION_SPRITE_WIDTH
	testing.expect_value(t, lines[0], fmt.tprintf("     %s", want_ears))
	testing.expect_value(t, lines[3], "Running tool: read")
}

@(test)
test_station_block_cat_is_static :: proc(t: ^testing.T) {
	first := station_block_lines(0, 0, true, "")
	next := station_block_lines(0, 1, true, "")
	testing.expect_value(t, first[2], next[2])
	testing.expect_value(t, first[1], next[1])
}

@(test)
test_station_block_truncates_long_status :: proc(t: ^testing.T) {
	long := strings.repeat("x", STATION_STATUS_MAX + 20, context.temp_allocator)
	lines := station_block_lines(0, 0, true, long)
	testing.expect_value(t, len(lines[3]), STATION_STATUS_MAX)
}

@(test)
test_station_block_strips_line_breaks_from_status :: proc(t: ^testing.T) {
	lines := station_block_lines(0, 0, true, "one\ntwo\rthree")
	testing.expect_value(t, lines[3], "onetwothree")
	// No row carries CR or LF, so the four rows written with a `\n` between them
	// stay exactly STATION_BLOCK_ROWS visual rows.
	breaks := 0
	for row, i in lines {
		for r in row {
			if r == '\n' || r == '\r' {
				breaks += 1
			}
		}
		testing.expectf(t, !strings.contains_any(row, "\r\n"), "row %d must not contain a line break: %q", i, row)
	}
	testing.expect_value(t, breaks, 0)
}

@(test)
test_station_block_clamps_multi_byte_status_on_a_rune_boundary :: proc(t: ^testing.T) {
	// 4 bytes per rune, so the byte clamp must stop before a rune that would
	// straddle STATION_STATUS_MAX.
	long := strings.repeat("\u00e9\u00e9", STATION_STATUS_MAX, context.temp_allocator)
	lines := station_block_lines(0, 0, true, long)
	testing.expect(t, len(lines[3]) <= STATION_STATUS_MAX, "clamp must not exceed the byte cap")
	for r in lines[3] {
		testing.expect(t, r != '\uFFFD', "clamp must not cut a rune in half")
	}
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
