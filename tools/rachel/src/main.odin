package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

CLI_Options :: struct {
	root: string,
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
	if len(args) != 2 {
		return {}, os.Error(.Invalid_Command)
	}
	if !os.is_dir(args[1]) {
		return {}, os.Error(.Invalid_Dir)
	}
	root, clone_err := strings.clone(args[1], allocator)
	if clone_err != nil {
		return {}, os.Error(clone_err)
	}
	return CLI_Options{root = root}, nil
}

options_destroy :: proc(options: ^CLI_Options, allocator := context.allocator) {
	delete(options.root, allocator)
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
		fmt.eprintfln("[ERROR] %s", os.error_string(parse_err))
		return 2
	}
	defer options_destroy(&options)
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
			time.sleep(350 * time.Millisecond)
			latest, latest_err := scan_odin_project(root, context.allocator, &current)
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
