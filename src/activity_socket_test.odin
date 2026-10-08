package main

import "core:c"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(test)
test_activity_socket_round_trips_multiple_worker_streams :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "coffee-shop-activity-*", context.allocator)
	testing.expect_value(t, err, os.Error(nil))
	defer os.remove_all(directory)
	defer delete(directory)
	path, _ := filepath.join({directory, "events.sock"})
	defer delete(path)

	listener, listener_ok := activity_listener_open(path)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)
	first_sender, first_sender_ok := activity_sender_open(path)
	testing.expect(t, first_sender_ok)
	defer activity_sender_close(&first_sender)
	second_sender, second_sender_ok := activity_sender_open(path)
	testing.expect(t, second_sender_ok)
	defer activity_sender_close(&second_sender)

	first := Activity_Message{
		brew_id = "brew-1", shot_id = "shot-a", kind = "tool-start",
		description = "Reading files", timestamp_ns = 100,
	}
	second := Activity_Message{
		brew_id = "brew-1", shot_id = "shot-b", kind = "message",
		description = "Found the cause", timestamp_ns = 200,
	}
	testing.expect(t, activity_sender_send(&first_sender, first))
	testing.expect(t, activity_sender_send(&second_sender, second))

	got_first := activity_listener_receive(&listener)
	defer destroy_struct(&got_first.message)
	testing.expect_value(t, got_first.kind, Activity_Receive_Kind.Message)
	testing.expect_value(t, got_first.message, first)
	got_second := activity_listener_receive(&listener)
	defer destroy_struct(&got_second.message)
	testing.expect_value(t, got_second.kind, Activity_Receive_Kind.Message)
	testing.expect_value(t, got_second.message, second)
	no_message := activity_listener_receive(&listener)
	testing.expect_value(t, no_message.kind, Activity_Receive_Kind.Unavailable)
}

@(test)
test_activity_socket_rejects_invalid_and_oversize_messages :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "coffee-shop-activity-*", context.allocator)
	testing.expect_value(t, err, os.Error(nil))
	defer os.remove_all(directory)
	defer delete(directory)
	path, _ := filepath.join({directory, "events.sock"})
	defer delete(path)
	listener, listener_ok := activity_listener_open(path)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)
	sender, sender_ok := activity_sender_open(path)
	testing.expect(t, sender_ok)
	defer activity_sender_close(&sender)

	empty_brew := Activity_Message{
		brew_id = "", shot_id = "shot", kind = "kind", description = "description", timestamp_ns = 1,
	}
	testing.expect(t, !activity_sender_send(&sender, empty_brew))
	empty_kind := Activity_Message{
		brew_id = "brew", shot_id = "shot", kind = "", description = "description", timestamp_ns = 1,
	}
	testing.expect(t, !activity_sender_send(&sender, empty_kind))
	no_timestamp := Activity_Message{
		brew_id = "brew", shot_id = "shot", kind = "kind", description = "description",
	}
	testing.expect(t, !activity_sender_send(&sender, no_timestamp))
	oversize_text, _ := strings.repeat("x", 3000)
	defer delete(oversize_text)
	testing.expect(t, !activity_sender_send(&sender, Activity_Message{
		brew_id = "brew", shot_id = "shot", kind = "kind", description = oversize_text, timestamp_ns = 1,
	}))

	activity_sender_close(&sender)
	_ = activity_listener_receive(&listener)
	raw_fd := activity_test_connect_raw(t, path)
	defer posix.close(raw_fd)
	activity_test_send_raw(t, raw_fd, "")
	empty := activity_listener_receive(&listener)
	testing.expect_value(t, empty.kind, Activity_Receive_Kind.Malformed)
	activity_test_send_raw(t, raw_fd, "{not json}")
	malformed := activity_listener_receive(&listener)
	testing.expect_value(t, malformed.kind, Activity_Receive_Kind.Malformed)
	oversize_payload, _ := strings.repeat("x", ACTIVITY_MAX_PAYLOAD+1)
	defer delete(oversize_payload)
	activity_test_send_raw(t, raw_fd, oversize_payload)
	oversize := activity_listener_receive(&listener)
	testing.expect_value(t, oversize.kind, Activity_Receive_Kind.Malformed)
}

@(test)
test_activity_socket_failed_open_returns_safe_closed_handles :: proc(t: ^testing.T) {
	listener, listener_ok := activity_listener_open("")
	testing.expect(t, !listener_ok)
	testing.expect_value(t, listener.fd, posix.FD(-1))
	activity_listener_close(&listener)

	sender, sender_ok := activity_sender_open("")
	testing.expect(t, !sender_ok)
	testing.expect_value(t, sender.fd, posix.FD(-1))
	activity_sender_close(&sender)
}

@(test)
test_activity_socket_absent_receiver_and_client_disconnect :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "coffee-shop-activity-*", context.allocator)
	testing.expect_value(t, err, os.Error(nil))
	defer os.remove_all(directory)
	defer delete(directory)
	path, _ := filepath.join({directory, "events.sock"})
	defer delete(path)
	sender, sender_ok := activity_sender_open(path)
	testing.expect(t, !sender_ok)
	testing.expect_value(t, sender.fd, posix.FD(-1))
	activity_sender_close(&sender)

	listener, listener_ok := activity_listener_open(path)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)
	sender, sender_ok = activity_sender_open(path)
	testing.expect(t, sender_ok)
	activity_sender_close(&sender)
	closed := activity_listener_receive(&listener)
	testing.expect_value(t, closed.kind, Activity_Receive_Kind.Unavailable)

	raw_fd := activity_test_connect_raw(t, path)
	activity_test_send_fragment(t, raw_fd, `{"brew_id":"brew","shot_id":"shot"`)
	partial := activity_listener_receive(&listener)
	testing.expect_value(t, partial.kind, Activity_Receive_Kind.Unavailable)
	posix.close(raw_fd)
	disconnected := activity_listener_receive(&listener)
	testing.expect_value(t, disconnected.kind, Activity_Receive_Kind.Unavailable)
	activity_listener_close(&listener)
	testing.expect(t, !os.exists(path))
}

activity_test_connect_raw :: proc(t: ^testing.T, path: string) -> posix.FD {
	fd := posix.socket(.UNIX, .STREAM)
	testing.expect(t, fd >= 0)
	address: posix.sockaddr_un
	address.sun_family = .UNIX
	copy(address.sun_path[:], path)
	address_len := posix.socklen_t(size_of(address.sun_family) + len(path) + 1)
	testing.expect(t, posix.connect(fd, (^posix.sockaddr)(&address), address_len) == .OK)
	return fd
}

activity_test_send_fragment :: proc(t: ^testing.T, fd: posix.FD, payload: string) {
	sent := posix.send(fd, raw_data(payload), c.size_t(len(payload)), {.NOSIGNAL})
	testing.expect_value(t, sent, c.ssize_t(len(payload)))
}

activity_test_send_raw :: proc(t: ^testing.T, fd: posix.FD, payload: string) {
	frame := make([]u8, len(payload)+1)
	defer delete(frame)
	copy(frame, payload)
	frame[len(payload)] = '\n'
	sent := posix.send(fd, raw_data(frame), c.size_t(len(frame)), {.NOSIGNAL})
	testing.expect_value(t, sent, c.ssize_t(len(frame)))
}
