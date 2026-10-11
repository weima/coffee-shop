package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_cli_accepts_one_existing_project_directory :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp("", "rachel-cli-*", context.allocator)
	testing.expect(t, make_err == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}

	options, parse_err := parse_cli_args([]string{"rachel", root}, context.allocator)
	defer options_destroy(&options, context.allocator)
	testing.expect(t, parse_err == nil)
	testing.expect_value(t, options.root, root)
}

@(test)
test_cli_rejects_missing_or_invalid_directory :: proc(t: ^testing.T) {
	_, usage_err := parse_cli_args([]string{"rachel"}, context.allocator)
	testing.expect(t, usage_err != nil)
	_, directory_err := parse_cli_args([]string{"rachel", "/definitely/not/a/rachel/project"}, context.allocator)
	testing.expect(t, directory_err != nil)
}

@(test)
test_odin_check_captures_compiler_failure_for_terminal_report :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp("", "rachel-odin-*", context.allocator)
	testing.expect(t, make_err == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	fake_odin, path_err := filepath.join({root, "fake-odin"})
	testing.expect(t, path_err == nil)
	defer delete(fake_odin)
	_ = os.write_entire_file_from_string(fake_odin, "#!/bin/sh\nprintf '%s\\n' \"$1\" \"$2\" \"$3\"\nprintf 'fake compiler error\\n' >&2\nexit 3\n", os.Permissions{.Read_User, .Write_User, .Execute_User})

	result := run_odin_check(root, fake_odin, context.allocator)
	defer odin_command_result_destroy(&result, context.allocator)
	testing.expect(t, result.process_error == nil)
	testing.expect(t, result.state.exited)
	testing.expect_value(t, result.state.exit_code, 3)
	testing.expect(t, !result.state.success)
	testing.expect_value(t, string(result.stdout), "check\n-no-entry-point\n.\n")
	testing.expect(t, strings.contains(string(result.stderr), "fake compiler error"))
}

@(test)
test_odin_test_detects_leak_warning_even_with_zero_exit :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp("", "rachel-leak-*", context.allocator)
	testing.expect(t, make_err == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	fake_odin, path_err := filepath.join({root, "fake-odin"})
	testing.expect(t, path_err == nil)
	defer delete(fake_odin)
	_ = os.write_entire_file_from_string(
		fake_odin,
		"#!/bin/sh\nprintf 'test\\n.\\n'\nprintf '[WARN] leaked test\\n+++ leak 8B\\n' >&2\nexit 0\n",
		os.Permissions{.Read_User, .Write_User, .Execute_User},
	)

	result := run_odin_test(root, fake_odin, context.allocator)
	defer odin_command_result_destroy(&result, context.allocator)
	testing.expect(t, result.process_error == nil)
	testing.expect(t, result.state.success)
	testing.expect(t, odin_test_has_allocator_leak(result))
	testing.expect(t, !odin_test_result_success(result))
}

@(test)
test_procedure_scan_reports_intent_comments_and_missing_comments :: proc(t: ^testing.T) {
	source := "package sample\n// Returns the stable package name.\n@(private)\npackage_name :: proc() -> string { return \"sample\" }\n\nunreviewed :: proc() {}\n"
	procedures, scan_err := scan_procedure_declarations(source, context.allocator)
	defer procedure_declarations_destroy(procedures, context.allocator)
	testing.expect_value(t, scan_err, os.Error(nil))
	testing.expect_value(t, len(procedures), 2)
	testing.expect_value(t, procedures[0].name, "package_name")
	testing.expect(t, procedures[0].has_intent_comment)
	testing.expect_value(t, procedures[1].name, "unreviewed")
	testing.expect(t, !procedures[1].has_intent_comment)
}

@(test)
test_missing_contract_report_includes_only_new_undocumented_procs :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp("", "rachel-contract-*", context.allocator)
	testing.expect(t, make_err == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	module_path, path_err := filepath.join({root, "module.odin"})
	testing.expect(t, path_err == nil)
	defer delete(module_path)
	_ = os.write_entire_file_from_string(
		module_path,
		"package sample\n// Existing behavior.\nexisting :: proc() {}\n",
		os.Permissions{.Read_User, .Write_User},
	)
	before, before_err := scan_odin_project(root, context.allocator)
	defer project_snapshot_destroy(&before)
	testing.expect_value(t, before_err, os.Error(nil))

	_ = os.write_entire_file_from_string(
		module_path,
		"package sample\n// Existing behavior.\nexisting :: proc() {}\n// New documented behavior.\nadded_good :: proc() {}\nadded_plain :: proc() {}\n",
		os.Permissions{.Read_User, .Write_User},
	)
	after, after_err := scan_odin_project(root, context.allocator, &before)
	defer project_snapshot_destroy(&after)
	testing.expect_value(t, after_err, os.Error(nil))
	warnings := new_procedure_contract_warnings(before.files[0].procedures, after.files[0].procedures, context.allocator)
	defer delete_string_slice(warnings, context.allocator)
	testing.expect_value(t, len(warnings), 1)
	testing.expect_value(t, warnings[0], "[WARN] new procedure added_plain (line 6) has no intent comment")
}

@(test)
test_changed_source_gets_a_non_overwriting_companion_test_file :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp("", "rachel-companion-*", context.allocator)
	testing.expect(t, make_err == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	module_path, path_err := filepath.join({root, "module.odin"})
	testing.expect(t, path_err == nil)
	defer delete(module_path)
	test_path, test_path_err := filepath.join({root, "module_test.odin"})
	testing.expect(t, test_path_err == nil)
	defer delete(test_path)
	recursive_path, recursive_path_err := filepath.join({root, "module_test_test.odin"})
	testing.expect(t, recursive_path_err == nil)
	defer delete(recursive_path)
	_ = os.write_entire_file_from_string(module_path, "package sample\nvalue :: 1\n", os.Permissions{.Read_User, .Write_User})
	before, before_err := scan_odin_project(root, context.allocator)
	defer project_snapshot_destroy(&before)
	testing.expect_value(t, before_err, os.Error(nil))
	_ = os.write_entire_file_from_string(module_path, "package sample\nvalue :: 22\n", os.Permissions{.Read_User, .Write_User})
	after, after_err := scan_odin_project(root, context.allocator, &before)
	defer project_snapshot_destroy(&after)
	testing.expect_value(t, after_err, os.Error(nil))

	created, ensure_err := ensure_companion_test_files(before, after, after.files[0].package_dir, context.allocator)
	testing.expect_value(t, ensure_err, os.Error(nil))
	testing.expect(t, created)
	generated, read_err := os.read_entire_file(test_path, context.allocator)
	testing.expect_value(t, read_err, os.Error(nil))
	testing.expect_value(t, transmute(string)generated, "package sample\n// Tests for module.odin.\n")
	delete(generated)

	_ = os.write_entire_file_from_string(test_path, "package sample\n// Human-owned tests.\n", os.Permissions{.Read_User, .Write_User})
	created, ensure_err = ensure_companion_test_files(before, after, root, context.allocator)
	testing.expect_value(t, ensure_err, os.Error(nil))
	testing.expect(t, !created)
	generated, read_err = os.read_entire_file(test_path, context.allocator)
	testing.expect_value(t, read_err, os.Error(nil))
	testing.expect_value(t, transmute(string)generated, "package sample\n// Human-owned tests.\n")
	delete(generated)

	with_test_file, test_scan_err := scan_odin_project(root, context.allocator, &after)
	defer project_snapshot_destroy(&with_test_file)
	testing.expect_value(t, test_scan_err, os.Error(nil))
	created, ensure_err = ensure_companion_test_files(after, with_test_file, after.files[0].package_dir, context.allocator)
	testing.expect_value(t, ensure_err, os.Error(nil))
	testing.expect(t, !created)
	testing.expect(t, !os.exists(recursive_path))
}

@(test)
test_local_generator_appends_a_test_and_package_test_passes :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp("", "rachel-generator-*", context.allocator)
	testing.expect(t, make_err == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	module_path, module_path_err := filepath.join({root, "module.odin"})
	testing.expect(t, module_path_err == nil)
	defer delete(module_path)
	test_path, test_path_err := filepath.join({root, "module_test.odin"})
	testing.expect(t, test_path_err == nil)
	defer delete(test_path)
	generator_path, generator_path_err := filepath.join({root, "fake-generator"})
	testing.expect(t, generator_path_err == nil)
	defer delete(generator_path)
	permissions := os.Permissions{.Read_User, .Write_User}
	_ = os.write_entire_file_from_string(module_path, "package sample\n// Add two integers.\nadd :: proc(a, b: int) -> int { return a + b }\n", permissions)
	_ = os.write_entire_file_from_string(
		test_path,
		"package sample\n// Tests for module.odin.\n@(test)\ntest_add :: proc(t: ^testing.T) { testing.expect_value(t, add(2, 3), 5) }\n",
		permissions,
	)
	fake_generator := `#!/bin/sh
request=$(cat)
case "$request" in *procedure_name*) ;; *) echo "missing procedure name" >&2; exit 4 ;; esac
printf '%s\n' '{"protocol_version":1,"imports":["core:testing"],"test_source":"@(test)\ntest_multiply :: proc(t: ^testing.T) { testing.expect_value(t, multiply(2, 3), 6) }\n"}'
`
	_ = os.write_entire_file_from_string(generator_path, fake_generator, os.Permissions{.Read_User, .Write_User, .Execute_User})

	before, before_err := scan_odin_project(root, context.allocator)
	defer project_snapshot_destroy(&before)
	testing.expect_value(t, before_err, os.Error(nil))
	_ = os.write_entire_file_from_string(module_path, "package sample\n// Add two integers.\nadd :: proc(a, b: int) -> int { return a + b }\n// Multiply two integers.\nmultiply :: proc(a, b: int) -> int { return a * b }\n", permissions)
	after, after_err := scan_odin_project(root, context.allocator, &before)
	defer project_snapshot_destroy(&after)
	testing.expect_value(t, after_err, os.Error(nil))

	generated_count, generation_err := generate_tests_for_changed_procedures(generator_path, before, after, after.files[0].package_dir, context.allocator)
	testing.expect_value(t, generation_err, os.Error(nil))
	testing.expect_value(t, generated_count, 1)
	test_data, read_err := os.read_entire_file(test_path, context.allocator)
	defer delete(test_data)
	testing.expect_value(t, read_err, os.Error(nil))
	testing.expect(t, strings.contains(transmute(string)test_data, "test_multiply"))
	testing.expect(t, strings.contains(transmute(string)test_data, `import "core:testing"`))

	test_result := run_odin_test(root, "odin", context.allocator)
	defer odin_command_result_destroy(&test_result, context.allocator)
	testing.expect(t, odin_test_result_success(test_result), transmute(string)test_result.stderr)
	generated_count, generation_err = generate_tests_for_changed_procedures(generator_path, before, after, after.files[0].package_dir, context.allocator)
	testing.expect_value(t, generation_err, os.Error(nil))
	testing.expect_value(t, generated_count, 0)
}

@(test)
test_missing_justfile_is_created_and_runs_package_check_and_tests :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp("", "rachel-just-*", context.allocator)
	testing.expect(t, make_err == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	package_dir, package_path_err := filepath.join({root, "pkg with spaces"})
	testing.expect(t, package_path_err == nil)
	defer delete(package_dir)
	_ = os.make_directory(package_dir)
	module_path, path_err := filepath.join({package_dir, "module.odin"})
	testing.expect(t, path_err == nil)
	defer delete(module_path)
	test_path, test_path_err := filepath.join({package_dir, "module_test.odin"})
	testing.expect(t, test_path_err == nil)
	defer delete(test_path)
	permissions := os.Permissions{.Read_User, .Write_User}
	_ = os.write_entire_file_from_string(module_path, "package sample\nvalue :: 7\n", permissions)
	_ = os.write_entire_file_from_string(
		test_path,
		"package sample\nimport \"core:testing\"\n@(test)\ntest_value :: proc(t: ^testing.T) { testing.expect_value(t, value, 7) }\n",
		permissions,
	)

	justfile, ensure_err := ensure_project_justfile(root, context.allocator)
	defer justfile_destroy(&justfile, context.allocator)
	testing.expect_value(t, ensure_err, os.Error(nil))
	testing.expect(t, justfile.generated)
	check_result := run_just_recipe(justfile, root, "check", package_dir, context.allocator)
	defer odin_command_result_destroy(&check_result, context.allocator)
	testing.expect(t, odin_command_succeeded(check_result), transmute(string)check_result.stderr)
	test_result := run_just_recipe(justfile, root, "test", package_dir, context.allocator)
	defer odin_command_result_destroy(&test_result, context.allocator)
	testing.expect(t, odin_test_result_success(Odin_Command_Result{
		state = test_result.state,
		stdout = test_result.stdout,
		stderr = test_result.stderr,
		process_error = test_result.process_error,
	}), transmute(string)test_result.stderr)
}

@(test)
test_existing_justfile_is_never_overwritten :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp("", "rachel-existing-just-*", context.allocator)
	testing.expect(t, make_err == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	path, path_err := filepath.join({root, "justfile"})
	testing.expect(t, path_err == nil)
	defer delete(path)
	original := "check:\n    echo custom-check\n\ntest:\n    echo custom-test\n"
	_ = os.write_entire_file_from_string(path, original, os.Permissions{.Read_User, .Write_User})

	justfile, ensure_err := ensure_project_justfile(root, context.allocator)
	defer justfile_destroy(&justfile, context.allocator)
	testing.expect_value(t, ensure_err, os.Error(nil))
	testing.expect(t, !justfile.generated)
	check_result := run_just_recipe(justfile, root, "check", "", context.allocator)
	defer odin_command_result_destroy(&check_result, context.allocator)
	testing.expect(t, odin_command_succeeded(check_result))
	testing.expect(t, strings.contains(transmute(string)check_result.stdout, "custom-check"))
	test_result := run_just_recipe(justfile, root, "test", "", context.allocator)
	defer odin_command_result_destroy(&test_result, context.allocator)
	testing.expect(t, odin_command_succeeded(test_result))
	testing.expect(t, strings.contains(transmute(string)test_result.stdout, "custom-test"))
	contents, read_err := os.read_entire_file(path, context.allocator)
	defer delete(contents)
	testing.expect_value(t, read_err, os.Error(nil))
	testing.expect_value(t, transmute(string)contents, original)
}

@(test)
test_test_file_classifier_flags_production_procs_not_odin_tests :: proc(t: ^testing.T) {
	production := "package sample\nmemory_usage_test :: proc() {}\n"
	real_test := "package sample\n@(test)\nverify_memory :: proc(t: ^testing.T) {}\n"
	comment_only := "package sample\n// unused :: proc() {}\n"
	testing.expect(t, test_file_looks_like_production(production))
	testing.expect(t, !test_file_looks_like_production(real_test))
	testing.expect(t, !test_file_looks_like_production(comment_only))
}

@(test)
test_project_scan_finds_odin_files_and_skips_git_directory :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp("", "rachel-scan-*", context.allocator)
	testing.expect(t, make_err == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	source_dir, path_err := filepath.join({root, "src"})
	testing.expect(t, path_err == nil)
	defer delete(source_dir)
	_ = os.make_directory(source_dir)
	git_dir, git_path_err := filepath.join({root, ".git"})
	testing.expect(t, git_path_err == nil)
	defer delete(git_dir)
	_ = os.make_directory(git_dir)
	source_path, source_path_err := filepath.join({source_dir, "module.odin"})
	testing.expect(t, source_path_err == nil)
	defer delete(source_path)
	git_source_path, git_source_path_err := filepath.join({git_dir, "object.odin"})
	testing.expect(t, git_source_path_err == nil)
	defer delete(git_source_path)
	_ = os.write_entire_file_from_string(source_path, "package sample\n", os.Permissions{.Read_User, .Write_User})
	_ = os.write_entire_file_from_string(git_source_path, "package ignored\n", os.Permissions{.Read_User, .Write_User})

	snapshot, scan_err := scan_odin_project(root, context.allocator)
	defer project_snapshot_destroy(&snapshot)
	testing.expect_value(t, scan_err, os.Error(nil))
	testing.expect_value(t, len(snapshot.files), 1)
	testing.expect(t, strings.has_suffix(snapshot.files[0].path, "/src/module.odin"))
}

@(test)
test_package_detects_reserved_test_file_suffix :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp("", "rachel-test-suffix-*", context.allocator)
	testing.expect(t, make_err == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	module_path, path_err := filepath.join({root, "module.odin"})
	testing.expect(t, path_err == nil)
	defer delete(module_path)
	test_path, test_path_err := filepath.join({root, "module_test.odin"})
	testing.expect(t, test_path_err == nil)
	defer delete(test_path)
	_ = os.write_entire_file_from_string(module_path, "package sample\n", os.Permissions{.Read_User, .Write_User})
	before, scan_err := scan_odin_project(root, context.allocator)
	defer project_snapshot_destroy(&before)
	testing.expect_value(t, scan_err, os.Error(nil))
	testing.expect(t, !package_has_test_file(before, before.files[0].package_dir))

	_ = os.write_entire_file_from_string(test_path, "package sample\n", os.Permissions{.Read_User, .Write_User})
	after, after_err := scan_odin_project(root, context.allocator)
	defer project_snapshot_destroy(&after)
	testing.expect_value(t, after_err, os.Error(nil))
	testing.expect(t, package_has_test_file(after, after.files[0].package_dir))
}

@(test)
test_project_scan_reports_package_when_odin_source_changes :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp("", "rachel-change-*", context.allocator)
	testing.expect(t, make_err == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	source_path, path_err := filepath.join({root, "module.odin"})
	testing.expect(t, path_err == nil)
	defer delete(source_path)
	_ = os.write_entire_file_from_string(source_path, "package sample\n", os.Permissions{.Read_User, .Write_User})
	before, before_err := scan_odin_project(root, context.allocator)
	defer project_snapshot_destroy(&before)
	testing.expect_value(t, before_err, os.Error(nil))

	_ = os.write_entire_file_from_string(source_path, "package sample\n// changed\n", os.Permissions{.Read_User, .Write_User})
	after, after_err := scan_odin_project(root, context.allocator)
	defer project_snapshot_destroy(&after)
	testing.expect_value(t, after_err, os.Error(nil))
	changed, change_err := changed_package_dirs(before, after, context.allocator)
	defer delete_string_slice(changed, context.allocator)
	testing.expect_value(t, change_err, os.Error(nil))
	testing.expect_value(t, len(changed), 1)
	testing.expect_value(t, changed[0], after.files[0].package_dir)
}
