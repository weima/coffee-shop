package rachel_e2e

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

PASSING_TEST_MODULE :: `package demo

import "core:testing"

// value returns 1.
value :: proc() -> int {
	return 1
}

@(test)
test_value :: proc(t: ^testing.T) {
	testing.expect_value(t, value(), 1)
}
`

FAILING_TEST_MODULE :: `package demo

import "core:testing"

// value returns 1.
value :: proc() -> int {
	return 1
}

@(test)
test_wants_two :: proc(t: ^testing.T) {
	testing.expect_value(t, value(), 2)
}
`

@(test)
test_verify_runs_check_then_test_and_stops_on_failure :: proc(t: ^testing.T) {
	if !require_layout(t) {
		return
	}
	build := build_rachel(t)
	defer build_destroy(&build)
	if build.binary == "" {
		return
	}
	project := make_project(t)
	defer project_destroy(&project)
	if project == "" {
		return
	}
	justfile_path := fmt.aprintf("%s/justfile", project, allocator = context.allocator)
	defer delete(justfile_path, context.allocator)
	module_path := fmt.aprintf("%s/module.odin", project, allocator = context.allocator)
	defer delete(module_path, context.allocator)
	write_file(t, justfile_path, CUSTOM_JUSTFILE)

	write_file(t, module_path, PASSING_TEST_MODULE)
	ok_output, ok_err := run_to_output([]string{build.binary, "verify", project})
	defer output_destroy(&ok_output)
	testing.expectf(t, ok_err == nil, "verify would not run: %v", ok_err)
	testing.expectf(t, ok_output.exit_code == 0, "verify failed on a passing project: %q%s", ok_output.stdout, ok_output.stderr)
	testing.expectf(t, strings.has_prefix(ok_output.stdout, "rachel: check ok"), "missing check stage: %q", ok_output.stdout)
	testing.expectf(t, strings.contains(ok_output.stdout, "rachel: test ok (1 test)"), "missing test stage: %q", ok_output.stdout)

	write_file(t, module_path, FAILING_TEST_MODULE)
	fail_output, fail_err := run_to_output([]string{build.binary, "verify", project})
	defer output_destroy(&fail_output)
	testing.expectf(t, fail_err == nil, "verify would not run: %v", fail_err)
	testing.expect_value(t, fail_output.exit_code, 1)
	testing.expectf(t, strings.contains(fail_output.stdout, "rachel: check ok"), "check stage should still pass: %q", fail_output.stdout)
	testing.expectf(t, strings.contains(fail_output.stdout, "rachel: test fail"), "missing failing test stage: %q", fail_output.stdout)
	testing.expectf(t, strings.contains(fail_output.stdout, "test_wants_two"), "verdict does not name the failing test: %q", fail_output.stdout)
	testing.expectf(t, !strings.contains(fail_output.stdout, "rachel: test ok"), "failing run also reported test ok: %q", fail_output.stdout)
}
