package rachel_e2e

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

count_prefixed_lines :: proc(text, prefix: string) -> int {
	count := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, prefix) {
			count += 1
		}
	}
	return count
}

@(test)
test_check_reports_every_error_with_relative_paths :: proc(t: ^testing.T) {
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
	write_file(t, fmt.tprintf("%s/justfile", project), CUSTOM_JUSTFILE)
	write_file(t, fmt.tprintf("%s/module.odin", project), VALID_MODULE)

	ok_output, ok_err := run_to_output([]string{build.binary, "check", project})
	defer output_destroy(&ok_output)
	testing.expectf(t, ok_err == nil, "check would not run: %v", ok_err)
	testing.expect_value(t, ok_output.exit_code, 0)
	testing.expectf(t, strings.has_prefix(ok_output.stdout, "rachel: ok (1 checked)"), "unexpected verdict: %q", ok_output.stdout)

	write_file(t, fmt.tprintf("%s/module.odin", project), TWO_ERROR_MODULE)
	fail_output, fail_err := run_to_output([]string{build.binary, "check", project})
	defer output_destroy(&fail_output)
	testing.expectf(t, fail_err == nil, "check would not run: %v", fail_err)
	testing.expect_value(t, fail_output.exit_code, 1)
	testing.expectf(t, strings.contains(fail_output.stdout, "rachel: fail (1 of 1, 2 errors)"), "summary missing: %q", fail_output.stdout)
	testing.expect_value(t, count_prefixed_lines(fail_output.stdout, "rachel: error module.odin("), 2)
	testing.expectf(t, !strings.contains(fail_output.stdout, "/module.odin("), "verdict still prints an absolute path: %q", fail_output.stdout)

	first_output, first_err := run_to_output([]string{build.binary, "check", "--max-errors", "1", project})
	defer output_destroy(&first_output)
	testing.expectf(t, first_err == nil, "check would not run: %v", first_err)
	testing.expect_value(t, first_output.exit_code, 1)
	testing.expect_value(t, count_prefixed_lines(first_output.stdout, "rachel: error module.odin("), 1)
	testing.expectf(t, strings.contains(first_output.stdout, "rachel: error ... (1 more)"), "missing remainder line: %q", first_output.stdout)
}

@(test)
test_check_narrows_to_the_changed_package :: proc(t: ^testing.T) {
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
	write_file(t, fmt.tprintf("%s/module.odin", project), VALID_MODULE)
	_ = os.make_directory(fmt.tprintf("%s/sub", project))
	write_file(t, fmt.tprintf("%s/sub/other.odin", project), "package sub\n\n// two returns 2.\ntwo :: proc() -> int {\n\treturn 2\n}\n")

	// A generated justfile takes a package argument, so the count distinguishes
	// a narrowed check from a whole-project one.
	whole_output, whole_err := run_to_output([]string{build.binary, "check", project})
	defer output_destroy(&whole_output)
	testing.expectf(t, whole_err == nil, "check would not run: %v", whole_err)
	testing.expectf(t, strings.contains(whole_output.stdout, "(2 checked)"), "whole project should check two packages: %q", whole_output.stdout)

	narrowed_output, narrowed_err := run_to_output([]string{build.binary, "check", project, fmt.tprintf("%s/sub/other.odin", project)})
	defer output_destroy(&narrowed_output)
	testing.expectf(t, narrowed_err == nil, "check would not run: %v", narrowed_err)
	testing.expectf(t, strings.contains(narrowed_output.stdout, "(1 checked)"), "narrowed check should check one package: %q", narrowed_output.stdout)
}
