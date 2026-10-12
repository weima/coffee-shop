package oreo

import "core:fmt"
import "core:os"
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
}

@(test)
test_script_run_nonzero_exit_keeps_its_output :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	result := script_run(
		Script_Run_Config {
			source = `
package script

import "core:fmt"
import "core:os"

main :: proc() {
	fmt.println("about to stop")
	os.exit(7)
}
`,
			work_dir = dir,
		},
	)
	defer script_run_test_result_destroy(&result)

	testing.expect(t, !result.ok)
	testing.expect_value(t, result.exit_code, 7)
	testing.expect_value(t, result.timed_out, false)
	testing.expect(t, strings.contains(result.output, "about to stop"))
}

@(test)
test_script_run_kills_a_script_that_never_returns :: proc(t: ^testing.T) {
	dir := script_run_test_work_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)

	start := time.tick_now()
	result := script_run(
		Script_Run_Config {
			source = `
package script

import "core:os"

main :: proc() {
	for {
		_ = os.get_pid()
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
