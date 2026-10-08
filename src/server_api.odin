package main

import "core:c"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sys/posix"

SERVER_SOCKET_NAME :: "server.sock"
SERVER_LINE_MAX :: 64 * 1024
SERVER_IO_TIMEOUT_MS :: 2000

// One request and one response per connection, each a single JSON line. Stage 3
// supports two operations: "snapshot" and "transition".
Server_Request :: struct {
	op: string,
	brew_id: string,
	token: string,
	shot_id: string,
	to_state: string,
	detail: string,
}

Server_Response :: struct {
	ok: bool,
	error: string,
	register: Register,
}

Server_Api :: struct {
	listener: posix.FD,
	state_root: string,
	repository: string,
	socket_path: string,
}

// Opens the server's socket. The caller must hold the server's election lock,
// so a socket file left by a dead server is stale and may be replaced.
server_api_open :: proc(state_root, repository, directory: string) -> (api: Server_Api, ok: bool) {
	if !os.exists(directory) && os.make_directory_all(directory, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return
	}
	socket_path, path_err := strings.concatenate({directory, "/", SERVER_SOCKET_NAME})
	if path_err != nil {
		return
	}
	if !activity_valid_socket_path(socket_path) {
		delete(socket_path)
		return
	}
	activity_unlink(socket_path)
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		delete(socket_path)
		return
	}
	if posix.fcntl(fd, .SETFL, c.int(posix.O_Flags{.NONBLOCK})) != 0 {
		posix.close(fd)
		delete(socket_path)
		return
	}
	address := activity_socket_address(socket_path)
	if posix.bind(fd, (^posix.sockaddr)(&address), activity_socket_address_len(socket_path)) != .OK {
		posix.close(fd)
		delete(socket_path)
		return
	}
	if posix.listen(fd, SCALE) != .OK {
		posix.close(fd)
		activity_unlink(socket_path)
		delete(socket_path)
		return
	}
	api = Server_Api{listener = fd, state_root = state_root, repository = repository, socket_path = socket_path}
	return api, true
}

server_api_close :: proc(api: ^Server_Api) {
	posix.close(api.listener)
	activity_unlink(api.socket_path)
	delete(api.socket_path)
	api^ = Server_Api{listener = -1}
}

// Serves at most one waiting request. Returns false when none arrived in time.
server_api_serve_one :: proc(api: Server_Api, timeout_ms: c.int) -> bool {
	pending := posix.pollfd{fd = api.listener, events = {.IN}}
	if posix.poll(&pending, 1, timeout_ms) <= 0 {
		return false
	}
	conn := posix.accept(api.listener, nil, nil)
	if conn < 0 {
		return false
	}
	defer posix.close(conn)

	response: Server_Response
	defer destroy_struct(&response)
	line, read_ok := server_read_line(conn)
	defer delete(line)
	if !read_ok {
		response.error = strings.clone("request could not be read")
	} else {
		request: Server_Request
		defer destroy_struct(&request)
		if json.unmarshal_string(line, &request, .JSON) != nil {
			response.error = strings.clone("request is not valid JSON")
		} else {
			response = server_api_handle(api, request)
		}
	}
	server_write_response(conn, response)
	return true
}

server_api_handle :: proc(api: Server_Api, request: Server_Request) -> Server_Response {
	if !valid_shot_id(request.brew_id) {
		return Server_Response{error = strings.clone("Brew ID is invalid")}
	}
	brew_dir := state_file_path(api.state_root, request.brew_id)
	defer delete(brew_dir)
	register, state_err := read_state(brew_dir)
	if state_err.kind != .None {
		return Server_Response{error = strings.clone(state_error_message(state_err))}
	}
	if register.beans_path != api.repository {
		destroy_struct(&register)
		return Server_Response{error = strings.clone("Brew belongs to another repository")}
	}
	if register.brew_token != request.token {
		destroy_struct(&register)
		return Server_Response{error = strings.clone("token does not match this Brew")}
	}

	switch request.op {
	case "snapshot":
		return Server_Response{ok = true, register = register}
	case "transition":
		err := apply_transition(brew_dir, &register, request.shot_id, request.to_state, request.detail)
		return server_mutation_response(err, register)
	case "request_cancel":
		err := apply_request_shot_cancel(brew_dir, &register, request.shot_id, request.detail)
		return server_mutation_response(err, register)
	}
	destroy_struct(&register)
	return Server_Response{error = strings.clone("unknown operation")}
}

// A change returns the Register, so the caller can refresh its view in one round trip.
server_mutation_response :: proc(err: State_Error, register: Register) -> Server_Response {
	if err.kind != .None {
		failed := register
		destroy_struct(&failed)
		return Server_Response{error = strings.clone(state_error_message(err))}
	}
	return Server_Response{ok = true, register = register}
}

// Sends one request and waits for its response. A transport error means the
// server could not be reached or did not answer; a refusal comes back in response.
server_api_call :: proc(socket_path: string, request: Server_Request) -> (response: Server_Response, transport_err: string) {
	conn, send_err := server_api_send(socket_path, request)
	if send_err != "" {
		return {}, send_err
	}
	defer posix.close(conn)
	line, ok := server_read_line(conn)
	defer delete(line)
	if !ok {
		return {}, "server did not respond"
	}
	if json.unmarshal_string(line, &response, .JSON) != nil {
		destroy_struct(&response)
		return {}, "server response is not valid JSON"
	}
	return response, ""
}

// Connects and sends a request without waiting. Pair with server_api_receive.
server_api_send :: proc(socket_path: string, request: Server_Request) -> (conn: posix.FD, err: string) {
	if !activity_valid_socket_path(socket_path) {
		return -1, "server socket path is invalid"
	}
	conn = posix.socket(.UNIX, .STREAM)
	if conn < 0 {
		return -1, "could not create a socket"
	}
	address := activity_socket_address(socket_path)
	if posix.connect(conn, (^posix.sockaddr)(&address), activity_socket_address_len(socket_path)) != .OK {
		posix.close(conn)
		return -1, "no server is listening"
	}
	data, marshal_err := json.marshal(request, json.Marshal_Options{spec = .JSON})
	defer delete(data)
	if marshal_err != nil {
		posix.close(conn)
		return -1, "request could not be encoded"
	}
	framed := make([]byte, len(data) + 1)
	defer delete(framed)
	copy(framed, data)
	framed[len(data)] = '\n'
	if !server_write_all(conn, framed) {
		posix.close(conn)
		return -1, "request could not be sent"
	}
	return conn, ""
}

server_api_receive :: proc(conn: posix.FD) -> (response: Server_Response, err: string) {
	line, ok := server_read_line(conn)
	defer delete(line)
	if !ok {
		return {}, "server did not respond"
	}
	if json.unmarshal_string(line, &response, .JSON) != nil {
		destroy_struct(&response)
		return {}, "server response is not valid JSON"
	}
	if !response.ok {
		return response, response.error
	}
	return response, ""
}

// Reads up to the next newline, within a bounded size and a time limit.
server_read_line :: proc(conn: posix.FD) -> (line: string, ok: bool) {
	buffer: [dynamic]u8
	defer delete(buffer)
	byte_slot: [1]u8
	for len(buffer) < SERVER_LINE_MAX {
		pending := posix.pollfd{fd = conn, events = {.IN}}
		if posix.poll(&pending, 1, SERVER_IO_TIMEOUT_MS) <= 0 {
			return {}, false
		}
		if posix.read(conn, raw_data(byte_slot[:]), 1) != 1 {
			return {}, false
		}
		if byte_slot[0] == '\n' {
			return strings.clone(string(buffer[:])), true
		}
		append(&buffer, byte_slot[0])
	}
	return {}, false
}

server_write_response :: proc(conn: posix.FD, response: Server_Response) {
	data, marshal_err := json.marshal(response, json.Marshal_Options{spec = .JSON})
	defer delete(data)
	if marshal_err != nil {
		return
	}
	framed := make([]byte, len(data) + 1)
	defer delete(framed)
	copy(framed, data)
	framed[len(data)] = '\n'
	_ = server_write_all(conn, framed)
}

server_write_all :: proc(conn: posix.FD, data: []byte) -> bool {
	sent := uint(0)
	for sent < uint(len(data)) {
		n := posix.send(conn, raw_data(data[sent:]), c.size_t(uint(len(data)) - sent), {.NOSIGNAL})
		if n <= 0 {
			return false
		}
		sent += uint(n)
	}
	return true
}
