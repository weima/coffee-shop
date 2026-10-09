package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:sys/posix"
import "core:testing"

// A Brew on disk, and a server socket for its repository.
api_fixture :: proc(t: ^testing.T) -> (root: string, register: Register, api: Server_Api, ok: bool) {
	root = make_test_state_directory(t)
	register = make_test_register(t)
	if create_state(fmt.tprintf("%s/%s", root, register.brew_id), &register).kind != .None {
		return
	}
	api, ok = server_api_open(root, register.beans_path, fmt.tprintf("%s/server", root))
	return
}

@(test)
test_server_api_snapshot_returns_the_brew :: proc(t: ^testing.T) {
	root, register, api, ok := api_fixture(t)
	defer remove_test_state_directory(root)
	defer destroy_struct(&register)
	testing.expect(t, ok, "the server socket must open")
	defer server_api_close(&api)

	conn, send_err := server_api_send(api.socket_path, Server_Request{op = "snapshot", brew_id = register.brew_id, token = register.brew_token})
	defer posix.close(conn)
	testing.expect_value(t, send_err, "")
	testing.expect(t, server_api_serve_one(&api, 2000), "the waiting request must be served")

	response, recv_err := server_api_receive(conn)
	defer destroy_struct(&response)
	testing.expect_value(t, recv_err, "")
	testing.expect_value(t, response.register.brew_id, register.brew_id)
}

@(test)
test_server_api_transition_writes_through_the_server :: proc(t: ^testing.T) {
	root, register, api, ok := api_fixture(t)
	defer remove_test_state_directory(root)
	defer destroy_struct(&register)
	testing.expect(t, ok, "the server socket must open")
	defer server_api_close(&api)

	conn, send_err := server_api_send(api.socket_path, Server_Request{op = "transition", brew_id = register.brew_id, token = register.brew_token, shot_id = register.shots[0].id, to_state = SHOT_RUNNING, detail = "Worker started"})
	defer posix.close(conn)
	testing.expect_value(t, send_err, "")
	testing.expect(t, server_api_serve_one(&api, 2000), "the waiting request must be served")

	response, recv_err := server_api_receive(conn)
	defer destroy_struct(&response)
	testing.expect_value(t, recv_err, "")

	stored, stored_err := read_state(fmt.tprintf("%s/%s", root, register.brew_id))
	defer destroy_struct(&stored)
	testing.expect_value(t, stored_err.kind, State_Error_Kind.None)
	testing.expect_value(t, stored.shots[0].status, SHOT_RUNNING)
}

@(test)
test_server_api_refuses_a_wrong_token :: proc(t: ^testing.T) {
	root, register, api, ok := api_fixture(t)
	defer remove_test_state_directory(root)
	defer destroy_struct(&register)
	testing.expect(t, ok, "the server socket must open")
	defer server_api_close(&api)

	conn, _ := server_api_send(api.socket_path, Server_Request{op = "snapshot", brew_id = register.brew_id, token = "not-the-token"})
	defer posix.close(conn)
	testing.expect(t, server_api_serve_one(&api, 2000), "the waiting request must be served")

	response, _ := server_api_receive(conn)
	defer destroy_struct(&response)
	testing.expect(t, !response.ok, "a wrong token must be refused")
	testing.expect(t, strings.contains(response.error, "token"), response.error)
}

@(test)
test_server_api_refuses_a_brew_from_another_repository :: proc(t: ^testing.T) {
	root, register, api, ok := api_fixture(t)
	defer remove_test_state_directory(root)
	defer destroy_struct(&register)
	testing.expect(t, ok, "the server socket must open")
	defer server_api_close(&api)

	other, other_ok := server_api_open(root, "/elsewhere/repo", fmt.tprintf("%s/other", root))
	testing.expect(t, other_ok, "the second socket must open")
	defer server_api_close(&other)

	conn, _ := server_api_send(other.socket_path, Server_Request{op = "snapshot", brew_id = register.brew_id, token = register.brew_token})
	defer posix.close(conn)
	testing.expect(t, server_api_serve_one(&other, 2000), "the waiting request must be served")

	response, _ := server_api_receive(conn)
	defer destroy_struct(&response)
	testing.expect(t, !response.ok, "another repository's Brew must be refused")
	testing.expect(t, strings.contains(response.error, "another repository"), response.error)
}

@(test)
test_server_api_refuses_a_socket_path_that_is_too_long :: proc(t: ^testing.T) {
	root := make_test_state_directory(t)
	defer remove_test_state_directory(root)

	long := strings.repeat("d", 120, context.temp_allocator)
	_, ok := server_api_open(root, "/work/gac", fmt.tprintf("%s/%s", root, long))
	testing.expect(t, !ok, "a socket path beyond the Unix limit must be refused")
}

// A client that sends half a request and stops must not hold up another client.
// The first request the server finishes should be the healthy one, promptly.
@(test)
test_a_stalled_client_does_not_hold_up_another_client :: proc(t: ^testing.T) {
	root, register, api, ok := api_fixture(t)
	defer remove_test_state_directory(root)
	defer destroy_struct(&register)
	testing.expect(t, ok, "the server socket must open")
	defer server_api_close(&api)

	// The stalled client connects first, so the server sees it first.
	stalled := posix.socket(.UNIX, .STREAM)
	defer posix.close(stalled)
	stalled_address := activity_socket_address(api.socket_path)
	testing.expect(t, posix.connect(stalled, (^posix.sockaddr)(&stalled_address), activity_socket_address_len(api.socket_path)) == .OK, "the stalled client must connect")
	half := transmute([]byte)string(`{"op":"snapshot"`)
	_ = posix.send(stalled, raw_data(half), c.size_t(len(half)), {.NOSIGNAL})

	conn, send_err := server_api_send(api.socket_path, Server_Request{op = "snapshot", brew_id = register.brew_id, token = register.brew_token})
	defer posix.close(conn)
	testing.expect_value(t, send_err, "")

	start := time.tick_now()
	served_first := server_api_serve_one(&api, 20000)
	first_elapsed := time.tick_diff(start, time.tick_now())
	testing.expect(t, served_first, "a request must be served")
	testing.expect(t, first_elapsed < 500 * time.Millisecond, fmt.tprintf("the healthy client waited %v behind a stalled client", first_elapsed))

	// If the server spent its first turn on the stalled client, serve the healthy one now.
	if first_elapsed >= 500 * time.Millisecond {
		_ = server_api_serve_one(&api, 20000)
	}
	response, recv_err := server_api_receive(conn)
	defer destroy_struct(&response)
	testing.expect_value(t, recv_err, "")
	testing.expect(t, response.ok, response.error)
}

// Several stalled clients, ahead of a healthy one, must still leave the healthy one served first.
@(test)
test_several_stalled_clients_do_not_hold_up_a_healthy_client :: proc(t: ^testing.T) {
	root, register, api, ok := api_fixture(t)
	defer remove_test_state_directory(root)
	defer destroy_struct(&register)
	testing.expect(t, ok, "the server socket must open")
	defer server_api_close(&api)

	stalled: [2]posix.FD
	for i in 0..<len(stalled) {
		stalled[i] = posix.socket(.UNIX, .STREAM)
		address := activity_socket_address(api.socket_path)
		testing.expect(t, posix.connect(stalled[i], (^posix.sockaddr)(&address), activity_socket_address_len(api.socket_path)) == .OK, "a stalled client must connect")
		half := transmute([]byte)string(`{"op":"snap`)
		_ = posix.send(stalled[i], raw_data(half), c.size_t(len(half)), {.NOSIGNAL})
	}
	defer for fd in stalled { posix.close(fd) }

	conn, send_err := server_api_send(api.socket_path, Server_Request{op = "snapshot", brew_id = register.brew_id, token = register.brew_token})
	defer posix.close(conn)
	testing.expect_value(t, send_err, "")

	start := time.tick_now()
	served_first := server_api_serve_one(&api, 20000)
	first_elapsed := time.tick_diff(start, time.tick_now())
	testing.expect(t, served_first, "a request must be served")
	testing.expect(t, first_elapsed < 500 * time.Millisecond, fmt.tprintf("the healthy client waited %v behind stalled clients", first_elapsed))

	response, recv_err := server_api_receive(conn)
	defer destroy_struct(&response)
	testing.expect_value(t, recv_err, "")
	testing.expect(t, response.ok, response.error)
}
