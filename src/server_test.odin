package main

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

	first_lock, first, first_ok := server_start(directory, id, "/work/gac", "/tmp/gac.sock")
	testing.expect(t, first_ok, "the first start must succeed")
	testing.expect_value(t, first.generation, 1)
	file_lock_release(first_lock)

	second_lock, second, second_ok := server_start(directory, id, "/work/gac", "/tmp/gac.sock")
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

	lock, record, ok := server_start(directory, id, "/work/gac", "/tmp/gac.sock")
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
