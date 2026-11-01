package main

FAKE_HERDR :: `#!/bin/sh
d="$FAKE_HERDR_DIR"
if [ -n "$FAKE_HERDR_DOWN" ]; then
  echo '{"id":"x","error":{"code":"server_not_running","message":"no herdr server is running"}}' >&2
  exit 1
fi
case "$1 $2" in
"workspace create")
  echo '{"id":"x","result":{"type":"workspace_created","workspace":{"workspace_id":"w1"},"tab":{"tab_id":"t0"},"root_pane":{"pane_id":"p0"}}}' ;;
"tab create")
  n=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 )); echo $n > "$d/n"
  echo "{\"id\":\"x\",\"result\":{\"type\":\"tab_created\",\"tab\":{\"tab_id\":\"t$n\"},\"root_pane\":{\"pane_id\":\"p$n\"}}}" ;;
"pane run")
  # Like a real pane: a session of its own, so closing the tab can end the Worker
  # and everything it started.
  pane="$3"; shift 3
  set -m
  sh -c "exec $*" >"$d/worker-$pane.log" 2>&1 &
  echo $! > "$d/pid-$pane"
  echo '{}' ;;
"tab close")
  pid=$(cat "$d/pid-p${3#t}" 2>/dev/null)
  if [ -n "$pid" ] && [ -n "$FAKE_HERDR_CLOSE_DELAY" ]; then
    # The tab closes at once, but its Worker exits only after the delay.
    (sleep "$FAKE_HERDR_CLOSE_DELAY"; kill -s TERM -- "-$pid" 2>/dev/null) >/dev/null 2>&1 &
  elif [ -n "$pid" ]; then
    kill -s TERM -- "-$pid" 2>/dev/null
  fi
  echo '{}' ;;
*) echo '{}' ;;
esac
`


import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

host_pool_test_mutex: sync.Mutex

host_pool_test_lock :: proc() {
	sync.mutex_lock(&host_pool_test_mutex)
}

host_pool_test_unlock :: proc() {
	sync.mutex_unlock(&host_pool_test_mutex)
}

// Starts the pool on a private machine-limit root so another process's slots under the
// real state root can never refuse a test's acquire. Returns the root; pass it to
// host_pool_test_end after the cleanup. The limit itself is covered by machine_limit_test.odin.
host_pool_test_init :: proc(workspace_id: string) -> string {
	root, err := os.make_directory_temp(HOST_TEST_TEMP_DIR, "coffee-shop-pool-*", context.allocator)
	assert(err == nil, "cannot create the test state root")
	host_dispatch_init_at(workspace_id, root)
	return root
}

host_pool_test_end :: proc(root: string) {
	os.remove_all(root)
	delete(root)
}

// Regression tests for pool integration into host.odin.
// These test the real wired seams: dispatch queue, pane reclamation, terminal reports.

@(test)
test_host_dispatch_acquire_queues_at_capacity :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()

	// Test that dispatch queue works with real pool.
	pool_root := host_pool_test_init("ws-host-test")
	defer host_pool_test_end(pool_root)
	defer host_dispatch_cleanup("herdr")

	// Acquire up to capacity (default 5).
	for i in 0..<6 {
		id := fmt.aprintf("shot-%d", i)
		pane, _, ok := host_dispatch_acquire("req-1", id)
		testing.expect(t, ok, "acquire should succeed")
		if pane != "" {
			delete(pane)
		}
		delete(id)
	}

	// At least one should be queued (capacity = 5).
	queued_count, _ := host_dispatch_queue_status()
	testing.expect(t, queued_count >= 1, "should have queued at least one")
}

@(test)
test_host_pane_terminal_reclaims :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()

	// Test that terminal reports trigger pane reclaim.
	pool_root := host_pool_test_init("ws-host-test-2")
	defer host_pool_test_end(pool_root)
	defer host_dispatch_cleanup("herdr")

	// Acquire a pane.
	pane, _, ok := host_dispatch_acquire("req-1", "shot-a")
	testing.expect(t, ok, "acquire should succeed")

	// Mark terminal and reclaim (simulating host_relay_message handling).
	host_pane_mark_terminal(pane)
	reclaim_ok := host_pane_reclaim(pane)
	testing.expect(t, reclaim_ok, "reclaim should succeed")

	delete(pane)
}

@(test)
test_host_pane_pin_unpin_for_input :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()

	// Test that needs_input pins pane until reply/cancel.
	pool_root := host_pool_test_init("ws-host-test-3")
	defer host_pool_test_end(pool_root)
	defer host_dispatch_cleanup("herdr")

	// Acquire a pane.
	pane, _, ok := host_dispatch_acquire("req-1", "shot-a")
	testing.expect(t, ok, "acquire should succeed")

	// Pin (needs_input).
	host_pane_pin(pane)

	// Unpin (reply received).
	host_pane_unpin(pane)

	// Reclaim.
	host_pane_mark_terminal(pane)
	reclaim_ok := host_pane_reclaim(pane)
	testing.expect(t, reclaim_ok, "reclaim should succeed")

	delete(pane)
}

@(test)
test_host_dispatch_cleanup_releases_owned_state :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()

	pool_root := host_pool_test_init("ws-host-cleanup-test")
	defer host_pool_test_end(pool_root)
	for i in 0..<5 {
		shot_id := fmt.aprintf("shot-%d", i)
		pane, _, _ := host_dispatch_acquire("req-1", shot_id)
		delete(pane)
		delete(shot_id)
	}
	_, queued, _ := host_dispatch_acquire("req-1", "shot-queued")
	if queued {
		host_dispatch_queue_store_metadata("req-1", "shot-b", "/repo", "prompt", "model", "provider", "thinking", "execute", "pi", "taste", "message", "/station")
	}

	_ = host_dispatch_cleanup("herdr")

	testing.expect_value(t, len(host_pane_pool.panes), 0)
	testing.expect_value(t, len(host_pane_pool.host_owned_pane_ids), 0)
	testing.expect_value(t, len(host_dispatch_queue), 0)
}

@(test)
test_is_terminal_report_kinds :: proc(t: ^testing.T) {
	// Test terminal report detection.
	testing.expect(t, is_terminal_report("pulled"), "pulled should be terminal")
	testing.expect(t, is_terminal_report("taste_failed"), "taste_failed should be terminal")
	testing.expect(t, is_terminal_report("incomplete"), "incomplete should be terminal")
	testing.expect(t, is_terminal_report("session_failed"), "session_failed should be terminal")
	testing.expect(t, !is_terminal_report("needs_input"), "needs_input should not be terminal")
	testing.expect(t, !is_terminal_report("progress"), "progress should not be terminal")
}

// One-turn Station fixture: capacity 1, shot-a running (session recorded), shot-b queued,
// a fake herdr that logs the command it is asked to run, and a private state root.
Reap_Fixture :: struct {
	root:      string,
	fake_dir:  string,
	old_state: string,
}

reap_fixture_begin :: proc(t: ^testing.T) -> Reap_Fixture {
	fx: Reap_Fixture
	fx.root = host_pool_test_init("ws-reap")
	fx.fake_dir = fmt.aprintf("%s/fake-herdr", fx.root)
	_ = os.make_directory_all(fx.fake_dir)
	herdr := fmt.aprintf("%s/herdr", fx.root)
	_ = os.write_entire_file(herdr, FAKE_HERDR, os.Permissions{.Read_User, .Write_User, .Execute_User})
	_ = os.set_env("FAKE_HERDR_DIR", fx.fake_dir)
	fx.old_state = os.get_env("CS_STATE_DIR", context.allocator)
	_ = os.set_env("CS_STATE_DIR", fx.root)
	host_herdr_exe = herdr
	host_history_root = fmt.aprintf("%s/host", fx.root)
	_ = os.make_directory_all(host_history_root)
	host_station_executable = "coffee-shop"
	host_pane_pool.capacity = 1

	pane, _, ok := host_dispatch_acquire("req-1", "shot-a")
	testing.expect(t, ok, "shot-a takes the only pane")
	append(&host_sessions, Host_Session{request_id = strings.clone("req-1"), shot_id = strings.clone("shot-a"), pane_id = pane})
	_, queued, _ := host_dispatch_acquire("req-1", "shot-b")
	testing.expect(t, queued, "shot-b queues behind the full pool")
	host_dispatch_queue_store_metadata("req-1", "shot-b", fx.root, "prompt", "", "", "", "research", "pi", "", "", fx.root)
	return fx
}

reap_fixture_end :: proc(fx: Reap_Fixture) {
	for session in host_sessions {
		delete(session.request_id)
		delete(session.shot_id)
		delete(session.pane_id)
	}
	delete(host_sessions)
	host_sessions = nil
	delete(host_history_root)
	host_history_root = ""
	delete(host_herdr_exe)
	host_herdr_exe = "herdr"
	_ = os.set_env("CS_STATE_DIR", fx.old_state)
	delete(fx.old_state)
	delete(fx.fake_dir)
	_ = host_dispatch_cleanup("herdr")
	free_all(context.temp_allocator)
	host_pool_test_end(fx.root)
}

// What a one-turn Shot reports in the gate run: no terminal kind.
reap_relay_one_turn :: proc(shot_id: string) {
	for kind in ([]string{"turn_done", "usage", "agent_exited"}) {
		host_relay_message(Activity_Message{brew_id = "req-1", shot_id = shot_id, kind = kind, description = "x"})
	}
}

@(test)
test_one_turn_exit_without_terminal_report_leaves_the_queue_stuck :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	fx := reap_fixture_begin(t)
	defer reap_fixture_end(fx)

	// Reproduction of the gate run: the reports arrive, the relay alone frees nothing.
	reap_relay_one_turn("shot-a")
	queued_count, _ := host_dispatch_queue_status()
	testing.expect_value(t, queued_count, 1)
	testing.expect_value(t, host_pane_in_use_count(), 1)
}

@(test)
test_station_gone_after_agent_exited_releases_slot_and_starts_queued_shot :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	fx := reap_fixture_begin(t)
	defer reap_fixture_end(fx)
	reap_relay_one_turn("shot-a")

	// Still running its Taste: nothing is released.
	live := []Process_Command{{pid = 7, args = {"coffee-shop", "station", "--station", "shot-a", "--brew", "req-1"}}}
	testing.expect_value(t, host_reap_gone_sessions(live), 0)
	testing.expect_value(t, host_pane_in_use_count(), 1)

	// The process is gone and no terminal report came: the slot is released and shot-b starts.
	testing.expect_value(t, host_reap_gone_sessions(nil), 1)
	queued_count, _ := host_dispatch_queue_status()
	testing.expect_value(t, queued_count, 0)
	testing.expect_value(t, len(host_sessions), 1)
	if len(host_sessions) == 1 {
		testing.expect_value(t, host_sessions[0].shot_id, "shot-b")
	}
	testing.expect_value(t, host_pane_in_use_count(), 1)
	// The fake herdr records a pid file only when asked to run the Station command.
	testing.expect(t, os.exists(fmt.tprintf("%s/pid-p0", fx.fake_dir)), "shot-b's Station command was run")
}

@(test)
test_pinned_station_is_not_reaped_when_its_process_is_gone :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	fx := reap_fixture_begin(t)
	defer reap_fixture_end(fx)
	reap_relay_one_turn("shot-a")
	host_relay_message(Activity_Message{brew_id = "req-1", shot_id = "shot-a", kind = "needs_input", description = "?"})

	testing.expect_value(t, host_reap_gone_sessions(nil), 0)
	queued_count, _ := host_dispatch_queue_status()
	testing.expect_value(t, queued_count, 1)
	testing.expect(t, host_pane_is_pinned(host_sessions[0].pane_id), "the pane stays pinned")
}
