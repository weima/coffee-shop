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

current_identity :: proc() -> Process_Identity {
	pid := os.get_pid()
	start_time, _ := process_start_time(pid)
	return Process_Identity{pid = int(pid), start_time = start_time}
}

// A zombie has exited and only awaits its parent, so it counts as gone.
identity_alive :: proc(identity: Process_Identity) -> bool {
	start_time, state, ok := read_proc_stat(identity.pid)
	return ok && state != 'Z' && start_time == identity.start_time
}

process_start_time :: proc(pid: $T) -> (start_time: u64, ok: bool) {
	start_time, _, ok = read_proc_stat(int(pid))
	return
}

// Reads /proc/<pid>/stat. The command name is in parentheses and may contain
// spaces, so fields are counted from the last ')'.
read_proc_stat :: proc(pid: int) -> (start_time: u64, state: u8, ok: bool) {
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
	if err != nil {
		return 0, 0, false
	}
	text := string(data)
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
