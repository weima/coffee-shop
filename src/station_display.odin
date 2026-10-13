package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:terminal"
import "core:terminal/ansi"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

STATION_FRAME_INTERVAL :: 150 * time.Millisecond
// Leave one column empty so the status row cannot autowrap in the supported 80-column pane.
STATION_STATUS_MAX :: 79
STATION_TRACK :: 40 // columns the cat walks across
STATION_SPRITE_WIDTH :: 13
STATION_CAT_ROWS :: 3 // ears, face with mug, legs
STATION_BLOCK_ROWS :: 4 // the cat rows plus the status

// Each row is drawn in place, so the block never scrolls; the cat art is static and
// only turns around.

// The supplied art, exactly as given, each line padded to STATION_SPRITE_WIDTH.
STATION_CAT_RIGHT := [STATION_CAT_ROWS]string{"     /\\_/\\   ", "  ___( o.o)  ", " /   >  ^  > "}
// Each padded right line reversed with / and \, ( and ), and < and > swapped, so
// the two cats mirror in place at the same columns.
STATION_CAT_LEFT := [STATION_CAT_ROWS]string{"   /\\_/\\     ", "  (o.o )___  ", " <  ^  <   \\ "}

// The cat is one sprite: both facings, the rows the block is built from, and the
// position it sits at. The block's height is len(rows) and nothing else; the draw, the
// clear and every cursor movement read it through station_sprite_row_count, so the rows
// written, the rows erased and the cursor advance cannot disagree.
Station_Sprite :: struct {
	left:    [STATION_CAT_ROWS]string,
	right:   [STATION_CAT_ROWS]string,
	rows:    [STATION_BLOCK_ROWS]string,
	x:       int,
	on_pane: bool, // the rows are written below the permanent output right now
}

station_sprite_new :: proc() -> Station_Sprite {
	return {left = STATION_CAT_LEFT, right = STATION_CAT_RIGHT}
}

// The one place the block's height comes from.
station_sprite_row_count :: proc(sprite: ^Station_Sprite) -> int {
	return len(sprite.rows)
}

// The one place the cursor's vertical step over the block comes from, so a draw and the
// clear that follows it can never move by different amounts.
station_sprite_cursor_up :: proc(sprite: ^Station_Sprite) -> string {
	return fmt.tprintf("\x1b[%dA", station_sprite_row_count(sprite))
}

// Moving the sprite changes its position; the pad is derived from that one value when a
// row is written, so the rows cannot drift apart from each other.
station_sprite_move :: proc(sprite: ^Station_Sprite, x: int) {
	sprite.x = x
}

// Composes the block's rows from one facing and the current status.
station_sprite_face :: proc(sprite: ^Station_Sprite, facing_right: bool, status: string) {
	facing := sprite.right if facing_right else sprite.left
	for row, i in facing {
		sprite.rows[i] = row
	}
	sprite.rows[STATION_CAT_ROWS] = station_row_text(status)
}

// One row of the block, indented to the sprite's position. The cat rows share the
// sprite's pad; the status row is a line of its own and stays flush left.
station_sprite_text :: proc(sprite: ^Station_Sprite, row: int) -> string {
	if row >= STATION_CAT_ROWS {
		return sprite.rows[row]
	}
	return fmt.tprintf("%s%s", strings.repeat(" ", sprite.x, context.temp_allocator), sprite.rows[row])
}

// Writes every row of the block and records that it is on the pane. The row count is
// read once, from the sprite.
station_sprite_draw :: proc(sprite: ^Station_Sprite) {
	for row in 0 ..< station_sprite_row_count(sprite) {
		style := ansi.FG_YELLOW if row < STATION_CAT_ROWS else ansi.FAINT
		fmt.printf("\r\x1b[2K%s\n", station_style(style, station_sprite_text(sprite, row)))
	}
	sprite.on_pane = true
}

// Erases exactly the rows station_sprite_draw wrote, using the same count.
station_sprite_clear :: proc(sprite: ^Station_Sprite) {
	if !sprite.on_pane {
		return
	}
	for _ in 0 ..< station_sprite_row_count(sprite) {
		fmt.print("\r\x1b[2K\n")
	}
	sprite.on_pane = false
}

// One block of lines at the bottom of the pane, animated while the agent works.
// Permanent lines (replies, questions, the final text) print above it. When stdout
// is not a terminal, nothing is animated and only permanent lines appear.
// Escape codes are added only when stdout is a terminal.
station_styles_on: bool

Station_Display :: struct {
	mutex:   sync.Mutex,
	live:    bool,
	running: bool,
	status:          string,
	turn_count:      int,
	tool_count:      int,
	active_tool_count: int,
	animation_thread: ^thread.Thread,
	started_at_ns:   i64,
	sprite:          Station_Sprite,
	dir:             int,
}

// Starts the display. When it is live, the screen is cleared and a header names the
// Shot, so the pane shows the Station rather than the command that started it.
station_display_start :: proc(display: ^Station_Display, title: string) {
	display.live = terminal.is_terminal(os.stdout)
	station_styles_on = display.live
	display.running = true
	display.dir = 1
	display.started_at_ns = time.now()._nsec
	display.status = strings.clone("thinking")
	display.sprite = station_sprite_new()
	if display.live {
		fmt.print(ansi.CSI + "2" + ansi.ED + ansi.CSI + ansi.CUP)
		fmt.println(station_style(ansi.BOLD + ";" + ansi.FG_CYAN, title))
		fmt.println(station_style(ansi.FAINT, "────────────────────────────────────────"))
		display.animation_thread = thread.create_and_start_with_data(display, station_display_animate, self_cleanup = false)
	}
}

// Wraps text in an SGR style. Plain text is returned unchanged when the display is
// not live, so logs and tests never see escape codes.
station_style :: proc(code, text: string) -> string {
	if !station_styles_on {
		return text
	}
	return fmt.tprintf("%s%s%s%s%s%s%s", ansi.CSI, code, ansi.SGR, text, ansi.CSI, ansi.RESET, ansi.SGR)
}

station_display_animate :: proc(data: rawptr) {
	display := (^Station_Display)(data)
	for {
		time.sleep(STATION_FRAME_INTERVAL)
		sync.mutex_lock(&display.mutex)
		if !display.running {
			sync.mutex_unlock(&display.mutex)
			return
		}
		station_display_advance_locked(display)
		station_display_draw_locked(display)
		sync.mutex_unlock(&display.mutex)
	}
}

station_display_advance_locked :: proc(display: ^Station_Display) {
	x := display.sprite.x + display.dir
	if x <= 0 {
		x = 0
		display.dir = 1
	}
	if x >= STATION_TRACK - STATION_SPRITE_WIDTH {
		x = STATION_TRACK - STATION_SPRITE_WIDTH
		display.dir = -1
	}
	station_sprite_move(&display.sprite, x)
}

// Moves the cursor back over the rows the last frame wrote, then rewrites the whole
// sprite. The rows to move back over are read from the sprite, so a frame can never
// leave a row of the previous frame behind.
station_display_draw_locked :: proc(display: ^Station_Display) {
	if !display.live {
		return
	}
	if display.sprite.on_pane {
		fmt.print(station_sprite_cursor_up(&display.sprite))
	}
	status := station_display_status_line(display, time.now()._nsec)
	station_sprite_face(&display.sprite, display.dir > 0, status)
	station_sprite_draw(&display.sprite)
	delete(status)
}

// Erases the block and leaves the cursor at its top row, ready for a permanent line.
station_display_clear_locked :: proc(display: ^Station_Display) {
	if !display.live || !display.sprite.on_pane {
		return
	}
	up := station_sprite_cursor_up(&display.sprite)
	fmt.print(up)
	station_sprite_clear(&display.sprite)
	fmt.print(up)
}

// A drawn row must be exactly one terminal line. Tool descriptions are shell
// commands, so a status can carry CR or LF; left in, one raw row would become
// several visual lines, the block would grow past STATION_BLOCK_ROWS, and the
// cursor arithmetic would stop erasing the top row. Clamping stops on a rune
// boundary so a multi-byte rune is never cut in half.
station_row_text :: proc(text: string) -> string {
	if len(text) <= STATION_STATUS_MAX && !strings.contains_any(text, "\r\n") {
		return text
	}
	clean := strings.builder_make(context.temp_allocator)
	for offset := 0; offset < len(text); {
		r, size := utf8.decode_rune_in_string(text[offset:])
		offset += size
		if r == '\r' || r == '\n' {
			continue
		}
		if len(clean.buf) + utf8.rune_size(r) > STATION_STATUS_MAX {
			break
		}
		strings.write_rune(&clean, r)
	}
	return strings.to_string(clean)
}

station_display_status_line :: proc(display: ^Station_Display, now_ns: i64) -> string {
	elapsed := station_elapsed_label(display.started_at_ns, now_ns)
	defer delete(elapsed)
	return fmt.aprintf("%s · turn %d · %d tools · %s", display.status, display.turn_count, display.tool_count, elapsed)
}

station_elapsed_label :: proc(started_at_ns, now_ns: i64) -> string {
	return activity_duration_label(activity_age_seconds(now_ns, started_at_ns))
}

station_display_status :: proc(display: ^Station_Display, text: string) {
	sync.mutex_lock(&display.mutex)
	defer sync.mutex_unlock(&display.mutex)
	delete(display.status)
	display.status = strings.clone(text)
}

station_display_progress :: proc(display: ^Station_Display, event_type, step: string) {
	sync.mutex_lock(&display.mutex)
	defer sync.mutex_unlock(&display.mutex)
	switch event_type {
	case "turn_start":
		display.turn_count += 1
		display.active_tool_count = 0
		delete(display.status)
		display.status = strings.clone("thinking")
	case "tool_execution_start":
		display.tool_count += 1
		display.active_tool_count += 1
		delete(display.status)
		display.status = strings.clone(step)
	case "tool_execution_end":
		if display.active_tool_count > 0 {
			display.active_tool_count -= 1
		}
		if display.active_tool_count == 0 {
			delete(display.status)
			display.status = strings.clone("thinking")
		}
	case "message_update":
		if display.active_tool_count == 0 {
			delete(display.status)
			display.status = strings.clone("thinking")
		}
	}
}

// Prints a permanent line above the block, then draws the block again below it.
station_display_line :: proc(display: ^Station_Display, text: string) {
	sync.mutex_lock(&display.mutex)
	defer sync.mutex_unlock(&display.mutex)
	station_display_clear_locked(display)
	fmt.println(text)
	station_display_draw_locked(display)
}

station_display_stop :: proc(display: ^Station_Display) {
	sync.mutex_lock(&display.mutex)
	display.running = false
	station_display_clear_locked(display)
	sync.mutex_unlock(&display.mutex)

	if display.animation_thread != nil {
		thread.join(display.animation_thread)
		thread.destroy(display.animation_thread)
		display.animation_thread = nil
	}
	delete(display.status)
}
