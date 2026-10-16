package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Deterministic host integration test: dispatch Shots, record events, verify needs_input
// and stale warnings are emitted through the real host event stream.


@test
test_host_integration_dispatch_tracking :: proc(t: ^testing.T) {
	defer progress_supervision_cleanup()
	// Initialize progress ledger.
	progress_supervision_init("")

	// Simulate dispatch of a Shot.
	progress_supervision_add_station("test-req-1", "shot-a", "pane-1")
	progress_supervision_update_phase("test-req-1", "shot-a", "running")

	// Verify Station is tracked.
	pending := progress_supervision_pending()
	testing.expect(t, len(pending) == 1, "after dispatch, 1 Station should be pending")

	// Simulate a station_report event (e.g., progress update, not phase change).
	progress_supervision_record_report("test-req-1", "shot-a", "tool_call")

	// Verify phase is still running and report kind is updated.
	pending = progress_supervision_pending()
	if len(pending) > 0 {
		station := pending[0]
		testing.expect(t, station.phase == "running", "phase should be running")
		testing.expect(
			t,
			station.last_report_kind == "tool_call",
			fmt.tprintf("after report, kind should be 'tool_call', got %s", station.last_report_kind),
		)
	}
}

@test
test_host_integration_needs_input_event :: proc(t: ^testing.T) {
	defer progress_supervision_cleanup()
	// Initialize and dispatch.
	progress_supervision_init("")
	progress_supervision_add_station("test-req-1", "shot-a", "pane-1")
	progress_supervision_update_phase("test-req-1", "shot-a", "needs_input")

	// Check for needs_input alert event.
	emitted := progress_supervision_check_and_emit()
	testing.expect(
		t,
		emitted >= 1,
		fmt.tprintf("needs_input should emit at least 1 event, got %d", emitted),
	)
}

@test
test_host_integration_stale_event :: proc(t: ^testing.T) {
	defer progress_supervision_cleanup()
	// Initialize, dispatch, and update phase.
	progress_supervision_init("")
	progress_supervision_add_station("test-req-1", "shot-a", "pane-1")
	progress_supervision_update_phase("test-req-1", "shot-a", "running")

	// Manually advance the ledger time to trigger stale (this simulates 10+ min passing).
	sync.mutex_lock(&progress_ledger_mutex)
	now := progress_ledger_global.now
	stale_time := time.time_add(now, 10*time.Minute + 1*time.Second)
	progress_ledger_set_now(&progress_ledger_global, stale_time)

	// Directly check if it's stale (can't use check_and_emit because it will overwrite with time.now()).
	is_stale := progress_ledger_check_stale(&progress_ledger_global, "test-req-1", "shot-a")
	sync.mutex_unlock(&progress_ledger_mutex)

	// Verify stale check works with frozen time.
	testing.expect(
		t,
		is_stale,
		"Should be stale after 10+ min",
	)
}

@test
test_host_integration_restart_rebuild :: proc(t: ^testing.T) {
	defer progress_supervision_cleanup()
	// Create a temp history directory with a saved session state.
	temp_dir, temp_err := os.temp_directory(context.temp_allocator)
	if temp_err != nil {
		testing.expect(t, false, "could not get temp directory")
		return
	}

	history_dir, _ := filepath.join({temp_dir, "test-restart-history"}, context.temp_allocator)
	if os.make_directory_all(history_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		testing.expect(t, false, "could not create history directory")
		return
	}
	defer os.remove_all(history_dir)

	// Write a pre-saved history: dispatch + session_started events.
	request_dir, _ := filepath.join({history_dir, "test-req-1"}, context.temp_allocator)
	if os.make_directory_all(request_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		testing.expect(t, false, "could not create request directory")
		return
	}
	history_file, _ := filepath.join({request_dir, "history.ndjson"}, context.temp_allocator)

	// Build history content.
	build := strings.builder_make(context.temp_allocator)
	strings.write_string(&build, `{"type":"dispatch_accepted","request_id":"test-req-1"}`)
	strings.write_rune(&build, '\n')
	strings.write_string(&build, `{"type":"session_started","request_id":"test-req-1","shot_id":"shot-a","pane_id":"pane-1"}`)
	strings.write_rune(&build, '\n')
	history_content := strings.to_string(build)

	if os.write_entire_file(history_file, transmute([]u8)history_content) != nil {
		testing.expect(t, false, "could not write history file")
		return
	}

	// Simulate host restart: rebuild ledger from history.
	ok := progress_supervision_init(history_dir)
	testing.expect(t, ok, "init should succeed")

	// Verify that the dispatched Station is in the ledger.
	pending := progress_supervision_pending()
	testing.expect(t, len(pending) == 1, fmt.tprintf("after rebuild, 1 Station should be pending, got %d", len(pending)))

	if len(pending) > 0 {
		station := pending[0]
		testing.expect(t, station.request_id == "test-req-1", "request_id should match")
		testing.expect(t, station.shot_id == "shot-a", "shot_id should match")
		testing.expect(t, station.pane_id == "pane-1", "pane_id should match")
	}
}

@test
test_host_integration_terminal_settlement :: proc(t: ^testing.T) {
	defer progress_supervision_cleanup()
	// Dispatch, run, then receive a terminal report.
	progress_supervision_init("")
	progress_supervision_add_station("test-req-1", "shot-a", "pane-1")
	progress_supervision_update_phase("test-req-1", "shot-a", "running")

	// Verify it's pending before terminal.
	pending := progress_supervision_pending()
	testing.expect(t, len(pending) == 1, "before terminal, 1 should be pending")

	// Record terminal report.
	progress_supervision_record_report("test-req-1", "shot-a", "session_failed")

	// Verify it's no longer pending.
	pending = progress_supervision_pending()
	testing.expect(t, len(pending) == 0, "after terminal, 0 should be pending")

	// No events should be emitted for settled Stations.
	emitted := progress_supervision_check_and_emit()
	testing.expect(t, emitted == 0, fmt.tprintf("terminal Station should emit 0 events, got %d", emitted))
}
