package oreo

import "base:runtime"
import "core:strings"

// This slice is the provider-neutral agent loop: no store, no pool, no events,
// no network. It mirrors Pi's turn/tool-call behavior over injected procedures.

Agent_Message_Role :: enum {
	System,
	User,
	Assistant,
	Tool,
}

// Agent_Tool_Call names one requested tool call. The caller owns the strings.
Agent_Tool_Call :: struct {
	id, name, arguments_json: string,
}

// Agent_Message is one conversation entry. The caller owns text, tool_calls,
// and tool_call_id.
Agent_Message :: struct {
	role:         Agent_Message_Role,
	text:         string,
	tool_calls:   []Agent_Tool_Call,
	tool_call_id: string,
}

// Tool_Spec describes one tool the provider may call. The caller owns the
// strings.
Tool_Spec :: struct {
	name, description, parameters_json: string,
}

// Provider_Request is one provider turn's input. The loop owns the request for
// the duration of the complete call.
Provider_Request :: struct {
	messages: []Agent_Message,
	tools:    []Tool_Spec,
}

// Provider_Response is one provider turn's output. complete allocates the
// strings with the allocator it is given and transfers ownership to the loop.
Provider_Response :: struct {
	text:       string,
	tool_calls: []Agent_Tool_Call,
}

Provider_Error_Kind :: enum {
	None,
	Unavailable,
	Invalid_Response,
	Out_Of_Memory,
}

// Provider_Error owns its message text. Call provider_error_destroy on every
// value, including a zero value, when it is no longer needed.
Provider_Error :: struct {
	kind:    Provider_Error_Kind,
	message: string,
}

// Provider is one injected model source. complete returns strings allocated
// with the given allocator; ownership moves to the caller.
Provider :: struct {
	user:     rawptr,
	complete: proc(user: rawptr, request: Provider_Request, allocator: runtime.Allocator) -> (Provider_Response, Provider_Error),
}

// Tool_Outcome is one tool invocation result. The tool allocates output with
// the allocator it is given; ownership moves to the loop.
Tool_Outcome :: struct {
	ok:     bool,
	output: string,
}

Tool_Fn :: #type proc(name, arguments_json: string, allocator: runtime.Allocator) -> Tool_Outcome

// Tool_Set is the tools offered to the provider and the procedure that runs
// them. The caller owns specs.
Tool_Set :: struct {
	specs:  []Tool_Spec,
	invoke: Tool_Fn,
}

Agent_Error_Kind :: enum {
	None,
	Provider,
	Invalid_Request,
	Out_Of_Memory,
}

// Agent_Error owns its message text. Call agent_error_destroy on every value,
// including a zero value, when it is no longer needed.
Agent_Error :: struct {
	kind:    Agent_Error_Kind,
	message: string,
}

// Agent_Run_Result owns every string it contains. Call agent_result_destroy
// when it is no longer needed.
Agent_Run_Result :: struct {
	text:     string,
	turns:    int,
	messages: []Agent_Message,
}

AGENT_DEFAULT_MAX_TURNS :: 25

// agent_run drives the conversation until the provider answers without tool
// calls or max_turns is reached. max_turns <= 0 means AGENT_DEFAULT_MAX_TURNS.
// A provider error becomes an Agent_Error with kind .Provider; a missing
// provider complete or tools invoke is .Invalid_Request.
agent_run :: proc(
	provider: Provider,
	tools: Tool_Set,
	initial_prompt: string,
	max_turns: int,
	allocator := context.allocator,
) -> (Agent_Run_Result, Agent_Error) {
	if provider.complete == nil {
		return {}, agent_error(.Invalid_Request, "provider has no complete procedure", allocator)
	}
	if tools.invoke == nil {
		return {}, agent_error(.Invalid_Request, "tool set has no invoke procedure", allocator)
	}

	limit := max_turns
	if limit <= 0 {
		limit = AGENT_DEFAULT_MAX_TURNS
	}

	messages: [dynamic]Agent_Message
	messages.allocator = allocator
	result_text: string
	committed := false
	defer {
		if !committed {
			delete(result_text, allocator)
			destroy_agent_messages(messages[:], allocator)
		}
	}

	prompt, prompt_err := strings.clone(initial_prompt, allocator)
	if prompt_err != nil {
		return {}, agent_error(.Out_Of_Memory, "could not allocate the initial prompt", allocator)
	}
	if _, append_err := append(&messages, Agent_Message{role = .User, text = prompt}); append_err != nil {
		delete(prompt, allocator)
		return {}, agent_error(.Out_Of_Memory, "could not allocate the conversation", allocator)
	}

	turns := 0
	for turns < limit {
		response, provider_err := provider.complete(
			provider.user,
			Provider_Request{messages = messages[:], tools = tools.specs},
			allocator,
		)
		if provider_err.kind != .None {
			// Ownership of the error message moves to the caller-visible error.
			return {}, Agent_Error{kind = .Provider, message = provider_err.message}
		}
		turns += 1

		// The response text is kept as the run result and also recorded in the
		// assistant message, so each is owned independently.
		assistant_text, text_err := strings.clone(response.text, allocator)
		if text_err != nil {
			destroy_tool_calls(response.tool_calls, allocator)
			delete(response.text, allocator)
			return {}, agent_error(.Out_Of_Memory, "could not allocate the assistant message", allocator)
		}
		delete(result_text, allocator)
		result_text = response.text

		if _, append_err := append(&messages, Agent_Message{
			role = .Assistant,
			text = assistant_text,
			tool_calls = response.tool_calls,
		}); append_err != nil {
			delete(assistant_text, allocator)
			destroy_tool_calls(response.tool_calls, allocator)
			return {}, agent_error(.Out_Of_Memory, "could not allocate the conversation", allocator)
		}

		if len(response.tool_calls) == 0 {
			break
		}
		for call in response.tool_calls {
			outcome := tools.invoke(call.name, call.arguments_json, allocator)
			call_id, id_err := strings.clone(call.id, allocator)
			if id_err != nil {
				delete(outcome.output, allocator)
				return {}, agent_error(.Out_Of_Memory, "could not allocate the tool call id", allocator)
			}
			if _, append_err := append(&messages, Agent_Message{
				role = .Tool,
				text = outcome.output,
				tool_call_id = call_id,
			}); append_err != nil {
				delete(outcome.output, allocator)
				delete(call_id, allocator)
				return {}, agent_error(.Out_Of_Memory, "could not allocate the conversation", allocator)
			}
		}
	}

	committed = true
	return Agent_Run_Result{text = result_text, turns = turns, messages = messages[:]}, Agent_Error{}
}

provider_error_destroy :: proc(err: ^Provider_Error, allocator := context.allocator) {
	delete(err.message, allocator)
	err^ = Provider_Error{}
}

agent_error_destroy :: proc(err: ^Agent_Error, allocator := context.allocator) {
	delete(err.message, allocator)
	err^ = Agent_Error{}
}

agent_result_destroy :: proc(result: ^Agent_Run_Result, allocator := context.allocator) {
	delete(result.text, allocator)
	destroy_agent_messages(result.messages, allocator)
	result^ = Agent_Run_Result{}
}

@(private)
destroy_agent_messages :: proc(messages: []Agent_Message, allocator: runtime.Allocator) {
	for index in 0 ..< len(messages) {
		message := &messages[index]
		delete(message.text, allocator)
		delete(message.tool_call_id, allocator)
		destroy_tool_calls(message.tool_calls, allocator)
	}
	delete(messages, allocator)
}

@(private)
destroy_tool_calls :: proc(calls: []Agent_Tool_Call, allocator: runtime.Allocator) {
	for index in 0 ..< len(calls) {
		call := &calls[index]
		delete(call.id, allocator)
		delete(call.name, allocator)
		delete(call.arguments_json, allocator)
	}
	delete(calls, allocator)
}

@(private)
agent_error :: proc(kind: Agent_Error_Kind, message: string, allocator: runtime.Allocator) -> Agent_Error {
	owned, _ := strings.clone(message, allocator)
	return Agent_Error{kind = kind, message = owned}
}
