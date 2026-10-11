package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The foreground host is the public controller seam. It acknowledges structured
// dispatches in order, starts one interactive Pi session per Shot in isolated
// Stations, and stays ready until the harness shuts it down. A fake `herdr` on
// PATH stands in for Herdr; no Pi or AI service runs.
@(test)
test_foreground_host_accepts_dispatches_and_starts_sessions :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(HOST_TEST_TEMP_DIR, "coffee-shop-host-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	repo := fmt.aprintf("%s/beans", root)
	bin := fmt.aprintf("%s/bin", root)
	state := fmt.aprintf("%s/state", root)
	defer delete(repo)
	defer delete(bin)
	defer delete(state)
	rwx := os.Permissions{.Read_User, .Write_User, .Execute_User}
	testing.expect_value(t, os.make_directory_all(repo), os.Error(nil))
	testing.expect_value(t, os.make_directory_all(bin), os.Error(nil))
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/herdr", bin), HOST_FAKE_HERDR, rwx), os.Error(nil))

	git_state, _, git_stderr, git_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `git init -q "$1" && git -C "$1" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init`, "host-test", repo},
	}, context.allocator)
	defer delete(git_stderr)
	testing.expect_value(t, git_err, os.Error(nil))
	testing.expect(t, git_state.success, string(git_stderr))

	long_prompt := fmt.aprintf("first line\nit's a long prompt\n%s", strings.repeat("x", 5000, context.temp_allocator))
	defer delete(long_prompt)
	json_prompt, _ := strings.replace_all(long_prompt, "\n", "\\n", context.allocator)
	defer delete(json_prompt)
	input_path := fmt.aprintf("%s/requests.ndjson", root)
	defer delete(input_path)
	input := fmt.aprintf(`{{"type":"dispatch","request_id":"order-1","repo":"%s","recipe":{{"order":"first order","shots":[{{"id":"shot-a","prompt":"%s","model":"github-copilot/claude-haiku-5.5"}}]}}}}
{{"type":"dispatch","request_id":"order-2","repo":"%s","recipe":{{"order":"second order","shots":[{{"id":"shot-b","prompt":"inspect the tests"}}]}}}}
{{"type":"dispatch","request_id":"order-3","repo":"%s","recipe":{{"order":"bad order","shots":[{{"id":"../escape","prompt":"x"}}]}}}}
{{"type":"dispatch","request_id":"order-4","repo":"%s","recipe":{{"order":"bad model","shots":[{{"id":"shot-c","prompt":"x","model":"bad model;"}}]}}}}
{{"type":"shutdown","request_id":"shutdown-1"}}
`, repo, json_prompt, repo, repo, repo)
	defer delete(input)
	write_err := os.write_entire_file(input_path, input, rwx)
	testing.expect_value(t, write_err, os.Error(nil))
	if write_err != nil {
		return
	}

	binary := build_test_binary(t, root)
	defer delete(binary)
	state_run, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `export PATH="$2:$PATH" CS_STATE_DIR="$3" FAKE_HERDR_DIR="$4"; cat "$1" | "$5" host`, "host-test", input_path, bin, state, root, binary},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)

	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state_run.success, string(stderr))
	out := string(stdout)
	testing.expect(t, strings.contains(out, `{"type":"ready","protocol":1}`), out)
	testing.expect(t, strings.contains(out, `{"type":"dispatch_accepted","request_id":"order-1"}`), out)
	testing.expect(t, strings.contains(out, `{"type":"session_started","request_id":"order-1","shot_id":"shot-a","pane_id":"p0"}`), out)
	testing.expect(t, strings.contains(out, `{"type":"dispatch_accepted","request_id":"order-2"}`), out)
	testing.expect(t, strings.contains(out, `{"type":"session_started","request_id":"order-2","shot_id":"shot-b","pane_id":"p1"}`), out)
	testing.expect(t, strings.contains(out, `"request_id":"order-3"`) && strings.contains(out, `each shot needs a valid id and a prompt`), out)
	testing.expect(t, !strings.contains(out, `{"type":"dispatch_accepted","request_id":"order-3"}`), out)
	testing.expect(t, strings.contains(out, `"request_id":"order-4","shot_id":"shot-c"`) && strings.contains(out, `shot model must be`), out)
	testing.expect(t, !strings.contains(out, `{"type":"dispatch_accepted","request_id":"order-4"}`), out)
	testing.expect(t, strings.contains(out, `{"type":"stopped","request_id":"shutdown-1"}`), out)

	prompt_path := fmt.aprintf("%s/host/order-1/prompts/shot-a.md", state)
	defer delete(prompt_path)
	prompt_data, prompt_err := os.read_entire_file(prompt_path, context.allocator)
	defer delete(prompt_data)
	testing.expect_value(t, prompt_err, os.Error(nil))
	testing.expect_value(t, string(prompt_data), long_prompt)

	calls_data, calls_err := os.read_entire_file(fmt.tprintf("%s/calls.log", root), context.allocator)
	defer delete(calls_data)
	testing.expect_value(t, calls_err, os.Error(nil))
	calls := string(calls_data)
	testing.expect(t, strings.contains(calls, "--station shot-a --brew order-1 --prompt-file '") && strings.contains(calls, "-- pi --mode rpc --model 'github-copilot/claude-haiku-5.5' -e"), calls)
	prompt_command_at := strings.index(calls, "--station shot-a")
	prompt_command_start := strings.last_index_byte(calls[:prompt_command_at], '\n') + 1
	prompt_command_end := strings.index_byte(calls[prompt_command_at:], '\n')
	if prompt_command_end < 0 {
		prompt_command_end = len(calls) - prompt_command_at
	} else {
		prompt_command_end = prompt_command_at + prompt_command_end - prompt_command_start
	}
	prompt_command := calls[prompt_command_start : prompt_command_start+prompt_command_end]
	testing.expect(t, len(prompt_command) < 512, fmt.tprintf("command length: %d\n%s", len(prompt_command), prompt_command))
	shot_b_path := fmt.aprintf("%s/host/order-2/prompts/shot-b.md", state)
	defer delete(shot_b_path)
	shot_b_marker := strings.index(calls, "--station shot-b")
	shot_b_start := strings.last_index_byte(calls[:shot_b_marker], '\n') + 1
	shot_b_end := strings.index_byte(calls[shot_b_marker:], '\n')
	if shot_b_end < 0 {
		shot_b_end = len(calls) - shot_b_marker
	} else {
		shot_b_end = shot_b_marker + shot_b_end - shot_b_start
	}
	shot_b_command := calls[shot_b_start : shot_b_start+shot_b_end]
	testing.expect(t, strings.contains(shot_b_command, fmt.tprintf("--station shot-b --brew order-2 --prompt-file '%s' -- pi --mode rpc -e", shot_b_path)), shot_b_command)
	testing.expect(t, !strings.contains(shot_b_command, "--model"), shot_b_command)
	testing.expect(t, !os.exists(fmt.tprintf("%s/host/order-4/stations/shot-c", state)), "invalid model must not create a worktree")
	testing.expect(t, !strings.contains(calls, "shot-c"), "invalid model must not call Herdr")
}

// A research Shot gets read-only tools, an execute Shot does not, and an unknown kind
// is refused before any worktree or Herdr call for that dispatch.
@(test)
test_foreground_host_passes_shot_kind_and_rejects_unknown_kind :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(HOST_TEST_TEMP_DIR, "coffee-shop-host-kind-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	repo := fmt.aprintf("%s/beans", root)
	bin := fmt.aprintf("%s/bin", root)
	state := fmt.aprintf("%s/state", root)
	defer delete(repo)
	defer delete(bin)
	defer delete(state)
	rwx := os.Permissions{.Read_User, .Write_User, .Execute_User}
	testing.expect_value(t, os.make_directory_all(repo), os.Error(nil))
	testing.expect_value(t, os.make_directory_all(bin), os.Error(nil))
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/herdr", bin), HOST_FAKE_HERDR, rwx), os.Error(nil))

	git_state, _, git_stderr, git_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `git init -q "$1" && git -C "$1" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init`, "host-kind-test", repo},
	}, context.allocator)
	defer delete(git_stderr)
	testing.expect_value(t, git_err, os.Error(nil))
	testing.expect(t, git_state.success, string(git_stderr))

	input_path := fmt.aprintf("%s/requests.ndjson", root)
	defer delete(input_path)
	input := fmt.aprintf(`{{"type":"dispatch","request_id":"order-5","repo":"%s","recipe":{{"order":"research order","shots":[{{"id":"shot-r","prompt":"read the code","kind":"research"}},{{"id":"shot-e","prompt":"make the change","kind":"execute"}}]}}}}
{{"type":"dispatch","request_id":"order-6","repo":"%s","recipe":{{"order":"bad kind","shots":[{{"id":"shot-w","prompt":"write a file","kind":"write"}}]}}}}
{{"type":"shutdown","request_id":"shutdown-1"}}
`, repo, repo)
	defer delete(input)
	testing.expect_value(t, os.write_entire_file(input_path, input, rwx), os.Error(nil))

	binary := build_test_binary(t, root)
	defer delete(binary)
	state_run, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `export PATH="$2:$PATH" CS_STATE_DIR="$3" FAKE_HERDR_DIR="$4"; cat "$1" | "$5" host`, "host-kind-test", input_path, bin, state, root, binary},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state_run.success, string(stderr))
	out := string(stdout)
	testing.expect(t, strings.contains(out, `{"type":"session_started","request_id":"order-5","shot_id":"shot-r"`), out)
	testing.expect(t, strings.contains(out, `{"type":"session_started","request_id":"order-5","shot_id":"shot-e"`), out)
	testing.expect(t, strings.contains(out, `{"type":"error","request_id":"order-6","shot_id":"shot-w","reason":"shot kind must be execute or research"}`), out)
	testing.expect(t, !strings.contains(out, `{"type":"dispatch_accepted","request_id":"order-6"}`), out)
	testing.expect(t, !os.exists(fmt.tprintf("%s/host/order-6/stations/shot-w", state)), "unknown kind must not create a worktree")

	calls_data, calls_err := os.read_entire_file(fmt.tprintf("%s/calls.log", root), context.allocator)
	defer delete(calls_data)
	testing.expect_value(t, calls_err, os.Error(nil))
	calls := string(calls_data)
	testing.expect(t, !strings.contains(calls, "shot-w"), "unknown kind must not call Herdr")
	testing.expect(t, strings.contains(calls, "station --kind research --report") && strings.contains(calls, "-- pi --mode rpc --tools read,grep,find,ls -e"), calls)
	testing.expect(t, strings.contains(calls, "station --kind execute --report") && strings.contains(calls, "-- pi --mode rpc -e"), calls)
	testing.expect_value(t, strings.count(calls, "--tools"), 1)
}

HOST_TEST_TEMP_DIR :: "/private/tmp" when ODIN_OS == .Darwin else "/tmp"

// Records each call and answers the two Herdr commands the host uses.
HOST_FAKE_HERDR :: `#!/bin/sh
echo "$*" >> "$FAKE_HERDR_DIR/calls.log"
case "$1 $2" in
"workspace create")
  echo '{"id":"x","result":{"type":"workspace_created","workspace":{"workspace_id":"w1"},"tab":{"tab_id":"t0"},"root_pane":{"pane_id":"p0"}}}' ;;
"tab create")
  if [ "$4" = w1 ]; then
    echo '{"id":"x","result":{"type":"tab_created","tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1"}}}'
  else
    echo '{"id":"x","error":{"code":"workspace_not_found","message":"no workspace with that id"}}' >&2
    exit 1
  fi ;;
*) echo '{}' ;;
esac
`

Host_Contract_Run :: struct {
	root:  string, // owned by the caller
	state: string, // owned by the caller
	out:   string, // host stdout, owned by the caller
	calls: string, // fake Herdr calls, owned by the caller; empty when Herdr was never called
}

// Runs the foreground host on requests in a fresh repository with one commit. The
// @REPO@ placeholder in the requests becomes the repository path, and @OTHER@ becomes
// a second repository, "pulses". A non-empty saved_workspace is written as the
// workspace id already saved for "beans".
run_host_requests :: proc(t: ^testing.T, prefix, requests: string, saved_workspace := "") -> (run: Host_Contract_Run) {
	root, make_err := os.make_directory_temp(HOST_TEST_TEMP_DIR, prefix, context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	run.root = root
	repo := fmt.tprintf("%s/beans", root)
	other := fmt.tprintf("%s/pulses", root)
	bin := fmt.tprintf("%s/bin", root)
	run.state = fmt.aprintf("%s/state", root)
	rwx := os.Permissions{.Read_User, .Write_User, .Execute_User}
	testing.expect_value(t, os.make_directory_all(repo), os.Error(nil))
	testing.expect_value(t, os.make_directory_all(bin), os.Error(nil))
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/herdr", bin), HOST_FAKE_HERDR, rwx), os.Error(nil))
	git_state, _, git_stderr, git_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `for r in "$@"; do git init -q "$r" && git -C "$r" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init || exit 1; done`, "host-pull-test", repo, other},
	}, context.allocator)
	defer delete(git_stderr)
	testing.expect_value(t, git_err, os.Error(nil))
	testing.expect(t, git_state.success, string(git_stderr))

	if saved_workspace != "" {
		workspaces := fmt.tprintf("%s/host/workspaces", run.state)
		testing.expect_value(t, os.make_directory_all(workspaces), os.Error(nil))
		testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/beans.txt", workspaces), saved_workspace, rwx), os.Error(nil))
	}

	input, _ := strings.replace_all(requests, "@REPO@", repo, context.temp_allocator)
	input, _ = strings.replace_all(input, "@OTHER@", other, context.temp_allocator)
	input_path := fmt.tprintf("%s/requests.ndjson", root)
	testing.expect_value(t, os.write_entire_file(input_path, input, rwx), os.Error(nil))

	binary := build_test_binary(t, root)
	defer delete(binary)
	state_run, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `export PATH="$2:$PATH" CS_STATE_DIR="$3" FAKE_HERDR_DIR="$4"; cat "$1" | "$5" host`, "host-pull-test", input_path, bin, run.state, root, binary},
	}, context.allocator)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state_run.success, string(stderr))
	run.out = string(stdout)

	calls_data, calls_err := os.read_entire_file(fmt.tprintf("%s/calls.log", root), context.allocator)
	if calls_err == nil {
		run.calls = string(calls_data)
	}
	return
}

host_contract_destroy :: proc(run: Host_Contract_Run) {
	os.remove_all(run.root)
	delete(run.root)
	delete(run.state)
	delete(run.out)
	delete(run.calls)
}

@(test)
test_foreground_host_passes_taste_and_message_to_station :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-taste-*", `{"type":"dispatch","request_id":"order-t1","repo":"@REPO@","recipe":{"order":"pull order","shots":[{"id":"shot-t","prompt":"make the change","taste":"just test","message":"Add the taste check"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, strings.contains(run.out, `{"type":"session_started","request_id":"order-t1","shot_id":"shot-t","pane_id":"p0"}`), run.out)
	testing.expect(t, strings.contains(run.calls, "--prompt-file '") && strings.contains(run.calls, "--taste 'just test' --message 'Add the taste check' -- pi --mode rpc -e"), run.calls)
}

@(test)
test_foreground_host_omits_taste_for_shot_without_taste :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-no-taste-*", `{"type":"dispatch","request_id":"order-t2","repo":"@REPO@","recipe":{"order":"plain order","shots":[{"id":"shot-n","prompt":"make the change"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, strings.contains(run.out, `{"type":"session_started","request_id":"order-t2","shot_id":"shot-n"`), run.out)
	testing.expect(t, strings.contains(run.calls, "--station shot-n") && strings.contains(run.calls, "-- pi --mode rpc -e"), run.calls)
	testing.expect(t, !strings.contains(run.calls, "--taste") && !strings.contains(run.calls, "--message"), run.calls)
}

@(test)
test_foreground_host_rejects_taste_on_research_shot :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-research-taste-*", `{"type":"dispatch","request_id":"order-t3","repo":"@REPO@","recipe":{"order":"cupping order","shots":[{"id":"shot-r","prompt":"read the code","kind":"research","taste":"just test","message":"Add it"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, strings.contains(run.out, `{"type":"error","request_id":"order-t3","shot_id":"shot-r","reason":"shot taste needs an execute kind"}`), run.out)
	testing.expect(t, !strings.contains(run.out, `{"type":"dispatch_accepted","request_id":"order-t3"}`), run.out)
	testing.expect(t, !os.exists(fmt.tprintf("%s/host/order-t3/stations/shot-r", run.state)), "a refused taste must not create a worktree")
	testing.expect(t, !strings.contains(run.calls, "shot-r"), "a refused taste must not call Herdr")
}

// A message is required with a taste and must fit the commit subject limit. Both
// refusals happen before any worktree or Herdr call.
@(test)
test_foreground_host_rejects_taste_without_valid_message :: proc(t: ^testing.T) {
	long_message := strings.repeat("m", 201, context.temp_allocator)
	requests, _ := strings.replace_all(`{"type":"dispatch","request_id":"order-t4","repo":"@REPO@","recipe":{"order":"no message","shots":[{"id":"shot-m","prompt":"make the change","taste":"just test"}]}}
{"type":"dispatch","request_id":"order-t5","repo":"@REPO@","recipe":{"order":"long message","shots":[{"id":"shot-l","prompt":"make the change","taste":"just test","message":"@LONG@"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`, "@LONG@", long_message, context.temp_allocator)
	run := run_host_requests(t, "coffee-shop-host-message-*", requests)
	defer host_contract_destroy(run)
	testing.expect(t, strings.contains(run.out, `{"type":"error","request_id":"order-t4","shot_id":"shot-m","reason":"shot message is required with a taste and must be 1 to 200 characters on one line"}`), run.out)
	testing.expect(t, strings.contains(run.out, `{"type":"error","request_id":"order-t5","shot_id":"shot-l","reason":"shot message is required with a taste and must be 1 to 200 characters on one line"}`), run.out)
	testing.expect(t, !strings.contains(run.out, `"type":"dispatch_accepted","request_id":"order-t4"`), run.out)
	testing.expect(t, !strings.contains(run.out, `"type":"dispatch_accepted","request_id":"order-t5"`), run.out)
	testing.expect(t, !os.exists(fmt.tprintf("%s/host/order-t4/stations/shot-m", run.state)), "a refused message must not create a worktree")
	testing.expect(t, !os.exists(fmt.tprintf("%s/host/order-t5/stations/shot-l", run.state)), "a refused message must not create a worktree")
	testing.expect(t, !strings.contains(run.calls, "shot-m") && !strings.contains(run.calls, "shot-l"), "a refused message must not call Herdr")
}

// Two dispatches for one repository share one workspace. The first Shot takes the
// workspace's default tab; the second gets its own tab in that workspace.
@(test)
test_host_opens_shots_as_tabs_in_one_workspace_per_repository :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-workspace-*", `{"type":"dispatch","request_id":"order-w1","repo":"@REPO@","recipe":{"order":"first","shots":[{"id":"shot-w1","prompt":"make the change"}]}}
{"type":"dispatch","request_id":"order-w2","repo":"@REPO@","recipe":{"order":"second","shots":[{"id":"shot-w2","prompt":"make the change"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, strings.contains(run.out, `{"type":"session_started","request_id":"order-w1","shot_id":"shot-w1","pane_id":"p0"}`), run.out)
	testing.expect(t, strings.contains(run.out, `{"type":"session_started","request_id":"order-w2","shot_id":"shot-w2","pane_id":"p1"}`), run.out)
	testing.expect_value(t, strings.count(run.calls, "workspace create"), 1)
	testing.expect_value(t, strings.count(run.calls, "tab create"), 1)
	testing.expect(t, strings.contains(run.calls, "--label beans --no-focus"), run.calls)
	testing.expect(t, strings.contains(run.calls, "tab rename t0 Shot shot-w1"), run.calls)
	testing.expect(t, strings.contains(run.calls, "tab create --workspace w1 --cwd") && strings.contains(run.calls, "--label Shot shot-w2"), run.calls)

	saved, saved_err := os.read_entire_file(fmt.tprintf("%s/host/workspaces/beans.txt", run.state), context.allocator)
	defer delete(saved)
	testing.expect_value(t, saved_err, os.Error(nil))
	testing.expect_value(t, string(saved), "w1")
}

// A second repository gets its own workspace, labelled with its own name.
@(test)
test_host_opens_a_second_workspace_for_a_second_repository :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-two-repos-*", `{"type":"dispatch","request_id":"order-r1","repo":"@REPO@","recipe":{"order":"beans","shots":[{"id":"shot-r1","prompt":"make the change"}]}}
{"type":"dispatch","request_id":"order-r2","repo":"@OTHER@","recipe":{"order":"pulses","shots":[{"id":"shot-r2","prompt":"make the change"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, strings.contains(run.out, `{"type":"session_started","request_id":"order-r1","shot_id":"shot-r1","pane_id":"p0"}`), run.out)
	testing.expect(t, strings.contains(run.out, `{"type":"session_started","request_id":"order-r2","shot_id":"shot-r2","pane_id":"p0"}`), run.out)
	testing.expect_value(t, strings.count(run.calls, "workspace create"), 2)
	testing.expect_value(t, strings.count(run.calls, "tab create"), 0)
	testing.expect(t, strings.contains(run.calls, "--label beans --no-focus") && strings.contains(run.calls, "--label pulses --no-focus"), run.calls)
}

// A saved workspace that Herdr rejects is replaced by a new one, saved in its place,
// and the Shot still starts in that workspace's default tab.
@(test)
test_host_replaces_unusable_saved_workspace_and_still_starts_shot :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-stale-workspace-*", `{"type":"dispatch","request_id":"order-s1","repo":"@REPO@","recipe":{"order":"stale","shots":[{"id":"shot-s","prompt":"make the change"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`, "w-stale")
	defer host_contract_destroy(run)
	testing.expect(t, strings.contains(run.out, `{"type":"session_started","request_id":"order-s1","shot_id":"shot-s","pane_id":"p0"}`), run.out)
	testing.expect(t, !strings.contains(run.out, "session_failed"), run.out)
	testing.expect(t, strings.contains(run.calls, "tab create --workspace w-stale"), run.calls)
	testing.expect_value(t, strings.count(run.calls, "workspace create"), 1)
	testing.expect(t, strings.contains(run.calls, "tab rename t0 Shot shot-s"), run.calls)

	saved, saved_err := os.read_entire_file(fmt.tprintf("%s/host/workspaces/beans.txt", run.state), context.allocator)
	defer delete(saved)
	testing.expect_value(t, saved_err, os.Error(nil))
	testing.expect_value(t, string(saved), "w1")
}
