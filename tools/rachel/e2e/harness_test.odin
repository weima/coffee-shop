package rachel_e2e

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// This package runs from tools/rachel, so source paths are relative to it.
RACHEL_SRC :: "src"
WAIT_STEP :: 50 * time.Millisecond
STOP_TIMEOUT_MS :: 5000

CUSTOM_JUSTFILE :: `check:
    odin check -no-entry-point .

test:
    TZ=UTC odin test .
`

VALID_MODULE :: `package demo

// one returns 1.
one :: proc() -> int {
	return 1
}
`

TWO_ERROR_MODULE :: `package demo

// one returns 1.
one :: proc() -> int {
	return
}

// three returns true.
three :: proc() -> bool {
	return 1
}
`

Process_Output :: struct {
	stdout:    string, // owned
	stderr:    string, // owned
	exit_code: int,
}

output_destroy :: proc(output: ^Process_Output, allocator := context.allocator) {
	delete(output.stdout, allocator)
	delete(output.stderr, allocator)
	output^ = Process_Output{}
}

Rachel_Build :: struct {
	binary: string, // owned
	dir:    string, // owned
}

build_destroy :: proc(build: ^Rachel_Build, allocator := context.allocator) {
	if build.dir != "" {
		_ = os.remove_all(build.dir)
		delete(build.dir, allocator)
	}
	delete(build.binary, allocator)
	build^ = Rachel_Build{}
}

// require_layout fails the test with a useful message when it is run from the
// wrong directory, because every path here is relative to tools/rachel.
require_layout :: proc(t: ^testing.T) -> bool {
	if os.is_file(fmt.tprintf("%s/main.odin", RACHEL_SRC)) {
		return true
	}
	testing.expectf(t, false, "run this package from tools/rachel: %s/main.odin not found", RACHEL_SRC)
	return false
}

build_rachel :: proc(t: ^testing.T, allocator := context.allocator) -> (build: Rachel_Build) {
	dir, dir_err := os.make_directory_temp("", "rachel-e2e-build-*", allocator)
	if dir_err != nil {
		testing.expectf(t, false, "cannot create build directory: %v", dir_err)
		return
	}
	binary := fmt.aprintf("%s/rachel", dir, allocator = allocator)
	out_flag := fmt.aprintf("-out:%s", binary, allocator = context.temp_allocator)
	output, run_err := run_to_output([]string{"odin", "build", RACHEL_SRC, out_flag}, 180_000, allocator)
	if run_err != nil {
		testing.expectf(t, false, "cannot run odin build: %v", run_err)
		delete(binary, allocator)
		_ = os.remove_all(dir)
		delete(dir, allocator)
		return
	}
	defer output_destroy(&output, allocator)
	if output.exit_code != 0 {
		testing.expectf(t, false, "odin build failed:\n%s%s", output.stdout, output.stderr)
		delete(binary, allocator)
		_ = os.remove_all(dir)
		delete(dir, allocator)
		return
	}
	return Rachel_Build{binary = binary, dir = dir}
}

// run_to_output runs a command to completion and captures both streams in files,
// which cannot deadlock on a full pipe the way in-memory pipes can.
run_to_output :: proc(
	argv: []string,
	timeout_ms := 120_000,
	allocator := context.allocator,
) -> (output: Process_Output, err: os.Error) {
	dir, dir_err := os.make_directory_temp("", "rachel-e2e-io-*", allocator)
	if dir_err != nil {
		return {}, dir_err
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, allocator)
	}
	stdout_path := fmt.aprintf("%s/stdout", dir, allocator = allocator)
	defer delete(stdout_path, allocator)
	stderr_path := fmt.aprintf("%s/stderr", dir, allocator = allocator)
	defer delete(stderr_path, allocator)
	out_file, out_open := os.open(stdout_path, {.Write, .Create, .Trunc})
	if out_open != nil {
		return {}, out_open
	}
	err_file, err_open := os.open(stderr_path, {.Write, .Create, .Trunc})
	if err_open != nil {
		os.close(out_file)
		return {}, err_open
	}
	process, start_err := os.process_start(os.Process_Desc{command = argv, stdout = out_file, stderr = err_file})
	os.close(out_file)
	os.close(err_file)
	if start_err != nil {
		return {}, start_err
	}
	state, wait_err := os.process_wait(process, time.Duration(timeout_ms) * time.Millisecond)
	if wait_err != nil {
		return {}, wait_err
	}
	out_data, out_read := os.read_entire_file(stdout_path, allocator)
	if out_read != nil {
		return {}, out_read
	}
	err_data, err_read := os.read_entire_file(stderr_path, allocator)
	if err_read != nil {
		delete(out_data, allocator)
		return {}, err_read
	}
	return Process_Output{stdout = transmute(string)out_data, stderr = transmute(string)err_data, exit_code = state.exit_code}, nil
}

// spawn_to_log starts a long-running child whose output goes to a file the test polls.
spawn_to_log :: proc(argv: []string, log_path: string) -> (process: os.Process, err: os.Error) {
	file, open_err := os.open(log_path, {.Write, .Create, .Trunc})
	if open_err != nil {
		return {}, open_err
	}
	defer os.close(file)
	return os.process_start(os.Process_Desc{command = argv, stdout = file, stderr = file})
}

stop_process :: proc(process: os.Process) {
	if process.pid <= 0 {
		return
	}
	_ = posix.kill(posix.pid_t(process.pid), .SIGTERM)
	_, _ = os.process_wait(process, STOP_TIMEOUT_MS * time.Millisecond)
}

file_contains :: proc(path, needle: string) -> bool {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return false
	}
	defer free_all(context.temp_allocator)
	return strings.contains(transmute(string)data, needle)
}

file_count :: proc(path, needle: string) -> int {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return 0
	}
	defer free_all(context.temp_allocator)
	text := transmute(string)data
	count := 0
	for {
		index := strings.index(text, needle)
		if index < 0 {
			return count
		}
		count += 1
		text = text[index + len(needle):]
	}
}

// file_text returns the whole file for a failure message, in the temp allocator.
file_text :: proc(path: string) -> string {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return "<unreadable>"
	}
	return transmute(string)data
}

wait_file_contains :: proc(log_path, needle: string, timeout_ms: int) -> bool {
	start := time.now()
	for time.since(start) < time.Duration(timeout_ms) * time.Millisecond {
		if file_contains(log_path, needle) {
			return true
		}
		time.sleep(WAIT_STEP)
	}
	return false
}

wait_file_count :: proc(log_path, needle: string, wanted: int, timeout_ms: int) -> bool {
	start := time.now()
	for time.since(start) < time.Duration(timeout_ms) * time.Millisecond {
		if file_count(log_path, needle) >= wanted {
			return true
		}
		time.sleep(WAIT_STEP)
	}
	return false
}

write_file :: proc(t: ^testing.T, path, contents: string) {
	if err := os.write_entire_file_from_string(path, contents, os.Permissions{.Read_User, .Write_User}); err != nil {
		testing.expectf(t, false, "cannot write %s: %v", path, err)
	}
}

make_project :: proc(t: ^testing.T, allocator := context.allocator) -> (dir: string) {
	created, created_err := os.make_directory_temp("", "rachel-e2e-project-*", allocator)
	if created_err != nil {
		testing.expectf(t, false, "cannot create project directory: %v", created_err)
		return ""
	}
	return created
}

project_destroy :: proc(dir: ^string, allocator := context.allocator) {
	if dir^ != "" {
		_ = os.remove_all(dir^)
		delete(dir^, allocator)
		dir^ = ""
	}
}

has_watchexec :: proc() -> bool {
	path := os.get_env("PATH", context.temp_allocator)
	separator := fmt.aprintf("%c", rune(os.Path_List_Separator), allocator = context.temp_allocator)
	for part in strings.split(path, separator, context.temp_allocator) {
		if part == "" {
			continue
		}
		if os.is_file(fmt.aprintf("%s/watchexec", part, allocator = context.temp_allocator)) {
			return true
		}
	}
	return false
}
