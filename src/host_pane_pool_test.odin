package main

import "core:testing"

@(test)
test_host_pane_pool_dispatch_and_terminal :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	// Simulate a dispatch cycle: acquire → terminal → reclaim → reuse
	host_pane_pool_init("ws-test", 3)
	defer pane_pool_destroy(&host_pane_pool)

	// First dispatch acquires a pane.
	pane1, ok1 := host_pane_acquire("req-1", "shot-a")
	testing.expect(t, ok1, "first acquire should succeed")
	testing.expect_value(t, pane1, "p0")

	// Check pool is in use.
	in_use := host_pane_in_use_count()
	testing.expect_value(t, in_use, 1)

	// Simulate terminal report: mark the pane as reclaimable.
	mark_ok := host_pane_mark_terminal(pane1)
	testing.expect(t, mark_ok, "mark_terminal should succeed")

	// Reclaim the pane (clear and mark FREE).
	reclaim_ok := host_pane_reclaim(pane1)
	testing.expect(t, reclaim_ok, "reclaim should succeed")

	// Pool should have a free pane now.
	available := host_pane_available_count()
	testing.expect_value(t, available, 1)

	// Second dispatch should reuse the pane.
	pane2, ok2 := host_pane_acquire("req-2", "shot-b")
	testing.expect(t, ok2, "second acquire should succeed")
	testing.expect_value(t, pane2, "p0")

	delete(pane1)
	delete(pane2)
}

@(test)
test_host_pane_pool_waiting_for_human :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	// Simulate: acquire → needs_input (pin) → reply (unpin) → terminal
	host_pane_pool_init("ws-test-2", 2)
	defer pane_pool_destroy(&host_pane_pool)

	// Acquire a pane.
	pane, ok := host_pane_acquire("req-1", "shot-a")
	testing.expect(t, ok, "acquire should succeed")

	// Simulate needs_input: pin the pane.
	pin_ok := host_pane_pin(pane)
	testing.expect(t, pin_ok, "pin should succeed")

	// Pool should still show 1 in use (pinned panes count).
	in_use := host_pane_in_use_count()
	testing.expect_value(t, in_use, 1)

	// Try to acquire beyond capacity should fail (pane is pinned).
	pane2, ok2 := host_pane_acquire("req-2", "shot-b")
	testing.expect(t, ok2, "should still acquire since pool has room")

	// Now try another; should fail.
	pane3, ok3 := host_pane_acquire("req-3", "shot-c")
	testing.expect(t, !ok3, "should not acquire beyond capacity when pinned")

	// Simulate reply: unpin.
	unpin_ok := host_pane_unpin(pane)
	testing.expect(t, unpin_ok, "unpin should succeed")

	// Now mark terminal.
	mark_ok := host_pane_mark_terminal(pane)
	testing.expect(t, mark_ok, "mark_terminal should succeed")

	delete(pane)
	delete(pane2)
}

@(test)
test_host_pane_pool_capacity_enforced :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	host_pane_pool_init("ws-test-3", 2)
	defer pane_pool_destroy(&host_pane_pool)

	// Acquire up to capacity.
	pane1, ok1 := host_pane_acquire("req-1", "shot-a")
	testing.expect(t, ok1, "first acquire should succeed")

	pane2, ok2 := host_pane_acquire("req-2", "shot-b")
	testing.expect(t, ok2, "second acquire should succeed")

	// Try to acquire beyond capacity.
	pane3, ok3 := host_pane_acquire("req-3", "shot-c")
	testing.expect(t, !ok3, "acquire beyond capacity should fail")

	// Pool should show 2 in use.
	in_use := host_pane_in_use_count()
	testing.expect_value(t, in_use, 2)

	delete(pane1)
	delete(pane2)
}

@(test)
test_host_pane_pool_owned_persistence :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	host_pane_pool_init("ws-test-4", 3)
	defer pane_pool_destroy(&host_pane_pool)

	// Create a few panes.
	p1, _ := host_pane_acquire("req-1", "shot-a")
	p2, _ := host_pane_acquire("req-2", "shot-b")
	p3, _ := host_pane_acquire("req-3", "shot-c")

	// Verify the pool has owned panes.
	testing.expect_value(t, len(host_pane_pool.host_owned_pane_ids), 3)

	delete(p1)
	delete(p2)
	delete(p3)
}

@(test)
test_host_pane_pool_status :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	host_pane_pool_init("ws-test-5", 3)
	defer pane_pool_destroy(&host_pane_pool)

	p1, _ := host_pane_acquire("req-1", "shot-a")
	p2, _ := host_pane_acquire("req-2", "shot-b")

	status := host_pane_pool_status()
	defer delete(status)

	// Should report: 2 in use, 0 reclaimable, 1 free, capacity 3.
	testing.expect(t, len(status) > 0, "status should not be empty")

	delete(p1)
	delete(p2)
}
