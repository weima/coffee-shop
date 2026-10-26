package main

import "core:fmt"
import "core:log"
import "core:strings"

// Integration between the pane pool and host dispatch/report handling.
// Manages acquisition, reuse, and reclamation of panes through the Station lifecycle.

// Global pool, initialized when the host starts and cleaned up on exit.
host_pane_pool: Pane_Pool

// Initialize the pool for a workspace. Called once per host startup.
// A non-empty machine_root joins the machine-wide limit under that state root.
host_pane_pool_init :: proc(workspace_id: string, capacity: int = 5, machine_root: string = "") {
	host_pane_pool = pane_pool_init(capacity, workspace_id, context.allocator)
	host_pane_pool.machine_root = strings.clone(machine_root, context.allocator)
}

// Destroy the pool and close all host-owned panes. Called on host exit.
host_pane_pool_close :: proc(herdr_exe: string) -> int {
	return pane_pool_close_all(&host_pane_pool, session_surface_open(herdr_exe))
}

// Acquire a pane for a dispatch. If no FREE pane exists and pool is at capacity,
// returns empty pane_id and ok=false. Otherwise returns a pane (new or reused).
host_pane_acquire :: proc(request_id, shot_id: string) -> (pane_id: string, ok: bool) {
	pane_id, _, ok = pane_pool_acquire(&host_pane_pool, request_id, shot_id)
	if ok && pane_id != "" {
		when ODIN_DEBUG {
			log.debugf("acquired pane %s for shot %s (request %s)", pane_id, shot_id, request_id)
		}
	}
	return pane_id, ok
}

// Mark a pane as needing human input (pinned).
host_pane_pin :: proc(pane_id: string) -> bool {
	ok := pane_pool_pin(&host_pane_pool, pane_id)
	when ODIN_DEBUG {
		if ok {
			log.debugf("pinned pane %s (needs input)", pane_id)
		}
	}
	return ok
}

// Unpin a pane after human input (reply or cancel).
host_pane_unpin :: proc(pane_id: string) -> bool {
	ok := pane_pool_unpin(&host_pane_pool, pane_id)
	when ODIN_DEBUG {
		if ok {
			log.debugf("unpinned pane %s (input received/cancelled)", pane_id)
		}
	}
	return ok
}

// Record a pane as having a terminal report or process exit. Marks it RECLAIMABLE.
// Called when a station_report with kind in {pulled, taste_failed, incomplete, session_failed}
// arrives, or when the process is confirmed gone.
host_pane_mark_terminal :: proc(pane_id: string) -> bool {
	ok := pane_pool_mark_reclaimable(&host_pane_pool, pane_id)
	when ODIN_DEBUG {
		if ok {
			log.debugf("marked pane %s as reclaimable (terminal report/process gone)", pane_id)
		}
	}
	return ok
}

// Reclaim a pane: clear it and mark FREE for reuse.
// The pane must be RECLAIMABLE. This should be called before the next dispatch
// that will reuse this pane.
host_pane_reclaim :: proc(pane_id: string) -> bool {
	ok := pane_pool_reclaim(&host_pane_pool, pane_id)
	when ODIN_DEBUG {
		if ok {
			log.debugf("reclaimed pane %s (cleared and marked free)", pane_id)
		}
	}
	return ok
}

// Returns how many panes are currently in use (ALLOCATED or WAITING_FOR_HUMAN).
host_pane_in_use_count :: proc() -> int {
	return pane_pool_in_use(&host_pane_pool)
}

// Returns how many panes are available for reuse.
host_pane_available_count :: proc() -> int {
	free := 0
	for i in 0..<len(host_pane_pool.panes) {
		if host_pane_pool.panes[i].state == .FREE {
			free += 1
		}
	}
	return free
}

// Clear a pane before reuse and re-assert terminal state.
// This should be called just before running the next command in a reused pane.
// For now this is a placeholder; the actual implementation will use Herdr's
// pane clear command and emit the terminal reset sequences.
host_pane_clear :: proc(workspace_id, pane_id: string) -> bool {
	// TODO: implement clear via Herdr or direct terminal commands
	// For now, assume the pool reclaim already handled logical state.
	when ODIN_DEBUG {
		log.debugf("cleared pane %s in workspace %s", pane_id, workspace_id)
	}
	return true
}

// For crash recovery: get a list of host-owned pane IDs that should be closed
// on recovery start to clean up orphaned panes.
host_pane_owned_ids :: proc() -> [dynamic]string {
	return pane_pool_owned_ids(&host_pane_pool, context.allocator)
}

// Log the current pool state for debugging.
host_pane_pool_status :: proc() -> string {
	in_use := pane_pool_in_use(&host_pane_pool)
	reclaimable := pane_pool_reclaimable(&host_pane_pool)
	free_count := host_pane_available_count()
	capacity := host_pane_pool.capacity
	total := len(host_pane_pool.panes)
	return fmt.aprintf(
		"pool: capacity %d, total panes %d, in-use %d, reclaimable %d, free %d",
		capacity,
		total,
		in_use,
		reclaimable,
		free_count,
	)
}
