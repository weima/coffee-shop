package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// The PR and cleanup operations run against a real temporary Git repository with
// a dev worktree and a Station worktree. gh and process enumeration are
// substituted, so no GitHub remote or live Station is needed.

Pr_Fixture :: struct {
	root:       string,
	state_root: string,
	repo:       string,
	dev:        string,
	station:    string,
	run_dir:    string,
	base:       string,
	pull:       string,
}

Pr_Fake_Calls :: struct {
	gh:    [dynamic]string,
}

pr_fake_calls: Pr_Fake_Calls
pr_fake_processes: [dynamic]Process_Command
// The test runner runs tests on several threads, and these fakes are shared, so
// one test holds the lock for its whole duration.
pr_test_lock: sync.Mutex

pr_test_shell :: proc(script: string, args: ..string) -> bool {
	command := make([dynamic]string, 0, len(args)+3, context.temp_allocator)
	append(&command, "sh", "-c", script, "pr-test")
	append(&command, ..args)
	state, _, _, err := os.process_exec(os.Process_Desc{command = command[:]}, context.temp_allocator)
	return err == nil && state.success
}

pr_test_rev :: proc(t: ^testing.T, dir, ref: string) -> string {
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = {"git", "-C", dir, "rev-parse", ref}}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect(t, err == nil && state.success)
	return strings.clone(strings.trim_space(string(stdout)), context.temp_allocator)
}

pr_test_write_history :: proc(t: ^testing.T, run_dir, text: string) {
	if !os.is_directory(run_dir) {
		testing.expect_value(t, os.make_directory_all(run_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	}
	path := fmt.tprintf("%s/%s", run_dir, HOST_HISTORY_FILE_NAME)
	testing.expect_value(t, os.write_entire_file(path, text, os.Permissions{.Read_User, .Write_User}), os.Error(nil))
}

make_pr_fixture :: proc(t: ^testing.T, run_id, shot_id, branch: string) -> Pr_Fixture {
	fx: Pr_Fixture
	fx.root = make_fixture_root(t)
	fx.repo = fmt.tprintf("%s/beans", fx.root)
	fx.dev = fmt.tprintf("%s/dev", fx.root)
	fx.state_root = fmt.tprintf("%s/state", fx.root)
	fx.run_dir = fmt.tprintf("%s/host/%s", fx.state_root, run_id)
	fx.station = fmt.tprintf("%s/stations/%s", fx.run_dir, shot_id)
	ok := pr_test_shell(`
		set -e
		git init -q "$1"
		git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
		git init -q --bare "$1-remote"
		git -C "$1" remote add origin "$1-remote"
		git -C "$1" worktree add -q -b "$2" "$3"
		printf base > "$3/base.txt"
		git -C "$3" add -A
		git -C "$3" -c user.email=t@t -c user.name=t commit -q -m base
		mkdir -p "$(dirname "$4")"
		git -C "$3" worktree add -q -b "cs-host-$5-$6" "$4" HEAD
		printf pull > "$4/pull.txt"
		git -C "$4" add -A
		git -C "$4" -c user.email=t@t -c user.name=t commit -q -m pull
	`, fx.repo, branch, fx.dev, fx.station, run_id, shot_id)
	testing.expect(t, ok)
	fx.base = pr_test_rev(t, fx.dev, "HEAD")
	fx.pull = pr_test_rev(t, fx.station, "HEAD")
	pr_test_write_history(t, fx.run_dir, pr_test_happy_history(run_id, shot_id, fx.pull))
	return fx
}

pr_test_happy_history :: proc(run_id, shot_id, pull: string) -> string {
	short := pull[:8]
	return fmt.tprintf(
		`{{"type":"session_started","request_id":"%s","shot_id":"%s","pane_id":"w1:p1"}}` + "\n" +
		`{{"type":"station_report","request_id":"%s","shot_id":"%s","kind":"agent_exited","description":"Agent exited"}}` + "\n" +
		`{{"type":"station_report","request_id":"%s","shot_id":"%s","kind":"taste_passed","description":"Taste passed"}}` + "\n" +
		`{{"type":"station_report","request_id":"%s","shot_id":"%s","kind":"pulled","description":"%s"}}` + "\n",
		run_id, shot_id, run_id, shot_id, run_id, shot_id, run_id, shot_id, short)
}

pr_test_two_pull_history :: proc(run_id, shot_a, pull_a, shot_b, pull_b: string) -> string {
	return fmt.tprintf(
		`{{"type":"session_started","request_id":"%s","shot_id":"%s","pane_id":"w1:p1"}}` + "\n" +
		`{{"type":"station_report","request_id":"%s","shot_id":"%s","kind":"agent_exited","description":"Agent exited"}}` + "\n" +
		`{{"type":"station_report","request_id":"%s","shot_id":"%s","kind":"pulled","description":"%s"}}` + "\n" +
		`{{"type":"session_started","request_id":"%s","shot_id":"%s","pane_id":"w1:p2"}}` + "\n" +
		`{{"type":"station_report","request_id":"%s","shot_id":"%s","kind":"agent_exited","description":"Agent exited"}}` + "\n" +
		`{{"type":"station_report","request_id":"%s","shot_id":"%s","kind":"pulled","description":"%s"}}` + "\n",
		run_id, shot_a, run_id, shot_a, run_id, shot_a, pull_a[:8],
		run_id, shot_b, run_id, shot_b, run_id, shot_b, pull_b[:8])
}

// The fixture's path strings are temporary, so only the root is freed.
destroy_pr_fixture :: proc(fx: ^Pr_Fixture) {
	remove_fixture_root(fx.root)
}

fake_pr_gh :: proc(directory: string, args: []string) -> (out, detail: string, ok: bool) {
	line := strings.join(args, " ", context.temp_allocator)
	append(&pr_fake_calls.gh, strings.clone(line))
	return "https://example.test/pr/1", "", true
}

fake_pr_processes :: proc() -> []Process_Command {
	return pr_fake_processes[:]
}

pr_test_backend :: proc() -> Pr_Backend {
	backend := default_pr_backend()
	backend.gh = fake_pr_gh
	backend.processes = fake_pr_processes
	return backend
}

pr_test_begin :: proc() {
	sync.mutex_lock(&pr_test_lock)
	pr_fake_calls = {}
	pr_fake_calls.gh = make([dynamic]string, 0, 4)
	pr_fake_processes = make([dynamic]Process_Command, 0, 2)
}

pr_test_end :: proc() {
	for line in pr_fake_calls.gh {
		delete(line)
	}
	delete(pr_fake_calls.gh)
	delete(pr_fake_processes)
	sync.mutex_unlock(&pr_test_lock)
}

pr_test_calls_contain :: proc(calls: []string, needle: string) -> bool {
	for line in calls {
		if strings.contains(line, needle) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// CLI parsing

@(test)
test_parse_pr_arguments :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"pr", "run-1", "shot-a", "--branch", "feat-x"})
	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Pr)
	testing.expect_value(t, parsed.run_id, "run-1")
	testing.expect_value(t, parsed.shot_id, "shot-a")
	testing.expect_value(t, parsed.branch, "feat-x")
}

@(test)
test_parse_cleanup_argument :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"cleanup", "run-1"})
	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Cleanup)
	testing.expect_value(t, parsed.run_id, "run-1")
}

@(test)
test_rejects_pr_without_a_shot :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"pr", "run-1"})
	testing.expect(t, err != "")
}

// ---------------------------------------------------------------------------
// pr

@(test)
test_pr_fast_forwards_pushes_and_opens_the_pr :: proc(t: ^testing.T) {
	pr_test_begin()
	defer pr_test_end()
	fx := make_pr_fixture(t, "run-1", "shot-a", "feat-x")
	defer destroy_pr_fixture(&fx)

	output, err := pr_operation(fx.state_root, "run-1", "shot-a", "feat-x", "", "", false, pr_test_backend())
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(output, "https://example.test/pr/1"), output)
	testing.expect(t, strings.contains(output, "Waiting on the developer"), output)

	testing.expect_value(t, pr_test_rev(t, fx.dev, "HEAD"), fx.pull)
	testing.expect(t, pr_test_calls_contain(pr_fake_calls.gh[:], "pr create --head feat-x --fill"), fmt.tprintf("%v", pr_fake_calls.gh))
	testing.expect(t, pr_test_calls_contain(pr_fake_calls.gh[:], "https://example.test/pr/1") || len(pr_fake_calls.gh) > 0)

	record_path := fmt.tprintf("%s/pr/shot-a.json", fx.run_dir)
	testing.expect(t, os.exists(record_path), record_path)
}

@(test)
test_pr_requires_explicit_branch_without_workspace_discovery :: proc(t: ^testing.T) {
	pr_test_begin()
	defer pr_test_end()
	fx := make_pr_fixture(t, "run-1", "shot-a", "feat-x")
	defer destroy_pr_fixture(&fx)

	_, err := pr_operation(fx.state_root, "run-1", "shot-a", "", "", "", false, pr_test_backend())
	testing.expect_value(t, err, "branch must be explicit; pass --branch")
	testing.expect_value(t, pr_test_rev(t, fx.dev, "HEAD"), fx.base)
	testing.expect_value(t, len(pr_fake_calls.gh), 0)
}

@(test)
test_pr_refuses_without_a_terminal_state :: proc(t: ^testing.T) {
	pr_test_begin()
	defer pr_test_end()
	fx := make_pr_fixture(t, "run-1", "shot-a", "feat-x")
	defer destroy_pr_fixture(&fx)
	pr_test_write_history(t, fx.run_dir,
		`{"type":"session_started","request_id":"run-1","shot_id":"shot-a","pane_id":"w1:p1"}` + "\n" +
		`{"type":"station_report","request_id":"run-1","shot_id":"shot-a","kind":"taste_passed","description":"Taste passed"}` + "\n")

	_, err := pr_operation(fx.state_root, "run-1", "shot-a", "feat-x", "", "", false, pr_test_backend())
	testing.expect(t, strings.contains(err, "no terminal state"), err)
	testing.expect_value(t, len(pr_fake_calls.gh), 0)
	testing.expect_value(t, pr_test_rev(t, fx.dev, "HEAD"), fx.base)
}

@(test)
test_pr_refuses_a_failed_taste :: proc(t: ^testing.T) {
	pr_test_begin()
	defer pr_test_end()
	fx := make_pr_fixture(t, "run-1", "shot-a", "feat-x")
	defer destroy_pr_fixture(&fx)
	pr_test_write_history(t, fx.run_dir,
		`{"type":"station_report","request_id":"run-1","shot_id":"shot-a","kind":"agent_exited","description":"Agent exited"}` + "\n" +
		`{"type":"station_report","request_id":"run-1","shot_id":"shot-a","kind":"taste_failed","description":"Taste exited with code 1"}` + "\n")

	_, err := pr_operation(fx.state_root, "run-1", "shot-a", "feat-x", "", "", false, pr_test_backend())
	testing.expect(t, strings.contains(err, "did not pass Taste"), err)
	testing.expect_value(t, len(pr_fake_calls.gh), 0)
	testing.expect_value(t, pr_test_rev(t, fx.dev, "HEAD"), fx.base)
}

@(test)
test_pr_refuses_without_taste_evidence :: proc(t: ^testing.T) {
	pr_test_begin()
	defer pr_test_end()
	fx := make_pr_fixture(t, "run-1", "shot-a", "feat-x")
	defer destroy_pr_fixture(&fx)
	pr_test_write_history(t, fx.run_dir,
		`{"type":"station_report","request_id":"run-1","shot_id":"shot-a","kind":"agent_exited","description":"Agent exited"}` + "\n")

	_, err := pr_operation(fx.state_root, "run-1", "shot-a", "feat-x", "", "", false, pr_test_backend())
	testing.expect(t, strings.contains(err, "no recorded Taste evidence"), err)
	testing.expect_value(t, len(pr_fake_calls.gh), 0)
	testing.expect_value(t, pr_test_rev(t, fx.dev, "HEAD"), fx.base)
}

@(test)
test_pr_refuses_a_taste_pass_with_no_commit :: proc(t: ^testing.T) {
	pr_test_begin()
	defer pr_test_end()
	fx := make_pr_fixture(t, "run-1", "shot-a", "feat-x")
	defer destroy_pr_fixture(&fx)
	pr_test_write_history(t, fx.run_dir,
		`{"type":"station_report","request_id":"run-1","shot_id":"shot-a","kind":"agent_exited","description":"Agent exited"}` + "\n" +
		`{"type":"station_report","request_id":"run-1","shot_id":"shot-a","kind":"taste_passed","description":"Taste passed with no changes"}` + "\n")

	_, err := pr_operation(fx.state_root, "run-1", "shot-a", "feat-x", "", "", false, pr_test_backend())
	testing.expect(t, strings.contains(err, "nothing to turn into a PR"), err)
	testing.expect_value(t, len(pr_fake_calls.gh), 0)
	testing.expect_value(t, pr_test_rev(t, fx.dev, "HEAD"), fx.base)
}

@(test)
test_pr_refuses_a_non_fast_forward :: proc(t: ^testing.T) {
	pr_test_begin()
	defer pr_test_end()
	fx := make_pr_fixture(t, "run-1", "shot-a", "feat-x")
	defer destroy_pr_fixture(&fx)
	// Diverge the dev branch after the Pull branched, so it cannot fast-forward.
	ok := pr_test_shell(`
		set -e
		printf other > "$1/other.txt"
		git -C "$1" add -A
		git -C "$1" -c user.email=t@t -c user.name=t commit -q -m other
	`, fx.dev)
	testing.expect(t, ok)
	diverged := pr_test_rev(t, fx.dev, "HEAD")
	testing.expect(t, diverged != fx.pull)

	_, err := pr_operation(fx.state_root, "run-1", "shot-a", "feat-x", "", "", false, pr_test_backend())
	testing.expect(t, strings.contains(err, "refusing to force"), err)
	testing.expect_value(t, pr_test_rev(t, fx.dev, "HEAD"), diverged)
	testing.expect_value(t, len(pr_fake_calls.gh), 0)
}

@(test)
test_pr_refuses_to_blend_a_single_pull :: proc(t: ^testing.T) {
	pr_test_begin()
	defer pr_test_end()
	fx := make_pr_fixture(t, "run-1", "shot-a", "feat-x")
	defer destroy_pr_fixture(&fx)

	_, err := pr_operation(fx.state_root, "run-1", "shot-a", "feat-x", "", "one commit", true, pr_test_backend())
	testing.expect(t, strings.contains(err, "single Pull never needs Blend"), err)
	testing.expect_value(t, pr_test_rev(t, fx.dev, "HEAD"), fx.base)
	testing.expect_value(t, len(pr_fake_calls.gh), 0)
}

@(test)
test_pr_blends_two_pulls_into_one_commit :: proc(t: ^testing.T) {
	pr_test_begin()
	defer pr_test_end()
	fx := make_pr_fixture(t, "run-1", "shot-a", "feat-x")
	defer destroy_pr_fixture(&fx)
	// A second Pull branches from the same base as the first.
	station_b := fmt.tprintf("%s/stations/shot-b", fx.run_dir)
	ok := pr_test_shell(`
		set -e
		mkdir -p "$1"
		git -C "$2" worktree add -q -b cs-host-run-1-shot-b "$1" "$3"
		printf blended > "$1/b.txt"
		git -C "$1" add -A
		git -C "$1" -c user.email=t@t -c user.name=t commit -q -m pull-b
	`, station_b, fx.dev, fx.base)
	testing.expect(t, ok)
	pull_b := pr_test_rev(t, station_b, "HEAD")
	pr_test_write_history(t, fx.run_dir, pr_test_two_pull_history("run-1", "shot-a", fx.pull, "shot-b", pull_b))

	output, err := pr_operation(fx.state_root, "run-1", "shot-a", "feat-x", "", "Blend two Pulls", true, pr_test_backend())
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(output, "https://example.test/pr/1"), output)
	blended := pr_test_rev(t, fx.dev, "HEAD")
	testing.expect(t, blended != fx.base && blended != fx.pull, "the base must move to the blended commit")
	testing.expect(t, pr_test_shell(`git -C "$1" cat-file -e "HEAD:pull.txt"`, fx.dev), "the first Pull's change must be in the blend")
	testing.expect(t, pr_test_shell(`git -C "$1" cat-file -e "HEAD:b.txt"`, fx.dev), "the second Pull's change must be in the blend")
	testing.expect(t, pr_test_calls_contain(pr_fake_calls.gh[:], "pr create --head feat-x --fill"), fmt.tprintf("%v", pr_fake_calls.gh))
}

// ---------------------------------------------------------------------------
// cleanup

@(test)
test_cleanup_refuses_while_a_station_is_working :: proc(t: ^testing.T) {
	pr_test_begin()
	defer pr_test_end()
	fx := make_pr_fixture(t, "run-1", "shot-a", "feat-x")
	defer destroy_pr_fixture(&fx)
	append(&pr_fake_processes, Process_Command{pid = 4242, args = []string{"temp-binary", "station", "--brew", "run-1", "--station", "shot-a"}})

	_, err := cleanup_operation(fx.state_root, "run-1", "", pr_test_backend())
	testing.expect(t, strings.contains(err, "Refusing to clean run run-1"), err)
	testing.expect(t, strings.contains(err, "shot-a"), err)
	testing.expect(t, strings.contains(err, "4242"), err)
	testing.expect(t, os.is_directory(fx.station), "the Station worktree must be kept")
	testing.expect(t, os.is_directory(fx.dev), "the base worktree must be kept")
}

@(test)
test_cleanup_removes_the_run_and_keeps_the_rest :: proc(t: ^testing.T) {
	pr_test_begin()
	defer pr_test_end()
	fx := make_pr_fixture(t, "run-1", "shot-a", "feat-x")
	defer destroy_pr_fixture(&fx)
	// An unrelated worktree must survive the cleanup.
	other := fmt.tprintf("%s/other", fx.root)
	ok := pr_test_shell(`set -e; git -C "$1" worktree add -q -b other "$2" HEAD`, fx.dev, other)
	testing.expect(t, ok)
	testing.expect_value(t, write_pr_record(fx.run_dir, Pr_Record{shot_id = "shot-a", branch = "feat-x", worktree = fx.dev, commit = fx.pull}), "")

	output, err := cleanup_operation(fx.state_root, "run-1", "", pr_test_backend())
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(output, "Cleaned run run-1"), output)
	testing.expect(t, !os.exists(fx.station), "the Station worktree must be removed")
	testing.expect(t, !os.exists(fx.dev), "the base worktree must be removed")
	testing.expect(t, os.is_directory(other), "an unrelated worktree must be kept")
	testing.expect(t, os.exists(fmt.tprintf("%s/%s", fx.run_dir, HOST_HISTORY_FILE_NAME)), "run state must be kept")
}

// ---------------------------------------------------------------------------
// Live-Station detection

@(test)
test_live_station_detection_uses_the_brew_argument :: proc(t: ^testing.T) {
	commands := []Process_Command{
		{pid = 1, args = []string{"/tmp/odin-run-temp-binary", "station", "--brew", "run-7", "--station", "shot-z"}},
		{pid = 2, args = []string{"/tmp/odin-run-temp-binary", "station", "--brew", "other-run", "--station", "shot-q"}},
		{pid = 3, args = []string{"coffee-shop", "cleanup", "run-7"}},
	}
	live := live_stations(commands, "run-7")
	testing.expect_value(t, len(live), 1)
	testing.expect_value(t, live[0].pid, 1)
	testing.expect_value(t, live[0].shot_id, "shot-z")
}

@(test)
test_live_station_detection_finds_a_real_process_by_argv :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	script := fmt.tprintf("%s/temp-binary", root)
	testing.expect_value(t, os.write_entire_file(script, "#!/bin/sh\nsleep 30\n", os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))

	process, start_err := os.process_start(os.Process_Desc{command = {script, "station", "--brew", "run-9", "--station", "shot-z"}})
	testing.expect_value(t, start_err, os.Error(nil))
	defer {
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
	}
	time.sleep(300 * time.Millisecond)

	live := live_stations(default_process_commands(), "run-9")
	found := false
	for station in live {
		if station.shot_id == "shot-z" {
			found = true
		}
	}
	testing.expect(t, found, fmt.tprintf("live Stations: %v", live))
}
