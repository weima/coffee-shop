package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_server_election_admits_one_holder :: proc(t: ^testing.T) {
	root := make_test_state_directory(t)
	defer remove_test_state_directory(root)
	id := server_id("/work/gac")
	defer delete(id)
	directory := server_directory(root, id)
	defer delete(directory)

	first, first_ok := server_acquire(directory)
	testing.expect(t, first_ok, "the first server must be admitted")
	_, second_ok := server_acquire(directory)
	testing.expect(t, !second_ok, "a second server must not be admitted")
	file_lock_release(first)

	third, third_ok := server_acquire(directory)
	testing.expect(t, third_ok, "a server may start once the first has gone")
	file_lock_release(third)
}

@(test)
test_server_running_tracks_the_election_lock :: proc(t: ^testing.T) {
	root := make_test_state_directory(t)
	defer remove_test_state_directory(root)
	id := server_id("/work/gac")
	defer delete(id)
	directory := server_directory(root, id)
	defer delete(directory)

	testing.expect(t, !server_running(directory), "no lock file means no server")
	lock, ok := server_acquire(directory)
	testing.expect(t, ok, "the lock must be acquired")
	testing.expect(t, server_running(directory), "a held lock means a running server")
	file_lock_release(lock)
	testing.expect(t, !server_running(directory), "a released lock means no running server")
}

@(test)
test_server_restart_keeps_id_and_increments_generation :: proc(t: ^testing.T) {
	root := make_test_state_directory(t)
	defer remove_test_state_directory(root)
	id := server_id("/work/gac")
	defer delete(id)
	directory := server_directory(root, id)
	defer delete(directory)
	socket_path := fmt.aprintf("%s/gac.sock", TEMP_DIR)
	defer delete(socket_path)

	first_lock, first, first_ok := server_start(directory, id, "/work/gac", socket_path)
	testing.expect(t, first_ok, "the first start must succeed")
	testing.expect_value(t, first.generation, 1)
	file_lock_release(first_lock)

	second_lock, second, second_ok := server_start(directory, id, "/work/gac", socket_path)
	testing.expect(t, second_ok, "a restart must succeed once the first has gone")
	testing.expect_value(t, second.generation, 2)
	testing.expect(t, second.id == first.id, "a restart keeps the server id")
	file_lock_release(second_lock)

	stored, stored_ok := server_read_record(directory)
	testing.expect(t, stored_ok, "server.json must be readable")
	defer destroy_struct(&stored)
	testing.expect_value(t, stored.id, id)
	testing.expect_value(t, stored.generation, 2)
}

@(test)
test_server_id_is_stable_and_separates_same_named_repositories :: proc(t: ^testing.T) {
	first := server_id("/work/gac/app")
	defer delete(first)
	again := server_id("/work/gac/app")
	defer delete(again)
	other := server_id("/other/app")
	defer delete(other)

	testing.expect_value(t, first, again)
	testing.expect(t, first != other, "same-named repositories must get different ids")
	testing.expect(t, strings.has_prefix(first, "app-"), first)
}

@(test)
test_server_heartbeat_updates_the_stored_record :: proc(t: ^testing.T) {
	root := make_test_state_directory(t)
	defer remove_test_state_directory(root)
	id := server_id("/work/gac")
	defer delete(id)
	directory := server_directory(root, id)
	defer delete(directory)
	socket_path := fmt.aprintf("%s/gac.sock", TEMP_DIR)
	defer delete(socket_path)

	lock, record, ok := server_start(directory, id, "/work/gac", socket_path)
	testing.expect(t, ok, "the start must succeed")
	defer file_lock_release(lock)
	before := record.heartbeat_ns

	time.sleep(5 * time.Millisecond)
	beat_ok := server_heartbeat(directory, &record)
	testing.expect(t, beat_ok, "the heartbeat must be written")

	stored, stored_ok := server_read_record(directory)
	testing.expect(t, stored_ok, "server.json must be readable")
	defer destroy_struct(&stored)
	testing.expect(t, stored.heartbeat_ns > before, "the stored heartbeat must advance")
}

// Removing and recreating the server directory leaves the old lock on a file the
// path no longer names. That lock must not count as the server's.
@(test)
test_stale_lock_is_not_current_after_its_directory_is_recreated :: proc(t: ^testing.T) {
	root := make_test_state_directory(t)
	defer remove_test_state_directory(root)
	id := server_id("/work/gac")
	defer delete(id)
	directory := server_directory(root, id)
	defer delete(directory)

	old_lock, old_ok := server_acquire(directory)
	testing.expect(t, old_ok, "the first server must be admitted")
	testing.expect(t, server_lock_is_current(directory, old_lock), "a fresh lock is current")

	testing.expect(t, os.remove_all(directory) == nil, "the directory must be removable")
	new_lock, new_ok := server_acquire(directory)
	testing.expect(t, new_ok, "the recreated directory has a new lock file")
	testing.expect(t, !server_lock_is_current(directory, old_lock), "the old lock names a deleted file")
	testing.expect(t, server_lock_is_current(directory, new_lock), "the new lock is current")

	file_lock_release(old_lock)
	file_lock_release(new_lock)
}

// A Brew on `repository` with a Shot that has not finished.
idle_fixture_brew :: proc(t: ^testing.T, root, repository: string, supervised: bool) {
	register := make_test_register(t)
	defer destroy_struct(&register)
	delete(register.beans_path)
	register.beans_path = strings.clone(repository)
	brew_dir := fmt.tprintf("%s/brew-test", root)
	testing.expect_value(t, create_state(brew_dir, &register).kind, State_Error_Kind.None)
	if supervised {
		testing.expect(t, write_supervisor(brew_dir))
	}
}

// Runs the server loop with a short idle limit and reports how long it took.
idle_run :: proc(root, repository: string) -> (code: int, elapsed: time.Duration) {
	started := time.tick_now()
	code = run_server_idle(root, repository, 1_500_000_000)
	return code, time.tick_since(started)
}

@(test)
test_server_with_no_brew_exits_within_the_timeout :: proc(t: ^testing.T) {
	root := make_test_state_directory(t)
	defer remove_test_state_directory(root)
	code, elapsed := idle_run(root, root)
	testing.expect_value(t, code, 0)
	testing.expect(t, elapsed < 6 * time.Second, "an idle server must exit")
}

@(test)
test_server_exits_when_the_only_brew_lost_its_supervisor :: proc(t: ^testing.T) {
	root := make_test_state_directory(t)
	defer remove_test_state_directory(root)
	idle_fixture_brew(t, root, root, false)
	testing.expect(t, !repository_has_active_brew(root, root), "a crashed Brew must not block")
	code, elapsed := idle_run(root, root)
	testing.expect_value(t, code, 0)
	testing.expect(t, elapsed < 6 * time.Second, "a crashed Brew must not pin the server")
}

@(test)
test_server_exits_when_its_repository_directory_is_gone :: proc(t: ^testing.T) {
	root := make_test_state_directory(t)
	defer remove_test_state_directory(root)
	gone := fmt.tprintf("%s/deleted-repo", root)
	idle_fixture_brew(t, root, gone, true)
	testing.expect(t, !repository_has_active_brew(root, gone), "a deleted repository must not block")
	code, elapsed := idle_run(root, gone)
	testing.expect_value(t, code, 0)
	testing.expect(t, elapsed < 6 * time.Second, "a missing repository must not pin the server")
}

@(test)
test_live_brew_blocks_and_is_named :: proc(t: ^testing.T) {
	root := make_test_state_directory(t)
	defer remove_test_state_directory(root)
	idle_fixture_brew(t, root, root, true)
	brew_id, reason := blocking_brew(root, root)
	defer delete(brew_id)
	testing.expect_value(t, brew_id, "brew-test")
	testing.expect(t, reason != "", "the blocker must carry a reason")
}
