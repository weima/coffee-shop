#+build linux
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

platform_sample :: proc(pid: int) -> (sample: Sample) {
	if pid <= 0 {
		return
	}
	if data, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator); err == nil {
		sample.cpu_ms = linux_cpu_ms(string(data))
	}
	if data, err := os.read_entire_file(fmt.tprintf("/proc/%d/status", pid), context.temp_allocator); err == nil {
		sample.rss = linux_vm_rss(string(data))
	}
	if infos, err := os.read_all_directory_by_path(fmt.tprintf("/proc/%d/fd", pid), context.temp_allocator); err == nil {
		sample.fds = Metric{true, u64(len(infos))}
	}
	return
}

// utime and stime are stat fields 14 and 15: fields[11] and [12] after the ')'.
linux_cpu_ms :: proc(text: string) -> Metric {
	close_paren := strings.last_index_byte(text, ')')
	if close_paren < 0 {
		return {}
	}
	fields := strings.fields(text[close_paren + 1:], context.temp_allocator)
	hz := posix.sysconf(._CLK_TCK)
	if len(fields) < 13 || hz <= 0 {
		return {}
	}
	user, ok_user := strconv.parse_u64(fields[11])
	system, ok_system := strconv.parse_u64(fields[12])
	if !ok_user || !ok_system {
		return {}
	}
	return Metric{true, (user + system) * 1000 / u64(hz)}
}

linux_vm_rss :: proc(text: string) -> Metric {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "VmRSS:") {
			fields := strings.fields(line[len("VmRSS:"):], context.temp_allocator)
			if len(fields) == 0 {
				return {}
			}
			kib, ok := strconv.parse_u64(fields[0])
			return Metric{true, kib * 1024} if ok else Metric{}
		}
	}
	return {}
}

platform_process_table :: proc(allocator := context.allocator) -> []Process_Edge {
	edges := make([dynamic]Process_Edge, 0, 256, allocator)
	infos, err := os.read_all_directory_by_path("/proc", context.temp_allocator)
	if err != nil {
		return edges[:]
	}
	for info in infos {
		pid, is_pid := strconv.parse_int(info.name)
		if !is_pid {
			continue
		}
		data, read_err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
		if read_err != nil {
			continue
		}
		text := string(data)
		close_paren := strings.last_index_byte(text, ')')
		if close_paren < 0 {
			continue
		}
		fields := strings.fields(text[close_paren + 1:], context.temp_allocator)
		if len(fields) < 2 {
			continue
		}
		if ppid, ok := strconv.parse_int(fields[1]); ok {
			append(&edges, Process_Edge{pid, ppid})
		}
	}
	return edges[:]
}

platform_process_args :: proc(pid: int, buffer: ^[dynamic]u8) -> bool {
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/cmdline", pid), context.temp_allocator)
	if err != nil {
		return false
	}
	clear(buffer)
	append(buffer, ..data)
	return true
}
