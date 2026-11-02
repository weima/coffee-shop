package main

import "core:fmt"
import "core:log"
import "core:strings"

SCALE :: 5 // Host concurrency limit shared by the activity and request listeners.
import "core:time"

// Dispatch queue for Shots waiting for a free headless Station slot.

Queued_Shot :: struct {
	request_id:   string,
	shot_id:      string,
	created_at:   time.Time,
	// Full metadata for retry when a slot is released.
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
	session_id:   string,  // Set by dequeue: the slot this Shot now holds
}

// Global dispatch queue.
host_dispatch_queue: [dynamic]Queued_Shot
host_dispatch_queue_lock: bool // Simple spin-lock for now; real code uses sync primitives

// Initialize the headless slot budget and queue at host startup.
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
	delete(shot.session_id)
}

host_dispatch_init :: proc() {
	root, root_err := default_state_root(context.temp_allocator)
	if root_err != "" {
		root = "" // no state root: fall back to the per-host limit only
	}
	host_dispatch_init_at(root)
}

// Production uses the real state root (one limit for the whole machine); tests pass a private one.
host_dispatch_init_at :: proc(machine_root: string) {
	headless_slots_init(machine_root, SCALE)
	host_dispatch_queue = make([dynamic]Queued_Shot, 0, 100, context.allocator)
}

// Cleanup on host exit.
host_dispatch_cleanup :: proc() {
	for i := 0; i < len(host_sessions); {
		session := host_sessions[i]
		_ = headless_close(session.session_id)
		_ = headless_slot_release(session.session_id)
		delete(session.request_id)
		delete(session.shot_id)
		delete(session.session_id)
		unordered_remove(&host_sessions, i)
	}
	delete(host_sessions)
	host_sessions = nil

	for shot in host_dispatch_queue {
		host_dispatch_queued_shot_destroy(shot)
	}
	delete(host_dispatch_queue)
	host_dispatch_queue = nil
	headless_slots_destroy()
}

// Try to acquire a headless Station slot; queue the Shot when capacity is full.
// Returns (session_id, queued, ok).
host_dispatch_acquire :: proc(request_id, shot_id: string) -> (session_id: string, queued: bool, ok: bool) {
	slot_id, slot_ok := headless_slot_acquire(request_id, shot_id)
	if slot_ok {
		return slot_id, false, true
	}

	// No local or machine-wide slot. Queue with metadata added by the caller.
	refusal := headless_slots.last_refusal
	if refusal != "" {
		fmt.eprintfln("shot %s waiting: %s", shot_id, refusal)
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

// After a slot is released, take every queued Shot that now fits. Ownership of each
// returned Queued_Shot (its metadata and held session id) passes to the caller.
host_dispatch_dequeue_shots :: proc() -> [dynamic]Queued_Shot {
	result := make([dynamic]Queued_Shot, 0, 5, context.allocator)
	for len(host_dispatch_queue) > 0 {
		queued := host_dispatch_queue[0]
		session_id, ok := headless_slot_acquire(queued.request_id, queued.shot_id)
		if !ok {
			break // still no host or machine slot: leave it queued
		}
		queued.session_id = session_id
		append(&result, queued)
		ordered_remove(&host_dispatch_queue, 0)
		when ODIN_DEBUG {
			log.debugf("dequeued shot %s (request %s) into slot %s, queue depth %d", queued.shot_id, queued.request_id, session_id, len(host_dispatch_queue))
		}
	}
	return result
}

// Same, returning only (request_id, shot_id) pairs; the Shots are released.
host_dispatch_dequeue :: proc() -> [dynamic][2]string {
	result := make([dynamic][2]string, 0, 5, context.temp_allocator)
	shots := host_dispatch_dequeue_shots()
	defer delete(shots)
	for shot in shots {
		append(&result, [2]string{
			strings.clone(shot.request_id, context.temp_allocator),
			strings.clone(shot.shot_id, context.temp_allocator),
		})
		host_dispatch_queued_shot_destroy(shot)
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
