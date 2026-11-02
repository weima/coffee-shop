package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(test)
test_child_launch_outside_dev_is_this_executable :: proc(t: ^testing.T) {
	argv, err := child_launch_argv_for("", "", false, "/bin/coffee-shop", "/tmp/out.bin", context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(argv), 1)
	if len(argv) == 1 {
		testing.expect_value(t, argv[0], "/bin/coffee-shop")
	}
}

@(test)
test_child_launch_in_dev_builds_the_dev_repo_with_a_unique_output :: proc(t: ^testing.T) {
	argv, err := child_launch_argv_for("dev", "/repo", true, "/bin/coffee-shop", "/tmp/out.bin", context.temp_allocator)
	testing.expect_value(t, err, "")
	expected := []string{"odin", "run", "/repo/src", "-out:/tmp/out.bin", "--"}
	testing.expect_value(t, len(argv), len(expected))
	for want, i in expected {
		if i < len(argv) {
			testing.expect_value(t, argv[i], want)
		}
	}
}

@(test)
test_child_launch_refuses_dev_without_a_usable_repo :: proc(t: ^testing.T) {
	_, err := child_launch_argv_for("dev", "", false, "/bin/coffee-shop", "/tmp/out.bin", context.temp_allocator)
	testing.expect(t, strings.contains(err, "CS_DEV_REPO is unset"), err)
	_, err = child_launch_argv_for("dev", "/nowhere", false, "/bin/coffee-shop", "/tmp/out.bin", context.temp_allocator)
	testing.expect(t, strings.contains(err, "has no src package"), err)
}

@(test)
test_child_shell_prefix_leaves_odin_run_unquoted :: proc(t: ^testing.T) {
	prefix := child_shell_prefix([]string{"odin", "run", "/a b/src", "-out:/tmp/x.bin", "--"})
	testing.expect_value(t, prefix, "odin run '/a b/src' '-out:/tmp/x.bin' '--'")
}

@(test)
test_child_shell_prefix_quotes_executable_paths :: proc(t: ^testing.T) {
	prefix := child_shell_prefix([]string{"/path with spaces/coffee-shop"})
	testing.expect_value(t, prefix, "'/path with spaces/coffee-shop'")
}

@(test)
test_child_sweep_removes_only_outputs_of_dead_launchers :: proc(t: ^testing.T) {
	dir, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-child-sweep-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(dir)
	defer delete(dir)

	dead := fmt.tprintf("%s/cs-child-2147483000-1.bin", dir)
	live := fmt.tprintf("%s/cs-child-%d-2.bin", dir, os.get_pid())
	other := fmt.tprintf("%s/unrelated.bin", dir)
	for path in ([]string{dead, live, other}) {
		_ = os.write_entire_file(path, "x", os.Permissions{.Read_User, .Write_User})
	}
	child_sweep_outputs(dir)
	testing.expect(t, !os.exists(dead), "output of a dead launcher must be removed")
	testing.expect(t, os.exists(live), "output of a live launcher must stay")
	testing.expect(t, os.exists(other), "unrelated files must stay")
}

@(test)
test_dev_cancel_escalate_kills_the_group_after_the_timeout :: proc(t: ^testing.T) {
	// A process group that leads itself, as an odin run wrapper does.
	leader, start_err := os.process_start(os.Process_Desc{command = {"perl", "-e", "setpgrp(0,0); exec 'sleep', '300'"}})
	testing.expect_value(t, start_err, nil)
	if start_err != nil {
		return
	}
	dev_cancel_escalate(leader.pid, 1)
	// The leader is our child, so it is reaped only by waiting: a wait that ends means it was killed.
	_, wait_err := os.process_wait(leader, 10*time.Second)
	testing.expect(t, wait_err == nil, "the escalation must kill the wrapper's process group after the timeout")
}

// Runs in a forked copy that leads its own group, so a refused group kill cannot reach the runner.
// Exits 0 when the target stayed alive for the whole timeout, 1 when it was killed.
escalation_refused_in_own_group :: proc(as_group: bool) -> int {
	pid := posix.fork()
	if pid == 0 {
		_ = posix.setpgid(0, 0)
		sleeper, _ := os.process_start(os.Process_Desc{command = {"sleep", "300"}})
		dev_cancel_escalate(os.get_pid() if as_group else sleeper.pid, 1)
		time.sleep(3 * time.Second)
		alive := posix.kill(posix.pid_t(sleeper.pid), posix.Signal(0)) == .OK
		_ = posix.kill(posix.pid_t(sleeper.pid), .SIGKILL)
		posix._exit(0 if alive else 1)
	}
	status: i32
	for posix.waitpid(pid, &status, {}) == -1 {
		if posix.errno() != .EINTR {
			return -1
		}
	}
	if !posix.WIFEXITED(status) {
		return 2 // the forked caller itself was killed: the bug
	}
	return int(posix.WEXITSTATUS(status))
}

@(test)
test_dev_cancel_escalate_refuses_the_callers_own_group :: proc(t: ^testing.T) {
	testing.expect_value(t, escalation_refused_in_own_group(true), 0)
}

@(test)
test_dev_cancel_escalate_refuses_a_pid_in_the_callers_group :: proc(t: ^testing.T) {
	testing.expect_value(t, escalation_refused_in_own_group(false), 0)
}

@(test)
test_odin_run_child_is_zero_for_a_process_that_is_not_odin_run :: proc(t: ^testing.T) {
	// The test runner is not an odin run wrapper, so no child may be signalled on its behalf.
	testing.expect_value(t, odin_run_child(os.get_pid()), 0)
}

// Counts this process's children that have exited but were never waited on.
defunct_children :: proc() -> int {
	out, _ := exec_reaped({"ps", "-axo", "ppid=,stat="}, context.temp_allocator)
	me := fmt.tprintf("%d", os.get_pid())
	count := 0
	for line in strings.split_lines(string(out), context.temp_allocator) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 2 && fields[0] == me && strings.has_prefix(fields[1], "Z") {
			count += 1
		}
	}
	return count
}

// Runs in a forked copy of the test process. The copy has one thread and no children but
// its own, so defunct_children() there counts only what this test spawned; the runner's other
// threads (and their children) are not in it. Exits with the number left unreaped, capped.
short_lived_children_unreaped :: proc() -> int {
	pid := posix.fork()
	if pid == 0 {
		before := defunct_children()
		for _ in 0 ..< 20 {
			_ = process_commands_ps()
			dev_cancel_escalate(2147483000, 1)
		}
		time.sleep(300 * time.Millisecond)
		posix._exit(c.int(min(defunct_children() - before, 100)))
	}
	if pid < 0 {
		return -1
	}
	status: i32
	for posix.waitpid(pid, &status, {}) == -1 {
		if posix.errno() != .EINTR {
			return -1
		}
	}
	if !posix.WIFEXITED(status) {
		return -1
	}
	return int(posix.WEXITSTATUS(status))
}

@(test)
test_short_lived_children_are_reaped :: proc(t: ^testing.T) {
	testing.expect_value(t, short_lived_children_unreaped(), 0)
}
