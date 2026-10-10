#+build darwin
package main

import "core:sys/darwin"
import "core:sys/posix"

darwin_process_usage :: proc(pid: int) -> (usage: darwin.rusage_info_v0, ok: bool) {
	if pid <= 0 {
		return {}, false
	}
	return usage, darwin.proc_pid_rusage(posix.pid_t(pid), .V0, &usage) == 0
}

darwin_process_start_time :: proc(pid: int) -> (start_time: u64, ok: bool) {
	usage, found := darwin_process_usage(pid)
	if !found || usage.ri_proc_start_abstime == 0 {
		return 0, false
	}
	return usage.ri_proc_start_abstime, true
}

darwin_identity_liveness :: proc(identity: Process_Identity) -> Liveness {
	if identity.pid <= 0 {
		return .Unknown
	}
	usage, found := darwin_process_usage(identity.pid)
	if found {
		return .Gone if usage.ri_proc_exit_abstime != 0 || usage.ri_proc_start_abstime != identity.start_time else .Alive
	}

	// proc_pid_rusage can fail for an existing process when access is restricted.
	// kill(pid, 0) distinguishes that from a PID that is actually gone.
	posix.set_errno(.NONE)
	if posix.kill(posix.pid_t(identity.pid), posix.Signal(0)) == .FAIL && posix.errno() == .ESRCH {
		return .Gone
	}
	return .Unknown
}
