package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Test fixture: create a temporary directory with history files.
test_create_history :: proc(
	allocator := context.temp_allocator,
) -> (history_dir: string, cleanup_err: string) {
	temp_dir, temp_err := os.temp_directory(allocator)
	if temp_err != nil {
		return "", "could not get temp directory"
	}
	history_dir, _ = filepath.join({temp_dir, "test-history"}, allocator)
	if os.make_directory_all(history_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return "", "could not create history dir"
	}
	return history_dir, ""
}

// Test fixture: write a mock history file for a request.
test_write_history :: proc(history_dir, request_id: string, events: []string) -> string {
	request_dir, _ := filepath.join({history_dir, request_id}, context.temp_allocator)
	if os.make_directory_all(request_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return "could not create request dir"
	}
	history_file := fmt.tprintf("%s/%s", request_dir, "history.ndjson")

	// Build content manually to avoid string concatenation.
	build := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(events); i += 1 {
		if i > 0 {
			strings.write_rune(&build, '\n')
		}
		strings.write_string(&build, events[i])
	}
	if len(events) > 0 {
		strings.write_rune(&build, '\n')
	}
	content := strings.to_string(build)

	if os.write_entire_file(history_file, transmute([]u8)content) != nil {
		return "could not write history"
	}
	return ""
}

@test
test_progress_supervision_rebuild_empty :: proc(t: ^testing.T) {
	// The ledger is process-global and the runner uses ten threads.
	host_pool_test_lock()
	defer host_pool_test_unlock()

	// Empty history should result in an empty ledger.
	history_dir, err := test_create_history()
	testing.expect(t, err == "", fmt.tprintf("setup failed: %s", err))

	defer os.remove_all(history_dir)
	defer progress_supervision_cleanup()

	ok := progress_supervision_init(history_dir)
	testing.expect(t, ok, "init should succeed")

	pending := progress_supervision_pending()
	testing.expect(t, len(pending) == 0, "pending should be empty")
}

@test
test_progress_supervision_rebuild_with_sessions :: proc(t: ^testing.T) {
	// The ledger is process-global and the runner uses ten threads.
	host_pool_test_lock()
	defer host_pool_test_unlock()

	// History with session_started and station_report events should rebuild the ledger.
	history_dir, err := test_create_history()
	testing.expect(t, err == "", fmt.tprintf("setup failed: %s", err))
	defer os.remove_all(history_dir)
	defer progress_supervision_cleanup()

	events := [?]string{
		`{"type":"dispatch_accepted","request_id":"req1"}`,
		`{"type":"session_started","request_id":"req1","shot_id":"shot-a","pane_id":"pane-1"}`,
		`{"type":"station_report","request_id":"req1","shot_id":"shot-a","kind":"tool_call"}`,
		`{"type":"session_started","request_id":"req1","shot_id":"shot-b","pane_id":"pane-2"}`,
	}
	err_write := test_write_history(history_dir, "req1", events[:])
	testing.expect(t, err_write == "", fmt.tprintf("write history failed: %s", err_write))

	ok := progress_supervision_init(history_dir)
	testing.expect(t, ok, "init should succeed")

	pending := progress_supervision_pending()
	testing.expect(t, len(pending) == 2, "pending should have 2 Stations")

	// Verify Station states.
	found_a := false
	found_b := false
	for station in pending {
		if station.shot_id == "shot-a" {
			found_a = true
			testing.expect(t, station.phase == "running", "shot-a should be running after report")
			testing.expect(t, station.pane_id == "pane-1", "shot-a pane should match")
		}
		if station.shot_id == "shot-b" {
			found_b = true
			testing.expect(t, station.phase == "running", "shot-b should be running")
		}
	}
	testing.expect(t, found_a, "shot-a should be in pending")
	testing.expect(t, found_b, "shot-b should be in pending")
}

@test
test_progress_supervision_rebuild_with_terminal :: proc(t: ^testing.T) {
	// The ledger is process-global and the runner uses ten threads.
	host_pool_test_lock()
	defer host_pool_test_unlock()

	// Terminal reports should not appear in pending list after rebuild.
	history_dir, err := test_create_history()
	testing.expect(t, err == "", fmt.tprintf("setup failed: %s", err))
	defer os.remove_all(history_dir)
	defer progress_supervision_cleanup()

	events := [?]string{
		`{"type":"session_started","request_id":"req1","shot_id":"shot-a","pane_id":"pane-1"}`,
		`{"type":"session_started","request_id":"req1","shot_id":"shot-b","pane_id":"pane-2"}`,
		`{"type":"station_report","request_id":"req1","shot_id":"shot-a","kind":"session_failed"}`,
	}
	err_write := test_write_history(history_dir, "req1", events[:])
	testing.expect(t, err_write == "", fmt.tprintf("write history failed: %s", err_write))

	ok := progress_supervision_init(history_dir)
	testing.expect(t, ok, "init should succeed")

	pending := progress_supervision_pending()
	testing.expect(t, len(pending) == 1, "pending should have only shot-b (shot-a is terminal)")

	for station in pending {
		testing.expect(
			t,
			station.shot_id == "shot-b",
			fmt.tprintf("expected shot-b, got %s", station.shot_id),
		)
	}
}

@test
test_progress_supervision_record_and_check :: proc(t: ^testing.T) {
	// The ledger is process-global and the runner uses ten threads.
	host_pool_test_lock()
	defer host_pool_test_unlock()

	defer progress_supervision_cleanup()
	// Manual add, update, and check for stale/needs_input.
	progress_supervision_init("")

	progress_supervision_add_station("req1", "shot-a", "pane-1")
	progress_supervision_update_phase("req1", "shot-a", "running")

	pending := progress_supervision_pending()
	testing.expect(t, len(pending) == 1, "pending should have 1 Station")

	station := pending[0]
	testing.expect(t, station.phase == "running", "phase should be running")
	testing.expect(t, station.pane_id == "pane-1", "pane_id should match")
}

@test
test_progress_supervision_stale_detection :: proc(t: ^testing.T) {
	// The ledger is process-global and the runner uses ten threads.
	host_pool_test_lock()
	defer host_pool_test_unlock()

	defer progress_supervision_cleanup()
	// Stale detection when adding a Station and then advancing time.
	progress_supervision_init("")

	progress_supervision_add_station("req1", "shot-a", "pane-1")
	progress_supervision_update_phase("req1", "shot-a", "running")

	// Manually advance time in the ledger to trigger stale.
	sync.mutex_lock(&progress_ledger_mutex)
	now := progress_ledger_global.now
	later := time.time_add(now, 10*time.Minute + 1*time.Second)
	progress_ledger_set_now(&progress_ledger_global, later)

	// Directly check stale (can't use check_and_emit because it overwrites time with time.now()).
	is_stale := progress_ledger_check_stale(&progress_ledger_global, "req1", "shot-a")
	sync.mutex_unlock(&progress_ledger_mutex)

	testing.expect(t, is_stale, "should detect stale after 10+ min")
}

@test
test_progress_supervision_needs_input_alert :: proc(t: ^testing.T) {
	// The ledger is process-global and the runner uses ten threads.
	host_pool_test_lock()
	defer host_pool_test_unlock()

	defer progress_supervision_cleanup()
	// needs_input should trigger an alert event.
	progress_supervision_init("")

	progress_supervision_add_station("req1", "shot-a", "pane-1")
	progress_supervision_update_phase("req1", "shot-a", "needs_input")

	emitted := progress_supervision_check_and_emit()
	testing.expect(t, emitted >= 1, fmt.tprintf("should emit at least 1 event (needs_input alert), got %d", emitted))
}

@test
test_progress_supervision_terminal_no_alert :: proc(t: ^testing.T) {
	// The ledger is process-global and the runner uses ten threads.
	host_pool_test_lock()
	defer host_pool_test_unlock()

	defer progress_supervision_cleanup()
	// Terminal reports should not trigger any alerts.
	progress_supervision_init("")

	progress_supervision_add_station("req1", "shot-a", "pane-1")
	progress_supervision_update_phase("req1", "shot-a", "needs_input")
	progress_supervision_record_report("req1", "shot-a", "session_failed")

	// Terminal Station should not appear in pending.
	pending := progress_supervision_pending()
	testing.expect(t, len(pending) == 0, "terminal Station should not be pending")

	// No events should be emitted.
	emitted := progress_supervision_check_and_emit()
	testing.expect(t, emitted == 0, fmt.tprintf("no events should be emitted for terminal Station, got %d", emitted))
}
