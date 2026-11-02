package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"

// The part of the foreground host's contract this binary still consumes. The host
// itself is csd; `status`, `log` and `reply` read its lock, its history and its event
// lines, so their shapes live here rather than with the implementation.

HOST_LOCK_FILE_NAME :: "host.lock"
HOST_HISTORY_FILE_NAME :: "history.ndjson"

// One reply, in bytes. A line longer than this is refused before it is sent.
HOST_REPLY_MAX :: 4096

// Byte length of a received stdin line. A union so that events that do not carry
// it leave it nil, and json's omitempty then drops the field entirely.
Host_Byte_Count :: union {
	int,
}

// One line on stdout per event. Encoded with json.marshal so that free-form
// reasons from Git or a child process cannot break the framing.
Host_Event :: struct {
	type:        string `json:"type"`,
	request_id:  string `json:"request_id"`,
	// Only set on received events, so an unanswered request can be told apart
	// from one that was never read. A nil union field is omitted, unlike a zero
	// int, which json's omitempty never drops.
	bytes:       Host_Byte_Count `json:"bytes,omitempty"`,
	shot_id:     string `json:"shot_id,omitempty"`,
	pane_id:     string `json:"pane_id,omitempty"`,
	kind:        string `json:"kind,omitempty"`,
	description: string `json:"description,omitempty"`,
	reason:      string `json:"reason,omitempty"`,
	branch:      string `json:"branch,omitempty"`,
	commit:      string `json:"commit,omitempty"`,
	at:          string `json:"at"`,
}

// host_string reads one string field of a request object; a missing or non-string
// field is absent rather than an error.
host_string :: proc(object: json.Object, key: string) -> (string, bool) {
	value, found := object[key]
	if !found {
		return "", false
	}
	text, is_string := value.(json.String)
	return text, is_string
}

// One event line on stdout. Blend runs as a standalone command now, so it is the only
// producer here; the host implementation writes its own lines in Go.
host_emit :: proc(event: Host_Event) -> bool {
	stamped := event
	stamped.at = log_timestamp(time.now())
	data, err := json.marshal(stamped, {}, context.temp_allocator)
	if err != nil {
		fmt.eprintln("could not encode event")
		return false
	}
	fmt.println(string(data))
	return true
}

// Takes the host's life lock, or reports that a host already holds it.
host_acquire_lock :: proc(directory: string) -> (file: ^os.File, ok: bool) {
	path := state_file_path(directory, HOST_LOCK_FILE_NAME, context.temp_allocator)
	opened, open_err := os.open(path, os.O_RDWR|os.O_CREATE, private_file_permissions())
	if open_err != nil {
		return nil, false
	}
	if !file_lock_try(opened) {
		_ = os.close(opened)
		return nil, false
	}
	return opened, true
}
