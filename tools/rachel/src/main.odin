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
	watch:      bool,
	debounce:   string,
	evidence_last: bool,
	from_env:   bool,
	stage_check: bool,
	stage_test:  bool,
	stage_e2e:   bool,
	all_stages:  bool,
	max_errors: int, // 0 means every error; a human reading a terminal usually wants 1
}

Rachel_Justfile :: struct {
	path: string,
	generated: bool,
}

RACHEL_DEFAULT_JUSTFILE_MARKER :: "# Rachel-generated defaults"

// The generated TS recipe takes an ignored package argument so the existing
// per-package call path works unchanged; tsc has no per-package mode.
RACHEL_DEFAULT_TS_JUSTFILE :: `# Rachel-generated defaults; edit for other tools.
set shell := ["sh", "-cu"]

check package=".":
    tsc --noEmit
`

RACHEL_DEFAULT_JUSTFILE :: `# Rachel-generated defaults; edit for collections or custom linker flags.
set shell := ["sh", "-cu"]

check package=".":
    odin check -no-entry-point {{quote(package)}}

test package=".":
    TZ=UTC odin test {{quote(package)}}
`

parse_cli_args :: proc(args: []string, allocator := context.allocator) -> (options: CLI_Options, err: os.Error) {
	if len(args) >= 4 && args[1] == "evidence" && args[2] == "last" {
		if !os.is_dir(args[3]) {
			return {}, os.Error(.Invalid_Dir)
		}
		root, clone_err := canonical_root(args[3], allocator)
		if clone_err != nil {
			return {}, clone_err
		}
		return CLI_Options{root = root, evidence_last = true}, nil
	}
	rest := args[1:]
	if len(rest) > 0 && rest[0] == "watch" {
		options.watch = true
		options.debounce = RACHEL_WATCH_DEBOUNCE
		rest = rest[1:]
		if len(rest) >= 2 && rest[0] == "--debounce" {
			options.debounce = rest[1]
			rest = rest[2:]
		}
		if len(rest) != 1 || !os.is_dir(rest[0]) {
			return {}, os.Error(.Invalid_Dir)
		}
		root, clone_err := canonical_root(rest[0], allocator)
		if clone_err != nil {
			return {}, clone_err
		}
		return CLI_Options{root = root, watch = true, debounce = options.debounce}, nil
	}
	if len(rest) > 0 && (rest[0] == "check" || rest[0] == "verify") {
		options.check_once = rest[0] == "check"
		options.verify = rest[0] == "verify"
		options.max_errors = CHECK_DEFAULT_MAX_ERRORS
		// verify defaults to the cheap ladder; check ignores the stage flags.
		options.stage_check = true
		options.stage_test = true
		rest = rest[1:]
		for len(rest) > 0 && strings.has_prefix(rest[0], "--") {
			if rest[0] == "--from-env" {
				options.from_env = true
				rest = rest[1:]
				continue
			}
			if rest[0] == "--all" {
				options.all_stages = true
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
			if rest[0] == "--stages" && len(rest) >= 2 {
				if !parse_stages(rest[1], &options) {
					return {}, os.Error(.Invalid_Command)
				}
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
	root, clone_err := canonical_root(rest[0], allocator)
	if clone_err != nil {
		return {}, clone_err
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
	template := RACHEL_DEFAULT_JUSTFILE
	if project_language(root) == .TypeScript {
		template = RACHEL_DEFAULT_TS_JUSTFILE
	}
	_, write_err := os.write_string(file, template)
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
Language :: enum {
	Odin,
	TypeScript,
}

// tool_on_path answers whether Rachel's generated recipe can run at all.
@(private)
tool_on_path :: proc(name: string) -> bool {
	path := os.get_env("PATH", context.temp_allocator)
	separator := fmt.aprintf("%c", rune(os.Path_List_Separator), allocator = context.temp_allocator)
	for part in strings.split(path, separator, context.temp_allocator) {
		if part == "" {
			continue
		}
		candidate, join_err := filepath.join({part, name}, context.temp_allocator)
		if join_err != nil {
			continue
		}
		if os.is_file(candidate) {
			return true
		}
	}
	return false
}

/**
 * project_language decides which starter justfile to write and whether a
 * generated recipe should be called once when no Odin package is found.
 * Odin wins when the root has Odin sources, so a mixed repository keeps its
 * existing behaviour.
 */
project_language :: proc(root: string) -> Language {
	entries, read_err := os.read_all_directory_by_path(root, context.temp_allocator)
	if read_err == nil {
		for entry in entries {
			if strings.has_suffix(entry.name, ".odin") {
				return .Odin
			}
		}
	}
	tsconfig, ts_err := filepath.join({root, "tsconfig.json"}, context.temp_allocator)
	if ts_err == nil && os.is_file(tsconfig) {
		return .TypeScript
	}
	package_json, package_err := filepath.join({root, "package.json"}, context.temp_allocator)
	if package_err == nil && os.is_file(package_json) {
		return .TypeScript
	}
	return .Odin
}

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
	return run_just_recipe_with(justfile, working_dir, recipe, package_dir, false, allocator)
}

// no_deps is for verify: the check stage already ran, so a recipe declared as
// `test: check` must not run it a second time.
run_just_recipe_with :: proc(
	justfile: Rachel_Justfile,
	working_dir, recipe, package_dir: string,
	no_deps: bool,
	allocator := context.allocator,
) -> Odin_Command_Result {
	command := make([dynamic]string, 0, allocator)
	defer delete(command)
	for arg in ([]string{"just", "--justfile", justfile.path, "--working-directory", working_dir}) {
		_, _ = append(&command, arg)
	}
	if no_deps {
		_, _ = append(&command, "--no-deps")
	}
	_, _ = append(&command, recipe)
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
		fmt.eprintln("       rachel check <project-directory> [path ...]")
		fmt.eprintln("       rachel watch [--debounce 500ms] <project-directory>")
		fmt.eprintln("       rachel verify <odin-project-directory> [path ...]")
		fmt.eprintln("       rachel evidence last <odin-project-directory>")
		fmt.eprintfln("[ERROR] %s", os.error_string(parse_err))
		return 2
	}
	defer options_destroy(&options)
	if options.evidence_last {
		return print_evidence_last(options)
	}
	if options.watch {
		return run_watcher(options)
	}
	if options.check_once {
		return check_once(options)
	}
	if options.verify {
		return verify_once(options)
	}
	// A bare directory used to start the built-in poller. Watching now belongs to
	// watchexec (`rachel watch`), so the bare form is the one-shot verify a task
	// wants by default.
	options.verify = true
	options.stage_check = true
	options.stage_test = true
	return verify_once(options)
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


package_has_test_file :: proc(snapshot: Project_Snapshot, package_dir: string) -> bool {
	for file in snapshot.files {
		if file.package_dir == package_dir && strings.has_suffix(file.path, "_test.odin") {
			return true
		}
	}
	return false
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
// A relative project path used to reach just with --working-directory set, and
// just resolves --justfile against that directory, doubling the prefix. Roots are
// made absolute and symlink-free once, at parse time.
@(private)
canonical_root :: proc(path: string, allocator := context.allocator) -> (string, os.Error) {
	if resolved, ok := canonical_path(path, allocator); ok {
		return resolved, nil
	}
	absolute, err := os.get_absolute_path(path, allocator)
	if err != nil {
		return "", err
	}
	return absolute, nil
}

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
			// Odin's compiler uses "Error:"/"Syntax Error:", its tooling uses
			// "ERROR:", tsc uses "error TS", and generic tools use "error:".
			if !strings.contains(trimmed, "Error:") && !strings.contains(trimmed, "ERROR:") && !strings.contains(trimmed, "error TS") && !strings.contains(trimmed, "error:") {
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
	// A configured command replaces the Odin discovery path entirely: the project
	// decides its own scope, so no package narrowing and no starter justfile.
	if config, has_config := load_config(root); has_config {
		if entry, found := config.stages["check"]; found && len(entry.command) > 0 {
			stage_summary, stage_fatal := run_config_stage("check", entry, root, options.max_errors, allocator)
			if stage_fatal {
				return summary, true
			}
			summary.ok = stage_summary.ok
			summary.checked = 1
			summary.failures = stage_summary.failure_count
			summary.error_count = stage_summary.failure_count
			for line in stage_summary.failures {
				_ = append(&summary.diagnostics, line)
			}
			delete(stage_summary.failures)
			return summary, false
		}
	}
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
	// A missing tool is a precondition, not a mysterious recipe failure.
	if justfile.generated && project_language(root) == .TypeScript && !tool_on_path("tsc") {
		fmt.printfln("rachel: fail (precondition): tsc is not on PATH; install TypeScript or write a check recipe")
		return summary, true
	}

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
		// A TS project has no Odin packages, but its generated recipe still needs
		// one call. An Odin project with no packages keeps "ok (0 checked)".
		if len(to_check) == 0 && project_language(root) == .TypeScript {
			to_check = whole_project_call
		}
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

// verdict lines are built once so printing and evidence cannot disagree.
check_verdict_lines :: proc(summary: Check_Summary, tag: string, allocator := context.allocator) -> (lines: [dynamic]string) {
	lines = make([dynamic]string, 0, allocator)
	if summary.ok {
		_ = append(&lines, fmt.aprintf("%sok (%d checked)", tag, summary.checked, allocator = allocator))
		return lines
	}
	if summary.error_count == 1 {
		_ = append(&lines, fmt.aprintf("%sfail (%d of %d, 1 error)", tag, summary.failures, summary.checked, allocator = allocator))
	} else if summary.error_count > 1 {
		_ = append(&lines, fmt.aprintf("%sfail (%d of %d, %d errors)", tag, summary.failures, summary.checked, summary.error_count, allocator = allocator))
	} else {
		_ = append(&lines, fmt.aprintf("%sfail (%d of %d)", tag, summary.failures, summary.checked, allocator = allocator))
	}
	for line in summary.diagnostics {
		_ = append(&lines, fmt.aprintf("rachel: error %s", line, allocator = allocator))
	}
	if summary.error_count > len(summary.diagnostics) {
		_ = append(&lines, fmt.aprintf("rachel: error ... (%d more)", summary.error_count - len(summary.diagnostics), allocator = allocator))
	}
	return lines
}

print_check_verdict :: proc(summary: Check_Summary, tag: string) {
	lines := check_verdict_lines(summary, tag, context.temp_allocator)
	defer free_all(context.temp_allocator)
	for line in lines {
		fmt.println(line)
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
	skipped:       bool,
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

// parse_stages turns "check,test,e2e" into the stage flags.
@(private)
parse_stages :: proc(list: string, options: ^CLI_Options) -> bool {
	options.stage_check = false
	options.stage_test = false
	options.stage_e2e = false
	names, split_err := strings.split(list, ",", context.temp_allocator)
	if split_err != nil {
		return false
	}
	selected := 0
	for raw in names {
		switch strings.trim_space(raw) {
		case "check":
			options.stage_check = true
			selected += 1
		case "test":
			options.stage_test = true
			selected += 1
		case "e2e":
			options.stage_e2e = true
			selected += 1
		case:
			return false
		}
	}
	return selected > 0
}

// capture_command runs a short command and returns its stdout. A file is used
// instead of a pipe so a chatty child cannot block on a full pipe.
@(private)
capture_command :: proc(argv: []string, allocator := context.allocator) -> (stdout: string, ok: bool) {
	dir, dir_err := os.make_directory_temp("", "rachel-capture-*", allocator)
	if dir_err != nil {
		return "", false
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, allocator)
	}
	out_path := fmt.aprintf("%s/stdout", dir, allocator = allocator)
	defer delete(out_path, allocator)
	file, open_err := os.open(out_path, {.Write, .Create, .Trunc})
	if open_err != nil {
		return "", false
	}
	process, start_err := os.process_start(os.Process_Desc{command = argv, stdout = file, stderr = os.stderr})
	os.close(file)
	if start_err != nil {
		return "", false
	}
	state, wait_err := os.process_wait(process, 30_000 * time.Millisecond)
	if wait_err != nil || !state.exited || state.exit_code != 0 {
		return "", false
	}
	data, read_err := os.read_entire_file(out_path, allocator)
	if read_err != nil {
		return "", false
	}
	return transmute(string)data, true
}

@(private)
justfile_has_recipe :: proc(justfile_path, recipe: string, allocator := context.allocator) -> bool {
	stdout, ok := capture_command([]string{"just", "--summary", "--justfile", justfile_path}, allocator)
	if !ok {
		return false
	}
	defer delete(stdout, allocator)
	for name in strings.split(stdout, " ", context.temp_allocator) {
		if strings.trim_space(name) == recipe {
			return true
		}
	}
	return false
}

// run_recipe_stage runs one project recipe as a stage. `test` runs per package
// that has a test file; `e2e` is a single project-wide call. A missing recipe is
// reported as a skip, not a failure: not every project has one.
run_recipe_stage :: proc(
	recipe, root: string,
	max_errors: int,
	per_package, no_deps: bool,
	allocator := context.allocator,
) -> (summary: Test_Summary, fatal: bool) {
	summary.ok = true
	if config, has_config := load_config(root); has_config {
		if entry, found := config.stages[recipe]; found && len(entry.command) > 0 {
			return run_config_stage(recipe, entry, root, max_errors, allocator)
		}
	}
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
	if !justfile_has_recipe(justfile.path, recipe, allocator) {
		summary.skipped = true
		return summary, false
	}

	display_root := root
	display_owned: string
	if resolved, resolved_ok := canonical_path(root, allocator); resolved_ok {
		display_owned = resolved
		display_root = display_owned
	}
	defer delete(display_owned, allocator)

	directories := make([dynamic]string, 0, allocator)
	defer delete_string_slice(directories, allocator)
	per_package_run := per_package && justfile.generated
	if per_package_run {
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
	to_run: []string = whole_project_call
	if per_package_run {
		to_run = directories[:]
	}
	for package_dir in to_run {
		summary.packages += 1
		result := run_just_recipe_with(justfile, root, recipe, package_dir, no_deps, allocator)
		if result.process_error != nil {
			fmt.eprintfln("[ERROR] could not run the %s stage: %s", recipe, os.error_string(result.process_error))
			odin_command_result_destroy(&result, allocator)
			summary.ok = false
			continue
		}
		summary.tests += parse_test_count(transmute(string)result.stdout, transmute(string)result.stderr)
		if !odin_command_succeeded(result) {
			// Raw output is only useful when the stage failed; a passing stage that
			// prints its whole log buries the verdict lines a reader came for.
			print_command_output(result)
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

stage_verdict_lines :: proc(summary: Test_Summary, tag: string, allocator := context.allocator) -> (lines: [dynamic]string) {
	lines = make([dynamic]string, 0, allocator)
	if summary.skipped {
		_ = append(&lines, fmt.aprintf("%sskip (no recipe)", tag, allocator = allocator))
		return lines
	}
	if summary.ok {
		switch summary.tests {
		case 0:
			_ = append(&lines, fmt.aprintf("%sok", tag, allocator = allocator))
		case 1:
			_ = append(&lines, fmt.aprintf("%sok (1 test)", tag, allocator = allocator))
		case:
			_ = append(&lines, fmt.aprintf("%sok (%d tests)", tag, summary.tests, allocator = allocator))
		}
		return lines
	}
	if summary.tests > 0 {
		if summary.failure_count == 1 {
			_ = append(&lines, fmt.aprintf("%sfail (1 of %d tests)", tag, summary.tests, allocator = allocator))
		} else {
			_ = append(&lines, fmt.aprintf("%sfail (%d of %d tests)", tag, summary.failure_count, summary.tests, allocator = allocator))
		}
	} else if summary.failure_count > 1 {
		_ = append(&lines, fmt.aprintf("%sfail (%d failures)", tag, summary.failure_count, allocator = allocator))
	} else if summary.failure_count == 1 {
		_ = append(&lines, fmt.aprintf("%sfail (1 failure)", tag, allocator = allocator))
	} else {
		_ = append(&lines, fmt.aprintf("%sfail (exit code only)", tag, allocator = allocator))
	}
	for line in summary.failures {
		_ = append(&lines, fmt.aprintf("rachel: error %s", line, allocator = allocator))
	}
	if summary.failure_count > len(summary.failures) {
		_ = append(&lines, fmt.aprintf("rachel: error ... (%d more)", summary.failure_count - len(summary.failures), allocator = allocator))
	}
	return lines
}

print_stage_verdict :: proc(summary: Test_Summary, tag: string) {
	lines := stage_verdict_lines(summary, tag, context.temp_allocator)
	defer free_all(context.temp_allocator)
	for line in lines {
		fmt.println(line)
	}
}

// record_evidence writes the failing stage and prints where it went.
@(private)
record_evidence :: proc(
	root, stage, recipe: string,
	started: time.Time,
	duration: time.Duration,
	tests, failures: int,
	lines: []string,
	paths: []string,
	allocator := context.allocator,
) {
	dir, ok := evidence_write(root, stage, recipe, 1, started, duration, tests, failures, lines, paths, allocator)
	if !ok {
		fmt.eprintfln("[ERROR] could not write evidence for the %s stage", stage)
		return
	}
	defer delete(dir, allocator)
	display := dir
	if strings.has_prefix(display, root) {
		display = strings.trim_prefix(display[len(root):], "/")
	}
	fmt.printfln("rachel: evidence %s", display)
}

print_evidence_last :: proc(options: CLI_Options, allocator := context.allocator) -> int {
	dir, ok := evidence_last(options.root, allocator)
	if !ok {
		fmt.printfln("rachel: no evidence")
		return 1
	}
	defer delete(dir, allocator)
	display := dir
	if strings.has_prefix(display, options.root) {
		display = strings.trim_prefix(display[len(options.root):], "/")
	}
	fmt.println(display)
	return 0
}

// verify_stage runs one recipe stage and reports whether verify should continue.
@(private)
verify_stage :: proc(
	recipe: string,
	per_package: bool,
	options: CLI_Options,
	failed: ^bool,
	all_lines: ^[dynamic]string,
	stages: ^[dynamic]string,
	allocator := context.allocator,
) -> bool {
	started := time.now()
	summary, fatal := run_recipe_stage(recipe, options.root, options.max_errors, per_package, true, allocator)
	duration := time.since(started)
	defer test_summary_destroy(&summary, allocator)
	if fatal {
		return false
	}
	lines := stage_verdict_lines(summary, fmt.tprintf("rachel: %s ", recipe), allocator)
	stage_start := len(all_lines^)
	for line in lines {
		fmt.println(line)
		_ = append(all_lines, line) // ownership moves to the caller's list
	}
	delete(lines)
	_ = append(stages, strings.clone(recipe, allocator))
	if summary.ok {
		return true
	}
	failed^ = true
	record_evidence(
		options.root,
		recipe,
		recipe,
		started,
		duration,
		summary.tests,
		summary.failure_count,
		all_lines[stage_start:],
		options.paths[:],
		allocator,
	)
	return options.all_stages
}

// verify_once writes .rachel/last.json on every path, so a passing run still
// leaves a current signal for the guard. Failure evidence stays separate.
verify_once :: proc(options: CLI_Options, allocator := context.allocator) -> int {
	started := time.now()
	failed := false
	all_lines := make([dynamic]string, 0, allocator)
	defer delete_string_slice(all_lines, allocator)
	stages := make([dynamic]string, 0, allocator)
	defer delete_string_slice(stages, allocator)

	if options.stage_check {
		stage_clock := time.now()
		check_summary, check_fatal := run_checks(options, allocator)
		duration := time.since(stage_clock)
		if check_fatal {
			_ = last_verdict_write(options.root, started, false, stages[:], all_lines[:], allocator)
			return 1
		}
		defer check_summary_destroy(&check_summary, allocator)
		lines := check_verdict_lines(check_summary, "rachel: check ", allocator)
		stage_start := len(all_lines)
		for line in lines {
			fmt.println(line)
			_ = append(&all_lines, line)
		}
		delete(lines)
		_ = append(&stages, strings.clone("check", allocator))
		if !check_summary.ok {
			failed = true
			record_evidence(
				options.root,
				"check",
				"check",
				stage_clock,
				duration,
				check_summary.checked,
				check_summary.failures,
				all_lines[stage_start:],
				options.paths[:],
				allocator,
			)
			if !options.all_stages {
				_ = last_verdict_write(options.root, started, false, stages[:], all_lines[:], allocator)
				return 1
			}
		}
	}

	if options.stage_test {
		if !verify_stage("test", true, options, &failed, &all_lines, &stages, allocator) {
			_ = last_verdict_write(options.root, started, failed == false && false, stages[:], all_lines[:], allocator)
			return 1
		}
	}
	if options.stage_e2e {
		if !verify_stage("e2e", false, options, &failed, &all_lines, &stages, allocator) {
			_ = last_verdict_write(options.root, started, false, stages[:], all_lines[:], allocator)
			return 1
		}
	}

	_ = last_verdict_write(options.root, started, !failed, stages[:], all_lines[:], allocator)
	return failed ? 1 : 0
}
