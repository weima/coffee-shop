package main

import "core:fmt"
import "core:os"
import "core:strings"
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
test_child_shell_prefix_quotes_every_element :: proc(t: ^testing.T) {
	prefix := child_shell_prefix([]string{"odin", "run", "/a b/src", "-out:/tmp/x.bin", "--"})
	testing.expect_value(t, prefix, "'odin' 'run' '/a b/src' '-out:/tmp/x.bin' '--'")
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

@(test)
test_odin_run_child_is_zero_for_a_process_that_is_not_odin_run :: proc(t: ^testing.T) {
	// The test runner is not an odin run wrapper, so no child may be signalled on its behalf.
	testing.expect_value(t, odin_run_child(os.get_pid()), 0)
}
