package main

import "core:testing"

@(test)
test_pane_pool_acquire_reuse :: proc(t: ^testing.T) {
	pool := pane_pool_init(3, "ws-123")
	defer pane_pool_destroy(&pool)

	// Acquire first pane (new).
	id1, is_new1, ok1 := pane_pool_acquire(&pool, "req-1", "shot-a")
	testing.expect(t, ok1, "first acquire should succeed")
	testing.expect(t, is_new1, "first acquire should be new")
	testing.expect_value(t, id1, "p0")

	// Acquire second pane (new).
	id2, is_new2, ok2 := pane_pool_acquire(&pool, "req-2", "shot-b")
	testing.expect(t, ok2, "second acquire should succeed")
	testing.expect(t, is_new2, "second acquire should be new")
	testing.expect_value(t, id2, "p1")

	// Mark first as reclaimable.
	reclaim_ok := pane_pool_mark_reclaimable(&pool, id1)
	testing.expect(t, reclaim_ok, "mark_reclaimable should succeed")

	// Reclaim first pane.
	reclaim := pane_pool_reclaim(&pool, id1)
	testing.expect(t, reclaim, "reclaim should succeed")

	// Acquire third pane from the pool (reuse p0).
	id3, is_new3, ok3 := pane_pool_acquire(&pool, "req-3", "shot-c")
	testing.expect(t, ok3, "third acquire should succeed")
	testing.expect(t, !is_new3, "third acquire should reuse")
	testing.expect_value(t, id3, "p0")

	delete(id1)
	delete(id2)
	delete(id3)
}

@(test)
test_pane_pool_capacity :: proc(t: ^testing.T) {
	pool := pane_pool_init(2, "ws-456")
	defer pane_pool_destroy(&pool)

	// Acquire up to capacity.
	id1, _, ok1 := pane_pool_acquire(&pool, "req-1", "shot-a")
	testing.expect(t, ok1, "first acquire should succeed")
	id2, _, ok2 := pane_pool_acquire(&pool, "req-2", "shot-b")
	testing.expect(t, ok2, "second acquire should succeed")

	// Try to acquire beyond capacity.
	_, _, ok3 := pane_pool_acquire(&pool, "req-3", "shot-c")
	testing.expect(t, !ok3, "acquire beyond capacity should fail")

	// Mark one as reclaimable.
	pane_pool_mark_reclaimable(&pool, id1)
	pane_pool_reclaim(&pool, id1)

	// Now we should be able to acquire.
	id3, is_new3, ok4 := pane_pool_acquire(&pool, "req-3", "shot-c")
	testing.expect(t, ok4, "acquire after reclaim should succeed")
	testing.expect(t, !is_new3, "should reuse")

	delete(id1)
	delete(id2)
	delete(id3)
}

@(test)
test_pane_pool_waiting_for_human :: proc(t: ^testing.T) {
	pool := pane_pool_init(2, "ws-789")
	defer pane_pool_destroy(&pool)

	// Acquire a pane.
	id1, _, ok := pane_pool_acquire(&pool, "req-1", "shot-a")
	testing.expect(t, ok, "acquire should succeed")

	// Pin it (ALLOCATED → WAITING_FOR_HUMAN).
	pin_ok := pane_pool_pin(&pool, id1)
	testing.expect(t, pin_ok, "pin should succeed")

	// In-use count should include pinned panes.
	in_use := pane_pool_in_use(&pool)
	testing.expect_value(t, in_use, 1)

	// Unpin it (WAITING_FOR_HUMAN → RECLAIMABLE).
	unpin_ok := pane_pool_unpin(&pool, id1)
	testing.expect(t, unpin_ok, "unpin should succeed")

	// Now it's reclaimable.
	reclaimable := pane_pool_reclaimable(&pool)
	testing.expect_value(t, reclaimable, 1)

	// Reclaim it.
	reclaim_ok := pane_pool_reclaim(&pool, id1)
	testing.expect(t, reclaim_ok, "reclaim should succeed")

	delete(id1)
}

@(test)
test_pane_pool_invalid_transitions :: proc(t: ^testing.T) {
	pool := pane_pool_init(2, "ws-101")
	defer pane_pool_destroy(&pool)

	// Acquire a pane.
	id1, _, ok := pane_pool_acquire(&pool, "req-1", "shot-a")
	testing.expect(t, ok, "acquire should succeed")

	// Try to unpin an ALLOCATED pane (should fail).
	unpin_fail := pane_pool_unpin(&pool, id1)
	testing.expect(t, !unpin_fail, "unpin ALLOCATED should fail")

	// Try to reclaim an ALLOCATED pane (should fail).
	reclaim_fail := pane_pool_reclaim(&pool, id1)
	testing.expect(t, !reclaim_fail, "reclaim ALLOCATED should fail")

	delete(id1)
}

@(test)
test_pane_pool_mark_reclaimable :: proc(t: ^testing.T) {
	pool := pane_pool_init(2, "ws-202")
	defer pane_pool_destroy(&pool)

	// Acquire and pin a pane.
	id1, _, ok := pane_pool_acquire(&pool, "req-1", "shot-a")
	testing.expect(t, ok, "acquire should succeed")
	pane_pool_pin(&pool, id1)

	// Mark as reclaimable (WAITING_FOR_HUMAN → RECLAIMABLE).
	mark_ok := pane_pool_mark_reclaimable(&pool, id1)
	testing.expect(t, mark_ok, "mark_reclaimable on WAITING_FOR_HUMAN should succeed")

	// Should be reclaimable now.
	reclaimable := pane_pool_reclaimable(&pool)
	testing.expect_value(t, reclaimable, 1)

	delete(id1)
}
