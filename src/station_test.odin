package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

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

	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)

	// The reply reaches the Station on stdin; closing stdin then ends the session.
	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `printf '%s\n' "second question" | odin run src -- station --report "$1" --station shot-a --brew order-1 --prompt "first question" -- sh "$2" "$3"`, "station-test", socket, agent, received},
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
