package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// A Station-reported process identity takes precedence over the session child.
// `sleep 3` exits 0 by itself, so a missing signal differs from SIGTERM (15).
@(test)
test_cancel_signals_pid_the_station_reported :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	station, start_err := os.process_start(os.Process_Desc{command = []string{"sleep", "3"}})
	testing.expect(t, start_err == nil, "sleep must start")
	start_time, _ := process_start_time(station.pid)
	append(&host_sessions, Host_Session{request_id = strings.clone("req-1"), shot_id = strings.clone("shot-a")})
	defer {
		for s in host_sessions {
			delete(s.request_id)
			delete(s.shot_id)
		}
		delete(host_sessions)
		host_sessions = nil
	}
	host_relay_message(Activity_Message{
		brew_id = "req-1", shot_id = "shot-a", kind = "station_pid", timestamp_ns = 1,
		description = fmt.tprintf("station=%d start=%d agent=0", station.pid, start_time),
	})
	host_cancel_session("req-1", host_sessions[0])
	state, _ := process_reap(station)
	testing.expect_value(t, state.exit_code, 15)
}

// Without a Station report, cancellation identifies and signals the headless child.
@(test)
test_cancel_without_reported_pid_signals_headless_session :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	root, make_err := os.make_directory_temp(HOST_TEST_TEMP_DIR, "coffee-shop-cancel-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	old_state, state_set := os.lookup_env("CS_STATE_DIR", context.allocator)
	_ = os.set_env("CS_STATE_DIR", root)
	defer {
		if state_set {
			_ = os.set_env("CS_STATE_DIR", old_state)
		} else {
			_ = os.unset_env("CS_STATE_DIR")
		}
		delete(old_state)
	}

	surface := headless_session_surface(root)
	opened, open_err := surface.ops.tab_create(surface, "req-1", "shot-a", root, context.temp_allocator)
	testing.expect_value(t, open_err, "")
	testing.expect_value(t, surface.ops.pane_run(surface, opened.pane_id, "exec sleep 30"), "")
	identity := surface.ops.pane_process_info(surface, opened.pane_id)
	testing.expect(t, identity.pid > 0, "headless child has a process identity")
	session := Host_Session{request_id = "req-1", shot_id = "shot-a", session_id = opened.pane_id}
	testing.expect_value(t, session_station_pid(session), 0)
	host_cancel_session("cancel-1", session)

	for _ in 0..<100 {
		if identity_liveness(identity) == .Gone {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, identity_liveness(identity), Liveness.Gone)
	_ = headless_close(opened.pane_id)
}

@(test)
test_station_pid_description_roundtrip :: proc(t: ^testing.T) {
	identity, agent, ok := parse_station_pid(station_pid_description(Process_Identity{pid = 12, start_time = 34}, 56))
	testing.expect(t, ok)
	testing.expect_value(t, identity, Process_Identity{pid = 12, start_time = 34})
	testing.expect_value(t, agent, 56)
	_, _, bad := parse_station_pid("station=0 start=1 agent=2")
	testing.expect(t, !bad, "a non-positive pid is refused")
}
