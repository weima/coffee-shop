package oreo

// Tests for the remote provider. A fake peer stands in for the pi extension: it
// records the request lines the provider writes and replays scripted reply
// lines. The literal "{id}" in a reply is replaced with the request id the
// provider generated, so a test never hard-codes an opaque id. There are no
// model calls and no network; the pipe test drives a real os.Pipe from a thread.

import "core:bytes"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

@(private)
REMOTE_TEST_ID_PLACEHOLDER :: "{id}"
@(private)
REMOTE_TEST_PROVIDER :: "test-provider"
@(private)
REMOTE_TEST_MODEL :: "test-model"
@(private)
REMOTE_TEST_THINKING :: "low"
@(private)
REMOTE_TEST_TIMEOUT :: 25

// The fake peer. `written` holds the request lines the provider sent, `replies`
// the lines it will return in order.
@(private)
Remote_Test_Peer :: struct {
	mutex:          sync.Mutex,
	written:        [dynamic]string,
	replies:        [dynamic]string,
	next_reply:     int,
	fail_write:     bool,
	fail_read:      bool,
	last_timeout_ms: int,
}

@(private)
remote_test_provider_with :: proc(
	state: ^Provider_Remote_State,
	data: rawptr,
	events: Event_Fn,
	timeout_ms: int,
	write_line: proc(user: rawptr, line: string) -> bool,
	read_line: proc(user: rawptr, timeout_ms: int) -> (line: string, ok: bool),
) -> Provider {
	state.provider = REMOTE_TEST_PROVIDER
	state.model = REMOTE_TEST_MODEL
	state.thinking = REMOTE_TEST_THINKING
	state.data = data
	return provider_remote(Remote_Transport{
		user       = rawptr(state),
		write_line = write_line,
		read_line  = read_line,
	}, events, timeout_ms)
}

@(private)
remote_test_provider :: proc(state: ^Provider_Remote_State, peer: ^Remote_Test_Peer, events: Event_Fn, timeout_ms: int) -> Provider {
	return remote_test_provider_with(state, rawptr(peer), events, timeout_ms, remote_test_write, remote_test_read)
}

@(private)
remote_test_write :: proc(user: rawptr, line: string) -> bool {
	state := cast(^Provider_Remote_State)user
	peer := cast(^Remote_Test_Peer)state.data
	sync.mutex_lock(&peer.mutex)
	defer sync.mutex_unlock(&peer.mutex)
	if peer.fail_write {
		return false
	}
	cloned, _ := strings.clone(line, context.allocator)
	_, _ = append(&peer.written, cloned)
	return true
}

// remote_test_read answers with the next scripted line, filling in the request
// id from the most recent request. An exhausted script reports a timeout.
@(private)
remote_test_read :: proc(user: rawptr, timeout_ms: int) -> (string, bool) {
	state := cast(^Provider_Remote_State)user
	peer := cast(^Remote_Test_Peer)state.data
	sync.mutex_lock(&peer.mutex)
	defer sync.mutex_unlock(&peer.mutex)
	peer.last_timeout_ms = timeout_ms
	if peer.fail_read || peer.next_reply >= len(peer.replies) {
		return "", false
	}
	template := peer.replies[peer.next_reply]
	peer.next_reply += 1
	if !strings.contains(template, REMOTE_TEST_ID_PLACEHOLDER) || len(peer.written) == 0 {
		return strings.clone(template, context.allocator), true
	}
	request_id, found := remote_test_field(peer.written[len(peer.written) - 1], "request_id")
	if !found {
		return strings.clone(template, context.allocator), true
	}
	defer delete(request_id, context.allocator)
	replaced, allocated := strings.replace_all(template, REMOTE_TEST_ID_PLACEHOLDER, request_id, context.allocator)
	if !allocated {
		return strings.clone(replaced, context.allocator), true
	}
	return replaced, true
}

@(private)
remote_test_reply :: proc(peer: ^Remote_Test_Peer, line: string) {
	cloned, _ := strings.clone(line, context.allocator)
	sync.mutex_lock(&peer.mutex)
	defer sync.mutex_unlock(&peer.mutex)
	_, _ = append(&peer.replies, cloned)
}

@(private)
remote_test_peer_destroy :: proc(peer: ^Remote_Test_Peer) {
	for line in peer.written {
		delete(line, context.allocator)
	}
	delete(peer.written)
	for line in peer.replies {
		delete(line, context.allocator)
	}
	delete(peer.replies)
	peer^ = {}
}

@(private)
remote_test_written :: proc(peer: ^Remote_Test_Peer, index: int) -> (string, bool) {
	sync.mutex_lock(&peer.mutex)
	defer sync.mutex_unlock(&peer.mutex)
	if index >= len(peer.written) {
		return "", false
	}
	return strings.clone(peer.written[index], context.allocator), true
}

@(private)
remote_test_written_count :: proc(peer: ^Remote_Test_Peer) -> int {
	sync.mutex_lock(&peer.mutex)
	defer sync.mutex_unlock(&peer.mutex)
	return len(peer.written)
}

@(private)
remote_test_field :: proc(line, key: string) -> (string, bool) {
	parsed: json.Value
	if json.unmarshal_string(line, &parsed, .JSON) != nil {
		return "", false
	}
	defer json.destroy_value(parsed)
	object, is_object := parsed.(json.Object)
	if !is_object {
		return "", false
	}
	value, found := object[key]
	if !found {
		return "", false
	}
	text, is_string := value.(json.String)
	if !is_string {
		return "", false
	}
	return strings.clone(string(text), context.allocator), true
}

@(private)
remote_test_array_length :: proc(line, key: string) -> (int, bool) {
	parsed: json.Value
	if json.unmarshal_string(line, &parsed, .JSON) != nil {
		return 0, false
	}
	defer json.destroy_value(parsed)
	object, is_object := parsed.(json.Object)
	if !is_object {
		return 0, false
	}
	value, found := object[key]
	if !found {
		return 0, false
	}
	array, is_array := value.(json.Array)
	if !is_array {
		return 0, false
	}
	return len(array), true
}

@(private)
remote_test_expect_field :: proc(t: ^testing.T, line, key, want: string) {
	got, found := remote_test_field(line, key)
	testing.expectf(t, found, "the request line has no string field %q", key)
	testing.expectf(t, got == want, "the request line field %q is %q, want %q", key, got, want)
	delete(got, context.allocator)
}

// The event recorder. Agent_Event borrows its strings, so the callback clones
// the message it wants to inspect later.
@(private)
Remote_Test_Recorder :: struct {
	calls:   int,
	kind:    Agent_Event_Kind,
	message: string,
}

@(private)
remote_test_recorder: Remote_Test_Recorder

@(private)
remote_test_event :: proc(event: Agent_Event) {
	remote_test_recorder.calls += 1
	remote_test_recorder.kind = event.kind
	delete(remote_test_recorder.message, context.allocator)
	remote_test_recorder.message, _ = strings.clone(event.message, context.allocator)
}

@(private)
remote_test_recorder_reset :: proc() {
	delete(remote_test_recorder.message, context.allocator)
	remote_test_recorder = {}
}

// The pipe peer: the host writes the request to `request_write` and reads the
// reply from `response_read`; a thread reads the request and writes the reply.
@(private)
Remote_Test_Pipe :: struct {
	request_read:   ^os.File,
	request_write:  ^os.File,
	response_read:  ^os.File,
	response_write: ^os.File,
	request_buffer: [4096]byte,
	request_length: int,
	read_buffer:    [dynamic]byte,
}

@(private)
remote_test_pipe_destroy :: proc(pipe: ^Remote_Test_Pipe) {
	delete(pipe.read_buffer)
	pipe^ = {}
}

@(private)
remote_test_pipe_write :: proc(user: rawptr, line: string) -> bool {
	state := cast(^Provider_Remote_State)user
	pipe := cast(^Remote_Test_Pipe)state.data
	return remote_test_pipe_write_all(pipe.request_write, transmute([]byte)line)
}

@(private)
remote_test_pipe_read :: proc(user: rawptr, timeout_ms: int) -> (string, bool) {
	state := cast(^Provider_Remote_State)user
	pipe := cast(^Remote_Test_Pipe)state.data
	if line, found := remote_test_pipe_take(pipe); found {
		return line, true
	}
	deadline := time.now()
	for time.since(deadline) < time.Duration(timeout_ms) * time.Millisecond {
		poll_fds := [1]posix.pollfd{{fd = posix.FD(os.fd(pipe.response_read)), events = {.IN}}}
		ready := posix.poll(&poll_fds[0], 1, 20)
		if ready < 0 {
			return "", false
		}
		if ready == 0 {
			continue
		}
		chunk: [1024]byte
		count, read_err := os.read(pipe.response_read, chunk[:])
		if count > 0 {
			_, _ = append(&pipe.read_buffer, ..chunk[:count])
			if line, found := remote_test_pipe_take(pipe); found {
				return line, true
			}
		}
		if read_err != nil {
			return "", false
		}
	}
	return "", false
}

@(private)
remote_test_pipe_take :: proc(pipe: ^Remote_Test_Pipe) -> (string, bool) {
	newline := bytes.index_byte(pipe.read_buffer[:], '\n')
	if newline < 0 {
		return "", false
	}
	line := strings.clone_from_bytes(pipe.read_buffer[:newline], context.allocator)
	remaining := len(pipe.read_buffer) - newline - 1
	copy(pipe.read_buffer[:remaining], pipe.read_buffer[newline + 1:])
	resize(&pipe.read_buffer, remaining)
	return line, true
}

@(private)
remote_test_pipe_write_all :: proc(file: ^os.File, data: []byte) -> bool {
	written := 0
	for written < len(data) {
		count, write_err := os.write(file, data[written:])
		if write_err != nil || count <= 0 {
			return false
		}
		written += count
	}
	return true
}

// The peer thread reads one request line, takes its request id, and answers.
@(private)
remote_test_pipe_peer :: proc(worker: ^thread.Thread) {
	pipe := cast(^Remote_Test_Pipe)worker.data
	length := 0
	for length < len(pipe.request_buffer) {
		count, read_err := os.read(pipe.request_read, pipe.request_buffer[length:])
		if count > 0 {
			length += count
			if bytes.index_byte(pipe.request_buffer[:length], '\n') >= 0 {
				break
			}
		}
		if read_err != nil {
			break
		}
	}
	pipe.request_length = length

	request_id := remote_test_request_id(pipe.request_buffer[:length])
	// The reply is assembled by hand: fmt treats braces as argument placeholders,
	// and this JSON is full of them.
	reply: [1024]byte
	offset := copy(reply[:], `{"type":"model_response","request_id":"`)
	offset += copy(reply[offset:], request_id)
	offset += copy(reply[offset:], `","text":"pipe hello","tool_calls":[{"id":"call-1","name":"echo","arguments_json":"{}"}]}`)
	reply[offset] = '\n'
	offset += 1
	_ = remote_test_pipe_write_all(pipe.response_write, reply[:offset])
}

// remote_test_request_id finds the request_id value in raw request bytes,
// without parsing, so the peer thread allocates nothing.
@(private)
remote_test_request_id :: proc(line: []byte) -> []byte {
	key := `"request_id":"`
	if len(line) < len(key) {
		return nil
	}
	for index in 0 ..= len(line) - len(key) {
		if string(line[index:index + len(key)]) == key {
			start := index + len(key)
			end := start
			for end < len(line) && line[end] != '"' {
				end += 1
			}
			return line[start:end]
		}
	}
	return nil
}

// A conversation with every message shape, so the encoding of roles, tool
// calls, and tool_call_id is exercised.
@(private)
remote_test_conversation :: proc() -> (messages: [3]Agent_Message, calls: [1]Agent_Tool_Call) {
	calls[0] = Agent_Tool_Call{id = "call-1", name = "read", arguments_json = `{"path":"a.txt"}`}
	messages[0] = Agent_Message{role = .User, text = "read the file"}
	messages[1] = Agent_Message{role = .Assistant, tool_calls = calls[:]}
	messages[2] = Agent_Message{role = .Tool, text = "the contents", tool_call_id = "call-1"}
	return
}

@(private)
remote_test_tools: [1]Tool_Spec = {{name = "read", description = "Read a file.", parameters_json = `{"type":"object"}`}}

@(private)
remote_test_request :: proc(messages: []Agent_Message) -> Provider_Request {
	return Provider_Request{messages = messages, tools = remote_test_tools[:]}
}

@(test)
test_provider_remote_returns_text_and_tool_calls :: proc(t: ^testing.T) {
	peer: Remote_Test_Peer
	defer remote_test_peer_destroy(&peer)
	remote_test_reply(&peer, `{"type":"model_response","request_id":"{id}","text":"all done","tool_calls":[{"id":"call-9","name":"echo","arguments_json":"{}"}]}`)

	state: Provider_Remote_State
	provider := remote_test_provider(&state, &peer, nil, REMOTE_TEST_TIMEOUT)

	messages, _ := remote_test_conversation()
	response, provider_err := provider.complete(provider.user, remote_test_request(messages[:]), context.allocator)
	defer {
		delete(response.text, context.allocator)
		destroy_tool_calls(response.tool_calls, context.allocator)
		provider_error_destroy(&provider_err, context.allocator)
	}

	testing.expect_value(t, provider_err.kind, Provider_Error_Kind.None)
	testing.expect_value(t, response.text, "all done")
	testing.expect_value(t, len(response.tool_calls), 1)
	if len(response.tool_calls) == 1 {
		testing.expect_value(t, response.tool_calls[0].id, "call-9")
		testing.expect_value(t, response.tool_calls[0].name, "echo")
		testing.expect_value(t, response.tool_calls[0].arguments_json, "{}")
	}

	testing.expect_value(t, remote_test_written_count(&peer), 1)
	line, found := remote_test_written(&peer, 0)
	defer delete(line, context.allocator)
	testing.expect(t, found)
	if !found {
		return
	}
	remote_test_expect_field(t, line, "type", "model_request")
	remote_test_expect_field(t, line, "provider", REMOTE_TEST_PROVIDER)
	remote_test_expect_field(t, line, "model", REMOTE_TEST_MODEL)
	remote_test_expect_field(t, line, "thinking", REMOTE_TEST_THINKING)
	message_count, has_messages := remote_test_array_length(line, "messages")
	testing.expect(t, has_messages)
	testing.expect_value(t, message_count, 3)
	tool_count, has_tools := remote_test_array_length(line, "tools")
	testing.expect(t, has_tools)
	testing.expect_value(t, tool_count, 1)
	request_id, has_id := remote_test_field(line, "request_id")
	testing.expect(t, has_id)
	testing.expect(t, len(request_id) > 0)
	delete(request_id, context.allocator)
}

@(test)
test_provider_remote_delivers_events_while_waiting :: proc(t: ^testing.T) {
	remote_test_recorder_reset()
	defer remote_test_recorder_reset()

	peer: Remote_Test_Peer
	defer remote_test_peer_destroy(&peer)
	// An unrelated line, then an event, then the reply: only the reply ends the wait.
	remote_test_reply(&peer, `{"type":"accepted","work_item_id":"someone-else"}`)
	remote_test_reply(&peer, `{"type":"event","kind":"progress","session_id":"session-7","work_item_id":"item-7","message":"working"}`)
	remote_test_reply(&peer, `{"type":"model_response","request_id":"{id}","text":"done","tool_calls":[]}`)

	state: Provider_Remote_State
	provider := remote_test_provider(&state, &peer, remote_test_event, REMOTE_TEST_TIMEOUT)

	messages, _ := remote_test_conversation()
	response, provider_err := provider.complete(provider.user, remote_test_request(messages[:]), context.allocator)
	defer {
		delete(response.text, context.allocator)
		destroy_tool_calls(response.tool_calls, context.allocator)
		provider_error_destroy(&provider_err, context.allocator)
	}

	testing.expect_value(t, provider_err.kind, Provider_Error_Kind.None)
	testing.expect_value(t, response.text, "done")
	testing.expect_value(t, remote_test_recorder.calls, 1)
	testing.expect_value(t, remote_test_recorder.kind, Agent_Event_Kind.Progress)
	testing.expect_value(t, remote_test_recorder.message, "working")
}

@(test)
test_provider_remote_model_error_becomes_provider_error :: proc(t: ^testing.T) {
	peer: Remote_Test_Peer
	defer remote_test_peer_destroy(&peer)
	remote_test_reply(&peer, `{"type":"model_error","request_id":"{id}","reason":"not logged in to provider test-provider"}`)

	state: Provider_Remote_State
	provider := remote_test_provider(&state, &peer, nil, REMOTE_TEST_TIMEOUT)

	messages, _ := remote_test_conversation()
	response, provider_err := provider.complete(provider.user, remote_test_request(messages[:]), context.allocator)
	defer {
		destroy_tool_calls(response.tool_calls, context.allocator)
		provider_error_destroy(&provider_err, context.allocator)
	}

	testing.expect_value(t, provider_err.kind, Provider_Error_Kind.Unavailable)
	testing.expect(t, strings.contains(provider_err.message, "not logged in"))
	testing.expect_value(t, len(response.tool_calls), 0)
}

@(test)
test_provider_remote_timeout_becomes_provider_error :: proc(t: ^testing.T) {
	peer: Remote_Test_Peer
	defer remote_test_peer_destroy(&peer)
	// No replies: the peer never answers, so the read reports a timeout.

	state: Provider_Remote_State
	provider := remote_test_provider(&state, &peer, nil, 7)

	messages, _ := remote_test_conversation()
	_, provider_err := provider.complete(provider.user, remote_test_request(messages[:]), context.allocator)
	defer provider_error_destroy(&provider_err, context.allocator)

	testing.expect_value(t, provider_err.kind, Provider_Error_Kind.Unavailable)
	testing.expect(t, strings.contains(provider_err.message, "timeout"))
	testing.expect_value(t, peer.last_timeout_ms, 7)
}

@(test)
test_provider_remote_write_failure_becomes_provider_error :: proc(t: ^testing.T) {
	peer: Remote_Test_Peer
	defer remote_test_peer_destroy(&peer)
	peer.fail_write = true

	state: Provider_Remote_State
	provider := remote_test_provider(&state, &peer, nil, REMOTE_TEST_TIMEOUT)

	messages, _ := remote_test_conversation()
	_, provider_err := provider.complete(provider.user, remote_test_request(messages[:]), context.allocator)
	defer provider_error_destroy(&provider_err, context.allocator)

	testing.expect_value(t, provider_err.kind, Provider_Error_Kind.Unavailable)
	testing.expect(t, strings.contains(provider_err.message, "written"))
	testing.expect_value(t, remote_test_written_count(&peer), 0)
}

@(test)
test_provider_remote_over_os_pipe :: proc(t: ^testing.T) {
	request_read, request_write, request_err := os.pipe()
	testing.expect_value(t, request_err, os.Error(nil))
	response_read, response_write, response_err := os.pipe()
	testing.expect_value(t, response_err, os.Error(nil))
	defer {
		_ = os.close(request_read)
		_ = os.close(request_write)
		_ = os.close(response_read)
		_ = os.close(response_write)
	}

	pipe := Remote_Test_Pipe{
		request_read   = request_read,
		request_write  = request_write,
		response_read  = response_read,
		response_write = response_write,
	}
	defer remote_test_pipe_destroy(&pipe)

	worker := thread.create(remote_test_pipe_peer)
	assert(worker != nil)
	worker.data = rawptr(&pipe)
	thread.start(worker)

	state: Provider_Remote_State
	provider := remote_test_provider_with(&state, rawptr(&pipe), nil, 2_000, remote_test_pipe_write, remote_test_pipe_read)

	// A raw newline in the message text must be escaped, or the peer would see
	// a truncated request line and never match the request id.
	conversation := [1]Agent_Message{{role = .User, text = "line one\nline \"two\""}}
	response, provider_err := provider.complete(provider.user, Provider_Request{messages = conversation[:]}, context.allocator)
	// The peer must finish before its captured request line is read.
	thread.destroy(worker)
	defer {
		delete(response.text, context.allocator)
		destroy_tool_calls(response.tool_calls, context.allocator)
		provider_error_destroy(&provider_err, context.allocator)
	}

	testing.expect_value(t, provider_err.kind, Provider_Error_Kind.None)
	testing.expect_value(t, response.text, "pipe hello")
	testing.expect_value(t, len(response.tool_calls), 1)
	if len(response.tool_calls) == 1 {
		testing.expect_value(t, response.tool_calls[0].name, "echo")
	}

	line := transmute(string)pipe.request_buffer[:pipe.request_length]
	remote_test_expect_field(t, line, "type", "model_request")
	remote_test_expect_field(t, line, "provider", REMOTE_TEST_PROVIDER)
	remote_test_expect_field(t, line, "model", REMOTE_TEST_MODEL)
	remote_test_expect_field(t, line, "thinking", REMOTE_TEST_THINKING)
	message_count, has_messages := remote_test_array_length(line, "messages")
	testing.expect(t, has_messages)
	testing.expect_value(t, message_count, 1)
}
