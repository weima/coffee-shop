package main

import "core:testing"

@(test)
test_headless_slots_dequeue_in_order_after_release :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	root := host_pool_test_init()
	defer host_pool_test_end(root)
	defer host_dispatch_cleanup()

	active, queued, ok := host_dispatch_acquire("req-1", "shot-a")
	testing.expect(t, ok && !queued, "first Shot takes the slot")
	_, queued, ok = host_dispatch_acquire("req-1", "shot-b")
	testing.expect(t, ok && queued, "second Shot queues")
	_, queued, ok = host_dispatch_acquire("req-1", "shot-c")
	testing.expect(t, ok && queued, "third Shot queues")

	_ = headless_slot_release(active)
	delete(active)
	dequeued := host_dispatch_dequeue()
	defer delete(dequeued)
	testing.expect_value(t, len(dequeued), 1)
	if len(dequeued) == 1 {
		testing.expect_value(t, dequeued[0][1], "shot-b")
	}
	queued_count, _ := host_dispatch_queue_status()
	testing.expect_value(t, queued_count, 1)
}

@(test)
test_headless_slots_dequeue_by_request :: proc(t: ^testing.T) {
	host_pool_test_lock()
	defer host_pool_test_unlock()
	root := host_pool_test_init()
	defer host_pool_test_end(root)
	defer host_dispatch_cleanup()

	active, _, _ := host_dispatch_acquire("req-0", "shot-active")
	defer delete(active)
	_, queued, _ := host_dispatch_acquire("req-1", "shot-a")
	testing.expect(t, queued, "first Shot queues")
	_, queued, _ = host_dispatch_acquire("req-2", "shot-b")
	testing.expect(t, queued, "second Shot queues")

	cancelled := host_dispatch_dequeue_by_request("req-1")
	testing.expect_value(t, cancelled, 1)
	queued_count, _ := host_dispatch_queue_status()
	testing.expect_value(t, queued_count, 1)
	if len(host_dispatch_queue) == 1 {
		testing.expect_value(t, host_dispatch_queue[0].request_id, "req-2")
	}
}
