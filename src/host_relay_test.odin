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
"$bin" host --impl=odin < "$fifo" > "$out" 2> "$err" &
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
	testing.expect(t, host_output_contains(out, `{"type":"ready","protocol":1}`), out)
	testing.expect(t, host_output_contains(out, `{"type":"station_report","request_id":"order-1","shot_id":"shot-a","kind":"turn_done","description":"turn 1"}`), out)
	testing.expect(t, host_output_contains(out, `{"type":"station_report","request_id":"order-1","shot_id":"shot-a","kind":"agent_exited","description":"Agent exited"}`), out)
	testing.expect(t, host_output_contains(out, `{"type":"stopped","request_id":"done"}`), out)

	history, history_err := os.read_entire_file(fmt.tprintf("%s/host/order-1/history.ndjson", state), context.allocator)
	defer delete(history)
	testing.expect_value(t, history_err, os.Error(nil))
	testing.expect(t, strings.contains(string(history), `"kind":"turn_done"`) && strings.contains(string(history), `"kind":"agent_exited"`), string(history))
	spooled, _ := os.read_all_directory_by_path(fmt.tprintf("%s/host/spool", state), context.temp_allocator)
	testing.expect_value(t, len(spooled), 0) // every relayed report leaves the spool
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
	testing.expect(t, host_output_contains(out, expected), out[:min(len(out), 400)])
}

// Two hosts must not evict each other's socket.
HOST_LOCK_SCRIPT :: `set -eu
state="$1"; fifo="$2"; out="$3"; err="$4"; second_out="$5"; second_err="$6"; bin="$7"
export CS_STATE_DIR="$state"
mkfifo "$fifo"
"$bin" host --impl=odin < "$fifo" > "$out" 2> "$err" &
pid=$!
exec 3> "$fifo"
sock="$state/host/activity.sock"
i=0
while [ ! -S "$sock" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i+1)); done
set +e
printf '%s\n' '{"type":"shutdown","request_id":"second"}' | CS_STATE_DIR="$state" "$bin" host --impl=odin > "$second_out" 2> "$second_err"
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
	testing.expect(t, host_output_contains(string(out_data), `{"type":"sessions","sessions":[]}`), string(out_data))
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
		command = {"sh", "-c", `printf '%s\n' '{"type":"shutdown","request_id":"done"}' | CS_STATE_DIR="$1" "$2" host --impl=odin`, "stale-test", state, binary},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state_run.success, string(stderr))
	testing.expect(t, host_output_contains(string(stdout), `{"type":"ready","protocol":1}`), string(stdout))
}

// Starts the host with its stdin on a FIFO and sources the actions fragment as soon
// as the host is ready, so a test can control exactly when each write arrives.
HOST_STDIN_SCRIPT :: `set -u
state="$1"; fifo="$2"; out="$3"; err="$4"; bin="$5"; actions="$6"
export CS_STATE_DIR="$state"
mkfifo "$fifo"
"$bin" host --impl=odin < "$fifo" > "$out" 2> "$err" &
pid=$!
exec 3> "$fifo"
sock="$state/host/activity.sock"
i=0
while [ ! -S "$sock" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
. "$actions"
exec 3>&-
wait $pid
`

// Runs the host with stdin on a FIFO and feeds it the actions fragment, which writes
// to its inherited fd 3. The caller owns run.root, run.state and run.out through
// host_contract_destroy.
run_host_writes :: proc(t: ^testing.T, prefix, actions: string) -> (run: Host_Contract_Run) {
	root, make_err := os.make_directory_temp(TEMP_DIR, prefix, context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	run.root = root
	// run.state is owned by the caller (host_contract_destroy), so it must come from a
	// real allocator; the temp strings below are owned by context.temp_allocator.
	run.state = fmt.aprintf("%s/state", root)
	fifo := fmt.tprintf("%s/in.fifo", root)
	out_path := fmt.tprintf("%s/host.out", root)
	err_path := fmt.tprintf("%s/host.err", root)
	actions_path := fmt.tprintf("%s/actions.sh", root)
	rwx := os.Permissions{.Read_User, .Write_User, .Execute_User}
	testing.expect_value(t, os.write_entire_file(actions_path, actions, rwx), os.Error(nil))

	binary := build_test_binary(t, root)
	defer delete(binary)
	script_state, script_out, script_err, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", HOST_STDIN_SCRIPT, "stdin-test", run.state, fifo, out_path, err_path, binary, actions_path},
	}, context.allocator)
	defer delete(script_out)
	defer delete(script_err)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, script_state.success, string(script_err))

	out_data, out_err := os.read_entire_file(out_path, context.allocator)
	testing.expect_value(t, out_err, os.Error(nil))
	run.out = string(out_data)
	return
}

// Two complete request lines in one write are both handled, in the order written.
@(test)
test_host_handles_two_request_lines_in_one_write :: proc(t: ^testing.T) {
	first := `{"type":"sessions","request_id":"one"}`
	second := `{"type":"sessions","request_id":"two"}`
	shutdown := `{"type":"shutdown","request_id":"done"}`
	actions := fmt.aprintf("printf '%%s\\n%%s\\n' '%s' '%s' >&3\nsleep 0.4\nprintf '%%s\\n' '%s' >&3\n", first, second, shutdown)
	defer delete(actions)
	run := run_host_writes(t, "coffee-shop-stdin-two-*", actions)
	defer host_contract_destroy(run)
	one := fmt.tprintf(`{{"type":"received","request_id":"one","bytes":%d}}`, len(first))
	two := fmt.tprintf(`{{"type":"received","request_id":"two","bytes":%d}}`, len(second))
	testing.expect(t, host_output_contains(run.out, one) && host_output_contains(run.out, two), run.out)
	testing.expect(t, strings.index(strip_all_event_timestamps(run.out), one) < strings.index(strip_all_event_timestamps(run.out), two), run.out)
	testing.expect_value(t, host_output_count(run.out, `{"type":"sessions","sessions":[]}`), 2)
	testing.expect(t, host_output_contains(run.out, `{"type":"stopped","request_id":"done"}`), run.out)
}

// One request line split across two writes is buffered until its newline and then
// handled exactly once. The fragment checks stdout mid-run to prove the first half
// was held rather than handled alone.
@(test)
test_host_handles_request_line_split_across_writes :: proc(t: ^testing.T) {
	split := `{"type":"bogus","request_id":"split"}`
	half := len(split) / 2
	shutdown := `{"type":"shutdown","request_id":"done"}`
	actions := fmt.aprintf(`printf '%%s' '%s' >&3
i=0
while ! grep -q '"type":"ready"' "$out" && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
sleep 0.4
if ! grep -q '"type":"ready"' "$out"; then echo "host was not ready" >&2; exit 1; fi
if grep -q '"type":"received"' "$out"; then echo "unterminated line was handled" >&2; exit 1; fi
printf '%%s\n' '%s' >&3
sleep 0.4
printf '%%s\n' '%s' >&3
`, split[:half], split[half:], shutdown)
	defer delete(actions)
	run := run_host_writes(t, "coffee-shop-stdin-split-*", actions)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, fmt.tprintf(`{{"type":"received","request_id":"split","bytes":%d}}`, len(split))), run.out)
	// Received plus the unknown-request error: handled once, not once per write.
	testing.expect_value(t, host_output_count(run.out, `"request_id":"split"`), 2)
	testing.expect_value(t, host_output_count(run.out, `"reason":"unknown request type"`), 1)
	testing.expect(t, host_output_contains(run.out, `{"type":"stopped","request_id":"done"}`), run.out)
}

// Every line, valid or not, still produces exactly one received event before it is
// handled, with its own byte length.
@(test)
test_host_receives_every_line_written :: proc(t: ^testing.T) {
	first := `{"type":"sessions","request_id":"recv-a"}`
	bad := "not json"
	last := `{"type":"shutdown","request_id":"recv-b"}`
	actions := fmt.aprintf("printf '%%s\\n' '%s' >&3\nsleep 0.3\nprintf '%%s\\n' '%s' >&3\nsleep 0.3\nprintf '%%s\\n' '%s' >&3\n", first, bad, last)
	defer delete(actions)
	run := run_host_writes(t, "coffee-shop-stdin-recv-*", actions)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, fmt.tprintf(`{{"type":"received","request_id":"recv-a","bytes":%d}}`, len(first))), run.out)
	testing.expect(t, host_output_contains(run.out, fmt.tprintf(`{{"type":"received","request_id":"","bytes":%d}}`, len(bad))), run.out)
	testing.expect(t, host_output_contains(run.out, fmt.tprintf(`{{"type":"received","request_id":"recv-b","bytes":%d}}`, len(last))), run.out)
	testing.expect(t, host_output_contains(run.out, `{"type":"stopped","request_id":"recv-b"}`), run.out)
}

// A request that always produces exactly one terminal reply: a cancel with no
// Station running gives one cancelled event. With its received event that is two
// request-id references per request.
host_load_request_line :: proc(id: string) -> string {
	return fmt.tprintf(`{{"type":"cancel","request_id":"%s"}}`, id)
}

// One valid request in its own FIFO write.
host_load_write :: proc(b: ^strings.Builder, id: string) {
	strings.write_string(b, fmt.tprintf("printf '%%s\\n' '%s' >&3\n", host_load_request_line(id)))
}

// A contiguous block of valid requests, each in its own write.
host_load_range :: proc(b: ^strings.Builder, ids: ^[dynamic]string, prefix: string, from, to: int) {
	for i in from..<to {
		id := fmt.tprintf("%s-%03d", prefix, i)
		append(ids, id)
		host_load_write(b, id)
	}
}

// A request line split across two writes. A gate request is written in the same
// write as the first half, and the second half waits until the gate's reply shows
// in stdout: that reply proves the host read and buffered the first half, so the
// split is ordered by the FIFO instead of guessed with a sleep.
host_load_split :: proc(b: ^strings.Builder, ids: ^[dynamic]string, tag: string, index: int) {
	gate_id := fmt.tprintf("%s-gate-%03d", tag, index)
	split_id := fmt.tprintf("%s-split-%03d", tag, index)
	append(ids, gate_id)
	append(ids, split_id)
	line := host_load_request_line(split_id)
	half := len(line) / 2
	strings.write_string(b, fmt.tprintf("printf '%%s\\n%%s' '%s' '%s' >&3\n", host_load_request_line(gate_id), line[:half]))
	marker := fmt.tprintf(`"type":"cancelled","request_id":"%s"`, gate_id)
	strings.write_string(b, fmt.tprintf("i=0\nwhile ! grep -F -q '%s' \"$out\" && [ $i -lt 500 ]; do sleep 0.02; i=$((i+1)); done\n", marker))
	strings.write_string(b, fmt.tprintf("printf '%%s\\n' '%s' >&3\n", line[half:]))
}

// Drives the host with 250 requests in the write patterns a line reader can
// mishandle, then asserts that every one produced exactly one received event and
// exactly one terminal reply. A missing received is the original dropped-request
// bug; a duplicate is a different one. Five over-long lines must be dropped
// without stopping the reader.
@(test)
test_host_reads_and_answers_every_request_under_load :: proc(t: ^testing.T) {
	ids := make([dynamic]string, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)

	// 1. 120 requests, each written on its own.
	host_load_range(&b, &ids, "many", 0, 120)

	// 2. 40 complete lines delivered in one write.
	burst := strings.builder_make(context.temp_allocator)
	for i in 0..<40 {
		id := fmt.tprintf("burst-%03d", i)
		append(&ids, id)
		if i > 0 {
			strings.write_byte(&burst, '\n')
		}
		strings.write_string(&burst, host_load_request_line(id))
	}
	strings.write_string(&b, fmt.tprintf("printf '%%s\\n' '%s' >&3\n", strings.to_string(burst)))

	// 3. 6 lines split across two writes, with a pause enforced by the gate.
	for i in 0..<6 {
		host_load_split(&b, &ids, "p3", i)
	}

	// 4. 3 over-long lines interleaved with valid requests; each over-long line is
	// dropped and the valid requests after it still work.
	for g in 0..<3 {
		strings.write_string(&b, "long=$(head -c 70000 /dev/zero | tr '\\000' x)\nprintf '%s\\n' \"$long\" >&3\n")
		host_load_range(&b, &ids, fmt.tprintf("long-%d", g), 0, 12)
	}

	// 5. A mixed stream: valid requests around an over-long line split across two
	// writes and a split line delivered while the over-long line is in flight.
	host_load_range(&b, &ids, "mix", 0, 10)
	strings.write_string(&b, "long=$(head -c 40000 /dev/zero | tr '\\000' x)\nprintf '%s' \"$long\" >&3\n")
	strings.write_string(&b, "long=$(head -c 30000 /dev/zero | tr '\\000' x)\nprintf '%s\\n' \"$long\" >&3\n")
	host_load_range(&b, &ids, "mix", 10, 20)
	host_load_split(&b, &ids, "p5", 0)
	host_load_range(&b, &ids, "mix", 20, 30)
	strings.write_string(&b, "long=$(head -c 70000 /dev/zero | tr '\\000' x)\nprintf '%s\\n' \"$long\" >&3\n")
	host_load_range(&b, &ids, "mix", 30, 40)
	// An explicit shutdown ends the loop, as the rest of the harness does.
	strings.write_string(&b, "printf '%s\\n' '{\"type\":\"shutdown\",\"request_id\":\"load-done\"}' >&3\n")

	run := run_host_writes(t, "coffee-shop-load-*", strings.to_string(b))
	defer host_contract_destroy(run)
	out := run.out

	total := len(ids)
	testing.expect_value(t, total, 250)
	// Every valid request plus the shutdown line was received; each valid request
	// got its one terminal reply.
	testing.expect_value(t, host_output_count(out, `{"type":"received"`), total + 1)
	testing.expect_value(t, host_output_count(out, `{"type":"cancelled"`), total)
	testing.expect(t, host_output_contains(out, `{"type":"stopped","request_id":"load-done"}`), out)
	// Each over-long line was actually sent and dropped, so the reader did not stop
	// before the valid requests that followed it.
	testing.expect_value(t, host_output_count(out, "exceeds the 65536-byte limit"), 5)

	for id in ids {
		received := strings.concatenate({`{"type":"received","request_id":"`, id, `"`}, context.temp_allocator)
		terminal := strings.concatenate({`{"type":"cancelled","request_id":"`, id, `"`}, context.temp_allocator)
		received_count := host_output_count(out, received)
		terminal_count := host_output_count(out, terminal)
		testing.expectf(t, received_count == 1, "request %s: %d received events, expected exactly 1", id, received_count)
		testing.expectf(t, terminal_count == 1, "request %s: %d terminal replies, expected exactly 1", id, terminal_count)
	}
}

// A report a Station spooled before the host died is relayed, recorded in the
// history and removed from the spool on the next start, without reading a pane.
@(test)
test_host_recovers_unrelayed_spooled_report :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-recover-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	state := fmt.tprintf("%s/state", root)
	spool := fmt.tprintf("%s/host/spool", state)
	rwx := os.Permissions{.Read_User, .Write_User, .Execute_User}
	testing.expect_value(t, os.make_directory_all(spool, rwx), os.Error(nil))
	entry := fmt.tprintf("%s/0001-a.json", spool)
	line := `{"brew_id":"order-1","shot_id":"shot-a","kind":"turn_done","description":"finished while the host was down","timestamp_ns":1,"spool":"0001-a.json"}`
	testing.expect_value(t, os.write_entire_file(entry, line, rwx), os.Error(nil))

	binary := build_test_binary(t, root)
	defer delete(binary)
	run_state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `printf '%s\n' '{"type":"shutdown","request_id":"done"}' | CS_STATE_DIR="$1" "$2" host --impl=odin`, "recover-test", state, binary},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, run_state.success, string(stderr))
	testing.expect(t, host_output_contains(string(stdout), `{"type":"station_report","request_id":"order-1","shot_id":"shot-a","kind":"turn_done","description":"finished while the host was down"}`), string(stdout))
	history, history_err := os.read_entire_file(fmt.tprintf("%s/host/order-1/history.ndjson", state), context.allocator)
	defer delete(history)
	testing.expect_value(t, history_err, os.Error(nil))
	testing.expect(t, strings.contains(string(history), "finished while the host was down"), string(history))
	testing.expect(t, !os.exists(entry), "a relayed spool entry must be removed")
}

// Recovery must keep scanning after relaying each report, even though relay uses
// temporary allocations. Each valid spool entry is observable on stdout/history.
@(test)
test_host_recovers_multiple_unrelayed_spooled_reports :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-recover-many-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	state := fmt.tprintf("%s/state", root)
	spool := fmt.tprintf("%s/host/spool", state)
	rwx := os.Permissions{.Read_User, .Write_User, .Execute_User}
	testing.expect_value(t, os.make_directory_all(spool, rwx), os.Error(nil))
	ids := [5]string{"shot-a", "shot-b", "shot-c", "shot-d", "shot-e"}
	names := [5]string{"0001-a.json", "0002-b.json", "0003-c.json", "0004-d.json", "0005-e.json"}
	for i in 0 ..< len(ids) {
		entry := fmt.tprintf("%s/%s", spool, names[i])
		line := fmt.tprintf(`{{"brew_id":"order-1","shot_id":"%s","kind":"turn_done","description":"pending %s","timestamp_ns":%d,"spool":"%s"}}`, ids[i], ids[i], i + 1, names[i])
		testing.expect_value(t, os.write_entire_file(entry, line, rwx), os.Error(nil))
	}

	binary := build_test_binary(t, root)
	defer delete(binary)
	run_state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `printf '%s\n' '{"type":"shutdown","request_id":"done"}' | CS_STATE_DIR="$1" "$2" host --impl=odin`, "recover-many-test", state, binary},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, run_state.success, string(stderr))
	out := string(stdout)
	for i in 0 ..< len(ids) {
		expected := fmt.tprintf(`{{"type":"station_report","request_id":"order-1","shot_id":"%s","kind":"turn_done","description":"pending %s"}}`, ids[i], ids[i])
		testing.expect_value(t, host_output_count(out, expected), 1)
	}
	testing.expect_value(t, host_output_count(out, `"type":"station_report"`), len(ids))

	history, history_err := os.read_entire_file(fmt.tprintf("%s/host/order-1/history.ndjson", state), context.allocator)
	defer delete(history)
	testing.expect_value(t, history_err, os.Error(nil))
	testing.expect_value(t, strings.count(string(history), `"type":"station_report"`), len(ids))
	spooled, spool_err := os.read_all_directory_by_path(spool, context.temp_allocator)
	testing.expect_value(t, spool_err, os.Error(nil))
	testing.expect_value(t, len(spooled), 0)
}

// Drives one terminal report through host_relay_message with the pool, a session and a
// queued Shot in place. A bad free (temp-allocator dequeue strings, freed pane_id) fails
// under ODIN_TEST_FAIL_ON_BAD_MEMORY. A fake herdr on PATH keeps the test off real panes.
@(test)
test_host_terminal_report_frees_only_owned_strings :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()

	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-terminal-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)
	bin_dir, _ := filepath.join({root, "bin"})
	defer delete(bin_dir)
	_ = os.make_directory_all(bin_dir, os.Permissions{.Read_User, .Write_User, .Execute_User})
	fake, _ := filepath.join({bin_dir, "herdr"})
	defer delete(fake)
	_ = os.write_entire_file(fake, "#!/bin/sh\nexit 1\n", os.Permissions{.Read_User, .Write_User, .Execute_User})
	old_path := os.get_env("PATH", context.temp_allocator)
	_ = os.set_env("PATH", fmt.tprintf("%s:%s", bin_dir, old_path))
	_ = os.set_env("CS_STATE_DIR", root)
	defer {
		_ = os.set_env("PATH", old_path)
		_ = os.unset_env("CS_STATE_DIR")
	}
	host_history_root = strings.clone(root, context.allocator)
	defer {
		delete(host_history_root)
		host_history_root = ""
	}

	host_dispatch_init_at("ws-terminal", root)
	defer host_dispatch_cleanup(fake)
	defer {
		for s in host_sessions {
			delete(s.request_id)
			delete(s.shot_id)
			delete(s.pane_id)
		}
		delete(host_sessions)
		host_sessions = nil
	}

	// Fill the pool; the sixth Shot queues and is dequeued when shot-0 ends.
	for i in 0..<5 {
		id := fmt.aprintf("shot-%d", i)
		pane, _, _ := host_dispatch_acquire("req-1", id)
		append(&host_sessions, Host_Session{request_id = strings.clone("req-1"), shot_id = strings.clone(id), pane_id = pane})
		delete(id)
	}
	_, queued, _ := host_dispatch_acquire("req-1", "shot-queued")
	testing.expect(t, queued, "sixth Shot must queue")
	host_dispatch_queue_store_metadata("req-1", "shot-queued", "/repo", "prompt", "model", "provider", "thinking", "execute", "pi", "taste", "message", "/station")

	for kind in ([]string{"pulled", "taste_failed"}) {
		sid := "shot-0" if kind == "pulled" else "shot-1"
		host_relay_message(Activity_Message{brew_id = "req-1", shot_id = sid, kind = kind, description = "done"})
	}
	testing.expect_value(t, len(host_sessions), 3)
}
