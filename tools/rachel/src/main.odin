package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

CLI_Options :: struct {
	root:       string,
	paths:      [dynamic]string,
	check_once: bool,
}

Rachel_Justfile :: struct {
	path: string,
	generated: bool,
}

RACHEL_DEFAULT_JUSTFILE :: `# Rachel-generated defaults; edit for collections or custom linker flags.
set shell := ["sh", "-cu"]

check package=".":
    odin check -no-entry-point {{quote(package)}}

test package=".":
    TZ=UTC odin test {{quote(package)}}
`

parse_cli_args :: proc(args: []string, allocator := context.allocator) -> (options: CLI_Options, err: os.Error) {
	rest := args[1:]
	if len(rest) > 0 && rest[0] == "check" {
		options.check_once = true
		rest = rest[1:]
	}
	if len(rest) < 1 {
		return {}, os.Error(.Invalid_Command)
	}
	if !os.is_dir(rest[0]) {
		return {}, os.Error(.Invalid_Dir)
	}
	root, clone_err := strings.clone(rest[0], allocator)
	if clone_err != nil {
		return {}, os.Error(clone_err)
	}
	options.root = root
	if len(rest) > 1 && !options.check_once {
		options_destroy(&options, allocator)
		return {}, os.Error(.Invalid_Command)
	}
	for path in rest[1:] {
		cloned, path_err := strings.clone(path, allocator)
		if path_err != nil {
			options_destroy(&options, allocator)
			return {}, os.Error(path_err)
		}
		_, append_err := append(&options.paths, cloned)
		if append_err != nil {
			delete(cloned, allocator)
			options_destroy(&options, allocator)
			return {}, os.Error(append_err)
		}
	}
	return options, nil
}

options_destroy :: proc(options: ^CLI_Options, allocator := context.allocator) {
	delete(options.root, allocator)
	delete_string_slice(options.paths, allocator)
	options^ = CLI_Options{}
}

ensure_project_justfile :: proc(root: string, allocator := context.allocator) -> (justfile: Rachel_Justfile, err: os.Error) {
	for name in ([]string{"justfile", "Justfile", ".justfile"}) {
		path, path_err := filepath.join({root, name}, allocator)
		if path_err != nil {
			return {}, os.Error(path_err)
		}
		if os.is_file(path) {
			return Rachel_Justfile{path=path}, nil
		}
		if os.exists(path) {
			delete(path, allocator)
			return {}, os.Error(.Invalid_Path)
		}
		delete(path, allocator)
	}

	path, path_err := filepath.join({root, "justfile"}, allocator)
	if path_err != nil {
		return {}, os.Error(path_err)
	}
	file, open_err := os.open(path, {.Write, .Create, .Excl})
	if open_err != nil {
		if os.is_file(path) {
			return Rachel_Justfile{path=path}, nil
		}
		delete(path, allocator)
		return {}, open_err
	}
	_, write_err := os.write_string(file, RACHEL_DEFAULT_JUSTFILE)
	close_err := os.close(file)
	if write_err != nil {
		_ = os.remove(path)
		delete(path, allocator)
		return {}, write_err
	}
	if close_err != nil {
		_ = os.remove(path)
		delete(path, allocator)
		return {}, close_err
	}
	fmt.eprintfln("[RACHEL] Created default justfile %s", path)
	return Rachel_Justfile{path=path, generated=true}, nil
}

justfile_destroy :: proc(justfile: ^Rachel_Justfile, allocator := context.allocator) {
	delete(justfile.path, allocator)
	justfile^ = Rachel_Justfile{}
}

run_just_recipe :: proc(
	justfile: Rachel_Justfile,
	working_dir, recipe, package_dir: string,
	allocator := context.allocator,
) -> Odin_Command_Result {
	command := make([dynamic]string, 0, allocator)
	defer delete(command)
	for arg in ([]string{"just", "--justfile", justfile.path, "--working-directory", working_dir, recipe}) {
		_, _ = append(&command, arg)
	}
	if justfile.generated {
		_, _ = append(&command, package_dir)
	}
	state, stdout, stderr, process_err := os.process_exec(
		os.Process_Desc{working_dir=working_dir, command=command[:]},
		allocator,
	)
	return Odin_Command_Result{state=state, stdout=stdout, stderr=stderr, process_error=process_err}
}

main :: proc() {
	exit_code := run_cli(os.args)
	if exit_code != 0 {
		os.exit(exit_code)
	}
}

run_cli :: proc(args: []string) -> int {
	options, parse_err := parse_cli_args(args)
	if parse_err != nil {
		fmt.eprintln("Usage: rachel <odin-project-directory>")
		fmt.eprintln("       rachel check <odin-project-directory> [path ...]")
		fmt.eprintfln("[ERROR] %s", os.error_string(parse_err))
		return 2
	}
	defer options_destroy(&options)
	if options.check_once {
		return check_once(options)
	}
	return watch_project(options.root)
}

watch_project :: proc(root: string) -> int {
	current, scan_err := scan_odin_project(root)
	if scan_err != nil {
		fmt.eprintfln("[ERROR] cannot scan %s: %s", root, os.error_string(scan_err))
		return 1
	}
	defer project_snapshot_destroy(&current)
	justfile, justfile_err := ensure_project_justfile(root)
	if justfile_err != nil {
		fmt.eprintfln("[ERROR] cannot prepare Rachel's justfile in %s: %s", root, os.error_string(justfile_err))
		return 1
	}
	defer justfile_destroy(&justfile)
	generator_executable := os.get_env(RACHEL_TEST_GENERATOR_ENV, context.allocator)
	defer delete(generator_executable, context.allocator)
	warned_test_files := make([dynamic]string, 0, context.allocator)
	defer delete_string_slice(warned_test_files)
	packages, package_err := project_package_dirs(current)
	if package_err != nil {
		fmt.eprintfln("[ERROR] cannot list Odin packages: %s", os.error_string(package_err))
		return 1
	}
	if justfile.generated {
		for package_dir in packages {
			if run_and_report_just_check(justfile, root, package_dir) && package_has_test_file(current, package_dir) {
				run_and_report_just_test(justfile, root, package_dir)
			}
		}
	} else {
		check_ok := run_and_report_just_check(justfile, root, "")
		if check_ok && project_has_test_files(current) {
			run_and_report_just_test(justfile, root, "")
		}
	}
	delete_string_slice(packages)
	fmt.eprintfln("[RACHEL] Watching %s for Odin file changes. Press Ctrl-C to stop.", root)

	for {
		time.sleep(250 * time.Millisecond)
		next, next_err := scan_odin_project(root, context.allocator, &current)
		if next_err != nil {
			fmt.eprintfln("[ERROR] cannot scan %s: %s", root, os.error_string(next_err))
			continue
		}
		changed, diff_err := changed_package_dirs(current, next)
		if diff_err != nil {
			project_snapshot_destroy(&next)
			fmt.eprintfln("[ERROR] cannot compare Odin files: %s", os.error_string(diff_err))
			continue
		}
		if len(changed) > 0 {
			latest, latest_err := wait_for_quiet(root, &current)
			if latest_err != nil {
				delete_string_slice(changed)
				project_snapshot_destroy(&next)
				fmt.eprintfln("[ERROR] cannot scan %s: %s", root, os.error_string(latest_err))
				continue
			}
			stable_changes, stable_err := changed_package_dirs(current, latest)
			delete_string_slice(changed)
			project_snapshot_destroy(&next)
			if stable_err != nil {
				project_snapshot_destroy(&latest)
				fmt.eprintfln("[ERROR] cannot compare Odin files: %s", os.error_string(stable_err))
				continue
			}
			project_check_ok := true
			if !justfile.generated {
				project_check_ok = run_and_report_just_check(justfile, root, "")
			}
			validated_packages := make([dynamic]string, 0, context.allocator)
			test_file_created := false
			for package_dir in stable_changes {
				check_ok := project_check_ok
				if justfile.generated {
					check_ok = run_and_report_just_check(justfile, root, package_dir)
				}
				if !check_ok {
					continue
				}
				if append_err := append_unique_package(&validated_packages, package_dir, context.allocator); append_err != nil {
					fmt.eprintfln("[ERROR] cannot track changed package %s: %s", package_dir, os.error_string(append_err))
					continue
				}
				report_new_procedure_contract_warnings(current, latest, package_dir)
				created, create_err := ensure_companion_test_files(current, latest, package_dir)
				if create_err != nil {
					fmt.eprintfln("[ERROR] cannot create companion test file in %s: %s", package_dir, os.error_string(create_err))
				}
				test_file_created = test_file_created || created
				if create_err == nil {
					generated_count, generation_err := generate_tests_for_changed_procedures(
						generator_executable,
						current,
						latest,
						package_dir,
					)
					if generation_err != nil {
						fmt.eprintfln("[ERROR] test generation failed in %s: %s", package_dir, os.error_string(generation_err))
					}
					test_file_created = test_file_created || generated_count > 0
				}
				if warn_err := warn_test_filename_conflicts(current, latest, package_dir, &warned_test_files); warn_err != nil {
					fmt.eprintfln("[ERROR] cannot inspect test filenames in %s: %s", package_dir, os.error_string(warn_err))
				}
			}
			if test_file_created {
				refreshed, refresh_err := scan_odin_project(root, context.allocator, &latest)
				if refresh_err != nil {
					fmt.eprintfln("[ERROR] cannot refresh after creating test files: %s", os.error_string(refresh_err))
				} else {
					project_snapshot_destroy(&latest)
					latest = refreshed
				}
			}
			if justfile.generated {
				for package_dir in validated_packages {
					if package_has_test_file(latest, package_dir) {
						run_and_report_just_test(justfile, root, package_dir)
					}
				}
			} else if len(validated_packages) > 0 && project_has_test_files(latest) {
				run_and_report_just_test(justfile, root, "")
			}
			delete_string_slice(validated_packages)
			delete_string_slice(stable_changes)
			next = latest
		}
		project_snapshot_destroy(&current)
		current = next
	}
}

project_package_dirs :: proc(snapshot: Project_Snapshot, allocator := context.allocator) -> (directories: [dynamic]string, err: os.Error) {
	directories = make([dynamic]string, 0, allocator)
	transferred := false
	defer if !transferred { delete_string_slice(directories, allocator) }
	for file in snapshot.files {
		if err = append_unique_package(&directories, file.package_dir, allocator); err != nil {
			return nil, err
		}
	}
	transferred = true
	return directories, nil
}

report_new_procedure_contract_warnings :: proc(
	before, after: Project_Snapshot,
	package_dir: string,
	allocator := context.allocator,
) {
	for file in after.files {
		if file.package_dir != package_dir || strings.has_suffix(file.path, "_test.odin") || !odin_file_changed(before, file) {
			continue
		}
		previous, found := find_odin_file(before, file.path)
		previous_procedures: [dynamic]Procedure_Declaration
		if found {
			previous_procedures = previous.procedures
		}
		warnings := new_procedure_contract_warnings(previous_procedures, file.procedures, allocator)
		for warning in warnings {
			fmt.eprintfln("%s in %s", warning, file.path)
		}
		delete_string_slice(warnings, allocator)
	}
}

package_has_test_file :: proc(snapshot: Project_Snapshot, package_dir: string) -> bool {
	for file in snapshot.files {
		if file.package_dir == package_dir && strings.has_suffix(file.path, "_test.odin") {
			return true
		}
	}
	return false
}

ensure_companion_test_files :: proc(
	before, after: Project_Snapshot,
	package_dir: string,
	allocator := context.allocator,
) -> (created: bool, err: os.Error) {
	for file in after.files {
		if file.package_dir != package_dir || strings.has_suffix(file.path, "_test.odin") || !odin_file_changed(before, file) {
			continue
		}
		file_created, create_err := ensure_companion_test_file(file, allocator)
		if create_err != nil {
			return created, create_err
		}
		created = created || file_created
	}
	return
}

@(private)
ensure_companion_test_file :: proc(file: Odin_File_Stamp, allocator: runtime.Allocator) -> (created: bool, err: os.Error) {
	stem := file.path[:len(file.path)-len(".odin")]
	test_path, path_err := strings.concatenate({stem, "_test.odin"}, allocator)
	if path_err != nil {
		return false, os.Error(path_err)
	}
	defer delete(test_path, allocator)
	if os.is_file(test_path) {
		return false, nil
	}
	if os.exists(test_path) {
		return false, os.Error(.Invalid_Path)
	}

	data, read_err := os.read_entire_file(file.path, allocator)
	if read_err != nil {
		return false, read_err
	}
	defer delete(data, allocator)
	package_name := package_name_from_source(transmute(string)data, allocator)
	if package_name == "" {
		return false, os.Error(.Invalid_Command)
	}
	test_source := fmt.aprintf(
		"package %s\n// Tests for %s.\n",
		package_name,
		filepath.base(file.path),
		allocator=allocator,
	)
	defer delete(test_source, allocator)

	output, open_err := os.open(test_path, {.Write, .Create, .Excl})
	if open_err != nil {
		if os.is_file(test_path) {
			return false, nil
		}
		return false, open_err
	}
	_, write_err := os.write_string(output, test_source)
	close_err := os.close(output)
	if write_err != nil {
		_ = os.remove(test_path)
		return false, write_err
	}
	if close_err != nil {
		_ = os.remove(test_path)
		return false, close_err
	}
	fmt.eprintfln("[RACHEL] Created companion test file %s", test_path)
	return true, nil
}

@(private)
package_name_from_source :: proc(source: string, allocator: runtime.Allocator) -> string {
	lines, split_err := strings.split_lines(source, allocator)
	if split_err != nil {
		return ""
	}
	defer delete(lines, allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "package ") {
			name := strings.trim_space(trimmed[len("package "):])
			if separator := strings.index_byte(name, ' '); separator >= 0 {
				name = name[:separator]
			}
			if separator := strings.index_byte(name, '\t'); separator >= 0 {
				name = name[:separator]
			}
			return name
		}
	}
	return ""
}

warn_test_filename_conflicts :: proc(
	before, after: Project_Snapshot,
	package_dir: string,
	warned_paths: ^[dynamic]string,
	allocator := context.allocator,
) -> os.Error {
	for file in after.files {
		if file.package_dir != package_dir || !strings.has_suffix(file.path, "_test.odin") || !odin_file_changed(before, file) {
			continue
		}
		contents, read_err := os.read_entire_file(file.path, allocator)
		if read_err != nil {
			return read_err
		}
		looks_like_source := test_file_looks_like_production(transmute(string)contents, allocator)
		delete(contents, allocator)
		if !looks_like_source {
			forget_test_filename_warning(warned_paths, file.path, allocator)
			continue
		}
		if string_slice_contains(warned_paths^[:], file.path) {
			continue
		}
		fmt.eprintfln(
			"[WARN] %s contains production-looking procedures but uses the *_test.odin name; rename it if this is production code.",
			file.path,
		)
		warning_path, clone_err := strings.clone(file.path, allocator)
		if clone_err != nil {
			return os.Error(clone_err)
		}
		_, append_err := append(warned_paths, warning_path)
		if append_err != nil {
			delete(warning_path, allocator)
			return os.Error(append_err)
		}
	}
	return nil
}

@(private)
string_slice_contains :: proc(values: []string, target: string) -> bool {
	for value in values {
		if value == target {
			return true
		}
	}
	return false
}

@(private)
forget_test_filename_warning :: proc(warned_paths: ^[dynamic]string, path: string, allocator := context.allocator) {
	for index := 0; index < len(warned_paths^); index += 1 {
		if warned_paths^[index] == path {
			delete(warned_paths^[index], allocator)
			ordered_remove(warned_paths, index)
			return
		}
	}
}

project_has_test_files :: proc(snapshot: Project_Snapshot) -> bool {
	for file in snapshot.files {
		if strings.has_suffix(file.path, "_test.odin") {
			return true
		}
	}
	return false
}

run_and_report_just_check :: proc(
	justfile: Rachel_Justfile,
	root, package_dir: string,
	allocator := context.allocator,
) -> bool {
	result := run_just_recipe(justfile, root, "check", package_dir, allocator)
	defer odin_command_result_destroy(&result, allocator)
	success := odin_command_succeeded(result)
	if result.process_error != nil {
		fmt.eprintfln("[ERROR] just check failed in %s: %s", root, os.error_string(result.process_error))
	} else if !success {
		fmt.eprintfln("[ERROR] just check failed in %s (exit %d)", root, result.state.exit_code)
	} else {
		fmt.eprintfln("[OK] just check %s", root)
	}
	print_command_output(result)
	return success
}

run_and_report_just_test :: proc(
	justfile: Rachel_Justfile,
	root, package_dir: string,
	allocator := context.allocator,
) -> bool {
	result := run_just_recipe(justfile, root, "test", package_dir, allocator)
	defer odin_command_result_destroy(&result, allocator)
	leak_warning := odin_test_has_allocator_leak(result)
	success := odin_test_result_success(result)
	if leak_warning {
		fmt.eprintfln("[ERROR] just test reported allocator leaks in %s", root)
	} else if result.process_error != nil {
		fmt.eprintfln("[ERROR] just test failed in %s: %s", root, os.error_string(result.process_error))
	} else if !result.state.success {
		fmt.eprintfln("[ERROR] just test failed in %s (exit %d)", root, result.state.exit_code)
	} else {
		fmt.eprintfln("[OK] just test %s", root)
	}
	print_command_output(result)
	return success
}

odin_test_result_success :: proc(result: Odin_Command_Result) -> bool {
	return odin_command_succeeded(result) && !odin_test_has_allocator_leak(result)
}

@(private)
odin_command_succeeded :: proc(result: Odin_Command_Result) -> bool {
	return result.process_error == nil && result.state.exited && result.state.success
}

@(private)
print_command_output :: proc(result: Odin_Command_Result) {
	if len(result.stdout) > 0 {
		fmt.eprintln(transmute(string)result.stdout)
	}
	if len(result.stderr) > 0 {
		fmt.eprintln(transmute(string)result.stderr)
	}
}

Check_Outcome :: struct {
	ok:     bool,
	detail: string, // owned; the first compiler diagnostic, or ""
}

// check_targets narrows a check to the packages of the given .odin paths.
// Any other path checks the whole project, so a check is never skipped.
check_targets :: proc(
	root: string,
	paths: []string,
	allocator := context.allocator,
) -> (targets: [dynamic]string, whole_project: bool, err: os.Error) {
	targets = make([dynamic]string, 0, allocator)
	transferred := false
	defer if !transferred { delete_string_slice(targets, allocator) }
	if len(paths) == 0 {
		transferred = true
		return targets, true, nil
	}
	for path in paths {
		resolved := path
		owned: string
		if !filepath.is_abs(path) {
			joined, join_err := filepath.join({root, path}, allocator)
			if join_err != nil {
				return nil, false, os.Error(join_err)
			}
			owned = joined
			resolved = owned
		}
		defer if owned != "" { delete(owned, allocator) }
		if !strings.has_suffix(resolved, ".odin") {
			transferred = true
			return targets, true, nil
		}
		package_dir := filepath.dir(resolved)
		if !strings.has_prefix(package_dir, root) {
			transferred = true
			return targets, true, nil
		}
		if append_err := append_unique_package(&targets, package_dir, allocator); append_err != nil {
			return nil, false, os.Error(append_err)
		}
	}
	transferred = true
	return targets, false, nil
}

// check_package runs one check and keeps the first diagnostic for the verdict.
// The full compiler output goes to stderr so a caller's stdout stays one line.
check_package :: proc(
	justfile: Rachel_Justfile,
	root, package_dir: string,
	allocator := context.allocator,
) -> (outcome: Check_Outcome, err: os.Error) {
	result := run_just_recipe(justfile, root, "check", package_dir, allocator)
	defer odin_command_result_destroy(&result, allocator)
	if result.process_error != nil {
		return {}, result.process_error
	}
	if odin_command_succeeded(result) {
		return Check_Outcome{ok = true}, nil
	}
	print_command_output(result)
	detail, found := first_diagnostic(transmute(string)result.stdout, transmute(string)result.stderr, allocator)
	if !found {
		detail = fmt.aprintf("just check exited %d", result.state.exit_code, allocator = allocator)
	}
	return Check_Outcome{ok = false, detail = detail}, nil
}

@(private)
first_diagnostic :: proc(stdout, stderr: string, allocator := context.allocator) -> (line: string, found: bool) {
	for source in ([]string{stdout, stderr}) {
		lines, split_err := strings.split_lines(source, allocator)
		if split_err != nil {
			continue
		}
		defer delete(lines, allocator)
		for raw in lines {
			trimmed := strings.trim_space(raw)
			if !strings.contains(trimmed, "Error:") && !strings.contains(trimmed, "error:") {
				continue
			}
			cloned, clone_err := strings.clone(trimmed, allocator)
			if clone_err != nil {
				continue
			}
			return cloned, true
		}
	}
	return "", false
}

check_once :: proc(options: CLI_Options, allocator := context.allocator) -> int {
	root := options.root
	current, scan_err := scan_odin_project(root, allocator)
	if scan_err != nil {
		fmt.eprintfln("[ERROR] cannot scan %s: %s", root, os.error_string(scan_err))
		return 1
	}
	defer project_snapshot_destroy(&current, allocator)
	justfile, justfile_err := ensure_project_justfile(root, allocator)
	if justfile_err != nil {
		fmt.eprintfln("[ERROR] cannot prepare Rachel's justfile in %s: %s", root, os.error_string(justfile_err))
		return 1
	}
	defer justfile_destroy(&justfile, allocator)

	narrowed, whole_project, target_err := check_targets(root, options.paths[:], allocator)
	if target_err != nil {
		fmt.eprintfln("[ERROR] cannot resolve check paths: %s", os.error_string(target_err))
		return 1
	}
	defer delete_string_slice(narrowed, allocator)

	// A custom justfile takes no package argument, so it always checks the project.
	directories := make([dynamic]string, 0, allocator)
	defer delete_string_slice(directories, allocator)
	if justfile.generated {
		if whole_project {
			package_dirs, package_err := project_package_dirs(current, allocator)
			if package_err != nil {
				fmt.eprintfln("[ERROR] cannot list Odin packages: %s", os.error_string(package_err))
				return 1
			}
			defer delete_string_slice(package_dirs, allocator)
			for package_dir in package_dirs {
				if append_err := append_unique_package(&directories, package_dir, allocator); append_err != nil {
					fmt.eprintfln("[ERROR] cannot collect packages: %s", os.error_string(append_err))
					return 1
				}
			}
		} else {
			for package_dir in narrowed {
				if append_err := append_unique_package(&directories, package_dir, allocator); append_err != nil {
					fmt.eprintfln("[ERROR] cannot collect packages: %s", os.error_string(append_err))
					return 1
				}
			}
		}
	}

	whole_project_call := []string{""}
	to_check: []string = whole_project_call
	if justfile.generated {
		to_check = directories[:]
	}
	checked := 0
	failures := 0
	first_detail := ""
	for package_dir in to_check {
		checked += 1
		outcome, outcome_err := check_package(justfile, root, package_dir, allocator)
		if outcome_err != nil {
			fmt.eprintfln("[ERROR] could not run the check: %s", os.error_string(outcome_err))
			return 1
		}
		if outcome.ok {
			delete(outcome.detail, allocator)
			continue
		}
		failures += 1
		if first_detail == "" {
			first_detail = outcome.detail
		} else {
			delete(outcome.detail, allocator)
		}
	}
	defer if first_detail != "" { delete(first_detail, allocator) }

	if failures == 0 {
		fmt.printfln("rachel: ok (%d checked)", checked)
		return 0
	}
	if first_detail != "" {
		fmt.printfln("rachel: fail (%d of %d): %s", failures, checked, first_detail)
	} else {
		fmt.printfln("rachel: fail (%d of %d)", failures, checked)
	}
	return 1
}
