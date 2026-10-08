package main

import "core:c"
import "core:encoding/json"
import "core:strings"
import "core:sys/posix"

ACTIVITY_MAX_PAYLOAD :: 2048
ACTIVITY_MAX_ID :: 64
ACTIVITY_MAX_KIND :: 64
ACTIVITY_MAX_DESCRIPTION :: 1024

Activity_Message :: struct {
	brew_id: string,
	shot_id: string,
	kind: string,
	description: string,
	timestamp_ns: i64,
}

Activity_Client :: struct {
	fd: posix.FD,
	line: [ACTIVITY_MAX_PAYLOAD]u8,
	line_len: int,
	discarding: bool,
}

Activity_Listener :: struct {
	fd: posix.FD,
	path: string,
	clients: [SCALE]Activity_Client,
	next_client: int,
}

Activity_Sender :: struct {
	fd: posix.FD,
}

Activity_Receive_Kind :: enum {
	Unavailable,
	Message,
	Malformed,
	Failed,
}

Activity_Receive_Result :: struct {
	kind: Activity_Receive_Kind,
	message: Activity_Message,
}

activity_listener_open :: proc(path: string) -> (listener: Activity_Listener, ok: bool) {
	listener.fd = -1
	for &client in listener.clients {
		client.fd = -1
	}
	if !activity_valid_socket_path(path) {
		return
	}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return
	}
	if posix.fcntl(fd, .SETFL, c.int(posix.O_Flags{.NONBLOCK})) != 0 {
		posix.close(fd)
		return
	}
	address := activity_socket_address(path)
	if posix.bind(fd, (^posix.sockaddr)(&address), activity_socket_address_len(path)) != .OK {
		posix.close(fd)
		return
	}
	if posix.listen(fd, SCALE) != .OK {
		posix.close(fd)
		activity_unlink(path)
		return
	}
	owned_path, err := strings.clone(path)
	if err != nil {
		posix.close(fd)
		activity_unlink(path)
		return
	}
	listener.fd = fd
	listener.path = owned_path
	return listener, true
}

activity_listener_receive :: proc(
	listener: ^Activity_Listener,
	allocator := context.allocator,
) -> Activity_Receive_Result {
	if listener.fd < 0 {
		return Activity_Receive_Result{kind = .Failed}
	}
	activity_accept_pending(listener)
	for offset in 0 ..< SCALE {
		index := (listener.next_client + offset) % SCALE
		client := &listener.clients[index]
		if client.fd < 0 {
			continue
		}
		result := activity_client_receive(client, allocator)
		if result.kind != .Unavailable {
			listener.next_client = (index + 1) % SCALE
			return result
		}
	}
	return Activity_Receive_Result{kind = .Unavailable}
}

activity_listener_close :: proc(listener: ^Activity_Listener) {
	for index in 0 ..< SCALE {
		activity_client_close(&listener.clients[index])
	}
	if listener.fd >= 0 {
		posix.close(listener.fd)
		activity_unlink(listener.path)
		delete(listener.path)
	}
	listener^ = Activity_Listener{fd = -1}
	for index in 0 ..< SCALE {
		listener.clients[index].fd = -1
	}
}

activity_sender_open :: proc(path: string) -> (sender: Activity_Sender, ok: bool) {
	sender.fd = -1
	if !activity_valid_socket_path(path) {
		return
	}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return
	}
	if posix.fcntl(fd, .SETFL, c.int(posix.O_Flags{.NONBLOCK})) != 0 {
		posix.close(fd)
		return
	}
	address := activity_socket_address(path)
	if posix.connect(fd, (^posix.sockaddr)(&address), activity_socket_address_len(path)) != .OK {
		posix.close(fd)
		return
	}
	sender.fd = fd
	return sender, true
}

activity_sender_send :: proc(sender: ^Activity_Sender, message: Activity_Message) -> bool {
	if sender.fd < 0 || !activity_valid_message(message) {
		return false
	}
	data, err := json.marshal(message)
	if err != nil {
		return false
	}
	defer delete(data)
	if len(data) == 0 || len(data) > ACTIVITY_MAX_PAYLOAD {
		return false
	}
	frame := make([]u8, len(data)+1)
	defer delete(frame)
	copy(frame, data)
	frame[len(data)] = '\n'
	sent := posix.send(sender.fd, raw_data(frame), c.size_t(len(frame)), {.NOSIGNAL})
	if sent == c.ssize_t(len(frame)) {
		return true
	}
	if sent > 0 || (sent < 0 && posix.get_errno() != .EAGAIN && posix.get_errno() != .EWOULDBLOCK) {
		posix.close(sender.fd)
		sender.fd = -1
	}
	return false
}

activity_sender_close :: proc(sender: ^Activity_Sender) {
	if sender.fd >= 0 {
		posix.close(sender.fd)
	}
	sender^ = Activity_Sender{fd = -1}
}

activity_accept_pending :: proc(listener: ^Activity_Listener) {
	for {
		fd := posix.accept(listener.fd, nil, nil)
		if fd < 0 {
			err := posix.get_errno()
			if err == .EAGAIN || err == .EWOULDBLOCK {
				return
			}
			return
		}
		if posix.fcntl(fd, .SETFL, c.int(posix.O_Flags{.NONBLOCK})) != 0 {
			posix.close(fd)
			continue
		}
		free_index := -1
		for index in 0 ..< SCALE {
			if listener.clients[index].fd < 0 {
				free_index = index
				break
			}
		}
		if free_index < 0 {
			posix.close(fd)
			continue
		}
		listener.clients[free_index] = Activity_Client{fd = fd}
	}
}

activity_client_receive :: proc(
	client: ^Activity_Client,
	allocator := context.allocator,
) -> Activity_Receive_Result {
	for {
		value: u8
		count := posix.recv(client.fd, rawptr(&value), 1, {})
		if count == 1 {
			if value == '\n' {
				if client.discarding {
					client.discarding = false
					client.line_len = 0
					return Activity_Receive_Result{kind = .Malformed}
				}
				message: Activity_Message
				if client.line_len == 0 || json.unmarshal_string(
					string(client.line[:client.line_len]), &message, .JSON, allocator,
				) != nil || !activity_valid_message(message) {
					destroy_struct(&message, allocator)
					client.line_len = 0
					return Activity_Receive_Result{kind = .Malformed}
				}
				client.line_len = 0
				return Activity_Receive_Result{kind = .Message, message = message}
			}
			if !client.discarding {
				if client.line_len == ACTIVITY_MAX_PAYLOAD {
					client.line_len = 0
					client.discarding = true
				} else {
					client.line[client.line_len] = value
					client.line_len += 1
				}
			}
			continue
		}
		if count == 0 {
			activity_client_close(client)
			return Activity_Receive_Result{kind = .Unavailable}
		}
		err := posix.get_errno()
		if err == .EAGAIN || err == .EWOULDBLOCK {
			return Activity_Receive_Result{kind = .Unavailable}
		}
		activity_client_close(client)
		return Activity_Receive_Result{kind = .Failed}
	}
}

activity_client_close :: proc(client: ^Activity_Client) {
	if client.fd >= 0 {
		posix.close(client.fd)
	}
	client^ = Activity_Client{fd = -1}
}

activity_valid_message :: proc(message: Activity_Message) -> bool {
	return valid_shot_id(message.brew_id) && valid_shot_id(message.shot_id) &&
		len(message.kind) > 0 && len(message.kind) <= ACTIVITY_MAX_KIND &&
		len(message.description) > 0 && len(message.description) <= ACTIVITY_MAX_DESCRIPTION &&
		message.timestamp_ns > 0
}

activity_valid_socket_path :: proc(path: string) -> bool {
	return len(path) > 0 && len(path) < len(posix.sockaddr_un{}.sun_path)
}

activity_socket_address :: proc(path: string) -> posix.sockaddr_un {
	address: posix.sockaddr_un
	address.sun_family = .UNIX
	copy(address.sun_path[:], path)
	return address
}

activity_unlink :: proc(path: string) {
	path_bytes := make([]u8, len(path)+1)
	defer delete(path_bytes)
	copy(path_bytes, path)
	posix.unlink(cstring(raw_data(path_bytes)))
}

activity_socket_address_len :: proc(path: string) -> posix.socklen_t {
	return posix.socklen_t(size_of(posix.sockaddr_un{}.sun_family) + len(path) + 1)
}
