package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:terminal"
import "core:terminal/ansi"
import "core:thread"
import "core:time"

STATION_FRAME_INTERVAL :: 150 * time.Millisecond
STATION_STATUS_MAX :: 48
STATION_TRACK :: 40 // columns the cat walks across
STATION_SPRITE_WIDTH :: 11
STATION_BLOCK_ROWS :: 5 // steam, ears, face with mug, legs, status

// Each row is drawn in place, so the block never scrolls. Steam and legs alternate
// between two frames, so the cat appears to walk and the coffee to steam.
STATION_STEAM_RIGHT := [2]string{"       ~ ~", "      ~ ~ "}
STATION_STEAM_LEFT := [2]string{" ~ ~", "~ ~"}
STATION_LEGS_RIGHT := [2]string{" /    \\", " \\    /"}
STATION_LEGS_LEFT := [2]string{"    /   \\", "    \\   /"}

// One block of lines at the bottom of the pane, animated while the agent works.
// Permanent lines (replies, questions, the final text) print above it. When stdout
// is not a terminal, nothing is animated and only permanent lines appear.
// Escape codes are added only when stdout is a terminal.
station_styles_on: bool

Station_Display :: struct {
	mutex:   sync.Mutex,
	live:    bool,
	running: bool,
	status:  string,
	x:       int,
	dir:     int,
	step:    int,
	drawn:   int,
}

// Starts the display. When it is live, the screen is cleared and a header names the
// Shot, so the pane shows the Station rather than the command that started it.
station_display_start :: proc(display: ^Station_Display, title: string) {
	display.live = terminal.is_terminal(os.stdout)
	station_styles_on = display.live
	display.running = true
	display.dir = 1
	display.status = strings.clone("Starting")
	if display.live {
		fmt.print(ansi.CSI + "2" + ansi.ED + ansi.CSI + ansi.CUP)
		fmt.println(station_style(ansi.BOLD + ";" + ansi.FG_CYAN, title))
		fmt.println(station_style(ansi.FAINT, "────────────────────────────────────────"))
		_ = thread.create_and_start_with_data(display, station_display_animate, self_cleanup = true)
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
	display.x += display.dir
	if display.x <= 0 {
		display.x = 0
		display.dir = 1
	}
	if display.x >= STATION_TRACK - STATION_SPRITE_WIDTH {
		display.x = STATION_TRACK - STATION_SPRITE_WIDTH
		display.dir = -1
	}
	display.step += 1
}

// Moves the cursor back to the top of the block, then rewrites every row.
station_display_draw_locked :: proc(display: ^Station_Display) {
	if !display.live {
		return
	}
	if display.drawn > 0 {
		fmt.printf("\x1b[%dA", display.drawn)
	}
	lines := station_block_lines(display.x, display.step, display.dir > 0, display.status)
	// Steam is faint, the cat yellow, and the status label faint again.
	styles := [STATION_BLOCK_ROWS]string{ansi.FAINT, ansi.FG_YELLOW, ansi.FG_YELLOW, ansi.FG_YELLOW, ansi.FAINT}
	for line, i in lines {
		fmt.printf("\r\x1b[2K%s\n", station_style(styles[i], line))
	}
	display.drawn = STATION_BLOCK_ROWS
}

// Erases the block and leaves the cursor at its top row, ready for a permanent line.
station_display_clear_locked :: proc(display: ^Station_Display) {
	if !display.live || display.drawn == 0 {
		return
	}
	fmt.printf("\x1b[%dA", display.drawn)
	for _ in 0 ..< display.drawn {
		fmt.print("\r\x1b[2K\n")
	}
	fmt.printf("\x1b[%dA", display.drawn)
	display.drawn = 0
}

station_block_lines :: proc(x, step: int, facing_right: bool, status: string) -> [STATION_BLOCK_ROWS]string {
	pad := strings.repeat(" ", x, context.temp_allocator)
	text := status
	if len(text) > STATION_STATUS_MAX {
		text = text[:STATION_STATUS_MAX]
	}
	lines: [STATION_BLOCK_ROWS]string
	if facing_right {
		lines[0] = fmt.tprintf("%s%s", pad, STATION_STEAM_RIGHT[(step / 2) % 2])
		lines[1] = fmt.tprintf("%s /\\_/\\", pad)
		lines[2] = fmt.tprintf("%s( o.o )[_]", pad)
		lines[3] = fmt.tprintf("%s%s", pad, STATION_LEGS_RIGHT[step % 2])
	} else {
		lines[0] = fmt.tprintf("%s%s", pad, STATION_STEAM_LEFT[(step / 2) % 2])
		lines[1] = fmt.tprintf("%s     /\\_/\\", pad)
		lines[2] = fmt.tprintf("%s[_] ( o.o )", pad)
		lines[3] = fmt.tprintf("%s%s", pad, STATION_LEGS_LEFT[step % 2])
	}
	lines[4] = text
	return lines
}

station_display_status :: proc(display: ^Station_Display, text: string) {
	sync.mutex_lock(&display.mutex)
	defer sync.mutex_unlock(&display.mutex)
	delete(display.status)
	display.status = strings.clone(text)
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
	defer sync.mutex_unlock(&display.mutex)
	display.running = false
	station_display_clear_locked(display)
}
