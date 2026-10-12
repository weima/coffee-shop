package script

// Tests for the script-side tool API. Each case drives a fake host on a thread:
// a real AF_UNIX listener that accepts one connection and answers a scripted
// list of reply lines, recording every request line it received. The socket
// lives in a fresh temporary directory, and no case contacts the network or a
// model.
//
// The package opens one connection per process by design, so each case calls
// script_client_reset first and starts its own listener. A case that makes two
// tool calls and passes also proves the connection is reused: the fake host
// accepts only one.

import "base:runtime"
import "core:bytes"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"

@(private)
SCRIPT_TEST_TEMP_DIR :: "/private/tmp" when ODIN_OS == .Darwin else "/tmp"

// Stands in a reply template for the id of the request being answered, so a
// case never hard-codes an opaque id.
@(private)
SCRIPT_TEST_ID_PLACEHOLDER :: "{id}"

// A fake host waits this long for the next request before giving up, so a bug
// in a case fails an expectation instead of hanging the thread join.
@(private)
SCRIPT_TEST_POLL_MS :: 5_000

// OREO_SCRIPT_SOCKET is process-wide and the test runner runs cases on parallel
// threads, so every case that redirects it holds this lock and the package's
// one connection per process stays a per-case fact.
@(private)
script_test_suite_lock: sync.Mutex

@(private)
Script_Test_Host :: struct {
	path:      string,
	replies:   []string,
	received:  [dynamic]string,
	allocator: runtime.Allocator,
	listener:  posix.FD,
	accepted:  posix.FD,
}

@(private)
Script_Test_Value :: struct {
	name:  string `json:"name"`,
	count: int    `json:"count"`,
}

// script_test_socket_path makes a unique temporary directory and names a socket
// inside it. The caller owns both strings and calls script_test_cleanup.
@(private)
script_test_socket_path :: proc(t: ^testing.T, name: string) -> (directory: string, path: string) {
	dir, directory_err := os.make_directory_temp(SCRIPT_TEST_TEMP_DIR, "oreo-script-*", context.allocator)
	testing.expect_value(t, directory_err, os.Error(nil))
	return dir, fmt.aprintf("%s/%s.sock", dir, name, allocator = context.allocator)
}

@(private)
script_test_cleanup :: proc(directory, path: string) {
	_ = os.remove_all(directory)
	delete(directory)
	delete(path)
}

// The test binds and listens, so the client can only ever find a ready
// listener; the thread just accepts and answers.
@(private)
script_test_host_listen :: proc(t: ^testing.T, host: ^Script_Test_Host) {
	host.listener = posix.socket(.UNIX, .STREAM)
	testing.expect(t, host.listener != posix.FD(-1), "could not create the fake host socket")
	address := script_socket_address(host.path)
	bind_result := posix.bind(host.listener, (^posix.sockaddr)(&address), script_socket_address_len(host.path))
	testing.expect(t, bind_result == .OK, "could not bind the fake host socket")
	listen_result := posix.listen(host.listener, 1)
	testing.expect(t, listen_result == .OK, "could not listen on the fake host socket")
}

@(private)
script_test_host_start :: proc(host: ^Script_Test_Host) -> ^thread.Thread {
	worker := thread.create(script_test_host_run)
	assert(worker != nil, "could not create the fake host thread")
	worker.data = rawptr(host)
	thread.start(worker)
	return worker
}

@(private)
script_test_host_run :: proc(worker: ^thread.Thread) {
	host := cast(^Script_Test_Host)worker.data
	context.allocator = host.allocator
	wait_fds := [1]posix.pollfd{{fd = host.listener, events = {.IN}}}
	if posix.poll(&wait_fds[0], 1, SCRIPT_TEST_POLL_MS) <= 0 {
		return
	}
	host.accepted = posix.accept(host.listener, nil, nil)
	if host.accepted == posix.FD(-1) {
		return
	}
	for reply in host.replies {
		request, ok := script_test_recv_line(host.accepted)
		if !ok {
			break
		}
		append(&host.received, request)

		line := reply
		filled := false
		if id, found := script_test_field(request, "id"); found {
			line, filled = strings.replace_all(reply, SCRIPT_TEST_ID_PLACEHOLDER, id, context.allocator)
			delete(id, context.allocator)
		}
		script_test_send_line(host.accepted, line)
		if filled {
			delete(line, context.allocator)
		}
	}
	posix.close(host.accepted)
	host.accepted = posix.FD(-1)
}

// script_test_host_destroy closes the host and frees every line it owns. Run it
// after the worker has been joined.
@(private)
script_test_host_destroy :: proc(host: ^Script_Test_Host) {
	if host.accepted != posix.FD(-1) {
		posix.close(host.accepted)
	}
	if host.listener != posix.FD(-1) {
		posix.close(host.listener)
	}
	for line in host.received {
		delete(line, context.allocator)
	}
	delete(host.received)
	host^ = {}
}

// script_test_recv_line reads one newline-terminated line. It is deliberately
// separate from the package's reader, so a framing bug in the package cannot
// hide behind the fake host.
@(private)
script_test_recv_line :: proc(fd: posix.FD) -> (line: string, ok: bool) {
	builder: strings.Builder
	strings.builder_init(&builder, context.allocator)
	buffer: [4096]u8
	for {
		wait_fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
		if posix.poll(&wait_fds[0], 1, SCRIPT_TEST_POLL_MS) <= 0 {
			strings.builder_destroy(&builder)
			return "", false
		}
		n := posix.recv(fd, rawptr(&buffer[0]), c.size_t(len(buffer)), {})
		if n <= 0 {
			strings.builder_destroy(&builder)
			return "", false
		}
		chunk := buffer[:int(n)]
		if newline := bytes.index_byte(chunk, '\n'); newline >= 0 {
			strings.write_bytes(&builder, chunk[:newline])
			return strings.to_string(builder), true
		}
		strings.write_bytes(&builder, chunk)
	}
}

@(private)
script_test_send_line :: proc(fd: posix.FD, text: string) {
	line := make([]u8, len(text) + 1, context.allocator)
	defer delete(line, context.allocator)
	copy(line, text)
	line[len(text)] = '\n'
	sent := 0
	for sent < len(line) {
		remaining := len(line) - sent
		n := posix.send(fd, rawptr(&line[sent]), c.size_t(remaining), {.NOSIGNAL})
		if n <= 0 {
			return
		}
		sent += int(n)
	}
}

// script_test_field returns the string value of one top-level JSON field.
@(private)
script_test_field :: proc(line, key: string) -> (string, bool) {
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
Script_Test_Request :: struct {
	type: string     `json:"type"`,
	id:   string     `json:"id"`,
	tool: string     `json:"tool"`,
	args: json.Value `json:"args"`,
}

@(private)
script_test_parse :: proc(t: ^testing.T, line: string) -> Script_Test_Request {
	request: Script_Test_Request
	unmarshal_err := json.unmarshal_string(line, &request, .JSON)
	testing.expectf(t, unmarshal_err == nil, "the request line is not JSON: %s", line)
	return request
}

@(private)
script_test_request_destroy :: proc(request: ^Script_Test_Request) {
	delete(request.type)
	delete(request.id)
	delete(request.tool)
	json.destroy_value(request.args)
	request^ = {}
}

// The value of one string field inside args. The string is borrowed from the
// request; destroy the request, not the value.
@(private)
script_test_arg :: proc(request: ^Script_Test_Request, key: string) -> (value: string, found: bool) {
	object, is_object := request.args.(json.Object)
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
	return string(text), true
}

@(private)
script_test_arg_int :: proc(request: ^Script_Test_Request, key: string) -> (value: int, found: bool) {
	object, is_object := request.args.(json.Object)
	if !is_object {
		return 0, false
	}
	field, has_field := object[key]
	if !has_field {
		return 0, false
	}
	number, is_number := field.(json.Integer)
	if !is_number {
		return 0, false
	}
	return int(number), true
}

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

@(test)
test_execute_sends_a_well_formed_call :: proc(t: ^testing.T) {
	sync.mutex_lock(&script_test_suite_lock)
	defer sync.mutex_unlock(&script_test_suite_lock)
	script_client_reset()
	directory, path := script_test_socket_path(t, "execute")
	defer script_test_cleanup(directory, path)
	os.set_env(SCRIPT_SOCKET_ENV, path)
	defer os.unset_env(SCRIPT_SOCKET_ENV)

	host: Script_Test_Host
	host.path = path
	host.replies = {`{"type":"result","id":"{id}","ok":true,"output":"hello world","exit_code":0}`}
	host.allocator = context.allocator
	host.listener = posix.FD(-1)
	host.accepted = posix.FD(-1)
	defer script_test_host_destroy(&host)
	script_test_host_listen(t, &host)
	worker := script_test_host_start(&host)
	defer thread.destroy(worker)

	output, exit_code, err := execute("echo hello", directory)
	defer delete(output, context.allocator)
	thread.join(worker)

	testing.expectf(t, err.message == "", "execute reported: %s", err.message)
	error_destroy(&err)
	testing.expect_value(t, output, "hello world")
	testing.expect_value(t, exit_code, 0)

	testing.expect_value(t, len(host.received), 1)
	if len(host.received) < 1 {
		return
	}
	request := script_test_parse(t, host.received[0])
	defer script_test_request_destroy(&request)
	testing.expect(t, request.id != "", "the call needs a non-empty id")
	testing.expect_value(t, request.type, "call")
	testing.expect_value(t, request.tool, "execute")

	command, command_found := script_test_arg(&request, "command")
	testing.expect(t, command_found, "execute args must carry command")
	testing.expect_value(t, command, "echo hello")
	working_directory, directory_found := script_test_arg(&request, "working_directory")
	testing.expect(t, directory_found, "execute args must carry working_directory")
	testing.expect_value(t, working_directory, directory)

	// The exact wire line, so a formatting change cannot slip past the host.
	expected, _ := strings.concatenate(
		{
			`{"type":"call","id":"`,
			request.id,
			`","tool":"execute","args":{"command":"echo hello","working_directory":"`,
			directory,
			`"}}`,
		},
		context.temp_allocator,
	)
	testing.expect_value(t, host.received[0], expected)
}

@(test)
test_non_zero_exit_code_is_a_normal_result :: proc(t: ^testing.T) {
	sync.mutex_lock(&script_test_suite_lock)
	defer sync.mutex_unlock(&script_test_suite_lock)
	script_client_reset()
	directory, path := script_test_socket_path(t, "exit-code")
	defer script_test_cleanup(directory, path)
	os.set_env(SCRIPT_SOCKET_ENV, path)
	defer os.unset_env(SCRIPT_SOCKET_ENV)

	host: Script_Test_Host
	host.path = path
	// The first reply ran the command; the exit code is the command's, not a
	// tool failure. The second reply is a genuine tool failure.
	host.replies = {
		`{"type":"result","id":"{id}","ok":true,"output":"boom","exit_code":3}`,
		`{"type":"result","id":"{id}","ok":false,"output":"could not start the command","exit_code":1}`,
	}
	host.allocator = context.allocator
	host.listener = posix.FD(-1)
	host.accepted = posix.FD(-1)
	defer script_test_host_destroy(&host)
	script_test_host_listen(t, &host)
	worker := script_test_host_start(&host)
	defer thread.destroy(worker)

	output, exit_code, err := execute("false")
	defer delete(output, context.allocator)
	// One connection serves both calls, so the second request goes out before
	// the fake host is joined.
	failed_output, failed_exit_code, failed_err := execute("missing-command")
	defer delete(failed_output, context.allocator)
	thread.join(worker)

	testing.expectf(t, err.message == "", "a non-zero exit code is not an error: %s", err.message)
	error_destroy(&err)
	testing.expect_value(t, output, "boom")
	testing.expect_value(t, exit_code, 3)

	testing.expect(t, failed_err.message != "", "an ok=false reply must produce an Error")
	error_destroy(&failed_err)
	testing.expect_value(t, failed_output, "could not start the command")
	testing.expect_value(t, failed_exit_code, 1)
}

@(test)
test_read_and_write_send_their_args :: proc(t: ^testing.T) {
	sync.mutex_lock(&script_test_suite_lock)
	defer sync.mutex_unlock(&script_test_suite_lock)
	script_client_reset()
	directory, path := script_test_socket_path(t, "read-write")
	defer script_test_cleanup(directory, path)
	os.set_env(SCRIPT_SOCKET_ENV, path)
	defer os.unset_env(SCRIPT_SOCKET_ENV)

	host: Script_Test_Host
	host.path = path
	host.replies = {
		`{"type":"result","id":"{id}","ok":true,"output":"1\tone\n2\ttwo","exit_code":0}`,
		`{"type":"result","id":"{id}","ok":true,"output":"","exit_code":0}`,
	}
	host.allocator = context.allocator
	host.listener = posix.FD(-1)
	host.accepted = posix.FD(-1)
	defer script_test_host_destroy(&host)
	script_test_host_listen(t, &host)
	worker := script_test_host_start(&host)
	defer thread.destroy(worker)

	content, read_err := read("/tmp/read-target", 5, 10)
	defer delete(content, context.allocator)
	write_err := write("/tmp/write-target", "written text")
	thread.join(worker)

	testing.expectf(t, read_err.message == "", "read reported: %s", read_err.message)
	error_destroy(&read_err)
	testing.expect_value(t, content, "1\tone\n2\ttwo")
	testing.expectf(t, write_err.message == "", "write reported: %s", write_err.message)
	error_destroy(&write_err)

	testing.expect_value(t, len(host.received), 2)
	if len(host.received) < 2 {
		return
	}
	read_request := script_test_parse(t, host.received[0])
	defer script_test_request_destroy(&read_request)
	testing.expect_value(t, read_request.type, "call")
	testing.expect_value(t, read_request.tool, "read")
	read_path, read_path_found := script_test_arg(&read_request, "path")
	testing.expect(t, read_path_found, "read args must carry path")
	testing.expect_value(t, read_path, "/tmp/read-target")
	offset, offset_found := script_test_arg_int(&read_request, "offset")
	testing.expect(t, offset_found, "read args must carry offset")
	testing.expect_value(t, offset, 5)
	limit, limit_found := script_test_arg_int(&read_request, "limit")
	testing.expect(t, limit_found, "read args must carry limit")
	testing.expect_value(t, limit, 10)

	write_request := script_test_parse(t, host.received[1])
	defer script_test_request_destroy(&write_request)
	testing.expect_value(t, write_request.type, "call")
	testing.expect_value(t, write_request.tool, "write")
	write_path, write_path_found := script_test_arg(&write_request, "path")
	testing.expect(t, write_path_found, "write args must carry path")
	testing.expect_value(t, write_path, "/tmp/write-target")
	write_content, write_content_found := script_test_arg(&write_request, "content")
	testing.expect(t, write_content_found, "write args must carry content")
	testing.expect_value(t, write_content, "written text")
}

@(test)
test_mismatched_reply_id_is_an_error :: proc(t: ^testing.T) {
	sync.mutex_lock(&script_test_suite_lock)
	defer sync.mutex_unlock(&script_test_suite_lock)
	script_client_reset()
	directory, path := script_test_socket_path(t, "mismatch")
	defer script_test_cleanup(directory, path)
	os.set_env(SCRIPT_SOCKET_ENV, path)
	defer os.unset_env(SCRIPT_SOCKET_ENV)

	host: Script_Test_Host
	host.path = path
	host.replies = {`{"type":"result","id":"not-the-request-id","ok":true,"output":"not the answer","exit_code":0}`}
	host.allocator = context.allocator
	host.listener = posix.FD(-1)
	host.accepted = posix.FD(-1)
	defer script_test_host_destroy(&host)
	script_test_host_listen(t, &host)
	worker := script_test_host_start(&host)
	defer thread.destroy(worker)

	output, exit_code, err := execute("echo hello")
	defer delete(output, context.allocator)
	thread.join(worker)

	testing.expect(t, err.message != "", "a reply with another id must produce an Error")
	error_destroy(&err)
	// The wrong value must not be handed back as a result.
	testing.expect_value(t, output, "")
	testing.expect_value(t, exit_code, 0)
}

@(test)
test_malformed_reply_is_an_error :: proc(t: ^testing.T) {
	sync.mutex_lock(&script_test_suite_lock)
	defer sync.mutex_unlock(&script_test_suite_lock)
	script_client_reset()
	directory, path := script_test_socket_path(t, "malformed")
	defer script_test_cleanup(directory, path)
	os.set_env(SCRIPT_SOCKET_ENV, path)
	defer os.unset_env(SCRIPT_SOCKET_ENV)

	host: Script_Test_Host
	host.path = path
	// Valid JSON that is not a reply object, then a truncated line.
	host.replies = {
		`[1,2,3]`,
		`{"type":"result","id":`,
	}
	host.allocator = context.allocator
	host.listener = posix.FD(-1)
	host.accepted = posix.FD(-1)
	defer script_test_host_destroy(&host)
	script_test_host_listen(t, &host)
	worker := script_test_host_start(&host)
	defer thread.destroy(worker)

	output, _, err := execute("echo hello")
	defer delete(output, context.allocator)
	second_output, _, second_err := execute("echo hello")
	defer delete(second_output, context.allocator)
	thread.join(worker)

	testing.expect(t, err.message != "", "a non-object reply must produce an Error")
	error_destroy(&err)
	testing.expect_value(t, output, "")

	testing.expect(t, second_err.message != "", "a truncated reply must produce an Error")
	error_destroy(&second_err)
	testing.expect_value(t, second_output, "")
}

@(test)
test_missing_socket_path_is_an_error :: proc(t: ^testing.T) {
	sync.mutex_lock(&script_test_suite_lock)
	defer sync.mutex_unlock(&script_test_suite_lock)
	script_client_reset()
	os.unset_env(SCRIPT_SOCKET_ENV)
	defer os.unset_env(SCRIPT_SOCKET_ENV)

	output, exit_code, err := execute("echo hello")
	defer delete(output, context.allocator)

	testing.expect(t, err.message != "", "execute must fail while OREO_SCRIPT_SOCKET is unset")
	error_destroy(&err)
	testing.expect_value(t, output, "")
	testing.expect_value(t, exit_code, 0)
	testing.expect_value(t, script_test_connected(), false)
}

@(test)
test_unconnectable_socket_is_an_error :: proc(t: ^testing.T) {
	sync.mutex_lock(&script_test_suite_lock)
	defer sync.mutex_unlock(&script_test_suite_lock)
	script_client_reset()
	// A path with no listener and no socket file.
	path := "/tmp/oreo-script-test-no-listener.sock"
	os.set_env(SCRIPT_SOCKET_ENV, path)
	defer os.unset_env(SCRIPT_SOCKET_ENV)
	defer script_test_unlink(path)

	content, err := read("/tmp/anything")
	defer delete(content, context.allocator)

	testing.expect(t, err.message != "", "read must fail when nothing listens on the socket")
	error_destroy(&err)
	testing.expect_value(t, content, "")
	testing.expect_value(t, script_test_connected(), false)
}

@(test)
test_text_writes_to_stdout_and_never_uses_the_socket :: proc(t: ^testing.T) {
	sync.mutex_lock(&script_test_suite_lock)
	defer sync.mutex_unlock(&script_test_suite_lock)
	script_client_reset()
	// The environment names a path with no listener: text must still work,
	// which proves it never opened the socket.
	directory, path := script_test_socket_path(t, "text")
	defer script_test_cleanup(directory, path)
	os.set_env(SCRIPT_SOCKET_ENV, path)
	defer os.unset_env(SCRIPT_SOCKET_ENV)

	read_end, write_end, pipe_err := os.pipe()
	testing.expect_value(t, pipe_err, os.Error(nil))

	original_stdout := os.stdout
	os.stdout = write_end
	text("plain text")
	text(42)
	text(Script_Test_Value{name = "oreo", count = 2})
	os.stdout = original_stdout
	os.close(write_end)

	captured, read_err := os.read_entire_file_from_file(read_end, context.allocator)
	defer delete(captured, context.allocator)
	os.close(read_end)
	testing.expect_value(t, read_err, os.Error(nil))
	testing.expect_value(t, string(captured), "plain text\n42\n{\"name\":\"oreo\",\"count\":2}\n")
	testing.expect_value(t, script_test_connected(), false)
}

@(private)
script_test_connected :: proc() -> bool {
	return client.connected
}

@(private)
script_test_unlink :: proc(path: string) {
	path_bytes := make([]u8, len(path) + 1, context.allocator)
	defer delete(path_bytes, context.allocator)
	copy(path_bytes, path)
	posix.unlink(cstring(raw_data(path_bytes)))
}
