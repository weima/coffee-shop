package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Starts the host with its stdin on a FIFO, so it stays up while a real Station
// reports through the host's socket. Then it sends shutdown and returns the host's
// stdout for inspection.
HOST_RELAY_SCRIPT :: `set -u
state="$1"; fifo="$2"; out="$3"; err="$4"; agent="$5"; received="$6"; bin="$7"
export CS_STATE_DIR="$state"
mkfifo "$fifo"
"$bin" host < "$fifo" > "$out" 2> "$err" &
pid=$!
exec 3> "$fifo"
sock="$state/host/activity.sock"
i=0
while [ ! -S "$sock" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
"$bin" station --report "$sock" --station shot-a --brew order-1 --prompt "first question" -- sh "$agent" "$received" < /dev/null
sleep 1
printf '%s\n' '{"type":"shutdown","request_id":"done"}' >&3
exec 3>&-
wait $pid
`

@(test)
test_host_report_refuses_symlinks_and_prefix_escapes :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-report-path-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	host_dir, _ := filepath.join({root, "host"})
	reports_dir, _ := filepath.join({host_dir, "reports"})
	outside, _ := filepath.join({root, "outside"})
	prefix_dir, _ := filepath.join({root, "reports-other"})
	inside_path, _ := filepath.join({reports_dir, "ok.txt"})
	leak_path, _ := filepath.join({reports_dir, "leak"})
	prefix_path, _ := filepath.join({prefix_dir, "x"})
	defer delete(host_dir)
	defer delete(reports_dir)
	defer delete(outside)
	defer delete(prefix_dir)
	defer delete(inside_path)
	defer delete(leak_path)
	defer delete(prefix_path)

	testing.expect_value(t, os.make_directory_all(reports_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	testing.expect_value(t, os.make_directory_all(prefix_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	testing.expect_value(t, os.write_entire_file(outside, "secret", os.Permissions{.Read_User, .Write_User}), os.Error(nil))
	testing.expect_value(t, os.write_entire_file(inside_path, "safe", os.Permissions{.Read_User, .Write_User}), os.Error(nil))
	testing.expect_value(t, os.write_entire_file(prefix_path, "wrong", os.Permissions{.Read_User, .Write_User}), os.Error(nil))
	testing.expect_value(t, os.symlink(outside, leak_path), os.Error(nil))

	host_history_root = strings.clone(host_dir, context.allocator)
	defer {
		delete(host_history_root)
		host_history_root = ""
	}
	testing.expect_value(t, host_report_text(fmt.tprintf("%s%s", STATION_FILE_PREFIX, inside_path)), "safe")
	testing.expect(t, strings.contains(host_report_text(fmt.tprintf("%s%s", STATION_FILE_PREFIX, leak_path)), "Report location refused"), "symlink report must be refused")
	testing.expect(t, strings.contains(host_report_text(fmt.tprintf("%s%s", STATION_FILE_PREFIX, prefix_path)), "Report location refused"), "reports-other prefix must be refused")
}

@(test)
test_host_relays_station_reports_to_stdout :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-relay-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	state, _ := filepath.join({root, "state"})
	fifo, _ := filepath.join({root, "in.fifo"})
	out_path, _ := filepath.join({root, "host.out"})
	err_path, _ := filepath.join({root, "host.err"})
	agent, _ := filepath.join({root, "agent.sh"})
	received, _ := filepath.join({root, "received.log"})
	defer delete(state)
	defer delete(fifo)
	defer delete(out_path)
	defer delete(err_path)
	defer delete(agent)
	defer delete(received)
	testing.expect_value(t, os.write_entire_file(agent, FAKE_STATION_AGENT, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))

	binary := build_test_binary(t, root)
	defer delete(binary)
	script_state, script_out, script_err, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", HOST_RELAY_SCRIPT, "relay-test", state, fifo, out_path, err_path, agent, received, binary},
	}, context.allocator)
	defer delete(script_out)
	defer delete(script_err)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, script_state.success, string(script_err))

	out_data, out_err := os.read_entire_file(out_path, context.allocator)
	defer delete(out_data)
	testing.expect_value(t, out_err, os.Error(nil))
	out := string(out_data)
	testing.expect(t, strings.contains(out, `{"type":"ready","protocol":1}`), out)
	testing.expect(t, strings.contains(out, `{"type":"station_report","request_id":"order-1","shot_id":"shot-a","kind":"turn_done","description":"turn 1"}`), out)
	testing.expect(t, strings.contains(out, `{"type":"station_report","request_id":"order-1","shot_id":"shot-a","kind":"agent_exited","description":"Agent exited"}`), out)
	testing.expect(t, strings.contains(out, `{"type":"stopped","request_id":"done"}`), out)

	history, history_err := os.read_entire_file(fmt.tprintf("%s/host/order-1/history.ndjson", state), context.allocator)
	defer delete(history)
	testing.expect_value(t, history_err, os.Error(nil))
	testing.expect(t, strings.contains(string(history), `"kind":"turn_done"`) && strings.contains(string(history), `"kind":"agent_exited"`), string(history))
}

@(test)
test_host_relays_full_long_station_report :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-relay-long-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	state, _ := filepath.join({root, "state"})
	fifo, _ := filepath.join({root, "in.fifo"})
	out_path, _ := filepath.join({root, "host.out"})
	err_path, _ := filepath.join({root, "host.err"})
	agent, _ := filepath.join({root, "agent.sh"})
	received, _ := filepath.join({root, "received.log"})
	defer delete(state)
	defer delete(fifo)
	defer delete(out_path)
	defer delete(err_path)
	defer delete(agent)
	defer delete(received)
	testing.expect_value(t, os.write_entire_file(agent, FAKE_LONG_AGENT, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	binary := build_test_binary(t, root)
	defer delete(binary)

	script_state, script_out, script_err, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", HOST_RELAY_SCRIPT, "relay-test", state, fifo, out_path, err_path, agent, received, binary},
	}, context.allocator)
	defer delete(script_out)
	defer delete(script_err)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, script_state.success, string(script_err))

	out_data, out_err := os.read_entire_file(out_path, context.allocator)
	defer delete(out_data)
	testing.expect_value(t, out_err, os.Error(nil))
	out := string(out_data)
	full := strings.repeat("x", 3000, context.temp_allocator)
	expected := strings.concatenate({`"kind":"turn_done","description":"`, full, `"}`}, context.temp_allocator)
	testing.expect(t, strings.contains(out, expected), out[:min(len(out), 400)])
}

// Two hosts must not evict each other's socket.
HOST_LOCK_SCRIPT :: `set -eu
state="$1"; fifo="$2"; out="$3"; err="$4"; second_out="$5"; second_err="$6"; bin="$7"
export CS_STATE_DIR="$state"
mkfifo "$fifo"
"$bin" host < "$fifo" > "$out" 2> "$err" &
pid=$!
exec 3> "$fifo"
sock="$state/host/activity.sock"
i=0
while [ ! -S "$sock" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i+1)); done
set +e
printf '%s\n' '{"type":"shutdown","request_id":"second"}' | CS_STATE_DIR="$state" "$bin" host > "$second_out" 2> "$second_err"
second_status=$?
set -e
test "$second_status" -ne 0
printf '%s\n' '{"type":"sessions"}' >&3
sleep 0.2
printf '%s\n' '{"type":"shutdown","request_id":"first"}' >&3
exec 3>&-
wait "$pid"
`

@(test)
test_second_host_keeps_first_host_socket_alive :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-host-lock-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	state, _ := filepath.join({root, "state"})
	fifo, _ := filepath.join({root, "in.fifo"})
	out_path, _ := filepath.join({root, "host.out"})
	err_path, _ := filepath.join({root, "host.err"})
	second_out, _ := filepath.join({root, "second.out"})
	second_err, _ := filepath.join({root, "second.err"})
	defer delete(state)
	defer delete(fifo)
	defer delete(out_path)
	defer delete(err_path)
	defer delete(second_out)
	defer delete(second_err)

	binary := build_test_binary(t, root)
	defer delete(binary)
	script_state, script_out, script_err, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", HOST_LOCK_SCRIPT, "host-lock-test", state, fifo, out_path, err_path, second_out, second_err, binary},
	}, context.allocator)
	defer delete(script_out)
	defer delete(script_err)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, script_state.success, string(script_err))

	out_data, out_err := os.read_entire_file(out_path, context.allocator)
	defer delete(out_data)
	second_data, second_read_err := os.read_entire_file(second_err, context.allocator)
	defer delete(second_data)
	testing.expect_value(t, out_err, os.Error(nil))
	testing.expect_value(t, second_read_err, os.Error(nil))
	testing.expect(t, strings.contains(string(out_data), `{"type":"sessions","sessions":[]}`), string(out_data))
	testing.expect(t, strings.contains(string(second_data), "another host is already running"), string(second_data))
}

// A killed host leaves its socket file behind; the next host must still start.
@(test)
test_host_starts_over_stale_socket_file :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-stale-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	state, _ := filepath.join({root, "state"})
	defer delete(state)
	host_dir, _ := filepath.join({state, "host"})
	defer delete(host_dir)
	testing.expect_value(t, os.make_directory_all(host_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	stale, _ := filepath.join({host_dir, "activity.sock"})
	defer delete(stale)
	testing.expect_value(t, os.write_entire_file(stale, "", os.Permissions{.Read_User, .Write_User}), os.Error(nil))
	binary := build_test_binary(t, root)
	defer delete(binary)

	state_run, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `printf '%s\n' '{"type":"shutdown","request_id":"done"}' | CS_STATE_DIR="$1" "$2" host`, "stale-test", state, binary},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state_run.success, string(stderr))
	testing.expect(t, strings.contains(string(stdout), `{"type":"ready","protocol":1}`), string(stdout))
}
