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
