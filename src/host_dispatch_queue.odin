package main

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

// Dispatch queue for Shots waiting for a free pane.
// When pool is at capacity, new Shots queue here until a pane reclaims.

Queued_Shot :: struct {
	request_id:   string,
	shot_id:      string,
	created_at:   time.Time,
	// Full metadata for retry when pane reclaims.
	repo:         string,
	prompt:       string,
	model:        string,
	provider:     string,
	thinking:     string,
	kind:         string,
	runtime:      string,
	taste:        string,
	message:      string,
	station_path: string,  // Worktree path (already created when queued)
}

// Global dispatch queue.
host_dispatch_queue: [dynamic]Queued_Shot
host_dispatch_queue_lock: bool // Simple spin-lock for now; real code uses sync primitives

// Initialize the dispatch pool and queue at host startup.
host_dispatch_queued_shot_destroy :: proc(shot: Queued_Shot) {
	delete(shot.request_id)
	delete(shot.shot_id)
	delete(shot.repo)
	delete(shot.prompt)
	delete(shot.model)
	delete(shot.provider)
	delete(shot.thinking)
	delete(shot.kind)
	delete(shot.runtime)
	delete(shot.taste)
	delete(shot.message)
	delete(shot.station_path)
}

host_dispatch_init :: proc(workspace_id: string) {
	root, root_err := default_state_root(context.temp_allocator)
	if root_err != "" {
		root = "" // no state root: fall back to the per-host limit only
	}
	host_dispatch_init_at(workspace_id, root)
}

// Same as host_dispatch_init with an explicit machine-limit root. Production uses the
// real state root (one limit for the whole machine); tests pass a private one.
host_dispatch_init_at :: proc(workspace_id, machine_root: string) {
	host_pane_pool_init(workspace_id, 5, machine_root) // Capacity = concurrency limit
	host_dispatch_queue = make([dynamic]Queued_Shot, 0, 100, context.allocator)
}

// Cleanup on host exit.
host_dispatch_cleanup :: proc(herdr_exe: string) -> int {
	// Close all host-owned panes.
	exit_code := host_pane_pool_close(herdr_exe)

	// Clear queue (in case of early exit).
	for shot in host_dispatch_queue {
		host_dispatch_queued_shot_destroy(shot)
	}
	delete(host_dispatch_queue)
	host_dispatch_queue = nil
	pane_pool_destroy(&host_pane_pool)

	return exit_code
}

// Try to acquire a pane for a Shot. If pool is at capacity, queue the Shot with full metadata for retry.
// Returns (pane_id, queued, ok).
// - ok=true, queued=false: pane acquired, ready to launch
// - ok=true, queued=true: Shot queued, will retry when pane frees
// - ok=false: fatal error
host_dispatch_acquire :: proc(request_id, shot_id: string) -> (pane_id: string, queued: bool, ok: bool) {
	// Try to acquire from pool.
	acquired_pane_id, pool_ok := host_pane_acquire(request_id, shot_id)
	if pool_ok {
		return acquired_pane_id, false, true
	}

	// Pool at capacity. Say why, then queue the Shot (minimal metadata for now).
	if host_pane_pool.last_refusal != "" {
		fmt.eprintfln("shot %s waiting: %s", shot_id, host_pane_pool.last_refusal)
	}
	// Full metadata is stored at call site when queued=true.
	queued_shot := Queued_Shot{
		request_id = strings.clone(request_id, context.allocator),
		shot_id = strings.clone(shot_id, context.allocator),
		created_at = time.now(),
	}
	append(&host_dispatch_queue, queued_shot)
	when ODIN_DEBUG {
		log.debugf("queued shot %s (request %s), queue depth %d", shot_id, request_id, len(host_dispatch_queue))
	}
	return "", true, true
}

// Store full metadata for a queued Shot (called immediately after dispatch_acquire returns queued=true).
host_dispatch_queue_store_metadata :: proc(request_id, shot_id, repo, prompt, model, provider, thinking, kind, runtime, taste, message, station_path: string) {
	for i in 0..<len(host_dispatch_queue) {
		if host_dispatch_queue[i].request_id == request_id && host_dispatch_queue[i].shot_id == shot_id {
			host_dispatch_queue[i].repo = strings.clone(repo, context.allocator)
			host_dispatch_queue[i].prompt = strings.clone(prompt, context.allocator)
			host_dispatch_queue[i].model = strings.clone(model, context.allocator)
			host_dispatch_queue[i].provider = strings.clone(provider, context.allocator)
			host_dispatch_queue[i].thinking = strings.clone(thinking, context.allocator)
			host_dispatch_queue[i].kind = strings.clone(kind, context.allocator)
			host_dispatch_queue[i].runtime = strings.clone(runtime, context.allocator)
			host_dispatch_queue[i].taste = strings.clone(taste, context.allocator)
			host_dispatch_queue[i].message = strings.clone(message, context.allocator)
			host_dispatch_queue[i].station_path = strings.clone(station_path, context.allocator)
			break
		}
	}
}

// After a pane is reclaimed, try to launch queued Shots.
// This is called whenever a terminal report arrives or a process exits.
// Returns a list of (request_id, shot_id) pairs that were dequeued and can launch.
host_dispatch_dequeue :: proc() -> [dynamic][2]string {
	result := make([dynamic][2]string, 0, 5, context.temp_allocator)

	for i := 0; i < len(host_dispatch_queue); {
		queued := host_dispatch_queue[i]

		// Try to acquire a pane for this queued Shot.
		pane_id, ok := host_pane_acquire(queued.request_id, queued.shot_id)
		if !ok {
			// Still no pane available. Leave it queued and stop.
			break
		}

		// Acquired! Return allocator-owned identifiers before releasing the queue entry.
		append(&result, [2]string{
			strings.clone(queued.request_id, context.temp_allocator),
			strings.clone(queued.shot_id, context.temp_allocator),
		})
		delete(pane_id)
		host_dispatch_queued_shot_destroy(queued)
		unordered_remove(&host_dispatch_queue, i)

		when ODIN_DEBUG {
			log.debugf("dequeued shot %s (request %s) for pane %s, queue depth %d", queued.shot_id, queued.request_id, pane_id, len(host_dispatch_queue))
		}
	}

	return result
}

// Query the queue state for status reporting.
host_dispatch_queue_status :: proc() -> (queued_count: int, oldest_age: time.Duration) {
	queued_count = len(host_dispatch_queue)
	if queued_count > 0 {
		oldest := host_dispatch_queue[0].created_at
		oldest_age = time.since(oldest)
	}
	return queued_count, oldest_age
}

// Cancel all Shots from a request in the queue (if they haven't started yet).
host_dispatch_dequeue_by_request :: proc(request_id: string) -> int {
	count := 0
	for i := 0; i < len(host_dispatch_queue); {
		if host_dispatch_queue[i].request_id == request_id {
			host_dispatch_queued_shot_destroy(host_dispatch_queue[i])
			unordered_remove(&host_dispatch_queue, i)
			count += 1
		} else {
			i += 1
		}
	}
	return count
}
