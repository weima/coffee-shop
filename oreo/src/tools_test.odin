package oreo

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

TOOLS_TEMP_DIR :: "/private/tmp" when ODIN_OS == .Darwin else "/tmp"

@(test)
test_tool_write_then_read_round_trip :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	path := tools_test_path(t, directory, "note.txt")
	defer delete(path)

	write_err := tool_write(path, "alpha\nbeta\n")
	defer tool_error_destroy(&write_err)
	testing.expect_value(t, write_err.kind, Tool_Error_Kind.None)

	content, read_err := tool_read(path, 0, 0)
	defer delete(content)
	defer tool_error_destroy(&read_err)
	testing.expect_value(t, read_err.kind, Tool_Error_Kind.None)
	testing.expect_value(t, content, "1\talpha\n2\tbeta")
}

@(test)
test_tool_read_returns_numbered_offset_and_limit_windows :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	path := tools_test_path(t, directory, "lines.txt")
	defer delete(path)
	write_err := tool_write(path, "one\ntwo\nthree\nfour\n")
	defer tool_error_destroy(&write_err)
	testing.expect_value(t, write_err.kind, Tool_Error_Kind.None)

	all, all_err := tool_read(path, 0, 0)
	defer delete(all)
	defer tool_error_destroy(&all_err)
	testing.expect_value(t, all_err.kind, Tool_Error_Kind.None)
	testing.expect_value(t, all, "1\tone\n2\ttwo\n3\tthree\n4\tfour")

	window, window_err := tool_read(path, 1, 2)
	defer delete(window)
	defer tool_error_destroy(&window_err)
	testing.expect_value(t, window_err.kind, Tool_Error_Kind.None)
	testing.expect_value(t, window, "2\ttwo\n3\tthree")

	tail, tail_err := tool_read(path, 2, 0)
	defer delete(tail)
	defer tool_error_destroy(&tail_err)
	testing.expect_value(t, tail_err.kind, Tool_Error_Kind.None)
	testing.expect_value(t, tail, "3\tthree\n4\tfour")

	clamped, clamped_err := tool_read(path, 3, 99)
	defer delete(clamped)
	defer tool_error_destroy(&clamped_err)
	testing.expect_value(t, clamped_err.kind, Tool_Error_Kind.None)
	testing.expect_value(t, clamped, "4\tfour")

	beyond, beyond_err := tool_read(path, 9, 0)
	defer delete(beyond)
	defer tool_error_destroy(&beyond_err)
	testing.expect_value(t, beyond_err.kind, Tool_Error_Kind.None)
	testing.expect_value(t, beyond, "")
}

@(test)
test_tool_read_missing_file_is_not_found :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	path := tools_test_path(t, directory, "absent.txt")
	defer delete(path)

	content, read_err := tool_read(path, 0, 0)
	defer delete(content)
	defer tool_error_destroy(&read_err)
	testing.expect_value(t, read_err.kind, Tool_Error_Kind.Not_Found)
	testing.expect_value(t, content, "")
}

@(test)
test_tool_read_directory_is_invalid_argument :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}

	content, read_err := tool_read(directory, 0, 0)
	defer delete(content)
	defer tool_error_destroy(&read_err)
	testing.expect_value(t, read_err.kind, Tool_Error_Kind.Invalid_Argument)
	testing.expect_value(t, content, "")
}

@(test)
test_tool_write_creates_missing_nested_directories :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	path := tools_test_path(t, directory, "nested/deeper/note.txt")
	defer delete(path)

	write_err := tool_write(path, "created\n")
	defer tool_error_destroy(&write_err)
	testing.expect_value(t, write_err.kind, Tool_Error_Kind.None)

	content, read_err := tool_read(path, 0, 0)
	defer delete(content)
	defer tool_error_destroy(&read_err)
	testing.expect_value(t, read_err.kind, Tool_Error_Kind.None)
	testing.expect_value(t, content, "1\tcreated")
}

@(test)
test_tool_execute_captures_merged_streams_and_zero_exit :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}

	output, exit_code, exec_err := tool_execute("echo first; echo second 1>&2; echo third", directory)
	defer delete(output)
	defer tool_error_destroy(&exec_err)
	testing.expect_value(t, exec_err.kind, Tool_Error_Kind.None)
	testing.expect_value(t, exit_code, 0)
	testing.expect_value(t, output, "first\nsecond\nthird\n")

	cwd, _, cwd_err := tool_execute("pwd", directory)
	defer delete(cwd)
	defer tool_error_destroy(&cwd_err)
	testing.expect_value(t, cwd_err.kind, Tool_Error_Kind.None)
	testing.expect_value(t, strings.trim_space(cwd), directory)
}

@(test)
test_tool_execute_failing_command_returns_exit_code_and_stderr :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}

	output, exit_code, exec_err := tool_execute("echo problem 1>&2; exit 7", directory)
	defer delete(output)
	defer tool_error_destroy(&exec_err)
	testing.expect_value(t, exec_err.kind, Tool_Error_Kind.None)
	testing.expect_value(t, exit_code, 7)
	testing.expect_value(t, output, "problem\n")
}

@(test)
test_tool_execute_empty_command_is_invalid_argument :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}

	output, exit_code, exec_err := tool_execute("", directory)
	defer delete(output)
	defer tool_error_destroy(&exec_err)
	testing.expect_value(t, exec_err.kind, Tool_Error_Kind.Invalid_Argument)
	testing.expect_value(t, exit_code, 0)
	testing.expect_value(t, output, "")
}

@(private)
tools_test_directory :: proc(t: ^testing.T) -> string {
	directory, err := os.make_directory_temp(TOOLS_TEMP_DIR, "oreo-tools-*", context.allocator)
	testing.expect(t, err == nil)
	return directory
}

@(private)
tools_test_path :: proc(t: ^testing.T, directory, name: string) -> string {
	path: string
	join_err: os.Error
	path, join_err = filepath.join({directory, name}, context.allocator)
	testing.expect(t, join_err == nil)
	return path
}
