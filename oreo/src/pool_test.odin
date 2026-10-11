package oreo

// Tests for the bounded worker pool. They run against the real bundled SQLite
// engine through the host and store helpers, with an in-file fake Work_Fn.

import "core:os"
import "core:path/filepath"
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

// Odin's test runner runs tests in parallel. The three pool tests share one
// fake, so they take this lock to run one at a time.
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
