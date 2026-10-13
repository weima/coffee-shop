package oreo

// Tests for the assembled host. A fake extension stands in for the pi
// extension: it is a thread on the far end of two pipes, driving the real
// protocol and answering model requests with a scripted reply. The host runs
// through the real exported entry point, so the whole path is exercised -
// transport, pool, runtime, agent loop, provider_remote, and the scripted
// reply - with no model and no network.
//
// The host shares the runtime's retained-output list and the transport's
// active-server globals, so these tests take the same locks the runtime and
// transport tests take and run one at a time.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import store "oreo:store"

@(private)
HOST_TEST_TIMEOUT_MS :: 10_000
@(private)
HOST_TEST_PEER_TIMEOUT_MS :: 20_000

// host_test_lock serializes the host tests themselves.
@(private)
host_test_lock: sync.Mutex

// Host_Test_Mode decides what the fake extension does with a model request.
@(private)
Host_Test_Mode :: enum {
	Respond,
	Error,
	Silent,
}

// Host_Test_Peer is the fake extension. The peer thread reads the host's output
// and answers model requests; the test thread writes `submit` and `quit` on the
// same pipe, so writes take the same lock.
@(private)
Host_Test_Peer :: struct {
	allocator:     runtime.Allocator,
	mutex:         sync.Mutex,
	write_mutex:   sync.Mutex,
	lines:         [dynamic]string,
	requests:      [dynamic]string,
	replies:       int,
	mode:          Host_Test_Mode,
	reply_text:    string,
	request_file:  ^os.File,
	response_file: ^os.File,
	read_buffer:   [dynamic]byte,
}

// Host_Test_Server runs host_run on its own thread.
@(private)
Host_Test_Server :: struct {
	store_path: string,
	input:      io.Reader,
	output:     io.Writer,
	allocator:  runtime.Allocator,
	status:     int,
}

@(private)
Host_Test_Rig :: struct {
	directory:      string,
	store_path:     string,
	request_read:   ^os.File,
	request_write:  ^os.File,
	response_read:  ^os.File,
	response_write: ^os.File,
	server:         Host_Test_Server,
	peer:           Host_Test_Peer,
	server_thread:  ^thread.Thread,
	peer_thread:    ^thread.Thread,
}

// The wire shapes, so the test builds valid JSON with the same encoder the host
// uses.
@(private)
Host_Test_Submit :: struct {
	message_type: string `json:"type"`,
	session_id:   string,
	prompt:       string,
	provider:     string,
	model:        string,
	thinking:     string,
}

@(private)
Host_Test_Type_Only :: struct {
	message_type: string `json:"type"`,
}

@(private)
Host_Test_Model_Response :: struct {
	message_type: string `json:"type"`,
	request_id:   string,
	text:         string,
}

@(private)
Host_Test_Model_Error :: struct {
	message_type: string `json:"type"`,
	request_id:   string,
	reason:       string,
}

@(private)
host_test_server_run :: proc(worker: ^thread.Thread) {
	server := cast(^Host_Test_Server)worker.data
	context.allocator = server.allocator
	server.status = host_run(server.store_path, server.input, server.output)
}

@(private)
host_test_peer_run :: proc(worker: ^thread.Thread) {
	peer := cast(^Host_Test_Peer)worker.data
	context.allocator = peer.allocator
	for {
		line, ok := host_test_read_line(peer, HOST_TEST_PEER_TIMEOUT_MS)
		if !ok {
			return
		}
		host_test_peer_record(peer, line)
		line_type, _ := host_test_field(line, "type")
		stopped := line_type == "stopped"
		if line_type == "model_request" {
			request_id, _ := host_test_field(line, "request_id")
			host_trace(request_id, "peer model_request read, mode=%v", peer.mode)
			host_test_peer_record_request(peer, line)
			host_test_answer(peer, line)
			host_trace(request_id, "peer request handled")
			delete(request_id)
		}
		delete(line_type)
		delete(line)
		if stopped {
			return
		}
	}
}

// host_test_answer sends exactly one reply per model request, or intentionally
// none in Silent mode. It records that the request was handled so a test can
// order its quit after the reply.
@(private)
host_test_answer :: proc(peer: ^Host_Test_Peer, line: string) {
	request_id, found := host_test_field(line, "request_id")
	if !found {
		return
	}
	defer delete(request_id)

	switch peer.mode {
	case .Respond:
		_ = host_test_write_message(peer, Host_Test_Model_Response{
			message_type = "model_response",
			request_id   = request_id,
			text         = peer.reply_text,
		})
	case .Error:
		_ = host_test_write_message(peer, Host_Test_Model_Error{
			message_type = "model_error",
			request_id   = request_id,
			reason       = "the test peer refused the model",
		})
	case .Silent:
	}

	sync.mutex_lock(&peer.mutex)
	peer.replies += 1
	sync.mutex_unlock(&peer.mutex)
}

@(private)
host_test_peer_record :: proc(peer: ^Host_Test_Peer, line: string) {
	cloned, _ := strings.clone(line, peer.allocator)
	sync.mutex_lock(&peer.mutex)
	defer sync.mutex_unlock(&peer.mutex)
	_, _ = append(&peer.lines, cloned)
}

@(private)
host_test_peer_record_request :: proc(peer: ^Host_Test_Peer, line: string) {
	cloned, _ := strings.clone(line, peer.allocator)
	sync.mutex_lock(&peer.mutex)
	defer sync.mutex_unlock(&peer.mutex)
	_, _ = append(&peer.requests, cloned)
}

// host_test_write_message frames one JSON message and writes it whole. Both the
// peer thread and the test thread use it, so the write mutex keeps two lines
// from interleaving on the pipe.
@(private)
host_test_write_message :: proc(peer: ^Host_Test_Peer, value: any) -> bool {
	encoded, marshal_err := json.marshal(value, allocator = context.allocator)
	if marshal_err != nil {
		return false
	}
	defer delete(encoded, context.allocator)
	line := make([]byte, len(encoded) + 1, context.allocator)
	defer delete(line, context.allocator)
	copy(line, encoded)
	line[len(encoded)] = '\n'

	sync.mutex_lock(&peer.write_mutex)
	defer sync.mutex_unlock(&peer.write_mutex)
	return host_test_pipe_write_all(peer.request_file, line)
}

@(private)
host_test_pipe_write_all :: proc(file: ^os.File, data: []byte) -> bool {
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

// host_test_read_line returns one complete host output line, or ok = false when
// the deadline passes or the pipe closes.
@(private)
host_test_read_line :: proc(peer: ^Host_Test_Peer, timeout_ms: int) -> (string, bool) {
	if line, found := host_test_take_line(&peer.read_buffer); found {
		return line, true
	}
	deadline := time.now()
	for time.since(deadline) < time.Duration(timeout_ms) * time.Millisecond {
		poll_fds := [1]posix.pollfd{{fd = posix.FD(os.fd(peer.response_file)), events = {.IN}}}
		if posix.poll(&poll_fds[0], 1, 100) <= 0 {
			continue
		}
		chunk: [4096]byte
		count, read_err := os.read(peer.response_file, chunk[:])
		if count > 0 {
			_, _ = append(&peer.read_buffer, ..chunk[:count])
			if line, found := host_test_take_line(&peer.read_buffer); found {
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
host_test_take_line :: proc(buffer: ^[dynamic]byte) -> (string, bool) {
	newline := -1
	for value, index in buffer^ {
		if value == '\n' {
			newline = index
			break
		}
	}
	if newline < 0 {
		return "", false
	}
	line, _ := strings.clone_from_bytes(buffer^[:newline], context.allocator)
	remaining := len(buffer^) - newline - 1
	copy(buffer^[:remaining], buffer^[newline + 1:])
	resize(buffer, remaining)
	return line, true
}

@(private)
host_test_rig_start :: proc(t: ^testing.T, mode: Host_Test_Mode, reply_text: string) -> ^Host_Test_Rig {
	rig := new(Host_Test_Rig)
	directory, directory_err := os.make_directory_temp(TEMP_DIR, "oreo-host-run-*", context.allocator)
	testing.expect_value(t, directory_err, os.Error(nil))
	rig.directory = directory
	path, path_err := filepath.join({directory, "sessions.db"}, context.allocator)
	testing.expect(t, path_err == nil)
	rig.store_path = path

	request_read, request_write, request_err := os.pipe()
	testing.expect_value(t, request_err, os.Error(nil))
	response_read, response_write, response_err := os.pipe()
	testing.expect_value(t, response_err, os.Error(nil))
	rig.request_read = request_read
	rig.request_write = request_write
	rig.response_read = response_read
	rig.response_write = response_write

	rig.peer.allocator = context.allocator
	rig.peer.mode = mode
	rig.peer.reply_text, _ = strings.clone(reply_text, context.allocator)
	rig.peer.request_file = request_write
	rig.peer.response_file = response_read
	rig.peer.read_buffer = make([dynamic]byte, 0, 4096, context.allocator)
	rig.peer.lines = make([dynamic]string, 0, 16, context.allocator)
	rig.peer.requests = make([dynamic]string, 0, 4, context.allocator)

	rig.server = Host_Test_Server{
		store_path = rig.store_path,
		input      = os.to_reader(request_read),
		output     = os.to_writer(response_write),
		allocator  = context.allocator,
	}

	rig.peer_thread = thread.create(host_test_peer_run)
	assert(rig.peer_thread != nil)
	rig.peer_thread.data = rawptr(&rig.peer)
	thread.start(rig.peer_thread)

	rig.server_thread = thread.create(host_test_server_run)
	assert(rig.server_thread != nil)
	rig.server_thread.data = rawptr(&rig.server)
	thread.start(rig.server_thread)
	return rig
}

// host_test_rig_finish joins the peer and the host and returns host_run's exit
// status. A quit must already have been sent.
@(private)
host_test_rig_finish :: proc(t: ^testing.T, rig: ^Host_Test_Rig) -> int {
	thread.destroy(rig.peer_thread)
	status := rig.server.status
	thread.destroy(rig.server_thread)
	return status
}

@(private)
host_test_rig_free :: proc(rig: ^Host_Test_Rig) {
	for line in rig.peer.lines {
		delete(line)
	}
	delete(rig.peer.lines)
	for line in rig.peer.requests {
		delete(line)
	}
	delete(rig.peer.requests)
	delete(rig.peer.read_buffer)
	delete(rig.peer.reply_text)
	_ = os.close(rig.request_read)
	_ = os.close(rig.request_write)
	_ = os.close(rig.response_read)
	_ = os.close(rig.response_write)
	_ = os.remove_all(rig.directory)
	delete(rig.directory)
	delete(rig.store_path)
	free(rig)
}

// host_test_field clones one string field from a line into the current
// allocator. The caller owns it.
@(private)
host_test_field :: proc(line, key: string) -> (string, bool) {
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
	cloned, _ := strings.clone(string(text))
	return cloned, true
}

@(private)
host_test_expect_field :: proc(t: ^testing.T, line, key, want: string) {
	got, found := host_test_field(line, key)
	testing.expectf(t, found, "the line has no string field %q", key)
	testing.expectf(t, got == want, "the line field %q is %q, want %q", key, got, want)
	delete(got)
}

// host_test_find_type returns a clone of the first recorded line of `wanted`.
@(private)
host_test_find_type :: proc(peer: ^Host_Test_Peer, wanted: string) -> (string, bool) {
	sync.mutex_lock(&peer.mutex)
	defer sync.mutex_unlock(&peer.mutex)
	for line in peer.lines {
		line_type, found := host_test_field(line, "type")
		if found && line_type == wanted {
			delete(line_type)
			cloned, _ := strings.clone(line)
			return cloned, true
		}
		delete(line_type)
	}
	return "", false
}

@(private)
host_test_wait_type :: proc(peer: ^Host_Test_Peer, wanted: string, timeout_ms: int) -> (string, bool) {
	deadline := time.now()
	for {
		if line, found := host_test_find_type(peer, wanted); found {
			return line, true
		}
		if time.since(deadline) >= time.Duration(timeout_ms) * time.Millisecond {
			return "", false
		}
		time.sleep(time.Millisecond)
	}
}

// host_test_find_event returns a clone of the first event line of `kind`.
@(private)
host_test_find_event :: proc(peer: ^Host_Test_Peer, kind: string) -> (string, bool) {
	sync.mutex_lock(&peer.mutex)
	defer sync.mutex_unlock(&peer.mutex)
	for line in peer.lines {
		line_type, type_found := host_test_field(line, "type")
		if !type_found || line_type != "event" {
			delete(line_type)
			continue
		}
		delete(line_type)
		got_kind, kind_found := host_test_field(line, "kind")
		if kind_found && got_kind == kind {
			delete(got_kind)
			cloned, _ := strings.clone(line)
			return cloned, true
		}
		delete(got_kind)
	}
	return "", false
}

@(private)
host_test_wait_event :: proc(peer: ^Host_Test_Peer, kind: string, timeout_ms: int) -> (string, bool) {
	deadline := time.now()
	for {
		if line, found := host_test_find_event(peer, kind); found {
			return line, true
		}
		if time.since(deadline) >= time.Duration(timeout_ms) * time.Millisecond {
			return "", false
		}
		time.sleep(time.Millisecond)
	}
}

@(private)
host_test_wait_replies :: proc(peer: ^Host_Test_Peer, count, timeout_ms: int) -> bool {
	deadline := time.now()
	for {
		sync.mutex_lock(&peer.mutex)
		replies := peer.replies
		sync.mutex_unlock(&peer.mutex)
		if replies >= count {
			return true
		}
		if time.since(deadline) >= time.Duration(timeout_ms) * time.Millisecond {
			return false
		}
		time.sleep(time.Millisecond)
	}
}

// host_test_first_message returns the role and text of the request's first
// message, so a test proves the extension is asked the right question.
@(private)
host_test_first_message :: proc(line: string) -> (role: string, text: string, ok: bool) {
	parsed: json.Value
	if json.unmarshal_string(line, &parsed, .JSON) != nil {
		return "", "", false
	}
	defer json.destroy_value(parsed)
	object, is_object := parsed.(json.Object)
	if !is_object {
		return "", "", false
	}
	messages_value, found := object["messages"]
	if !found {
		return "", "", false
	}
	messages, is_array := messages_value.(json.Array)
	if !is_array || len(messages) == 0 {
		return "", "", false
	}
	first, is_message := messages[0].(json.Object)
	if !is_message {
		return "", "", false
	}
	role_text, _ := first["role"].(json.String)
	text_text, _ := first["text"].(json.String)
	cloned_role, _ := strings.clone(string(role_text))
	cloned_text, _ := strings.clone(string(text_text))
	return cloned_role, cloned_text, true
}

// host_test_open_store opens a second connection to the host's store after the
// host has closed, which also proves the host released it cleanly.
@(private)
host_test_open_store :: proc(t: ^testing.T, store_path: string) -> Host {
	host, open_err := open_host(store_path)
	testing.expect_value(t, open_err.kind, Host_Error_Kind.None)
	host_error_destroy(&open_err)
	return host
}

@(private)
host_test_item_status :: proc(t: ^testing.T, host: Host, work_item_id: string) -> string {
	store_handle, store_err := pool_store(host)
	testing.expect_value(t, store_err.kind, Host_Error_Kind.None)
	host_error_destroy(&store_err)
	item, found, item_err := store.get_work_item(store_handle, work_item_id)
	testing.expect(t, found, "the work item was not found")
	testing.expect_value(t, item_err.kind, store.Store_Error_Kind.None)
	defer store.work_item_destroy(&item)
	defer store.store_error_destroy(&item_err)
	return strings.clone(item.status)
}

// host_test_final_record_message returns the text of a completed run's final
// record, or the reason of a failed one. The two cases use different payload
// keys.
@(private)
host_test_final_record_message :: proc(t: ^testing.T, host: Host, work_item_id: string) -> (string, bool) {
	store_handle, store_err := pool_store(host)
	testing.expect_value(t, store_err.kind, Host_Error_Kind.None)
	host_error_destroy(&store_err)
	records, records_err := store.list_work_item_records(store_handle, work_item_id)
	testing.expect_value(t, records_err.kind, store.Store_Error_Kind.None)
	defer store.records_destroy(records)
	defer store.store_error_destroy(&records_err)
	for record in records {
		if record.kind != RUNTIME_FINAL_RECORD_KIND {
			continue
		}
		parsed: json.Value
		if json.unmarshal_string(record.payload_json, &parsed, .JSON) != nil {
			continue
		}
		message := ""
		found := false
		if object, is_object := parsed.(json.Object); is_object {
			for key in ([]string{"text", "message"}) {
				if text, is_string := object[key].(json.String); is_string {
					message, _ = strings.clone(string(text))
					found = true
					break
				}
			}
		}
		json.destroy_value(parsed)
		if found {
			return message, true
		}
	}
	return "", false
}

// host_test_submit sends one submit and returns the accepted work-item id.
@(private)
host_test_submit :: proc(t: ^testing.T, rig: ^Host_Test_Rig, session_id, prompt, provider, model, thinking: string) -> string {
	testing.expect(t, host_test_write_message(&rig.peer, Host_Test_Submit{
		message_type = "submit",
		session_id   = session_id,
		prompt       = prompt,
		provider     = provider,
		model        = model,
		thinking     = thinking,
	}), "the submit could not be written")

	accepted, accepted_found := host_test_wait_type(&rig.peer, "accepted", HOST_TEST_TIMEOUT_MS)
	if !accepted_found {
		testing.expect(t, false, "no accepted reply arrived")
		return ""
	}
	defer delete(accepted)
	work_item_id, id_found := host_test_field(accepted, "work_item_id")
	testing.expect(t, id_found, "accepted carried no work_item_id")
	return work_item_id
}

@(private)
host_test_quit :: proc(rig: ^Host_Test_Rig) {
	_ = host_test_write_message(&rig.peer, Host_Test_Type_Only{message_type = "quit"})
}

@(test)
test_host_runs_a_work_item_end_to_end :: proc(t: ^testing.T) {
	sync.mutex_lock(&host_test_lock)
	defer sync.mutex_unlock(&host_test_lock)
	sync.mutex_lock(&runtime_test_lock)
	defer sync.mutex_unlock(&runtime_test_lock)

	previous_timeout := host_model_timeout_ms
	host_model_timeout_ms = 5_000
	defer host_model_timeout_ms = previous_timeout

	rig := host_test_rig_start(t, .Respond, "scripted final answer")
	accepted_id := host_test_submit(t, rig, "host-session-1", "say hello", "test-provider", "test-model", "low")

	// The whole path has run when the final_result event carries the scripted
	// text back from provider_remote.
	event_line, event_found := host_test_wait_event(&rig.peer, "final_result", HOST_TEST_TIMEOUT_MS)
	testing.expect(t, event_found, "no final_result event arrived")
	message, work_item_id, message_found := "", "", false
	if event_found {
		message, _ = host_test_field(event_line, "message")
		work_item_id, message_found = host_test_field(event_line, "work_item_id")
		testing.expect(t, message_found, "the event carried no work_item_id")
	}
	testing.expect_value(t, message, "scripted final answer")
	testing.expect_value(t, work_item_id, accepted_id)

	host_test_quit(rig)
	status := host_test_rig_finish(t, rig)
	testing.expect_value(t, status, 0)

	// The run is durable: the session the submit named exists, and the item
	// completed with the scripted text recorded.
	host := host_test_open_store(t, rig.store_path)
	item_status := host_test_item_status(t, host, work_item_id)
	testing.expect_value(t, item_status, store.WORK_ITEM_COMPLETED)
	delete(item_status)
	recorded, recorded_found := host_test_final_record_message(t, host, work_item_id)
	testing.expect(t, recorded_found, "the final record was not written")
	testing.expect_value(t, recorded, "scripted final answer")
	delete(recorded)
	close_err := close_host(&host)
	host_error_destroy(&close_err)

	delete(event_line)
	delete(message)
	delete(work_item_id)
	delete(accepted_id)
	host_test_rig_free(rig)
}

@(test)
test_host_model_request_carries_the_run_settings :: proc(t: ^testing.T) {
	sync.mutex_lock(&host_test_lock)
	defer sync.mutex_unlock(&host_test_lock)
	sync.mutex_lock(&runtime_test_lock)
	defer sync.mutex_unlock(&runtime_test_lock)

	previous_timeout := host_model_timeout_ms
	host_model_timeout_ms = 5_000
	defer host_model_timeout_ms = previous_timeout

	rig := host_test_rig_start(t, .Respond, "ok")
	accepted_id := host_test_submit(t, rig, "host-session-2", "inspect the request", "test-provider", "test-model", "medium")

	request_line, request_found := host_test_wait_type(&rig.peer, "model_request", HOST_TEST_TIMEOUT_MS)
	testing.expect(t, request_found, "the host asked for no model turn")
	if request_found {
		host_test_expect_field(t, request_line, "type", "model_request")
		host_test_expect_field(t, request_line, "provider", "test-provider")
		host_test_expect_field(t, request_line, "model", "test-model")
		host_test_expect_field(t, request_line, "thinking", "medium")
		role, text, message_ok := host_test_first_message(request_line)
		testing.expect(t, message_ok, "the request carried no messages")
		testing.expect_value(t, role, "user")
		testing.expect_value(t, text, "inspect the request")
		delete(role)
		delete(text)
	}

	host_test_quit(rig)
	status := host_test_rig_finish(t, rig)
	testing.expect_value(t, status, 0)

	delete(request_line)
	delete(accepted_id)
	host_test_rig_free(rig)
}

@(test)
test_host_model_error_fails_the_work_item :: proc(t: ^testing.T) {
	sync.mutex_lock(&host_test_lock)
	defer sync.mutex_unlock(&host_test_lock)
	sync.mutex_lock(&runtime_test_lock)
	defer sync.mutex_unlock(&runtime_test_lock)

	previous_timeout := host_model_timeout_ms
	host_model_timeout_ms = 5_000
	defer host_model_timeout_ms = previous_timeout

	rig := host_test_rig_start(t, .Error, "")
	accepted_id := host_test_submit(t, rig, "host-session-3", "this will fail", "test-provider", "test-model", "low")

	request_line, request_found := host_test_wait_type(&rig.peer, "model_request", HOST_TEST_TIMEOUT_MS)
	delete(request_line)
	testing.expect(t, request_found, "the host asked for no model turn")
	testing.expect(t, host_test_wait_replies(&rig.peer, 1, HOST_TEST_TIMEOUT_MS), "the peer did not answer")

	host_test_quit(rig)
	status := host_test_rig_finish(t, rig)
	testing.expect_value(t, status, 0)

	host := host_test_open_store(t, rig.store_path)
	item_status := host_test_item_status(t, host, accepted_id)
	testing.expect_value(t, item_status, store.WORK_ITEM_FAILED)
	delete(item_status)
	// A failed run reports no final_result; it fails instead of hanging.
	_, final_found := host_test_find_event(&rig.peer, "final_result")
	testing.expect(t, !final_found, "a failed run emitted a final_result")
	close_err := close_host(&host)
	host_error_destroy(&close_err)

	delete(accepted_id)
	host_test_rig_free(rig)
}

@(test)
test_host_quit_stops_cleanly :: proc(t: ^testing.T) {
	sync.mutex_lock(&host_test_lock)
	defer sync.mutex_unlock(&host_test_lock)
	sync.mutex_lock(&runtime_test_lock)
	defer sync.mutex_unlock(&runtime_test_lock)

	previous_timeout := host_model_timeout_ms
	host_model_timeout_ms = 5_000
	defer host_model_timeout_ms = previous_timeout

	rig := host_test_rig_start(t, .Respond, "done")
	accepted_id := host_test_submit(t, rig, "host-session-4", "finish then stop", "test-provider", "test-model", "low")

	event_line, event_found := host_test_wait_event(&rig.peer, "final_result", HOST_TEST_TIMEOUT_MS)
	testing.expect(t, event_found, "the run did not finish")
	delete(event_line)

	host_test_quit(rig)
	// Joining both threads proves the host's pool and serving loop are gone.
	status := host_test_rig_finish(t, rig)
	testing.expect_value(t, status, 0)

	stopped_line, stopped_found := host_test_find_type(&rig.peer, "stopped")
	testing.expect(t, stopped_found, "the host did not report stopped")
	delete(stopped_line)

	// Reopening the store proves the host released its connection and the
	// session it opened survived the stop.
	host := host_test_open_store(t, rig.store_path)
	session, session_found, session_err := find_session(host, "host-session-4")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)
	testing.expect(t, session_found, "the session the host opened is gone")
	close_err := close_host(&host)
	host_error_destroy(&close_err)

	delete(accepted_id)
	host_test_rig_free(rig)
}

@(test)
test_host_quit_cancels_a_silent_model_wait :: proc(t: ^testing.T) {
	sync.mutex_lock(&host_test_lock)
	defer sync.mutex_unlock(&host_test_lock)
	sync.mutex_lock(&runtime_test_lock)
	defer sync.mutex_unlock(&runtime_test_lock)

	previous_timeout := host_model_timeout_ms
	host_model_timeout_ms = 1_000
	defer host_model_timeout_ms = previous_timeout

	rig := host_test_rig_start(t, .Silent, "")
	accepted_id := host_test_submit(t, rig, "host-session-quit-cancel", "nobody will answer", "test-provider", "test-model", "low")

	request_line, request_found := host_test_wait_type(&rig.peer, "model_request", HOST_TEST_TIMEOUT_MS)
	delete(request_line)
	testing.expect(t, request_found, "the host asked for no model turn")
	testing.expect(t, host_test_wait_replies(&rig.peer, 1, HOST_TEST_TIMEOUT_MS), "the peer saw no request")

	started := time.now()
	host_test_quit(rig)
	status := host_test_rig_finish(t, rig)
	elapsed_ms := cast(i64)(time.since(started) / time.Millisecond)
	fmt.printf("%s: quit wait %d ms\n", "test_host_quit_cancels_a_silent_model_wait", elapsed_ms)
	testing.expect_value(t, status, 0)
	testing.expect(t, elapsed_ms < 500, "quit waited for the model timeout")

	host := host_test_open_store(t, rig.store_path)
	item_status := host_test_item_status(t, host, accepted_id)
	testing.expect_value(t, item_status, store.WORK_ITEM_FAILED)
	delete(item_status)
	reason, reason_found := host_test_final_record_message(t, host, accepted_id)
	testing.expect(t, reason_found, "the cancellation reason was not recorded")
	testing.expect(t, !strings.contains(reason, "timeout"), "the quit was recorded as a timeout")
	delete(reason)
	close_err := close_host(&host)
	host_error_destroy(&close_err)

	delete(accepted_id)
	host_test_rig_free(rig)
}

@(test)
test_host_model_reply_timeout_fails_the_work_item :: proc(t: ^testing.T) {
	sync.mutex_lock(&host_test_lock)
	defer sync.mutex_unlock(&host_test_lock)
	sync.mutex_lock(&runtime_test_lock)
	defer sync.mutex_unlock(&runtime_test_lock)

	previous_timeout := host_model_timeout_ms
	host_model_timeout_ms = 250
	defer host_model_timeout_ms = previous_timeout

	// The peer never answers, so the run must fail on the timeout rather than
	// hang the worker or the pool.
	rig := host_test_rig_start(t, .Silent, "")
	accepted_id := host_test_submit(t, rig, "host-session-5", "nobody will answer", "test-provider", "test-model", "low")

	request_line, request_found := host_test_wait_type(&rig.peer, "model_request", HOST_TEST_TIMEOUT_MS)
	delete(request_line)
	testing.expect(t, request_found, "the host asked for no model turn")
	testing.expect(t, host_test_wait_replies(&rig.peer, 1, HOST_TEST_TIMEOUT_MS), "the peer saw no request")
	// Let the bounded model wait expire before quitting, so this test covers
	// the no-quit anti-hang path rather than cancellation.
	time.sleep(300 * time.Millisecond)

	host_test_quit(rig)
	status := host_test_rig_finish(t, rig)
	testing.expect_value(t, status, 0)

	host := host_test_open_store(t, rig.store_path)
	item_status := host_test_item_status(t, host, accepted_id)
	testing.expect_value(t, item_status, store.WORK_ITEM_FAILED)
	delete(item_status)
	reason, reason_found := host_test_final_record_message(t, host, accepted_id)
	testing.expect(t, reason_found, "the failure reason was not recorded")
	testing.expect(t, strings.contains(reason, "timeout"), "the failure was not the model-reply timeout")
	delete(reason)
	close_err := close_host(&host)
	host_error_destroy(&close_err)

	delete(accepted_id)
	host_test_rig_free(rig)
}
