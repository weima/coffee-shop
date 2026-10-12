package oreo

// Hermetic tests for the script server. A fake script client runs on a thread
// and speaks the JSON-lines protocol over a temporary Unix socket. Every test
// owns its own temp directory, and the server removes its socket on stop.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

@(private)
SCRIPT_SERVER_TEST_TIMEOUT_MS :: 5_000

@(private)
Script_Test_Peer :: struct {
	socket_path: string,
	requests:    []string,
	replies:     [dynamic]string,
	allocator:   runtime.Allocator,
	failed:      bool,
}

@(private)
Script_Test_Reply :: struct {
	id:        string,
	ok:        bool,
	output:    string,
	exit_code: int,
}

@(private)
Script_Test_Read_Args :: struct {
	path:   string,
	offset: int,
	limit:  int,
}

@(private)
Script_Test_Execute_Args :: struct {
	command:           string,
	working_directory: string,
}

@(private)
Script_Test_No_Args :: struct {}

@(test)
test_script_server_read_call_returns_file_contents :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	socket_path := tools_test_path(t, directory, "script.sock")
	defer delete(socket_path)
	file_path := tools_test_path(t, directory, "note.txt")
	defer delete(file_path)
	write_err := tool_write(file_path, "alpha\nbeta\n")
	defer tool_error_destroy(&write_err)
	testing.expect_value(t, write_err.kind, Tool_Error_Kind.None)

	server := script_test_start(t, socket_path)
	defer script_test_stop(&server)

	requests := []string{
		script_test_request("r1", "read", Script_Test_Read_Args{path = file_path}),
	}
	defer script_test_requests_destroy(requests)
	replies, served := script_test_serve(t, &server, requests)
	defer script_test_replies_destroy(&replies)
	testing.expect(t, served)
	if len(replies) != len(requests) {
		return
	}

	reply := script_test_parse_reply(t, replies[0])
	defer script_test_reply_destroy(&reply)
	testing.expect_value(t, reply.id, "r1")
	testing.expect_value(t, reply.ok, true)
	testing.expect_value(t, reply.output, "1\talpha\n2\tbeta")
}

@(test)
test_script_server_execute_call_returns_output_and_exit_code :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	socket_path := tools_test_path(t, directory, "script.sock")
	defer delete(socket_path)

	server := script_test_start(t, socket_path)
	defer script_test_stop(&server)

	requests := []string{
		script_test_request(
			"e1",
			"execute",
			Script_Test_Execute_Args{command = "echo ok", working_directory = directory},
		),
		script_test_request(
			"e2",
			"execute",
			Script_Test_Execute_Args{
				command = "echo problem 1>&2; exit 7",
				working_directory = directory,
			},
		),
	}
	defer script_test_requests_destroy(requests)
	replies, served := script_test_serve(t, &server, requests)
	defer script_test_replies_destroy(&replies)
	testing.expect(t, served)
	if len(replies) != len(requests) {
		return
	}

	zero := script_test_parse_reply(t, replies[0])
	defer script_test_reply_destroy(&zero)
	testing.expect_value(t, zero.id, "e1")
	testing.expect_value(t, zero.ok, true)
	testing.expect_value(t, zero.output, "ok\n")
	testing.expect_value(t, zero.exit_code, 0)

	failing := script_test_parse_reply(t, replies[1])
	defer script_test_reply_destroy(&failing)
	testing.expect_value(t, failing.id, "e2")
	// A non-zero exit is a normal result, not an error.
	testing.expect_value(t, failing.ok, true)
	testing.expect_value(t, failing.output, "problem\n")
	testing.expect_value(t, failing.exit_code, 7)
}

@(test)
test_script_server_malformed_line_keeps_serving :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	socket_path := tools_test_path(t, directory, "script.sock")
	defer delete(socket_path)
	file_path := tools_test_path(t, directory, "note.txt")
	defer delete(file_path)
	write_err := tool_write(file_path, "kept\n")
	defer tool_error_destroy(&write_err)
	testing.expect_value(t, write_err.kind, Tool_Error_Kind.None)

	server := script_test_start(t, socket_path)
	defer script_test_stop(&server)

	requests := []string{
		strings.clone(`{"type":"call","id":"m1",`),
		script_test_request("m2", "read", Script_Test_Read_Args{path = file_path}),
	}
	defer script_test_requests_destroy(requests)
	replies, served := script_test_serve(t, &server, requests)
	defer script_test_replies_destroy(&replies)
	testing.expect(t, served)
	if len(replies) != len(requests) {
		return
	}

	malformed := script_test_parse_reply(t, replies[0])
	defer script_test_reply_destroy(&malformed)
	testing.expect_value(t, malformed.ok, false)

	following := script_test_parse_reply(t, replies[1])
	defer script_test_reply_destroy(&following)
	testing.expect_value(t, following.id, "m2")
	testing.expect_value(t, following.ok, true)
	testing.expect_value(t, following.output, "1\tkept")
}

@(test)
test_script_server_unknown_tool_is_a_failed_result :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	socket_path := tools_test_path(t, directory, "script.sock")
	defer delete(socket_path)

	server := script_test_start(t, socket_path)
	defer script_test_stop(&server)

	requests := []string{
		script_test_request("u1", "frobnicate", Script_Test_No_Args{}),
	}
	defer script_test_requests_destroy(requests)
	replies, served := script_test_serve(t, &server, requests)
	defer script_test_replies_destroy(&replies)
	testing.expect(t, served)
	if len(replies) != len(requests) {
		return
	}

	reply := script_test_parse_reply(t, replies[0])
	defer script_test_reply_destroy(&reply)
	testing.expect_value(t, reply.id, "u1")
	testing.expect_value(t, reply.ok, false)
	testing.expect(t, strings.contains(reply.output, "unknown tool"))
}

@(test)
test_script_server_deadline_returns_without_a_client :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	socket_path := tools_test_path(t, directory, "script.sock")
	defer delete(socket_path)

	server := script_test_start(t, socket_path)
	defer script_test_stop(&server)

	start := time.tick_now()
	served, serve_err := script_server_serve_one(&server, 100)
	elapsed := time.tick_since(start)
	defer host_error_destroy(&serve_err)

	testing.expect(t, !served)
	testing.expect_value(t, serve_err.kind, Host_Error_Kind.None)
	// It waited for the deadline rather than returning at once, and it did not
	// hang past it.
	testing.expect(t, elapsed >= 50 * time.Millisecond)
	testing.expect(t, elapsed < time.Second)
}

@(test)
test_script_server_stop_removes_the_socket_and_is_idempotent :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	socket_path := tools_test_path(t, directory, "script.sock")
	defer delete(socket_path)

	server := script_test_start(t, socket_path)

	stop_err := script_server_stop(&server)
	defer host_error_destroy(&stop_err)
	testing.expect_value(t, stop_err.kind, Host_Error_Kind.None)

	info, stat_err := os.stat(socket_path, context.allocator)
	if stat_err == nil {
		os.file_info_delete(info, context.allocator)
	}
	testing.expect_value(t, stat_err, os.Error(os.General_Error.Not_Exist))

	second_err := script_server_stop(&server)
	defer host_error_destroy(&second_err)
	testing.expect_value(t, second_err.kind, Host_Error_Kind.None)
}

@(test)
test_script_server_listener_is_close_on_exec :: proc(t: ^testing.T) {
	directory := tools_test_directory(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	socket_path := tools_test_path(t, directory, "script.sock")
	defer delete(socket_path)

	server := script_test_start(t, socket_path)
	defer script_test_stop(&server)

	// FD_CLOEXEC is what keeps the listener out of a command the script runs.
	flags := posix.fcntl(server.fd, .GETFD)
	testing.expect(t, flags & posix.FD_CLOEXEC != 0)
}

@(test)
test_script_server_rejects_a_path_over_the_kernel_limit :: proc(t: ^testing.T) {
	long_path := strings.repeat("s", len(posix.sockaddr_un{}.sun_path) + 16)
	defer delete(long_path)

	_, start_err := script_server_start(long_path)
	defer host_error_destroy(&start_err)
	testing.expect_value(t, start_err.kind, Host_Error_Kind.Invalid_Argument)
	limit_text := fmt.aprintf("%d", len(posix.sockaddr_un{}.sun_path))
	defer delete(limit_text)
	testing.expect(t, strings.contains(start_err.message, limit_text))
}

// script_test_start opens a server on path, failing the test cleanly.
@(private)
script_test_start :: proc(t: ^testing.T, socket_path: string) -> (server: Script_Server) {
	started, err := script_server_start(socket_path)
	testing.expect_value(t, err.kind, Host_Error_Kind.None)
	host_error_destroy(&err)
	return started
}

@(private)
script_test_stop :: proc(server: ^Script_Server) {
	stop_err := script_server_stop(server)
	host_error_destroy(&stop_err)
}

// script_test_request builds one call line with real JSON encoding. The caller
// owns the returned string.
@(private)
script_test_request :: proc(id, tool: string, args: $T) -> string {
	args_json, marshal_err := json.marshal(args)
	if marshal_err != nil {
		return ""
	}
	defer delete(args_json)
	return strings.concatenate(
		{`{"type":"call","id":"`, id, `","tool":"`, tool, `","args":`, string(args_json), `}`},
		context.allocator,
	)
}

// script_test_serve runs the fake script on its own thread while the caller
// serves one connection, then joins the thread. The caller owns the replies.
@(private)
script_test_serve :: proc(
	t: ^testing.T,
	server: ^Script_Server,
	requests: []string,
) -> (replies: [dynamic]string, served: bool) {
	peer := Script_Test_Peer{
		socket_path = server.path,
		requests    = requests,
		allocator   = context.allocator,
	}
	peer.replies.allocator = context.allocator

	worker := thread.create(script_test_peer_run)
	worker.data = rawptr(&peer)
	thread.start(worker)

	serve_err: Host_Error
	served, serve_err = script_server_serve_one(server, SCRIPT_SERVER_TEST_TIMEOUT_MS)
	testing.expect_value(t, serve_err.kind, Host_Error_Kind.None)
	host_error_destroy(&serve_err)

	thread.destroy(worker)
	testing.expect(t, !peer.failed)
	return peer.replies, served
}

@(private)
script_test_peer_run :: proc(worker: ^thread.Thread) {
	peer := cast(^Script_Test_Peer)worker.data
	context.allocator = peer.allocator

	fd := script_test_peer_connect(peer.socket_path)
	if fd < 0 {
		peer.failed = true
		return
	}
	defer posix.close(fd)

	for request in peer.requests {
		if !script_test_peer_send(fd, request) {
			peer.failed = true
			return
		}
		reply, received := script_test_peer_receive(fd)
		if !received {
			peer.failed = true
			return
		}
		append(&peer.replies, reply)
	}
}

@(private)
script_test_peer_connect :: proc(path: string) -> posix.FD {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return -1
	}
	address := script_server_address(path)
	if posix.connect(fd, (^posix.sockaddr)(&address), script_server_address_len(path)) != .OK {
		posix.close(fd)
		return -1
	}
	return fd
}

@(private)
script_test_peer_send :: proc(fd: posix.FD, line: string) -> bool {
	frame := make([]u8, len(line) + 1)
	defer delete(frame)
	copy(frame, line)
	frame[len(line)] = '\n'
	return script_server_write_all(fd, frame)
}

@(private)
script_test_peer_receive :: proc(fd: posix.FD) -> (line: string, ok: bool) {
	buffer: [dynamic]u8
	buffer.allocator = context.allocator
	defer delete(buffer)
	for {
		value: u8
		count := posix.recv(fd, rawptr(&value), 1, {})
		if count == 1 {
			if value == '\n' {
				return strings.clone(string(buffer[:])), true
			}
			append(&buffer, value)
			continue
		}
		return "", false
	}
}

@(private)
script_test_parse_reply :: proc(t: ^testing.T, line: string) -> Script_Test_Reply {
	wire: Script_Server_Reply
	unmarshal_err := json.unmarshal_string(line, &wire, .JSON)
	testing.expect(t, unmarshal_err == nil)
	if unmarshal_err != nil {
		return {}
	}
	delete(wire.message_type)
	return Script_Test_Reply{
		id        = wire.id,
		ok        = wire.ok,
		output    = wire.output,
		exit_code = wire.exit_code,
	}
}

@(private)
script_test_reply_destroy :: proc(reply: ^Script_Test_Reply) {
	delete(reply.id)
	delete(reply.output)
	reply^ = {}
}

@(private)
script_test_requests_destroy :: proc(requests: []string) {
	for request in requests {
		delete(request)
	}
}

@(private)
script_test_replies_destroy :: proc(replies: ^[dynamic]string) {
	for line in replies {
		delete(line)
	}
	delete(replies^)
}
