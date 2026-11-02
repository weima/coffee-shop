package rachel_e2e

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

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
	ok_output, ok_err := run_to_output([]string{build.binary, "verify", "--no-lock", project})
	defer output_destroy(&ok_output)
	testing.expectf(t, ok_err == nil, "verify would not run: %v", ok_err)
	testing.expectf(t, ok_output.exit_code == 0, "verify failed on a passing project: %q%s", ok_output.stdout, ok_output.stderr)
	testing.expectf(t, strings.has_prefix(ok_output.stdout, "rachel: check ok"), "missing check stage: %q", ok_output.stdout)
	testing.expectf(t, strings.contains(ok_output.stdout, "rachel: test ok (1 test)"), "missing test stage: %q", ok_output.stdout)

	// The guard pushes .rachel/last.json, so a passing run must leave one.
	last_path := fmt.aprintf("%s/.rachel/last.json", project, allocator = context.allocator)
	defer delete(last_path, context.allocator)
	testing.expectf(t, os.is_file(last_path), "passing verify left no last verdict file")
	last_data, last_err := os.read_entire_file(last_path, context.allocator)
	if last_err == nil {
		defer delete(last_data)
		last_text := transmute(string)last_data
		testing.expectf(t, strings.contains(last_text, "rachel: check ok"), "last verdict lacks the check line: %q", last_text)
		testing.expectf(t, strings.contains(last_text, `"ok":true`), "last verdict is not marked ok: %q", last_text)
	}

	write_file(t, module_path, FAILING_TEST_MODULE)
	fail_output, fail_err := run_to_output([]string{build.binary, "verify", "--no-lock", project})
	defer output_destroy(&fail_output)
	testing.expectf(t, fail_err == nil, "verify would not run: %v", fail_err)
	testing.expect_value(t, fail_output.exit_code, 1)
	testing.expectf(t, strings.contains(fail_output.stdout, "rachel: check ok"), "check stage should still pass: %q", fail_output.stdout)
	testing.expectf(t, strings.contains(fail_output.stdout, "rachel: test fail"), "missing failing test stage: %q", fail_output.stdout)
	testing.expectf(t, strings.contains(fail_output.stdout, "test_wants_two"), "verdict does not name the failing test: %q", fail_output.stdout)
	testing.expectf(t, !strings.contains(fail_output.stdout, "rachel: test ok"), "failing run also reported test ok: %q", fail_output.stdout)
}

VERIFY_JUSTFILE :: `check:
    odin check -no-entry-point .

test:
    TZ=UTC odin test .

e2e:
    sh -c "exit 0"
`

@(test)
test_verify_stage_selection_all_and_skip :: proc(t: ^testing.T) {
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
	write_file(t, justfile_path, VERIFY_JUSTFILE)
	write_file(t, module_path, FAILING_TEST_MODULE)

	// Selection: only the check stage runs, so the failing test cannot fail verify.
	check_only, check_err := run_to_output([]string{build.binary, "verify", "--no-lock", "--stages", "check", project})
	defer output_destroy(&check_only)
	testing.expectf(t, check_err == nil, "verify would not run: %v", check_err)
	testing.expect_value(t, check_only.exit_code, 0)
	testing.expectf(t, strings.contains(check_only.stdout, "rachel: check ok"), "missing check stage: %q", check_only.stdout)
	testing.expectf(t, !strings.contains(check_only.stdout, "rachel: test"), "test stage ran when not selected: %q", check_only.stdout)

	// Default ladder stops at the failing test.
	stopped, stopped_err := run_to_output([]string{build.binary, "verify", "--no-lock", "--stages", "check,test,e2e", project})
	defer output_destroy(&stopped)
	testing.expectf(t, stopped_err == nil, "verify would not run: %v", stopped_err)
	testing.expect_value(t, stopped.exit_code, 1)
	testing.expectf(t, strings.contains(stopped.stdout, "rachel: test fail"), "missing test failure: %q", stopped.stdout)
	testing.expectf(t, !strings.contains(stopped.stdout, "rachel: e2e"), "e2e ran after a failed stage: %q", stopped.stdout)

	// --all continues past the failure.
	every, every_err := run_to_output([]string{build.binary, "verify", "--no-lock", "--all", "--stages", "check,test,e2e", project})
	defer output_destroy(&every)
	testing.expectf(t, every_err == nil, "verify would not run: %v", every_err)
	testing.expect_value(t, every.exit_code, 1)
	testing.expectf(t, strings.contains(every.stdout, "rachel: e2e ok"), "--all did not run e2e: %q", every.stdout)

	// A stage with no recipe is a skip, not a failure.
	write_file(t, justfile_path, CUSTOM_JUSTFILE)
	skipped, skipped_err := run_to_output([]string{build.binary, "verify", "--no-lock", "--stages", "check,e2e", project})
	defer output_destroy(&skipped)
	testing.expectf(t, skipped_err == nil, "verify would not run: %v", skipped_err)
	testing.expect_value(t, skipped.exit_code, 0)
	testing.expectf(t, strings.contains(skipped.stdout, "rachel: e2e skip (no recipe)"), "missing skip line: %q", skipped.stdout)
}

@(test)
test_failing_verify_writes_evidence_and_passing_writes_none :: proc(t: ^testing.T) {
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
	evidence_root := fmt.aprintf("%s/.rachel/evidence", project, allocator = context.allocator)
	defer delete(evidence_root, context.allocator)
	write_file(t, justfile_path, CUSTOM_JUSTFILE)

	write_file(t, module_path, PASSING_TEST_MODULE)
	passing, passing_err := run_to_output([]string{build.binary, "verify", "--no-lock", project})
	defer output_destroy(&passing)
	testing.expectf(t, passing_err == nil, "verify would not run: %v", passing_err)
	testing.expect_value(t, passing.exit_code, 0)
	testing.expectf(t, !os.exists(evidence_root), "a passing stage wrote evidence")

	write_file(t, module_path, FAILING_TEST_MODULE)
	failing, failing_err := run_to_output([]string{build.binary, "verify", "--no-lock", project})
	defer output_destroy(&failing)
	testing.expectf(t, failing_err == nil, "verify would not run: %v", failing_err)
	testing.expect_value(t, failing.exit_code, 1)
	testing.expectf(t, strings.contains(failing.stdout, "rachel: evidence .rachel/evidence/"), "no evidence line: %q", failing.stdout)

	entries, read_err := os.read_all_directory_by_path(evidence_root, context.allocator)
	testing.expectf(t, read_err == nil, "no evidence directory: %v", read_err)
	if read_err != nil {
		return
	}
	defer os.file_info_slice_delete(entries, context.allocator)
	runs := 0
	for entry in entries {
		if entry.type == .Directory {
			runs += 1
		}
	}
	testing.expect_value(t, runs, 1)

	last, last_err := run_to_output([]string{build.binary, "evidence", "last", project})
	defer output_destroy(&last)
	testing.expectf(t, last_err == nil, "evidence last would not run: %v", last_err)
	testing.expect_value(t, last.exit_code, 0)
	testing.expectf(t, strings.contains(last.stdout, ".rachel/evidence/"), "evidence last printed no path: %q", last.stdout)
}

TS_CONFIG :: `{
  "compilerOptions": { "strict": true, "noEmit": true, "target": "ES2020" },
  "files": ["a.ts"]
}
`

BAD_TS :: `const value: number = "not a number";
export { value };
`

GOOD_TS :: `const value: number = 1;
export { value };
`

@(test)
test_typescript_project_compiles_with_tsc :: proc(t: ^testing.T) {
	if !require_layout(t) {
		return
	}
	if !has_tool("tsc") {
		fmt.println("SKIP: tsc is not installed")
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
	tsconfig_path := fmt.aprintf("%s/tsconfig.json", project, allocator = context.allocator)
	defer delete(tsconfig_path, context.allocator)
	source_path := fmt.aprintf("%s/a.ts", project, allocator = context.allocator)
	defer delete(source_path, context.allocator)
	justfile_path := fmt.aprintf("%s/justfile", project, allocator = context.allocator)
	defer delete(justfile_path, context.allocator)
	write_file(t, tsconfig_path, TS_CONFIG)
	write_file(t, source_path, BAD_TS)

	failing, failing_err := run_to_output([]string{build.binary, "check", project})
	defer output_destroy(&failing)
	testing.expectf(t, failing_err == nil, "check would not run: %v", failing_err)
	testing.expect_value(t, failing.exit_code, 1)
	testing.expectf(t, strings.contains(failing.stdout, "rachel: fail"), "no failure verdict: %q", failing.stdout)
	testing.expectf(t, strings.contains(failing.stdout, "error TS2322"), "tsc diagnostic missing: %q", failing.stdout)

	// The starter justfile must match the language.
	testing.expectf(t, os.is_file(justfile_path), "no starter justfile for a TS project")
	generated, generated_err := os.read_entire_file(justfile_path, context.allocator)
	if generated_err == nil {
		defer delete(generated)
		testing.expectf(t, strings.contains(transmute(string)generated, "tsc --noEmit"), "starter justfile is not a TS one")
	}

	write_file(t, source_path, GOOD_TS)
	passing, passing_err := run_to_output([]string{build.binary, "check", project})
	defer output_destroy(&passing)
	testing.expectf(t, passing_err == nil, "check would not run: %v", passing_err)
	testing.expect_value(t, passing.exit_code, 0)
	testing.expectf(t, strings.contains(passing.stdout, "rachel: ok"), "no passing verdict: %q", passing.stdout)
}

SLOW_CHECK_JUSTFILE :: `check:
    sh -c "sleep 1.5"

test:
    sh -c "true"
`

@(test)
test_verify_serialises_on_the_machine_lock :: proc(t: ^testing.T) {
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
	lock_path := fmt.aprintf("%s/lock", build.dir, allocator = context.allocator)
	defer delete(lock_path, context.allocator)
	first_log := fmt.aprintf("%s/first.log", build.dir, allocator = context.allocator)
	defer delete(first_log, context.allocator)
	write_file(t, justfile_path, SLOW_CHECK_JUSTFILE)

	// A holds the lock for ~1.5 s.
	first, start_err := spawn_to_log([]string{build.binary, "verify", "--lock-path", lock_path, project}, first_log)
	testing.expectf(t, start_err == nil, "cannot start the first verify: %v", start_err)
	if start_err != nil {
		return
	}
	defer stop_process(first)
	time.sleep(400 * time.Millisecond)

	// B must refuse rather than measure under load.
	refused, refused_err := run_to_output([]string{build.binary, "verify", "--no-wait", "--lock-path", lock_path, project})
	defer output_destroy(&refused)
	testing.expectf(t, refused_err == nil, "verify would not run: %v", refused_err)
	testing.expect_value(t, refused.exit_code, 1)
	testing.expectf(t, strings.contains(refused.stdout, "another verify is running"), "no refusal message: %q", refused.stdout)

	// C waits and then runs.
	waited, waited_err := run_to_output([]string{build.binary, "verify", "--lock-path", lock_path, project})
	defer output_destroy(&waited)
	testing.expectf(t, waited_err == nil, "verify would not run: %v", waited_err)
	testing.expectf(t, strings.contains(waited.stderr, "another verify held the lock"), "no wait message: %q", waited.stderr)
	testing.expect_value(t, waited.exit_code, 0)
}
