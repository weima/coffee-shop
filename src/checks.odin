package main

import "core:fmt"
import "core:os"
import "base:runtime"
import "core:strings"

Check_Result :: struct {
	started: bool,
	exit_code: int,
	success: bool,
	output_tail: string,
	detail: string,
}

run_check :: proc(station_path: string, argv: []string, max_tail_bytes := 8192, allocator := context.allocator) -> Check_Result {
	if len(argv) == 0 {
		return Check_Result{detail = checks_clone("could not launch command: empty argument vector", allocator)}
	}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{working_dir = station_path, command = argv}, allocator)
	defer delete(stdout, allocator)
	defer delete(stderr, allocator)
	if err != nil {
		return Check_Result{detail = checks_clone(fmt.tprintf("could not launch %s: %v", argv[0], err), allocator)}
	}

	output := checks_output_tail(stdout, stderr, max_tail_bytes, allocator)
	detail := checks_clone(fmt.tprintf("exited with code %d", state.exit_code), allocator)
	return Check_Result{
		started = true,
		exit_code = state.exit_code,
		success = state.success && state.exit_code == 0,
		output_tail = output,
		detail = detail,
	}
}

destroy_check_result :: proc(result: ^Check_Result, allocator := context.allocator) {
	delete(result.output_tail, allocator)
	delete(result.detail, allocator)
	result^ = Check_Result{}
}

command_text :: proc(argv: []string, allocator := context.allocator) -> string {
	text: [dynamic]u8
	text.allocator = allocator
	for arg, i in argv {
		if i > 0 {
			append(&text, " ")
		}
		quote := len(arg) == 0
		for i in 0 ..< len(arg) {
			if !checks_display_safe(arg[i]) {
				quote = true
				break
			}
		}
		if !quote {
			append(&text, arg)
			continue
		}
		append(&text, "'")
		for i in 0 ..< len(arg) {
			if arg[i] == '\'' {
				append(&text, "'\\''")
			} else {
				append(&text, arg[i])
			}
		}
		append(&text, "'")
	}
	result, _ := strings.clone(string(text[:]), allocator)
	delete(text)
	return result
}

checks_display_safe :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-' || c == '.' || c == '/' || c == ':'
}

checks_clone :: proc(value: string, allocator: runtime.Allocator) -> string {
	copy, err := strings.clone(value, allocator)
	if err != nil {
		return ""
	}
	return copy
}

checks_output_tail :: proc(stdout, stderr: []byte, max_tail_bytes: int, allocator: runtime.Allocator) -> string {
	output: [dynamic]u8
	output.allocator = allocator
	append(&output, ..stdout)
	if len(stderr) > 0 {
		if len(stdout) > 0 && stdout[len(stdout)-1] != '\n' {
			append(&output, '\n')
		}
		append(&output, "--- stderr ---\n")
		append(&output, ..stderr)
	}

	start := 0
	limit := max(max_tail_bytes, 0)
	truncated := len(output) > limit
	if truncated {
		raw_start := len(output) - limit
		start = raw_start
		// Prefer to begin at a line boundary. If the only boundary is the final
		// newline (one very long last line), keep the raw tail instead of
		// discarding the only evidence.
		for index in raw_start ..< len(output) - 1 {
			if output[index] == '\n' {
				start = index + 1
				break
			}
		}
	}
	prefix := ""
	if truncated {
		prefix = "[output truncated]\n"
	}
	result := checks_clone(fmt.tprintf("%s%s", prefix, string(output[start:])), allocator)
	delete(output)
	return result
}
