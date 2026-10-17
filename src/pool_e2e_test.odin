package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// End-to-end tests for pool dispatch, queueing, reuse, and recovery.
// These test the integration between acquisition, reclamation, and dispatch.

@(test)
test_dispatch_pool_acquire_and_queue :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	// Initialize pool with capacity 2.
	pool_root := host_pool_test_init("ws-e2e-1")
	defer host_pool_test_end(pool_root)
	host_pane_pool.capacity = 2
	defer host_dispatch_cleanup("herdr")

	// First two Shots should acquire panes immediately.
	id1, q1, ok1 := host_dispatch_acquire("req-1", "shot-a")
	testing.expect(t, ok1, "first acquire should succeed")
	testing.expect(t, !q1, "first acquire should not queue")
	testing.expect_value(t, id1, "p0")

	id2, q2, ok2 := host_dispatch_acquire("req-1", "shot-b")
	testing.expect(t, ok2, "second acquire should succeed")
	testing.expect(t, !q2, "second acquire should not queue")
	testing.expect_value(t, id2, "p1")

	// Third Shot should queue (pool at capacity).
	id3, q3, ok3 := host_dispatch_acquire("req-1", "shot-c")
	testing.expect(t, ok3, "third acquire should succeed (queued)")
	testing.expect(t, q3, "third acquire should queue")
	testing.expect_value(t, id3, "")

	// Queue should have one item.
	queued_count, _ := host_dispatch_queue_status()
	testing.expect_value(t, queued_count, 1)

	delete(id1)
	delete(id2)
	delete(id3)
}

@(test)
test_dispatch_pool_dequeue_on_reclaim :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	// Initialize pool with capacity 1.
	pool_root := host_pool_test_init("ws-e2e-2")
	defer host_pool_test_end(pool_root)
	host_pane_pool.capacity = 1
	defer host_dispatch_cleanup("herdr")

	// Acquire the only pane.
	id1, q1, ok1 := host_dispatch_acquire("req-1", "shot-a")
	testing.expect(t, ok1, "acquire should succeed")
	testing.expect(t, !q1, "should not queue")

	// Queue two Shots.
	_, q2, ok2 := host_dispatch_acquire("req-1", "shot-b")
	testing.expect(t, q2, "should queue")
	host_dispatch_queue_store_metadata("req-1", "shot-b", "/repo", "prompt", "model", "provider", "thinking", "execute", "pi", "taste", "message", "/station")
	_, q3, ok3 := host_dispatch_acquire("req-1", "shot-c")
	testing.expect(t, q3, "should queue")

	// Reclaim the pane.
	host_pane_mark_terminal(id1)
	host_pane_reclaim(id1)

	// Dequeue and check first queued Shot is ready.
	dequeued := host_dispatch_dequeue()
	testing.expect_value(t, len(dequeued), 1)
	if len(dequeued) > 0 {
		testing.expect_value(t, dequeued[0][1], "shot-b")
	}

	// Queue should have one item left.
	queued_count, _ := host_dispatch_queue_status()
	testing.expect_value(t, queued_count, 1)

	delete(id1)
	delete(dequeued)
}

@(test)
test_dispatch_pool_dequeue_by_request :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	// Initialize pool with capacity 1.
	pool_root := host_pool_test_init("ws-e2e-3")
	defer host_pool_test_end(pool_root)
	host_pane_pool.capacity = 1
	defer host_dispatch_cleanup("herdr")

	// Keep capacity occupied, then queue Shots from two different requests.
	active_pane, _, _ := host_dispatch_acquire("req-0", "shot-active")
	defer delete(active_pane)
	_, q1, _ := host_dispatch_acquire("req-1", "shot-a")
	testing.expect(t, q1, "should queue")
	_, q2, _ := host_dispatch_acquire("req-2", "shot-b")
	testing.expect(t, q2, "should queue")

	// Cancel all Shots from req-1.
	cancelled := host_dispatch_dequeue_by_request("req-1")
	testing.expect_value(t, cancelled, 1)

	// Queue should have only req-2's Shot.
	queued_count, _ := host_dispatch_queue_status()
	testing.expect_value(t, queued_count, 1)
}

@(test)
test_dispatch_pool_reuse_after_clear :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	// Initialize pool with capacity 1.
	pool_root := host_pool_test_init("ws-e2e-4")
	defer host_pool_test_end(pool_root)
	host_pane_pool.capacity = 1
	defer host_dispatch_cleanup("herdr")

	// Acquire and immediately release (in normal flow, dispatch would launch here).
	id1, _, ok1 := host_dispatch_acquire("req-1", "shot-a")
	testing.expect(t, ok1, "acquire should succeed")

	// Simulate terminal report.
	host_pane_mark_terminal(id1)

	// Reclaim the pane (clear happens here in real flow).
	ok_reclaim := host_pane_reclaim(id1)
	testing.expect(t, ok_reclaim, "reclaim should succeed")

	// Next acquire should reuse the same pane.
	id2, _, ok2 := host_dispatch_acquire("req-2", "shot-b")
	testing.expect(t, ok2, "second acquire should succeed")
	testing.expect_value(t, id2, "p0")

	delete(id1)
	delete(id2)
}

@(test)
test_dispatch_pool_waiting_for_human :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	// Initialize pool with capacity 2.
	pool_root := host_pool_test_init("ws-e2e-5")
	defer host_pool_test_end(pool_root)
	host_pane_pool.capacity = 2
	defer host_dispatch_cleanup("herdr")

	// Acquire two panes.
	id1, _, ok1 := host_dispatch_acquire("req-1", "shot-a")
	testing.expect(t, ok1, "first acquire should succeed")
	id2, _, ok2 := host_dispatch_acquire("req-1", "shot-b")
	testing.expect(t, ok2, "second acquire should succeed")

	// Pin one pane (needs_input).
	host_pane_pin(id1)

	// Third Shot should queue (pinned pane counts against capacity).
	_, q3, ok3 := host_dispatch_acquire("req-1", "shot-c")
	testing.expect(t, q3, "should queue because of pinned pane")

	// Unpin and reclaim.
	host_pane_unpin(id1)
	host_pane_reclaim(id1)

	// Dequeue should succeed.
	dequeued := host_dispatch_dequeue()
	testing.expect_value(t, len(dequeued), 1)

	delete(id1)
	delete(id2)
	delete(dequeued)
}

@(test)
test_pane_clear_sequences_valid :: proc(t: ^testing.T) {
	// Verify that clear sequences are well-formed.
	init_pane_clear()

	testing.expect(t, strings.contains(PANE_RESET_SEQUENCE, "\x1b["), "reset sequence should contain escape code")
	testing.expect(t, strings.contains(PANE_RESET_SEQUENCE, "2J"), "should contain clear display")
	testing.expect(t, strings.contains(PANE_RESET_SEQUENCE, "H"), "should contain cursor home")
	testing.expect(t, strings.contains(PANE_RESET_SEQUENCE, "0m"), "should contain reset attributes")
	testing.expect(t, strings.contains(PANE_RESET_SEQUENCE, "7h"), "should contain autowrap on")
	testing.expect(t, strings.contains(PANE_RESET_SEQUENCE, "25h"), "should contain cursor visible")
}
