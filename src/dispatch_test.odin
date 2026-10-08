package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_worker_command_quotes_paths_and_contains_only_ids :: proc(t: ^testing.T) {
	command, err := worker_command("/tmp/it's here/coffee-shop", "/tmp/my state", "brew-1-0", "shot-a")
	defer delete(command)
	testing.expect_value(t, err, "")
	testing.expect_value(t, command, `'/tmp/it'\''s here/coffee-shop' __worker --state-root '/tmp/my state' --brew-id brew-1-0 --shot-id shot-a`)
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
	defer destroy_register(&register)
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
	_ = os.write_entire_file(recipe_path, `{"order":"o","shots":[{"id":"a","prompt":"it's $(x)"}]}`, os.Permissions{.Read_User, .Write_User})
	state_root := fmt.tprintf("%s/state", root)
	// Herdr fails after Stations exist, so the Worker can be run directly.
	brew_id, _ := run_brew_with(repo, recipe_path, state_root, "/nonexistent", "/nonexistent/herdr")
	defer delete(brew_id)

	fake_pi := fmt.tprintf("%s/pi", root)
	_ = os.write_entire_file(fake_pi, "#!/bin/sh\nprintf '%s' \"$4\" > arg.txt\nexit 3\n", os.Permissions{.Read_User, .Write_User, .Execute_User})
	code := run_worker_with(state_root, brew_id, "a", fake_pi)
	testing.expect_value(t, code, 3)

	arg, _ := os.read_entire_file(fmt.tprintf("%s/%s/stations/a/arg.txt", state_root, brew_id), context.allocator)
	defer delete(arg)
	testing.expect_value(t, string(arg), "Order: o\n\nShot: it's $(x)")
	result_path := worker_result_path(fmt.tprintf("%s/%s", state_root, brew_id), "a")
	defer delete(result_path)
	result, result_err := read_worker_result(result_path)
	defer destroy_worker_result(&result)
	testing.expect_value(t, result_err, "")
	testing.expect(t, result.started && !result.success)
	testing.expect_value(t, result.exit_code, 3)
}

make_fixture_root :: proc(t: ^testing.T) -> string {
	root, err := os.make_directory_temp("", "coffee-shop-dispatch-*", context.allocator)
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
		state, _, _, err := os.process_exec(os.Process_Desc{command = args}, context.allocator)
		testing.expect(t, err == nil && state.success)
	}
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
	_ = os.write_entire_file(recipe_path, `{"order":"o","shots":[{"id":"a","prompt":"pa"}]}`, os.Permissions{.Read_User, .Write_User})
	state_root := fmt.tprintf("%s/state", root)

	brew_id, err := run_brew_with(repo, recipe_path, state_root, "/nonexistent", "/nonexistent/herdr")
	defer delete(brew_id)
	testing.expect_value(t, err, "")

	_, stdout, _, _ := os.process_exec(os.Process_Desc{command = []string{"git", "-C", repo, "rev-parse", "HEAD"}}, context.allocator)
	defer delete(stdout)
	register, state_err := read_state(fmt.tprintf("%s/%s", state_root, brew_id))
	defer destroy_register(&register)
	testing.expect_value(t, state_err.kind, State_Error_Kind.None)
	testing.expect_value(t, len(register.base_commit), 40)
	testing.expect_value(t, register.base_commit, strings.trim_space(string(stdout)))
}
