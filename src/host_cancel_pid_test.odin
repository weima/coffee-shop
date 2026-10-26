package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A Station that reported its own pid is cancelled by that pid; the session's pane
// ("" here, and no herdr exists) is never consulted. `sleep 3` exits 0 by itself, so
// an unsent signal shows as exit code 0 instead of SIGTERM (15) rather than a hang.
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

// A Station that never reported keeps the Herdr fallback: with no pid recorded the
// cancel signals nothing and says why.
@(test)
test_cancel_without_reported_pid_signals_nothing :: proc(t: ^testing.T) {
	session := Host_Session{request_id = "req-1", shot_id = "shot-a"}
	testing.expect_value(t, session_station_pid(session), 0)
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
