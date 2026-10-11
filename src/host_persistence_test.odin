package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

HOST_PERSISTENCE_SCRIPT :: `set -u
export PATH="$2:$PATH" CS_STATE_DIR="$3" FAKE_HERDR_DIR="$4"
cat "$1" | "$5" host
`

host_persistence_run :: proc(root, binary, bin, state, input_path: string) -> (stdout, stderr: string, ok: bool) {
	run, out, errout, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", HOST_PERSISTENCE_SCRIPT, "host-persistence", input_path, bin, state, root, binary},
	}, context.allocator)
	defer delete(out)
	defer delete(errout)
	stdout = strings.clone(string(out), context.allocator)
	stderr = strings.clone(string(errout), context.allocator)
	return stdout, stderr, exec_err == nil && run.success
}

@(test)
test_host_history_survives_restart_without_replaying_herdr :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(HOST_TEST_TEMP_DIR, "coffee-shop-history-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	repo := fmt.aprintf("%s/beans", root)
	bin := fmt.aprintf("%s/bin", root)
	state := fmt.aprintf("%s/state", root)
	first_input := fmt.aprintf("%s/first.ndjson", root)
	second_input := fmt.aprintf("%s/second.ndjson", root)
	closed_history_dir := fmt.aprintf("%s/host/closed-1", state)
	closed_history := fmt.aprintf("%s/history.ndjson", closed_history_dir)
	defer delete(repo)
	defer delete(bin)
	defer delete(state)
	defer delete(first_input)
	defer delete(second_input)
	defer delete(closed_history_dir)
	defer delete(closed_history)

	rwx := os.Permissions{.Read_User, .Write_User, .Execute_User}
	testing.expect_value(t, os.make_directory_all(repo, rwx), os.Error(nil))
	testing.expect_value(t, os.make_directory_all(bin, rwx), os.Error(nil))
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/herdr", bin), HOST_FAKE_HERDR, rwx), os.Error(nil))
	git_state, _, git_stderr, git_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `git init -q "$1" && git -C "$1" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init`, "history-test", repo},
	}, context.allocator)
	defer delete(git_stderr)
	testing.expect_value(t, git_err, os.Error(nil))
	testing.expect(t, git_state.success, string(git_stderr))

	input := fmt.aprintf(`{{"type":"dispatch","request_id":"order-1","repo":"%s","recipe":{{"shots":[{{"id":"shot-a","prompt":"inspect"}}]}}}}
{{"type":"reply","request_id":"order-1","shot_id":"shot-a","message":"follow up"}}
{{"type":"shutdown","request_id":"stop-1"}}
`, repo)
	defer delete(input)
	testing.expect_value(t, os.write_entire_file(first_input, input, rwx), os.Error(nil))

	binary := build_test_binary(t, root)
	defer delete(binary)
	first_out, first_err, first_ok := host_persistence_run(root, binary, bin, state, first_input)
	defer delete(first_out)
	defer delete(first_err)
	testing.expect(t, first_ok, first_err)
	testing.expect(t, strings.contains(first_out, `{"type":"dispatch_accepted","request_id":"order-1"}`), first_out)
	testing.expect(t, strings.contains(first_out, `{"type":"session_started","request_id":"order-1"`), first_out)
	testing.expect(t, strings.contains(first_out, `{"type":"reply_sent","request_id":"order-1","shot_id":"shot-a"}`), first_out)

	history_path := fmt.aprintf("%s/host/order-1/history.ndjson", state)
	defer delete(history_path)
	history_data, history_err := os.read_entire_file(history_path, context.allocator)
	defer delete(history_data)
	testing.expect_value(t, history_err, os.Error(nil))
	history := string(history_data)
	dispatch_at := strings.index(history, `"type":"dispatch_accepted"`)
	started_at := strings.index(history, `"type":"session_started"`)
	reply_at := strings.index(history, `"type":"reply_sent"`)
	testing.expect(t, dispatch_at >= 0 && started_at > dispatch_at && reply_at > started_at, history)

	calls_before_data, calls_before_err := os.read_entire_file(fmt.tprintf("%s/calls.log", root), context.allocator)
	defer delete(calls_before_data)
	testing.expect_value(t, calls_before_err, os.Error(nil))
	calls_before := string(calls_before_data)

	// A valid closed history followed by a truncated line must keep its earlier evidence.
	testing.expect_value(t, os.make_directory_all(closed_history_dir, rwx), os.Error(nil))
	closed := `{"type":"dispatch_accepted","request_id":"closed-1"}
{"type":"session_started","request_id":"closed-1","shot_id":"shot-a","pane_id":"p0"}
{"type":"station_report","request_id":"closed-1","shot_id":"shot-a","kind":"agent_exited","description":"Agent exited"}
{"type":"truncated"`
	testing.expect_value(t, os.write_entire_file(closed_history, closed, rwx), os.Error(nil))

	second_input_text := `{"type":"sessions"}
{"type":"shutdown","request_id":"stop-2"}
`
	testing.expect_value(t, os.write_entire_file(second_input, second_input_text, rwx), os.Error(nil))
	second_out, second_err, second_ok := host_persistence_run(root, binary, bin, state, second_input)
	defer delete(second_out)
	defer delete(second_err)
	testing.expect(t, second_ok, second_err)
	testing.expect(t, strings.contains(second_out, `"type":"sessions"`), second_out)
	testing.expect(t, strings.contains(second_out, `"request_id":"order-1"`) && strings.contains(second_out, `"unfinished":true`), second_out)
	testing.expect(t, strings.contains(second_out, HOST_UNFINISHED_REASON), second_out)
	testing.expect(t, strings.contains(second_out, `"request_id":"closed-1"`) && strings.contains(second_out, `"kind":"agent_exited"`), second_out)
	testing.expect(t, !strings.contains(second_out, "truncated"), second_out)

	calls_after_data, calls_after_err := os.read_entire_file(fmt.tprintf("%s/calls.log", root), context.allocator)
	defer delete(calls_after_data)
	testing.expect_value(t, calls_after_err, os.Error(nil))
	testing.expect_value(t, string(calls_after_data), calls_before)
}
