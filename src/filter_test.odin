package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_filter_reviews_and_runs_discovered_checks_once_and_reuses_evidence :: proc(t: ^testing.T) {
	fixture := make_filter_fixture(t, "echo ok", "echo reviewed >> \"$(dirname \"$0\")/pi-calls.txt\"; echo 'No findings'")
	defer remove_fixture_root(fixture.root)

	first, err := render_collect_with_pi(fixture.state_root, fixture.brew_id, fixture.pi)
	defer delete(first.output)
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(first.output, "Review:\nNo findings"), first.output)
	// No Worker report was written for this Shot; the Oreo must say nothing about one.
	testing.expect(t, !strings.contains(first.output, "Report:"), first.output)
	testing.expect(t, strings.contains(first.output, "[unit] make test (Makefile test): passed"), first.output)

	// Collecting again must not re-run Pi or the checks, and must show the same evidence.
	second, _ := render_collect_with_pi(fixture.state_root, fixture.brew_id, fixture.pi)
	defer delete(second.output)
	calls, _ := os.read_entire_file(fmt.tprintf("%s/pi-calls.txt", fixture.root), context.allocator)
	defer delete(calls)
	testing.expect_value(t, strings.count(string(calls), "reviewed"), 1)
	testing.expect(t, strings.contains(second.output, "[unit] make test (Makefile test): passed"))
	testing.expect(t, strings.contains(second.output, "Review:\nNo findings"))
}

@(test)
test_oreo_lists_decisions_for_failed_checks_and_findings :: proc(t: ^testing.T) {
	fixture := make_filter_fixture(t, "echo broken; exit 2", "echo '- high: src/a.odin:1 leaks'")
	defer remove_fixture_root(fixture.root)

	result, err := render_collect_with_pi(fixture.state_root, fixture.brew_id, fixture.pi)
	defer delete(result.output)
	testing.expect_value(t, err, "")
	testing.expect(t, !result.complete)
	testing.expect(t, strings.contains(result.output, "[unit] make test (Makefile test): FAILED (exited with code 2)"), result.output)
	testing.expect(t, strings.contains(result.output, "broken"), "failing output tail is shown")
	testing.expect(t, strings.contains(result.output, "## Decisions for the developer"), result.output)
	testing.expect(t, strings.contains(result.output, "Shot shot-a: a check failed"), result.output)
	testing.expect(t, strings.contains(result.output, "Shot shot-a: review reported findings"), result.output)
}

@(test)
test_filter_reports_a_review_that_could_not_run_and_ambiguous_tests :: proc(t: ^testing.T) {
	fixture := make_filter_fixture(t, "echo ok", "exit 2")
	defer remove_fixture_root(fixture.root)
	// A second test source makes the unit command ambiguous: nothing may be guessed or run.
	_ = os.write_entire_file(fmt.tprintf("%s/station/go.mod", fixture.root), "module x\n", os.Permissions{.Read_User, .Write_User})

	result, err := render_collect_with_pi(fixture.state_root, fixture.brew_id, fixture.pi)
	defer delete(result.output)
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(result.output, "Not performed: Pi exited with code 2"), result.output)
	testing.expect(t, strings.contains(result.output, "ambiguous unit test commands"), result.output)
	testing.expect(t, !strings.contains(result.output, "[unit]"), "no command may run when ambiguous")
	testing.expect(t, strings.contains(result.output, "Shot shot-a: review was not performed"), result.output)
	testing.expect(t, strings.contains(result.output, "Shot shot-a: ambiguous unit test commands"), result.output)
}

Filter_Fixture :: struct {
	root, state_root, brew_id, pi: string,
}

// A completed Shot whose Station has a standards.md, an uncommitted change, and a
// Makefile test target; Pi is a shell script printing what the caller supplies.
make_filter_fixture :: proc(t: ^testing.T, make_test_body, pi_body: string) -> Filter_Fixture {
	root := make_fixture_root(t)
	station := fmt.tprintf("%s/station", root)
	make_fixture_repo(t, station)
	rw := os.Permissions{.Read_User, .Write_User}
	_ = os.write_entire_file(fmt.tprintf("%s/standards.md", station), "# Standards\n", rw)
	_ = os.write_entire_file(fmt.tprintf("%s/Makefile", station), fmt.tprintf("test:\n\t%s\n", make_test_body), rw)
	for args in ([][]string{{"git", "-C", station, "add", "."}, {"git", "-C", station, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "base"}}) {
		_, out, errout, _ := os.process_exec(os.Process_Desc{command = args}, context.allocator)
		delete(out)
		delete(errout)
	}
	_, head, head_stderr, _ := os.process_exec(os.Process_Desc{command = []string{"git", "-C", station, "rev-parse", "HEAD"}}, context.allocator)
	base := strings.clone(strings.trim_space(string(head)))
	delete(head)
	delete(head_stderr)
	_ = os.write_entire_file(fmt.tprintf("%s/new.txt", station), "change\n", rw)

	pi := fmt.tprintf("%s/pi", root)
	_ = os.write_entire_file(pi, fmt.tprintf("#!/bin/sh\n%s\n", pi_body), os.Permissions{.Read_User, .Write_User, .Execute_User})

	state_root := fmt.tprintf("%s/state", root)
	brew_id := "brew-test"
	register := make_test_register(t)
	defer destroy_register(&register)
	register.base_commit = base
	brew_dir := fmt.tprintf("%s/%s", state_root, brew_id)
	_ = create_state(brew_dir, &register)
	register.shots[0].station_path = strings.clone(station)
	_ = save_register_metadata(brew_dir, register)
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_RUNNING, "Worker started")
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_COMPLETED, "Pi exited with code 0")
	return Filter_Fixture{root = root, state_root = state_root, brew_id = brew_id, pi = pi}
}

@(test)
test_filter_saves_evidence_for_every_completed_shot :: proc(t: ^testing.T) {
	fixture := make_filter_fixture(t, "echo ok", "echo 'No findings'")
	defer remove_fixture_root(fixture.root)
	// Complete the second Shot too; the shared filter/ directory already exists by then.
	brew_dir := fmt.tprintf("%s/%s", fixture.state_root, fixture.brew_id)
	register, _ := read_state(brew_dir)
	defer destroy_register(&register)
	register.shots[1].station_path = strings.clone(fmt.tprintf("%s/station", fixture.root))
	_ = save_register_metadata(brew_dir, register)
	_ = transition_shot(brew_dir, &register, "shot-b", SHOT_RUNNING, "Worker started")
	_ = transition_shot(brew_dir, &register, "shot-b", SHOT_COMPLETED, "Pi exited with code 0")

	result, err := render_collect_with_pi(fixture.state_root, fixture.brew_id, fixture.pi)
	defer delete(result.output)
	testing.expect_value(t, err, "")
	testing.expect(t, result.complete)
	testing.expect_value(t, strings.count(result.output, "Review:\nNo findings"), 2)
	for shot_id in ([]string{"shot-a", "shot-b"}) {
		path := filter_evidence_path(brew_dir, shot_id)
		testing.expect(t, os.exists(path), path)
		delete(path)
	}
}
