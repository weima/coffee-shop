package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

CLI_Options :: struct {
	root:       string,
	paths:      [dynamic]string,
	check_once: bool,
	verify:     bool,
	from_env:   bool,
	max_errors: int, // 0 means every error; a human reading a terminal usually wants 1
}

Rachel_Justfile :: struct {
	path: string,
	generated: bool,
}

RACHEL_DEFAULT_JUSTFILE_MARKER :: "# Rachel-generated defaults"

RACHEL_DEFAULT_JUSTFILE :: `# Rachel-generated defaults; edit for collections or custom linker flags.
set shell := ["sh", "-cu"]

check package=".":
    odin check -no-entry-point {{quote(package)}}

test package=".":
    TZ=UTC odin test {{quote(package)}}
`

parse_cli_args :: proc(args: []string, allocator := context.allocator) -> (options: CLI_Options, err: os.Error) {
	rest := args[1:]
	if len(rest) > 0 && (rest[0] == "check" || rest[0] == "verify") {
		options.check_once = rest[0] == "check"
		options.verify = rest[0] == "verify"
		options.max_errors = CHECK_DEFAULT_MAX_ERRORS
		rest = rest[1:]
		for len(rest) > 0 && strings.has_prefix(rest[0], "--") {
			if rest[0] == "--from-env" {
				options.from_env = true
				rest = rest[1:]
				continue
			}
			if rest[0] == "--max-errors" && len(rest) >= 2 {
				value, parsed := strconv.parse_int(rest[1])
				if !parsed || value < 0 {
					return {}, os.Error(.Invalid_Command)
				}
				options.max_errors = value
				rest = rest[2:]
				continue
			}
			return {}, os.Error(.Invalid_Command)
		}
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
	if len(rest) > 1 && !options.check_once && !options.verify {
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
			return Rachel_Justfile{path=path, generated=justfile_uses_rachel_defaults(path, allocator)}, nil
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
			return Rachel_Justfile{path=path, generated=justfile_uses_rachel_defaults(path, allocator)}, nil
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

// A justfile that still starts with Rachel's marker keeps the per-package
// behaviour; a hand-written one is run once for the whole project. Detecting the
// marker matters after the first run, when the created file is no longer new.
@(private)
justfile_uses_rachel_defaults :: proc(path: string, allocator := context.allocator) -> bool {
	contents, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return false
	}
	defer delete(contents, allocator)
	return strings.has_prefix(transmute(string)contents, RACHEL_DEFAULT_JUSTFILE_MARKER)
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
		fmt.eprintln("       rachel verify <odin-project-directory> [path ...]")
		fmt.eprintfln("[ERROR] %s", os.error_string(parse_err))
		return 2
	}
	defer options_destroy(&options)
	if options.check_once {
		return check_once(options)
	}
	if options.verify {
		return verify_once(options)
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

// A checker's answer for one package: whether it passed, and the distinct
// compiler diagnostics an agent needs to fix it. Reporting only the first error
// forced the reader to run the compiler again, which defeats the point.
Check_Outcome :: struct {
	ok:          bool,
	diagnostics: [dynamic]string, // owned; at most CHECK_DIAGNOSTIC_MAX, paths relative to the project
	error_count: int,             // distinct diagnostics seen, before the cap
}

CHECK_DEFAULT_MAX_ERRORS :: 10 // enough to act on, small enough to read
CHECK_DIAGNOSTIC_MAX :: CHECK_DEFAULT_MAX_ERRORS

// canonical_path resolves symlinks (macOS /var is /private/var) so a watcher's
// absolute paths and a user's project root compare equal.
@(private)
canonical_path :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	buf: [4096]byte
	resolved := posix.realpath(cpath, raw_data(buf[:]))
	if resolved == nil {
		return "", false
	}
	return strings.clone(string(resolved), allocator), true
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
	canonical_root := root
	root_owned: string
	if resolved, ok := canonical_path(root, allocator); ok {
		root_owned = resolved
		canonical_root = root_owned
	}
	defer delete(root_owned, allocator)
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
		canonical, canonical_ok := canonical_path(resolved, allocator)
		if !canonical_ok {
			transferred = true
			return targets, true, nil
		}
		defer delete(canonical, allocator)
		package_dir := filepath.dir(canonical)
		if !strings.has_prefix(package_dir, canonical_root) {
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

// check_package runs one check and collects its distinct diagnostics. The full
// compiler output still goes to stderr for a human reading a terminal.
check_package :: proc(
	justfile: Rachel_Justfile,
	root, package_dir, display_root: string,
	limit: int,
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
	outcome.diagnostics, outcome.error_count = collect_diagnostics(
		transmute(string)result.stdout,
		transmute(string)result.stderr,
		display_root,
		limit,
		allocator,
	)
	if outcome.error_count == 0 {
		fallback := fmt.aprintf("just check exited %d", result.state.exit_code, allocator = allocator)
		_ = append(&outcome.diagnostics, fallback)
		outcome.error_count = 1
	}
	return outcome, nil
}

// collect_diagnostics keeps one entry per distinct compiler error, in compiler
// order, with the project root stripped. Odin prints `file(line:col) Error:
// message` followed by a source snippet and caret line; only the error line is
// kept, because the snippet costs tokens and the file is one read away.
@(private)
collect_diagnostics :: proc(
	stdout, stderr, root: string,
	limit: int, // 0 lists every distinct error
	allocator := context.allocator,
) -> (diagnostics: [dynamic]string, total: int) {
	diagnostics = make([dynamic]string, 0, allocator)
	for source in ([]string{stderr, stdout}) {
		lines, split_err := strings.split_lines(source, allocator)
		if split_err != nil {
			continue
		}
		for raw in lines {
			trimmed := strings.trim_space(raw)
			// Odin prints both "Error:" and "Syntax Error:"; a snippet and caret line
			// contains neither.
			if !strings.contains(trimmed, "Error:") {
				continue
			}
			display := trimmed
			if len(root) > 0 && strings.has_prefix(display, root) {
				display = strings.trim_prefix(display[len(root):], "/")
			}
			duplicate := false
			for existing in diagnostics {
				if existing == display {
					duplicate = true
					break
				}
			}
			if duplicate {
				continue
			}
			total += 1
			if limit == 0 || len(diagnostics) < limit {
				if cloned, clone_err := strings.clone(display, allocator); clone_err == nil {
					_ = append(&diagnostics, cloned)
				}
			}
		}
		delete(lines, allocator)
	}
	return diagnostics, total
}

WATCHEXEC_PATH_VARS :: []string{
	"WATCHEXEC_WRITTEN_PATH",
	"WATCHEXEC_CREATED_PATH",
	"WATCHEXEC_REMOVED_PATH",
	"WATCHEXEC_RENAMED_PATH",
	"WATCHEXEC_META_CHANGED_PATH",
	"WATCHEXEC_OTHERWISE_CHANGED_PATH",
}

// paths_from_watchexec_env reads the paths a watcher reported for one batch.
// watchexec emits them relative to WATCHEXEC_COMMON_PATH, joined by the
// platform path-list separator.
paths_from_watchexec_env :: proc(allocator := context.allocator) -> (paths: [dynamic]string, err: os.Error) {
	paths = make([dynamic]string, 0, allocator)
	transferred := false
	defer if !transferred { delete_string_slice(paths, allocator) }
	common := os.get_env("WATCHEXEC_COMMON_PATH", allocator)
	defer delete(common, allocator)
	separator := fmt.aprintf("%c", rune(os.Path_List_Separator), allocator = allocator)
	defer delete(separator, allocator)
	for name in WATCHEXEC_PATH_VARS {
		value := os.get_env(name, allocator)
		if len(value) == 0 {
			delete(value, allocator)
			continue
		}
		// entries are slices into value, so value outlives them.
		entries, split_err := strings.split(value, separator, allocator)
		if split_err != nil {
			delete(value, allocator)
			return nil, os.Error(split_err)
		}
		for entry in entries {
			if entry == "" {
				continue
			}
			full := entry
			owned: string
			if len(common) > 0 && !filepath.is_abs(entry) {
				joined, join_err := filepath.join({common, entry}, allocator)
				if join_err != nil {
					return nil, os.Error(join_err)
				}
				owned = joined
				full = owned
			}
			append_err := append_unique_package(&paths, full, allocator)
			delete(owned, allocator)
			if append_err != nil {
				delete(entries, allocator)
				delete(value, allocator)
				return nil, os.Error(append_err)
			}
		}
		delete(entries, allocator)
		delete(value, allocator)
	}
	transferred = true
	return paths, nil
}

Check_Summary :: struct {
	ok:          bool,
	checked:     int,
	failures:    int,
	error_count: int,
	diagnostics: [dynamic]string, // owned, capped by --max-errors
}

check_summary_destroy :: proc(summary: ^Check_Summary, allocator := context.allocator) {
	delete_string_slice(summary.diagnostics, allocator)
	summary^ = Check_Summary{}
}

// run_checks is the check stage without its verdict, so verify can tag the result
// with the stage name. Only operational errors are printed here.
run_checks :: proc(options: CLI_Options, allocator := context.allocator) -> (summary: Check_Summary, fatal: bool) {
	root := options.root
	current, scan_err := scan_odin_project(root, allocator)
	if scan_err != nil {
		fmt.eprintfln("[ERROR] cannot scan %s: %s", root, os.error_string(scan_err))
		return summary, true
	}
	defer project_snapshot_destroy(&current, allocator)
	justfile, justfile_err := ensure_project_justfile(root, allocator)
	if justfile_err != nil {
		fmt.eprintfln("[ERROR] cannot prepare Rachel's justfile in %s: %s", root, os.error_string(justfile_err))
		return summary, true
	}
	defer justfile_destroy(&justfile, allocator)

	paths := options.paths[:]
	env_paths: [dynamic]string
	if options.from_env {
		loaded, env_err := paths_from_watchexec_env(allocator)
		if env_err != nil {
			fmt.eprintfln("[ERROR] cannot read watcher paths: %s", os.error_string(env_err))
			return summary, true
		}
		env_paths = loaded
		if len(env_paths) > 0 {
			paths = env_paths[:]
		}
	}
	// Function scope: a defer inside the if block frees this before check_targets reads it.
	defer delete_string_slice(env_paths, allocator)

	narrowed, whole_project, target_err := check_targets(root, paths, allocator)
	if target_err != nil {
		fmt.eprintfln("[ERROR] cannot resolve check paths: %s", os.error_string(target_err))
		return summary, true
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
				return summary, true
			}
			defer delete_string_slice(package_dirs, allocator)
			for package_dir in package_dirs {
				if append_err := append_unique_package(&directories, package_dir, allocator); append_err != nil {
					fmt.eprintfln("[ERROR] cannot collect packages: %s", os.error_string(append_err))
					return summary, true
				}
			}
		} else {
			for package_dir in narrowed {
				if append_err := append_unique_package(&directories, package_dir, allocator); append_err != nil {
					fmt.eprintfln("[ERROR] cannot collect packages: %s", os.error_string(append_err))
					return summary, true
				}
			}
		}
	}

	whole_project_call := []string{""}
	to_check: []string = whole_project_call
	if justfile.generated {
		to_check = directories[:]
	}
	// The compiler prints resolved paths (/private/var on macOS), so strip the
	// canonical root, not the path the caller typed.
	display_root := root
	display_owned: string
	if resolved, resolved_ok := canonical_path(root, allocator); resolved_ok {
		display_owned = resolved
		display_root = display_owned
	}
	defer delete(display_owned, allocator)

	for package_dir in to_check {
		summary.checked += 1
		outcome, outcome_err := check_package(justfile, root, package_dir, display_root, options.max_errors, allocator)
		if outcome_err != nil {
			fmt.eprintfln("[ERROR] could not run the check: %s", os.error_string(outcome_err))
			return summary, true
		}
		if outcome.ok {
			continue
		}
		summary.failures += 1
		summary.error_count += outcome.error_count
		for line in outcome.diagnostics {
			if options.max_errors == 0 || len(summary.diagnostics) < options.max_errors {
				_ = append(&summary.diagnostics, line) // ownership moves to summary
			} else {
				delete(line, allocator)
			}
		}
		delete(outcome.diagnostics)
	}
	summary.ok = summary.failures == 0
	return summary, false
}

print_check_verdict :: proc(summary: Check_Summary, tag: string) {
	if summary.ok {
		fmt.printfln("%sok (%d checked)", tag, summary.checked)
		return
	}
	if summary.error_count == 1 {
		fmt.printfln("%sfail (%d of %d, 1 error)", tag, summary.failures, summary.checked)
	} else if summary.error_count > 1 {
		fmt.printfln("%sfail (%d of %d, %d errors)", tag, summary.failures, summary.checked, summary.error_count)
	} else {
		fmt.printfln("%sfail (%d of %d)", tag, summary.failures, summary.checked)
	}
	for line in summary.diagnostics {
		fmt.printfln("rachel: error %s", line)
	}
	if summary.error_count > len(summary.diagnostics) {
		fmt.printfln("rachel: error ... (%d more)", summary.error_count - len(summary.diagnostics))
	}
}

check_once :: proc(options: CLI_Options, allocator := context.allocator) -> int {
	summary, fatal := run_checks(options, allocator)
	defer check_summary_destroy(&summary, allocator)
	if fatal {
		return 1
	}
	print_check_verdict(summary, "rachel: ")
	if !summary.ok {
		return 1
	}
	return 0
}

Test_Summary :: struct {
	ok:            bool,
	packages:      int,
	tests:         int,
	failure_count: int,
	failures:      [dynamic]string, // owned, capped by --max-errors
}

test_summary_destroy :: proc(summary: ^Test_Summary, allocator := context.allocator) {
	delete_string_slice(summary.failures, allocator)
	summary^ = Test_Summary{}
}

// parse_test_count reads Odin's "Finished N tests" trailer. Zero means the count
// could not be read, which is reported differently from "no tests".
parse_test_count :: proc(stdout, stderr: string) -> int {
	for source in ([]string{stdout, stderr}) {
		text := source
		for {
			index := strings.index(text, "Finished ")
			if index < 0 {
				break
			}
			rest := text[index + len("Finished "):]
			digits := 0
			for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
				digits += 1
			}
			if digits > 0 {
				if value, parsed := strconv.parse_int(rest[:digits]); parsed {
					return value
				}
			}
			text = rest
		}
	}
	return 0
}

// test_failure_text turns one Odin test runner line into "<location> <message>".
// The real form is: [ERROR] --- [<timestamp>] [<location>] <message>
@(private)
test_failure_text :: proc(line, display_root: string, allocator := context.allocator) -> (text: string, ok: bool) {
	trimmed := strings.trim_space(line)
	if !strings.has_prefix(trimmed, "[ERROR]") {
		return "", false
	}
	separator := strings.index(trimmed, "] [")
	if separator < 0 {
		return "", false
	}
	rest := trimmed[separator + 3:]
	close := strings.index(rest, "] ")
	if close < 0 {
		return "", false
	}
	location := rest[:close]
	message := strings.trim_space(rest[close + 2:])
	if len(display_root) > 0 && strings.has_prefix(location, display_root) {
		location = strings.trim_prefix(location[len(display_root):], "/")
	}
	if len(location) == 0 || len(message) == 0 {
		return "", false
	}
	return fmt.aprintf("%s %s", location, message, allocator = allocator), true
}

// collect_test_failures keeps distinct failures in output order. Deduplication
// compares against the retained lines, so a flood past the cap can overcount.
@(private)
collect_test_failures :: proc(
	stdout, stderr, display_root: string,
	limit: int,
	allocator := context.allocator,
) -> (failures: [dynamic]string, total: int) {
	failures = make([dynamic]string, 0, allocator)
	for source in ([]string{stderr, stdout}) {
		lines, split_err := strings.split_lines(source, allocator)
		if split_err != nil {
			continue
		}
		for raw in lines {
			text, ok := test_failure_text(raw, display_root, allocator)
			if !ok {
				continue
			}
			duplicate := false
			for existing in failures {
				if existing == text {
					duplicate = true
					break
				}
			}
			if duplicate {
				delete(text, allocator)
				continue
			}
			total += 1
			if limit == 0 || len(failures) < limit {
				_ = append(&failures, text)
			} else {
				delete(text, allocator)
			}
		}
		delete(lines, allocator)
	}
	return failures, total
}

// run_tests is the test stage: every package with a test file, or the whole
// project once when the justfile is hand-written.
run_tests :: proc(root: string, max_errors: int, allocator := context.allocator) -> (summary: Test_Summary, fatal: bool) {
	summary.ok = true
	current, scan_err := scan_odin_project(root, allocator)
	if scan_err != nil {
		fmt.eprintfln("[ERROR] cannot scan %s: %s", root, os.error_string(scan_err))
		return summary, true
	}
	defer project_snapshot_destroy(&current, allocator)
	justfile, justfile_err := ensure_project_justfile(root, allocator)
	if justfile_err != nil {
		fmt.eprintfln("[ERROR] cannot prepare Rachel's justfile in %s: %s", root, os.error_string(justfile_err))
		return summary, true
	}
	defer justfile_destroy(&justfile, allocator)

	display_root := root
	display_owned: string
	if resolved, resolved_ok := canonical_path(root, allocator); resolved_ok {
		display_owned = resolved
		display_root = display_owned
	}
	defer delete(display_owned, allocator)

	directories := make([dynamic]string, 0, allocator)
	defer delete_string_slice(directories, allocator)
	if justfile.generated {
		package_dirs, package_err := project_package_dirs(current, allocator)
		if package_err != nil {
			fmt.eprintfln("[ERROR] cannot list Odin packages: %s", os.error_string(package_err))
			return summary, true
		}
		defer delete_string_slice(package_dirs, allocator)
		for package_dir in package_dirs {
			if !package_has_test_file(current, package_dir) {
				continue
			}
			if append_err := append_unique_package(&directories, package_dir, allocator); append_err != nil {
				fmt.eprintfln("[ERROR] cannot collect packages: %s", os.error_string(append_err))
				return summary, true
			}
		}
	}

	whole_project_call := []string{""}
	to_test: []string = whole_project_call
	if justfile.generated {
		to_test = directories[:]
	}
	for package_dir in to_test {
		summary.packages += 1
		result := run_just_recipe(justfile, root, "test", package_dir, allocator)
		if result.process_error != nil {
			fmt.eprintfln("[ERROR] could not run the test stage: %s", os.error_string(result.process_error))
			odin_command_result_destroy(&result, allocator)
			summary.ok = false
			continue
		}
		print_command_output(result)
		summary.tests += parse_test_count(transmute(string)result.stdout, transmute(string)result.stderr)
		if !odin_command_succeeded(result) {
			summary.ok = false
			lines, total := collect_test_failures(
				transmute(string)result.stdout,
				transmute(string)result.stderr,
				display_root,
				max_errors,
				allocator,
			)
			summary.failure_count += total
			for line in lines {
				if max_errors == 0 || len(summary.failures) < max_errors {
					_ = append(&summary.failures, line)
				} else {
					delete(line, allocator)
				}
			}
			delete(lines) // the dynamic array; its strings were moved or freed above
		}
		odin_command_result_destroy(&result, allocator)
	}
	return summary, false
}

print_test_verdict :: proc(summary: Test_Summary, tag: string) {
	if summary.ok {
		switch summary.tests {
		case 0:
			fmt.printfln("%sok (no tests)", tag)
		case 1:
			fmt.printfln("%sok (1 test)", tag)
		case:
			fmt.printfln("%sok (%d tests)", tag, summary.tests)
		}
		return
	}
	if summary.tests > 0 {
		if summary.failure_count == 1 {
			fmt.printfln("%sfail (1 of %d tests)", tag, summary.tests)
		} else {
			fmt.printfln("%sfail (%d of %d tests)", tag, summary.failure_count, summary.tests)
		}
	} else if summary.failure_count > 1 {
		fmt.printfln("%sfail (%d failures)", tag, summary.failure_count)
	} else if summary.failure_count == 1 {
		fmt.printfln("%sfail (1 failure)", tag)
	} else {
		fmt.printfln("%sfail (exit code only)", tag)
	}
	for line in summary.failures {
		fmt.printfln("rachel: error %s", line)
	}
	if summary.failure_count > len(summary.failures) {
		fmt.printfln("rachel: error ... (%d more)", summary.failure_count - len(summary.failures))
	}
}

verify_once :: proc(options: CLI_Options, allocator := context.allocator) -> int {
	check_summary, check_fatal := run_checks(options, allocator)
	defer check_summary_destroy(&check_summary, allocator)
	if check_fatal {
		return 1
	}
	print_check_verdict(check_summary, "rachel: check ")
	if !check_summary.ok {
		return 1
	}
	test_summary, test_fatal := run_tests(options.root, options.max_errors, allocator)
	defer test_summary_destroy(&test_summary, allocator)
	if test_fatal {
		return 1
	}
	print_test_verdict(test_summary, "rachel: test ")
	if !test_summary.ok {
		return 1
	}
	return 0
}
