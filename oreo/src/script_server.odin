package oreo

// The host side of Oreo's code-mode script API. A generated script runs as its
// own process and calls back to the host over a Unix stream socket whose path
// it reads from OREO_SCRIPT_SOCKET, speaking one JSON object per line. See
// oreo/code-mode.md, "Script API".
//
// Wire protocol, one JSON object per line in both directions:
//
//	script -> host  {"type":"call","id":"<unique>","tool":"read|write|execute","args":{...}}
//	                 read:    path, offset, limit
//	                 write:   path, content
//	                 execute: command, working_directory
//	host -> script  {"type":"result","id":"<the same id>","ok":bool,"output":string,"exit_code":int}
//
// The server dispatches to Oreo's own tool_read, tool_write, and tool_execute;
// it never reimplements them. A malformed line, an unknown tool, or unreadable
// args still gets one result with ok = false, and the connection keeps serving.

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"

// SCRIPT_SERVER_ENV is the environment variable that carries the socket path to
// a running script.
SCRIPT_SERVER_ENV :: "OREO_SCRIPT_SOCKET"

// How often an idle accept or receive rechecks the deadline. Small enough to
// return near the deadline, large enough not to spin a core.
@(private)
SCRIPT_SERVER_POLL_INTERVAL :: 1 * time.Millisecond

// Script_Server owns one listening Unix socket bound at a caller-given path. The
// path is owned by the server and removed by script_server_stop.
Script_Server :: struct {
	fd:   posix.FD,
	path: string,
}

// Every message is one JSON object; `type` is written through a tag because it
// is an Odin keyword.
@(private)
Script_Server_Reply :: struct {
	message_type: string `json:"type"`,
	id:           string,
	ok:           bool,
	output:       string,
	exit_code:    int,
}

// script_server_start binds a listening Unix stream socket at path. A path that
// does not fit the kernel's sockaddr_un limit is rejected by name, never
// truncated.
script_server_start :: proc(path: string) -> (server: Script_Server, err: Host_Error) {
	server.fd = -1
	if len(path) == 0 {
		return server, host_error(.Invalid_Argument, "script socket path must not be empty")
	}
	limit := len(posix.sockaddr_un{}.sun_path)
	if len(path) >= limit {
		message := fmt.aprintf(
			"script socket path is %d bytes; the kernel limit is %d bytes including the NUL terminator",
			len(path),
			limit,
		)
		defer delete(message)
		return server, host_error(.Invalid_Argument, message)
	}

	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return server, host_error(.Internal, "could not create the script socket")
	}
	// O_NONBLOCK lets accept and recv honor the deadline; FD_CLOEXEC keeps the
	// listener out of any command a script runs through execute.
	script_server_make_async(fd)

	address := script_server_address(path)
	if posix.bind(fd, (^posix.sockaddr)(&address), script_server_address_len(path)) != .OK {
		posix.close(fd)
		return server, host_error(.Internal, "could not bind the script socket")
	}
	if posix.listen(fd, 1) != .OK {
		posix.close(fd)
		script_server_unlink(path)
		return server, host_error(.Internal, "could not listen on the script socket")
	}

	owned, clone_err := strings.clone(path)
	if clone_err != nil {
		posix.close(fd)
		script_server_unlink(path)
		return server, host_error(.Out_Of_Memory, "could not own the script socket path")
	}
	server.fd = fd
	server.path = owned
	return server, Host_Error{}
}

// script_server_serve_one accepts one connection and answers that script's
// calls until the connection closes or the deadline passes. served reports
// whether a connection was accepted. timeout_ms is measured from entry, so an
// unconnected listener returns without hanging.
script_server_serve_one :: proc(server: ^Script_Server, timeout_ms: int) -> (served: bool, err: Host_Error) {
	if server == nil || server.fd < 0 || server.path == "" {
		return false, host_error(.Invalid_Argument, "script server is not started")
	}
	timeout := time.Duration(max(timeout_ms, 0)) * time.Millisecond
	deadline := time.tick_now()

	client := posix.FD(-1)
	for client < 0 {
		accepted := posix.accept(server.fd, nil, nil)
		if accepted >= 0 {
			client = accepted
			break
		}
		accept_err := posix.get_errno()
		if accept_err != .EAGAIN && accept_err != .EWOULDBLOCK {
			return false, host_error(.Internal, "could not accept a script connection")
		}
		if time.tick_since(deadline) >= timeout {
			return false, Host_Error{}
		}
		time.sleep(SCRIPT_SERVER_POLL_INTERVAL)
	}
	defer posix.close(client)
	script_server_make_async(client)

	line: [dynamic]u8
	line.allocator = context.allocator
	defer delete(line)
	// shortcut: request lines are buffered without a cap; add one if scripts ever
	// stop being model-authored.

	for {
		value: u8
		count := posix.recv(client, rawptr(&value), 1, {})
		if count == 1 {
			if value == '\n' {
				script_server_handle_line(client, string(line[:]))
				clear(&line)
				if time.tick_since(deadline) >= timeout {
					return true, Host_Error{}
				}
				continue
			}
			append(&line, value)
			continue
		}
		if count == 0 {
			// The peer closed. A trailing partial line is still a received call.
			if len(line) > 0 {
				script_server_handle_line(client, string(line[:]))
				clear(&line)
			}
			return true, Host_Error{}
		}
		recv_err := posix.get_errno()
		if recv_err == .EAGAIN || recv_err == .EWOULDBLOCK {
			if time.tick_since(deadline) >= timeout {
				return true, Host_Error{}
			}
			time.sleep(SCRIPT_SERVER_POLL_INTERVAL)
			continue
		}
		return true, Host_Error{}
	}
}

// script_server_stop closes the listener and removes the socket file. It is safe
// to call twice, and on a zero value.
script_server_stop :: proc(server: ^Script_Server) -> Host_Error {
	if server == nil {
		return Host_Error{}
	}
	if server.fd >= 0 && server.path != "" {
		posix.close(server.fd)
	}
	if server.path != "" {
		script_server_unlink(server.path)
		delete(server.path)
	}
	server^ = Script_Server{fd = -1}
	return Host_Error{}
}

// script_server_handle_line answers one received line with exactly one result.
@(private)
script_server_handle_line :: proc(fd: posix.FD, line: string) {
	parsed: json.Value
	if json.unmarshal_string(line, &parsed, .JSON) != nil {
		script_server_reply(fd, "", false, "malformed JSON line", 0)
		return
	}
	defer json.destroy_value(parsed)

	object, is_object := parsed.(json.Object)
	if !is_object {
		script_server_reply(fd, "", false, "expected a JSON object", 0)
		return
	}

	id, _ := script_json_string(object, "id")
	message_type, has_type := script_json_string(object, "type")
	if !has_type || message_type != "call" {
		script_server_reply(fd, id, false, "expected a call message", 0)
		return
	}
	tool, has_tool := script_json_string(object, "tool")
	if !has_tool {
		script_server_reply(fd, id, false, "call is missing a tool", 0)
		return
	}
	args_value, has_args := object["args"]
	args, args_is_object := args_value.(json.Object)
	if !has_args || !args_is_object {
		script_server_reply(fd, id, false, "call is missing args", 0)
		return
	}

	switch tool {
	case "read":
		path, has_path := script_json_string(args, "path")
		if !has_path {
			script_server_reply(fd, id, false, "read requires a path", 0)
			return
		}
		offset, _ := script_json_int(args, "offset")
		limit, _ := script_json_int(args, "limit")
		content, tool_err := tool_read(path, offset, limit)
		defer delete(content)
		defer tool_error_destroy(&tool_err)
		if tool_err.kind != .None {
			script_server_reply(fd, id, false, tool_err.message, 0)
			return
		}
		script_server_reply(fd, id, true, content, 0)
	case "write":
		path, has_path := script_json_string(args, "path")
		content, has_content := script_json_string(args, "content")
		if !has_path || !has_content {
			script_server_reply(fd, id, false, "write requires a path and content", 0)
			return
		}
		tool_err := tool_write(path, content)
		defer tool_error_destroy(&tool_err)
		if tool_err.kind != .None {
			script_server_reply(fd, id, false, tool_err.message, 0)
			return
		}
		script_server_reply(fd, id, true, "", 0)
	case "execute":
		command, has_command := script_json_string(args, "command")
		working_directory, has_directory := script_json_string(args, "working_directory")
		if !has_command || !has_directory {
			script_server_reply(fd, id, false, "execute requires a command and working_directory", 0)
			return
		}
		output, exit_code, tool_err := tool_execute(command, working_directory)
		defer delete(output)
		defer tool_error_destroy(&tool_err)
		if tool_err.kind != .None {
			script_server_reply(fd, id, false, tool_err.message, exit_code)
			return
		}
		// A non-zero exit is a normal result: ok stays true and the code is
		// reported for the script to inspect.
		script_server_reply(fd, id, true, output, exit_code)
	case:
		message := fmt.aprintf("unknown tool: %s", tool)
		defer delete(message)
		script_server_reply(fd, id, false, message, 0)
	}
}

// script_server_reply encodes one result and writes it as a whole line.
@(private)
script_server_reply :: proc(fd: posix.FD, id: string, ok: bool, output: string, exit_code: int) {
	encoded, marshal_err := json.marshal(Script_Server_Reply{
		message_type = "result",
		id           = id,
		ok           = ok,
		output       = output,
		exit_code    = exit_code,
	})
	if marshal_err != nil {
		return
	}
	defer delete(encoded)
	line := make([]u8, len(encoded) + 1)
	defer delete(line)
	copy(line, encoded)
	line[len(encoded)] = '\n'
	script_server_write_all(fd, line)
}

// script_server_write_all writes every byte, retrying while the peer's buffer is
// full. It reports whether the whole line was handed to the kernel.
@(private)
script_server_write_all :: proc(fd: posix.FD, data: []u8) -> bool {
	written := 0
	for written < len(data) {
		remaining := len(data) - written
		sent := posix.send(fd, raw_data(data[written:]), c.size_t(remaining), {.NOSIGNAL})
		if sent > 0 {
			written += int(sent)
			continue
		}
		if sent == 0 {
			return false
		}
		send_err := posix.get_errno()
		if send_err == .EAGAIN || send_err == .EWOULDBLOCK {
			time.sleep(SCRIPT_SERVER_POLL_INTERVAL)
			continue
		}
		if send_err == .EINTR {
			continue
		}
		return false
	}
	return true
}

@(private)
script_json_string :: proc(object: json.Object, key: string) -> (string, bool) {
	value, has_value := object[key]
	if !has_value {
		return "", false
	}
	text, is_string := value.(json.String)
	if !is_string {
		return "", false
	}
	return string(text), true
}

@(private)
script_json_int :: proc(object: json.Object, key: string) -> (int, bool) {
	value, has_value := object[key]
	if !has_value {
		return 0, false
	}
	if number, is_integer := value.(json.Integer); is_integer {
		return int(number), true
	}
	if number, is_float := value.(json.Float); is_float {
		return int(number), true
	}
	return 0, false
}

// script_server_make_async makes a socket nonblocking for deadline polling and
// close-on-exec so the listener and its clients never leak into a child.
@(private)
script_server_make_async :: proc(fd: posix.FD) {
	_ = posix.fcntl(fd, .SETFL, c.int(posix.O_Flags{.NONBLOCK}))
	_ = posix.fcntl(fd, .SETFD, c.int(posix.FD_CLOEXEC))
}

@(private)
script_server_address :: proc(path: string) -> posix.sockaddr_un {
	address: posix.sockaddr_un
	address.sun_family = .UNIX
	when ODIN_OS == .Darwin {
		address.sun_len = c.uchar(script_server_address_len(path))
	}
	copy(address.sun_path[:], path)
	return address
}

@(private)
script_server_address_len :: proc(path: string) -> posix.socklen_t {
	when ODIN_OS == .Darwin {
		return posix.socklen_t(
			size_of(posix.sockaddr_un{}.sun_len) +
				size_of(posix.sockaddr_un{}.sun_family) + len(path) + 1,
		)
	} else {
		return posix.socklen_t(size_of(posix.sockaddr_un{}.sun_family) + len(path) + 1)
	}
}

@(private)
script_server_unlink :: proc(path: string) {
	path_bytes := make([]u8, len(path) + 1)
	defer delete(path_bytes)
	copy(path_bytes, path)
	posix.unlink(cstring(raw_data(path_bytes)))
}
