package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// A project owns its commands in .rachel.json, so Rachel does not need to know
// the language of the project it checks. The justfile recipes remain the fallback
// for projects that already have one.
RACHEL_CONFIG_FILE :: ".rachel.json"
RACHEL_WATCH_DEBOUNCE :: "500ms"

Stage_Config :: struct {
	command:     []string `json:"command"`,
	filters:     []string `json:"filters"`,
	working_dir: string   `json:"working_dir"`,
}

Rachel_Config :: struct {
	version: int                     `json:"version"`,
	stages:  map[string]Stage_Config `json:"stages"`,
}

/**
 * load_config reads .rachel.json. A missing or malformed file is not an error:
 * the caller falls back to the project's justfile, which is what every existing
 * project uses.
 */
load_config :: proc(root: string) -> (config: Rachel_Config, ok: bool) {
	path, join_err := filepath.join({root, RACHEL_CONFIG_FILE}, context.temp_allocator)
	if join_err != nil {
		return {}, false
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return {}, false
	}
	// The temp allocator is right for a value that lives for one command: every
	// caller uses the config and returns, and tests free it with free_all.
	if unmarshal_err := json.unmarshal(data, &config, allocator = context.temp_allocator); unmarshal_err != nil {
		return {}, false
	}
	return config, len(config.stages) > 0
}

/** stage_filters collects the watch filters of every configured stage. */
stage_filters :: proc(config: Rachel_Config, allocator := context.allocator) -> (filters: [dynamic]string) {
	filters = make([dynamic]string, 0, allocator)
	for _, entry in config.stages {
		for filter in entry.filters {
			duplicate := false
			for existing in filters {
				if existing == filter {
					duplicate = true
					break
				}
			}
			if duplicate {
				continue
			}
			if cloned, clone_err := strings.clone(filter, allocator); clone_err == nil {
				_ = append(&filters, cloned)
			}
		}
	}
	return filters
}

/**
 * watch_argv is watchexec invoking Rachel, not Rachel watching: one watcher, one
 * project, the configured filters, and a verify run per batch. A file watcher is
 * the one thing every language needs and none of them wants written per project.
 */
watch_argv :: proc(
	rachel_binary, root: string,
	config: Rachel_Config,
	debounce := RACHEL_WATCH_DEBOUNCE,
	allocator := context.allocator,
) -> (argv: [dynamic]string) {
	argv = make([dynamic]string, 0, allocator)
	for arg in ([]string{"watchexec", "-q", "-d", debounce, "-w", root}) {
		_ = append(&argv, strings.clone(arg, allocator) or_else "")
	}
	filters := stage_filters(config, allocator)
	defer delete_string_slice(filters, allocator)
	for filter in filters {
		_ = append(&argv, strings.clone("-f", allocator) or_else "")
		_ = append(&argv, strings.clone(filter, allocator) or_else "")
	}
	for arg in ([]string{"--", rachel_binary, "verify", "--from-env", root}) {
		_ = append(&argv, strings.clone(arg, allocator) or_else "")
	}
	return argv
}

/**
 * run_config_stage runs a configured command and normalizes its output into the
 * same verdict the justfile path produces. There is no package narrowing here:
 * the command is the project's, so it decides its own scope.
 */
run_config_stage :: proc(
	stage: string,
	entry: Stage_Config,
	root: string,
	max_errors: int,
	allocator := context.allocator,
) -> (summary: Test_Summary, fatal: bool) {
	summary.ok = true
	workdir := root
	if entry.working_dir != "" {
		joined, join_err := filepath.join({root, entry.working_dir}, allocator)
		if join_err != nil {
			fmt.eprintfln("[ERROR] cannot resolve the %s stage directory: %s", stage, os.error_string(os.Error(join_err)))
			return summary, true
		}
		defer delete(joined, allocator)
		workdir = joined
	}
	state, stdout, stderr, process_err := os.process_exec(
		os.Process_Desc{working_dir = workdir, command = entry.command},
		allocator,
	)
	defer {
		delete(stdout, allocator)
		delete(stderr, allocator)
	}
	if process_err != nil {
		fmt.eprintfln("[ERROR] cannot run the %s stage: %s", stage, os.error_string(process_err))
		return summary, true
	}
	summary.tests = parse_test_count(transmute(string)stdout, transmute(string)stderr)
	if state.exited && state.exit_code == 0 {
		return summary, false
	}
	summary.ok = false
	if len(stdout) > 0 {
		fmt.eprintln(transmute(string)stdout)
	}
	if len(stderr) > 0 {
		fmt.eprintln(transmute(string)stderr)
	}
	lines, total := collect_diagnostics(transmute(string)stdout, transmute(string)stderr, root, max_errors, allocator)
	if total == 0 {
		// A test runner's failure lines are not compiler diagnostics; e.g. Odin
		// prints "[ERROR] --- [timestamp] [location] message".
		delete_string_slice(lines, allocator)
		lines, total = collect_test_failures(transmute(string)stdout, transmute(string)stderr, root, max_errors, allocator)
	}
	summary.failure_count = total
	for line in lines {
		if max_errors == 0 || len(summary.failures) < max_errors {
			_ = append(&summary.failures, line)
		} else {
			delete(line, allocator)
		}
	}
	delete(lines)
	if summary.failure_count == 0 {
		fallback := fmt.aprintf("%s exited %d", stage, state.exit_code, allocator = allocator)
		_ = append(&summary.failures, fallback)
		summary.failure_count = 1
	}
	return summary, false
}

/**
 * watch_project runs watchexec around Rachel. It is deliberately a thin launcher:
 * a file watcher is the one thing every project needs and none wants to write
 * again, and keeping it outside Rachel means Rachel carries no polling loop of
 * its own and works for any language the project configures.
 */
run_watcher :: proc(options: CLI_Options, allocator := context.allocator) -> int {
	config, has_config := load_config(options.root)
	if !has_config {
		fmt.eprintln("[ERROR] no .rachel.json with stages here; add one, or use `rachel <dir>` for Odin")
		return 2
	}
	executable, exec_err := os.get_executable_path(allocator)
	if exec_err != nil {
		fmt.eprintfln("[ERROR] cannot locate the rachel binary: %s", os.error_string(exec_err))
		return 1
	}
	defer delete(executable, allocator)
	argv := watch_argv(executable, options.root, config, options.debounce, allocator)
	defer delete_string_slice(argv, allocator)
	state, _, _, process_err := os.process_exec(
		os.Process_Desc{command = argv[:], stdin = os.stdin, stdout = os.stdout, stderr = os.stderr},
		allocator,
	)
	if process_err != nil {
		fmt.eprintfln("[ERROR] cannot start watchexec: %s", os.error_string(process_err))
		fmt.eprintln("        install watchexec, or run: watchexec -q -w <dir> -- rachel verify --from-env <dir>")
		return 1
	}
	if state.exited {
		return state.exit_code
	}
	return 0
}
