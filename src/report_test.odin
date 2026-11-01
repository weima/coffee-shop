package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_headless_no_host_no_log :: proc(t: ^testing.T) {
	root, _ := os.make_directory_temp("", "cs-headless-", context.temp_allocator)
	defer os.remove_all(root)
	testing.expect(t, !host_is_running(root))
	// No host: nothing is listed and nothing is invented.
	testing.expect_value(t, print_stations(root, "", false), 1)
	// A log that does not exist yet has a path but no file.
	path := station_log_path(root, "req-1", "shot-a")
	testing.expect(t, strings.has_suffix(path, "/host/req-1/logs/shot-a.log"))
	testing.expect(t, !os.exists(path))
}

@(test)
test_history_live_stations :: proc(t: ^testing.T) {
	root, _ := os.make_directory_temp("", "cs-headless-", context.temp_allocator)
	defer os.remove_all(root)
	dir := fmt.tprintf("%s/host/req-1", root)
	_ = os.make_directory_all(dir)
	history := `{"type":"session_started","request_id":"req-1","shot_id":"a","pane_id":"p"}
{"type":"session_started","request_id":"req-1","shot_id":"b"}
{"type":"station_report","request_id":"req-1","shot_id":"a","kind":"needs_input"}
{"type":"station_report","request_id":"req-1","shot_id":"b","kind":"agent_exited"}
`
	_ = os.write_entire_file(fmt.tprintf("%s/history.ndjson", dir), history)
	live := history_live_stations(root, "req-1")
	testing.expect_value(t, len(live), 1)
	testing.expect_value(t, live[0].shot_id, "a")
	testing.expect_value(t, live[0].phase, "needs_input")
}

@(test)
test_log_excerpt_and_reply_line :: proc(t: ^testing.T) {
	excerpt, total := log_excerpt("a\nb\nc\n", 2)
	testing.expect_value(t, excerpt, "b\nc")
	testing.expect_value(t, total, 3)
	full, _ := log_excerpt("a\nb\n", 0)
	testing.expect_value(t, full, "a\nb\n")
	line, err := reply_request_line("req-1", "shot-a", "  hi \"x\"  ")
	testing.expect_value(t, err, "")
	testing.expect_value(t, line, `{"type":"reply","request_id":"req-1","shot_id":"shot-a","message":"hi \"x\""}`)
	_, bad := reply_request_line("req-1", "shot-a", "two\nlines")
	testing.expect(t, bad != "")
	_, bad_id := reply_request_line("../x", "s", "hi")
	testing.expect(t, bad_id != "")
}
