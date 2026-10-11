package main

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_station_frame_line_redraws_in_place_and_truncates :: proc(t: ^testing.T) {
	testing.expect_value(t, station_frame_line(0, "Starting"), "\r\x1b[2K=^.^=  ~    [_]  Starting")
	testing.expect_value(t, station_frame_line(4, "Starting"), "\r\x1b[2K=^.^=  ~    [_]  Starting")

	long := strings.repeat("x", STATION_STATUS_MAX + 20, context.temp_allocator)
	line := station_frame_line(3, long)
	prefix := fmt.tprintf("\r\x1b[2K%s  ", STATION_FRAMES[3])
	testing.expect_value(t, len(line), len(prefix) + STATION_STATUS_MAX)
	testing.expect(t, strings.has_prefix(line, prefix), line)
}
