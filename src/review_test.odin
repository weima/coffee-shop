package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_review_prompt_contains_instructions_diff_and_untracked_files :: proc(t: ^testing.T) {
	prompt := review_prompt("DIFF", "new.txt\n", true)
	defer delete(prompt)
	for expected in ([]string{
		"read-only review", "standards.md", "file and line", "high/medium/low",
		"No findings", "never modify files", "under 400 words", "truncated",
		"DIFF", "new.txt",
	}) {
		testing.expect(t, strings.contains(prompt, expected), expected)
	}
}

@(test)
test_review_skips_when_standards_are_missing :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	station := fmt.tprintf("%s/station", root)
	make_fixture_repo(t, station)
	result := review_station(station, "HEAD", "/missing/pi")
	defer destroy_struct(&result)
	testing.expect(t, !result.performed)
	testing.expect_value(t, result.detail, "standards.md is missing in the Beans repository; no review was performed")
}

@(test)
test_review_skips_when_there_are_no_changes :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	station := review_test_station(t, root)
	pi := review_test_pi(t, root, "printf called > \"$RECORD\"\n")
	result := review_station(station, "HEAD", pi)
	defer destroy_struct(&result)
	testing.expect(t, !result.performed)
	testing.expect_value(t, result.detail, "no changes to review")
	testing.expect(t, !os.exists(fmt.tprintf("%s/called", root)))
}

@(test)
test_review_runs_pi_with_exact_read_only_arguments_and_preserves_station :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	station := review_test_station(t, root)
	_ = os.write_entire_file(fmt.tprintf("%s/change.txt", station), "changed\n", os.Permissions{.Read_User, .Write_User})
	_ = os.write_entire_file(fmt.tprintf("%s/new.txt", station), "untracked\n", os.Permissions{.Read_User, .Write_User})
	pi := review_test_pi(t, root, "printf '%s\\n' \"$0\" \"$@\" > \"$RECORD\"\nprintf '  findings here  \\n'\n")
	before, _ := os.read_entire_file(fmt.tprintf("%s/change.txt", station), context.allocator)
	defer delete(before)
	result := review_station(station, "HEAD", pi)
	defer destroy_struct(&result)
	testing.expect(t, result.performed)
	testing.expect_value(t, result.findings, "findings here")
	argv, _ := os.read_entire_file(fmt.tprintf("%s/argv", root), context.allocator)
	defer delete(argv)
	args := transmute(string)argv
	for expected in ([]string{"--print", "--no-session", "--no-extensions", "--no-mcp", "--tools", "read,grep,find,ls", "--"}) {
		testing.expect(t, strings.contains(args, expected), fmt.tprintf("missing %s from %s", expected, args))
	}
	testing.expect(t, strings.has_prefix(args, fmt.tprintf("%s\n--print\n--no-session\n--no-extensions\n--no-mcp\n--tools\nread,grep,find,ls\n--\n", pi)))
	testing.expect(t, strings.has_suffix(args, "Untracked files:\nchange.txt\nnew.txt\n\n"))
	after, _ := os.read_entire_file(fmt.tprintf("%s/change.txt", station), context.allocator)
	defer delete(after)
	testing.expect_value(t, string(after), string(before))
}

@(test)
test_review_truncates_diff_and_identifies_it_in_prompt :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	station := review_test_station(t, root)
	_ = os.write_entire_file(fmt.tprintf("%s/tracked.txt", station), strings.repeat("x", 500, context.temp_allocator), os.Permissions{.Read_User, .Write_User})
	pi := review_test_pi(t, root, "printf '%s' \"$*\" > \"$RECORD\"\nprintf 'ok'\n")
	result := review_station(station, "HEAD", pi, 200)
	defer destroy_struct(&result)
	testing.expect(t, result.performed)
	prompt, _ := os.read_entire_file(fmt.tprintf("%s/argv", root), context.allocator)
	defer delete(prompt)
	testing.expect(t, strings.contains(transmute(string)prompt, "truncated"))
	testing.expect(t, strings.contains(transmute(string)prompt, "diff --git"))
}

@(test)
test_review_reports_git_failure_and_pi_failures :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	station := fmt.tprintf("%s/station", root)
	_ = os.make_directory_all(station, os.Permissions{.Read_User, .Write_User, .Execute_User})
	_ = os.write_entire_file(fmt.tprintf("%s/standards.md", station), "standard", os.Permissions{.Read_User, .Write_User})
	result := review_station(station, "HEAD", "/missing/pi")
	defer destroy_struct(&result)
	testing.expect(t, !result.performed && result.detail != "")

	destroy_struct(&result)
	station = review_test_station(t, root)
	_ = os.write_entire_file(fmt.tprintf("%s/change.txt", station), "change\n", os.Permissions{.Read_User, .Write_User})
	pi := review_test_pi(t, root, "exit 2\n")
	result = review_station(station, "HEAD", pi)
	testing.expect(t, !result.performed)
	testing.expect(t, strings.contains(result.detail, "Pi exited with code 2"))

	destroy_struct(&result)
	result = review_station(station, "HEAD", "/missing/pi")
	testing.expect(t, !result.performed)
	testing.expect(t, result.detail != "")
}

review_test_station :: proc(t: ^testing.T, root: string) -> string {
	station := fmt.tprintf("%s/station", root)
	make_fixture_repo(t, station)
	_ = os.write_entire_file(fmt.tprintf("%s/standards.md", station), "# Standards\n", os.Permissions{.Read_User, .Write_User})
	_ = os.write_entire_file(fmt.tprintf("%s/tracked.txt", station), "initial\n", os.Permissions{.Read_User, .Write_User})
	state, _, _, err := os.process_exec(os.Process_Desc{command = []string{"git", "-C", station, "add", "standards.md", "tracked.txt"}}, context.allocator)
	testing.expect(t, err == nil && state.success)
	state, _, _, err = os.process_exec(os.Process_Desc{command = []string{"git", "-C", station, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "standards"}}, context.allocator)
	testing.expect(t, err == nil && state.success)
	return station
}

review_test_pi :: proc(t: ^testing.T, root, body: string) -> string {
	path := fmt.tprintf("%s/pi", root)
	script := fmt.aprintf("#!/bin/sh\nRECORD='%s/argv'\n%s", root, body)
	defer delete(script)
	testing.expect_value(t, os.write_entire_file(path, script, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	return path
}
