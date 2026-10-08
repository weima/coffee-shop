package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// A PID alone can be reused by another process. Pairing it with the kernel's
// start time identifies one specific process.
Process_Identity :: struct {
	pid:        int,
	start_time: u64,
}

// What reading /proc says about a saved identity. Only evidence of absence may
// say Gone: a read that failed or text that does not parse proves nothing, so it
// is Unknown, and Unknown must never be recorded as an exit.
Liveness :: enum {
	Alive,
	Gone,
	Unknown,
}

// The identity of this process, or false if its own /proc entry cannot be read. A
// guessed start time would later read as "a different process", i.e. dead.
current_identity :: proc() -> (identity: Process_Identity, ok: bool) {
	pid := os.get_pid()
	start_time, found := process_start_time(pid)
	if !found {
		return Process_Identity{}, false
	}
	return Process_Identity{pid = int(pid), start_time = start_time}, true
}

// Gone means a missing entry, a zombie (it has exited and only awaits its parent),
// or a different start time (the PID now belongs to another process).
classify_proc_stat :: proc(identity: Process_Identity, data: []byte, read_err: os.Error) -> Liveness {
	if read_err == os.General_Error.Not_Exist {
		return .Gone
	}
	if read_err != nil {
		return .Unknown
	}
	start_time, state, ok := parse_proc_stat(string(data))
	if !ok {
		return .Unknown
	}
	if state == 'Z' || start_time != identity.start_time {
		return .Gone
	}
	return .Alive
}

identity_liveness :: proc(identity: Process_Identity) -> Liveness {
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", identity.pid), context.temp_allocator)
	return classify_proc_stat(identity, data, err)
}

identity_alive :: proc(identity: Process_Identity) -> bool {
	return identity_liveness(identity) == .Alive
}

process_start_time :: proc(pid: $T) -> (start_time: u64, ok: bool) {
	start_time, _, ok = read_proc_stat(int(pid))
	return
}

// Reads /proc/<pid>/stat.
read_proc_stat :: proc(pid: int) -> (start_time: u64, state: u8, ok: bool) {
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
	if err != nil {
		return 0, 0, false
	}
	return parse_proc_stat(string(data))
}

// The command name is in parentheses and may contain spaces, so fields are counted
// from the last ')'.
parse_proc_stat :: proc(text: string) -> (start_time: u64, state: u8, ok: bool) {
	close_paren := strings.last_index_byte(text, ')')
	if close_paren < 0 {
		return 0, 0, false
	}
	// fields[0] is stat field 3 (state), so field 22 (start time) is fields[19].
	fields := strings.fields(text[close_paren + 1:], context.temp_allocator)
	if len(fields) < 20 || len(fields[0]) != 1 {
		return 0, 0, false
	}
	value, parsed := strconv.parse_u64(fields[19])
	return value, fields[0][0], parsed
}

write_file_atomic :: proc(path: string, data: []byte) -> bool {
	temp_path, alloc_err := strings.concatenate({path, ".tmp"})
	if alloc_err != nil {
		return false
	}
	defer delete(temp_path)
	if write_all_to_file(temp_path, data, os.O_WRONLY | os.O_CREATE | os.O_TRUNC).kind != .None {
		_ = os.remove(temp_path)
		return false
	}
	if os.rename(temp_path, path) != nil {
		_ = os.remove(temp_path)
		return false
	}
	return true
}

write_identity_file :: proc(path: string, identity: Process_Identity) -> bool {
	data, err := json.marshal(identity)
	if err != nil {
		delete(data)
		return false
	}
	defer delete(data)
	return write_file_atomic(path, data)
}

read_identity_file :: proc(path: string) -> (identity: Process_Identity, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return Process_Identity{}, false
	}
	if json.unmarshal(data, &identity, .JSON, context.temp_allocator) != nil || identity.pid <= 0 {
		return Process_Identity{}, false
	}
	return identity, true
}
