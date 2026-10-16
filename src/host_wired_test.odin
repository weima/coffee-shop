package main

import "core:fmt"
import "core:sync"
import "core:testing"

host_pool_test_mutex: sync.Mutex

host_pool_test_lock :: proc() {
	sync.mutex_lock(&host_pool_test_mutex)
}

host_pool_test_unlock :: proc() {
	sync.mutex_unlock(&host_pool_test_mutex)
}

// Regression tests for pool integration into host.odin.
// These test the real wired seams: dispatch queue, pane reclamation, terminal reports.

@(test)
test_host_dispatch_acquire_queues_at_capacity :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()

	// Test that dispatch queue works with real pool.
	host_dispatch_init("ws-host-test")
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
	host_dispatch_init("ws-host-test-2")
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
	host_dispatch_init("ws-host-test-3")
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

	host_dispatch_init("ws-host-cleanup-test")
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
