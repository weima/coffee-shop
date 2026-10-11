package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

STATION_FRAME_INTERVAL :: 200 * time.Millisecond
STATION_STATUS_MAX :: 48

// A cat peeks over a cup while the steam rises. One line, redrawn in place.
STATION_FRAMES := [4]string{
	"=^.^=  ~    [_]",
	"=^.^=  ~~   [_]",
	"=^.^=  ~~~  [_]",
	"=^-^=  ~~~~ [_]",
}

// One status line at the bottom of the pane, animated while the agent works.
// Permanent lines (replies, questions, final text) are printed above it. When
// stdout is not a terminal, nothing is animated and only permanent lines appear.
Station_Display :: struct {
	mutex:   sync.Mutex,
	live:    bool,
	running: bool,
	status:  string,
	frame:   int,
	drawn:   bool,
}

station_display_start :: proc(display: ^Station_Display) {
	display.live = bool(posix.isatty(posix.STDOUT_FILENO))
	display.running = true
	display.status = strings.clone("Starting")
	if display.live {
		_ = thread.create_and_start_with_data(display, station_display_animate, self_cleanup = true)
	}
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
		station_display_draw_locked(display)
		sync.mutex_unlock(&display.mutex)
	}
}

station_display_draw_locked :: proc(display: ^Station_Display) {
	if !display.live {
		return
	}
	fmt.print(station_frame_line(display.frame, display.status))
	display.frame += 1
	display.drawn = true
}

// The line is erased with an ANSI clear before each redraw, so it never scrolls.
station_frame_line :: proc(frame: int, status: string) -> string {
	text := status
	if len(text) > STATION_STATUS_MAX {
		text = text[:STATION_STATUS_MAX]
	}
	return fmt.tprintf("\r\x1b[2K%s  %s", STATION_FRAMES[frame % len(STATION_FRAMES)], text)
}

station_display_status :: proc(display: ^Station_Display, text: string) {
	sync.mutex_lock(&display.mutex)
	defer sync.mutex_unlock(&display.mutex)
	delete(display.status)
	display.status = strings.clone(text)
}

// Prints a permanent line above the status line, then draws the status again.
station_display_line :: proc(display: ^Station_Display, text: string) {
	sync.mutex_lock(&display.mutex)
	defer sync.mutex_unlock(&display.mutex)
	if display.live && display.drawn {
		fmt.print("\r\x1b[2K")
		display.drawn = false
	}
	fmt.println(text)
	station_display_draw_locked(display)
}

station_display_stop :: proc(display: ^Station_Display) {
	sync.mutex_lock(&display.mutex)
	defer sync.mutex_unlock(&display.mutex)
	display.running = false
	if display.live && display.drawn {
		fmt.print("\r\x1b[2K")
		display.drawn = false
	}
}
