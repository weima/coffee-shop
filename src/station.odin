package main

import "core:bufio"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"

// Station runs one agent session and relays between it and the parent Coffee
// Shop. The agent speaks the Pi RPC subset on stdin/stdout (prompt in, agent_end
// out), so Pi or Oreo can run here if it speaks the same subset. Lines typed
// into the Station's stdin are replies, sent to the agent as follow-up prompts.
// Closing stdin ends the session.
// shortcut: one report per turn, truncated to the activity limit; no
// needs_input or completion distinction and no reply queue yet.

Station_Prompt :: struct {
	type:              string `json:"type"`,
	message:           string `json:"message"`,
	streamingBehavior: string `json:"streamingBehavior,omitempty"`,
}

Station_Relay :: struct {
	input: ^os.File,
	agent: ^os.File,
}

run_station :: proc(report_path, station_id, brew_id, prompt: string, agent: []string) -> int {
	sender, sender_ok := activity_sender_open(report_path)
	if !sender_ok {
		write_error("could not reach the parent Coffee Shop")
		return 1
	}
	defer activity_sender_close(&sender)

	agent_in_read, agent_in_write, in_err := os.pipe()
	agent_out_read, agent_out_write, out_err := os.pipe()
	if in_err != nil || out_err != nil {
		write_error("could not create the agent pipes")
		return 1
	}
	process, start_err := os.process_start(os.Process_Desc{
		command = agent,
		stdin = agent_in_read,
		stdout = agent_out_write,
		stderr = os.stderr,
	})
	_ = os.close(agent_in_read)
	_ = os.close(agent_out_write)
	defer os.close(agent_out_read)
	if start_err != nil {
		_ = os.close(agent_in_write)
		write_error("could not start the agent")
		return 1
	}
	if !station_write_prompt(agent_in_write, prompt, "") {
		write_error("could not send the first prompt to the agent")
		return 1
	}

	relay := new(Station_Relay)
	relay.input = os.stdin
	relay.agent = agent_in_write
	_ = thread.create_and_start_with_data(relay, station_relay_replies, self_cleanup = true)

	parser: Pi_Event_State
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_reader(agent_out_read))
	defer bufio.reader_destroy(&reader)
	for {
		line, read_err := bufio.reader_read_string(&reader, '\n', context.temp_allocator)
		if read_err != nil {
			break
		}
		text := strings.trim_right(line, "\r\n")
		_ = pi_event_consume(&parser, text)
		if station_is_turn_end(text) {
			report := parser.final_report
			if report == "" {
				report = "Turn finished without a text reply."
			}
			station_report(&sender, brew_id, station_id, "turn_done", report)
		}
		free_all(context.temp_allocator)
	}

	state, wait_err := os.process_wait(process)
	station_report(&sender, brew_id, station_id, "agent_exited", "Agent exited")
	if wait_err != nil || !state.success {
		return 1
	}
	return 0
}

// Every stdin line is a reply. End of stdin closes the agent's input, which ends
// the agent and therefore the Station.
station_relay_replies :: proc(data: rawptr) {
	relay := (^Station_Relay)(data)
	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, os.to_reader(relay.input))
	defer bufio.scanner_destroy(&scanner)
	for bufio.scanner_scan(&scanner) {
		text := strings.trim_space(bufio.scanner_text(&scanner))
		if text == "" {
			continue
		}
		if !station_write_prompt(relay.agent, text, "followUp") {
			break
		}
	}
	_ = os.close(relay.agent)
}

station_write_prompt :: proc(file: ^os.File, message, behavior: string) -> bool {
	data, err := json.marshal(Station_Prompt{type = "prompt", message = message, streamingBehavior = behavior}, {}, context.temp_allocator)
	if err != nil {
		return false
	}
	if _, write_err := os.write(file, data); write_err != nil {
		return false
	}
	_, newline_err := os.write_string(file, "\n")
	return newline_err == nil
}

station_is_turn_end :: proc(line: string) -> bool {
	value, err := json.parse_string(line, .JSON, false, context.temp_allocator)
	if err != .None {
		return false
	}
	root, ok := value.(json.Object)
	return ok && pi_event_string(root, "type") == "agent_end"
}

station_report :: proc(sender: ^Activity_Sender, brew_id, station_id, kind, description: string) {
	text := description
	if len(text) > ACTIVITY_MAX_DESCRIPTION {
		text = text[:ACTIVITY_MAX_DESCRIPTION]
	}
	_ = activity_sender_send(sender, Activity_Message{
		brew_id = brew_id,
		shot_id = station_id,
		kind = kind,
		description = text,
		timestamp_ns = time.now()._nsec,
	})
}
