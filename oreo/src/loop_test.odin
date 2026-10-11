package oreo

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"

// Fake_Provider is the in-file scriptable provider. It serves a deep clone of
// the scripted responses (repeating the last one when the script runs out) and
// records a deep clone of every request it receives.
Fake_Provider :: struct {
	script:        []Provider_Response,
	index:         int,
	received:      [dynamic][]Agent_Message,
	error_kind:    Provider_Error_Kind,
	error_message: string,
}

fake_provider :: proc(script: []Provider_Response) -> Fake_Provider {
	return Fake_Provider{script = script}
}

fake_provider_complete :: proc(
	user: rawptr,
	request: Provider_Request,
	allocator: runtime.Allocator,
) -> (Provider_Response, Provider_Error) {
	fake := cast(^Fake_Provider)user
	if fake.error_kind != .None {
		return {}, Provider_Error{
			kind = fake.error_kind,
			message = fake_clone_string(fake.error_message, allocator),
		}
	}
	if len(fake.script) == 0 {
		return {}, Provider_Error{kind = .Invalid_Response, message = fake_clone_string("no scripted response", allocator)}
	}
	recorded := fake_clone_messages(request.messages, allocator)
	if _, append_err := append(&fake.received, recorded); append_err != nil {
		destroy_agent_messages(recorded, allocator)
		return {}, Provider_Error{kind = .Out_Of_Memory, message = fake_clone_string("could not record the request", allocator)}
	}
	// Continuing to ask for tools after the script runs out is deliberate: it
	// lets a test prove the turn limit stops the loop.
	index := min(fake.index, len(fake.script) - 1)
	fake.index += 1
	response := Provider_Response{
		text = fake_clone_string(fake.script[index].text, allocator),
		tool_calls = fake_clone_tool_calls(fake.script[index].tool_calls, allocator),
	}
	return response, Provider_Error{}
}

fake_provider_destroy :: proc(fake: ^Fake_Provider) {
	for recorded in fake.received {
		destroy_agent_messages(recorded, context.allocator)
	}
	delete(fake.received)
	fake^ = Fake_Provider{}
}

// fake_tool_invoke echoes the exact tool name and arguments so a recorded
// request proves what the tool received.
fake_tool_invoke :: proc(name, arguments_json: string, allocator: runtime.Allocator) -> Tool_Outcome {
	return Tool_Outcome{ok = true, output = fmt.aprintf("ran %s with %s", name, arguments_json, allocator = allocator)}
}

@(private)
fake_text_response :: proc(text: string) -> Provider_Response {
	return Provider_Response{text = fake_clone_string(text, context.allocator)}
}

@(private)
fake_tool_call :: proc(id, name, arguments_json: string) -> Agent_Tool_Call {
	return Agent_Tool_Call{id = id, name = name, arguments_json = arguments_json}
}

@(private)
fake_clone_string :: proc(value: string, allocator: runtime.Allocator) -> string {
	cloned, _ := strings.clone(value, allocator)
	return cloned
}

@(private)
fake_clone_messages :: proc(messages: []Agent_Message, allocator: runtime.Allocator) -> []Agent_Message {
	if len(messages) == 0 {
		return nil
	}
	copied := make([]Agent_Message, len(messages), allocator)
	for message, index in messages {
		copied[index] = Agent_Message{
			role = message.role,
			text = fake_clone_string(message.text, allocator),
			tool_calls = fake_clone_tool_calls(message.tool_calls, allocator),
			tool_call_id = fake_clone_string(message.tool_call_id, allocator),
		}
	}
	return copied
}

@(private)
fake_clone_tool_calls :: proc(calls: []Agent_Tool_Call, allocator: runtime.Allocator) -> []Agent_Tool_Call {
	if len(calls) == 0 {
		return nil
	}
	copied := make([]Agent_Tool_Call, len(calls), allocator)
	for call, index in calls {
		copied[index] = Agent_Tool_Call{
			id = fake_clone_string(call.id, allocator),
			name = fake_clone_string(call.name, allocator),
			arguments_json = fake_clone_string(call.arguments_json, allocator),
		}
	}
	return copied
}

// fake_destroy_responses frees the strings of a scripted response list. The
// list itself is a local literal and is not owned by the allocator.
@(private)
fake_destroy_responses :: proc(responses: []Provider_Response) {
	for response in responses {
		delete(response.text, context.allocator)
		for call in response.tool_calls {
			delete(call.id, context.allocator)
			delete(call.name, context.allocator)
			delete(call.arguments_json, context.allocator)
		}
		delete(response.tool_calls, context.allocator)
	}
}

@(test)
test_agent_run_text_only_response_finishes_in_one_turn :: proc(t: ^testing.T) {
	script := []Provider_Response{fake_text_response("all done")}
	defer fake_destroy_responses(script)
	fake := fake_provider(script)
	defer fake_provider_destroy(&fake)

	result, err := agent_run(
		Provider{user = rawptr(&fake), complete = fake_provider_complete},
		Tool_Set{invoke = fake_tool_invoke},
		"do the thing",
		0,
	)
	defer agent_result_destroy(&result)
	defer agent_error_destroy(&err)

	testing.expect_value(t, err.kind, Agent_Error_Kind.None)
	testing.expect_value(t, result.text, "all done")
	testing.expect_value(t, result.turns, 1)
	testing.expect_value(t, len(fake.received), 1)
	testing.expect_value(t, len(fake.received[0]), 1)
	testing.expect_value(t, fake.received[0][0].role, Agent_Message_Role.User)
	testing.expect_value(t, fake.received[0][0].text, "do the thing")
}

@(test)
test_agent_run_tool_call_round_trip :: proc(t: ^testing.T) {
	script := []Provider_Response{
		Provider_Response{
			tool_calls = fake_clone_tool_calls(
				[]Agent_Tool_Call{fake_tool_call("call-1", "read", `{"path":"a.txt"}`)},
				context.allocator,
			),
		},
		fake_text_response("tool said hello"),
	}
	defer fake_destroy_responses(script)
	fake := fake_provider(script)
	defer fake_provider_destroy(&fake)

	result, err := agent_run(
		Provider{user = rawptr(&fake), complete = fake_provider_complete},
		Tool_Set{invoke = fake_tool_invoke},
		"read a file",
		0,
	)
	defer agent_result_destroy(&result)
	defer agent_error_destroy(&err)

	testing.expect_value(t, err.kind, Agent_Error_Kind.None)
	testing.expect_value(t, result.text, "tool said hello")
	testing.expect_value(t, result.turns, 2)
	testing.expect_value(t, len(fake.received), 2)

	second := fake.received[1]
	testing.expect_value(t, len(second), 3)
	testing.expect_value(t, second[0].role, Agent_Message_Role.User)
	testing.expect_value(t, second[1].role, Agent_Message_Role.Assistant)
	testing.expect_value(t, len(second[1].tool_calls), 1)
	testing.expect_value(t, second[1].tool_calls[0].id, "call-1")
	testing.expect_value(t, second[2].role, Agent_Message_Role.Tool)
	testing.expect_value(t, second[2].tool_call_id, "call-1")
	testing.expect_value(t, second[2].text, `ran read with {"path":"a.txt"}`)
}

@(test)
test_agent_run_stops_at_max_turns :: proc(t: ^testing.T) {
	script := []Provider_Response{
		Provider_Response{
			text = fake_clone_string("let me check", context.allocator),
			tool_calls = fake_clone_tool_calls(
				[]Agent_Tool_Call{fake_tool_call("call-1", "read", `{"path":"a.txt"}`)},
				context.allocator,
			),
		},
	}
	defer fake_destroy_responses(script)
	fake := fake_provider(script)
	defer fake_provider_destroy(&fake)

	result, err := agent_run(
		Provider{user = rawptr(&fake), complete = fake_provider_complete},
		Tool_Set{invoke = fake_tool_invoke},
		"keep going",
		1,
	)
	defer agent_result_destroy(&result)
	defer agent_error_destroy(&err)

	testing.expect_value(t, err.kind, Agent_Error_Kind.None)
	testing.expect_value(t, result.turns, 1)
	testing.expect_value(t, result.text, "let me check")
	testing.expect_value(t, len(fake.received), 1)
}

@(test)
test_agent_run_provider_error_is_reported :: proc(t: ^testing.T) {
	fake := fake_provider(nil)
	fake.error_kind = .Unavailable
	fake.error_message = "provider is offline"
	defer fake_provider_destroy(&fake)

	result, err := agent_run(
		Provider{user = rawptr(&fake), complete = fake_provider_complete},
		Tool_Set{invoke = fake_tool_invoke},
		"anything",
		0,
	)
	defer agent_result_destroy(&result)
	defer agent_error_destroy(&err)

	testing.expect_value(t, err.kind, Agent_Error_Kind.Provider)
	testing.expect_value(t, err.message, "provider is offline")
	testing.expect_value(t, result.turns, 0)
	testing.expect_value(t, len(result.messages), 0)
}

@(test)
test_agent_run_two_tool_calls_append_two_tool_messages :: proc(t: ^testing.T) {
	script := []Provider_Response{
		Provider_Response{
			tool_calls = fake_clone_tool_calls(
				[]Agent_Tool_Call{
					fake_tool_call("first", "read", `{"path":"one"}`),
					fake_tool_call("second", "write", `{"path":"two"}`),
				},
				context.allocator,
			),
		},
		fake_text_response("both done"),
	}
	defer fake_destroy_responses(script)
	fake := fake_provider(script)
	defer fake_provider_destroy(&fake)

	result, err := agent_run(
		Provider{user = rawptr(&fake), complete = fake_provider_complete},
		Tool_Set{invoke = fake_tool_invoke},
		"do two things",
		0,
	)
	defer agent_result_destroy(&result)
	defer agent_error_destroy(&err)

	testing.expect_value(t, err.kind, Agent_Error_Kind.None)
	testing.expect_value(t, result.turns, 2)
	testing.expect_value(t, len(result.messages), 5)

	second := fake.received[1]
	testing.expect_value(t, len(second), 4)
	testing.expect_value(t, second[1].role, Agent_Message_Role.Assistant)
	testing.expect_value(t, len(second[1].tool_calls), 2)
	testing.expect_value(t, second[2].tool_call_id, "first")
	testing.expect_value(t, second[2].text, `ran read with {"path":"one"}`)
	testing.expect_value(t, second[3].tool_call_id, "second")
	testing.expect_value(t, second[3].text, `ran write with {"path":"two"}`)
}
