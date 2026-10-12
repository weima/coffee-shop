package script

// Oreo code mode, script-side half of the tool API. A generated script imports
// this package; every tool call goes to the host as one JSON object per line
// over the Unix stream socket named by OREO_SCRIPT_SOCKET, and the host answers
// with one JSON object per line. See oreo/code-mode.md, "Script API".
//
// The connection is opened on the first tool call and reused for the rest of
// the script: the host sees one client, and the script pays one connect.
//
// The socket is built with core:sys/posix rather than core:net. In this Odin
// release core:net models IP4/IP6 only (net.Address_Family has no UNIX member),
// so it cannot create the AF_UNIX stream socket this transport needs. The
// command line allowlist constrains the generated script's imports, not this
// package's, and core:sys/posix is not offered to the script.

import "base:runtime"
import "core:bytes"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"

/*
	Error carries one message owned by the caller. Pass it to error_destroy when
	it is no longer needed, including a zero value.
*/
Error :: struct {
	message: string,
}

/*
	execute runs command in working_directory and returns its merged output and
	exit code. A non-zero exit code is a normal result, not an error: it is
	returned in exit_code and err only reports whether the host's reply was ok.
	The caller owns output.
*/
execute :: proc(command: string, working_directory := "", allocator := context.allocator) -> (output: string, exit_code: int, err: Error) {
	reply, call_err := script_call("execute", Execute_Args{
		command = command,
		working_directory = working_directory,
	}, allocator)
	if call_err.message != "" {
		return "", 0, call_err
	}
	if !reply.ok {
		err = script_reply_error(reply.output, "execute failed", allocator)
	}
	return reply.output, reply.exit_code, err
}

/*
	read returns the requested line window of path. offset is a 0-based line
	index and limit <= 0 means every remaining line. The caller owns content.
*/
read :: proc(path: string, offset := 0, limit := 0, allocator := context.allocator) -> (content: string, err: Error) {
	reply, call_err := script_call("read", Read_Args{
		path = path,
		offset = offset,
		limit = limit,
	}, allocator)
	if call_err.message != "" {
		return "", call_err
	}
	if !reply.ok {
		err = script_reply_error(reply.output, "read failed", allocator)
	}
	return reply.output, err
}

/*
	write overwrites path with content, creating missing parent directories.
*/
write :: proc(path, content: string) -> Error {
	reply, call_err := script_call("write", Write_Args{path = path, content = content}, context.allocator)
	if call_err.message != "" {
		return call_err
	}
	defer delete(reply.output, context.allocator)
	if !reply.ok {
		return script_reply_error(reply.output, "write failed", context.allocator)
	}
	return Error{}
}

/*
	text adds one model-visible output item by writing it to stdout, followed by
	a newline. Strings are written verbatim; any other value is encoded as JSON.
	The runner already bounds the script's stdout, so no protocol is needed and
	the socket is never touched.
*/
text :: proc(value: any) {
	switch v in value {
	case string:
		fmt.print(v)
	case:
		data, marshal_err := json.marshal(value)
		if marshal_err != nil {
			// Keep stdout line-clean; the diagnostic goes to stderr.
			fmt.eprintfln("script.text: could not encode the value as JSON")
			return
		}
		defer delete(data)
		fmt.print(string(data))
	}
	fmt.println()
}

/*
	error_destroy releases the message owned by err. Safe on a zero value. The
	message was allocated with the allocator passed to the call that produced the
	Error, so pass the same one here.
*/
error_destroy :: proc(err: ^Error, allocator := context.allocator) {
	delete(err.message, allocator)
	err^ = Error{}
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

@(private)
SCRIPT_SOCKET_ENV :: "OREO_SCRIPT_SOCKET"

// A reply is one line. A larger one is a broken peer, not a payload.
@(private)
SCRIPT_MAX_REPLY_BYTES :: 8 * 1024 * 1024

@(private)
SCRIPT_RECV_CHUNK :: 4096

// The request line, exactly as it goes on the wire:
//   {"type":"call","id":"<id>","tool":"<tool>","args":{...}}
//
// It is polymorphic in the args type: this Odin release's json.marshal rejects a
// struct field of type `any`, which is exactly what a non-polymorphic
// Call_Request would need.
@(private)
Call_Request :: struct($Args_Type: typeid) {
	type: string    `json:"type"`,
	id:   string    `json:"id"`,
	tool: string    `json:"tool"`,
	args: Args_Type `json:"args"`,
}

@(private)
Execute_Args :: struct {
	command:           string `json:"command"`,
	working_directory: string `json:"working_directory"`,
}

@(private)
Read_Args :: struct {
	path:   string `json:"path"`,
	offset: int    `json:"offset"`,
	limit:  int    `json:"limit"`,
}

@(private)
Write_Args :: struct {
	path:    string `json:"path"`,
	content: string `json:"content"`,
}

// The reply line: {"type":"result","id":"<the same id>","ok":true,"output":"...","exit_code":0}
@(private)
Result_Reply :: struct {
	type:      string `json:"type"`,
	id:        string `json:"id"`,
	ok:        bool   `json:"ok"`,
	output:    string `json:"output"`,
	exit_code: int    `json:"exit_code"`,
}

// The one connection every call reuses. connected guards fd; counter hands out
// unique request ids for the life of the script.
@(private)
Client :: struct {
	mutex:     sync.Mutex,
	fd:        posix.FD,
	connected: bool,
	counter:   u64,
}

@(private)
client: Client = {fd = posix.FD(-1)}

// An ok reply narrowed to what the public procedures return. output is owned by
// the allocator passed to the call.
@(private)
Reply :: struct {
	ok:        bool,
	output:    string,
	exit_code: int,
}

// script_call sends one request line and returns the reply that carries the
// same id, cloning its output into allocator. The whole exchange holds the
// client mutex, so two threads cannot interleave lines on the one connection.
@(private)
script_call :: proc(tool: string, args: $Args_Type, allocator: runtime.Allocator) -> (reply: Reply, err: Error) {
	sync.mutex_lock(&client.mutex)
	defer sync.mutex_unlock(&client.mutex)

	fd, connect_err := script_client_fd(allocator)
	if connect_err.message != "" {
		return {}, connect_err
	}

	client.counter += 1
	id_buffer: [32]u8
	id := fmt.bprintf(id_buffer[:], "%d", client.counter)

	request, marshal_err := json.marshal(
		Call_Request(Args_Type){type = "call", id = id, tool = tool, args = args},
		allocator = context.allocator,
	)
	if marshal_err != nil {
		return {}, script_error("could not encode the tool call", allocator)
	}
	defer delete(request, context.allocator)

	line := make([]u8, len(request) + 1, context.allocator)
	defer delete(line, context.allocator)
	copy(line, request)
	line[len(request)] = '\n'

	if send_err := script_send_all(fd, line, allocator); send_err.message != "" {
		return {}, send_err
	}

	reply_line, recv_err := script_recv_line(fd, allocator)
	if recv_err.message != "" {
		return {}, recv_err
	}
	defer delete(reply_line, allocator)

	parsed: Result_Reply
	if unmarshal_err := json.unmarshal_string(reply_line, &parsed, .JSON, context.allocator); unmarshal_err != nil {
		script_result_reply_destroy(&parsed)
		return {}, script_error("the host sent a malformed reply", allocator)
	}
	defer script_result_reply_destroy(&parsed)

	if parsed.id != id {
		return {}, script_error("the host reply did not match the request id", allocator)
	}

	return Reply{
		ok = parsed.ok,
		output = strings.clone(parsed.output, allocator),
		exit_code = parsed.exit_code,
	}, Error{}
}

// script_client_fd returns the live connection, opening it on first use. A
// failure leaves the client disconnected, so the next call tries again instead
// of reporting a dead socket as a live one.
@(private)
script_client_fd :: proc(allocator: runtime.Allocator) -> (fd: posix.FD, err: Error) {
	if client.connected {
		return client.fd, Error{}
	}
	path := os.get_env_alloc(SCRIPT_SOCKET_ENV, allocator)
	defer delete(path, allocator)
	if path == "" {
		return posix.FD(-1), script_error("OREO_SCRIPT_SOCKET is not set", allocator)
	}
	if !script_valid_socket_path(path) {
		return posix.FD(-1), script_error("OREO_SCRIPT_SOCKET is not a usable socket path", allocator)
	}

	fd = posix.socket(.UNIX, .STREAM)
	if fd == posix.FD(-1) {
		return posix.FD(-1), script_error("could not create the socket", allocator)
	}
	address := script_socket_address(path)
	if posix.connect(fd, (^posix.sockaddr)(&address), script_socket_address_len(path)) != .OK {
		posix.close(fd)
		return posix.FD(-1), script_error("could not connect to OREO_SCRIPT_SOCKET", allocator)
	}
	client.fd = fd
	client.connected = true
	return fd, Error{}
}

// script_send_all writes every byte or reports an error; send rarely writes a
// whole line at once. NOSIGNAL keeps a host that has gone away from killing the
// script with SIGPIPE.
@(private)
script_send_all :: proc(fd: posix.FD, data: []u8, allocator: runtime.Allocator) -> Error {
	sent := 0
	for sent < len(data) {
		remaining := len(data) - sent
		n := posix.send(fd, rawptr(&data[sent]), c.size_t(remaining), {.NOSIGNAL})
		if n <= 0 {
			return script_error("could not send the tool call to the host", allocator)
		}
		sent += int(n)
	}
	return Error{}
}

// script_recv_line reads one newline-terminated reply line. A closed connection
// or an oversized line is an error, never a panic.
@(private)
script_recv_line :: proc(fd: posix.FD, allocator: runtime.Allocator) -> (line: string, err: Error) {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	buffer: [SCRIPT_RECV_CHUNK]u8
	for {
		n := posix.recv(fd, rawptr(&buffer[0]), c.size_t(len(buffer)), {})
		if n < 0 {
			strings.builder_destroy(&builder)
			return "", script_error("could not read the host reply", allocator)
		}
		if n == 0 {
			strings.builder_destroy(&builder)
			return "", script_error("the host closed the connection before replying", allocator)
		}
		chunk := buffer[:int(n)]
		if newline := bytes.index_byte(chunk, '\n'); newline >= 0 {
			strings.write_bytes(&builder, chunk[:newline])
			return strings.to_string(builder), Error{}
		}
		strings.write_bytes(&builder, chunk)
		if strings.builder_len(builder) > SCRIPT_MAX_REPLY_BYTES {
			strings.builder_destroy(&builder)
			return "", script_error("the host reply is larger than the script allows", allocator)
		}
	}
}

@(private)
script_result_reply_destroy :: proc(reply: ^Result_Reply) {
	delete(reply.type)
	delete(reply.id)
	delete(reply.output)
	reply^ = {}
}

// script_valid_socket_path rejects a path sun_path cannot hold, which is
// truncated silently otherwise.
@(private)
script_valid_socket_path :: proc(path: string) -> bool {
	return len(path) > 0 && len(path) < len(posix.sockaddr_un{}.sun_path)
}

@(private)
script_socket_address :: proc(path: string) -> posix.sockaddr_un {
	address: posix.sockaddr_un
	address.sun_family = .UNIX
	when ODIN_OS == .Darwin {
		address.sun_len = c.uchar(script_socket_address_len(path))
	}
	copy(address.sun_path[:], path)
	return address
}

@(private)
script_socket_address_len :: proc(path: string) -> posix.socklen_t {
	when ODIN_OS == .Darwin {
		return posix.socklen_t(
			size_of(posix.sockaddr_un{}.sun_len) +
				size_of(posix.sockaddr_un{}.sun_family) + len(path) + 1,
		)
	} else {
		return posix.socklen_t(size_of(posix.sockaddr_un{}.sun_family) + len(path) + 1)
	}
}

// script_client_reset drops the cached connection. A script opens one
// connection per process on purpose; the tests call this between cases so each
// case starts from a clean client.
@(private)
script_client_reset :: proc() {
	if client.connected {
		posix.close(client.fd)
	}
	client.fd = posix.FD(-1)
	client.connected = false
	client.counter = 0
}

// script_reply_error turns a failed reply into a caller-owned Error. The host's
// output doubles as the message when it sent one.
@(private)
script_reply_error :: proc(output, fallback: string, allocator: runtime.Allocator) -> Error {
	message := output
	if strings.trim_space(message) == "" {
		message = fallback
	}
	return script_error(message, allocator)
}

@(private)
script_error :: proc(message: string, allocator: runtime.Allocator) -> Error {
	owned, _ := strings.clone(message, allocator)
	return Error{message = owned}
}
