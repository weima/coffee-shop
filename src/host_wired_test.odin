package main

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

// Give each slot test a private machine limit so it cannot collide with a live host.
host_pool_test_init :: proc() -> string {
	root, err := os.make_directory_temp(HOST_TEST_TEMP_DIR, "coffee-shop-slots-*", context.allocator)
	assert(err == nil, "cannot create the test state root")
	host_dispatch_init_at(root)
	headless_slots.capacity = 1
	return root
}

host_pool_test_end :: proc(root: string) {
	os.remove_all(root)
	delete(root)
}

@(test)
test_host_dispatch_acquire_queues_at_capacity :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	root := host_pool_test_init()
	defer host_pool_test_end(root)
	defer host_dispatch_cleanup()

	for i in 0..<6 {
		id := fmt.aprintf("shot-%d", i)
		session_id, queued, ok := host_dispatch_acquire("req-1", id)
		delete(id)
		if !queued {
			delete(session_id)
		}
		testing.expect(t, ok, "acquire should succeed or queue")
		if i == 0 {
			testing.expect(t, !queued, "first Shot occupies the only slot")
		} else {
			testing.expect(t, queued, "later Shots wait for a slot")
		}
	}
	queued_count, _ := host_dispatch_queue_status()
	testing.expect_value(t, queued_count, 5)
	testing.expect_value(t, len(headless_slots.held), 1)
}

@(test)
test_host_slot_release_starts_next_queued_shot :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	root := host_pool_test_init()
	defer host_pool_test_end(root)
	defer host_dispatch_cleanup()

	active, queued, ok := host_dispatch_acquire("req-1", "shot-a")
	testing.expect(t, ok && !queued, "first Shot takes the slot")
	_, queued, ok = host_dispatch_acquire("req-1", "shot-b")
	testing.expect(t, ok && queued, "second Shot waits")

	_ = headless_slot_release(active)
	dequeued := host_dispatch_dequeue()
	defer delete(dequeued)
	testing.expect_value(t, len(dequeued), 1)
	if len(dequeued) == 1 {
		testing.expect_value(t, dequeued[0][1], "shot-b")
	}
	delete(active)
}

@(test)
test_host_dispatch_cleanup_releases_owned_state :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	root := host_pool_test_init()
	defer host_pool_test_end(root)

	for i in 0..<5 {
		shot_id := fmt.aprintf("shot-%d", i)
		session_id, _, _ := host_dispatch_acquire("req-1", shot_id)
		delete(session_id)
		delete(shot_id)
	}
	_, queued, _ := host_dispatch_acquire("req-1", "shot-queued")
	if queued {
		host_dispatch_queue_store_metadata("req-1", "shot-queued", "/repo", "prompt", "model", "provider", "thinking", "execute", "pi", "taste", "message", "/station")
	}

	host_dispatch_cleanup()
	testing.expect_value(t, len(headless_slots.held), 0)
	testing.expect_value(t, len(host_dispatch_queue), 0)
}

@(test)
test_is_terminal_report_kinds :: proc(t: ^testing.T) {
	for kind in ([]string{"pulled", "taste_failed", "incomplete", "session_failed"}) {
		testing.expect(t, is_terminal_report(kind), kind)
	}
	for kind in ([]string{"needs_input", "progress", "agent_exited"}) {
		testing.expect(t, !is_terminal_report(kind), kind)
	}
}

Reap_Fixture :: struct {
	root: string,
	old_state: string,
	old_state_set: bool,
	old_history_root: string,
	old_station_executable: string,
}

reap_fixture_begin :: proc(t: ^testing.T) -> Reap_Fixture {
	fx: Reap_Fixture
	fx.root = host_pool_test_init()
	fx.old_state, fx.old_state_set = os.lookup_env("CS_STATE_DIR", context.allocator)
	_ = os.set_env("CS_STATE_DIR", fx.root)
	fx.old_history_root = host_history_root
	fx.old_station_executable = host_station_executable
	host_history_root = fmt.aprintf("%s/host", fx.root)
	_ = os.make_directory_all(host_history_root)
	host_station_executable = "/bin/true"

	session_id, _, ok := host_dispatch_acquire("req-1", "shot-a")
	testing.expect(t, ok, "shot-a takes the only slot")
	append(&host_sessions, Host_Session{request_id = strings.clone("req-1"), shot_id = strings.clone("shot-a"), session_id = session_id})
	_, queued, _ := host_dispatch_acquire("req-1", "shot-b")
	testing.expect(t, queued, "shot-b queues behind the occupied slot")
	host_dispatch_queue_store_metadata("req-1", "shot-b", fx.root, "prompt", "", "", "", "research", "pi", "", "", fx.root)
	return fx
}

reap_fixture_end :: proc(fx: Reap_Fixture) {
	host_dispatch_cleanup()
	delete(host_history_root)
	host_history_root = fx.old_history_root
	host_station_executable = fx.old_station_executable
	if fx.old_state_set {
		_ = os.set_env("CS_STATE_DIR", fx.old_state)
	} else {
		_ = os.unset_env("CS_STATE_DIR")
	}
	delete(fx.old_state)
	free_all(context.temp_allocator)
	host_pool_test_end(fx.root)
}

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

	reap_relay_one_turn("shot-a")
	queued_count, _ := host_dispatch_queue_status()
	testing.expect_value(t, queued_count, 1)
	testing.expect_value(t, len(headless_slots.held), 1)
}

@(test)
test_station_gone_after_agent_exited_releases_slot_and_starts_queued_shot :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	fx := reap_fixture_begin(t)
	defer reap_fixture_end(fx)
	reap_relay_one_turn("shot-a")

	live := []Process_Command{{pid = 7, args = {"coffee-shop", "station", "--station", "shot-a", "--brew", "req-1"}}}
	testing.expect_value(t, host_reap_gone_sessions(live), 0)
	testing.expect_value(t, len(headless_slots.held), 1)

	testing.expect_value(t, host_reap_gone_sessions(nil), 1)
	queued_count, _ := host_dispatch_queue_status()
	testing.expect_value(t, queued_count, 0)
	testing.expect_value(t, len(host_sessions), 1)
	if len(host_sessions) == 1 {
		testing.expect_value(t, host_sessions[0].shot_id, "shot-b")
	}
	testing.expect_value(t, len(headless_slots.held), 1)
	log_path := fmt.aprintf("%s/host/req-1/logs/shot-b.log", fx.root)
	defer delete(log_path)
	testing.expect(t, os.exists(log_path), "shot-b's headless log was created")
}
