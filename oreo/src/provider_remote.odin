package oreo

// A Provider that runs one model turn through the host transport, with the pi
// extension on the other end of the pipe. complete writes one `model_request`
// JSON line, then blocks reading lines until the matching `model_response` or
// `model_error` arrives. Unrelated lines caught while waiting (an `event`,
// another request's reply) are handled and skipped.
//
// Provider_Request carries only the conversation, so the resolved provider,
// model, and thinking level for the work item ride in the transport state: the
// caller allocates one Provider_Remote_State per work item, sets those three
// fields, puts its own transport data (a pipe, file, or buffer) in `data`, and
// points Remote_Transport.user at the state. That is also the rawptr the
// Provider hands back to complete, so one state is one provider is one turn.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"

// Remote_Transport is the host transport: one JSON object per line. `user` is
// the transport state. write_line writes one already-framed line and reports
// whether it reached the peer. read_line returns the next line, owned by the
// caller, or ok=false when the timeout elapses or the transport closes.
Remote_Transport :: struct {
	user:       rawptr,
	write_line: proc(user: rawptr, line: string) -> bool,
	read_line:  proc(user: rawptr, timeout_ms: int) -> (line: string, ok: bool),
}

// Provider_Remote_State is the per-work-item state a remote provider needs.
// provider, model, and thinking are the work item's resolved settings: the
// model name and thinking level the bridge must use.
Provider_Remote_State :: struct {
	provider: string,
	model:    string,
	thinking: string,
	// data is the caller's transport data. The write_line and read_line
	// callbacks receive `user` (a pointer to this state) and reach their data
	// here.
	data: rawptr,
	// transport, events, and timeout_ms are recorded by provider_remote.
	transport:  Remote_Transport,
	events:     Event_Fn,
	timeout_ms: int,
}

// provider_remote returns a Provider whose complete sends model requests
// through `transport` and waits for the reply. The state lives in
// transport.user; the callbacks reach their own data through its `data` field.
provider_remote :: proc(transport: Remote_Transport, events: Event_Fn = nil, timeout_ms: int = 120_000) -> Provider {
	if state := cast(^Provider_Remote_State)transport.user; state != nil {
		state.transport = transport
		state.events = events
		state.timeout_ms = timeout_ms
	}
	return Provider{user = transport.user, complete = provider_remote_complete}
}

@(private)
provider_remote_complete :: proc(
	user: rawptr,
	request: Provider_Request,
	allocator: runtime.Allocator,
) -> (Provider_Response, Provider_Error) {
	state := cast(^Provider_Remote_State)user
	if state == nil {
		return {}, provider_remote_error(.Unavailable, "the remote provider has no state", allocator)
	}
	if state.transport.write_line == nil || state.transport.read_line == nil {
		return {}, provider_remote_error(.Unavailable, "the remote provider has no transport callbacks", allocator)
	}

	id_buffer: [48]byte
	request_id := provider_remote_next_request_id(id_buffer[:])
	if !provider_remote_write_request(state, request, request_id, allocator) {
		return {}, provider_remote_error(.Unavailable, "the model request could not be written to pi", allocator)
	}
	return provider_remote_wait(state, request_id, allocator)
}

// provider_remote_write_request encodes the request and writes exactly one line.
@(private)
provider_remote_write_request :: proc(
	state: ^Provider_Remote_State,
	request: Provider_Request,
	request_id: string,
	allocator: runtime.Allocator,
) -> bool {
	encoded, marshal_err := provider_remote_encode_request(state, request, request_id, allocator)
	if marshal_err != nil {
		return false
	}
	defer delete(encoded, allocator)

	line := make([]byte, len(encoded) + 1, allocator)
	defer delete(line, allocator)
	copy(line, encoded)
	line[len(encoded)] = '\n'
	return state.transport.write_line(state.transport.user, transmute(string)(line))
}

// provider_remote_wait reads and handles lines until the matching reply
// arrives. Every returned line is owned by this proc.
@(private)
provider_remote_wait :: proc(
	state: ^Provider_Remote_State,
	request_id: string,
	allocator: runtime.Allocator,
) -> (Provider_Response, Provider_Error) {
	for {
		line, ok := state.transport.read_line(state.transport.user, state.timeout_ms)
		if !ok {
			return {}, provider_remote_error(.Unavailable, "no reply arrived from pi before the timeout", allocator)
		}
		completed, response, provider_err := provider_remote_handle_line(state, line, request_id, allocator)
		delete(line, context.allocator)
		if completed {
			return response, provider_err
		}
	}
}

// provider_remote_handle_line decodes one line. completed is true only when the
// line is this request's model_response or model_error.
@(private)
provider_remote_handle_line :: proc(
	state: ^Provider_Remote_State,
	line: string,
	request_id: string,
	allocator: runtime.Allocator,
) -> (completed: bool, response: Provider_Response, provider_err: Provider_Error) {
	decoded: Remote_Line
	if json.unmarshal_string(line, &decoded, allocator = allocator) != nil {
		return false, {}, {}
	}
	defer provider_remote_line_destroy(&decoded, allocator)

	switch decoded.message_type {
	case "model_response":
		if decoded.request_id != request_id {
			return false, {}, {}
		}
		response := Provider_Response{
			text       = decoded.text,
			tool_calls = provider_remote_take_tool_calls(&decoded, allocator),
		}
		decoded.text = ""
		return true, response, {}
	case "model_error":
		if decoded.request_id != request_id {
			return false, {}, {}
		}
		return true, {}, provider_remote_reason_error(decoded.reason, allocator)
	case "event":
		provider_remote_deliver_event(state, &decoded)
		return false, {}, {}
	}
	return false, {}, {}
}

// provider_remote_take_tool_calls moves the decoded tool calls into the type the
// loop expects. The strings move with them; only the decoded slice is freed.
@(private)
provider_remote_take_tool_calls :: proc(decoded: ^Remote_Line, allocator: runtime.Allocator) -> []Agent_Tool_Call {
	if len(decoded.tool_calls) == 0 {
		return nil
	}
	calls := make([]Agent_Tool_Call, len(decoded.tool_calls), allocator)
	for call, index in decoded.tool_calls {
		calls[index] = Agent_Tool_Call{id = call.id, name = call.name, arguments_json = call.arguments_json}
	}
	delete(decoded.tool_calls, allocator)
	decoded.tool_calls = nil
	return calls
}

@(private)
provider_remote_deliver_event :: proc(state: ^Provider_Remote_State, decoded: ^Remote_Line) {
	event_emit(state.events, Agent_Event{
		kind         = provider_remote_event_kind(decoded.kind),
		session_id   = decoded.session_id,
		work_item_id = decoded.work_item_id,
		message      = decoded.message,
	})
}

// provider_remote_encode_request marshals the model_request. Every value is
// encoded by the JSON encoder, so a free-form message cannot break the framing.
@(private)
provider_remote_encode_request :: proc(
	state: ^Provider_Remote_State,
	request: Provider_Request,
	request_id: string,
	allocator: runtime.Allocator,
) -> ([]byte, json.Marshal_Error) {
	messages := make([]Remote_Request_Message, len(request.messages), allocator)
	defer {
		for message in messages {
			delete(message.tool_calls, allocator)
		}
		delete(messages, allocator)
	}
	for source, index in request.messages {
		calls := make([]Remote_Request_Tool_Call, len(source.tool_calls), allocator)
		for call, call_index in source.tool_calls {
			calls[call_index] = Remote_Request_Tool_Call{
				id             = call.id,
				name           = call.name,
				arguments_json = call.arguments_json,
			}
		}
		messages[index] = Remote_Request_Message{
			role         = provider_remote_role(source.role),
			text         = source.text,
			tool_calls   = calls,
			tool_call_id = source.tool_call_id,
		}
	}

	tools := make([]Remote_Request_Tool, len(request.tools), allocator)
	defer delete(tools, allocator)
	for source, index in request.tools {
		tools[index] = Remote_Request_Tool{
			name            = source.name,
			description     = source.description,
			parameters_json = source.parameters_json,
		}
	}

	return json.marshal(Remote_Model_Request{
		message_type = "model_request",
		request_id   = request_id,
		provider     = state.provider,
		model        = state.model,
		thinking     = state.thinking,
		messages     = messages,
		tools        = tools,
	}, allocator = allocator)
}

@(private)
provider_remote_role :: proc(role: Agent_Message_Role) -> string {
	switch role {
	case .System:
		return "system"
	case .User:
		return "user"
	case .Assistant:
		return "assistant"
	case .Tool:
		return "tool"
	}
	return "user"
}

@(private)
provider_remote_event_kind :: proc(kind: string) -> Agent_Event_Kind {
	switch kind {
	case TRANSPORT_EVENT_NEEDS_INPUT:
		return .Needs_Input
	case TRANSPORT_EVENT_FINAL_RESULT:
		return .Final_Result
	}
	return .Progress
}

// provider_remote_request_serial makes every request id unique per call.
@(private)
provider_remote_request_serial: u64

@(private)
provider_remote_next_request_id :: proc(buffer: []byte) -> string {
	serial := sync.atomic_add(&provider_remote_request_serial, u64(1))
	return fmt.bprintf(buffer, "oreo-%d", serial)
}

@(private)
provider_remote_error :: proc(kind: Provider_Error_Kind, message: string, allocator: runtime.Allocator) -> Provider_Error {
	owned, _ := strings.clone(message, allocator)
	return Provider_Error{kind = kind, message = owned}
}

@(private)
provider_remote_reason_error :: proc(reason: string, allocator: runtime.Allocator) -> Provider_Error {
	if len(reason) == 0 {
		return provider_remote_error(.Unavailable, "pi reported a model error with no reason", allocator)
	}
	return Provider_Error{
		kind    = .Unavailable,
		message = fmt.aprintf("pi reported a model error: %s", reason, allocator = allocator),
	}
}

// The decoded wire shapes. One struct covers every line type the provider can
// see; fields that do not belong to a line stay empty.
@(private)
Remote_Response_Tool_Call :: struct {
	id:             string,
	name:           string,
	arguments_json: string,
}

@(private)
Remote_Line :: struct {
	message_type: string `json:"type"`,
	request_id:   string,
	text:         string,
	tool_calls:   []Remote_Response_Tool_Call,
	reason:       string,
	kind:         string,
	session_id:   string,
	work_item_id: string,
	message:      string,
}

@(private)
provider_remote_line_destroy :: proc(decoded: ^Remote_Line, allocator: runtime.Allocator) {
	delete(decoded.message_type, allocator)
	delete(decoded.request_id, allocator)
	delete(decoded.text, allocator)
	for call in decoded.tool_calls {
		delete(call.id, allocator)
		delete(call.name, allocator)
		delete(call.arguments_json, allocator)
	}
	delete(decoded.tool_calls, allocator)
	delete(decoded.reason, allocator)
	delete(decoded.kind, allocator)
	delete(decoded.session_id, allocator)
	delete(decoded.work_item_id, allocator)
	delete(decoded.message, allocator)
	decoded^ = {}
}

// The encoded wire shapes. A nil slice encodes as [], so an absent tool list
// still sends a JSON array.
@(private)
Remote_Request_Tool_Call :: struct {
	id:             string,
	name:           string,
	arguments_json: string,
}

@(private)
Remote_Request_Message :: struct {
	role:         string,
	text:         string,
	tool_calls:   []Remote_Request_Tool_Call,
	tool_call_id: string,
}

@(private)
Remote_Request_Tool :: struct {
	name:            string,
	description:     string,
	parameters_json: string,
}

@(private)
Remote_Model_Request :: struct {
	message_type: string `json:"type"`,
	request_id:   string,
	provider:     string,
	model:        string,
	thinking:     string,
	messages:     []Remote_Request_Message,
	tools:        []Remote_Request_Tool,
}
