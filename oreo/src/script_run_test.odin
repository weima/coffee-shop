package oreo

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"

// Each test gets its own work directory and removes it, so no temporary
// directory and no compiled binary survives a run.

@(private)
script_run_test_work_dir :: proc(t: ^testing.T) -> string {
	dir, dir_err := os.make_directory_temp("", "oreo-script-run-*", context.allocator)
	if dir_err != nil {
		testing.fail_now(t, "could not create a temporary work directory")
	}
	return dir
}

@(private)
script_run_test_result_destroy :: proc(result: ^Script_Run_Result) {
	delete(result.reason)
	delete(result.output)
	delete(result.full_output_path)
	result^ = Script_Run_Result{}
}

// A generated script that imports "oreo:script" needs the compiler to resolve
// it, so the test passes the same collection mapping this test binary was built
// with. #file keeps that mapping run-relative: the compiler runs with the work
// directory as its working directory, where a relative collection would miss.
@(private)
script_run_test_collection :: proc() -> string {
	return fmt.aprintf("-collection:oreo=%s", filepath.dir(#file))
}

@(private)
script_run_test_socket_path :: proc(dir: string) -> string {
	return fmt.aprintf("%s/%s", dir, SCRIPT_RUN_SOCKET_NAME)
}

@(private)
script_run_test_expect_no_socket :: proc(t: ^testing.T, dir: string) {
	socket_path := script_run_test_socket_path(dir)
	defer delete(socket_path)
	testing.expectf(t, !os.exists(socket_path), "the script socket %q survived the run", socket_path)
}

@(test)
test_script_run_prints_a_line :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	result := script_run(
		Script_Run_Config {
			source = `
package script

import "core:fmt"

main :: proc() {
	fmt.println("hello from oreo")
}
`,
			work_dir = dir,
		},
	)
	defer script_run_test_result_destroy(&result)

	testing.expect(t, result.ok)
	testing.expect_value(t, result.exit_code, 0)
	testing.expect(t, !result.timed_out)
	testing.expect(t, strings.contains(result.output, "hello from oreo"))
}

@(test)
test_script_run_gate_rejection_writes_and_compiles_nothing :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	result := script_run(
		Script_Run_Config {
			// core:mem is outside the gate's allowlist.
			source = `
package script

import "core:mem"

main :: proc() {}
`,
			work_dir = dir,
		},
	)
	defer script_run_test_result_destroy(&result)

	testing.expect(t, !result.ok)
	testing.expect(t, strings.contains(result.reason, "core:mem"))
	testing.expect_value(t, result.output, "")
	testing.expect_value(t, result.exit_code, 0)

	// The gate runs before anything touches the work directory, so neither the
	// source nor a binary exists: there was nothing to compile.
	testing.expect(t, !os.exists(fmt.tprintf("%s/script.odin", dir)))
	testing.expect(t, !os.exists(fmt.tprintf("%s/script", dir)))

	files, list_err := os.read_directory_by_path(dir, -1, context.allocator)
	defer os.file_info_slice_delete(files, context.allocator)
	testing.expect(t, list_err == nil)
	testing.expect_value(t, len(files), 0)
}

@(test)
test_script_run_compile_failure_reports_the_compiler :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	result := script_run(
		Script_Run_Config {
			// Parses cleanly, so the gate passes; the compiler rejects the call.
			source = `
package script

main :: proc() {
	missing_symbol()
}
`,
			work_dir = dir,
		},
	)
	defer script_run_test_result_destroy(&result)

	testing.expect(t, !result.ok)
	testing.expect(t, !result.timed_out)
	testing.expect(t, len(result.reason) > 0)
	testing.expect(t, strings.contains(result.reason, "missing_symbol"))
	script_run_test_expect_no_socket(t, dir)
}

@(test)
test_script_run_nonzero_exit_keeps_its_output :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	result := script_run(
		Script_Run_Config {
			// A crash, not a chosen exit code: the script dies by panicking on an
			// out-of-bounds index after it prints.
			source = `
package script

import "core:fmt"

main :: proc() {
	fmt.println("about to stop")
	values := []int{0}
	index := 1
	fmt.println(values[index])
}
`,
			work_dir = dir,
		},
	)
	defer script_run_test_result_destroy(&result)

	testing.expect(t, !result.ok)
	testing.expect_value(t, result.timed_out, false)
	// A panic exits with a plain non-zero code; a signal-killed child would
	// report that instead, so only non-zero is asserted.
	testing.expect(t, result.exit_code != 0)
	testing.expect(t, strings.contains(result.output, "about to stop"))
	script_run_test_expect_no_socket(t, dir)
}

@(test)
test_script_run_script_exit_code_reaches_the_result :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	collection := script_run_test_collection()
	defer delete(collection)

	source := `
package main

import "core:fmt"
import "oreo:script"

main :: proc() {
	fmt.println("before the exit")
	script.exit(7)
}
`

	result := script_run(
		Script_Run_Config {
			source             = source,
			work_dir           = dir,
			extra_compile_args = []string{collection},
		},
	)
	defer script_run_test_result_destroy(&result)

	testing.expect(t, !result.ok)
	testing.expect_value(t, result.exit_code, 7)
	testing.expect(t, !result.timed_out)
	// The code is reported as the script chose it, and what it printed first is
	// not lost to the exit.
	testing.expect(t, strings.contains(result.reason, "7"))
	testing.expect(t, strings.contains(result.output, "before the exit"))
	script_run_test_expect_no_socket(t, dir)
}

@(test)
test_script_run_script_fail_shows_the_reason :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	collection := script_run_test_collection()
	defer delete(collection)

	source := `
package main

import "oreo:script"

main :: proc() {
	script.fail("something went wrong")
}
`

	result := script_run(
		Script_Run_Config {
			source             = source,
			work_dir           = dir,
			extra_compile_args = []string{collection},
		},
	)
	defer script_run_test_result_destroy(&result)

	testing.expect(t, !result.ok)
	testing.expect(t, result.exit_code != 0)
	testing.expect(t, !result.timed_out)
	testing.expect(t, strings.contains(result.output, "something went wrong"))
	script_run_test_expect_no_socket(t, dir)
}

@(test)
test_script_run_script_exit_zero_is_success :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	collection := script_run_test_collection()
	defer delete(collection)

	source := `
package main

import "core:fmt"
import "oreo:script"

main :: proc() {
	fmt.println("finished cleanly")
	script.exit(0)
}
`

	result := script_run(
		Script_Run_Config {
			source             = source,
			work_dir           = dir,
			extra_compile_args = []string{collection},
		},
	)
	defer script_run_test_result_destroy(&result)

	testing.expect(t, result.ok)
	testing.expect_value(t, result.exit_code, 0)
	testing.expect(t, !result.timed_out)
	testing.expect(t, strings.contains(result.output, "finished cleanly"))
	script_run_test_expect_no_socket(t, dir)
}

@(test)
test_script_run_kills_a_script_that_never_returns :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	start := time.tick_now()
	result := script_run(
		Script_Run_Config {
			// A bare loop needs no import at all.
			source = `
package script

main :: proc() {
	for {
	}
}
`,
			work_dir   = dir,
			timeout_ms = 1500,
		},
	)
	defer script_run_test_result_destroy(&result)
	wall_ms := i64(time.tick_since(start)) / i64(time.Millisecond)

	testing.expect(t, !result.ok)
	testing.expect_value(t, result.timed_out, true)
	// Generous: the point is that the call returns at all, not that it returns
	// at exactly the deadline.
	testing.expectf(t, wall_ms < 20_000, "script_run took %d ms, expected a bounded kill", wall_ms)
	script_run_test_expect_no_socket(t, dir)
}

@(test)
test_script_run_script_reads_a_file_through_the_server :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	note_path := fmt.aprintf("%s/note.txt", dir)
	defer delete(note_path)
	testing.expect(t, os.write_entire_file_from_string(note_path, "alpha\nbeta\n") == nil)

	collection := script_run_test_collection()
	defer delete(collection)

	// A generated script is Odin source full of braces, so it is assembled by
	// concatenation: fmt would read those braces as its own directives.
	source := strings.concatenate(
		{
			`
package main

import "core:fmt"
import "oreo:script"

main :: proc() {
	content, err := script.read("`,
			note_path,
			`")
	defer delete(content)
	defer script.error_destroy(&err)
	if err.message != "" {
		fmt.eprintln(err.message)
	}
	fmt.println(content)
}
`,
		},
	)
	defer delete(source)

	result := script_run(
		Script_Run_Config {
			source             = source,
			work_dir           = dir,
			extra_compile_args = []string{collection},
		},
	)
	defer script_run_test_result_destroy(&result)

	testing.expect(t, result.ok)
	testing.expect_value(t, result.exit_code, 0)
	testing.expect(t, !result.timed_out)
	// tool_read numbers its lines, so reading the host's own answer back shows
	// the script and the host actually talked, not that a constant was printed.
	testing.expect(t, strings.contains(result.output, "1\talpha"))
	testing.expect(t, strings.contains(result.output, "2\tbeta"))
	script_run_test_expect_no_socket(t, dir)
}

@(test)
test_script_run_script_calls_execute_through_the_server :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	collection := script_run_test_collection()
	defer delete(collection)

	source := strings.concatenate(
		{
			`
package main

import "core:fmt"
import "oreo:script"

main :: proc() {
	output, code, err := script.execute("printf hello-from-execute", "`,
			dir,
			`")
	defer delete(output)
	defer script.error_destroy(&err)
	if err.message != "" {
		fmt.eprintln(err.message)
	}
	fmt.println(output)
	fmt.printfln("code=%d", code)

	ignored, second_code, second_err := script.execute("exit 7", "`,
			dir,
			`")
	defer delete(ignored)
	defer script.error_destroy(&second_err)
	if second_err.message != "" {
		fmt.eprintln(second_err.message)
	}
	fmt.printfln("second_code=%d", second_code)
}
`,
		},
	)
	defer delete(source)

	result := script_run(
		Script_Run_Config {
			source             = source,
			work_dir           = dir,
			extra_compile_args = []string{collection},
		},
	)
	defer script_run_test_result_destroy(&result)

	testing.expect(t, result.ok)
	testing.expect(t, strings.contains(result.output, "hello-from-execute"))
	testing.expect(t, strings.contains(result.output, "code=0"))
	// A non-zero exit is a normal result the script inspects, not a failure.
	testing.expect(t, strings.contains(result.output, "second_code=7"))
	script_run_test_expect_no_socket(t, dir)
}

@(test)
test_script_run_kills_a_script_that_connects_and_then_hangs :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	note_path := fmt.aprintf("%s/note.txt", dir)
	defer delete(note_path)
	testing.expect(t, os.write_entire_file_from_string(note_path, "hello\n") == nil)

	collection := script_run_test_collection()
	defer delete(collection)

	source := strings.concatenate(
		{
			`
package main

import "oreo:script"

main :: proc() {
	// Connect and get one answer, then never return.
	content, err := script.read("`,
			note_path,
			`")
	defer delete(content)
	defer script.error_destroy(&err)
	for {
	}
}
`,
		},
	)
	defer delete(source)

	start := time.tick_now()
	result := script_run(
		Script_Run_Config {
			source             = source,
			work_dir           = dir,
			timeout_ms         = 1500,
			extra_compile_args = []string{collection},
		},
	)
	defer script_run_test_result_destroy(&result)
	wall_ms := i64(time.tick_since(start)) / i64(time.Millisecond)

	testing.expect(t, !result.ok)
	testing.expect_value(t, result.timed_out, true)
	testing.expectf(t, wall_ms < 20_000, "script_run took %d ms, expected a bounded kill", wall_ms)
	script_run_test_expect_no_socket(t, dir)
}

@(test)
test_script_run_does_not_wait_for_a_script_that_never_connects :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	start := time.tick_now()
	result := script_run(
		Script_Run_Config {
			source = `
package script

import "core:fmt"

main :: proc() {
	fmt.println("no socket needed")
}
`,
			work_dir   = dir,
			timeout_ms = 60_000,
		},
	)
	defer script_run_test_result_destroy(&result)
	wall_ms := i64(time.tick_since(start)) / i64(time.Millisecond)

	testing.expect(t, result.ok)
	testing.expect_value(t, result.exit_code, 0)
	testing.expect(t, !result.timed_out)
	testing.expect(t, strings.contains(result.output, "no socket needed"))
	// The listener must not hold the run open to its deadline.
	testing.expectf(t, wall_ms < 20_000, "script_run took %d ms waiting for a connection", wall_ms)
	script_run_test_expect_no_socket(t, dir)
}

@(test)
test_script_run_truncates_output_and_keeps_the_full_text :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	result := script_run(
		Script_Run_Config {
			source = `
package script

import "core:fmt"

main :: proc() {
	for _ in 0 ..< 2000 {
		fmt.print("aaaaaaaaaa\n")
	}
}
`,
			work_dir         = dir,
			max_output_bytes = 1000,
		},
	)
	defer script_run_test_result_destroy(&result)

	testing.expect(t, result.ok)
	testing.expect_value(t, result.output_truncated, true)
	testing.expect(t, strings.contains(result.output, "<omitted"))
	testing.expect(t, len(result.output) < 22_000)

	full_path := result.full_output_path
	testing.expect(t, full_path != "")
	testing.expect(t, os.exists(full_path))

	full, read_err := os.read_entire_file(full_path, context.allocator)
	defer delete(full)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, len(full), 2000 * 11)
}

@(test)
test_script_run_never_splits_a_utf8_rune :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	result := script_run(
		Script_Run_Config {
			// 500 three-byte runes; a 100-byte cap with a naive split would cut
			// both halves mid-rune.
			source = `
package script

import "core:fmt"

main :: proc() {
	for _ in 0 ..< 500 {
		fmt.print("€")
	}
}
`,
			work_dir         = dir,
			max_output_bytes = 100,
		},
	)
	defer script_run_test_result_destroy(&result)

	testing.expect(t, result.ok)
	testing.expect_value(t, result.output_truncated, true)
	testing.expect(t, strings.contains(result.output, "<omitted"))
	testing.expect(t, utf8.valid_string(result.output))

	full, read_err := os.read_entire_file(result.full_output_path, context.allocator)
	defer delete(full)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, len(full), 500 * 3)
	testing.expect(t, utf8.valid_string(string(full)))
}
