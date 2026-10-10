package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
test_completion_marker_is_removed_and_missing_marker_is_incomplete :: proc(t: ^testing.T) {
	marker, report := completion_marker("finished\nCS-DONE")
	defer delete(marker); defer delete(report)
	testing.expect_value(t, marker, "CS-DONE")
	testing.expect_value(t, report, "finished")
	blocked, blocked_report := completion_marker("stuck\nCS-BLOCKED: needs access")
	defer delete(blocked); defer delete(blocked_report)
	testing.expect_value(t, blocked, "CS-BLOCKED: needs access")
	missing, missing_report := completion_marker("still working")
	defer delete(missing); defer delete(missing_report)
	testing.expect(t, strings.contains(missing, "missing"))
}

@(test)
test_worker_command_quotes_paths_and_contains_only_ids :: proc(t: ^testing.T) {
	command, err := worker_command("/tmp/it's here/coffee-shop", "/tmp/my state", "brew-1-0", "shot-a", "abc123")
	defer delete(command)
	testing.expect_value(t, err, "")
	testing.expect_value(t, command, `'/tmp/it'\''s here/coffee-shop' __worker --state-root '/tmp/my state' --brew-id brew-1-0 --shot-id shot-a --token 'abc123'`)
}

@(test)
test_brew_fails_every_shot_when_herdr_is_unavailable :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	repo := fmt.tprintf("%s/repo", root)
	make_fixture_repo(t, repo)
	recipe_path := fmt.tprintf("%s/recipe.json", root)
	_ = os.write_entire_file(recipe_path, `{"order":"o","shots":[{"id":"a","prompt":"pa"},{"id":"b","prompt":"pb"}]}`, os.Permissions{.Read_User, .Write_User})
	state_root := fmt.tprintf("%s/state", root)

	brew_id, err := run_brew_with(repo, recipe_path, state_root, "/nonexistent/coffee-shop", "/nonexistent/herdr")
	defer delete(brew_id)
	testing.expect_value(t, err, "")

	register, state_err := read_state(fmt.tprintf("%s/%s", state_root, brew_id))
	defer destroy_struct(&register)
	testing.expect_value(t, state_err.kind, State_Error_Kind.None)
	for shot in register.shots {
		testing.expect_value(t, shot.status, SHOT_FAILED)
	}
}

@(test)
test_worker_records_pi_failure_and_passes_prompt_as_one_argument :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	repo := fmt.tprintf("%s/repo", root)
	make_fixture_repo(t, repo)
	recipe_path := fmt.tprintf("%s/recipe.json", root)
	_ = os.write_entire_file(recipe_path, `{"order":"o","model":"openai/default","thinking":"medium","shots":[{"id":"a","prompt":"it's $(x)","model":"anthropic/custom","thinking":"low"}]}`, os.Permissions{.Read_User, .Write_User})
	state_root := fmt.tprintf("%s/state", root)
	// Herdr fails after Stations exist, so the Worker can be run directly.
	brew_id, _ := run_brew_with(repo, recipe_path, state_root, "/nonexistent", "/nonexistent/herdr")
	defer delete(brew_id)

	fake_pi := fmt.tprintf("%s/pi", root)
	fake_pi_script := `#!/bin/sh
for last; do :; done
printf '%s' "$last" > arg.txt
printf '%s' "$*" > argv.txt
exit 3
`
	_ = os.write_entire_file(
		fake_pi, fake_pi_script,
		os.Permissions{.Read_User, .Write_User, .Execute_User},
	)
	code := run_worker_with(state_root, brew_id, "a", "", fake_pi)
	testing.expect_value(t, code, 3)

	arg, _ := os.read_entire_file(fmt.tprintf("%s/%s/stations/a/arg.txt", state_root, brew_id), context.allocator)
	defer delete(arg)
	testing.expect(t, strings.has_prefix(string(arg), "Order: o\n\nShot: it's $(x)\n\nFinish with exactly one final line:"), string(arg))
	argv, _ := os.read_entire_file(fmt.tprintf("%s/%s/stations/a/argv.txt", state_root, brew_id), context.temp_allocator)
	defer delete(argv, context.temp_allocator)
	testing.expect(t, strings.contains(transmute(string)argv, "--model anthropic/custom") && strings.contains(transmute(string)argv, "--thinking low"), transmute(string)argv)
	testing.expect(t, strings.contains(string(arg), "CS-DONE") && strings.contains(string(arg), "CS-BLOCKED:"), string(arg))
	result_path := worker_result_path(fmt.tprintf("%s/%s", state_root, brew_id), "a")
	defer delete(result_path)
	result, result_err := read_worker_result(result_path)
	defer destroy_struct(&result)
	testing.expect_value(t, result_err, "")
	testing.expect(t, result.started && !result.success)
	testing.expect_value(t, result.exit_code, 3)
}

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
test_worker_streams_pi_json_and_preserves_final_report :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	repo := fmt.tprintf("%s/repo", root)
	make_fixture_repo(t, repo)
	recipe_path := fmt.tprintf("%s/recipe.json", root)
	_ = os.write_entire_file(recipe_path, `{
		"order":"o",
		"shots":[{"id":"a","prompt":"pa"}]
	}`, os.Permissions{.Read_User, .Write_User})
	state_root := fmt.tprintf("%s/state", root)
	brew_id, _ := run_brew_with(repo, recipe_path, state_root, "/nonexistent", "/nonexistent/herdr")
	defer delete(brew_id)
	brew_dir := fmt.tprintf("%s/%s", state_root, brew_id)

	socket_path := activity_socket_path(brew_dir)
	defer delete(socket_path)
	listener, listening := activity_listener_open(socket_path)
	testing.expect(t, listening)
	defer activity_listener_close(&listener)
	fake_pi := fmt.tprintf("%s/pi", root)
	_ = os.write_entire_file(fake_pi, `#!/bin/sh
printf '%s\n' '{"type":"turn_start"}'
printf '%s\n' '{"type":"tool_execution_start","toolName":"read","args":{}}'
printf '%s\n' '{"type":"message_end","message":{"role":"assistant",'\
'"content":[{"type":"text","text":"final report"}]}}'
printf '%s\n' '{"type":"agent_end","messages":[{"role":"assistant",'\
'"content":[{"type":"text","text":"final report"}]}]}'
`, os.Permissions{.Read_User, .Write_User, .Execute_User})
	code := run_worker_with(state_root, brew_id, "a", "", fake_pi)
	testing.expect_value(t, code, 0)

	report_path := fmt.tprintf("%s/reports/a.md", brew_dir)
	report, report_err := os.read_entire_file(report_path, context.allocator)
	defer delete(report)
	testing.expect_value(t, report_err, os.Error(nil))
	testing.expect_value(t, string(report), "final report")

	saw_start, saw_tool, saw_end := false, false, false
	for {
		received := activity_listener_receive(&listener)
		switch received.kind {
		case .Message:
			if received.message.brew_id == brew_id && received.message.shot_id == "a" {
				saw_start = saw_start || received.message.kind == "starting"
				saw_tool = saw_tool || received.message.kind == "tool_start"
				saw_end = saw_end || received.message.kind == "agent_end"
			}
			destroy_struct(&received.message)
		case .Unavailable:
			break
		case .Malformed, .Failed:
			testing.expect(t, false, "Pi activity message should be valid")
			return
		}
		if received.kind == .Unavailable {
			break
		}
	}
	testing.expect(
		t,
		saw_start && saw_tool && saw_end,
		"starting, tool and completion activity should be streamed",
	)
}

@(test)
test_supervisor_accepts_activity_only_for_running_shots_in_this_brew :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	register := make_test_register(t)
	defer destroy_struct(&register)
	brew_dir := fmt.tprintf("%s/%s", root, register.brew_id)
	_ = create_state(brew_dir, &register)
	workers_dir := state_file_path(brew_dir, "workers")
	defer delete(workers_dir)
	_ = os.make_directory_all(workers_dir, os.Permissions{.Read_User, .Write_User, .Execute_User})
	_ = transition_shot(brew_dir, &register, "shot-a", SHOT_RUNNING, "Worker started")
	delete(register.shots[1].status)
	register.shots[1].status = strings.clone(SHOT_COMPLETED)

	socket_path := activity_socket_path(brew_dir)
	defer delete(socket_path)
	listener, listening := activity_listener_open(socket_path)
	testing.expect(t, listening)
	defer activity_listener_close(&listener)
	sender, sending := activity_sender_open(socket_path)
	testing.expect(t, sending)
	defer activity_sender_close(&sender)

	for message in ([]Activity_Message{
		{
			brew_id = "other-brew", shot_id = "shot-a", kind = "tool_start",
			description = "wrong Brew", timestamp_ns = 1,
		},
		{
			brew_id = register.brew_id, shot_id = "shot-missing", kind = "tool_start",
			description = "unknown Shot", timestamp_ns = 2,
		},
		{
			brew_id = register.brew_id, shot_id = "shot-b", kind = "tool_start",
			description = "terminal Shot", timestamp_ns = 3,
		},
		{
			brew_id = register.brew_id, shot_id = "shot-a", kind = "tool_start",
			description = "valid activity", timestamp_ns = 4,
		},
	}) {
		testing.expect(t, activity_sender_send(&sender, message))
	}
	drain_worker_activity(brew_dir, register, &listener)

	record, found := read_activity_record(brew_dir, "shot-a")
	defer destroy_struct(&record)
	testing.expect(t, found)
	testing.expect_value(t, record.description, "valid activity")
	_, found = read_activity_record(brew_dir, "shot-b")
	testing.expect(t, !found)
	_, found = read_activity_record(brew_dir, "shot-missing")
	testing.expect(t, !found)
}

@(test)
test_brew_ids_are_utc_timestamps_that_sort_chronologically :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	earlier, _ := time.components_to_time(2026, 10, 8, 4, 15, 0)
	later, _ := time.components_to_time(2026, 10, 8, 4, 15, 1)

	first := next_brew_id(root, earlier)
	defer delete(first)
	testing.expect(t, strings.has_prefix(first, "brew-20261008T041500Z-"), first)
	testing.expect(t, valid_shot_id(first), "Brew IDs must satisfy the safe ID rule")

	// A second Brew in the same second must still get a distinct, later-sorting ID.
	_ = os.make_directory_all(fmt.tprintf("%s/%s", root, first))
	same_second := next_brew_id(root, earlier)
	defer delete(same_second)
	testing.expect(t, same_second != first)
	testing.expect(t, same_second > first, same_second)

	next := next_brew_id(root, later)
	defer delete(next)
	testing.expect(t, next > same_second && next > first)
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

@(test)
test_brew_records_the_beans_base_commit :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	repo := fmt.tprintf("%s/repo", root)
	make_fixture_repo(t, repo)
	recipe_path := fmt.tprintf("%s/recipe.json", root)
	_ = os.write_entire_file(recipe_path, `{
		"order":"o",
		"shots":[{"id":"a","prompt":"pa"}]
	}`, os.Permissions{.Read_User, .Write_User})
	state_root := fmt.tprintf("%s/state", root)

	brew_id, err := run_brew_with(repo, recipe_path, state_root, "/nonexistent", "/nonexistent/herdr")
	defer delete(brew_id)
	testing.expect_value(t, err, "")

	_, stdout, _, _ := os.process_exec(os.Process_Desc{command = []string{"git", "-C", repo, "rev-parse", "HEAD"}}, context.allocator)
	defer delete(stdout)
	register, state_err := read_state(fmt.tprintf("%s/%s", state_root, brew_id))
	defer destroy_struct(&register)
	testing.expect_value(t, state_err.kind, State_Error_Kind.None)
	testing.expect_value(t, len(register.base_commit), 40)
	testing.expect_value(t, register.base_commit, strings.trim_space(string(stdout)))
}

@(test)
test_herdr_json_errors_are_reported_as_their_message :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	repo := fmt.tprintf("%s/repo", root)
	make_fixture_repo(t, repo)
	recipe_path := fmt.tprintf("%s/recipe.json", root)
	_ = os.write_entire_file(recipe_path, `{
		"order":"o",
		"shots":[{"id":"a","prompt":"pa"}]
	}`, os.Permissions{.Read_User, .Write_User})
	// What real Herdr does when no server is running: JSON on stderr, exit code 1.
	herdr := fmt.tprintf("%s/herdr", root)
	_ = os.write_entire_file(herdr, `#!/bin/sh
echo '{"id":"cli:workspace:create","error":{"code":"server_not_running","message":"no herdr server is running; run herdr to start it"}}' >&2
exit 1
`, os.Permissions{.Read_User, .Write_User, .Execute_User})
	state_root := fmt.tprintf("%s/state", root)

	brew_id, err := run_brew_with(repo, recipe_path, state_root, "/nonexistent", herdr)
	defer delete(brew_id)
	testing.expect_value(t, err, "")

	receipt, _ := os.read_entire_file(fmt.tprintf("%s/%s/receipt.ndjson", state_root, brew_id), context.allocator)
	defer delete(receipt)
	testing.expect(t, strings.contains(string(receipt), "Herdr workspace launch failed: no herdr server is running; run herdr to start it"), string(receipt))
	testing.expect(t, !strings.contains(string(receipt), "server_not_running"), "the raw JSON must not be shown")
}

// A block line that other text follows still names its reason. The Shot stays
// incomplete, because no marker ends the final message.
@(test)
test_completion_marker_names_a_block_followed_by_other_text :: proc(t: ^testing.T) {
	marker, clean := completion_marker("I cannot do it.\nCS-BLOCKED: no access\n\nPREAMBLE-OK\n")
	defer delete(marker)
	defer delete(clean)
	testing.expect_value(t, marker, "CS-BLOCKED: no access")
}
