package main

import "core:os"
import "core:sys/posix"

is_terminal :: proc(status: string) -> bool {
	return status == SHOT_COMPLETED || status == SHOT_FAILED || status == SHOT_CANCELLED || status == SHOT_INTERRUPTED || status == SHOT_INCOMPLETE
}

all_terminal :: proc(register: Register) -> bool {
	for shot in register.shots {
		if !is_terminal(shot.status) {
			return false
		}
	}
	return true
}

supervisor_path :: proc(directory: string) -> string {
	return state_file_path(directory, "supervisor.json")
}

write_supervisor :: proc(directory: string) -> bool {
	path := supervisor_path(directory)
	defer delete(path)
	identity, ok := current_identity()
	if !ok {
		return false
	}
	return write_identity_file(path, identity)
}

// Missing or unreadable supervisor identity is distinguished from a confirmed exit.
supervisor_liveness :: proc(directory: string) -> Liveness {
	path := supervisor_path(directory)
	defer delete(path)
	identity, ok := read_identity_file(path)
	if !ok {
		if !os.exists(path) {
			return .Gone
		}
		return .Unknown
	}
	return identity_liveness(identity)
}

supervisor_gone :: proc(directory: string) -> bool {
	return supervisor_liveness(directory) == .Gone
}

// Sends SIGTERM to the recorded Station. Only a positive PID is signalled; a
// missing or unreadable identity is left for the tab-close fallback.
stop_worker_gracefully :: proc(identity: Process_Identity) {
	if identity.pid <= 0 {
		return
	}
	target := identity.pid
	if os.get_env("CS_MODE", context.temp_allocator) == "dev" {
		if child := odin_run_child(identity.pid); child > 0 {
			target = child
		}
		dev_cancel_escalate(identity.pid, DEV_CANCEL_TIMEOUT_SECONDS)
	}
	_ = posix.kill(posix.pid_t(target), .SIGTERM)
}
