package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_brew_status_reports_the_least_finished_or_worst_outcome :: proc(t: ^testing.T) {
	cases := []struct{ statuses: [2]string, want: string }{
		{{SHOT_QUEUED, SHOT_QUEUED}, SHOT_QUEUED},
		{{SHOT_COMPLETED, SHOT_QUEUED}, SHOT_RUNNING},
		{{SHOT_RUNNING, SHOT_FAILED}, SHOT_RUNNING},
		{{SHOT_COMPLETED, SHOT_COMPLETED}, SHOT_COMPLETED},
		{{SHOT_COMPLETED, SHOT_FAILED}, SHOT_FAILED},
		{{SHOT_CANCELLED, SHOT_INTERRUPTED}, SHOT_INTERRUPTED},
		{{SHOT_COMPLETED, SHOT_CANCELLED}, SHOT_CANCELLED},
	}
	for c in cases {
		register := make_test_register(t)
		defer destroy_register(&register)
		for status, index in c.statuses {
			delete(register.shots[index].status)
			register.shots[index].status = strings.clone(status)
		}
		testing.expect_value(t, brew_status(register), c.want)
	}
}

@(test)
test_status_and_collect_reject_bad_or_unknown_brews :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)

	_, err := render_status(root, "../escape")
	testing.expect_value(t, err, "Brew ID is invalid")
	_, err = render_status(root, "brew-missing")
	testing.expect_value(t, err, "no Brew named brew-missing")
}

@(test)
test_status_lists_each_shot_and_pending_cancellation :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	register := make_test_register(t)
	defer destroy_register(&register)
	brew_dir := fmt.tprintf("%s/brew-test", root)
	_ = create_state(brew_dir, &register)
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_RUNNING, "Worker started")
	_ = request_shot_cancel(brew_dir, &register, "shot-a", "user requested cancellation")

	output, err := render_status(root, "brew-test")
	defer delete(output)
	testing.expect_value(t, err, "")
	testing.expect_value(t, output, "Brew brew-test: running\n  shot-a  running (cancel requested)\n  shot-b  queued\nSupervisor is not running; `collect` or `cancel` will settle unfinished Shots.\n")
}

@(test)
test_status_shows_runtime_latest_activity_and_quiet_marker :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	register := make_test_register(t)
	defer destroy_register(&register)
	brew_dir := fmt.tprintf("%s/brew-test", root)
	_ = create_state(brew_dir, &register)
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_RUNNING, "Worker started")
	workers_dir := state_file_path(brew_dir, "workers")
	defer delete(workers_dir)
	_ = os.make_directory_all(workers_dir, os.Permissions{.Read_User, .Write_User, .Execute_User})

	now_ns := time.now()._nsec
	_ = write_worker_started_at(brew_dir, "shot-a", now_ns-3_661_000_000_000)
	message := Activity_Message{
		brew_id = "brew-test", shot_id = "shot-a", kind = "tool_start",
		description = "Running tool: read", timestamp_ns = now_ns-780_000_000_000,
	}
	_ = write_activity_record(brew_dir, message)

	output, err := render_status(root, "brew-test")
	defer delete(output)
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(output, "1h01m elapsed"), output)
	testing.expect(t, strings.contains(output, "quiet; last activity 13m00s ago"), output)
	testing.expect(t, strings.contains(output, "Running tool: read"), output)
}

@(test)
test_collect_includes_report_changes_and_failure_detail_and_flags_incomplete :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	station := fmt.tprintf("%s/station", root)
	make_fixture_repo(t, station)
	_ = os.write_entire_file(fmt.tprintf("%s/new.txt", station), "x", os.Permissions{.Read_User, .Write_User})

	register := make_test_register(t)
	defer destroy_register(&register)
	brew_dir := fmt.tprintf("%s/brew-test", root)
	_ = create_state(brew_dir, &register)
	register.shots[0].station_path = strings.clone(station)
	_ = save_register_metadata(brew_dir, register)
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_RUNNING, "Worker started")
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_COMPLETED, "Pi exited with code 0")
	_ = transition_shot(brew_dir, &register, "shot-b", SHOT_FAILED, "Herdr tab launch failed")
	_ = os.make_directory_all(fmt.tprintf("%s/reports", brew_dir))
	_ = write_shot_output(brew_dir, "shot-a", transmute([]byte)string("All done"), nil)

	output, complete, err := render_collect(root, "brew-test")
	defer delete(output)
	testing.expect_value(t, err, "")
	testing.expect(t, !complete, "a failed Shot makes the Brew incomplete")
	testing.expect(t, strings.contains(output, "## Shot shot-a: completed"))
	testing.expect(t, strings.contains(output, "?? new.txt"))
	testing.expect(t, strings.contains(output, "All done"))
	testing.expect(t, strings.contains(output, "## Shot shot-b: failed\nDetail: Herdr tab launch failed"))
}

@(test)
test_collect_reports_missing_station_changes_for_completed_shot :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	register := make_test_register(t)
	defer destroy_register(&register)
	brew_dir := fmt.tprintf("%s/brew-test", root)
	_ = create_state(brew_dir, &register)
	register.shots[0].station_path = strings.clone(fmt.tprintf("%s/missing-station", root))
	_ = save_register_metadata(brew_dir, register)
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_RUNNING, "Worker started")
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_COMPLETED, "Pi exited with code 0")
	_ = transition_shot(brew_dir, &register, "shot-b", SHOT_RUNNING, "Worker started")
	_ = transition_shot(brew_dir, &register, "shot-b", SHOT_COMPLETED, "Pi exited with code 0")

	output, complete, err := render_collect(root, "brew-test")
	defer delete(output)
	testing.expect_value(t, err, "")
	testing.expect(t, complete, "a completed Shot keeps the Brew complete")
	testing.expect(t, strings.contains(output, "## Shot shot-a: completed"), "the completed Shot is reported")
	testing.expect(t, strings.contains(output, "(could not read Station changes)"), "missing Station changes are reported as unreadable")
	testing.expect(t, !strings.contains(output, "Changes:\n(none)"), "a missing Station is not reported as having no changes")
}

@(test)
test_launch_failure_is_reported_only_when_no_worker_ever_started :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)

	// Every Shot failed before any Worker started: that is a launch failure.
	nothing := make_test_register(t)
	defer destroy_register(&nothing)
	nothing_dir := fmt.tprintf("%s/brew-nothing", root)
	_ = create_state(nothing_dir, &nothing)
	_ = transition_shot(nothing_dir, &nothing, "shot-a", SHOT_FAILED, "Herdr workspace launch failed: no server")
	_ = transition_shot(nothing_dir, &nothing, "shot-b", SHOT_FAILED, "Herdr workspace launch failed: no server")
	testing.expect_value(t, brew_launch_failure(root, "brew-nothing"), "no Shot could be launched (Herdr workspace launch failed: no server)")

	// One Worker started and failed: an ordinary Worker failure, not a launch failure.
	ran := make_test_register(t)
	defer destroy_register(&ran)
	ran_dir := fmt.tprintf("%s/brew-ran", root)
	_ = create_state(ran_dir, &ran)
	_ = transition_shot(ran_dir, &ran, "shot-a", SHOT_RUNNING, "Worker started")
	_ = transition_shot(ran_dir, &ran, "shot-a", SHOT_FAILED, "Pi exited with code 3")
	_ = transition_shot(ran_dir, &ran, "shot-b", SHOT_FAILED, "Herdr tab launch failed")
	testing.expect_value(t, brew_launch_failure(root, "brew-ran"), "")

	// Cancelled before anything started is the user's choice, not a failure.
	cancelled := make_test_register(t)
	defer destroy_register(&cancelled)
	cancelled_dir := fmt.tprintf("%s/brew-cancelled", root)
	_ = create_state(cancelled_dir, &cancelled)
	_ = transition_shot(cancelled_dir, &cancelled, "shot-a", SHOT_CANCELLED, "Brew cancelled before the Worker started")
	_ = transition_shot(cancelled_dir, &cancelled, "shot-b", SHOT_CANCELLED, "Brew cancelled before the Worker started")
	testing.expect_value(t, brew_launch_failure(root, "brew-cancelled"), "")
}
