package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

DEAD_IDENTITY :: Process_Identity{pid = 2147480000, start_time = 1}

@(test)
test_process_identity_distinguishes_live_reused_and_missing_processes :: proc(t: ^testing.T) {
	me := current_identity()
	testing.expect(t, me.start_time != 0)
	testing.expect(t, identity_alive(me))
	testing.expect(t, !identity_alive(Process_Identity{pid = me.pid, start_time = me.start_time + 1}), "a reused PID has a different start time")
	testing.expect(t, !identity_alive(DEAD_IDENTITY))
}

@(test)
test_observe_records_a_finished_workers_result :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_register(&register)
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_RUNNING, "Worker started")
	write_test_result(brew_dir, "shot-a", true)

	testing.expect_value(t, settle_brew(brew_dir, &register, "unused", .Observe).kind, State_Error_Kind.None)
	testing.expect_value(t, register.shots[0].status, SHOT_COMPLETED)
	testing.expect_value(t, register.shots[1].status, SHOT_QUEUED)
}

@(test)
test_observe_marks_a_vanished_worker_interrupted_never_completed :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_register(&register)
	write_test_started(brew_dir, "shot-a", DEAD_IDENTITY)

	testing.expect_value(t, settle_brew(brew_dir, &register, "unused", .Observe).kind, State_Error_Kind.None)
	testing.expect_value(t, register.shots[0].status, SHOT_INTERRUPTED)
}

@(test)
test_observe_leaves_live_workers_and_queued_shots_alone :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_register(&register)
	write_test_started(brew_dir, "shot-a", current_identity())

	testing.expect_value(t, settle_brew(brew_dir, &register, "unused", .Observe).kind, State_Error_Kind.None)
	testing.expect_value(t, register.shots[0].status, SHOT_RUNNING)
	testing.expect_value(t, register.shots[1].status, SHOT_QUEUED)
}

@(test)
test_cancel_stops_a_live_worker_and_cancels_queued_shots :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_register(&register)

	child, start_err := os.process_start(os.Process_Desc{command = []string{"sleep", "30"}})
	testing.expect_value(t, start_err, os.Error(nil))
	defer {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child)
	}
	start_time, _ := process_start_time(child.pid)
	write_test_started(brew_dir, "shot-a", Process_Identity{pid = child.pid, start_time = start_time})
	// Stand-in for `herdr tab close`: ending the Worker is what closing a tab does.
	herdr := fmt.tprintf("%s/herdr", root)
	_ = os.write_entire_file(herdr, fmt.tprintf("#!/bin/sh\nkill %d\n", child.pid), os.Permissions{.Read_User, .Write_User, .Execute_User})

	testing.expect_value(t, settle_brew(brew_dir, &register, herdr, .Cancel).kind, State_Error_Kind.None)
	testing.expect_value(t, register.shots[0].status, SHOT_CANCELLED)
	testing.expect_value(t, register.shots[1].status, SHOT_CANCELLED)

	reloaded, read_err := read_state(brew_dir)
	defer destroy_register(&reloaded)
	testing.expect_value(t, read_err.kind, State_Error_Kind.None)
	testing.expect_value(t, reloaded.shots[0].status, SHOT_CANCELLED)
}

@(test)
test_cancel_marks_a_worker_interrupted_when_its_exit_cannot_be_confirmed :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_register(&register)
	write_test_started(brew_dir, "shot-a", current_identity()) // never exits
	herdr := fmt.tprintf("%s/herdr", root)
	_ = os.write_entire_file(herdr, "#!/bin/sh\nexit 0\n", os.Permissions{.Read_User, .Write_User, .Execute_User})

	testing.expect_value(t, settle_brew(brew_dir, &register, herdr, .Cancel, 200 * time.Millisecond).kind, State_Error_Kind.None)
	testing.expect_value(t, register.shots[0].status, SHOT_INTERRUPTED)
}

@(test)
test_cancel_brew_hands_off_to_a_live_supervisor_and_is_repeatable :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_register(&register)
	testing.expect(t, write_supervisor(brew_dir))

	for _ in 0 ..< 2 {
		output, err := cancel_brew(root, "unused", "brew-test")
		testing.expect_value(t, err, "")
		testing.expect(t, strings.contains(output, "Cancellation requested"), output)
		delete(output)
	}
	testing.expect(t, cancel_requested(brew_dir))
	reloaded, _ := read_state(brew_dir)
	defer destroy_register(&reloaded)
	testing.expect_value(t, reloaded.event_sequence, 0)
}

@(test)
test_cancel_brew_settles_an_orphaned_brew_itself :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_register(&register)

	output, err := cancel_brew(root, "unused", "brew-test")
	defer delete(output)
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(output, "Brew brew-test: cancelled"), output)

	again, again_err := cancel_brew(root, "unused", "brew-test")
	defer delete(again)
	testing.expect_value(t, again_err, "")
	testing.expect(t, strings.contains(again, "already finished: cancelled"), again)
}

@(test)
test_settle_orphaned_brew_records_results_before_collect :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_register(&register)
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_RUNNING, "Worker started")
	write_test_result(brew_dir, "shot-a", true)

	testing.expect_value(t, settle_orphaned_brew(root, "unused", "brew-test"), "")
	reloaded, _ := read_state(brew_dir)
	defer destroy_register(&reloaded)
	testing.expect_value(t, reloaded.shots[0].status, SHOT_COMPLETED)
	testing.expect_value(t, reloaded.shots[1].status, SHOT_QUEUED)
}

make_brew_fixture :: proc(t: ^testing.T, root: string) -> (brew_dir: string, register: Register) {
	brew_dir = fmt.tprintf("%s/brew-test", root)
	register = make_test_register(t)
	testing.expect_value(t, create_state(brew_dir, &register).kind, State_Error_Kind.None)
	for name in ([]string{"workers", "results", "reports"}) {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", brew_dir, name))
	}
	register.shots[0].herdr_tab_id = strings.clone("t1")
	testing.expect_value(t, save_register_metadata(brew_dir, register).kind, State_Error_Kind.None)
	return
}

write_test_started :: proc(brew_dir, shot_id: string, identity: Process_Identity) {
	path := worker_started_path(brew_dir, shot_id)
	defer delete(path)
	_ = write_identity_file(path, identity)
}

write_test_result :: proc(brew_dir, shot_id: string, success: bool) {
	path := worker_result_path(brew_dir, shot_id)
	defer delete(path)
	_ = write_worker_result(path, Worker_Result{brew_id = "brew-test", shot_id = shot_id, started = true, success = success, detail = "Pi exited with code 0"})
}
