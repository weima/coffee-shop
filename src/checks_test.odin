package main

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_run_check_success_and_empty_output :: proc(t: ^testing.T) {
	result := run_check(".", []string{"sh", "-c", "exit 0"})
	defer destroy_struct(&result)
	testing.expect(t, result.started && result.success)
	testing.expect_value(t, result.exit_code, 0)
	testing.expect_value(t, result.output_tail, "")
	testing.expect_value(t, result.detail, "exited with code 0")
}

@(test)
test_run_check_nonzero_exit :: proc(t: ^testing.T) {
	result := run_check(".", []string{"sh", "-c", "echo hi; exit 3"})
	defer destroy_struct(&result)
	testing.expect(t, result.started && !result.success)
	testing.expect_value(t, result.exit_code, 3)
	testing.expect_value(t, result.output_tail, "hi\n")
	testing.expect_value(t, result.detail, "exited with code 3")
}

@(test)
test_run_check_missing_executable_is_launch_failure :: proc(t: ^testing.T) {
	result := run_check(".", []string{"checks-no-such-executable"})
	defer destroy_struct(&result)
	testing.expect(t, !result.started && !result.success)
	testing.expect_value(t, result.exit_code, 0)
	testing.expect(t, strings.contains(result.detail, "checks-no-such-executable"), result.detail)
}

@(test)
test_run_check_captures_stderr_after_stdout :: proc(t: ^testing.T) {
	result := run_check(".", []string{"sh", "-c", "printf 'out\\n'; printf err >&2"})
	defer destroy_struct(&result)
	testing.expect_value(t, result.output_tail, "out\n--- stderr ---\nerr")
}

@(test)
test_run_check_truncates_tail_at_line_boundary :: proc(t: ^testing.T) {
	result := run_check(".", []string{"sh", "-c", "printf 'one\\ntwo\\nthree\\n'"}, 8)
	defer destroy_struct(&result)
	testing.expect_value(t, result.output_tail, "[output truncated]\nthree\n")
}

@(test)
test_run_check_uses_station_as_working_directory :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	result := run_check(root, []string{"sh", "-c", "pwd"})
	defer destroy_struct(&result)
	testing.expect_value(t, strings.trim_space(result.output_tail), root)
}

@(test)
test_command_text_quotes_shell_special_arguments :: proc(t: ^testing.T) {
	text := command_text([]string{"npm", "run", "test suite", "a;b", "plain"})
	defer delete(text)
	testing.expect_value(t, text, "npm run 'test suite' 'a;b' plain")
}

@(test)
test_run_check_keeps_the_raw_tail_when_the_last_line_exceeds_the_limit :: proc(t: ^testing.T) {
	// One very long final line has no line boundary inside the tail. Dropping it
	// would silently discard the only evidence, so the raw tail is kept instead.
	result := run_check(".", []string{"sh", "-c", "i=0; while [ $i -lt 100 ]; do printf x; i=$((i+1)); done; echo"}, 20)
	defer destroy_struct(&result)
	testing.expect(t, result.success)
	testing.expect(t, strings.has_prefix(result.output_tail, "[output truncated]\n"), result.output_tail)
	testing.expect(t, strings.contains(result.output_tail, "xxxxx"), result.output_tail)
}
