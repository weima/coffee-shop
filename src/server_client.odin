package main

import "core:encoding/json"
import "core:log"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

SERVER_ATTEMPTS :: 6
SERVER_RETRY_PAUSE :: 500 * time.Millisecond

// Commands and Workers never change Brew state themselves. In production the
// change goes to the repository's server, which is the only writer. Unit tests
// (ODIN_TEST) apply the same operation in-process instead: that is the fake
// server. The e2e tests run the real binary and the real server.
transition_shot :: proc(directory: string, register: ^Register, shot_id, to_state, detail: string) -> State_Error {
	when ODIN_TEST {
		return apply_transition(directory, register, shot_id, to_state, detail)
	} else {
		return server_mutate(directory, register, Server_Request{op = "transition", shot_id = shot_id, to_state = to_state, detail = detail})
	}
}

request_shot_cancel :: proc(directory: string, register: ^Register, shot_id, detail: string) -> State_Error {
	when ODIN_TEST {
		return apply_request_shot_cancel(directory, register, shot_id, detail)
	} else {
		return server_mutate(directory, register, Server_Request{op = "request_cancel", shot_id = shot_id, detail = detail})
	}
}

server_mutate :: proc(directory: string, register: ^Register, change: Server_Request) -> State_Error {
	// The Brew directory is <state root>/<brew id>, so the state root is a slice of it.
	state_root := directory[:len(directory) - len(register.brew_id) - 1]
	request := change
	request.brew_id = register.brew_id
	request.token = register.brew_token
	response, transport_err := server_request(state_root, register.beans_path, request)
	defer destroy_struct(&response)
	if transport_err != "" {
		write_error(transport_err)
		return State_Error{kind = .Server_Unavailable}
	}
	if !response.ok {
		write_error(response.error)
		return State_Error{kind = .Server_Refused}
	}
	register_sync(register, response.register)
	return State_Error{}
}

// Copies the server's view of each Shot's status into the caller's Register in
// place. The caller may hold pointers into its Shots, so the slice is never replaced.
register_sync :: proc(register: ^Register, fresh: Register) {
	register.event_sequence = fresh.event_sequence
	for &shot, index in register.shots {
		if index >= len(fresh.shots) || fresh.shots[index].id != shot.id {
			continue
		}
		fresh_shot := fresh.shots[index]
		if shot.status != fresh_shot.status {
			delete(shot.status)
			shot.status = strings.clone(fresh_shot.status)
		}
		shot.cancel_requested = fresh_shot.cancel_requested
		delete(shot.detail)
		shot.detail = strings.clone(fresh_shot.detail)
	}
}

// The Register a command shows. Its repository and token come from the Brew's
// register.json, which is read only for those two identity fields.
command_snapshot :: proc(state_root, brew_id: string) -> (register: Register, err: string) {
	brew_dir := state_file_path(state_root, brew_id)
	defer delete(brew_dir)
	when ODIN_TEST {
		state, state_err := read_state(brew_dir)
		if state_err.kind != .None {
			return {}, state_error_message(state_err)
		}
		return state, ""
	} else {
		repository, token, ok := brew_identity(brew_dir)
		defer delete(repository)
		defer delete(token)
		if !ok {
			return {}, "Brew state is unknown: its identity could not be read"
		}
		return server_snapshot(state_root, repository, brew_id, token)
	}
}

// The Register a Worker uses. The token is the one it was launched with, and the
// server refuses the request if it does not match the Brew.
worker_snapshot :: proc(state_root, brew_id, token: string) -> (register: Register, err: string) {
	brew_dir := state_file_path(state_root, brew_id)
	defer delete(brew_dir)
	when ODIN_TEST {
		state, state_err := read_state(brew_dir)
		if state_err.kind != .None {
			return {}, state_error_message(state_err)
		}
		return state, ""
	} else {
		repository, _, ok := brew_identity(brew_dir)
		defer delete(repository)
		if !ok {
			return {}, "Brew state is unknown: its identity could not be read"
		}
		return server_snapshot(state_root, repository, brew_id, token)
	}
}

server_snapshot :: proc(state_root, repository, brew_id, token: string) -> (register: Register, err: string) {
	response, transport_err := server_request(state_root, repository, Server_Request{op = "snapshot", brew_id = brew_id, token = token})
	if transport_err != "" {
		return {}, transport_err
	}
	if !response.ok {
		refusal := fmt.tprintf("%s", response.error)
		destroy_struct(&response)
		return {}, refusal
	}
	register = response.register
	response.register = Register{}
	destroy_struct(&response)
	return register, ""
}

// Reads only the repository path and Brew token from register.json. The file is
// replaced atomically, so the read never sees half a write. Strings are owned.
brew_identity :: proc(brew_dir: string) -> (repository, token: string, ok: bool) {
	path := state_file_path(brew_dir, REGISTER_FILE_NAME)
	defer delete(path)
	data, read_err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	if read_err != nil {
		return {}, {}, false
	}
	register: Register
	if json.unmarshal_string(transmute(string)data, &register, .JSON) != nil {
		destroy_struct(&register)
		return {}, {}, false
	}
	repository = strings.clone(register.beans_path)
	token = strings.clone(register.brew_token)
	destroy_struct(&register)
	return repository, token, true
}

// Sends one request. Each attempt checks the socket, starts the server if none is
// running, and retries after a pause. A transport failure is retried; a refusal
// from the server is returned as is. After SERVER_ATTEMPTS the caller aborts.
server_request :: proc(state_root, repository: string, request: Server_Request) -> (response: Server_Response, transport_err: string) {
	log.debugf("request op=%s brew=%s repository=%s", request.op, request.brew_id, repository)
	cause := ""
	for attempt in 0 ..< SERVER_ATTEMPTS {
		socket, directory, setup_err := server_paths(state_root, repository)
		if setup_err != "" {
			return {}, setup_err
		}
		if server_socket_reachable(socket) {
			reply, call_err := server_api_call(socket, request)
			delete(socket)
			delete(directory)
			log.debugf("request attempt=%d op=%s brew=%s ok=%v refusal=%q", attempt, request.op, request.brew_id, call_err == "" && reply.ok, reply.error)
			if call_err == "" {
				return reply, ""
			}
			cause = call_err
		} else {
			if !server_running(directory) {
				if executable, exe_err := os.get_executable_path(context.allocator); exe_err == nil {
					_ = server_spawn(executable, state_root, repository)
					delete(executable)
				}
			}
			delete(socket)
			delete(directory)
			cause = "the server is not accepting connections yet"
		}
		time.sleep(SERVER_RETRY_PAUSE)
	}
	return {}, fmt.tprintf("the server for %s did not answer after %d attempts: %s", repository, SERVER_ATTEMPTS, cause)
}

// The server's directory and socket path. Both are owned by the caller. A path
// the kernel cannot bind is a configuration error, so it is reported at once.
server_paths :: proc(state_root, repository: string) -> (socket, directory, err: string) {
	id := server_id(repository)
	defer delete(id)
	directory = server_directory(state_root, id)
	socket_path, path_err := strings.concatenate({directory, "/", SERVER_SOCKET_NAME})
	if path_err != nil {
		delete(directory)
		return "", "", "could not build the server socket path"
	}
	if !activity_valid_socket_path(socket_path) {
		length := len(socket_path)
		delete(socket_path)
		delete(directory)
		return "", "", fmt.tprintf("the server socket path is %d bytes, over the Unix limit; use a shorter CS_STATE_DIR", length)
	}
	return socket_path, directory, ""
}

server_spawn :: proc(executable, state_root, repository: string) -> bool {
	log.debugf("spawn server repository=%s", repository)
	// The shell starts the server in the background and exits at once, so waiting
	// on it frees the handle without waiting for the server itself.
	process, spawn_err := os.process_start(os.Process_Desc{
		command = {"/bin/sh", "-c", "\"$0\" __server --state-root \"$1\" --repository \"$2\" </dev/null >/dev/null 2>&1 &", executable, state_root, repository},
	})
	if spawn_err != nil {
		return false
	}
	_, wait_err := os.process_wait(process)
	return wait_err == nil
}

server_socket_reachable :: proc(socket_path: string) -> bool {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return false
	}
	defer posix.close(fd)
	address := activity_socket_address(socket_path)
	return posix.connect(fd, (^posix.sockaddr)(&address), activity_socket_address_len(socket_path)) == .OK
}
