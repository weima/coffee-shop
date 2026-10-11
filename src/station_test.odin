package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Each test builds its own binary: parallel `odin run` calls share one output path
// and can run each other's build. The caller owns the returned path.
build_test_binary :: proc(t: ^testing.T, root: string) -> string {
	binary, _ := filepath.join({root, "coffee-shop"})
	build_state, _, build_stderr, build_err := os.process_exec(os.Process_Desc{
		command = {"odin", "build", "src", fmt.tprintf("-out:%s", binary)},
	}, context.allocator)
	defer delete(build_stderr)
	testing.expect_value(t, build_err, os.Error(nil))
	testing.expect(t, build_state.success, string(build_stderr))
	return binary
}

// Fake agent: logs each stdin line, then answers every prompt with one agent_end
// whose text counts the turns. It exits when its stdin closes.
FAKE_STATION_AGENT :: `#!/bin/sh
n=0
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$1"
  n=$((n+1))
  printf '%s\n' "{\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"turn $n\"}]}]}"
done
`

@(test)
test_station_reports_each_turn_and_relays_replies :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-station-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "report.sock"})
	defer delete(socket)
	agent, _ := filepath.join({root, "agent.sh"})
	defer delete(agent)
	received, _ := filepath.join({root, "received.log"})
	defer delete(received)
	write_err := os.write_entire_file(agent, FAKE_STATION_AGENT, os.Permissions{.Read_User, .Write_User, .Execute_User})
	testing.expect_value(t, write_err, os.Error(nil))

	binary := build_test_binary(t, root)
	defer delete(binary)
	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)

	// The reply reaches the Station on stdin; closing stdin then ends the session.
	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `printf '%s\n' "second question" | "$4" station --report "$1" --station shot-a --brew order-1 --prompt "first question" -- sh "$2" "$3"`, "station-test", socket, agent, received, binary},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state.success, string(stderr))

	turns: [dynamic]string
	defer {
		for turn in turns {
			delete(turn)
		}
		delete(turns)
	}
	exited := false
	for {
		result := activity_listener_receive(&listener)
		if result.kind == .Unavailable {
			break
		}
		if result.kind != .Message {
			continue
		}
		switch result.message.kind {
		case "turn_done":
			append(&turns, strings.clone(result.message.description))
		case "agent_exited":
			exited = true
		}
		destroy_struct(&result.message)
	}
	testing.expect_value(t, len(turns), 2)
	if len(turns) == 2 {
		testing.expect_value(t, turns[0], "turn 1")
		testing.expect_value(t, turns[1], "turn 2")
	}
	testing.expect(t, exited, "Station should report the agent exit")

	log_data, log_err := os.read_entire_file(received, context.allocator)
	defer delete(log_data)
	testing.expect_value(t, log_err, os.Error(nil))
	log := string(log_data)
	testing.expect(t, strings.contains(log, `"message":"first question"`), log)
	testing.expect(t, strings.contains(log, `"message":"second question"`) && strings.contains(log, `"streamingBehavior":"followUp"`), log)
	_ = fmt.tprintf
}

// Fake agent that asks a select dialog for its first prompt and answers the reply
// with agent_end. Every stdin line is logged to $1.
FAKE_DIALOG_AGENT :: `#!/bin/sh
n=0
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$1"
  case "$line" in
  *'"extension_ui_response"'*)
    n=$((n+1))
    printf '%s\n' "{\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"answered $n\"}]}]}"
    ;;
  *)
    printf '%s\n' '{"type":"extension_ui_request","id":"d1","method":"select","title":"Pick one","options":["Allow","Block"]}'
    ;;
  esac
done
`

@(test)
test_station_forwards_dialog_and_applies_reply :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-dialog-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "report.sock"})
	agent, _ := filepath.join({root, "agent.sh"})
	received, _ := filepath.join({root, "received.log"})
	defer delete(socket)
	defer delete(agent)
	defer delete(received)
	testing.expect_value(t, os.write_entire_file(agent, FAKE_DIALOG_AGENT, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	binary := build_test_binary(t, root)
	defer delete(binary)

	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)

	// The answer is typed one second after start, once the dialog is pending.
	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `( sleep 1; printf '%s\n' "Allow"; sleep 1 ) | "$4" station --report "$1" --station shot-a --brew order-1 --prompt "first question" -- sh "$2" "$3"`, "dialog-test", socket, agent, received, binary},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state.success, string(stderr))

	needs_input: string
	turn: string
	for {
		result := activity_listener_receive(&listener)
		if result.kind == .Unavailable {
			break
		}
		if result.kind != .Message {
			continue
		}
		switch result.message.kind {
		case "needs_input":
			needs_input = strings.clone(result.message.description)
		case "turn_done":
			turn = strings.clone(result.message.description)
		}
		destroy_struct(&result.message)
	}
	defer delete(needs_input)
	defer delete(turn)
	testing.expect_value(t, needs_input, "Pick one [Allow / Block]")
	testing.expect_value(t, turn, "answered 1")

	log_data, log_err := os.read_entire_file(received, context.allocator)
	defer delete(log_data)
	testing.expect_value(t, log_err, os.Error(nil))
	log := string(log_data)
	testing.expect(t, strings.contains(log, `{"type":"extension_ui_response","id":"d1","value":"Allow"}`), log)
}

@(test)
test_dialog_response_matches_method :: proc(t: ^testing.T) {
	options := []string{"Allow", "Block"}
	select_dialog := Station_Dialog{active = true, id = "d1", method = "select", options = options}
	testing.expect_value(t, station_dialog_response(select_dialog, "Block"), `{"type":"extension_ui_response","id":"d1","value":"Block"}`)
	testing.expect_value(t, station_dialog_response(select_dialog, "Maybe"), `{"type":"extension_ui_response","id":"d1","cancelled":true}`)

	confirm_dialog := Station_Dialog{active = true, id = "d2", method = "confirm"}
	testing.expect_value(t, station_dialog_response(confirm_dialog, "YES"), `{"type":"extension_ui_response","id":"d2","confirmed":true}`)
	testing.expect_value(t, station_dialog_response(confirm_dialog, "n"), `{"type":"extension_ui_response","id":"d2","confirmed":false}`)
	testing.expect_value(t, station_dialog_response(confirm_dialog, "later"), `{"type":"extension_ui_response","id":"d2","cancelled":true}`)

	input_dialog := Station_Dialog{active = true, id = "d3", method = "input"}
	testing.expect_value(t, station_dialog_response(input_dialog, "hello"), `{"type":"extension_ui_response","id":"d3","value":"hello"}`)
}

@(test)
test_station_report_rejects_invalid_name_before_creating_reports :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-report-name-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "activity.sock"})
	defer delete(socket)
	path, ok := station_write_report_file(socket, "order-1", "../escape", "turn_done", "report")
	defer delete(path)
	testing.expect(t, !ok, "an invalid station id must not write a report")
	reports, _ := filepath.join({root, "reports"})
	defer delete(reports)
	testing.expect(t, !os.exists(reports), "invalid names must not create the reports directory")
}

@(test)
test_station_report_paths_include_unique_names :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-report-collision-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "activity.sock"})
	defer delete(socket)
	first, first_ok := station_write_report_file(socket, "order-1", "shot-a", "turn_done", "first")
	defer delete(first)
	second, second_ok := station_write_report_file(socket, "order-1", "shot-a", "turn_done", "second")
	defer delete(second)
	testing.expect(t, first_ok && second_ok, "both reports should be written")
	testing.expect(t, first != second, "report paths must be unique")
	if first_ok {
		first_data, first_err := os.read_entire_file(first, context.allocator)
		defer delete(first_data)
		testing.expect_value(t, first_err, os.Error(nil))
		testing.expect_value(t, string(first_data), "first")
	}
	if second_ok {
		second_data, second_err := os.read_entire_file(second, context.allocator)
		defer delete(second_data)
		testing.expect_value(t, second_err, os.Error(nil))
		testing.expect_value(t, string(second_data), "second")
	}
}

@(test)
test_station_report_falls_back_when_reports_directory_is_unwritable :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-report-fallback-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "activity.sock"})
	reports, _ := filepath.join({root, "reports"})
	defer delete(socket)
	defer delete(reports)
	testing.expect_value(t, os.make_directory_all(reports, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	testing.expect_value(t, os.change_mode(reports, os.Permissions{.Read_User, .Execute_User}), os.Error(nil))

	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)
	sender, sender_ok := activity_sender_open(socket)
	testing.expect(t, sender_ok)
	defer activity_sender_close(&sender)

	long := strings.repeat("x", ACTIVITY_MAX_DESCRIPTION+100, context.temp_allocator)
	station_report(&sender, "order-1", "shot-a", "turn_done", long)
	result := activity_listener_receive(&listener)
	fallback := ""
	if result.kind == .Message {
		fallback = strings.clone(result.message.description)
	}
	destroy_struct(&result.message)
	defer delete(fallback)
	testing.expect(t, fallback != "" && !strings.has_prefix(fallback, STATION_FILE_PREFIX), fallback)
	testing.expect_value(t, len(fallback), ACTIVITY_MAX_DESCRIPTION)
}

// Fake agent whose every turn answers with a 3000-character report.
FAKE_LONG_AGENT :: `#!/bin/sh
while IFS= read -r line; do
  text=$(head -c 3000 /dev/zero | tr '\0' 'x')
  printf '%s\n' "{\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"$text\"}]}]}"
done
`

@(test)
test_station_writes_long_report_to_file :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-long-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "activity.sock"})
	agent, _ := filepath.join({root, "agent.sh"})
	defer delete(socket)
	defer delete(agent)
	testing.expect_value(t, os.write_entire_file(agent, FAKE_LONG_AGENT, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	binary := build_test_binary(t, root)
	defer delete(binary)

	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)

	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `(sleep 1) | "$2" station --report "$1" --station shot-a --brew order-1 --prompt "hi" -- sh "$3"`, "long-test", socket, binary, agent},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state.success, string(stderr))

	description: string
	for {
		result := activity_listener_receive(&listener)
		if result.kind == .Unavailable {
			break
		}
		if result.kind == .Message && result.message.kind == "turn_done" {
			description = strings.clone(result.message.description)
		}
		destroy_struct(&result.message)
	}
	defer delete(description)
	testing.expect(t, strings.has_prefix(description, STATION_FILE_PREFIX), description)
	if !strings.has_prefix(description, STATION_FILE_PREFIX) {
		return
	}
	report, read_err := os.read_entire_file(description[len(STATION_FILE_PREFIX):], context.allocator)
	defer delete(report)
	testing.expect_value(t, read_err, os.Error(nil))
	testing.expect_value(t, len(report), 3000)
}
