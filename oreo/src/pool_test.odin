package oreo

// Tests for the bounded worker pool. They run against the real bundled SQLite
// engine through the host and store helpers, with an in-file fake Work_Fn.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import store "oreo:store"

// The fake work function is a plain proc with no user data, so its bookkeeping
// lives in one package-level value, reset by each test before it starts a pool.
@(private)
Pool_Test_Fake :: struct {
	mutex:       sync.Mutex,
	changed:     sync.Cond,
	calls:       int,
	running:     int,
	max_running: int,
	hold:        bool,
	released:    bool,
}

@(private)
pool_test_fake: Pool_Test_Fake

// Odin's test runner runs tests in parallel. The pool tests share the fakes and
// the event log, so they take this lock to run one at a time.
@(private)
pool_test_lock: sync.Mutex

@(test)
test_pool_runs_all_items_with_bounded_concurrency :: proc(t: ^testing.T) {
	sync.mutex_lock(&pool_test_lock)
	defer sync.mutex_unlock(&pool_test_lock)
	host, directory, path := pool_test_host(t)
	defer pool_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "pool concurrency")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	pool_test_reset(hold = false)
	pool, pool_err := pool_start(host, 2, pool_test_work)
	defer host_error_destroy(&pool_err)
	testing.expect_value(t, pool_err.kind, Host_Error_Kind.None)

	ids: [dynamic]string
	defer {
		for id in ids {
			delete(id)
		}
		delete(ids)
	}
	for _ in 0 ..< 6 {
		id, submit_err := pool_submit(pool, session.id, "fake-provider", "fake-model", "low", "work")
		testing.expect_value(t, submit_err.kind, Host_Error_Kind.None)
		host_error_destroy(&submit_err)
		append(&ids, id)
	}

	testing.expect(t, pool_wait_idle(pool, 30_000), "the pool did not become idle")

	items, list_err := store.list_work_items_by_session(pool_test_store(t, host), session.id)
	defer store.work_items_destroy(items)
	testing.expect_value(t, list_err.kind, store.Store_Error_Kind.None)
	testing.expect_value(t, len(items), 6)
	completed := 0
	for item in items {
		if item.status == store.WORK_ITEM_COMPLETED {
			completed += 1
		}
	}
	testing.expect_value(t, completed, 6)

	calls, max_running := pool_test_snapshot()
	testing.expect_value(t, calls, 6)
	testing.expect(t, max_running <= 2, "more than two work items ran at once")
	testing.expect_value(t, max_running, 2)

	pool_stop_err := pool_stop(&pool, false)
	defer host_error_destroy(&pool_stop_err)
	testing.expect_value(t, pool_stop_err.kind, Host_Error_Kind.None)
}

@(test)
test_pool_persists_completed_and_failed_items :: proc(t: ^testing.T) {
	sync.mutex_lock(&pool_test_lock)
	defer sync.mutex_unlock(&pool_test_lock)
	host, directory, path := pool_test_host(t)
	defer pool_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "pool outcomes")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	pool_test_reset(hold = false)
	pool, pool_err := pool_start(host, 2, pool_test_work)
	defer host_error_destroy(&pool_err)
	testing.expect_value(t, pool_err.kind, Host_Error_Kind.None)

	failed_id, failed_err := pool_submit(pool, session.id, "fake-provider", "fake-model", "low", "fail")
	defer delete(failed_id)
	defer host_error_destroy(&failed_err)
	testing.expect_value(t, failed_err.kind, Host_Error_Kind.None)
	completed_id, completed_err := pool_submit(pool, session.id, "fake-provider", "fake-model", "low", "ok")
	defer delete(completed_id)
	defer host_error_destroy(&completed_err)
	testing.expect_value(t, completed_err.kind, Host_Error_Kind.None)

	testing.expect(t, pool_wait_idle(pool, 30_000), "the pool did not become idle")

	store_handle := pool_test_store(t, host)
	testing.expect(t, pool_test_has_status(t, store_handle, failed_id, store.WORK_ITEM_FAILED))
	testing.expect(t, pool_test_has_status(t, store_handle, completed_id, store.WORK_ITEM_COMPLETED))

	pool_stop_err := pool_stop(&pool, false)
	defer host_error_destroy(&pool_stop_err)
	testing.expect_value(t, pool_stop_err.kind, Host_Error_Kind.None)
}

@(test)
test_pool_session_close_cancels_queued_items :: proc(t: ^testing.T) {
	sync.mutex_lock(&pool_test_lock)
	defer sync.mutex_unlock(&pool_test_lock)
	host, directory, path := pool_test_host(t)
	defer pool_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "pool close")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	// One worker holds its first item open, so the rest stay queued.
	pool_test_reset(hold = true)
	pool, pool_err := pool_start(host, 1, pool_test_work)
	defer host_error_destroy(&pool_err)
	testing.expect_value(t, pool_err.kind, Host_Error_Kind.None)

	ids: [dynamic]string
	defer {
		for id in ids {
			delete(id)
		}
		delete(ids)
	}
	for _ in 0 ..< 4 {
		id, submit_err := pool_submit(pool, session.id, "fake-provider", "fake-model", "low", "work")
		testing.expect_value(t, submit_err.kind, Host_Error_Kind.None)
		host_error_destroy(&submit_err)
		append(&ids, id)
	}
	pool_test_wait_for_call(t)

	close_err := close_session(host, session.id)
	defer host_error_destroy(&close_err)
	testing.expect_value(t, close_err.kind, Host_Error_Kind.None)
	pool_test_release()

	testing.expect(t, pool_wait_idle(pool, 30_000), "the pool did not become idle")

	items, list_err := store.list_work_items_by_session(pool_test_store(t, host), session.id)
	defer store.work_items_destroy(items)
	testing.expect_value(t, list_err.kind, store.Store_Error_Kind.None)
	testing.expect_value(t, len(items), 4)
	cancelled := 0
	unfinished := 0
	for item in items {
		if item.status == store.WORK_ITEM_CANCELLED {
			cancelled += 1
		}
		if item.status == store.WORK_ITEM_QUEUED || item.status == store.WORK_ITEM_RUNNING {
			unfinished += 1
		}
	}
	testing.expect_value(t, unfinished, 0)
	testing.expect_value(t, cancelled, 4)

	calls, _ := pool_test_snapshot()
	testing.expect_value(t, calls, 1)

	pool_stop_err := pool_stop(&pool, false)
	defer host_error_destroy(&pool_stop_err)
	testing.expect_value(t, pool_stop_err.kind, Host_Error_Kind.None)
}

@(private)
pool_test_work :: proc(input: Work_Item_Input) -> Work_Item_Result {
	fake := &pool_test_fake
	sync.mutex_lock(&fake.mutex)
	fake.calls += 1
	fake.running += 1
	if fake.running > fake.max_running {
		fake.max_running = fake.running
	}
	sync.cond_broadcast(&fake.changed)
	// Test 3 holds every call open until the test releases it.
	if fake.hold {
		for !fake.released {
			sync.cond_wait(&fake.changed, &fake.mutex)
		}
	}
	sync.mutex_unlock(&fake.mutex)

	// Hold each call briefly so concurrent workers are observed to overlap.
	time.sleep(30 * time.Millisecond)

	ok := input.request != "fail"

	sync.mutex_lock(&fake.mutex)
	fake.running -= 1
	sync.cond_broadcast(&fake.changed)
	sync.mutex_unlock(&fake.mutex)
	return Work_Item_Result{ok = ok, output = ""}
}

@(private)
pool_test_reset :: proc(hold: bool) {
	pool_test_fake.hold = hold
	pool_test_fake.released = false
	pool_test_fake.calls = 0
	pool_test_fake.running = 0
	pool_test_fake.max_running = 0
}

@(private)
pool_test_snapshot :: proc() -> (calls: int, max_running: int) {
	sync.mutex_lock(&pool_test_fake.mutex)
	calls = pool_test_fake.calls
	max_running = pool_test_fake.max_running
	sync.mutex_unlock(&pool_test_fake.mutex)
	return
}

@(private)
pool_test_wait_for_call :: proc(t: ^testing.T) {
	start := time.now()
	started := false
	for time.since(start) < 5*time.Second {
		sync.mutex_lock(&pool_test_fake.mutex)
		started = pool_test_fake.calls >= 1
		sync.mutex_unlock(&pool_test_fake.mutex)
		if started {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, started, "no worker started the held work item")
}

@(private)
pool_test_release :: proc() {
	sync.mutex_lock(&pool_test_fake.mutex)
	pool_test_fake.released = true
	sync.cond_broadcast(&pool_test_fake.changed)
	sync.mutex_unlock(&pool_test_fake.mutex)
}

@(private)
pool_test_has_status :: proc(t: ^testing.T, store_handle: store.Store, work_item_id, wanted: string) -> bool {
	item, found, item_err := store.get_work_item(store_handle, work_item_id)
	defer store.work_item_destroy(&item)
	defer store.store_error_destroy(&item_err)
	testing.expect(t, found)
	testing.expect_value(t, item_err.kind, store.Store_Error_Kind.None)
	return item.status == wanted
}

@(private)
pool_test_store :: proc(t: ^testing.T, host: Host) -> store.Store {
	store_handle, store_err := pool_store(host)
	defer host_error_destroy(&store_err)
	testing.expect_value(t, store_err.kind, Host_Error_Kind.None)
	return store_handle
}

@(private)
pool_test_host :: proc(t: ^testing.T) -> (Host, string, string) {
	directory, directory_err := os.make_directory_temp(TEMP_DIR, "oreo-pool-*", context.allocator)
	testing.expect_value(t, directory_err, os.Error(nil))
	path, path_err := filepath.join({directory, "sessions.db"}, context.allocator)
	testing.expect(t, path_err == nil)
	host: Host
	open_err: Host_Error
	host, open_err = open_host(path)
	host_error_destroy(&open_err)
	testing.expect_value(t, open_err.kind, Host_Error_Kind.None)
	return host, directory, path
}

@(private)
pool_test_cleanup :: proc(host: ^Host, directory, path: string) {
	close_err := close_host(host)
	host_error_destroy(&close_err)
	_ = os.remove_all(directory)
	delete(directory)
	delete(path)
}

// The pause tests use one fake that pauses on its first call and records the
// reply its second call was resumed with.
@(private)
POOL_TEST_PAUSE_MESSAGE :: "need input"

@(private)
Pool_Test_Pause :: struct {
	mutex:         sync.Mutex,
	paused_once:   bool,
	resumed_calls: int,
	seen_resumed:  string,
}

@(private)
pool_test_pause: Pool_Test_Pause

@(private)
pool_test_pause_work :: proc(input: Work_Item_Input) -> Work_Item_Result {
	sync.mutex_lock(&pool_test_pause.mutex)
	should_pause := !pool_test_pause.paused_once
	pool_test_pause.paused_once = true
	sync.mutex_unlock(&pool_test_pause.mutex)
	if should_pause {
		return Work_Item_Result{ok = true, needs_input = true, output = POOL_TEST_PAUSE_MESSAGE}
	}
	sync.mutex_lock(&pool_test_pause.mutex)
	delete(pool_test_pause.seen_resumed)
	pool_test_pause.seen_resumed = strings.clone(input.resumed_input)
	pool_test_pause.resumed_calls += 1
	sync.mutex_unlock(&pool_test_pause.mutex)
	return Work_Item_Result{ok = true, output = "resumed result"}
}

@(private)
pool_test_pause_reset :: proc() {
	sync.mutex_lock(&pool_test_pause.mutex)
	delete(pool_test_pause.seen_resumed)
	pool_test_pause.seen_resumed = ""
	pool_test_pause.paused_once = false
	pool_test_pause.resumed_calls = 0
	sync.mutex_unlock(&pool_test_pause.mutex)
}

@(private)
pool_test_pause_resumed :: proc() -> (seen: string, calls: int) {
	sync.mutex_lock(&pool_test_pause.mutex)
	defer sync.mutex_unlock(&pool_test_pause.mutex)
	return pool_test_pause.seen_resumed, pool_test_pause.resumed_calls
}

// The event log records copies: Agent_Event strings are borrowed by the pool.
@(private)
Pool_Test_Event_Log :: struct {
	mutex:  sync.Mutex,
	events: [dynamic]Agent_Event,
}

@(private)
pool_test_events: Pool_Test_Event_Log

@(private)
pool_test_record_event :: proc(event: Agent_Event) {
	sync.mutex_lock(&pool_test_events.mutex)
	defer sync.mutex_unlock(&pool_test_events.mutex)
	_, _ = append(&pool_test_events.events, Agent_Event{
		kind         = event.kind,
		session_id   = strings.clone(event.session_id, context.allocator),
		work_item_id = strings.clone(event.work_item_id, context.allocator),
		message      = strings.clone(event.message, context.allocator),
	})
}

// pool_test_event_clear releases the log. Call it before a test starts and
// after its pool stops, once no worker can still emit.
@(private)
pool_test_event_clear :: proc() {
	sync.mutex_lock(&pool_test_events.mutex)
	defer sync.mutex_unlock(&pool_test_events.mutex)
	for event in pool_test_events.events {
		delete(event.session_id)
		delete(event.work_item_id)
		delete(event.message)
	}
	delete(pool_test_events.events)
	pool_test_events.events = nil
}

@(private)
pool_test_event_len :: proc() -> int {
	sync.mutex_lock(&pool_test_events.mutex)
	defer sync.mutex_unlock(&pool_test_events.mutex)
	return len(pool_test_events.events)
}

@(private)
pool_test_event_count :: proc(kind: Agent_Event_Kind) -> int {
	sync.mutex_lock(&pool_test_events.mutex)
	defer sync.mutex_unlock(&pool_test_events.mutex)
	count := 0
	for event in pool_test_events.events {
		if event.kind == kind {
			count += 1
		}
	}
	return count
}

@(private)
pool_test_event_at :: proc(index: int) -> Agent_Event {
	sync.mutex_lock(&pool_test_events.mutex)
	defer sync.mutex_unlock(&pool_test_events.mutex)
	if index < 0 || index >= len(pool_test_events.events) {
		return {}
	}
	return pool_test_events.events[index]
}

@(private)
pool_test_find_event :: proc(kind: Agent_Event_Kind) -> (Agent_Event, bool) {
	sync.mutex_lock(&pool_test_events.mutex)
	defer sync.mutex_unlock(&pool_test_events.mutex)
	for event in pool_test_events.events {
		if event.kind == kind {
			return event, true
		}
	}
	return {}, false
}

@(private)
pool_test_event_work :: proc(input: Work_Item_Input) -> Work_Item_Result {
	return Work_Item_Result{ok = true, output = input.request}
}

@(test)
test_pool_pauses_for_input_and_runs_other_items :: proc(t: ^testing.T) {
	sync.mutex_lock(&pool_test_lock)
	defer sync.mutex_unlock(&pool_test_lock)
	host, directory, path := pool_test_host(t)
	defer pool_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "pool pause")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	pool_test_pause_reset()
	pool_test_event_clear()
	// One worker proves that a pause releases it for the other item.
	pool, pool_err := pool_start(host, 1, pool_test_pause_work, pool_test_record_event)
	defer host_error_destroy(&pool_err)
	testing.expect_value(t, pool_err.kind, Host_Error_Kind.None)

	paused_id, paused_err := pool_submit(pool, session.id, "fake-provider", "fake-model", "low", "pause")
	defer delete(paused_id)
	defer host_error_destroy(&paused_err)
	testing.expect_value(t, paused_err.kind, Host_Error_Kind.None)
	other_id, other_err := pool_submit(pool, session.id, "fake-provider", "fake-model", "low", "other")
	defer delete(other_id)
	defer host_error_destroy(&other_err)
	testing.expect_value(t, other_err.kind, Host_Error_Kind.None)

	testing.expect(t, pool_wait_idle(pool, 30_000), "the pool did not become idle")

	store_handle := pool_test_store(t, host)
	testing.expect(t, pool_test_has_status(t, store_handle, paused_id, store.WORK_ITEM_NEEDS_INPUT))
	testing.expect(t, pool_test_has_status(t, store_handle, other_id, store.WORK_ITEM_COMPLETED))
	testing.expect_value(t, pool_test_event_count(.Needs_Input), 1)

	pause_event, pause_found := pool_test_find_event(.Needs_Input)
	testing.expect(t, pause_found)
	testing.expect_value(t, pause_event.work_item_id, paused_id)
	testing.expect_value(t, pause_event.message, POOL_TEST_PAUSE_MESSAGE)

	pool_stop_err := pool_stop(&pool, false)
	defer host_error_destroy(&pool_stop_err)
	testing.expect_value(t, pool_stop_err.kind, Host_Error_Kind.None)
	pool_test_event_clear()
}

@(test)
test_pool_resume_requeues_with_caller_input :: proc(t: ^testing.T) {
	sync.mutex_lock(&pool_test_lock)
	defer sync.mutex_unlock(&pool_test_lock)
	host, directory, path := pool_test_host(t)
	defer pool_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "pool resume")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	pool_test_pause_reset()
	pool_test_event_clear()
	pool, pool_err := pool_start(host, 1, pool_test_pause_work, pool_test_record_event)
	defer host_error_destroy(&pool_err)
	testing.expect_value(t, pool_err.kind, Host_Error_Kind.None)

	item_id, submit_err := pool_submit(pool, session.id, "fake-provider", "fake-model", "low", "pause")
	defer delete(item_id)
	defer host_error_destroy(&submit_err)
	testing.expect_value(t, submit_err.kind, Host_Error_Kind.None)

	testing.expect(t, pool_wait_idle(pool, 30_000), "the pool did not become idle while paused")
	store_handle := pool_test_store(t, host)
	testing.expect(t, pool_test_has_status(t, store_handle, item_id, store.WORK_ITEM_NEEDS_INPUT))

	resume_err := pool_resume(pool, item_id, "the caller reply")
	defer host_error_destroy(&resume_err)
	testing.expect_value(t, resume_err.kind, Host_Error_Kind.None)

	testing.expect(t, pool_wait_idle(pool, 30_000), "the pool did not finish the resumed item")
	testing.expect(t, pool_test_has_status(t, store_handle, item_id, store.WORK_ITEM_COMPLETED))

	seen, resumed_calls := pool_test_pause_resumed()
	testing.expect_value(t, resumed_calls, 1)
	testing.expect_value(t, seen, "the caller reply")
	pool_test_pause_reset()

	final_event, final_found := pool_test_find_event(.Final_Result)
	testing.expect(t, final_found)
	testing.expect_value(t, final_event.work_item_id, item_id)
	testing.expect_value(t, final_event.message, "resumed result")

	// The reply is durable context, not just an in-memory handoff.
	records, records_err := store.list_work_item_records(store_handle, item_id)
	defer store.records_destroy(records)
	testing.expect_value(t, records_err.kind, store.Store_Error_Kind.None)
	reply_recorded := false
	for record in records {
		if record.kind == POOL_INPUT_RECORD_KIND {
			reply_recorded = true
		}
	}
	testing.expect(t, reply_recorded, "the caller reply was not recorded")

	pool_stop_err := pool_stop(&pool, false)
	defer host_error_destroy(&pool_stop_err)
	testing.expect_value(t, pool_stop_err.kind, Host_Error_Kind.None)
	pool_test_event_clear()
}

@(test)
test_pool_events_surround_each_item :: proc(t: ^testing.T) {
	sync.mutex_lock(&pool_test_lock)
	defer sync.mutex_unlock(&pool_test_lock)
	host, directory, path := pool_test_host(t)
	defer pool_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "pool events")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	pool_test_event_clear()
	// One worker makes the event order deterministic.
	pool, pool_err := pool_start(host, 1, pool_test_event_work, pool_test_record_event)
	defer host_error_destroy(&pool_err)
	testing.expect_value(t, pool_err.kind, Host_Error_Kind.None)

	requests := [3]string{"event-1", "event-2", "event-3"}
	ids: [dynamic]string
	defer {
		for id in ids {
			delete(id)
		}
		delete(ids)
	}
	for request in requests {
		id, submit_err := pool_submit(pool, session.id, "fake-provider", "fake-model", "low", request)
		testing.expect_value(t, submit_err.kind, Host_Error_Kind.None)
		host_error_destroy(&submit_err)
		append(&ids, id)
	}

	testing.expect(t, pool_wait_idle(pool, 30_000), "the pool did not become idle")
	testing.expect_value(t, pool_test_event_len(), len(requests) * 2)
	for request, index in requests {
		progress := pool_test_event_at(index * 2)
		final := pool_test_event_at(index * 2 + 1)
		testing.expect_value(t, progress.kind, Agent_Event_Kind.Progress)
		testing.expect_value(t, progress.work_item_id, ids[index])
		testing.expect_value(t, final.kind, Agent_Event_Kind.Final_Result)
		testing.expect_value(t, final.work_item_id, ids[index])
		testing.expect_value(t, final.message, request)
	}

	pool_stop_err := pool_stop(&pool, false)
	defer host_error_destroy(&pool_stop_err)
	testing.expect_value(t, pool_stop_err.kind, Host_Error_Kind.None)
	pool_test_event_clear()
}
