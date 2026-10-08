package main

import "core:testing"

@(test)
test_parse_brew_arguments :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"brew", "--repo", "/tmp/beans", "--recipe", "/tmp/recipe.json"})

	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Brew)
	testing.expect_value(t, parsed.repo, "/tmp/beans")
	testing.expect_value(t, parsed.recipe, "/tmp/recipe.json")
}

@(test)
test_parse_status_argument :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"status", "brew-123"})

	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Status)
	testing.expect_value(t, parsed.brew_id, "brew-123")
}

@(test)
test_rejects_status_without_brew_id :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"status"})

	testing.expect(t, err != "")
}

@(test)
test_rejects_incomplete_brew_before_execution :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"brew", "--repo", "/tmp/beans"})

	testing.expect(t, err != "")
}

@(test)
test_rejects_unknown_command :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"something-else"})

	testing.expect(t, err != "")
}

@(test)
test_parses_help :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"--help"})

	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Help)
}

@(test)
test_parse_worker_arguments_include_the_state_root :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"__worker", "--state-root", "/tmp/state", "--brew-id", "brew-1-0", "--shot-id", "shot-a"})

	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Worker)
	testing.expect_value(t, parsed.state_root, "/tmp/state")
	testing.expect_value(t, parsed.brew_id, "brew-1-0")
	testing.expect_value(t, parsed.shot_id, "shot-a")
}

@(test)
test_rejects_worker_without_a_state_root :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"__worker", "--brew-id", "brew-1-0", "--shot-id", "shot-a"})

	testing.expect(t, err != "")
}
