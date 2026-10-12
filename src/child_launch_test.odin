package main

import "core:strings"
import "core:testing"

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
