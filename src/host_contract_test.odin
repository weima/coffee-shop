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

	input_path := fmt.aprintf("%s/requests.ndjson", root)
	defer delete(input_path)
	input := fmt.aprintf(`{{"type":"dispatch","request_id":"order-1","repo":"%s","recipe":{{"order":"first order","shots":[{{"id":"shot-a","prompt":"inspect the repository"}}]}}}}
{{"type":"dispatch","request_id":"order-2","repo":"%s","recipe":{{"order":"second order","shots":[{{"id":"shot-b","prompt":"inspect the tests"}}]}}}}
{{"type":"dispatch","request_id":"order-3","repo":"%s","recipe":{{"order":"bad order","shots":[{{"id":"../escape","prompt":"x"}}]}}}}
{{"type":"shutdown","request_id":"shutdown-1"}}
`, repo, repo, repo)
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
	testing.expect(t, strings.contains(out, `{"type":"session_started","request_id":"order-2","shot_id":"shot-b","pane_id":"p0"}`), out)
	testing.expect(t, strings.contains(out, `"request_id":"order-3"`) && strings.contains(out, `each shot needs a valid id and a prompt`), out)
	testing.expect(t, !strings.contains(out, `{"type":"dispatch_accepted","request_id":"order-3"}`), out)
	testing.expect(t, strings.contains(out, `{"type":"stopped","request_id":"shutdown-1"}`), out)

	calls_data, calls_err := os.read_entire_file(fmt.tprintf("%s/calls.log", root), context.allocator)
	defer delete(calls_data)
	testing.expect_value(t, calls_err, os.Error(nil))
	calls := string(calls_data)
	testing.expect(t, strings.contains(calls, "--station shot-a --brew order-1 --prompt 'inspect the repository' -- pi --mode rpc"), calls)
	testing.expect(t, strings.contains(calls, "--station shot-b --brew order-2 --prompt 'inspect the tests' -- pi --mode rpc"), calls)
	testing.expect(t, strings.contains(calls, "/state/host/order-1/stations/shot-a"), calls)
	testing.expect(t, strings.contains(calls, "/state/host/order-2/stations/shot-b"), calls)
}

HOST_TEST_TEMP_DIR :: "/private/tmp" when ODIN_OS == .Darwin else "/tmp"

// Records each call and answers the two Herdr commands the host uses.
HOST_FAKE_HERDR :: `#!/bin/sh
echo "$*" >> "$FAKE_HERDR_DIR/calls.log"
case "$1 $2" in
"workspace create")
  echo '{"id":"x","result":{"type":"workspace_created","workspace":{"workspace_id":"w1"},"tab":{"tab_id":"t0"},"root_pane":{"pane_id":"p0"}}}' ;;
"tab create")
  echo '{"id":"x","result":{"type":"tab_created","tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1"}}}' ;;
*) echo '{}' ;;
esac
`
