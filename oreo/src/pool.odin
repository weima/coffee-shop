package oreo

// The bounded worker pool. One long-lived host owns one pool of reusable worker
// threads; every task session submits work items into the same pool. The pool
// owns scheduling and threading only: every work-item lifecycle transition is
// persisted through the store.

import "base:runtime"
import "core:container/queue"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import store "oreo:store"

// Work_Item_Input carries everything one Work_Fn call needs. Every string is
// borrowed from the pool and is valid only for the duration of the call.
Work_Item_Input :: struct {
	work_item_id: string,
	session_id: string,
	profile_id: string,
	provider: string,
	model: string,
	thinking: string,
	request: string,
	// resumed_input is the caller's reply for an item that paused and was
	// resumed through pool_resume; empty on a first run.
	resumed_input: string,
}

// Work_Item_Result is the outcome of one Work_Fn call. `output` is not retained
// or released by the pool; its owner is the Work_Fn. Set needs_input to pause
// the item and hand `output` to the caller as a Needs_Input event.
Work_Item_Result :: struct {
	ok: bool,
	output: string,
	needs_input: bool,
	// resumed_input echoes the reply this call was resumed with, when any.
	resumed_input: string,
}

Work_Fn :: #type proc(input: Work_Item_Input) -> Work_Item_Result

// The store's record vocabulary names a caller's reply "input_response"; the
// store rejects any other kind, so this is what pool_resume persists.
POOL_INPUT_RECORD_KIND :: "input_response"

// Pool_Input_Payload is the JSON body stored for one caller reply.
@(private)
Pool_Input_Payload :: struct {
	input: string,
}

// Pool_Resume holds one caller reply until the resumed item runs again. Both
// strings are owned by the pool.
@(private)
Pool_Resume :: struct {
	work_item_id: string,
	input:        string,
}

@(private)
Pool_State :: struct {
	host:           Host,
	work:           Work_Fn,
	// events is the optional callback for Needs_Input, Progress, and
	// Final_Result events. It is invoked from worker threads.
	events:         Event_Fn,
	// allocator is the allocator the pool was started with. Workers adopt it so
	// every pool allocation and its matching free use one allocator, even when
	// the string crosses between the submitter and a worker thread.
	allocator:      runtime.Allocator,
	mutex:          sync.Mutex,
	// submit_mutex serializes provider-profile deduplication so two concurrent
	// submissions cannot race on the same profile row.
	submit_mutex:   sync.Mutex,
	work_available: sync.Cond,
	// idle is signalled whenever an in-flight item finishes, so pool_wait_idle
	// can block instead of polling.
	idle:           sync.Cond,
	// pending_ids is the FIFO of queued work-item ids owned by the pool. A
	// worker owns one id after popping it and releases it when the call returns.
	pending_ids:    queue.Queue(string),
	// pending counts ids that a worker has popped but not yet finished, so
	// pool_wait_idle cannot report idle during a pop/finish gap.
	pending:        int,
	stopping:       bool,
	// resumed holds caller replies for paused items until their next run. The
	// pool owns both strings in every entry.
	resumed:        [dynamic]Pool_Resume,
	threads:        [dynamic]^thread.Thread,
	first_error:    Host_Error,
	has_error:      bool,
}

// Pool is an opaque handle to one running worker pool.
Pool :: distinct ^Pool_State

// pool_start starts `workers` reusable worker threads (clamped to 1..5) over an
// open host. The pool borrows the host and the Work_Fn; close them after
// pool_stop. `events` is an optional callback for pool events and may be nil.
pool_start :: proc(host: Host, workers: int, work: Work_Fn, events: Event_Fn = nil) -> (Pool, Host_Error) {
	_, store_err := pool_store(host)
	if store_err.kind != .None {
		return Pool(nil), store_err
	}
	if work == nil {
		return Pool(nil), host_error(.Invalid_Argument, "a work function is required")
	}
	allocator := context.allocator
	state, alloc_err := new(Pool_State, allocator)
	if alloc_err != nil {
		return Pool(nil), host_error(.Out_Of_Memory, "could not allocate the worker pool")
	}
	state.host = host
	state.work = work
	state.events = events
	state.allocator = allocator
	worker_count := clamp(workers, 1, 5)
	state.threads = make([dynamic]^thread.Thread, 0, worker_count, allocator)

	if queue_err := queue.init(&state.pending_ids, queue.DEFAULT_CAPACITY, allocator); queue_err != nil {
		delete(state.threads)
		free(state, allocator)
		return Pool(nil), host_error(.Out_Of_Memory, "could not allocate the work queue")
	}
	state.resumed = make([dynamic]Pool_Resume, 0, 4, allocator)
	for _ in 0 ..< worker_count {
		worker := thread.create(pool_worker)
		if worker == nil {
			pool_abort_start(state)
			return Pool(nil), host_error(.Internal, "could not create a pool worker thread")
		}
		worker.data = rawptr(state)
		thread.start(worker)
		_, _ = append(&state.threads, worker)
	}
	return Pool(state), Host_Error{}
}

// pool_submit deduplicates the (provider, model, thinking) tuple into one
// provider profile, inserts a queued work item, and makes it available to a
// worker. The caller owns the returned work_item_id.
pool_submit :: proc(pool: Pool, session_id, provider, model, thinking, request: string) -> (work_item_id: string, err: Host_Error) {
	if pool == Pool(nil) {
		return "", host_error(.Closed, "the worker pool is not running")
	}
	state := cast(^Pool_State)pool
	sync.mutex_lock(&state.submit_mutex)
	defer sync.mutex_unlock(&state.submit_mutex)

	sync.mutex_lock(&state.mutex)
	stopping := state.stopping
	sync.mutex_unlock(&state.mutex)
	if stopping {
		return "", host_error(.Closed, "the worker pool is stopping")
	}

	store_handle, store_err := pool_store(state.host)
	if store_err.kind != .None {
		return "", store_err
	}
	profile_id, profile_err := pool_profile_id(provider, model, thinking)
	if profile_err.kind != .None {
		return "", profile_err
	}
	defer delete(profile_id)

	// The id is derived from the tuple, so a lookup decides reuse: an existing
	// profile is never inserted twice.
	profile, found, get_err := store.get_profile(store_handle, profile_id)
	if get_err.kind != .None {
		return "", host_store_error(get_err)
	}
	if found {
		store.profile_destroy(&profile)
	} else if create_err := store.create_profile(store_handle, profile_id, provider, model, thinking, current_time_ms()); create_err.kind != .None {
		return "", host_store_error(create_err)
	}

	created_id, id_err := new_session_id()
	if id_err.kind != .None {
		return "", id_err
	}
	if create_err := store.create_work_item(store_handle, created_id, session_id, profile_id, request, current_time_ms(), 0, false); create_err.kind != .None {
		delete(created_id)
		return "", host_store_error(create_err)
	}

	sync.mutex_lock(&state.mutex)
	if state.stopping {
		sync.mutex_unlock(&state.mutex)
		delete(created_id)
		return "", host_error(.Closed, "the worker pool is stopping")
	}
	queued_id := strings.clone(created_id, state.allocator)
	if _, queue_err := queue.push_back(&state.pending_ids, queued_id); queue_err != nil {
		sync.mutex_unlock(&state.mutex)
		delete(queued_id)
		delete(created_id)
		return "", host_error(.Out_Of_Memory, "could not queue the work item")
	}
	sync.cond_signal(&state.work_available)
	sync.mutex_unlock(&state.mutex)
	return created_id, Host_Error{}
}

// pool_resume records the caller's reply for an item that paused through a
// Needs_Input event, moves it back to queued, and makes it runnable. The reply
// reaches the next Work_Fn call as Work_Item_Input.resumed_input.
pool_resume :: proc(pool: Pool, work_item_id, input: string) -> Host_Error {
	if pool == Pool(nil) {
		return host_error(.Closed, "the worker pool is not running")
	}
	state := cast(^Pool_State)pool
	store_handle, store_err := pool_store(state.host)
	if store_err.kind != .None {
		return store_err
	}
	if pool_is_stopping(state) {
		return host_error(.Closed, "the worker pool is stopping")
	}

	item, found, item_err := store.get_work_item(store_handle, work_item_id)
	if item_err.kind != .None {
		return host_store_error(item_err)
	}
	defer store.work_item_destroy(&item)
	if !found {
		return host_error(.Invalid_Argument, "the work item was not found")
	}
	if item.status != store.WORK_ITEM_NEEDS_INPUT {
		return host_error(.Invalid_Argument, "the work item is not waiting for input")
	}

	// The reply is durable before the item can run again.
	if reply_err := pool_retain_reply(state, store_handle, work_item_id, input); reply_err.kind != .None {
		return reply_err
	}
	if transition_err := store.transition_work_item(store_handle, work_item_id, store.WORK_ITEM_QUEUED, current_time_ms()); transition_err.kind != .None {
		pool_drop_resumed(state, work_item_id)
		return host_store_error(transition_err)
	}
	return pool_requeue_resumed(state, work_item_id)
}

// pool_retain_reply appends the caller's reply as an ordered work-item record
// and keeps a pool-owned copy for the resumed run.
@(private)
pool_retain_reply :: proc(state: ^Pool_State, store_handle: store.Store, work_item_id, input: string) -> Host_Error {
	payload, marshal_err := json.marshal(Pool_Input_Payload{input = input}, allocator = state.allocator)
	if marshal_err != nil {
		return host_error(.Internal, "could not encode the caller input")
	}
	defer delete(payload, state.allocator)
	if _, record_err := store.append_record(store_handle, work_item_id, POOL_INPUT_RECORD_KIND, string(payload), current_time_ms()); record_err.kind != .None {
		return host_store_error(record_err)
	}

	entry := Pool_Resume{
		work_item_id = strings.clone(work_item_id, state.allocator),
		input        = strings.clone(input, state.allocator),
	}
	sync.mutex_lock(&state.mutex)
	defer sync.mutex_unlock(&state.mutex)
	// Grow the list with the pool's allocator, not the caller's.
	context.allocator = state.allocator
	if _, append_err := append(&state.resumed, entry); append_err != nil {
		delete(entry.work_item_id, state.allocator)
		delete(entry.input, state.allocator)
		return host_error(.Out_Of_Memory, "could not retain the caller input")
	}
	return Host_Error{}
}

// pool_requeue_resumed returns a requeued item to the pending FIFO and wakes a
// worker. The resumed reply is already retained, so it is dropped when the
// pool cannot queue the item.
@(private)
pool_requeue_resumed :: proc(state: ^Pool_State, work_item_id: string) -> Host_Error {
	queued_id := strings.clone(work_item_id, state.allocator)
	sync.mutex_lock(&state.mutex)
	if state.stopping {
		sync.mutex_unlock(&state.mutex)
		delete(queued_id, state.allocator)
		pool_drop_resumed(state, work_item_id)
		return host_error(.Closed, "the worker pool is stopping")
	}
	if _, queue_err := queue.push_back(&state.pending_ids, queued_id); queue_err != nil {
		sync.mutex_unlock(&state.mutex)
		delete(queued_id, state.allocator)
		pool_drop_resumed(state, work_item_id)
		return host_error(.Out_Of_Memory, "could not queue the resumed work item")
	}
	sync.cond_signal(&state.work_available)
	sync.mutex_unlock(&state.mutex)
	return Host_Error{}
}

// pool_take_resumed_input removes and returns the caller's reply for one run.
// The caller owns the returned string.
@(private)
pool_take_resumed_input :: proc(state: ^Pool_State, work_item_id: string) -> string {
	sync.mutex_lock(&state.mutex)
	defer sync.mutex_unlock(&state.mutex)
	for entry, index in state.resumed {
		if entry.work_item_id == work_item_id {
			ordered_remove(&state.resumed, index)
			delete(entry.work_item_id, state.allocator)
			return entry.input
		}
	}
	return ""
}

@(private)
pool_drop_resumed :: proc(state: ^Pool_State, work_item_id: string) {
	sync.mutex_lock(&state.mutex)
	defer sync.mutex_unlock(&state.mutex)
	for entry, index in state.resumed {
		if entry.work_item_id == work_item_id {
			ordered_remove(&state.resumed, index)
			delete(entry.work_item_id, state.allocator)
			delete(entry.input, state.allocator)
			return
		}
	}
}

@(private)
pool_destroy_resumed :: proc(state: ^Pool_State) {
	for entry in state.resumed {
		delete(entry.work_item_id, state.allocator)
		delete(entry.input, state.allocator)
	}
	delete(state.resumed)
	state.resumed = nil
}

@(private)
pool_is_stopping :: proc(state: ^Pool_State) -> bool {
	sync.mutex_lock(&state.mutex)
	defer sync.mutex_unlock(&state.mutex)
	return state.stopping
}

// pool_wait_idle reports whether the pool has no queued or in-flight work
// within timeout_ms milliseconds. A non-positive timeout checks immediately.
pool_wait_idle :: proc(pool: Pool, timeout_ms: int) -> bool {
	if pool == Pool(nil) {
		return true
	}
	state := cast(^Pool_State)pool
	sync.mutex_lock(&state.mutex)
	defer sync.mutex_unlock(&state.mutex)

	timeout := time.Duration(timeout_ms) * time.Millisecond
	start := time.now()
	for !pool_is_idle(state) {
		elapsed := time.since(start)
		if elapsed >= timeout {
			return false
		}
		if !sync.cond_wait_with_timeout(&state.idle, &state.mutex, timeout-elapsed) {
			return pool_is_idle(state)
		}
	}
	return true
}

// pool_stop joins every worker and releases the pool. It is safe on an already
// stopped pool. With cancel_pending, queued work items are cancelled; running
// items finish their current Work_Fn call. Worker errors are reported here
// because a worker thread cannot return them to a caller.
pool_stop :: proc(pool: ^Pool, cancel_pending: bool) -> Host_Error {
	if pool == nil || pool^ == Pool(nil) {
		return Host_Error{}
	}
	state := cast(^Pool_State)pool^
	store_handle, store_err := pool_store(state.host)
	defer host_error_destroy(&store_err)

	sync.mutex_lock(&state.mutex)
	state.stopping = true
	cancel_error: Host_Error
	for queue.len(state.pending_ids) > 0 {
		work_item_id := queue.pop_front(&state.pending_ids)
		if cancel_pending && store_err.kind == .None {
			transition_err := store.transition_work_item(store_handle, work_item_id, store.WORK_ITEM_CANCELLED, current_time_ms())
			if transition_err.kind != .None {
				#partial switch transition_err.kind {
				case .Invalid_State, .Not_Found:
					// A session close already cancelled or removed the item.
					store.store_error_destroy(&transition_err)
				case:
					if cancel_error.kind == .None {
						cancel_error = host_store_error(transition_err)
					} else {
						store.store_error_destroy(&transition_err)
					}
				}
			}
		}
		delete(work_item_id, state.allocator)
	}
	sync.cond_broadcast(&state.work_available)
	sync.mutex_unlock(&state.mutex)

	for worker in state.threads {
		thread.destroy(worker)
	}
	delete(state.threads)
	queue.destroy(&state.pending_ids)
	pool_destroy_resumed(state)

	result := cancel_error
	if state.has_error {
		if result.kind == .None {
			result = state.first_error
		} else {
			host_error_destroy(&state.first_error)
		}
	}
	free(state, state.allocator)
	pool^ = Pool(nil)
	return result
}

// pool_destroy stops the pool with queued work cancelled. Callers that need
// pool_stop's error should call pool_stop directly.
pool_destroy :: proc(pool: ^Pool) {
	if pool == nil {
		return
	}
	stop_err := pool_stop(pool, true)
	host_error_destroy(&stop_err)
}

@(private)
pool_worker :: proc(worker: ^thread.Thread) {
	state := cast(^Pool_State)worker.data
	// Adopt the pool allocator so worker allocations match the frees that the
	// pool owner performs when it joins the worker.
	context.allocator = state.allocator
	for {
		sync.mutex_lock(&state.mutex)
		for queue.len(state.pending_ids) == 0 && !state.stopping {
			sync.cond_wait(&state.work_available, &state.mutex)
		}
		if state.stopping {
			sync.mutex_unlock(&state.mutex)
			return
		}
		work_item_id := queue.pop_front(&state.pending_ids)
		state.pending += 1
		sync.mutex_unlock(&state.mutex)

		pool_run_work_item(state, work_item_id)
		delete(work_item_id)

		sync.mutex_lock(&state.mutex)
		state.pending -= 1
		sync.cond_broadcast(&state.idle)
		sync.mutex_unlock(&state.mutex)
	}
}

// pool_run_work_item runs one dequeued item and persists its outcome. It
// re-reads the item first: a session close may have cancelled it while it
// waited in the queue, in which case it is skipped without running.
@(private)
pool_run_work_item :: proc(state: ^Pool_State, work_item_id: string) {
	store_handle := (cast(^Host_State)state.host).store
	item, found, item_err := store.get_work_item(store_handle, work_item_id)
	if item_err.kind != .None {
		pool_record_error(state, host_store_error(item_err))
		return
	}
	if !found {
		return
	}
	defer store.work_item_destroy(&item)
	// A paused item is never run by the queue; pool_resume requeues it once the
	// caller replies. A cancelled item is likewise skipped.
	if item.status != store.WORK_ITEM_QUEUED {
		return
	}

	profile, profile_found, profile_err := store.get_profile(store_handle, item.profile_id)
	if profile_err.kind != .None {
		pool_record_error(state, host_store_error(profile_err))
		return
	}
	if !profile_found {
		pool_record_error(state, host_error(.Internal, "the work item references a missing provider profile"))
		return
	}
	defer store.profile_destroy(&profile)

	run_err := store.transition_work_item(store_handle, work_item_id, store.WORK_ITEM_RUNNING, current_time_ms())
	if run_err.kind != .None {
		#partial switch run_err.kind {
		case .Invalid_State, .Not_Found:
			// A session close won the race; the item must not run.
			store.store_error_destroy(&run_err)
		case:
			pool_record_error(state, host_store_error(run_err))
		}
		return
	}

	// A resumed item carries the caller's reply into this run.
	resumed_input := pool_take_resumed_input(state, work_item_id)
	defer delete(resumed_input, state.allocator)

	event_emit(state.events, Agent_Event{
		kind = .Progress,
		session_id = item.session_id,
		work_item_id = work_item_id,
	})

	result := state.work(Work_Item_Input{
		work_item_id = item.work_item_id,
		session_id = item.session_id,
		profile_id = item.profile_id,
		provider = profile.provider,
		model = profile.model,
		thinking = profile.thinking,
		request = item.request,
		resumed_input = resumed_input,
	})

	// A needs_input result pauses the item instead of finishing it; the worker
	// returns to the queue rather than waiting for the caller.
	final_status := result.ok ? store.WORK_ITEM_COMPLETED : store.WORK_ITEM_FAILED
	if result.needs_input {
		final_status = store.WORK_ITEM_NEEDS_INPUT
	}
	current, current_found, current_err := store.get_work_item(store_handle, work_item_id)
	if current_err.kind != .None {
		pool_record_error(state, host_store_error(current_err))
		return
	}
	if current_found {
		// A close requested while the call ran ends the item cancelled, even
		// when the call asked to pause.
		if current.has_cancel_requested_at {
			final_status = store.WORK_ITEM_CANCELLED
		}
		store.work_item_destroy(&current)
	}
	if finish_err := store.transition_work_item(store_handle, work_item_id, final_status, current_time_ms()); finish_err.kind != .None {
		pool_record_error(state, host_store_error(finish_err))
		return
	}
	if final_status == store.WORK_ITEM_NEEDS_INPUT {
		event_emit(state.events, Agent_Event{
			kind = .Needs_Input,
			session_id = item.session_id,
			work_item_id = work_item_id,
			message = result.output,
		})
	} else if final_status == store.WORK_ITEM_COMPLETED {
		event_emit(state.events, Agent_Event{
			kind = .Final_Result,
			session_id = item.session_id,
			work_item_id = work_item_id,
			message = result.output,
		})
	}
}

@(private)
pool_record_error :: proc(state: ^Pool_State, err: Host_Error) {
	sync.mutex_lock(&state.mutex)
	if !state.has_error {
		state.first_error = err
		state.has_error = true
	} else {
		discarded := err
		host_error_destroy(&discarded)
	}
	sync.mutex_unlock(&state.mutex)
}

@(private)
pool_is_idle :: proc(state: ^Pool_State) -> bool {
	return queue.len(state.pending_ids) == 0 && state.pending == 0
}

// pool_abort_start releases a pool whose worker threads could not all start.
@(private)
pool_abort_start :: proc(state: ^Pool_State) {
	sync.mutex_lock(&state.mutex)
	state.stopping = true
	sync.cond_broadcast(&state.work_available)
	sync.mutex_unlock(&state.mutex)
	for worker in state.threads {
		thread.destroy(worker)
	}
	delete(state.threads)
	queue.destroy(&state.pending_ids)
	pool_destroy_resumed(state)
	free(state, state.allocator)
}

// pool_profile_id derives a stable, injective profile id from the tuple so
// identical settings always resolve to one row. Length prefixes keep distinct
// tuples from colliding when a value contains the separator byte.
@(private)
pool_profile_id :: proc(provider, model, thinking: string) -> (string, Host_Error) {
	profile_id := fmt.aprintf("%d:%s%d:%s%d:%s", len(provider), provider, len(model), model, len(thinking), thinking)
	if len(profile_id) == 0 {
		return "", host_error(.Out_Of_Memory, "could not allocate a provider profile id")
	}
	return profile_id, Host_Error{}
}

@(private)
pool_store :: proc(host: Host) -> (store.Store, Host_Error) {
	state, err := host_state(host)
	if err.kind != .None {
		return store.Store(nil), err
	}
	return state.store, Host_Error{}
}
