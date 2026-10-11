package oreo

import "base:runtime"
import "core:os"
import "core:strings"

Tool_Error_Kind :: enum {
	None,
	Invalid_Argument,
	Not_Found,
	Permission,
	Io,
	Out_Of_Memory,
}

// Tool_Error owns its message text. Call tool_error_destroy on every value,
// including a zero value, when it is no longer needed.
Tool_Error :: struct {
	kind: Tool_Error_Kind,
	message: string,
}

// tool_read returns the requested line window as "<line number>\t<line text>"
// records joined by newlines. offset is a 0-based line index and limit <= 0
// means every remaining line. A trailing newline does not add an empty last
// line. The caller owns content.
tool_read :: proc(path: string, offset: int, limit: int, allocator := context.allocator) -> (content: string, err: Tool_Error) {
	info, stat_err := os.stat(path, context.allocator)
	if stat_err != nil {
		if stat_err == os.General_Error.Not_Exist {
			return "", tool_error(.Not_Found, "file does not exist")
		}
		return "", tool_error(.Io, "could not inspect the file")
	}
	defer os.file_info_delete(info, context.allocator)
	if info.type == .Directory {
		return "", tool_error(.Invalid_Argument, "path is a directory")
	}

	data, read_err := os.read_entire_file_from_path(path, allocator)
	if read_err != nil {
		if read_err == os.General_Error.Not_Exist {
			return "", tool_error(.Not_Found, "file does not exist")
		}
		return "", tool_error(.Io, "could not read the file")
	}
	defer delete(data, allocator)
	return format_numbered_lines(string(data), offset, limit, allocator)
}

// tool_write creates missing parent directories with user read/write/execute
// permission and overwrites the file at path.
tool_write :: proc(path: string, content: string) -> Tool_Error {
	if path == "" {
		return tool_error(.Invalid_Argument, "path must not be empty")
	}
	parent := os.dir(path)
	if parent != "" && parent != "." && parent != "/" && !os.is_directory(parent) {
		mkdir_err := os.make_directory_all(parent, os.Permissions{.Read_User, .Write_User, .Execute_User})
		if mkdir_err != nil {
			return tool_error(.Io, "could not create the parent directory")
		}
	}
	if write_err := os.write_entire_file_from_string(path, content); write_err != nil {
		return tool_error(.Io, "could not write the file")
	}
	return Tool_Error{}
}

// tool_execute runs command with "/bin/sh -c" in working_directory and returns
// its merged stdout/stderr and exit code. A non-zero exit code is a normal
// result. The caller owns output.
tool_execute :: proc(command, working_directory: string, allocator := context.allocator) -> (output: string, exit_code: int, err: Tool_Error) {
	if command == "" {
		return "", 0, tool_error(.Invalid_Argument, "command must not be empty")
	}
	read_end, write_end, pipe_err := os.pipe()
	if pipe_err != nil {
		return "", 0, tool_error(.Io, "could not create a pipe")
	}
	argv := [3]string{"/bin/sh", "-c", command}
	process, start_err := os.process_start(os.Process_Desc{
		working_dir = working_directory,
		command     = argv[:],
		stdout      = write_end,
		stderr      = write_end,
	})
	_ = os.close(write_end)
	if start_err != nil {
		_ = os.close(read_end)
		return "", 0, tool_error(.Io, "could not start the command")
	}

	output_bytes: [dynamic]byte
	output_bytes.allocator = allocator
	buffer: [4096]u8
	done := false
	for !done {
		n, read_err := os.read(read_end, buffer[:])
		if n > 0 {
			if _, append_err := append(&output_bytes, ..buffer[:n]); append_err != nil {
				_ = os.close(read_end)
				delete(output_bytes)
				return "", 0, tool_error(.Out_Of_Memory, "could not buffer the command output")
			}
		}
		switch read_err {
		case nil:
		case .EOF:
			done = true
		case:
			_ = os.close(read_end)
			delete(output_bytes)
			return "", 0, tool_error(.Io, "could not read the command output")
		}
	}
	_ = os.close(read_end)

	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		delete(output_bytes)
		return "", 0, tool_error(.Io, "could not wait for the command")
	}
	return string(output_bytes[:]), state.exit_code, Tool_Error{}
}

tool_error_destroy :: proc(err: ^Tool_Error) {
	delete(err.message)
	err^ = Tool_Error{}
}

@(private)
format_numbered_lines :: proc(data: string, offset, limit: int, allocator: runtime.Allocator) -> (string, Tool_Error) {
	if len(data) == 0 {
		return "", Tool_Error{}
	}
	start := max(offset, 0)
	builder: strings.Builder
	strings.builder_init(&builder, allocator)

	line_number := 1
	segment_start := 0
	selected := 0
	for i in 0 ..= len(data) {
		if i != len(data) && data[i] != '\n' {
			continue
		}
		// A trailing newline ends the last line; it is not an empty extra line.
		trailing := i == len(data) && segment_start == i
		if !trailing {
			if line_number > start {
				if selected > 0 {
					strings.write_byte(&builder, '\n')
				}
				strings.write_int(&builder, line_number)
				strings.write_byte(&builder, '\t')
				strings.write_string(&builder, data[segment_start:i])
				selected += 1
				if limit > 0 && selected >= limit {
					break
				}
			}
			line_number += 1
		}
		segment_start = i + 1
	}
	return strings.to_string(builder), Tool_Error{}
}

@(private)
tool_error :: proc(kind: Tool_Error_Kind, message: string) -> Tool_Error {
	owned, _ := strings.clone(message)
	return Tool_Error{kind = kind, message = owned}
}
