package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_parse_status_argument :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"status", "brew-123"})

	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Status)
	testing.expect_value(t, parsed.brew_id, "brew-123")
}

@(test)
test_rejects_status_without_brew_id :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"status"})

	testing.expect(t, err != "")
}

@(test)
test_rejects_unknown_command :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"something-else"})

	testing.expect(t, err != "")
}

@(test)
test_parses_help :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"--help"})

	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Help)
}

@(test)
test_parse_status_stations_flag :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"status", "--stations"})
	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Status)
	testing.expect(t, parsed.stations)
}

@(test)
test_parse_log_arguments :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"log", "req-1", "shot-a", "--tail", "20"})
	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Log)
	testing.expect_value(t, parsed.brew_id, "req-1")
	testing.expect_value(t, parsed.shot_id, "shot-a")
	testing.expect_value(t, parsed.tail, 20)
	_, both := parse_args([]string{"log", "r", "s", "--cat", "--tail", "3"})
	testing.expect(t, both != "")
	_, missing := parse_args([]string{"log", "r"})
	testing.expect(t, missing != "")
}

@(test)
test_parse_reply_arguments :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"reply", "req-1", "shot-a", "yes, go ahead", "--print"})
	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Reply)
	testing.expect_value(t, parsed.message, "yes, go ahead")
	testing.expect(t, parsed.print_only)
	_, missing := parse_args([]string{"reply", "req-1", "shot-a"})
	testing.expect(t, missing != "")
}

@(test)
test_parse_host_has_one_implementation :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"host"})

	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Host)
}

@(test)
test_rejects_a_host_implementation_flag :: proc(t: ^testing.T) {
	// There is one host; a caller asking for another one must be told, not ignored.
	_, err := parse_args([]string{"host", "--impl=odin"})

	testing.expect(t, err != "", "a retired --impl must be refused")
}

@(test)
test_resolve_go_host_prefers_cs_csd :: proc(t: ^testing.T) {
	path, found := resolve_go_host("/bin/sh", "/embedded/csd", "/nowhere")

	testing.expect(t, found)
	testing.expect_value(t, path, "/bin/sh")
	_, missing := resolve_go_host("/nowhere/csd", "/embedded/csd", "/bin")
	testing.expect(t, !missing)
}

@(test)
test_resolve_go_host_finds_csd_on_path :: proc(t: ^testing.T) {
	directory, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-go-host-*", context.allocator)
	defer os.remove_all(directory)
	defer delete(directory, context.allocator)
	testing.expect(t, make_err == nil)
	csd, _ := filepath.join({directory, GO_HOST_NAME}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(csd, "go host") == nil)

	path, found := resolve_go_host("", "", fmt.tprintf("/nowhere:%s", directory))
	testing.expect(t, found)
	testing.expect_value(t, path, csd)
	_, embedded := resolve_go_host("", csd, fmt.tprintf("/nowhere:%s", directory))
	testing.expect(t, embedded)
	_, empty := resolve_go_host("", "", "")
	testing.expect(t, !empty)
}

@(test)
test_run_host_go_reports_a_missing_csd_and_exits_one :: proc(t: ^testing.T) {
	testing.expect(t, run_host_go("", "/nowhere") == 1)
	testing.expect(t, strings.contains(GO_HOST_MISSING, "CS_CSD"))
	testing.expect(t, strings.contains(GO_HOST_MISSING, GO_HOST_NAME))
}
