package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

Request_Probe :: struct {
	dir, line: string,
	result:    Host_Send_Result,
	reason:    string,
}

request_probe_run :: proc(t: ^thread.Thread) {
	probe := (^Request_Probe)(t.data)
	probe.result, probe.reason = host_request_send(probe.dir, probe.line)
}

// Sends `line` from a client thread while this thread serves the socket.
request_through_socket :: proc(listener: ^Activity_Listener, dir, line: string) -> (Host_Send_Result, string) {
	probe := Request_Probe{dir = dir, line = line}
	client := thread.create(request_probe_run)
	client.data = &probe
	thread.start(client)
	for !thread.is_done(client) {
		host_serve_requests(listener)
	}
	thread.join(client)
	thread.destroy(client)
	return probe.result, probe.reason
}

@(test)
test_request_socket_routes_replies_and_rejects_the_rest :: proc(t: ^testing.T) {
	// host_sessions and host_history_root are process-global; the delivered test below
	// changes them, so these two run one at a time.
	host_pool_test_lock()
	defer host_pool_test_unlock()

	root, _ := os.make_directory_temp("", "cs-rq-", context.temp_allocator)
	defer os.remove_all(root)
	dir := fmt.tprintf("%s/host", root)
	_ = os.make_directory_all(dir, os.Permissions{.Read_User, .Write_User, .Execute_User})
	testing.expect(t, host_dir_make_private(dir))
	listener, ok := host_request_listener_open(dir)
	testing.expect(t, ok)
	defer activity_listener_close(&listener)

	info, _ := os.stat(dir, context.temp_allocator)
	testing.expect_value(t, info.mode & os.Permissions{.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}, os.Permissions{})
	testing.expect(t, .Execute_User in info.mode)
	sock_info, _ := os.stat(host_request_socket_path(dir, context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, sock_info.mode & os.Permissions{.Read_Group, .Write_Group, .Read_Other, .Write_Other}, os.Permissions{})

	// A well-formed reply reaches host_reply: only it can say no Station runs for the shot.
	line, _ := reply_request_line("req-1", "shot-a", "hello")
	result, reason := request_through_socket(&listener, dir, line)
	testing.expect_value(t, result, Host_Send_Result.Refused)
	testing.expect_value(t, reason, "no Station is running for that shot")

	rejected := [][2]string{
		{`{"type":"dispatch","request_id":"r","repo":"/tmp","shots":[]}`, "the request socket accepts only reply requests"},
		{`{"type":"shutdown","request_id":"r"}`, "the request socket accepts only reply requests"},
		{`not json`, "invalid json"},
		{`[1]`, "request must be an object"},
		{`{"type":"reply","request_id":"../x","shot_id":"s","message":"hi"}`, "request_id must be a valid shot-style identifier (letters, digits, - or _, up to 64)"},
		{`{"type":"reply","request_id":"r","shot_id":"s","message":"hi","command":"rm -rf /"}`, `unexpected field "command"`},
	}
	for c in rejected {
		got, why := request_through_socket(&listener, dir, c[0])
		testing.expect_value(t, got, Host_Send_Result.Refused)
		testing.expect_value(t, why, c[1])
	}
}

@(test)
test_reply_exit_codes_without_a_deliverable_host :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()

	root, _ := os.make_directory_temp("", "cs-rq-", context.temp_allocator)
	defer os.remove_all(root)
	line, _ := reply_request_line("req-1", "shot-a", "hello")
	// No host at all.
	testing.expect_value(t, reply_deliver(root, line), 1)
	// A host holds the lock but nothing listens on the request socket.
	dir := fmt.tprintf("%s/host", root)
	_ = os.make_directory_all(dir, os.Permissions{.Read_User, .Write_User, .Execute_User})
	lock, locked := host_acquire_lock(dir)
	testing.expect(t, locked)
	defer file_lock_release(lock)
	testing.expect_value(t, reply_deliver(root, line), HOST_REPLY_EXIT_UNREACHABLE)
	// A host that refuses: a socket whose host has no such Station.
	listener, ok := host_request_listener_open(dir)
	testing.expect(t, ok)
	defer activity_listener_close(&listener)
	probe := Request_Probe{dir = dir, line = line}
	client := thread.create(request_probe_run)
	client.data = &probe
	thread.start(client)
	for !thread.is_done(client) {
		host_serve_requests(&listener)
	}
	thread.join(client)
	thread.destroy(client)
	testing.expect_value(t, probe.result, Host_Send_Result.Refused)
}

// A reply sent through the request socket reaches the live headless Station stdin.
@(test)
test_request_socket_delivers_a_reply_to_its_station :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()

	root, _ := os.make_directory_temp("", "cs-rq-", context.temp_allocator)
	defer os.remove_all(root)
	dir := fmt.tprintf("%s/host", root)
	_ = os.make_directory_all(dir, os.Permissions{.Read_User, .Write_User, .Execute_User})
	testing.expect(t, host_dir_make_private(dir))
	listener, ok := host_request_listener_open(dir)
	testing.expect(t, ok)
	defer activity_listener_close(&listener)

	old_state, state_set := os.lookup_env("CS_STATE_DIR", context.allocator)
	_ = os.set_env("CS_STATE_DIR", root)
	old_history := host_history_root
	host_history_root = strings.clone(dir, context.allocator)
	defer {
		if state_set {
			_ = os.set_env("CS_STATE_DIR", old_state)
		} else {
			_ = os.unset_env("CS_STATE_DIR")
		}
		delete(old_state)
		delete(host_history_root)
		host_history_root = old_history
	}

	surface := headless_session_surface(root)
	opened, open_err := surface.ops.tab_create(surface, "req-1", "shot-a", root, context.temp_allocator)
	testing.expect_value(t, open_err, "")
	marker := fmt.tprintf("%s/reply.txt", root)
	quoted_marker := shell_quote(marker)
	command := fmt.aprintf("IFS= read -r line; printf 'got:%%s' \"$line\" > %s", quoted_marker)
	defer delete(quoted_marker)
	defer delete(command)
	testing.expect_value(t, surface.ops.pane_run(surface, opened.pane_id, command), "")
	append(&host_sessions, Host_Session{request_id = strings.clone("req-1"), shot_id = strings.clone("shot-a"), session_id = strings.clone(opened.pane_id)})
	defer {
		_ = headless_close(opened.pane_id)
		for session in host_sessions {
			delete(session.request_id)
			delete(session.shot_id)
			delete(session.session_id)
		}
		delete(host_sessions)
		host_sessions = nil
	}

	line, _ := reply_request_line("req-1", "shot-a", "hello")
	result, reason := request_through_socket(&listener, dir, line)
	testing.expect_value(t, result, Host_Send_Result.Delivered)
	testing.expect_value(t, reason, "")

	reply_data: []byte
	reply_err: os.Error
	for _ in 0..<100 {
		reply_data, reply_err = os.read_entire_file(marker, context.temp_allocator)
		if reply_err == nil {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, reply_err, os.Error(nil))
	testing.expect_value(t, string(reply_data), "got:hello")

	history, history_err := os.read_entire_file(host_history_path("req-1", context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, history_err, os.Error(nil))
	testing.expect(t, host_output_contains(string(history), `{"type":"reply_sent","request_id":"req-1","shot_id":"shot-a"}`), string(history))
}
