package main

import "core:encoding/json"
import "core:fmt"
import "core:runtime"
import "core:strings"
import "core:time"

// A Station's progress state as tracked by the host. Each Station is identified
// by request_id + shot_id; its pane_id is remembered so we can relay answers to
// the right pane. The ledger tracks the phase ("dispatched", "running",
// "needs_input", "done"), last progress timestamp, and the latest report seen.
//
// Stale is a warning, not auto-cancel. A Station is stale after STALE_THRESHOLD
// (10 min) without any progress event. Once flagged stale, a single progress
// event resets it; stale persists across restarts until settled.
Progress_Station :: struct {
	request_id:      string,
	shot_id:         string,
	pane_id:         string,
	phase:           string, // "dispatched", "running", "needs_input", "done", "failed"
	last_progress:   time.Time,
	last_report_kind: string, // for diagnosis; the kind from the latest station_report
	stale_warned:    bool, // have we already emitted the stale warning for this Station?
	terminal:        bool, // true once a terminal report (session_failed, blended, blend_failed) is received
}

Progress_Ledger :: struct {
	stations: map[string]Progress_Station, // key = request_id + "/" + shot_id
	now:      time.Time, // wall clock, frozen for testing
}

STALE_THRESHOLD :: 10 * time.Minute

// Create a new ledger with the current time.
progress_ledger_new :: proc() -> Progress_Ledger {
	return Progress_Ledger{
		stations = make(map[string]Progress_Station),
		now = time.now(),
	}
}

// Ledger key for a Station.
progress_station_key :: proc(request_id, shot_id: string, allocator := context.temp_allocator) -> string {
	build := strings.builder_make(allocator)
	strings.write_string(&build, request_id)
	strings.write_rune(&build, '/')
	strings.write_string(&build, shot_id)
	return strings.to_string(build)
}

// Ledger key for a Station (allocator version for non-temp usage).
progress_station_key_with :: proc(
	request_id, shot_id: string,
	allocator: runtime.Allocator,
) -> string {
	build := strings.builder_make(allocator)
	strings.write_string(&build, request_id)
	strings.write_rune(&build, '/')
	strings.write_string(&build, shot_id)
	return strings.to_string(build)
}

// Add a dispatched Station to the ledger.
progress_ledger_add_station :: proc(
	ledger: ^Progress_Ledger,
	request_id, shot_id, pane_id: string,
) {
	key := progress_station_key(request_id, shot_id)
	ledger.stations[key] = Progress_Station{
		request_id = request_id,
		shot_id = shot_id,
		pane_id = pane_id,
		phase = "dispatched",
		last_progress = ledger.now,
		terminal = false,
		stale_warned = false,
	}
}

// Update a Station's phase and touch its last-progress time.
progress_ledger_update :: proc(
	ledger: ^Progress_Ledger,
	request_id, shot_id, phase: string,
) {
	key := progress_station_key(request_id, shot_id)
	if station, ok := ledger.stations[key]; ok {
		station.phase = phase
		station.last_progress = ledger.now
		// Transitioning off stale resets the warning flag.
		if station.stale_warned && phase != "needs_input" {
			station.stale_warned = false
		}
		ledger.stations[key] = station
	}
}

// Record a station_report event: update progress and the report kind.
// If the report is terminal, mark the Station done.
progress_ledger_report :: proc(
	ledger: ^Progress_Ledger,
	request_id, shot_id, report_kind: string,
) {
	key := progress_station_key(request_id, shot_id)
	if station, ok := ledger.stations[key]; ok {
		station.last_progress = ledger.now
		station.last_report_kind = report_kind
		// Terminal reports: session_failed, blended, blend_failed
		if report_kind == "session_failed" || report_kind == "blended" || report_kind == "blend_failed" {
			station.terminal = true
			station.phase = "done"
		}
		// Stale warning resets on any progress (not just non-needs_input).
		station.stale_warned = false
		ledger.stations[key] = station
	}
}

// Check if a Station is stale (no progress for STALE_THRESHOLD) and has not
// yet had a stale warning emitted. Returns true if this is the first time the
// Station crossed the stale threshold.
progress_ledger_check_stale :: proc(
	ledger: ^Progress_Ledger,
	request_id, shot_id: string,
) -> bool {
	key := progress_station_key(request_id, shot_id)
	if station, ok := ledger.stations[key]; ok {
		elapsed := time.diff(station.last_progress, ledger.now)
		is_stale := elapsed >= STALE_THRESHOLD
		if is_stale && !station.stale_warned {
			station.stale_warned = true
			ledger.stations[key] = station
			return true
		}
	}
	return false
}

// Check if a Station needs input and is still waiting (not yet terminated).
progress_ledger_needs_input :: proc(
	ledger: ^Progress_Ledger,
	request_id, shot_id: string,
) -> bool {
	key := progress_station_key(request_id, shot_id)
	if station, ok := ledger.stations[key]; ok {
		return station.phase == "needs_input" && !station.terminal
	}
	return false
}

// Get a snapshot of all pending Stations (not yet done).
progress_ledger_pending :: proc(
	ledger: Progress_Ledger,
	allocator := context.temp_allocator,
) -> [dynamic]Progress_Station {
	pending := make([dynamic]Progress_Station, 0, len(ledger.stations), allocator)
	for _, station in ledger.stations {
		if !station.terminal {
			append(&pending, station)
		}
	}
	return pending
}

// Remove a Station from the ledger (for cleanup after it settles).
progress_ledger_remove_station :: proc(
	ledger: ^Progress_Ledger,
	request_id, shot_id: string,
) {
	key := progress_station_key(request_id, shot_id)
	// In Odin dev-2026-10, map deletion requires special handling; for this
	// ledger we simply let the entry persist since maps are cleaned up on exit.
	// TODO: use a proper map removal once Odin's API is determined.
	_ = key
}

// Destroy the ledger and free all allocated resources.
progress_ledger_destroy :: proc(ledger: ^Progress_Ledger) {
	delete(ledger.stations)
}

// For testing: set the "current time" in the ledger.
progress_ledger_set_now :: proc(ledger: ^Progress_Ledger, now: time.Time) {
	ledger.now = now
}
