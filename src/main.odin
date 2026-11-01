package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

main :: proc() {
	context.logger = setup_logging()
	if guard_code := dev_guard_check(); guard_code != 0 {
		os.exit(guard_code)
	}
	exit_code := run_cli(os.args[1:])
	if exit_code != 0 {
		os.exit(exit_code)
	}
}

run_cli :: proc(args: []string) -> int {
	command, err := parse_args(args)
	if err != "" {
		write_error(err)
		return 2
	}

	if command.kind == .Help {
		fmt.println(USAGE)
		return 0
	}

	if command.kind == .Status {
		return run_status(command.brew_id, command.stations)
	}
	if command.kind == .Log {
		return run_log(command.brew_id, command.shot_id, command.tail, command.dump)
	}
	if command.kind == .Reply {
		return run_reply(command.brew_id, command.shot_id, command.message, command.print_only)
	}
	if command.kind == .Host {
		if command.host_impl == .Go {
			return run_host_go(os.get_env("CS_CSD", context.temp_allocator), os.get_env("PATH", context.temp_allocator))
		}
		return run_host()
	}
	if command.kind == .Prepare {
		return run_prepare(command.repo, command.branch, command.worktree_dir)
	}
	if command.kind == .Release {
		return run_release(command.repo, command.worktree_dir)
	}
	if command.kind == .Pr {
		return run_pr(command.run_id, command.shot_id, command.branch, command.remote, command.message, command.blend)
	}
	if command.kind == .Cleanup {
		return run_cleanup(command.run_id, command.branch, command.workspace)
	}
	if command.kind == .Station {
		return run_station(command.report_path, command.shot_id, command.brew_id, command.prompt, command.prompt_file, command.shot_kind, command.taste, command.message, Shot_Options{interactive = command.interactive, codemode = command.codemode}, command.agent)
	}
	if command.kind == .Server {
		return run_server(command.state_root, command.repo)
	}


	write_error("command not implemented yet")
	return 3
}

write_error :: proc(message: string) {
	stderr := os.to_stream(os.stderr)
	fmt.wprintfln(stderr, "coffee-shop: %s", message)
	fmt.wprintln(stderr, "Run `coffee-shop --help` for usage.")
}

GO_HOST_NAME :: "csd"

GO_HOST_MISSING :: "--impl=go needs the Go host binary: set CS_CSD to its path, or put csd on PATH"

// The Go host comes from CS_CSD, then PATH, then this build's embedded copy, which is
// written under the state directory. A missing binary is reported here instead of
// surfacing as a failed exec.
resolve_go_host :: proc(csd_env, path_env: string) -> (path: string, found: bool) {
	if csd_env != "" {
		return csd_env, os.is_file(csd_env)
	}
	remaining := path_env
	for directory in strings.split_iterator(&remaining, ":") {
		if directory == "" {
			continue
		}
		candidate, _ := filepath.join({directory, GO_HOST_NAME}, context.temp_allocator)
		if os.is_file(candidate) {
			return candidate, true
		}
	}
	return "", false
}

// The host protocol is line-delimited JSON on stdin/stdout, so the Go host has to
// replace this process: a wrapper that buffered either stream would break it.
// Returns only when the exec itself failed.
exec_go_host :: proc(path: string) -> string {
	argv := [2]cstring{strings.clone_to_cstring(path, context.temp_allocator), nil}
	posix.execv(argv[0], raw_data(argv[:]))
	return fmt.tprintf("cannot exec the Go host %s: %v", path, posix.get_errno())
}

run_host_go :: proc(csd_env, path_env: string) -> int {
	path, found := resolve_go_host(csd_env, path_env)
	// The Pi extension and the private host directory are csd's start-up now: it installs
	// the extension itself (go/internal/extension.Install), so a fresh state directory
	// dispatches without this binary doing anything before the handover.
	state_root, state_err := default_state_root(context.temp_allocator)
	if state_err != "" {
		write_error(state_err)
		return 1
	}
	if !found && csd_embedded() {
		// A normal build carries the Go host, so there is nothing to install by hand.
		extracted, extract_reason := csd_extract(state_root, context.allocator)
		if extract_reason != "" {
			write_error(extract_reason)
			return 1
		}
		path, found = extracted, true
	}
	if !found {
		write_error(GO_HOST_MISSING)
		return 1
	}
	write_error(exec_go_host(path))
	return 1
}
