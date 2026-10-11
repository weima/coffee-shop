package main

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

HOST_HISTORY_FILE_NAME :: "history.ndjson"
HOST_UNFINISHED_REASON :: "host restarted or the Station is not confirmed alive"

Host_Session_Snapshot :: struct {
	request_id: string `json:"request_id"`,
	events:     [dynamic]Host_Event `json:"events"`,
	unfinished: bool `json:"unfinished"`,
	reason:     string `json:"reason,omitempty"`,
}

Host_Sessions_Event :: struct {
	type:     string `json:"type"`,
	sessions: [dynamic]Host_Session_Snapshot `json:"sessions"`,
}

host_history_event :: proc(event: Host_Event) -> bool {
	switch event.type {
	case "dispatch_accepted", "session_started", "session_failed", "station_report", "reply_sent":
		return true
	}
	return false
}

host_history_path :: proc(request_id: string, allocator := context.temp_allocator) -> string {
	request_dir, _ := filepath.join({host_history_root, request_id}, allocator)
	return state_file_path(request_dir, HOST_HISTORY_FILE_NAME, allocator)
}

// The caller holds host_output_mutex. sync makes the record durable before its
// corresponding event is acknowledged on stdout.
host_history_append :: proc(event: Host_Event, data: []byte) -> bool {
	if host_history_root == "" || !valid_shot_id(event.request_id) {
		return false
	}
	request_dir, join_err := filepath.join({host_history_root, event.request_id}, context.temp_allocator)
	if join_err != nil {
		return false
	}
	if !os.is_directory(request_dir) && os.make_directory_all(request_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return false
	}
	path := host_history_path(event.request_id)
	line := make([]byte, len(data)+1, context.temp_allocator)
	copy(line, data)
	line[len(data)] = '\n'
	return write_all_to_file(path, line, os.O_WRONLY|os.O_APPEND|os.O_CREATE).kind == .None
}

host_history_contains :: proc(values: []string, value: string) -> bool {
	for candidate in values {
		if candidate == value {
			return true
		}
	}
	return false
}

host_history_read_session :: proc(request_id: string) -> Host_Session_Snapshot {
	snapshot := Host_Session_Snapshot{
		request_id = request_id,
		events = make([dynamic]Host_Event, 0, context.temp_allocator),
	}
	path := host_history_path(request_id)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		snapshot.unfinished = true
		snapshot.reason = HOST_UNFINISHED_REASON
		return snapshot
	}

	started: [dynamic]string
	started.allocator = context.temp_allocator
	exited: [dynamic]string
	exited.allocator = context.temp_allocator
	has_dispatch := false
	has_failure := false
	remaining := string(data)
	for line in strings.split_lines_iterator(&remaining) {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		event: Host_Event
		if json.unmarshal_string(trimmed, &event, .JSON, context.temp_allocator) != nil ||
			event.request_id != request_id || !host_history_event(event) {
			continue
		}
		append(&snapshot.events, event)
		switch event.type {
		case "dispatch_accepted":
			has_dispatch = true
		case "session_failed":
			has_failure = true
		case "session_started":
			if event.shot_id != "" && !host_history_contains(started[:], event.shot_id) {
				append(&started, event.shot_id)
			}
		case "station_report":
			if event.kind == "agent_exited" && event.shot_id != "" && !host_history_contains(exited[:], event.shot_id) {
				append(&exited, event.shot_id)
			}
		}
	}
	delete(data, context.temp_allocator)

	if len(started) == 0 {
		snapshot.unfinished = has_dispatch && !has_failure
	} else {
		for shot_id in started {
			if !host_history_contains(exited[:], shot_id) {
				snapshot.unfinished = true
				break
			}
		}
	}
	if snapshot.unfinished {
		snapshot.reason = HOST_UNFINISHED_REASON
	}
	delete(started)
	delete(exited)
	return snapshot
}

host_list_sessions :: proc() {
	response := Host_Sessions_Event{
		type = "sessions",
		sessions = make([dynamic]Host_Session_Snapshot, 0, context.temp_allocator),
	}
	ids: [dynamic]string
	ids.allocator = context.temp_allocator
	if host_history_root != "" {
		entries, read_err := os.read_all_directory_by_path(host_history_root, context.temp_allocator)
		if read_err == nil {
			defer os.file_info_slice_delete(entries, context.temp_allocator)
			for entry in entries {
				if entry.type != .Directory || !valid_shot_id(entry.name) {
					continue
				}
				path := host_history_path(entry.name)
				if os.exists(path) {
					append(&ids, entry.name)
				}
			}
		}
	}
	slice.sort(ids[:])
	for request_id in ids {
		append(&response.sessions, host_history_read_session(request_id))
	}
	delete(ids)

	data, marshal_err := json.marshal(response, json.Marshal_Options{spec = .JSON}, context.temp_allocator)
	if marshal_err == nil {
		host_write_line(string(data))
	} else {
		host_write_line(`{"type":"error","reason":"could not read session history"}`)
	}
}
