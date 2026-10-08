package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

DEAD_IDENTITY :: Process_Identity{pid = 2147480000, start_time = 1}

@(test)
test_process_identity_distinguishes_live_reused_and_missing_processes :: proc(t: ^testing.T) {
	me, me_ok := current_identity()
	testing.expect(t, me_ok)
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
	defer destroy_struct(&register)
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_RUNNING, "Worker started")
	write_test_result(brew_dir, "shot-a", true)

	testing.expect_value(t, settle_brew(brew_dir, &register, "unused", .Observe).kind, State_Error_Kind.None)
	testing.expect_value(t, register.shots[0].status, SHOT_COMPLETED)
	testing.expect_value(t, register.shots[1].status, SHOT_QUEUED)
}

@(test)
test_v2_worker_without_completion_marker_is_incomplete :: proc(t: ^testing.T) {
	root := make_fixture_root(t); defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root); defer destroy_struct(&register)
	register.completion_marker_required = true
	_ = save_register_metadata(brew_dir, register)
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_RUNNING, "Worker started")
	path := worker_result_path(brew_dir, "shot-a"); defer delete(path)
	_ = write_worker_result(path, Worker_Result{brew_id="brew-test", shot_id="shot-a", started=true, success=true, detail="missing CS-DONE completion marker"})
	_ = settle_brew(brew_dir, &register, "unused", .Observe)
	testing.expect_value(t, register.shots[0].status, SHOT_INCOMPLETE)
	_ = transition_shot(brew_dir, &register, "shot-b", SHOT_CANCELLED, "test terminal state")
	testing.expect_value(t, brew_status(register), SHOT_INCOMPLETE)
}

@(test)
test_observe_marks_a_vanished_worker_interrupted_never_completed :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_struct(&register)
	write_test_started(brew_dir, "shot-a", DEAD_IDENTITY)

	testing.expect_value(t, settle_brew(brew_dir, &register, "unused", .Observe).kind, State_Error_Kind.None)
	testing.expect_value(t, register.shots[0].status, SHOT_INTERRUPTED)
}

race_brew_dir: string

// A Worker writes its result before it exits. This callback does the same
// between the Brew's result check and its liveness check.
finishing_worker_liveness :: proc(identity: Process_Identity) -> Liveness {
	write_test_result(race_brew_dir, "shot-a", true)
	return .Gone
}

@(test)
test_observe_keeps_a_result_written_as_the_worker_exits :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_struct(&register)
	race_brew_dir = brew_dir
	write_test_started(brew_dir, "shot-a", DEAD_IDENTITY)

	err := settle_brew(brew_dir, &register, "unused", .Observe, liveness = finishing_worker_liveness)
	testing.expect_value(t, err.kind, State_Error_Kind.None)
	// The result is evidence of completion; it must not be recorded as interrupted.
	testing.expect_value(t, register.shots[0].status, SHOT_COMPLETED)
}

@(test)
test_observe_leaves_live_workers_and_queued_shots_alone :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_struct(&register)
	write_test_started(brew_dir, "shot-a", current_identity_or_dead())

	testing.expect_value(t, settle_brew(brew_dir, &register, "unused", .Observe).kind, State_Error_Kind.None)
	testing.expect_value(t, register.shots[0].status, SHOT_RUNNING)
	testing.expect_value(t, register.shots[1].status, SHOT_QUEUED)
}

@(test)
test_cancel_stops_a_live_worker_and_cancels_queued_shots :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_struct(&register)

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
	defer destroy_struct(&reloaded)
	testing.expect_value(t, read_err.kind, State_Error_Kind.None)
	testing.expect_value(t, reloaded.shots[0].status, SHOT_CANCELLED)
}

@(test)
test_cancel_marks_a_worker_interrupted_when_its_exit_cannot_be_confirmed :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_struct(&register)
	write_test_started(brew_dir, "shot-a", current_identity_or_dead()) // never exits
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
	defer destroy_struct(&register)
	testing.expect(t, write_supervisor(brew_dir))

	for _ in 0 ..< 2 {
		output, err := cancel_brew(root, "unused", "brew-test")
		testing.expect_value(t, err, "")
		testing.expect(t, strings.contains(output, "Cancellation requested"), output)
		delete(output)
	}
	testing.expect(t, cancel_requested(brew_dir))
	reloaded, _ := read_state(brew_dir)
	defer destroy_struct(&reloaded)
	testing.expect_value(t, reloaded.event_sequence, 0)
}

@(test)
test_cancel_brew_settles_an_orphaned_brew_itself :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_struct(&register)

	output, err := cancel_brew(root, "unused", "brew-test")
	defer delete(output)
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(output, "Brew brew-test (beans): cancelled"), output)

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
	defer destroy_struct(&register)
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_RUNNING, "Worker started")
	write_test_result(brew_dir, "shot-a", true)

	testing.expect_value(t, settle_orphaned_brew(root, "unused", "brew-test"), "")
	reloaded, _ := read_state(brew_dir)
	defer destroy_struct(&reloaded)
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

// A /proc entry that cannot be read says nothing about whether the process is
// running. Only evidence of absence may say Gone.
@(test)
test_liveness_separates_gone_from_unknown :: proc(t: ^testing.T) {
	identity := Process_Identity{pid = 77, start_time = 4242}
	running := "77 (x) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 4242"
	zombie := "77 (x) Z 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 4242"
	reused := "77 (x) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 9999"
	garbage := "not a stat line"

	testing.expect_value(t, classify_proc_stat(identity, transmute([]byte)running, nil), Liveness.Alive)
	// Evidence the process is gone: a zombie, a reused PID, or no such entry.
	testing.expect_value(t, classify_proc_stat(identity, transmute([]byte)zombie, nil), Liveness.Gone)
	testing.expect_value(t, classify_proc_stat(identity, transmute([]byte)reused, nil), Liveness.Gone)
	testing.expect_value(t, classify_proc_stat(identity, nil, os.General_Error.Not_Exist), Liveness.Gone)
	// No evidence either way: any other read failure (Invalid_File stands in for a
	// platform error such as a permission problem), or text that does not parse.
	testing.expect_value(t, classify_proc_stat(identity, nil, os.General_Error.Invalid_File), Liveness.Unknown)
	testing.expect_value(t, classify_proc_stat(identity, transmute([]byte)garbage, nil), Liveness.Unknown)
}

@(test)
test_current_identity_is_recorded_only_when_it_can_be_read :: proc(t: ^testing.T) {
	identity, ok := current_identity()
	testing.expect(t, ok)
	testing.expect(t, identity.start_time != 0, "a recorded identity must carry a real start time")
	testing.expect_value(t, identity_liveness(identity), Liveness.Alive)
}

unknown_liveness :: proc(identity: Process_Identity) -> Liveness {
	return .Unknown
}

@(test)
test_observe_does_not_declare_a_worker_dead_when_liveness_is_unknown :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_struct(&register)
	// The Worker started, left no result, and its /proc entry cannot be read.
	write_test_started(brew_dir, "shot-a", DEAD_IDENTITY)

	err := settle_brew(brew_dir, &register, "unused", .Observe, liveness = unknown_liveness)
	testing.expect_value(t, err.kind, State_Error_Kind.None)
	// It must not be recorded as interrupted: nobody has shown it is gone.
	testing.expect_value(t, register.shots[0].status, SHOT_RUNNING)

	// The same Worker is interrupted when /proc does show it is gone.
	err = settle_brew(brew_dir, &register, "unused", .Observe)
	testing.expect_value(t, err.kind, State_Error_Kind.None)
	testing.expect_value(t, register.shots[0].status, SHOT_INTERRUPTED)
}

@(test)
test_cancel_never_confirms_an_exit_it_cannot_see :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_struct(&register)
	write_test_started(brew_dir, "shot-a", current_identity_or_dead())
	herdr := fmt.tprintf("%s/herdr", root)
	_ = os.write_entire_file(herdr, "#!/bin/sh\nexit 0\n", os.Permissions{.Read_User, .Write_User, .Execute_User})

	err := settle_brew(brew_dir, &register, herdr, .Cancel, 200 * time.Millisecond, unknown_liveness)
	testing.expect_value(t, err.kind, State_Error_Kind.None)
	testing.expect_value(t, register.shots[0].status, SHOT_INTERRUPTED)
}

current_identity_or_dead :: proc() -> Process_Identity {
	identity, ok := current_identity()
	return identity if ok else DEAD_IDENTITY
}

@(test)
test_supervisor_liveness_distinguishes_missing_unreadable_and_running :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_struct(&register)
	path := supervisor_path(brew_dir)
	defer delete(path)

	// No supervisor file: a Brew from before the file existed, or one that crashed early.
	testing.expect_value(t, supervisor_liveness(brew_dir), Liveness.Gone)
	// A file that cannot be understood proves nothing.
	_ = os.write_entire_file(path, "not json", os.Permissions{.Read_User, .Write_User})
	testing.expect_value(t, supervisor_liveness(brew_dir), Liveness.Unknown)
	// A real, running identity.
	testing.expect(t, write_supervisor(brew_dir))
	testing.expect_value(t, supervisor_liveness(brew_dir), Liveness.Alive)
	// An identity whose process is not there.
	testing.expect(t, write_identity_file(path, DEAD_IDENTITY))
	testing.expect_value(t, supervisor_liveness(brew_dir), Liveness.Gone)
}

@(test)
test_cancel_does_not_take_over_a_supervisor_it_cannot_confirm_is_gone :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	brew_dir, register := make_brew_fixture(t, root)
	defer destroy_struct(&register)
	path := supervisor_path(brew_dir)
	defer delete(path)
	_ = os.write_entire_file(path, "not json", os.Permissions{.Read_User, .Write_User})

	output, err := cancel_brew(root, "unused", "brew-test")
	defer delete(output)
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(output, "Cancellation requested"), output)
	// Settling here could race a supervisor that is still running, so nothing changed.
	reloaded, _ := read_state(brew_dir)
	defer destroy_struct(&reloaded)
	testing.expect_value(t, reloaded.shots[0].status, SHOT_QUEUED)
	testing.expect_value(t, reloaded.event_sequence, 0)

	// Collect likewise leaves an orphan-looking Brew alone.
	testing.expect_value(t, settle_orphaned_brew(root, "unused", "brew-test"), "")
	again, _ := read_state(brew_dir)
	defer destroy_struct(&again)
	testing.expect_value(t, again.event_sequence, 0)
}
