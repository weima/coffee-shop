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

// The dev launcher is the fixed command `odin run`; keep those command words
// bare for Herdr, and quote every path and argument.
child_shell_prefix :: proc(argv: []string) -> string {
	parts := make([dynamic]string, 0, len(argv), context.temp_allocator)
	odin_run := len(argv) >= 2 && argv[0] == "odin" && argv[1] == "run"
	for arg, index in argv {
		if odin_run && index < 2 {
			append(&parts, strings.clone(arg, context.allocator))
		} else {
			append(&parts, shell_quote(arg))
		}
	}
	joined := strings.join(parts[:], " ", context.temp_allocator)
	for part in parts {
		delete(part)
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
// SIGTERM to its child. Returns the wrapper's first child, or 0 when pid is not an odin run.
// ps is not used: under Odin's process_exec it reports Permission_Denied even on success.
odin_run_child :: proc(pid: int) -> int {
	wrappers_state, wrappers_out, _, wrappers_err := os.process_exec(os.Process_Desc{command = {"pgrep", "-f", "^odin run"}}, context.temp_allocator)
	if wrappers_err != nil || !wrappers_state.success {
		return 0
	}
	is_wrapper := false
	for listed in strings.fields(string(wrappers_out), context.temp_allocator) {
		if listed == fmt.tprintf("%d", pid) {
			is_wrapper = true
		}
	}
	if !is_wrapper {
		return 0
	}
	children_state, children_out, _, children_err := os.process_exec(os.Process_Desc{command = {"pgrep", "-P", fmt.tprintf("%d", pid)}}, context.temp_allocator)
	if children_err != nil || !children_state.success {
		return 0
	}
	fields := strings.fields(string(children_out), context.temp_allocator)
	if len(fields) == 0 {
		return 0
	}
	child, ok := strconv.parse_int(fields[0])
	if !ok {
		return 0
	}
	return child
}

// A dev cancel the Station has not finished within this many seconds is killed. Its odin
// run wrapper leads the process group, so the group takes the Station and Pi with it.
// shortcut: a Station mid-turn loses that turn at the timeout, not at a clean stop; a clean stop would need the Station to answer the cancel itself.
DEV_CANCEL_TIMEOUT_SECONDS :: 60

// Runs after the timeout, in the background. The target is re-read then, because the pid may
// have been reused during the sleep. $1 seconds, $2 wrapper pid, $3 the caller's group.
// Refuses a pid that is gone or whose group is unreadable, and any target in the caller's group.
// The group form is used only when the wrapper leads its own group; else only the wrapper dies.
// shortcut: a wrapper that exited before the timeout is not signalled, so its surviving Station is left to the tab-close fallback.
DEV_CANCEL_KILL_SCRIPT :: `(sleep "$1"
pg=$(ps -o pgid= -p "$2" 2>/dev/null | tr -d ' ')
[ -n "$pg" ] && [ "$pg" != "$3" ] || exit 0
if [ "$pg" = "$2" ]; then kill -KILL -- "-$2"; else kill -KILL "$2"; fi) 2>/dev/null </dev/null >/dev/null 2>&1 &`

// Schedules a guarded SIGKILL of the wrapper (and its group, when it leads one) after seconds.
dev_cancel_escalate :: proc(wrapper, seconds: int) {
	command := []string{
		"/bin/sh", "-c", DEV_CANCEL_KILL_SCRIPT,
		"coffee-shop",
		fmt.tprintf("%d", seconds),
		fmt.tprintf("%d", wrapper),
		fmt.tprintf("%d", int(posix.getpgrp())),
	}
	process, spawn_err := os.process_start(os.Process_Desc{command = command})
	if spawn_err != nil {
		return
	}
	_, _ = process_reap(process)
}

// Waits for a child we started and reaps it. os.process_wait cannot be used for this on
// macOS: it first checks the handle with proc_pid_rusage, which fails for a child that has
// already exited, so it returns an error and leaves the zombie behind until this process dies.
// A short-lived child (a shell that backgrounds and exits) is exactly that case.
process_reap :: proc(process: os.Process) -> (state: os.Process_State, err: os.Error) {
	state.pid = process.pid
	status: i32
	for {
		if posix.waitpid(posix.pid_t(process.pid), &status, {}) != -1 {
			break
		}
		if errno := posix.errno(); errno != .EINTR {
			return state, errno
		}
	}
	state.exited = true
	if posix.WIFEXITED(status) {
		state.exit_code = int(posix.WEXITSTATUS(status))
	} else if posix.WIFSIGNALED(status) {
		state.exit_code = int(posix.WTERMSIG(status))
	}
	state.success = posix.WIFEXITED(status) && state.exit_code == 0
	return
}

// Runs a short-lived command and returns its stdout, always reaping the child. os.process_exec
// cannot be used for a setuid binary such as ps on macOS: its wait fails with Permission_Denied
// (proc_pid_rusage is refused) and the child is never reaped, so each call left one zombie.
exec_reaped :: proc(command: []string, allocator := context.allocator) -> (stdout: []byte, ok: bool) {
	read_end, write_end, pipe_err := os.pipe()
	if pipe_err != nil {
		return nil, false
	}
	defer os.close(read_end)
	process, start_err := os.process_start(os.Process_Desc{command = command, stdout = write_end})
	_ = os.close(write_end)
	if start_err != nil {
		return nil, false
	}
	data, read_err := os.read_entire_file(read_end, allocator)
	state, wait_err := process_reap(process)
	return data, read_err == nil && wait_err == nil && state.success
}
