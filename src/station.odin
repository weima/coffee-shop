package main

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:terminal/ansi"
import "core:thread"
import "core:time"

// Station runs one agent session and relays between it and the parent Coffee
// Shop. The agent speaks the Pi RPC subset on stdin/stdout (prompt in, agent_end
// out), so Pi or Oreo can run here if it speaks the same subset.
//
// Lines typed into the Station's pane, or sent there by the host, are replies.
// A reply answers a pending dialog if the agent asked one; otherwise it is a
// follow-up prompt. Closing stdin ends the session.
// shortcut: one report per turn and per dialog, truncated to the activity limit;
// dialog timeouts are not tracked, so a late answer can reach the next prompt.

Station_Prompt :: struct {
	type:              string `json:"type"`,
	message:           string `json:"message"`,
	streamingBehavior: string `json:"streamingBehavior,omitempty"`,
}

Dialog_Value_Response :: struct {
	type:  string `json:"type"`,
	id:    string `json:"id"`,
	value: string `json:"value"`,
}

Dialog_Confirm_Response :: struct {
	type:      string `json:"type"`,
	id:        string `json:"id"`,
	confirmed: bool `json:"confirmed"`,
}

Dialog_Cancel_Response :: struct {
	type:      string `json:"type"`,
	id:        string `json:"id"`,
	cancelled: bool `json:"cancelled"`,
}

// A dialog the agent is blocked on. Strings are owned.
Station_Dialog :: struct {
	active:  bool,
	id:      string,
	method:  string,
	options: []string,
}

Station_Relay :: struct {
	input:   ^os.File,
	agent:   ^os.File,
	mutex:   sync.Mutex,
	dialog:  Station_Dialog,
	display: ^Station_Display,
}

run_station :: proc(report_path, station_id, brew_id, prompt: string, agent: []string) -> int {
	sender, sender_ok := activity_sender_open(report_path)
	if !sender_ok {
		write_error("could not reach the parent Coffee Shop")
		return 1
	}
	defer activity_sender_close(&sender)

	display := new(Station_Display)
	station_display_start(display, fmt.tprintf("Shot %s  ·  brew %s", station_id, brew_id))

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
	station_display_line(display, station_style(ansi.FAINT, fmt.tprintf("sent the first prompt to the agent")))

	relay := new(Station_Relay)
	relay.input = os.stdin
	relay.agent = agent_in_write
	relay.display = display
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
		station_handle_agent_line(relay, &sender, brew_id, station_id, &parser, text)
		free_all(context.temp_allocator)
	}

	state, wait_err := os.process_wait(process)
	station_display_stop(display)
	fmt.println("Agent exited.")
	station_report(&sender, brew_id, station_id, "agent_exited", "Agent exited")
	if wait_err != nil || !state.success {
		return 1
	}
	return 0
}

// UI requests are handled here. Other output updates progress, and a finished
// turn is reported to the parent.
station_handle_agent_line :: proc(
	relay: ^Station_Relay,
	sender: ^Activity_Sender,
	brew_id, station_id: string,
	parser: ^Pi_Event_State,
	text: string,
) {
	value, parse_err := json.parse_string(text, .JSON, false, context.temp_allocator)
	if parse_err == .None {
		if root, ok := value.(json.Object); ok && pi_event_string(root, "type") == "extension_ui_request" {
			// Only dialogs need handling; other UI requests are display-only.
			_ = station_dialog_request(relay, sender, brew_id, station_id, root)
			return
		}
	}

	// Any other agent output means the agent moved past a dialog it had open.
	sync.mutex_lock(&relay.mutex)
	station_dialog_clear(&relay.dialog)
	sync.mutex_unlock(&relay.mutex)

	if pi_event_consume(parser, text) && parser.last_description != "" {
		station_display_status(relay.display, parser.last_description)
	}
	if station_is_turn_end(text) {
		report := parser.final_report
		if report == "" {
			report = "Turn finished without a text reply."
		}
		station_display_line(relay.display, report)
		station_display_status(relay.display, "Waiting for your reply")
		station_report(sender, brew_id, station_id, "turn_done", report)
	}
}

// Fire-and-forget UI requests need no answer. Dialogs make the agent wait, so they
// are reported as needs_input and kept until a reply arrives.
station_dialog_request :: proc(
	relay: ^Station_Relay,
	sender: ^Activity_Sender,
	brew_id, station_id: string,
	root: json.Object,
) -> bool {
	method := pi_event_string(root, "method")
	switch method {
	case "select", "confirm", "input", "editor":
	case:
		return false
	}
	id := pi_event_string(root, "id")
	if id == "" {
		return false
	}
	title := pi_event_string(root, "title")
	options: [dynamic]string
	if options_value, found := root["options"]; found {
		if list, is_list := options_value.(json.Array); is_list {
			for item in list {
				if text, is_text := item.(json.String); is_text {
					append(&options, strings.clone(text))
				}
			}
		}
	}

	question := title
	if method == "select" && len(options) > 0 {
		question = fmt.tprintf("%s [%s]", title, strings.join(options[:], " / ", context.temp_allocator))
	}
	hint := station_style(ansi.FAINT, "  (reply in this pane or from the main agent)")
	station_display_line(relay.display, fmt.tprintf("%s%s", station_style(ansi.BOLD+";"+ansi.FG_YELLOW, fmt.tprintf("? %s", question)), hint))
	station_display_status(relay.display, "Waiting for an answer")

	sync.mutex_lock(&relay.mutex)
	station_dialog_clear(&relay.dialog)
	relay.dialog = Station_Dialog{active = true, id = strings.clone(id), method = strings.clone(method), options = options[:]}
	sync.mutex_unlock(&relay.mutex)

	station_report(sender, brew_id, station_id, "needs_input", question)
	return true
}

station_dialog_clear :: proc(dialog: ^Station_Dialog) {
	if !dialog.active {
		return
	}
	delete(dialog.id)
	delete(dialog.method)
	for option in dialog.options {
		delete(option)
	}
	delete(dialog.options)
	dialog^ = {}
}

// Every non-empty stdin line is a reply: it answers the pending dialog if there is
// one, otherwise it is a follow-up prompt. End of stdin closes the agent's input,
// which ends the agent and therefore the Station.
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

		sync.mutex_lock(&relay.mutex)
		if relay.dialog.active {
			response := station_dialog_response(relay.dialog, text)
			station_dialog_clear(&relay.dialog)
			sync.mutex_unlock(&relay.mutex)
			if !station_write_line(relay.agent, response) {
				break
			}
			continue
		}
		sync.mutex_unlock(&relay.mutex)

		if !station_write_prompt(relay.agent, text, "followUp") {
			break
		}
	}
	_ = os.close(relay.agent)
}

// Builds the agent's answer to a dialog from a typed reply. Unmatched select
// options and unclear confirm answers are cancelled rather than guessed.
station_dialog_response :: proc(dialog: Station_Dialog, reply: string) -> string {
	data: []byte
	err: json.Marshal_Error
	switch dialog.method {
	case "confirm":
		lower := strings.to_lower(reply, context.temp_allocator)
		switch lower {
		case "yes", "y":
			data, err = json.marshal(Dialog_Confirm_Response{type = "extension_ui_response", id = dialog.id, confirmed = true}, {}, context.temp_allocator)
		case "no", "n":
			data, err = json.marshal(Dialog_Confirm_Response{type = "extension_ui_response", id = dialog.id, confirmed = false}, {}, context.temp_allocator)
		case:
			data, err = json.marshal(Dialog_Cancel_Response{type = "extension_ui_response", id = dialog.id, cancelled = true}, {}, context.temp_allocator)
		}
	case "select":
		if !slice_contains(dialog.options, reply) {
			data, err = json.marshal(Dialog_Cancel_Response{type = "extension_ui_response", id = dialog.id, cancelled = true}, {}, context.temp_allocator)
			break
		}
		data, err = json.marshal(Dialog_Value_Response{type = "extension_ui_response", id = dialog.id, value = reply}, {}, context.temp_allocator)
	case:
		data, err = json.marshal(Dialog_Value_Response{type = "extension_ui_response", id = dialog.id, value = reply}, {}, context.temp_allocator)
	}
	if err != nil {
		return `{"type":"extension_ui_response","cancelled":true}`
	}
	return string(data)
}

slice_contains :: proc(items: []string, value: string) -> bool {
	for item in items {
		if item == value {
			return true
		}
	}
	return false
}

station_write_prompt :: proc(file: ^os.File, message, behavior: string) -> bool {
	data, err := json.marshal(Station_Prompt{type = "prompt", message = message, streamingBehavior = behavior}, {}, context.temp_allocator)
	if err != nil {
		return false
	}
	return station_write_line(file, string(data))
}

station_write_line :: proc(file: ^os.File, line: string) -> bool {
	if _, write_err := os.write_string(file, line); write_err != nil {
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
