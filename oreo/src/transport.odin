package oreo

// The host-process transport. Oreo runs as a long-lived separate OS process that
// the pi extension starts; this is the Odin side of the wire protocol: one JSON
// object per line in, one JSON object per line out, over a local pipe. The
// TypeScript extension is written against this protocol afterwards.

import "core:bufio"
import "core:encoding/json"
import "core:io"
import "core:strings"
import "core:sync"

// TRANSPORT_PROTOCOL is the wire protocol version the host announces in its
// ready line.
TRANSPORT_PROTOCOL :: 1

// Transport_Config is everything transport_serve needs to start serving.
Transport_Config :: struct {
	host:    Host,
	work:    Work_Fn,
	events:  Event_Fn,
	workers: int,
}

@(private)
TRANSPORT_EVENT_NEEDS_INPUT :: "needs_input"
@(private)
TRANSPORT_EVENT_PROGRESS :: "progress"
@(private)
TRANSPORT_EVENT_FINAL_RESULT :: "final_result"

@(private)
Transport_Action :: enum {
	Continue,
	Quit,
}

// Every message is one JSON object. The `type` key is written through a tag
// because `type` is an Odin keyword and cannot be a field name.
@(private)
Transport_Ready_Message :: struct {
	message_type: string `json:"type"`,
	protocol:     int,
}

@(private)
Transport_Accepted_Message :: struct {
	message_type: string `json:"type"`,
	work_item_id: string,
}

@(private)
Transport_Closed_Message :: struct {
	message_type: string `json:"type"`,
	session_id:   string,
}

@(private)
Transport_Stopped_Message :: struct {
	message_type: string `json:"type"`,
}

@(private)
Transport_Error_Message :: struct {
	message_type: string `json:"type"`,
	reason:       string,
}

@(private)
Transport_Event_Message :: struct {
	message_type: string `json:"type"`,
	kind:         string,
	session_id:   string,
	work_item_id: string,
	message:      string,
}

// Transport_State is the shared state the relay and the serving loop both use.
// The mutex serializes writes so a worker-thread event and a serving-thread
// reply never interleave inside one line.
@(private)
Transport_State :: struct {
	mutex:          sync.Mutex,
	output:         io.Writer,
	events:         Event_Fn,
	host:           Host,
	quit_requested: bool,
}

// transport_active points at the one state a running server relays through.
// transport_serve_lock makes that pointer unambiguous: one process serves one
// protocol stream, and the relay callback carries no user data of its own.
@(private)
transport_active: ^Transport_State

@(private)
transport_serve_lock: sync.Mutex

// transport_serve reads one JSON object per line from input, answers each
// request on output, and returns when the caller asks to quit or input ends.
// It owns the pool it starts; a returned error is a failure that prevented
// serving.
transport_serve :: proc(config: Transport_Config, input: io.Reader, output: io.Writer) -> Host_Error {
	sync.mutex_lock(&transport_serve_lock)
	defer sync.mutex_unlock(&transport_serve_lock)

	state, alloc_err := new(Transport_State)
	if alloc_err != nil {
		return host_error(.Out_Of_Memory, "could not allocate the transport state")
	}
	defer free(state)
	state.output = output
	state.events = config.events
	state.host = config.host

	transport_active = state
	defer transport_active = nil

	// The ready line precedes the first read, so a caller can synchronize on it.
	if ready_err := transport_write_message(state, Transport_Ready_Message{
		message_type = "ready",
		protocol     = TRANSPORT_PROTOCOL,
	}); ready_err.kind != .None {
		return ready_err
	}

	pool, pool_err := pool_start(config.host, clamp(config.workers, 1, 5), config.work, transport_relay)
	if pool_err.kind != .None {
		return pool_err
	}

	loop_err := transport_loop(state, input, &pool)
	// The pool is joined before the stopped reply, so no worker can emit an
	// event after it.
	stop_err := pool_stop(&pool, true)

	if loop_err.kind != .None {
		host_error_destroy(&stop_err)
		return loop_err
	}
	if state.quit_requested {
		stopped_err := transport_write_message(state, Transport_Stopped_Message{message_type = "stopped"})
		if stop_err.kind != .None {
			host_error_destroy(&stopped_err)
			return stop_err
		}
		return stopped_err
	}
	return stop_err
}

// transport_loop reads and answers requests until quit or end of input.
@(private)
transport_loop :: proc(state: ^Transport_State, input: io.Reader, pool: ^Pool) -> Host_Error {
	reader: bufio.Reader
	bufio.reader_init(&reader, input)
	defer bufio.reader_destroy(&reader)

	for {
		line, read_err := bufio.reader_read_string(&reader, '\n')
		if read_err != nil && read_err != .EOF {
			delete(line)
			return host_error(.Internal, "could not read the transport input")
		}
		if len(line) == 0 && read_err == .EOF {
			return Host_Error{}
		}
		trimmed := strings.trim_right(line, "\r\n")
		action, handle_err := transport_handle_line(state, pool, trimmed)
		delete(line)
		if handle_err.kind != .None {
			return handle_err
		}
		if action == .Quit || read_err == .EOF {
			return Host_Error{}
		}
	}
}

@(private)
transport_handle_line :: proc(state: ^Transport_State, pool: ^Pool, line: string) -> (Transport_Action, Host_Error) {
	parsed: json.Value
	if unmarshal_err := json.unmarshal_string(line, &parsed, .JSON); unmarshal_err != nil {
		return .Continue, transport_reply_error(state, "malformed JSON")
	}
	defer json.destroy_value(parsed)

	object, is_object := parsed.(json.Object)
	if !is_object {
		return .Continue, transport_reply_error(state, "expected a JSON object")
	}
	request_type, has_type := transport_string_field(object, "type")
	if !has_type {
		return .Continue, transport_reply_error(state, "missing type")
	}

	switch request_type {
	case "submit":
		return transport_handle_submit(state, pool, object)
	case "resume":
		return transport_handle_resume(state, pool, object)
	case "close_session":
		return transport_handle_close_session(state, object)
	case "quit":
		state.quit_requested = true
		return .Quit, Host_Error{}
	}
	return .Continue, transport_reply_error(state, "unknown type")
}

@(private)
transport_handle_submit :: proc(state: ^Transport_State, pool: ^Pool, object: json.Object) -> (Transport_Action, Host_Error) {
	session_id, has_session := transport_string_field(object, "session_id")
	if !has_session {
		return .Continue, transport_reply_error(state, "missing session_id")
	}
	prompt, has_prompt := transport_string_field(object, "prompt")
	if !has_prompt {
		return .Continue, transport_reply_error(state, "missing prompt")
	}
	provider, has_provider := transport_string_field(object, "provider")
	if !has_provider {
		return .Continue, transport_reply_error(state, "missing provider")
	}
	model, has_model := transport_string_field(object, "model")
	if !has_model {
		return .Continue, transport_reply_error(state, "missing model")
	}
	thinking, has_thinking := transport_string_field(object, "thinking")
	if !has_thinking {
		return .Continue, transport_reply_error(state, "missing thinking")
	}

	work_item_id, submit_err := pool_submit(pool^, session_id, provider, model, thinking, prompt)
	if submit_err.kind != .None {
		reply_err := transport_reply_error(state, submit_err.message)
		host_error_destroy(&submit_err)
		return .Continue, reply_err
	}
	reply_err := transport_write_message(state, Transport_Accepted_Message{
		message_type = "accepted",
		work_item_id = work_item_id,
	})
	delete(work_item_id)
	return .Continue, reply_err
}

@(private)
transport_handle_resume :: proc(state: ^Transport_State, pool: ^Pool, object: json.Object) -> (Transport_Action, Host_Error) {
	work_item_id, has_item := transport_string_field(object, "work_item_id")
	if !has_item {
		return .Continue, transport_reply_error(state, "missing work_item_id")
	}
	resumed_input, has_input := transport_string_field(object, "input")
	if !has_input {
		return .Continue, transport_reply_error(state, "missing input")
	}

	resume_err := pool_resume(pool^, work_item_id, resumed_input)
	if resume_err.kind != .None {
		reply_err := transport_reply_error(state, resume_err.message)
		host_error_destroy(&resume_err)
		return .Continue, reply_err
	}
	return .Continue, transport_write_message(state, Transport_Accepted_Message{
		message_type = "accepted",
		work_item_id = work_item_id,
	})
}

@(private)
transport_handle_close_session :: proc(state: ^Transport_State, object: json.Object) -> (Transport_Action, Host_Error) {
	session_id, has_session := transport_string_field(object, "session_id")
	if !has_session {
		return .Continue, transport_reply_error(state, "missing session_id")
	}

	close_err := close_session(state.host, session_id)
	if close_err.kind != .None {
		reply_err := transport_reply_error(state, close_err.message)
		host_error_destroy(&close_err)
		return .Continue, reply_err
	}
	return .Continue, transport_write_message(state, Transport_Closed_Message{
		message_type = "closed",
		session_id   = session_id,
	})
}

// transport_relay is the pool's event callback. It runs on a worker thread, so
// it forwards to the configured callback and then writes one event line.
@(private)
transport_relay :: proc(event: Agent_Event) {
	state := transport_active
	if state == nil {
		return
	}
	if state.events != nil {
		state.events(event)
	}
	relay_err := transport_write_message(state, Transport_Event_Message{
		message_type = "event",
		kind         = transport_event_kind(event.kind),
		session_id   = event.session_id,
		work_item_id = event.work_item_id,
		message      = event.message,
	})
	host_error_destroy(&relay_err)
}

@(private)
transport_event_kind :: proc(kind: Agent_Event_Kind) -> string {
	switch kind {
	case .Needs_Input:
		return TRANSPORT_EVENT_NEEDS_INPUT
	case .Progress:
		return TRANSPORT_EVENT_PROGRESS
	case .Final_Result:
		return TRANSPORT_EVENT_FINAL_RESULT
	}
	return TRANSPORT_EVENT_PROGRESS
}

@(private)
transport_reply_error :: proc(state: ^Transport_State, reason: string) -> Host_Error {
	return transport_write_message(state, Transport_Error_Message{
		message_type = "error",
		reason       = reason,
	})
}

@(private)
transport_string_field :: proc(object: json.Object, key: string) -> (string, bool) {
	field, has_field := object[key]
	if !has_field {
		return "", false
	}
	text, is_string := field.(json.String)
	if !is_string {
		return "", false
	}
	return string(text), true
}

// transport_write_message encodes one message with the JSON encoder and writes
// it as a whole line under the state mutex.
@(private)
transport_write_message :: proc(state: ^Transport_State, message: any) -> Host_Error {
	encoded, marshal_err := json.marshal(message)
	if marshal_err != nil {
		return host_error(.Internal, "could not encode a transport message")
	}
	defer delete(encoded)
	line := make([]byte, len(encoded) + 1)
	defer delete(line)
	copy(line, encoded)
	line[len(encoded)] = '\n'

	sync.mutex_lock(&state.mutex)
	defer sync.mutex_unlock(&state.mutex)
	if write_err := transport_write_all(state.output, line); write_err != nil {
		return host_error(.Internal, "could not write a transport message")
	}
	return Host_Error{}
}

@(private)
transport_write_all :: proc(output: io.Writer, data: []byte) -> io.Error {
	written := 0
	for written < len(data) {
		count, write_err := io.write(output, data[written:])
		if write_err != nil {
			return write_err
		}
		if count <= 0 {
			return .Short_Write
		}
		written += count
	}
	return nil
}
