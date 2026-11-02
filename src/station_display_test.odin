package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
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

// Serializes the tests that swap os.stdout, so one capture cannot steal the stream while
// another test's draw is running.
capture_lock: sync.Mutex

// Captures what a whole-sprite operation writes by pointing the display's own sink at a
// temp file. It must not swap os.stdout: that is process-wide, so another test's print
// would land inside the capture and the exact-byte assertions would fail under load. The
// cursor arithmetic is only real in the bytes, so a test reads those rather than trusting
// bookkeeping with no production reader. The caller owns the returned bytes.
capture_display_op :: proc(t: ^testing.T, display: ^Station_Display, label: string, clear: bool) -> []u8 {
	sync.mutex_lock(&capture_lock)
	defer sync.mutex_unlock(&capture_lock)

	dir, dir_err := os.temp_directory(context.temp_allocator)
	base := dir if dir_err == nil else "/tmp"
	name := fmt.aprintf("%s/station-sprite-%d-%s.txt", base, os.get_pid(), label)
	defer delete(name)
	out, create_err := os.create(name)
	if create_err != nil {
		testing.fail(t)
		return nil
	}
	defer os.close(out)
	defer os.remove(name)

	old := display_output
	display_output = out
	if clear {
		station_display_clear_locked(display)
	} else {
		station_display_draw_locked(display)
	}
	display_output = old

	os.seek(out, 0, .Start)
	data, read_err := os.read_entire_file_from_file(out, context.allocator)
	if read_err != nil {
		testing.fail(t)
		return nil
	}
	return data
}

// A capture must go through the display's own sink and leave it as it found it. Swapping
// os.stdout also captured every other test's output, which is how this file's exact-byte
// assertions failed under a ten-thread suite: a foreign print landed between the swap and
// the read.
@(test)
test_capture_uses_the_display_sink_and_restores_it :: proc(t: ^testing.T) {
	display := Station_Display{live = true}
	display.sprite = station_sprite_new()
	station_display_draw_locked(&display)

	before := display_output
	data := capture_display_op(t, &display, "sink", false)
	defer delete(data)
	testing.expect_value(t, display_output, before)
	testing.expect(t, len(data) > 0, "the capture must return the display's bytes")
}

// The rows each "\x1b[<n>A" cursor-up escape in text moves over. Erase and SGR
// sequences share the "\x1b[" prefix, so the final byte decides.
cursor_up_counts :: proc(text: string) -> [dynamic]int {
	counts := make([dynamic]int, context.temp_allocator)
	for i := 0; i + 2 < len(text); i += 1 {
		if text[i] != 0x1b || text[i + 1] != '[' {
			continue
		}
		n := 0
		j := i + 2
		for j < len(text) && text[j] >= '0' && text[j] <= '9' {
			n = n * 10 + int(text[j] - '0')
			j += 1
		}
		if j > i + 2 && j < len(text) && text[j] == 'A' {
			append(&counts, n)
		}
	}
	return counts
}

@(test)
test_station_sprite_matches_the_supplied_cat_and_its_mirror :: proc(t: ^testing.T) {
	// The supplied art, byte for byte, padded to STATION_SPRITE_WIDTH.
	want_right := [STATION_CAT_ROWS]string{"     /\\_/\\   ", "  ___( o.o)  ", " /   >  ^  > "}
	sprite := station_sprite_new()
	station_sprite_face(&sprite, true, "")
	for line, i in want_right {
		testing.expect_value(t, len(line), STATION_SPRITE_WIDTH)
		testing.expect_value(t, station_sprite_text(&sprite, i), line)
	}
	station_sprite_face(&sprite, false, "")
	for line, i in want_right {
		// The left-facing line must be the true mirror, so editing one side and
		// forgetting the other fails here rather than shifting the cat.
		testing.expect_value(t, station_sprite_text(&sprite, i), mirror_sprite_row(line))
		testing.expect_value(t, len(mirror_sprite_row(line)), STATION_SPRITE_WIDTH)
		testing.expect(t, station_sprite_text(&sprite, i) != line, "directions should differ")
	}
}

@(test)
test_station_sprite_pads_from_its_position :: proc(t: ^testing.T) {
	sprite := station_sprite_new()
	station_sprite_face(&sprite, true, "Running tool: read")
	station_sprite_move(&sprite, 5)
	want_ears := "     /\\_/\\   " // the supplied ears row, padded to STATION_SPRITE_WIDTH
	testing.expect_value(t, station_sprite_text(&sprite, 0), fmt.tprintf("     %s", want_ears))
	testing.expect_value(t, station_sprite_text(&sprite, STATION_CAT_ROWS), "Running tool: read")

	// The pad is the sprite's position, not each row's own state: moving changes the one
	// value, every cat row picks up the new pad, and the composed rows are untouched.
	before := sprite.rows
	station_sprite_move(&sprite, 9)
	testing.expect_value(t, sprite.rows, before)
	for row in 0 ..< STATION_CAT_ROWS {
		testing.expect_value(t, station_sprite_text(&sprite, row), fmt.tprintf("         %s", STATION_CAT_RIGHT[row]))
	}
}

@(test)
test_station_sprite_draw_and_clear_move_the_same_rows :: proc(t: ^testing.T) {
	display := Station_Display{live = true}
	display.sprite = station_sprite_new()
	// One frame on the pane, so the next draw has rows to step back over.
	station_display_draw_locked(&display)

	draw_data := capture_display_op(t, &display, "drawn", false)
	defer delete(draw_data)
	draw_text := string(draw_data)
	draw_moves := cursor_up_counts(draw_text)
	testing.expect_value(t, len(draw_moves), 1)
	testing.expect_value(t, draw_moves[0], station_sprite_row_count(&display.sprite))

	clear_data := capture_display_op(t, &display, "cleared", true)
	defer delete(clear_data)
	clear_moves := cursor_up_counts(string(clear_data))
	// The clear steps back over the block before erasing it, then steps back again to
	// leave the cursor where the next permanent line goes. Both steps are the draw's.
	testing.expect_value(t, len(clear_moves), 2)
	// Exact bytes: step up, erase every row, step up again. A draw emitted in place of
	// the clear (or the reverse) cannot match.
	up := fmt.tprintf("\x1b[%dA", station_sprite_row_count(&display.sprite))
	erase := strings.repeat("\r\x1b[2K\n", station_sprite_row_count(&display.sprite), context.temp_allocator)
	testing.expect_value(t, string(clear_data), fmt.tprintf("%s%s%s", up, erase, up))
	testing.expect(t, !strings.has_suffix(draw_text, erase), "a draw must not end with the clear's erase rows")
	testing.expect_value(t, clear_moves[0], draw_moves[0])
	testing.expect_value(t, clear_moves[1], draw_moves[0])
	testing.expect(t, !display.sprite.on_pane, "the clear must record that the rows are gone")
}

@(test)
test_station_sprite_facings_share_one_row_count :: proc(t: ^testing.T) {
	right := Station_Display{live = true, dir = 1}
	right.sprite = station_sprite_new()
	station_display_draw_locked(&right)
	right_data := capture_display_op(t, &right, "facing-right", false)
	defer delete(right_data)
	right_text := string(right_data)

	left := Station_Display{live = true, dir = -1}
	left.sprite = station_sprite_new()
	station_display_draw_locked(&left)
	left_data := capture_display_op(t, &left, "facing-left", false)
	defer delete(left_data)
	left_text := string(left_data)

	testing.expect_value(t, station_sprite_row_count(&left.sprite), station_sprite_row_count(&right.sprite))
	testing.expect_value(t, station_sprite_row_count(&right.sprite), STATION_BLOCK_ROWS)
	right_moves := cursor_up_counts(right_text)
	left_moves := cursor_up_counts(left_text)
	testing.expect_value(t, left_moves[0], right_moves[0])
	// The same count and the same advance, but the two mirrored cats are different art.
	testing.expect(t, strings.contains(right_text, "( o.o)"), "the right frame must carry the right cat")
	testing.expect(t, strings.contains(left_text, "(o.o )"), "the left frame must carry the left cat")
}

@(test)
test_station_sprite_truncates_long_status :: proc(t: ^testing.T) {
	long := strings.repeat("x", STATION_STATUS_MAX + 20, context.temp_allocator)
	sprite := station_sprite_new()
	station_sprite_face(&sprite, true, long)
	testing.expect_value(t, len(sprite.rows[STATION_CAT_ROWS]), STATION_STATUS_MAX)
}

@(test)
test_station_sprite_strips_line_breaks_from_status :: proc(t: ^testing.T) {
	sprite := station_sprite_new()
	station_sprite_face(&sprite, true, "one\ntwo\rthree")
	testing.expect_value(t, sprite.rows[STATION_CAT_ROWS], "onetwothree")
	// No row carries CR or LF, so the four rows written with a `\n` between them stay
	// exactly STATION_BLOCK_ROWS visual rows.
	for row, i in sprite.rows {
		testing.expectf(t, !strings.contains_any(row, "\r\n"), "row %d must not contain a line break: %q", i, row)
	}
}

@(test)
test_station_sprite_clamps_multi_byte_status_on_a_rune_boundary :: proc(t: ^testing.T) {
	// 4 bytes per rune, so the byte clamp must stop before a rune that would
	// straddle STATION_STATUS_MAX.
	long := strings.repeat("\u00e9\u00e9", STATION_STATUS_MAX, context.temp_allocator)
	sprite := station_sprite_new()
	station_sprite_face(&sprite, true, long)
	status := sprite.rows[STATION_CAT_ROWS]
	testing.expect(t, len(status) <= STATION_STATUS_MAX, "clamp must not exceed the byte cap")
	for r in status {
		testing.expect(t, r != '\uFFFD', "clamp must not cut a rune in half")
	}
}

@(test)
test_station_display_frames_are_bounded_and_clear_the_sprite :: proc(t: ^testing.T) {
	// Inspect the exact bytes emitted by every frame without an external terminal
	// emulator: each row is cleared before it is rewritten, and the sprite is four
	// rows tall. The existing sprite tests cover the cursor-up and erase contract.
	sync.mutex_lock(&capture_lock)
	defer sync.mutex_unlock(&capture_lock)

	dir, dir_err := os.temp_directory(context.temp_allocator)
	base := dir if dir_err == nil else "/tmp"
	path := fmt.aprintf("%s/station-sprite-frames-%d.bin", base, os.get_pid())
	defer delete(path)
	defer os.remove(path)
	out, create_err := os.create(path)
	testing.expect_value(t, create_err, os.Error(nil))
	if create_err != nil {
		return
	}

	frame_count := 200
	display := Station_Display{live = true, dir = 1, started_at_ns = 1}
	display.sprite = station_sprite_new()
	display.status = strings.clone(strings.repeat("x", STATION_STATUS_MAX, context.temp_allocator))
	defer delete(display.status)
	old_output := display_output
	display_output = out
	station_styles_on = false
	for frame := 0; frame < frame_count; frame += 1 {
		if frame > 0 {
			station_display_advance_locked(&display)
		}
		station_display_draw_locked(&display)
	}
	// Exercise the same whole-sprite clear used when permanent output replaces the
	// animation. Its bytes remain in the exact stream, after the 200 frame proof.
	station_display_clear_locked(&display)
	display_output = old_output
	_ = os.close(out)

	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		testing.fail(t)
		return
	}
	frames := strings.split(string(data), "\x1b[4A", context.temp_allocator)
	// 199 moves between drawn frames, one move before clear, and one after it.
	testing.expect_value(t, len(frames), frame_count+2)
	if len(frames) < frame_count+2 {
		return
	}

	x, step := 0, 1
	for frame_index := 0; frame_index < frame_count; frame_index += 1 {
		frame := frames[frame_index]
		art := STATION_CAT_RIGHT if step > 0 else STATION_CAT_LEFT
		line_start := 0
		for row := 0; row < STATION_BLOCK_ROWS; row += 1 {
			newline := strings.index_byte(frame[line_start:], '\n')
			if newline < 0 {
				testing.fail(t)
				return
			}
			line := frame[line_start : line_start+newline]
			testing.expect(t, strings.has_prefix(line, "\r\x1b[2K"), fmt.tprintf("frame %d row %d must clear before drawing", frame_index, row))
			text := line[len("\r\x1b[2K"):]
			if row < STATION_CAT_ROWS {
				expected := fmt.tprintf("%s%s", strings.repeat(" ", x, context.temp_allocator), art[row])
				testing.expect_value(t, text, expected)
				testing.expect(t, len(text) <= 80, fmt.tprintf("frame %d row %d must fit the terminal", frame_index, row))
			} else {
				testing.expect(t, len(text) <= STATION_STATUS_MAX, fmt.tprintf("frame %d status must fit one terminal row", frame_index))
			}
			line_start += newline + 1
		}
		testing.expect_value(t, line_start, len(frame))
		if frame_index+1 < frame_count {
			x += step
			if x <= 0 {
				x, step = 0, 1
			}
			if x >= STATION_TRACK-STATION_SPRITE_WIDTH {
				x, step = STATION_TRACK-STATION_SPRITE_WIDTH, -1
			}
		}
	}

	expected_clear := strings.repeat("\r\x1b[2K\n", STATION_BLOCK_ROWS, context.temp_allocator)
	testing.expect_value(t, frames[frame_count], expected_clear)
	testing.expect_value(t, frames[frame_count+1], "")
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
	testing.expect_value(t, display.sprite.x, STATION_TRACK - STATION_SPRITE_WIDTH)
	for i := 0; display.dir == -1 && i < 4 * STATION_TRACK; i += 1 {
		station_display_advance_locked(&display)
	}
	testing.expect_value(t, display.dir, 1)
	testing.expect_value(t, display.sprite.x, 0)
}

@(test)
test_station_display_start_turns_auto_wrap_on_first :: proc(t: ^testing.T) {
	seq := station_display_start_sequence()
	testing.expect(t, strings.has_prefix(seq, "\x1b[?7h"), "start must re-enable auto-wrap before anything else")
	testing.expect(t, strings.has_suffix(seq, "\x1b[2J\x1b[H"), "start must then clear and home")
}

@(test)
test_station_row_text_neutralises_control_characters :: proc(t: ^testing.T) {
	testing.expect_value(t, station_row_text("a\tb\x1bc\x7fd\u0085e\x00f"), "abcdef")
	sprite := station_sprite_new()
	station_sprite_face(&sprite, true, "ls\t-l\x08\x1b[2J")
	testing.expect_value(t, sprite.rows[STATION_CAT_ROWS], "ls-l[2J")
}
