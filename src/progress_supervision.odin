package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

// Host-level progress supervision: tracks active Stations and surfaces needs_input
// and stale-warning events. The relay thread checks this ledger on each iteration.

// Global ledger, protected by a mutex since the relay thread and main input thread
// both access it (relay reads for stale checks, dispatch writes on station_started).
progress_ledger_global: Progress_Ledger
progress_ledger_mutex: sync.Mutex

// Initialize the progress ledger and rebuild it from saved history.
progress_supervision_init :: proc(host_history_dir: string) -> bool {
	progress_ledger_global = progress_ledger_new()
	return progress_supervision_rebuild_from_history(host_history_dir)
}

// Rebuild the ledger from the host history at startup. For each request_id with
// a history file, replay all station_report events to reconstruct the final state
// of each Station.
progress_supervision_rebuild_from_history :: proc(host_history_dir: string) -> bool {
	if host_history_dir == "" {
		return true // No history available; start with empty ledger.
	}

	entries, read_err := os.read_all_directory_by_path(host_history_dir, context.temp_allocator)
	if read_err != nil {
		return true // No history directory; start empty.
	}

	for entry in entries {
		if entry.type != .Directory {
			continue
		}
		request_id := entry.name
		if !valid_shot_id(request_id) {
			continue
		}

		history_path := fmt.tprintf("%s/%s/history.ndjson", host_history_dir, request_id)
		data, read_err := os.read_entire_file(history_path, context.temp_allocator)
		if read_err != nil {
			continue
		}

		// Replay all lines. We only care about session_started (to add Station and record pane_id)
		// and station_report (to track phase, report kind, and terminal status).
		remaining := string(data)
		for line in strings.split_lines_iterator(&remaining) {
			trimmed := strings.trim_space(line)
			if trimmed == "" {
				continue
			}
			event: Host_Event
			if json.unmarshal_string(trimmed, &event, .JSON, context.temp_allocator) != nil {
				continue
			}

			switch event.type {
			case "session_started":
				if valid_shot_id(event.shot_id) && event.pane_id != "" {
					sync.mutex_lock(&progress_ledger_mutex)
					progress_ledger_add_station(&progress_ledger_global, request_id, event.shot_id, event.pane_id)
					progress_ledger_update(&progress_ledger_global, request_id, event.shot_id, "running")
					sync.mutex_unlock(&progress_ledger_mutex)
				}
			case "station_report":
				if valid_shot_id(event.shot_id) && event.kind != "" {
					sync.mutex_lock(&progress_ledger_mutex)
					progress_ledger_report(&progress_ledger_global, request_id, event.shot_id, event.kind)
					sync.mutex_unlock(&progress_ledger_mutex)
				}
			}
		}
	}
	return true
}

// Record a dispatched Station in the ledger.
progress_supervision_add_station :: proc(request_id, shot_id, pane_id: string) {
	sync.mutex_lock(&progress_ledger_mutex)
	defer sync.mutex_unlock(&progress_ledger_mutex)
	progress_ledger_add_station(&progress_ledger_global, request_id, shot_id, pane_id)
}

// Update a Station's phase (used when transitioning to "running", "needs_input", etc.).
progress_supervision_update_phase :: proc(request_id, shot_id, phase: string) {
	sync.mutex_lock(&progress_ledger_mutex)
	defer sync.mutex_unlock(&progress_ledger_mutex)
	progress_ledger_update(&progress_ledger_global, request_id, shot_id, phase)
}

// Record a station_report event. This updates last_progress time and may mark
// the Station terminal.
progress_supervision_record_report :: proc(request_id, shot_id, report_kind: string) {
	sync.mutex_lock(&progress_ledger_mutex)
	defer sync.mutex_unlock(&progress_ledger_mutex)
	progress_ledger_report(&progress_ledger_global, request_id, shot_id, report_kind)
}

// Check all active Stations for staleness and needs_input, emitting Host_Events
// for any new conditions. Called from the relay thread on each iteration.
// Returns the number of events emitted (for testing).
progress_supervision_check_and_emit :: proc() -> int {
	emitted := 0

	sync.mutex_lock(&progress_ledger_mutex)
	progress_ledger_set_now(&progress_ledger_global, time.now())
	pending := progress_ledger_pending(progress_ledger_global)
	sync.mutex_unlock(&progress_ledger_mutex)

	for station in pending {
		// Check for staleness.
		sync.mutex_lock(&progress_ledger_mutex)
		is_stale := progress_ledger_check_stale(&progress_ledger_global, station.request_id, station.shot_id)
		sync.mutex_unlock(&progress_ledger_mutex)
		if is_stale {
			elapsed_min := int(10) // Exactly 10 min = stale threshold
			host_emit(Host_Event{
				type = "stale_warning",
				request_id = station.request_id,
				shot_id = station.shot_id,
				reason = fmt.tprintf("%d minutes without progress", elapsed_min),
			})
			emitted += 1
		}

		// Check for needs_input.
		sync.mutex_lock(&progress_ledger_mutex)
		needs_reply := progress_ledger_needs_input(&progress_ledger_global, station.request_id, station.shot_id)
		sync.mutex_unlock(&progress_ledger_mutex)
		if needs_reply {
			host_emit(Host_Event{
				type = "needs_input_alert",
				request_id = station.request_id,
				shot_id = station.shot_id,
				pane_id = station.pane_id,
			})
			emitted += 1
		}
	}

	return emitted
}

// Get a snapshot of all pending Stations for the coordinator.
progress_supervision_pending :: proc(allocator := context.temp_allocator) -> [dynamic]Progress_Station {
	sync.mutex_lock(&progress_ledger_mutex)
	defer sync.mutex_unlock(&progress_ledger_mutex)
	return progress_ledger_pending(progress_ledger_global, allocator)
}

// Cleanup the progress supervision system (for testing).
progress_supervision_cleanup :: proc() {
	sync.mutex_lock(&progress_ledger_mutex)
	defer sync.mutex_unlock(&progress_ledger_mutex)
	progress_ledger_destroy(&progress_ledger_global)
}
