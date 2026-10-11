package oreo

// Tests for the host-process transport. They run against the real bundled
// SQLite engine through the host helpers and a fake Work_Fn that never calls a
// model. The relay's active state is one package value, so these tests take one
// lock and run one at a time.

import "base:runtime"
import "core:bufio"
import "core:bytes"
import "core:encoding/json"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

@(private)
TRANSPORT_TEST_RESULT :: "transport result"

// transport_test_lock serializes the tests because the fake work state and the
// transport's active relay pointer are shared.
@(private)
transport_test_lock: sync.Mutex

// The fake completes immediately unless its gate is closed, which lets a test
// observe the accepted reply before the final result.
@(private)
Transport_Test_Fake :: struct {
	mutex: sync.Mutex,
	cond:  sync.Cond,
	open:  bool,
	calls: int,
}

@(private)
transport_test_fake: Transport_Test_Fake

@(private)
transport_test_work :: proc(input: Work_Item_Input) -> Work_Item_Result {
	fake := &transport_test_fake
	sync.mutex_lock(&fake.mutex)
	fake.calls += 1
	for !fake.open {
		sync.cond_wait(&fake.cond, &fake.mutex)
	}
	sync.mutex_unlock(&fake.mutex)
	return Work_Item_Result{ok = true, output = TRANSPORT_TEST_RESULT}
}

@(private)
transport_test_fake_reset :: proc(open: bool) {
	sync.mutex_lock(&transport_test_fake.mutex)
	transport_test_fake.open = open
	transport_test_fake.calls = 0
	sync.cond_broadcast(&transport_test_fake.cond)
	sync.mutex_unlock(&transport_test_fake.mutex)
}

@(private)
transport_test_fake_open :: proc() {
	sync.mutex_lock(&transport_test_fake.mutex)
	transport_test_fake.open = true
	sync.cond_broadcast(&transport_test_fake.cond)
	sync.mutex_unlock(&transport_test_fake.mutex)
}

@(private)
transport_test_fake_calls :: proc() -> int {
	sync.mutex_lock(&transport_test_fake.mutex)
	defer sync.mutex_unlock(&transport_test_fake.mutex)
	return transport_test_fake.calls
}

// The in-memory reader blocks until the test writes more input or closes it, so
// a test can drive the protocol one request at a time.
@(private)
Transport_Test_Input :: struct {
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	buffer: [dynamic]byte,
	closed: bool,
}

@(private)
transport_test_input_read :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
	if mode != .Read {
		return 0, .Unsupported
	}
	stream := cast(^Transport_Test_Input)data
	sync.mutex_lock(&stream.mutex)
	defer sync.mutex_unlock(&stream.mutex)
	for len(stream.buffer) == 0 && !stream.closed {
		sync.cond_wait(&stream.cond, &stream.mutex)
	}
	if len(stream.buffer) == 0 {
		return 0, .EOF
	}
	count := copy(p, stream.buffer[:])
	remaining := len(stream.buffer) - count
	copy(stream.buffer[:remaining], stream.buffer[count:])
	resize(&stream.buffer, remaining)
	return i64(count), nil
}

@(private)
transport_test_input_write :: proc(stream: ^Transport_Test_Input, data: []byte) {
	sync.mutex_lock(&stream.mutex)
	defer sync.mutex_unlock(&stream.mutex)
	_, _ = append(&stream.buffer, ..data)
	sync.cond_broadcast(&stream.cond)
}

@(private)
transport_test_input_write_text :: proc(stream: ^Transport_Test_Input, text: string) {
	transport_test_input_write(stream, transmute([]byte)text)
}

@(private)
transport_test_input_close :: proc(stream: ^Transport_Test_Input) {
	sync.mutex_lock(&stream.mutex)
	stream.closed = true
	sync.cond_broadcast(&stream.cond)
	sync.mutex_unlock(&stream.mutex)
}

@(private)
transport_test_reader :: proc(stream: ^Transport_Test_Input) -> io.Reader {
	return io.Reader{procedure = transport_test_input_read, data = rawptr(stream)}
}

// The in-memory writer captures every byte the server writes.
@(private)
Transport_Test_Output :: struct {
	mutex:  sync.Mutex,
	buffer: [dynamic]byte,
}

@(private)
transport_test_output_write :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
	if mode != .Write {
		return 0, .Unsupported
	}
	stream := cast(^Transport_Test_Output)data
	sync.mutex_lock(&stream.mutex)
	defer sync.mutex_unlock(&stream.mutex)
	_, _ = append(&stream.buffer, ..p)
	return i64(len(p)), nil
}

@(private)
transport_test_writer :: proc(stream: ^Transport_Test_Output) -> io.Writer {
	return io.Writer{procedure = transport_test_output_write, data = rawptr(stream)}
}

// transport_test_output_line returns a cloned copy of one complete output line.
@(private)
transport_test_output_line :: proc(stream: ^Transport_Test_Output, wanted: int) -> (string, bool) {
	sync.mutex_lock(&stream.mutex)
	defer sync.mutex_unlock(&stream.mutex)
	rest := stream.buffer[:]
	index := 0
	for {
		newline := bytes.index_byte(rest, '\n')
		if newline < 0 {
			return "", false
		}
		if index == wanted {
			return strings.clone_from_bytes(rest[:newline]), true
		}
		index += 1
		rest = rest[newline + 1:]
	}
}

@(private)
transport_test_wait_line :: proc(t: ^testing.T, stream: ^Transport_Test_Output, index: int) -> string {
	deadline := time.now()
	for time.since(deadline) < 5 * time.Second {
		if line, found := transport_test_output_line(stream, index); found {
			return line
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, false, "transport output line %d did not arrive", index)
	return ""
}

@(private)
transport_test_output_lines :: proc(stream: ^Transport_Test_Output) -> [dynamic]string {
	sync.mutex_lock(&stream.mutex)
	defer sync.mutex_unlock(&stream.mutex)
	lines: [dynamic]string
	rest := stream.buffer[:]
	for {
		newline := bytes.index_byte(rest, '\n')
		if newline < 0 {
			if len(rest) > 0 {
				_, _ = append(&lines, strings.clone_from_bytes(rest))
			}
			return lines
		}
		if newline > 0 {
			_, _ = append(&lines, strings.clone_from_bytes(rest[:newline]))
		}
		rest = rest[newline + 1:]
	}
}

@(private)
transport_test_lines_destroy :: proc(lines: [dynamic]string) {
	for line in lines {
		delete(line)
	}
	delete(lines)
}

// transport_test_field decodes one string field from an output line.
@(private)
transport_test_field :: proc(line, key: string) -> (string, bool) {
	parsed: json.Value
	if json.unmarshal_string(line, &parsed, .JSON) != nil {
		return "", false
	}
	defer json.destroy_value(parsed)
	object, is_object := parsed.(json.Object)
	if !is_object {
		return "", false
	}
	field, has_field := object[key]
	if !has_field {
		return "", false
	}
	text, is_string := field.(json.String)
	if !is_string {
		return "", false
	}
	return strings.clone(string(text)), true
}

@(private)
transport_test_int_field :: proc(line, key: string) -> (i64, bool) {
	parsed: json.Value
	if json.unmarshal_string(line, &parsed, .JSON) != nil {
		return 0, false
	}
	defer json.destroy_value(parsed)
	object, is_object := parsed.(json.Object)
	if !is_object {
		return 0, false
	}
	field, has_field := object[key]
	if !has_field {
		return 0, false
	}
	number, is_integer := field.(json.Integer)
	if !is_integer {
		return 0, false
	}
	return i64(number), true
}

@(private)
transport_test_line_type :: proc(line: string) -> string {
	value, found := transport_test_field(line, "type")
	if !found {
		return ""
	}
	return value
}

@(private)
transport_test_parses :: proc(line: string) -> bool {
	parsed: json.Value
	if json.unmarshal_string(line, &parsed, .JSON) != nil {
		return false
	}
	json.destroy_value(parsed)
	return true
}

// Request shapes mirror the protocol so a test builds valid JSON with the same
// encoder the server uses.
@(private)
Transport_Test_Type_Only :: struct {
	message_type: string `json:"type"`,
}

@(private)
Transport_Test_Submit :: struct {
	message_type: string `json:"type"`,
	session_id:   string,
	prompt:       string,
	provider:     string,
	model:        string,
	thinking:     string,
}

@(private)
Transport_Test_Close_Session :: struct {
	message_type: string `json:"type"`,
	session_id:   string,
}

@(private)
transport_test_send :: proc(stream: ^Transport_Test_Input, value: any) {
	encoded, marshal_err := json.marshal(value)
	assert(marshal_err == nil)
	defer delete(encoded)
	line := make([]byte, len(encoded) + 1)
	defer delete(line)
	copy(line, encoded)
	line[len(encoded)] = '\n'
	transport_test_input_write(stream, line)
}

@(private)
transport_test_write_request :: proc(t: ^testing.T, file: ^os.File, value: any) {
	encoded, marshal_err := json.marshal(value)
	testing.expect(t, marshal_err == nil)
	defer delete(encoded)
	line := make([]byte, len(encoded) + 1)
	defer delete(line)
	copy(line, encoded)
	line[len(encoded)] = '\n'
	written, write_err := os.write(file, line)
	testing.expect_value(t, write_err, os.Error(nil))
	testing.expect_value(t, written, len(line))
}

// The serve thread adopts the test's allocator so its allocations are tracked
// and released by the same owner.
@(private)
Transport_Test_Server :: struct {
	config:    Transport_Config,
	input:     io.Reader,
	output:    io.Writer,
	allocator: runtime.Allocator,
	result:    Host_Error,
}

@(private)
transport_test_server_run :: proc(worker: ^thread.Thread) {
	server := cast(^Transport_Test_Server)worker.data
	context.allocator = server.allocator
	server.result = transport_serve(server.config, server.input, server.output)
}

@(private)
transport_test_start_server :: proc(server: ^Transport_Test_Server) -> ^thread.Thread {
	worker := thread.create(transport_test_server_run)
	assert(worker != nil)
	worker.data = rawptr(server)
	thread.start(worker)
	return worker
}

@(private)
transport_test_host :: proc(t: ^testing.T) -> (Host, string, string) {
	directory, directory_err := os.make_directory_temp(TEMP_DIR, "oreo-transport-*", context.allocator)
	testing.expect_value(t, directory_err, os.Error(nil))
	path, path_err := filepath.join({directory, "sessions.db"}, context.allocator)
	testing.expect(t, path_err == nil)
	host, open_err := open_host(path)
	host_error_destroy(&open_err)
	testing.expect_value(t, open_err.kind, Host_Error_Kind.None)
	return host, directory, path
}

@(private)
transport_test_cleanup :: proc(host: ^Host, directory, path: string) {
	close_err := close_host(host)
	host_error_destroy(&close_err)
	_ = os.remove_all(directory)
	delete(directory)
	delete(path)
}

@(private)
transport_test_teardown :: proc(t: ^testing.T, server: ^Transport_Test_Server, worker: ^thread.Thread, input: ^Transport_Test_Input) {
	// Open the fake gate first so a blocked worker cannot stall the pool join.
	transport_test_fake_open()
	transport_test_input_close(input)
	thread.destroy(worker)
	testing.expect_value(t, server.result.kind, Host_Error_Kind.None)
	host_error_destroy(&server.result)
}

@(test)
test_transport_scripted_session :: proc(t: ^testing.T) {
	sync.mutex_lock(&transport_test_lock)
	defer sync.mutex_unlock(&transport_test_lock)

	host, directory, path := transport_test_host(t)
	defer transport_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "transport session")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	transport_test_fake_reset(open = false)

	input: Transport_Test_Input
	defer delete(input.buffer)
	output: Transport_Test_Output
	defer delete(output.buffer)

	server := Transport_Test_Server{
		config    = Transport_Config{host = host, work = transport_test_work, workers = 1},
		input     = transport_test_reader(&input),
		output    = transport_test_writer(&output),
		allocator = context.allocator,
	}
	worker := transport_test_start_server(&server)

	// The ready line is first because it is written before the pool starts.
	ready_line := transport_test_wait_line(t, &output, 0)
	defer delete(ready_line)
	testing.expect(t, transport_test_parses(ready_line))
	ready_type := transport_test_line_type(ready_line)
	defer delete(ready_type)
	testing.expect_value(t, ready_type, "ready")
	ready_protocol, has_protocol := transport_test_int_field(ready_line, "protocol")
	testing.expect(t, has_protocol)
	testing.expect_value(t, ready_protocol, i64(TRANSPORT_PROTOCOL))

	transport_test_send(&input, Transport_Test_Submit{
		message_type = "submit",
		session_id   = session.id,
		prompt       = "scripted prompt",
		provider     = "fake-provider",
		model        = "fake-model",
		thinking     = "low",
	})

	// A worker emits progress as soon as the item starts, so the accepted reply
	// may be preceded by progress. The gate keeps it ahead of the final result.
	index := 1
	accepted_id := ""
	final_id := ""
	saw_accepted := false
	saw_final := false
	for !saw_final {
		line := transport_test_wait_line(t, &output, index)
		index += 1
		if len(line) == 0 {
			break
		}
		testing.expect(t, transport_test_parses(line))
		line_type := transport_test_line_type(line)
		switch line_type {
		case "accepted":
			saw_accepted = true
			item_id, found := transport_test_field(line, "work_item_id")
			testing.expect(t, found)
			delete(accepted_id)
			accepted_id = item_id
			transport_test_fake_open()
		case "event":
			kind, found := transport_test_field(line, "kind")
			testing.expect(t, found)
			if kind == "final_result" {
				saw_final = true
				item_id, item_found := transport_test_field(line, "work_item_id")
				testing.expect(t, item_found)
				delete(final_id)
				final_id = item_id
				message, message_found := transport_test_field(line, "message")
				testing.expect(t, message_found)
				testing.expect_value(t, message, TRANSPORT_TEST_RESULT)
				delete(message)
			}
			delete(kind)
		case:
			testing.expectf(t, false, "unexpected transport line %q", line_type)
		}
		delete(line_type)
		delete(line)
	}
	testing.expect(t, saw_accepted, "no accepted reply arrived")
	testing.expect(t, saw_final, "no final_result event arrived")
	testing.expect_value(t, accepted_id, final_id)
	testing.expect_value(t, transport_test_fake_calls(), 1)
	delete(accepted_id)
	delete(final_id)

	transport_test_send(&input, Transport_Test_Type_Only{message_type = "quit"})
	stopped_line := transport_test_wait_line(t, &output, index)
	index += 1
	defer delete(stopped_line)
	testing.expect(t, transport_test_parses(stopped_line))
	stopped_type := transport_test_line_type(stopped_line)
	defer delete(stopped_type)
	testing.expect_value(t, stopped_type, "stopped")

	transport_test_teardown(t, &server, worker, &input)
}

@(test)
test_transport_rejects_malformed_and_unknown :: proc(t: ^testing.T) {
	sync.mutex_lock(&transport_test_lock)
	defer sync.mutex_unlock(&transport_test_lock)

	host, directory, path := transport_test_host(t)
	defer transport_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "transport errors")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	transport_test_fake_reset(open = true)

	input: Transport_Test_Input
	defer delete(input.buffer)
	output: Transport_Test_Output
	defer delete(output.buffer)

	server := Transport_Test_Server{
		config    = Transport_Config{host = host, work = transport_test_work, workers = 1},
		input     = transport_test_reader(&input),
		output    = transport_test_writer(&output),
		allocator = context.allocator,
	}
	worker := transport_test_start_server(&server)

	// A malformed line and an unknown type are both answered and survived: a
	// following close_session is served normally.
	transport_test_input_write_text(&input, "this is not json\n")
	transport_test_send(&input, Transport_Test_Type_Only{message_type = "definitely_not_a_request"})
	transport_test_send(&input, Transport_Test_Close_Session{message_type = "close_session", session_id = session.id})
	transport_test_send(&input, Transport_Test_Type_Only{message_type = "quit"})

	transport_test_teardown(t, &server, worker, &input)

	lines := transport_test_output_lines(&output)
	defer transport_test_lines_destroy(lines)
	expected := [5]string{"ready", "error", "error", "closed", "stopped"}
	testing.expect_value(t, len(lines), len(expected))
	if len(lines) == len(expected) {
		for line, index in lines {
			testing.expect(t, transport_test_parses(line))
			line_type := transport_test_line_type(line)
			testing.expect_value(t, line_type, expected[index])
			delete(line_type)
		}
	}
}

@(test)
test_transport_close_session_closes_store_session :: proc(t: ^testing.T) {
	sync.mutex_lock(&transport_test_lock)
	defer sync.mutex_unlock(&transport_test_lock)

	host, directory, path := transport_test_host(t)
	defer transport_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "transport close")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	transport_test_fake_reset(open = true)

	input: Transport_Test_Input
	defer delete(input.buffer)
	output: Transport_Test_Output
	defer delete(output.buffer)

	server := Transport_Test_Server{
		config    = Transport_Config{host = host, work = transport_test_work, workers = 1},
		input     = transport_test_reader(&input),
		output    = transport_test_writer(&output),
		allocator = context.allocator,
	}
	worker := transport_test_start_server(&server)

	transport_test_send(&input, Transport_Test_Close_Session{message_type = "close_session", session_id = session.id})
	transport_test_send(&input, Transport_Test_Type_Only{message_type = "quit"})

	transport_test_teardown(t, &server, worker, &input)

	lines := transport_test_output_lines(&output)
	defer transport_test_lines_destroy(lines)
	expected := [3]string{"ready", "closed", "stopped"}
	testing.expect_value(t, len(lines), len(expected))
	if len(lines) == len(expected) {
		for line, index in lines {
			testing.expect(t, transport_test_parses(line))
			line_type := transport_test_line_type(line)
			testing.expect_value(t, line_type, expected[index])
			delete(line_type)
		}
	}

	closed, found, find_err := find_session(host, session.id)
	defer session_destroy(&closed)
	defer host_error_destroy(&find_err)
	testing.expect_value(t, find_err.kind, Host_Error_Kind.None)
	testing.expect(t, found)
	testing.expect_value(t, closed.status, SESSION_CLOSED)
}

@(test)
test_transport_over_os_pipe :: proc(t: ^testing.T) {
	sync.mutex_lock(&transport_test_lock)
	defer sync.mutex_unlock(&transport_test_lock)

	host, directory, path := transport_test_host(t)
	defer transport_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "transport pipe")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	transport_test_fake_reset(open = true)

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

	server := Transport_Test_Server{
		config    = Transport_Config{host = host, work = transport_test_work, workers = 1},
		input     = os.to_reader(request_read),
		output    = os.to_writer(response_write),
		allocator = context.allocator,
	}
	worker := transport_test_start_server(&server)

	// The pipe preserves byte order, so the server reads submit before quit.
	transport_test_write_request(t, request_write, Transport_Test_Submit{
		message_type = "submit",
		session_id   = session.id,
		prompt       = "pipe prompt",
		provider     = "fake-provider",
		model        = "fake-model",
		thinking     = "low",
	})
	transport_test_write_request(t, request_write, Transport_Test_Type_Only{message_type = "quit"})

	lines: [dynamic]string
	defer transport_test_lines_destroy(lines)
	pipe_buffer: [dynamic]byte
	defer delete(pipe_buffer)
	saw_accepted := false
	saw_stopped := false
	for !saw_stopped {
		line, found := transport_test_pipe_line(t, response_read, &pipe_buffer)
		if !found {
			break
		}
		testing.expect(t, transport_test_parses(line))
		line_type := transport_test_line_type(line)
		switch line_type {
		case "accepted":
			saw_accepted = true
		case "stopped":
			saw_stopped = true
		}
		delete(line_type)
		_, _ = append(&lines, line)
	}

	testing.expect(t, len(lines) > 0, "the pipe produced no output")
	if len(lines) > 0 {
		first_type := transport_test_line_type(lines[0])
		testing.expect_value(t, first_type, "ready")
		delete(first_type)
		last_type := transport_test_line_type(lines[len(lines) - 1])
		testing.expect_value(t, last_type, "stopped")
		delete(last_type)
	}
	testing.expect(t, saw_accepted, "the pipe carried no accepted reply")
	testing.expect(t, saw_stopped, "the pipe carried no stopped reply")

	thread.destroy(worker)
	testing.expect_value(t, server.result.kind, Host_Error_Kind.None)
	host_error_destroy(&server.result)
}

@(test)
test_transport_eof_stops_server :: proc(t: ^testing.T) {
	sync.mutex_lock(&transport_test_lock)
	defer sync.mutex_unlock(&transport_test_lock)

	host, directory, path := transport_test_host(t)
	defer transport_test_cleanup(&host, directory, path)

	transport_test_fake_reset(open = true)

	input: Transport_Test_Input
	defer delete(input.buffer)
	output: Transport_Test_Output
	defer delete(output.buffer)

	server := Transport_Test_Server{
		config    = Transport_Config{host = host, work = transport_test_work, workers = 1},
		input     = transport_test_reader(&input),
		output    = transport_test_writer(&output),
		allocator = context.allocator,
	}
	worker := transport_test_start_server(&server)

	// No request is sent: end of input alone must stop the pool and return.
	transport_test_teardown(t, &server, worker, &input)

	lines := transport_test_output_lines(&output)
	defer transport_test_lines_destroy(lines)
	testing.expect_value(t, len(lines), 1)
	if len(lines) == 1 {
		testing.expect(t, transport_test_parses(lines[0]))
		line_type := transport_test_line_type(lines[0])
		testing.expect_value(t, line_type, "ready")
		delete(line_type)
	}
}

// transport_test_pipe_line reads one newline-terminated line from a pipe with a
// deadline, so a stalled server fails the test instead of hanging it.
@(private)
transport_test_pipe_line :: proc(t: ^testing.T, file: ^os.File, buffer: ^[dynamic]byte) -> (string, bool) {
	if line, found := transport_test_take_line(buffer); found {
		return line, true
	}
	deadline := time.now()
	for time.since(deadline) < 5*time.Second {
		poll_fds := [1]posix.pollfd{{fd = posix.FD(os.fd(file)), events = {.IN}}}
		if posix.poll(&poll_fds[0], 1, 100) <= 0 {
			continue
		}
		chunk: [4096]byte
		count, read_err := os.read(file, chunk[:])
		if count > 0 {
			_, _ = append(buffer, ..chunk[:count])
			if line, found := transport_test_take_line(buffer); found {
				return line, true
			}
		}
		if read_err != nil {
			break
		}
	}
	testing.expect(t, false, "the pipe produced no complete line before the deadline")
	return "", false
}

@(private)
transport_test_take_line :: proc(buffer: ^[dynamic]byte) -> (string, bool) {
	newline := bytes.index_byte(buffer[:], '\n')
	if newline < 0 {
		return "", false
	}
	line := strings.clone_from_bytes(buffer[:newline])
	remaining := len(buffer) - newline - 1
	copy(buffer[:remaining], buffer[newline + 1:])
	resize(buffer, remaining)
	return line, true
}
