package main

import "core:strings"
import "core:testing"

@(test)
test_pi_events_report_normalized_tool_and_response_activity :: proc(t: ^testing.T) {
	state: Pi_Event_State
	defer pi_event_state_destroy(&state)

	start := `{"type":"tool_execution_start","toolCallId":"call-1",` +
		`"toolName":"read","args":{"path":"secret"}}`
	testing.expect(t, pi_event_consume(&state, start))
	testing.expect_value(t, state.last_kind, "tool_start")
	testing.expect_value(t, state.last_description, "Running tool: read")
	// Arguments are never surfaced, and an identical activity is not a change.
	testing.expect(t, !strings.contains(state.last_description, "secret"))
	testing.expect(t, !pi_event_consume(&state, start))

	end := `{"type":"tool_execution_end","toolCallId":"call-1",` +
		`"toolName":"read","result":{"content":[{"type":"text",` +
		`"text":"private output"}]},"isError":false}`
	testing.expect(t, pi_event_consume(&state, end))
	testing.expect_value(t, state.last_kind, "tool_end")
	testing.expect_value(t, state.last_description, "Finished tool: read")

	turn := `{"type":"turn_start"}`
	testing.expect(t, pi_event_consume(&state, turn))
	testing.expect_value(t, state.last_description, "Starting turn")
	turn = `{"type":"turn_end","message":{"role":"assistant","content":[]},"toolResults":[]}`
	testing.expect(t, pi_event_consume(&state, turn))
	testing.expect_value(t, state.last_description, "Finished turn")

	delta := `{"type":"message_update","assistantMessageEvent":{"type":"text_delta",` +
		`"contentIndex":0,"delta":"private response"}}`
	testing.expect(t, pi_event_consume(&state, delta))
	testing.expect_value(t, state.last_kind, "response")
	testing.expect_value(t, state.last_description, "Drafting response")
	testing.expect(t, !strings.contains(state.last_description, "private"))
}

@(test)
test_pi_events_extracts_last_final_assistant_text_blocks :: proc(t: ^testing.T) {
	state: Pi_Event_State
	defer pi_event_state_destroy(&state)
	line := `{"type":"agent_end","messages":[` +
		`{"role":"assistant","content":[{"type":"text","text":"old"}]},` +
		`{"role":"toolResult","content":[{"type":"text","text":"ignore"}]},` +
		`{"role":"assistant","content":[{"type":"thinking","thinking":"hidden"},` +
		`{"type":"text","text":"first"},{"type":"text","text":" second"}]}]}`
	testing.expect(t, pi_event_consume(&state, line))
	testing.expect_value(t, state.final_report, "first\n second")
	testing.expect_value(t, state.last_kind, "agent_end")
	testing.expect_value(t, state.last_description, "Worker finished")

	// A final assistant message with no text clears the old report.
	line = `{"type":"agent_end","messages":[{"role":"assistant","content":[]}]}`
	_ = pi_event_consume(&state, line)
	testing.expect_value(t, state.final_report, "")
}

@(test)
test_pi_events_ignores_invalid_irrelevant_and_empty_events :: proc(t: ^testing.T) {
	state: Pi_Event_State
	defer pi_event_state_destroy(&state)
	valid := `{"type":"turn_start"}`
	testing.expect(t, pi_event_consume(&state, valid))
	before_kind := state.last_kind
	before_description := state.last_description
	too_long, _ := strings.repeat("x", PI_EVENT_LINE_MAX+1)
	defer delete(too_long)
	for line in ([]string{
		`{"type":"future_event","data":"ignored"}`,
		`{"type":"turn_start"`,
		`{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":""}}`,
		`{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"secret"}}`,
		`{"type":"tool_execution_start","args":{"x":1}}`,
		too_long,
	}) {
		testing.expect(t, !pi_event_consume(&state, line), line)
		testing.expect_value(t, state.last_kind, before_kind)
		testing.expect_value(t, state.last_description, before_description)
	}
}

@(test)
test_pi_events_keep_message_end_report_if_agent_end_exceeds_bound :: proc(t: ^testing.T) {
	state: Pi_Event_State
	defer pi_event_state_destroy(&state)
	message_end := `{"type":"message_end","message":{"role":"assistant",` +
		`"content":[{"type":"text","text":"final answer"}]}}`
	testing.expect(t, !pi_event_consume(&state, message_end))
	testing.expect_value(t, state.final_report, "final answer")

	too_long, _ := strings.repeat("x", PI_EVENT_LINE_MAX+1)
	defer delete(too_long)
	testing.expect(t, !pi_event_consume(&state, too_long))
	testing.expect_value(t, state.final_report, "final answer")
}

@(test)
test_pi_events_malformed_report_events_preserve_previous_report :: proc(t: ^testing.T) {
	state := Pi_Event_State{final_report = strings.clone("previous report")}
	defer pi_event_state_destroy(&state)
	message_end := `{"type":"message_end","message":{"role":"assistant","content":"not an array"}}`
	testing.expect(t, !pi_event_consume(&state, message_end))
	testing.expect_value(t, state.final_report, "previous report")

	agent_end := `{"type":"agent_end","messages":"not an array"}`
	testing.expect(t, pi_event_consume(&state, agent_end))
	testing.expect_value(t, state.final_report, "previous report")
}

@(test)
test_pi_events_bounds_description_and_handles_repeated_agent_end :: proc(t: ^testing.T) {
	state: Pi_Event_State
	defer pi_event_state_destroy(&state)
	name := strings.repeat("x", 1000)
	defer delete(name)
	line, _ := strings.concatenate({
		`{"type":"tool_execution_start","toolName":"`, name, `","args":{}}`,
	})
	defer delete(line)
	testing.expect(t, pi_event_consume(&state, line))
	testing.expect(t, len(state.last_description) <= PI_EVENT_DESCRIPTION_MAX)

	end, _ := strings.concatenate({
		`{"type":"agent_end","messages":[{"role":"assistant","content":[`,
		`{"type":"text","text":"done"}`, `]}]}`,
	})
	defer delete(end)
	testing.expect(t, pi_event_consume(&state, end))
	testing.expect(t, !pi_event_consume(&state, end))
	testing.expect_value(t, state.final_report, "done")
}
