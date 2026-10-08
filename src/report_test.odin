package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

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
	testing.expect_value(t, output, "Brew brew-test: running\n  shot-a  running (cancel requested)\n  shot-b  queued\n")
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
