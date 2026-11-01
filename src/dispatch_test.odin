package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Names must be unique across tests in one process: a removed root can otherwise be
// recreated under the same path while a server from the earlier test still uses it.
TEMP_DIR :: "/private/tmp" when ODIN_OS == .Darwin else "/tmp"

fixture_sequence: int

make_fixture_root :: proc(t: ^testing.T) -> string {
	sequence := sync.atomic_add(&fixture_sequence, 1)
	root, err := os.make_directory_temp(TEMP_DIR, fmt.tprintf("cs-%d-%d-*", os.get_pid(), sequence), context.allocator)
	testing.expect_value(t, err, os.Error(nil))
	return root
}

remove_fixture_root :: proc(root: string) {
	_ = os.remove_all(root)
	delete(root)
}

make_fixture_repo :: proc(t: ^testing.T, path: string) {
	for args in ([][]string{
		{"git", "init", "-q", path},
		{"git", "-C", path, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"},
	}) {
		state, git_out, git_err, err := os.process_exec(os.Process_Desc{command = args}, context.allocator)
		if !(err == nil && state.success) {
			fd_entries, _ := os.read_all_directory_by_path("/proc/self/fd", context.temp_allocator)
			log.errorf("make_fixture_repo: %v failed err=%v exit=%v open_fds=%d stdout=%q stderr=%q", args, err, state.exit_code, len(fd_entries), git_out, git_err)
		}
		testing.expect(t, err == nil && state.success)
	}
}

@(test)
test_state_root_uses_cs_state_dir_when_set_and_home_otherwise :: proc(t: ^testing.T) {
	path, err := resolve_state_root("/data/cs", "/home/me")
	testing.expect_value(t, err, "")
	testing.expect_value(t, path, "/data/cs")
	delete(path)

	path, err = resolve_state_root("", "/home/me")
	testing.expect_value(t, err, "")
	testing.expect_value(t, path, "/home/me/.coffee-shop")
	delete(path)
}

@(test)
test_state_root_rejects_relative_override_and_missing_home :: proc(t: ^testing.T) {
	// A relative path would mean different directories for brew and its Workers.
	_, err := resolve_state_root("relative/dir", "/home/me")
	testing.expect_value(t, err, "CS_STATE_DIR must be an absolute path")

	_, err = resolve_state_root("", "")
	testing.expect_value(t, err, "set CS_STATE_DIR: could not locate the home directory")
}
