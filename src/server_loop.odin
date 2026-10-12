package main

import "core:c"
import "core:encoding/json"
import "core:strings"
import "core:sys/posix"
import "core:time"

// One accepted connection. A connection carries one request and its response,
// and the loop never blocks on it: reads and writes happen only when the socket
// is ready, so a stalled client holds up nobody but itself.
Server_Client :: struct {
	fd: posix.FD,
	accepted: time.Tick,
	inbox: [dynamic]u8,
	outbox: []u8,
	sent: int,
}

// A Station's own report reaches the Register through the server. It carries the
// report kind and description the activity socket already carries, so no new
// Station protocol is needed. The regular Server_Request cannot carry the kind,
// so a report uses this shape and never reaches server_api_handle.
Station_Report_Request :: struct {
	op:      string,
	brew_id: string,
	token:   string,
	shot_id: string,
	kind:    string,
	detail:  string,
}

// Serves requests until one response has been fully written, or until timeout_ms
// passes with nothing to serve. Clients that are still sending stay registered and
// are served by a later call. Returns true when a response was written.
server_api_serve_one :: proc(api: ^Server_Api, timeout_ms: c.int) -> bool {
	start := time.tick_now()
	timeout := time.Duration(timeout_ms) * time.Millisecond
	handled := false
	for {
		elapsed := time.tick_diff(start, time.tick_now())
		if handled && !server_loop_has_pending_output(api) {
			return true
		}
		if !handled && elapsed >= timeout {
			return false
		}
		if server_loop_step(api, server_loop_wait_ms(timeout - elapsed)) {
			handled = true
		}
	}
}

server_loop_wait_ms :: proc(remaining: time.Duration) -> c.int {
	if remaining <= 0 {
		return 0
	}
	ms := time.duration_milliseconds(remaining)
	return c.int(min(ms, 50))
}

server_loop_has_pending_output :: proc(api: ^Server_Api) -> bool {
	for client in api.clients {
		if client.outbox != nil {
			return true
		}
	}
	return false
}

// One poll over the listener and every client. Returns true if a request was
// answered during this step.
server_loop_step :: proc(api: ^Server_Api, wait_ms: c.int) -> bool {
	fds := make([dynamic]posix.pollfd, 0, len(api.clients) + 1, context.temp_allocator)
	append(&fds, posix.pollfd{fd = api.listener, events = {.IN}})
	for client in api.clients {
		events: posix.Poll_Event = {.IN}
		if client.outbox != nil {
			events = {.OUT}
		}
		append(&fds, posix.pollfd{fd = client.fd, events = events})
	}
	ready := posix.poll(raw_data(fds[:]), posix.nfds_t(len(fds)), wait_ms)

	answered := false
	if ready > 0 {
		// Walk clients from the back, so closing one never shifts a client not yet seen.
		for index := len(api.clients) - 1; index >= 0; index -= 1 {
			if server_loop_serve_client(api, index, fds[index + 1].revents) {
				answered = true
			}
		}
		if .IN in fds[0].revents {
			server_loop_accept(api)
		}
	}
	server_loop_expire(api)
	return answered
}

server_loop_accept :: proc(api: ^Server_Api) {
	for {
		fd := posix.accept(api.listener, nil, nil)
		if fd < 0 {
			return
		}
		server_loop_make_nonblocking(fd)
		append(&api.clients, Server_Client{fd = fd, accepted = time.tick_now()})
	}
}

// Handles one client that the poll reported. Returns true when its response has
// just been fully written.
server_loop_serve_client :: proc(api: ^Server_Api, index: int, revents: posix.Poll_Event) -> bool {
	client := &api.clients[index]
	if revents == {} {
		return false
	}
	if client.outbox != nil {
		if .OUT in revents || .ERR in revents || .HUP in revents {
			if server_loop_flush(client) {
				server_loop_close_client(api, index)
				return true
			}
		}
		return false
	}
	if !server_loop_read(client) {
		server_loop_close_client(api, index)
		return false
	}
	newline := strings.index_byte(string(client.inbox[:]), '\n')
	if newline < 0 {
		if len(client.inbox) > SERVER_LINE_MAX {
			server_loop_close_client(api, index)
		}
		return false
	}
	server_loop_answer(api, client, string(client.inbox[:newline]))
	if server_loop_flush(client) {
		server_loop_close_client(api, index)
		return true
	}
	return false
}

// Reads whatever is available. Returns false when the client has gone or failed.
server_loop_read :: proc(client: ^Server_Client) -> bool {
	buffer: [4096]u8
	for {
		count := posix.recv(client.fd, raw_data(buffer[:]), len(buffer), {})
		if count > 0 {
			append(&client.inbox, ..buffer[:count])
			if len(client.inbox) > SERVER_LINE_MAX + 1 {
				return false
			}
			continue
		}
		if count == 0 {
			return false
		}
		if posix.errno() == .EAGAIN || posix.errno() == .EWOULDBLOCK {
			return true
		}
		return false
	}
}

// Decodes the request in line, runs it, and queues its response line.
server_loop_answer :: proc(api: ^Server_Api, client: ^Server_Client, line: string) {
	response: Server_Response
	report: Station_Report_Request
	request: Server_Request
	if json.unmarshal_string(line, &report, .JSON) == nil && report.op == "report" {
		response = server_loop_report(api^, report)
	} else if json.unmarshal_string(line, &request, .JSON) != nil {
		response.error = strings.clone("request is not valid JSON")
	} else {
		response = server_api_handle(api^, request)
	}
	destroy_struct(&report)
	destroy_struct(&request)
	defer destroy_struct(&response)

	data, marshal_err := json.marshal(response, json.Marshal_Options{spec = .JSON})
	defer delete(data)
	if marshal_err != nil {
		return
	}
	framed := make([]byte, len(data) + 1)
	copy(framed, data)
	framed[len(data)] = '\n'
	client.outbox = framed
	client.sent = 0
}

// Validates a Station report the same way server_api_handle validates a regular
// request, then records it. A report is evidence only: it never changes a status.
server_loop_report :: proc(api: Server_Api, report: Station_Report_Request) -> Server_Response {
	if !valid_shot_id(report.brew_id) {
		return Server_Response{error = strings.clone("Brew ID is invalid")}
	}
	brew_dir := state_file_path(api.state_root, report.brew_id)
	defer delete(brew_dir)
	register, state_err := read_state_recovering(brew_dir)
	if state_err.kind != .None {
		return Server_Response{error = strings.clone(state_error_message(state_err))}
	}
	if register.beans_path != api.repository {
		destroy_struct(&register)
		return Server_Response{error = strings.clone("Brew belongs to another repository")}
	}
	if register.brew_token != report.token {
		destroy_struct(&register)
		return Server_Response{error = strings.clone("token does not match this Brew")}
	}
	err := apply_station_report(brew_dir, &register, report.shot_id, report.kind, report.detail)
	return server_mutation_response(err, register)
}

// Sends one Station report and waits for its response, mirroring server_api_send
// for the report shape.
server_report_send :: proc(socket_path: string, report: Station_Report_Request) -> (conn: posix.FD, err: string) {
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
	data, marshal_err := json.marshal(report, json.Marshal_Options{spec = .JSON})
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

// Writes as much of the queued response as the socket accepts. Returns true when
// all of it has been written.
server_loop_flush :: proc(client: ^Server_Client) -> bool {
	if client.outbox == nil {
		return true
	}
	for client.sent < len(client.outbox) {
		rest := client.outbox[client.sent:]
		count := posix.send(client.fd, raw_data(rest), c.size_t(len(rest)), {.NOSIGNAL})
		if count > 0 {
			client.sent += int(count)
			continue
		}
		if posix.errno() == .EAGAIN || posix.errno() == .EWOULDBLOCK {
			return false
		}
		// The client went away: nothing more can be delivered, so count it as done.
		return true
	}
	return true
}

// Closes clients that have waited too long without a complete request or response.
server_loop_expire :: proc(api: ^Server_Api) {
	timeout := time.Duration(SERVER_IO_TIMEOUT_MS) * time.Millisecond
	for index := len(api.clients) - 1; index >= 0; index -= 1 {
		if time.tick_diff(api.clients[index].accepted, time.tick_now()) >= timeout {
			server_loop_close_client(api, index)
		}
	}
}

server_loop_close_client :: proc(api: ^Server_Api, index: int) {
	client := api.clients[index]
	posix.close(client.fd)
	delete(client.inbox)
	delete(client.outbox)
	ordered_remove(&api.clients, index)
}

// Closes every client connection without touching the listener.
server_loop_close_all :: proc(api: ^Server_Api) {
	for index := len(api.clients) - 1; index >= 0; index -= 1 {
		server_loop_close_client(api, index)
	}
	delete(api.clients)
	api.clients = nil
}

server_loop_make_nonblocking :: proc(fd: posix.FD) {
	_ = posix.fcntl(fd, .SETFL, c.int(posix.O_Flags{.NONBLOCK}))
	_ = posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC))
}
