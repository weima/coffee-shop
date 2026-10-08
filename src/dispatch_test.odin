package main

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_worker_command_quotes_executable_and_contains_only_ids :: proc(t: ^testing.T) {
	command, err := worker_command("/tmp/it's here/coffee-shop", "brew-1-0", "shot-a")
	defer delete(command)
	testing.expect_value(t, err, "")
	testing.expect_value(t, command, `'/tmp/it'\''s here/coffee-shop' __worker --brew-id brew-1-0 --shot-id shot-a`)
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
