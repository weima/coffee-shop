package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"

PI_EVENT_DESCRIPTION_MAX :: 120
PI_EVENT_LINE_MAX :: 64 * 1024

Pi_Event_State :: struct {
	last_kind: string,
	last_description: string,
	final_report: string,
}

pi_event_consume :: proc(state: ^Pi_Event_State, line: string) -> bool {
	if len(line) == 0 || len(line) > PI_EVENT_LINE_MAX {
		return false
	}
	value, parse_err := json.parse_string(line, .JSON, false, context.temp_allocator)
	if parse_err != .None {
		return false
	}
	defer json.destroy_value(value, context.temp_allocator)

	root, ok := value.(json.Object)
	if !ok {
		return false
	}
	type_name := pi_event_string(root, "type")
	if type_name == "message_end" {
		message_value, found := root["message"]
		message, ok := message_value.(json.Object)
		if found && ok && pi_event_string(message, "role") == "assistant" {
			report, report_ok := pi_event_message_report(message)
			if report_ok {
				delete(state.final_report)
				state.final_report = report
			} else {
				delete(report)
			}
		}
		return false
	}
	kind, description, useful := pi_event_activity(root, type_name)
	if !useful {
		return false
	}

	changed := pi_event_set_activity(state, kind, description)
	if type_name == "agent_end" {
		report, report_ok := pi_event_final_report(root)
		if report_ok {
			delete(state.final_report)
			state.final_report = report
		} else {
			delete(report)
		}
	}
	return changed
}

pi_event_state_destroy :: proc(state: ^Pi_Event_State) {
	delete(state.last_kind)
	delete(state.last_description)
	delete(state.final_report)
	state^ = Pi_Event_State{}
}

pi_event_string :: proc(object: json.Object, key: string) -> string {
	value, found := object[key]
	if !found {
		return ""
	}
	text, ok := value.(json.String)
	if !ok {
		return ""
	}
	return text
}

pi_event_activity :: proc(
	root: json.Object,
	type_name: string,
) -> (kind, description: string, useful: bool) {
	switch type_name {
	case "tool_execution_start", "tool_execution_end":
		tool_name := pi_event_string(root, "toolName")
		if tool_name == "" {
			return
		}
		if len(tool_name) > PI_EVENT_DESCRIPTION_MAX-16 {
			tool_name = tool_name[:PI_EVENT_DESCRIPTION_MAX-16]
		}
		if type_name == "tool_execution_start" {
			return "tool_start", fmt.tprintf("Running tool: %s", tool_name), true
		}
		return "tool_end", fmt.tprintf("Finished tool: %s", tool_name), true
	case "turn_start":
		return "turn_start", "Starting turn", true
	case "turn_end":
		return "turn_end", "Finished turn", true
	case "agent_end":
		return "agent_end", "Worker finished", true
	case "message_update":
		event_value, found := root["assistantMessageEvent"]
		if !found {
			return
		}
		event, ok := event_value.(json.Object)
		if !ok || pi_event_string(event, "type") != "text_delta" {
			return
		}
		if pi_event_string(event, "delta") == "" {
			return
		}
		return "response", "Drafting response", true
	}
	return
}

pi_event_set_activity :: proc(state: ^Pi_Event_State, kind, description: string) -> bool {
	if state.last_kind == kind && state.last_description == description {
		return false
	}
	kind_copy, kind_err := strings.clone(kind)
	description_copy, description_err := strings.clone(description)
	if kind_err != nil || description_err != nil {
		delete(kind_copy)
		delete(description_copy)
		return false
	}
	delete(state.last_kind)
	delete(state.last_description)
	state.last_kind = kind_copy
	state.last_description = description_copy
	return true
}

pi_event_final_report :: proc(root: json.Object) -> (report: string, ok: bool) {
	messages_value, found := root["messages"]
	if !found {
		return "", false
	}
	messages, valid := messages_value.(json.Array)
	if !valid {
		return "", false
	}

	last_assistant: json.Object
	found_assistant := false
	for message_value in messages {
		message, message_ok := message_value.(json.Object)
		if !message_ok || pi_event_string(message, "role") != "assistant" {
			continue
		}
		last_assistant = message
		found_assistant = true
	}
	if !found_assistant {
		return "", false
	}

	return pi_event_message_report(last_assistant)
}

pi_event_message_report :: proc(message: json.Object) -> (report: string, ok: bool) {
	content_value, found := message["content"]
	if !found {
		return "", false
	}
	content, valid := content_value.(json.Array)
	if !valid {
		return "", false
	}

	text_blocks: [dynamic]string
	text_blocks.allocator = context.temp_allocator
	defer delete(text_blocks)
	for block_value in content {
		block, block_ok := block_value.(json.Object)
		if !block_ok || pi_event_string(block, "type") != "text" {
			continue
		}
		text := pi_event_string(block, "text")
		if text != "" {
			_, append_err := append(&text_blocks, text)
			if append_err != nil {
				return "", false
			}
		}
	}
	if len(text_blocks) == 0 {
		return "", true
	}

	joined_report, err := strings.join(text_blocks[:], "\n")
	if err != nil {
		return "", false
	}
	return joined_report, true
}
