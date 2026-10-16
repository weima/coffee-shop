package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

// A pane pool manages a bounded set of Herdr panes for reuse across Shots.
// Panes are allocated on dispatch, held while a Station runs, and returned
// for reuse after a terminal report or confirmed process exit.
//
// Pool semantics:
// - Capacity equals the concurrency limit (5).
// - A pane is FREE, ALLOCATED, WAITING_FOR_HUMAN, or RECLAIMABLE.
// - Dispatch acquires a FREE pane or creates one if pool is below limit.
// - Terminal report or process gone → RECLAIMABLE.
// - Clear and re-assert terminal state before reuse.
// - WAITING_FOR_HUMAN panes are pinned and counted against capacity.
// - Close only host-owned panes on clean exit.

Pane_State :: enum {
	FREE,
	ALLOCATED,
	WAITING_FOR_HUMAN,
	RECLAIMABLE,
}

Pane :: struct {
	pane_id:    string,
	state:      Pane_State,
	request_id: string, // Current occupant (cleared on FREE)
	shot_id:    string, // Current occupant (cleared on FREE)
}

Pane_Pool :: struct {
	panes:                [dynamic]Pane,
	capacity:             int,
	workspace_id:         string,
	host_owned_pane_ids:  [dynamic]string,
}

// Initialize the pool with a given capacity.
pane_pool_init :: proc(capacity: int, workspace_id: string, allocator := context.allocator) -> Pane_Pool {
	when ODIN_DEBUG {
		assert(capacity > 0, "pane pool capacity must be > 0")
		assert(workspace_id != "", "workspace_id must not be empty")
	}
	return {
		panes = make([dynamic]Pane, 0, capacity, allocator),
		capacity = capacity,
		workspace_id = workspace_id,
		host_owned_pane_ids = make([dynamic]string, 0, capacity, allocator),
	}
}

// Destroy the pool and release all resources.
pane_pool_destroy :: proc(pool: ^Pane_Pool) {
	for pane in pool.panes {
		delete(pane.pane_id)
		delete(pane.request_id)
		delete(pane.shot_id)
	}
	delete(pool.panes)
	for id in pool.host_owned_pane_ids {
		delete(id)
	}
	delete(pool.host_owned_pane_ids)
	pool^ = {}
}

// Count how many panes are currently in use (ALLOCATED, WAITING_FOR_HUMAN).
pane_pool_in_use :: proc(pool: ^Pane_Pool) -> int {
	count := 0
	for i in 0..<len(pool.panes) {
		if pool.panes[i].state == .ALLOCATED || pool.panes[i].state == .WAITING_FOR_HUMAN {
			count += 1
		}
	}
	return count
}

// Count how many panes are reclaimable.
pane_pool_reclaimable :: proc(pool: ^Pane_Pool) -> int {
	count := 0
	for i in 0..<len(pool.panes) {
		if pool.panes[i].state == .RECLAIMABLE {
			count += 1
		}
	}
	return count
}

// Find a pane by pane_id.
pane_pool_find :: proc(pool: ^Pane_Pool, pane_id: string) -> (int, bool) {
	for i in 0..<len(pool.panes) {
		if pool.panes[i].pane_id == pane_id {
			return i, true
		}
	}
	return -1, false
}

// Acquire a pane for dispatch: return a FREE pane or create one.
// Returns (pane_id, is_new, ok).
pane_pool_acquire :: proc(
	pool: ^Pane_Pool,
	request_id, shot_id: string,
) -> (pane_id: string, is_new: bool, ok: bool) {
	when ODIN_DEBUG {
		assert(request_id != "", "request_id must not be empty")
		assert(shot_id != "", "shot_id must not be empty")
	}

	// Try to find a FREE pane to reuse.
	for i in 0..<len(pool.panes) {
		if pool.panes[i].state == .FREE {
			pane_id = strings.clone(pool.panes[i].pane_id, context.allocator)
			pool.panes[i].state = .ALLOCATED
			pool.panes[i].request_id = strings.clone(request_id, context.allocator)
			pool.panes[i].shot_id = strings.clone(shot_id, context.allocator)
			return pane_id, false, true
		}
	}

	// If pool is below capacity, create a new pane.
	if len(pool.panes) < pool.capacity {
		new_pane_id := fmt.aprintf("p%d", len(pool.panes))
		pane := Pane{
			pane_id = new_pane_id,
			state = .ALLOCATED,
			request_id = strings.clone(request_id, context.allocator),
			shot_id = strings.clone(shot_id, context.allocator),
		}
		append(&pool.panes, pane)
		append(&pool.host_owned_pane_ids, strings.clone(new_pane_id, context.allocator))
		return strings.clone(new_pane_id, context.allocator), true, true
	}

	// Pool is at capacity, no pane available.
	return "", false, false
}

// Mark a pane as WAITING_FOR_HUMAN (pinned until reply or cancel).
pane_pool_pin :: proc(pool: ^Pane_Pool, pane_id: string) -> bool {
	idx, found := pane_pool_find(pool, pane_id)
	if !found {
		return false
	}
	if pool.panes[idx].state != .ALLOCATED {
		return false
	}
	pool.panes[idx].state = .WAITING_FOR_HUMAN
	return true
}

// Unpin a WAITING_FOR_HUMAN pane (reply or cancel).
pane_pool_unpin :: proc(pool: ^Pane_Pool, pane_id: string) -> bool {
	idx, found := pane_pool_find(pool, pane_id)
	if !found {
		return false
	}
	if pool.panes[idx].state != .WAITING_FOR_HUMAN {
		return false
	}
	pool.panes[idx].state = .RECLAIMABLE
	return true
}

// Mark a pane as RECLAIMABLE (terminal report or process gone).
pane_pool_mark_reclaimable :: proc(pool: ^Pane_Pool, pane_id: string) -> bool {
	idx, found := pane_pool_find(pool, pane_id)
	if !found {
		return false
	}
	if pool.panes[idx].state == .RECLAIMABLE {
		return true // Already reclaimable, idempotent.
	}
	if pool.panes[idx].state != .ALLOCATED && pool.panes[idx].state != .WAITING_FOR_HUMAN {
		return false // Invalid transition.
	}
	pool.panes[idx].state = .RECLAIMABLE
	return true
}

// Reclaim a RECLAIMABLE pane: clear it and mark FREE.
// Returns ok=false if the pane is not RECLAIMABLE.
pane_pool_reclaim :: proc(pool: ^Pane_Pool, pane_id: string) -> bool {
	idx, found := pane_pool_find(pool, pane_id)
	if !found {
		return false
	}
	if pool.panes[idx].state != .RECLAIMABLE {
		return false
	}

	// Clear the pane and re-assert terminal state.
	// This happens before reuse, so the next Station does not see leftover output.
	pool.panes[idx].state = .FREE
	delete(pool.panes[idx].request_id)
	pool.panes[idx].request_id = ""
	delete(pool.panes[idx].shot_id)
	pool.panes[idx].shot_id = ""

	return true
}

// Close all host-owned panes on clean host exit.
pane_pool_close_all :: proc(pool: ^Pane_Pool, herdr_exe: string) -> int {
	when ODIN_DEBUG {
		log.debug("closing all host-owned panes")
	}
	exit_code := 0
	for i in 0..<len(pool.host_owned_pane_ids) {
		pane_id := pool.host_owned_pane_ids[i]
		// Use Herdr to close the pane.
		cmd := []string{herdr_exe, "pane", "close", pool.workspace_id, pane_id}
		result, stdout, stderr, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
		defer delete(stdout)
		defer delete(stderr)
		if err != nil || !result.success {
			when ODIN_DEBUG {
				log.warnf("failed to close pane %s: %v, %s", pane_id, err, string(stderr))
			}
			exit_code = 1
		}
	}
	return exit_code
}

// For persistence: return a list of host-owned pane IDs.
pane_pool_owned_ids :: proc(pool: ^Pane_Pool, allocator := context.allocator) -> [dynamic]string {
	result := make([dynamic]string, 0, len(pool.host_owned_pane_ids), allocator)
	for i in 0..<len(pool.host_owned_pane_ids) {
		append(&result, strings.clone(pool.host_owned_pane_ids[i], allocator))
	}
	return result
}
