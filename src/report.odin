package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

// `status <request-id>` lists live Stations for a host request. Brew records are
// no longer a supported CLI surface.
run_status :: proc(request_id: string, stations := false) -> int {
	state_root, err := default_state_root()
	if err != "" {
		write_error(err)
		return 2
	}
	defer delete(state_root)
	if stations {
		return print_stations(state_root, "", true)
	}
	if print_stations(state_root, request_id, false) == 0 {
		return 0
	}
	write_error(fmt.tprintf("no live Stations for request %s", request_id))
	return 1
}

// ---- Watching a host run without a pane ------------------------------------
// Station lines are `station request=<id> shot=<id> phase=<kind> [log=<path>]`.
// The log path is shown only when the file exists.

STATION_LOG_SUFFIX :: ".log"
HOST_REPLY_EXIT_UNREACHABLE :: 4
HOST_REPLY_EXIT_REFUSED :: 5

host_dir_of :: proc(state_root: string) -> string {
	dir, _ := filepath.join({state_root, "host"}, context.temp_allocator)
	return dir
}

// A host holds host.lock for its whole life; if the lock cannot be taken, one runs.
host_is_running :: proc(state_root: string) -> bool {
	lock_path := state_file_path(host_dir_of(state_root), HOST_LOCK_FILE_NAME, context.temp_allocator)
	if !os.exists(lock_path) {
		return false
	}
	file, free_to_take := host_acquire_lock(host_dir_of(state_root))
	if free_to_take {
		file_lock_release(file)
	}
	return !free_to_take
}

// <state root>/host/<request>/<shot>.log; the headless backend writes it.
// Where a Station's headless log lives. The headless backend writes exactly this path
// (headless_session_open), so `status --stations` and `log` can find a running Station's
// output without a pane; the headless test asserts the two agree.
station_log_path :: proc(state_root, request_id, shot_id: string) -> string {
	dir, _ := filepath.join({host_dir_of(state_root), request_id, "logs"}, context.temp_allocator)
	return state_file_path(dir, strings.concatenate({shot_id, STATION_LOG_SUFFIX}, context.temp_allocator), context.temp_allocator)
}

Headless_Station :: struct {
	shot_id: string,
	phase:   string,
}

// Stations the history shows started and not yet exited. Strings are temp-allocated.
history_live_stations :: proc(state_root, request_id: string) -> []Headless_Station {
	path, _ := filepath.join({host_dir_of(state_root), request_id, HOST_HISTORY_FILE_NAME}, context.temp_allocator)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	live := make([dynamic]Headless_Station, context.temp_allocator)
	if read_err != nil {
		return live[:]
	}
	remaining := string(data)
	for line in strings.split_lines_iterator(&remaining) {
		event: Host_Event
		if json.unmarshal_string(strings.trim_space(line), &event, .JSON, context.temp_allocator) != nil || event.request_id != request_id {
			continue
		}
		index := -1
		for station, i in live { if station.shot_id == event.shot_id { index = i } }
		switch event.type {
		case "session_started":
			if index < 0 { append(&live, Headless_Station{event.shot_id, "started"}) }
		case "session_failed":
			if index >= 0 { ordered_remove(&live, index) }
		case "station_report":
			if index < 0 { continue }
			if event.kind == "agent_exited" || event.kind == "process_gone" {
				ordered_remove(&live, index)
			} else {
				live[index].phase = event.kind
			}
		}
	}
	return live[:]
}

// Prints live Stations (one request, or all when request_id is empty). Returns 0
// when something was printed, or when `verbose` explains an empty result.
print_stations :: proc(state_root, request_id: string, verbose: bool) -> int {
	defer free_all(context.temp_allocator)
	if !host_is_running(state_root) {
		if verbose { fmt.println("no host running") }
		return 1 if !verbose else 0
	}
	ids := make([dynamic]string, context.temp_allocator)
	if request_id != "" {
		append(&ids, request_id)
	} else if entries, err := os.read_all_directory_by_path(host_dir_of(state_root), context.temp_allocator); err == nil {
		for entry in entries {
			if entry.type == .Directory && valid_shot_id(entry.name) { append(&ids, entry.name) }
		}
		slice.sort(ids[:])
	}
	printed := 0
	for id in ids {
		for station in history_live_stations(state_root, id) {
			fmt.printf("station request=%s shot=%s phase=%s", id, station.shot_id, station.phase)
			if log_path := station_log_path(state_root, id, station.shot_id); os.exists(log_path) {
				fmt.printf(" log=%s", log_path)
			}
			fmt.println()
			printed += 1
		}
	}
	if printed == 0 && verbose { fmt.println("no live stations") }
	return 0 if printed > 0 || verbose else 1
}

// Output lines of `log`: the whole text, or its last `tail` lines.
log_excerpt :: proc(text: string, tail: int) -> (excerpt: string, total: int) {
	trimmed := strings.trim_right(text, "\n")
	lines := strings.split_lines(trimmed, context.temp_allocator)
	total = len(lines) if trimmed != "" else 0
	if tail <= 0 || total <= tail {
		return text, total
	}
	return strings.join(lines[total-tail:], "\n", context.temp_allocator), total
}

run_log :: proc(request_id, shot_id: string, tail: int, dump: bool) -> int {
	defer free_all(context.temp_allocator)
	if !valid_shot_id(request_id) || !valid_shot_id(shot_id) {
		write_error("request and shot ids must be letters, digits, - or _, up to 64")
		return 2
	}
	state_root, err := default_state_root(context.temp_allocator)
	if err != "" {
		write_error(err)
		return 2
	}
	path := station_log_path(state_root, request_id, shot_id)
	fmt.println(path)
	if tail == 0 && !dump {
		return 0
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("no log yet for %s/%s (not created)", request_id, shot_id)
		return 1
	}
	if len(data) == 0 {
		fmt.eprintfln("log for %s/%s exists but is empty so far", request_id, shot_id)
		return 0
	}
	excerpt, total := log_excerpt(string(data), tail)
	if tail > 0 && total > tail {
		fmt.eprintfln("showing last %d of %d lines", tail, total)
	}
	fmt.print(excerpt)
	if !strings.has_suffix(excerpt, "\n") { fmt.println() }
	return 0
}

// The host's routed `reply` request, as the one JSON line it reads on stdin.
reply_request_line :: proc(request_id, shot_id, message: string) -> (line: string, err: string) {
	text := strings.trim_space(message)
	if !valid_shot_id(request_id) || !valid_shot_id(shot_id) {
		return "", "request and shot ids must be letters, digits, - or _, up to 64"
	}
	if text == "" || len(text) > HOST_REPLY_MAX || strings.contains_any(text, "\r\n") {
		return "", "reply must be one non-empty line"
	}
	request := Reply_Request{"reply", request_id, shot_id, text}
	data, marshal_err := json.marshal(request, {}, context.temp_allocator)
	if marshal_err != nil {
		return "", "could not encode the reply"
	}
	return string(data), ""
}

Reply_Request :: struct {
	type:       string `json:"type"`,
	request_id: string `json:"request_id"`,
	shot_id:    string `json:"shot_id"`,
	message:    string `json:"message"`,
}

// Delivers the reply to the running host's request socket (<state>/host/requests.sock).
// Exit 0 delivered; 1 no host running; 4 a host is running but its socket could not
// be reached; 5 the host answered and refused or failed the delivery. --print emits
// the line for a parent to pipe into the host's stdin instead.
run_reply :: proc(request_id, shot_id, message: string, print_only: bool) -> int {
	defer free_all(context.temp_allocator)
	line, line_err := reply_request_line(request_id, shot_id, message)
	if line_err != "" {
		write_error(line_err)
		return 2
	}
	if print_only {
		fmt.println(line)
		return 0
	}
	state_root, err := default_state_root(context.temp_allocator)
	if err != "" {
		write_error(err)
		return 2
	}
	return reply_deliver(state_root, line)
}

reply_deliver :: proc(state_root, line: string) -> int {
	if !host_is_running(state_root) {
		write_error("no host is running; the reply was not sent")
		return 1
	}
	result, reason := host_request_send(host_dir_of(state_root), line)
	switch result {
	case .Delivered:
		return 0
	case .Unreachable:
		write_error(fmt.tprintf("a host is running but its request socket could not be used: %s; the reply was not sent", reason))
		return HOST_REPLY_EXIT_UNREACHABLE
	case .Refused:
		write_error(fmt.tprintf("the host refused the reply: %s", reason))
		return HOST_REPLY_EXIT_REFUSED
	}
	return HOST_REPLY_EXIT_UNREACHABLE
}
