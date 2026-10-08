package main

import "core:encoding/json"
import "core:fmt"
import "core:os"

ACTIVITY_QUIET_AFTER_NS :: i64(12 * 60 * 1_000_000_000)

Activity_Record :: struct {
	kind: string,
	description: string,
	observed_at_ns: i64,
}

Worker_Started_At :: struct {
	unix_ns: i64,
}

activity_socket_path :: proc(directory: string) -> string {
	workers_dir := state_file_path(directory, "workers")
	defer delete(workers_dir)
	return state_file_path(workers_dir, "activity.sock")
}

activity_record_path :: proc(directory, shot_id: string) -> string {
	workers_dir := state_file_path(directory, "workers")
	defer delete(workers_dir)
	filename := fmt.aprintf("%s.activity.json", shot_id)
	defer delete(filename)
	return state_file_path(workers_dir, filename)
}

worker_started_at_path :: proc(directory, shot_id: string) -> string {
	workers_dir := state_file_path(directory, "workers")
	defer delete(workers_dir)
	filename := fmt.aprintf("%s.started_at", shot_id)
	defer delete(filename)
	return state_file_path(workers_dir, filename)
}

write_worker_started_at :: proc(directory, shot_id: string, unix_ns: i64) -> bool {
	if !valid_shot_id(shot_id) || unix_ns <= 0 {
		return false
	}
	path := worker_started_at_path(directory, shot_id)
	defer delete(path)
	data, err := json.marshal(Worker_Started_At{unix_ns = unix_ns})
	if err != nil {
		delete(data)
		return false
	}
	defer delete(data)
	return write_file_atomic(path, data)
}

read_worker_started_at :: proc(directory, shot_id: string) -> (unix_ns: i64, ok: bool) {
	if !valid_shot_id(shot_id) {
		return
	}
	path := worker_started_at_path(directory, shot_id)
	defer delete(path)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		delete(data)
		return
	}
	defer delete(data)
	started_at: Worker_Started_At
	if json.unmarshal_string(string(data), &started_at, .JSON, context.temp_allocator) != nil ||
		started_at.unix_ns <= 0 {
		return
	}
	return started_at.unix_ns, true
}

// The state directory is private; atomic replacement keeps status readers from
// observing a partial activity record while the supervisor updates it.
write_activity_record :: proc(directory: string, message: Activity_Message) -> bool {
	if !activity_valid_message(message) {
		return false
	}
	path := activity_record_path(directory, message.shot_id)
	defer delete(path)
	record := Activity_Record{
		kind = message.kind,
		description = message.description,
		observed_at_ns = message.timestamp_ns,
	}
	data, err := json.marshal(record)
	if err != nil {
		delete(data)
		return false
	}
	defer delete(data)
	return write_file_atomic(path, data)
}

read_activity_record :: proc(directory, shot_id: string) -> (record: Activity_Record, ok: bool) {
	if !valid_shot_id(shot_id) {
		return
	}
	path := activity_record_path(directory, shot_id)
	defer delete(path)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		delete(data)
		return
	}
	defer delete(data)
	if json.unmarshal_string(string(data), &record, .JSON, context.allocator) != nil ||
		record.kind == "" || record.description == "" ||
		len(record.kind) > ACTIVITY_MAX_KIND ||
		len(record.description) > ACTIVITY_MAX_DESCRIPTION || record.observed_at_ns <= 0 {
		activity_record_destroy(&record)
		return Activity_Record{}, false
	}
	return record, true
}

activity_record_destroy :: proc(record: ^Activity_Record, allocator := context.allocator) {
	delete(record.kind, allocator)
	delete(record.description, allocator)
	record^ = Activity_Record{}
}

activity_age_seconds :: proc(now_ns, then_ns: i64) -> i64 {
	if now_ns <= then_ns {
		return 0
	}
	return (now_ns - then_ns) / 1_000_000_000
}

activity_is_quiet :: proc(observed_at_ns, now_ns: i64) -> bool {
	return now_ns > observed_at_ns && now_ns-observed_at_ns >= ACTIVITY_QUIET_AFTER_NS
}

activity_duration_label :: proc(seconds: i64) -> string {
	duration := max(seconds, 0)
	switch {
	case duration < 60:
		return fmt.aprintf("%ds", duration)
	case duration < 3600:
		return fmt.aprintf("%dm%02ds", duration/60, duration%60)
	}
	return fmt.aprintf("%dh%02dm", duration/3600, (duration%3600)/60)
}

