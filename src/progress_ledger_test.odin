package main

import "core:testing"
import "core:time"

@test
test_progress_ledger_add_and_track :: proc(t: ^testing.T) {
	ledger := progress_ledger_new()
	defer progress_ledger_destroy(&ledger)
	now := ledger.now

	// Add a Station.
	progress_ledger_add_station(&ledger, "req1", "shot-a", "pane-1")

	// Verify initial state.
	key := progress_station_key("req1", "shot-a")
	station, ok := ledger.stations[key]
	testing.expect(t, ok, "Station not added to ledger")
	testing.expect(t, station.phase == "dispatched", "Initial phase should be dispatched")
	testing.expect(t, station.last_progress == now, "Last progress should be initial time")
	testing.expect(t, station.terminal == false, "Should not be terminal")
	testing.expect(t, station.stale_warned == false, "Should not be stale-warned yet")
}

@test
test_progress_ledger_update_phase :: proc(t: ^testing.T) {
	ledger := progress_ledger_new()
	defer progress_ledger_destroy(&ledger)
	base := ledger.now

	progress_ledger_add_station(&ledger, "req1", "shot-a", "pane-1")

	// Advance time and update phase.
	later := time.time_add(base, 5*time.Minute)
	progress_ledger_set_now(&ledger, later)
	progress_ledger_update(&ledger, "req1", "shot-a", "running")

	key := progress_station_key("req1", "shot-a")
	station := ledger.stations[key]
	testing.expect(t, station.phase == "running", "Phase should be running")
	testing.expect(t, station.last_progress == later, "Last progress should be updated")
}

@test
test_progress_ledger_needs_input :: proc(t: ^testing.T) {
	ledger := progress_ledger_new()
	defer progress_ledger_destroy(&ledger)
	progress_ledger_add_station(&ledger, "req1", "shot-a", "pane-1")

	// Not needs_input yet.
	testing.expect(
		t,
		!progress_ledger_needs_input(&ledger, "req1", "shot-a"),
		"Should not be needs_input initially",
	)

	// Update to needs_input.
	progress_ledger_update(&ledger, "req1", "shot-a", "needs_input")
	testing.expect(
		t,
		progress_ledger_needs_input(&ledger, "req1", "shot-a"),
		"Should be needs_input after update",
	)

	// Once terminal, needs_input returns false.
	progress_ledger_report(&ledger, "req1", "shot-a", "session_failed")
	testing.expect(
		t,
		!progress_ledger_needs_input(&ledger, "req1", "shot-a"),
		"Should not be needs_input after terminal report",
	)
}

@test
test_progress_ledger_stale_warning :: proc(t: ^testing.T) {
	ledger := progress_ledger_new()
	defer progress_ledger_destroy(&ledger)
	base := ledger.now

	progress_ledger_add_station(&ledger, "req1", "shot-a", "pane-1")
	progress_ledger_update(&ledger, "req1", "shot-a", "running")

	// Not stale yet.
	testing.expect(
		t,
		!progress_ledger_check_stale(&ledger, "req1", "shot-a"),
		"Should not be stale at 0 min",
	)

	// Advance to 9 min 59 sec - still not stale.
	at_9_59 := time.time_add(base, 9*time.Minute + 59*time.Second)
	progress_ledger_set_now(&ledger, at_9_59)
	testing.expect(
		t,
		!progress_ledger_check_stale(&ledger, "req1", "shot-a"),
		"Should not be stale at 9:59",
	)

	// Advance to 10 min - stale!
	at_10_00 := time.time_add(base, 10*time.Minute)
	progress_ledger_set_now(&ledger, at_10_00)
	warned := progress_ledger_check_stale(&ledger, "req1", "shot-a")
	testing.expect(t, warned, "Should warn at 10 min threshold")

	// Check again at 11 min - already warned, so returns false.
	at_11_00 := time.time_add(base, 11*time.Minute)
	progress_ledger_set_now(&ledger, at_11_00)
	warned_again := progress_ledger_check_stale(&ledger, "req1", "shot-a")
	testing.expect(t, !warned_again, "Should not warn twice without progress")
}

@test
test_progress_ledger_stale_reset_on_progress :: proc(t: ^testing.T) {
	ledger := progress_ledger_new()
	defer progress_ledger_destroy(&ledger)
	base := ledger.now

	progress_ledger_add_station(&ledger, "req1", "shot-a", "pane-1")
	progress_ledger_update(&ledger, "req1", "shot-a", "running")

	// Advance past stale threshold.
	at_10_01 := time.time_add(base, 10*time.Minute + 1*time.Second)
	progress_ledger_set_now(&ledger, at_10_01)

	// Get the first stale warning.
	warned := progress_ledger_check_stale(&ledger, "req1", "shot-a")
	testing.expect(t, warned, "Should warn at 10 min")

	// Report progress (any report resets stale).
	progress_ledger_report(&ledger, "req1", "shot-a", "tool_call")

	// Check stale again - should return false because stale_warned was reset.
	warned_again := progress_ledger_check_stale(&ledger, "req1", "shot-a")
	testing.expect(t, !warned_again, "Stale should be reset after progress report")

	// But the Station is still at the same phase; advancing past stale again should warn.
	at_20_02 := time.time_add(base, 20*time.Minute + 2*time.Second)
	progress_ledger_set_now(&ledger, at_20_02)
	warned_again_later := progress_ledger_check_stale(&ledger, "req1", "shot-a")
	testing.expect(
		t,
		warned_again_later,
		"Should warn again if no new progress after reset threshold",
	)
}

@test
test_progress_ledger_terminal_reports :: proc(t: ^testing.T) {
	ledger := progress_ledger_new()
	defer progress_ledger_destroy(&ledger)
	progress_ledger_add_station(&ledger, "req1", "shot-a", "pane-1")

	// session_failed is terminal.
	progress_ledger_report(&ledger, "req1", "shot-a", "session_failed")
	key := progress_station_key("req1", "shot-a")
	station := ledger.stations[key]
	testing.expect(t, station.terminal == true, "session_failed should be terminal")
	testing.expect(t, station.phase == "done", "Phase should be done after terminal report")

	// Remove and test blended.
	progress_ledger_remove_station(&ledger, "req1", "shot-a")
	progress_ledger_add_station(&ledger, "req1", "shot-b", "pane-2")
	progress_ledger_report(&ledger, "req1", "shot-b", "blended")
	station_b := ledger.stations[progress_station_key("req1", "shot-b")]
	testing.expect(t, station_b.terminal == true, "blended should be terminal")

	// blend_failed is also terminal.
	progress_ledger_remove_station(&ledger, "req1", "shot-b")
	progress_ledger_add_station(&ledger, "req1", "shot-c", "pane-3")
	progress_ledger_report(&ledger, "req1", "shot-c", "blend_failed")
	station_c := ledger.stations[progress_station_key("req1", "shot-c")]
	testing.expect(t, station_c.terminal == true, "blend_failed should be terminal")
}

@test
test_progress_ledger_pending :: proc(t: ^testing.T) {
	ledger := progress_ledger_new()
	defer progress_ledger_destroy(&ledger)

	// Add three Stations.
	progress_ledger_add_station(&ledger, "req1", "shot-a", "pane-1")
	progress_ledger_add_station(&ledger, "req1", "shot-b", "pane-2")
	progress_ledger_add_station(&ledger, "req1", "shot-c", "pane-3")

	// All should be pending.
	pending := progress_ledger_pending(ledger)
	testing.expect(t, len(pending) == 3, "All should be pending")

	// Mark one terminal.
	progress_ledger_report(&ledger, "req1", "shot-b", "blended")
	pending = progress_ledger_pending(ledger)
	testing.expect(t, len(pending) == 2, "Should have 2 pending after one terminal")
}
