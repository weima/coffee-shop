package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

// The argv that starts one child Coffee Shop process: a Station, a brew Worker, or the
// server. Normally that is this executable. In dev mode (CS_MODE=dev) it is odin run
// against CS_DEV_REPO/src, so the child builds the current source. odin run removes its
// output on a clean exit; a dev launch sweeps the rest. Dev mode without a usable CS_DEV_REPO refuses to start
// a child, rather than fall back to a path that odin run may have removed.
child_launch_argv :: proc(exe: string) -> (argv: []string, err: string) {
	repo := os.get_env("CS_DEV_REPO", context.temp_allocator)
	has_src := repo != "" && os.is_dir(fmt.tprintf("%s/src", repo))
	mode := os.get_env("CS_MODE", context.temp_allocator)
	if mode == "dev" {
		child_sweep_outputs(child_output_dir())
	}
	return child_launch_argv_for(mode, repo, has_src, exe, child_output_path(), context.temp_allocator)
}

// The selection with its inputs passed in, so tests need no process environment.
child_launch_argv_for :: proc(mode, repo: string, has_src: bool, exe, out: string, allocator := context.allocator) -> (argv: []string, err: string) {
	if mode != "dev" {
		argv = make([]string, 1, allocator)
		argv[0] = exe
		return argv, ""
	}
	if repo == "" {
		return nil, "CS_MODE=dev but CS_DEV_REPO is unset, so no Coffee Shop child can start; set it to the checkout root"
	}
	if !has_src {
		return nil, fmt.tprintf("CS_MODE=dev but CS_DEV_REPO has no src package: %s", repo)
	}
	argv = make([]string, 5, allocator)
	argv[0] = "odin"
	argv[1] = "run"
	argv[2] = fmt.aprintf("%s/src", repo, allocator = allocator)
	argv[3] = fmt.aprintf("-out:%s", out, allocator = allocator)
	argv[4] = "--"
	return argv, ""
}

// The argv as one shell command prefix, every element quoted.
child_shell_prefix :: proc(argv: []string) -> string {
	parts := make([dynamic]string, 0, len(argv), context.temp_allocator)
	for arg in argv {
		append(&parts, shell_quote(arg))
	}
	joined := strings.join(parts[:], " ", context.temp_allocator)
	for quoted in parts {
		delete(quoted)
	}
	return joined
}

child_output_dir :: proc() -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	return dir if dir_err == nil else "/tmp"
}

// A unique output path per child, named by the launching process, so parallel odin runs
// never share a binary and a sweep can tell whose output it is.
child_output_path :: proc() -> string {
	return fmt.tprintf("%s/cs-child-%d-%d.bin", child_output_dir(), os.get_pid(), time.now()._nsec)
}

// odin run keeps its output when the child exits non-zero or is killed, and a cancelled
// Station exits non-zero. A dev launch removes the outputs of launchers that have exited.
// shortcut: a long-lived host keeps its own children's outputs until it exits, then the next launch sweeps them.
child_sweep_outputs :: proc(dir: string) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for info in infos {
		name := info.name
		if !strings.has_prefix(name, "cs-child-") || !strings.has_suffix(name, ".bin") {
			continue
		}
		rest := strings.trim_suffix(strings.trim_prefix(name, "cs-child-"), ".bin")
		launcher_text, _, _ := strings.partition(rest, "-")
		launcher, ok := strconv.parse_int(launcher_text)
		if !ok || launcher <= 0 {
			continue
		}
		if posix.kill(posix.pid_t(launcher), posix.Signal(0)) != .OK && posix.errno() == .ESRCH {
			_ = os.remove(fmt.tprintf("%s/%s", dir, name))
		}
	}
}

// In dev mode the identified process can be the odin run wrapper, which does not forward
// SIGTERM to its child. Returns the first child of an odin run wrapper, or 0 when pid is
// not one, so every other process is signalled as before.
odin_run_child :: proc(pid: int) -> int {
	command_state, command_out, _, command_err := os.process_exec(os.Process_Desc{command = {"ps", "-o", "command=", "-p", fmt.tprintf("%d", pid)}}, context.temp_allocator)
	if command_err != nil || !command_state.success || !strings.has_prefix(strings.trim_space(string(command_out)), "odin run") {
		return 0
	}
	child_state, child_out, _, child_err := os.process_exec(os.Process_Desc{command = {"pgrep", "-P", fmt.tprintf("%d", pid)}}, context.temp_allocator)
	if child_err != nil || !child_state.success {
		return 0
	}
	fields := strings.fields(string(child_out), context.temp_allocator)
	if len(fields) == 0 {
		return 0
	}
	child, ok := strconv.parse_int(fields[0])
	if !ok {
		return 0
	}
	return child
}
