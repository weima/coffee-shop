#+build darwin
package main

import "core:c"
import "core:sys/darwin"
import "core:sys/posix"

// CPU time is not reported: ri_user_time is in Mach absolute-time ticks, and this
// code does not read the timebase to convert them, so it stays "to be verified".
platform_sample :: proc(pid: int) -> (sample: Sample) {
	usage, found := darwin_process_usage(pid)
	if !found {
		return
	}
	sample.rss = Metric{true, usage.ri_resident_size}
	sample.fds = darwin_fd_count(pid)
	return
}

// proc_fdinfo is two 32-bit fields, 8 bytes per descriptor.
darwin_fd_count :: proc(pid: int) -> Metric {
	need := darwin.proc_pidinfo(posix.pid_t(pid), .LISTFDS, 0, nil, 0)
	if need <= 0 {
		return {}
	}
	buffer := make([]u8, int(need) + 64 * 8, context.temp_allocator)
	got := darwin.proc_pidinfo(posix.pid_t(pid), .LISTFDS, 0, raw_data(buffer), i32(len(buffer)))
	return Metric{true, u64(got / 8)} if got >= 0 else Metric{}
}

platform_process_table :: proc(allocator := context.allocator) -> []Process_Edge {
	edges := make([dynamic]Process_Edge, 0, 256, allocator)
	count := darwin.proc_listallpids(nil, 0)
	if count <= 0 {
		return edges[:]
	}
	pids := make([]i32, int(count) + 32, context.temp_allocator)
	got := darwin.proc_listallpids(raw_data(pids), i32(len(pids) * size_of(i32)))
	for pid in pids[:max(int(got), 0)] {
		info: darwin.proc_bsdinfo
		if darwin.proc_pidinfo(posix.pid_t(pid), .BSDINFO, 0, &info, size_of(info)) == size_of(info) {
			append(&edges, Process_Edge{int(pid), int(info.pbi_ppid)})
		}
	}
	return edges[:]
}

// KERN_PROCARGS2 (CTL_KERN=1, 49): argc, exec path, then NUL-separated arguments.
// False for a process this user may not read.
platform_process_args :: proc(pid: int, buffer: ^[dynamic]u8) -> bool {
	mib := [3]c.int{1, 49, c.int(pid)}
	size: c.size_t
	if darwin.syscall_sysctl(&mib[0], 3, nil, &size, nil, 0) != 0 || size == 0 {
		return false
	}
	resize(buffer, int(size))
	if darwin.syscall_sysctl(&mib[0], 3, raw_data(buffer[:]), &size, nil, 0) != 0 {
		return false
	}
	resize(buffer, int(size))
	return true
}
