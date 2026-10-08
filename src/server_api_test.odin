package main

import "core:fmt"
import "core:strings"
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
	defer destroy_register(&register)
	testing.expect(t, ok, "the server socket must open")
	defer server_api_close(&api)

	conn, send_err := server_api_send(api.socket_path, Server_Request{op = "snapshot", brew_id = register.brew_id, token = register.brew_token})
	defer posix.close(conn)
	testing.expect_value(t, send_err, "")
	testing.expect(t, server_api_serve_one(api, 2000), "the waiting request must be served")

	response, recv_err := server_api_receive(conn)
	defer server_response_destroy(&response)
	testing.expect_value(t, recv_err, "")
	testing.expect_value(t, response.register.brew_id, register.brew_id)
}

@(test)
test_server_api_transition_writes_through_the_server :: proc(t: ^testing.T) {
	root, register, api, ok := api_fixture(t)
	defer remove_test_state_directory(root)
	defer destroy_register(&register)
	testing.expect(t, ok, "the server socket must open")
	defer server_api_close(&api)

	conn, send_err := server_api_send(api.socket_path, Server_Request{op = "transition", brew_id = register.brew_id, token = register.brew_token, shot_id = register.shots[0].id, to_state = SHOT_RUNNING, detail = "Worker started"})
	defer posix.close(conn)
	testing.expect_value(t, send_err, "")
	testing.expect(t, server_api_serve_one(api, 2000), "the waiting request must be served")

	response, recv_err := server_api_receive(conn)
	defer server_response_destroy(&response)
	testing.expect_value(t, recv_err, "")

	stored, stored_err := read_state(fmt.tprintf("%s/%s", root, register.brew_id))
	defer destroy_register(&stored)
	testing.expect_value(t, stored_err.kind, State_Error_Kind.None)
	testing.expect_value(t, stored.shots[0].status, SHOT_RUNNING)
}

@(test)
test_server_api_refuses_a_wrong_token :: proc(t: ^testing.T) {
	root, register, api, ok := api_fixture(t)
	defer remove_test_state_directory(root)
	defer destroy_register(&register)
	testing.expect(t, ok, "the server socket must open")
	defer server_api_close(&api)

	conn, _ := server_api_send(api.socket_path, Server_Request{op = "snapshot", brew_id = register.brew_id, token = "not-the-token"})
	defer posix.close(conn)
	testing.expect(t, server_api_serve_one(api, 2000), "the waiting request must be served")

	response, _ := server_api_receive(conn)
	defer server_response_destroy(&response)
	testing.expect(t, !response.ok, "a wrong token must be refused")
	testing.expect(t, strings.contains(response.error, "token"), response.error)
}

@(test)
test_server_api_refuses_a_brew_from_another_repository :: proc(t: ^testing.T) {
	root, register, api, ok := api_fixture(t)
	defer remove_test_state_directory(root)
	defer destroy_register(&register)
	testing.expect(t, ok, "the server socket must open")
	defer server_api_close(&api)

	other, other_ok := server_api_open(root, "/elsewhere/repo", fmt.tprintf("%s/other", root))
	testing.expect(t, other_ok, "the second socket must open")
	defer server_api_close(&other)

	conn, _ := server_api_send(other.socket_path, Server_Request{op = "snapshot", brew_id = register.brew_id, token = register.brew_token})
	defer posix.close(conn)
	testing.expect(t, server_api_serve_one(other, 2000), "the waiting request must be served")

	response, _ := server_api_receive(conn)
	defer server_response_destroy(&response)
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
