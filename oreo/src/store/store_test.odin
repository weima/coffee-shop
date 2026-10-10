package store

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_store_persists_metadata_and_ordered_records_across_reopen :: proc(t: ^testing.T) {
	directory, path := store_test_database(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
		delete(path)
	}

	store, open_err := open(path)
	defer store_error_destroy(&open_err)
	testing.expect_value(t, open_err.kind, Store_Error_Kind.None)

	now_ms := i64(1_800_000_000_000)
	error := create_session(store, "session-a", "Oreo store", now_ms)
	defer store_error_destroy(&error)
	testing.expect_value(t, error.kind, Store_Error_Kind.None)
	error = create_profile(store, "profile-a", "test-provider", "model-a", "off", now_ms)
	testing.expect_value(t, error.kind, Store_Error_Kind.None)
	error = create_work_item(store, "work-a", "session-a", "profile-a", "read the README", now_ms+2, 0, false)
	testing.expect_value(t, error.kind, Store_Error_Kind.None)
	recent_session, session_found, session_err := get_session(store, "session-a")
	defer session_destroy(&recent_session)
	defer store_error_destroy(&session_err)
	testing.expect(t, session_found)
	testing.expect_value(t, recent_session.updated_at_ms, now_ms+2)
	sequence, record_err := append_record(store, "work-a", "assistant_message", `{"text":"started"}`, now_ms+3)
	defer store_error_destroy(&record_err)
	testing.expect_value(t, record_err.kind, Store_Error_Kind.None)
	testing.expect_value(t, sequence, i64(1))
	sequence, record_err = append_record(store, "work-a", "final_result", `{"text":"done"}`, now_ms+4)
	testing.expect_value(t, record_err.kind, Store_Error_Kind.None)
	testing.expect_value(t, sequence, i64(2))
	_, invalid_record_err := append_record(store, "work-a", "assistant_message", "not JSON", now_ms+5)
	defer store_error_destroy(&invalid_record_err)
	testing.expect_value(t, invalid_record_err.kind, Store_Error_Kind.Invalid_Argument)

	sessions, sessions_err := find_sessions_by_title(store, "Oreo store", 10)
	defer sessions_destroy(sessions)
	defer store_error_destroy(&sessions_err)
	testing.expect_value(t, sessions_err.kind, Store_Error_Kind.None)
	testing.expect_value(t, len(sessions), 1)
	testing.expect_value(t, sessions[0].session_id, "session-a")
	testing.expect_value(t, sessions[0].status, SESSION_OPEN)
	testing.expect_value(t, sessions[0].updated_at_ms, now_ms+4)

	work_items, items_err := list_work_items_by_session(store, "session-a")
	defer work_items_destroy(work_items)
	defer store_error_destroy(&items_err)
	testing.expect_value(t, items_err.kind, Store_Error_Kind.None)
	testing.expect_value(t, len(work_items), 1)
	testing.expect_value(t, work_items[0].work_item_id, "work-a")
	testing.expect_value(t, work_items[0].profile_id, "profile-a")

	records, records_err := list_work_item_records(store, "work-a")
	defer records_destroy(records)
	defer store_error_destroy(&records_err)
	testing.expect_value(t, records_err.kind, Store_Error_Kind.None)
	testing.expect_value(t, len(records), 2)
	testing.expect_value(t, records[0].sequence_no, i64(1))
	testing.expect_value(t, records[0].kind, "assistant_message")
	testing.expect_value(t, records[1].sequence_no, i64(2))
	testing.expect_value(t, records[1].kind, "final_result")

	close_err := close(&store)
	defer store_error_destroy(&close_err)
	testing.expect_value(t, close_err.kind, Store_Error_Kind.None)
	store, open_err = open(path)
	testing.expect_value(t, open_err.kind, Store_Error_Kind.None)
	store_error_destroy(&open_err)
	profile, profile_found, profile_err := get_profile(store, "profile-a")
	defer profile_destroy(&profile)
	defer store_error_destroy(&profile_err)
	testing.expect(t, profile_found)
	testing.expect_value(t, profile.provider, "test-provider")
	testing.expect_value(t, profile.model, "model-a")
	work_item, found, get_err := get_work_item(store, "work-a")
	defer work_item_destroy(&work_item)
	defer store_error_destroy(&get_err)
	testing.expect(t, found)
	testing.expect_value(t, work_item.request, "read the README")
	testing.expect_value(t, work_item.status, WORK_ITEM_QUEUED)
	close_err = close(&store)
	testing.expect_value(t, close_err.kind, Store_Error_Kind.None)
}

@(test)
test_work_item_lifecycle_updates_are_guarded_and_durable :: proc(t: ^testing.T) {
	directory, path := store_test_database(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
		delete(path)
	}
	store, open_err := open(path)
	defer store_error_destroy(&open_err)
	testing.expect_value(t, open_err.kind, Store_Error_Kind.None)

	now_ms := i64(1_800_000_000_000)
	store_err := create_session(store, "session-a", "Lifecycle", now_ms)
	defer store_error_destroy(&store_err)
	testing.expect_value(t, store_err.kind, Store_Error_Kind.None)
	store_err = create_profile(store, "profile-a", "test-provider", "model-a", "off", now_ms)
	testing.expect_value(t, store_err.kind, Store_Error_Kind.None)
	store_err = create_work_item(store, "work-a", "session-a", "profile-a", "test", now_ms, 0, false)
	testing.expect_value(t, store_err.kind, Store_Error_Kind.None)

	store_err = transition_work_item(store, "work-a", WORK_ITEM_COMPLETED, now_ms+1)
	testing.expect_value(t, store_err.kind, Store_Error_Kind.Invalid_State)
	store_error_destroy(&store_err)
	for transition in ([]struct{status: string, at_ms: i64}{
		{WORK_ITEM_RUNNING, now_ms+2},
		{WORK_ITEM_NEEDS_INPUT, now_ms+3},
		{WORK_ITEM_QUEUED, now_ms+4},
		{WORK_ITEM_RUNNING, now_ms+5},
		{WORK_ITEM_COMPLETED, now_ms+6},
	}) {
		store_err = transition_work_item(store, "work-a", transition.status, transition.at_ms)
		testing.expect_value(t, store_err.kind, Store_Error_Kind.None)
		store_error_destroy(&store_err)
	}

	first_item, found, get_err := get_work_item(store, "work-a")
	defer work_item_destroy(&first_item)
	defer store_error_destroy(&get_err)
	testing.expect(t, found)
	testing.expect_value(t, first_item.status, WORK_ITEM_COMPLETED)
	testing.expect(t, first_item.has_started_at && first_item.started_at_ms == now_ms+2)
	testing.expect(t, first_item.has_finished_at && first_item.finished_at_ms == now_ms+6)

	close_err := close(&store)
	defer store_error_destroy(&close_err)
	testing.expect_value(t, close_err.kind, Store_Error_Kind.None)
	store, open_err = open(path)
	testing.expect_value(t, open_err.kind, Store_Error_Kind.None)
	store_error_destroy(&open_err)
	second_item, second_found, second_get_err := get_work_item(store, "work-a")
	defer work_item_destroy(&second_item)
	defer store_error_destroy(&second_get_err)
	testing.expect(t, second_found)
	testing.expect_value(t, second_item.status, WORK_ITEM_COMPLETED)
	close_err = close(&store)
	testing.expect_value(t, close_err.kind, Store_Error_Kind.None)
}

@(test)
test_session_close_cancels_queued_and_waits_for_active_work :: proc(t: ^testing.T) {
	directory, path := store_test_database(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
		delete(path)
	}
	store, open_err := open(path)
	defer store_error_destroy(&open_err)
	testing.expect_value(t, open_err.kind, Store_Error_Kind.None)

	now_ms := i64(1_800_000_000_000)
	store_err := create_session(store, "session-close", "Closing", now_ms)
	defer store_error_destroy(&store_err)
	testing.expect_value(t, store_err.kind, Store_Error_Kind.None)
	store_err = create_profile(store, "profile-close", "test-provider", "model-a", "off", now_ms)
	testing.expect_value(t, store_err.kind, Store_Error_Kind.None)
	store_err = create_work_item(store, "queued-work", "session-close", "profile-close", "queued", now_ms, 0, false)
	testing.expect_value(t, store_err.kind, Store_Error_Kind.None)
	store_err = create_work_item(store, "active-work", "session-close", "profile-close", "active", now_ms, 0, false)
	testing.expect_value(t, store_err.kind, Store_Error_Kind.None)
	store_err = transition_work_item(store, "active-work", WORK_ITEM_RUNNING, now_ms+1)
	testing.expect_value(t, store_err.kind, Store_Error_Kind.None)

	request, close_err := request_session_close(store, "session-close", now_ms+2)
	defer session_close_request_destroy(&request)
	defer store_error_destroy(&close_err)
	testing.expect_value(t, close_err.kind, Store_Error_Kind.None)
	testing.expect(t, !request.session_closed)
	testing.expect_value(t, len(request.active_work_item_ids), 1)
	testing.expect_value(t, request.active_work_item_ids[0], "active-work")

	queued, queued_found, queued_err := get_work_item(store, "queued-work")
	defer work_item_destroy(&queued)
	defer store_error_destroy(&queued_err)
	testing.expect(t, queued_found)
	testing.expect_value(t, queued.status, WORK_ITEM_CANCELLED)
	testing.expect(t, queued.has_finished_at)
	active, active_found, active_err := get_work_item(store, "active-work")
	defer work_item_destroy(&active)
	defer store_error_destroy(&active_err)
	testing.expect(t, active_found)
	testing.expect_value(t, active.status, WORK_ITEM_RUNNING)
	testing.expect(t, active.has_cancel_requested_at)
	store_err = create_work_item(store, "late-work", "session-close", "profile-close", "late", now_ms+2, 0, false)
	testing.expect_value(t, store_err.kind, Store_Error_Kind.Invalid_State)
	store_error_destroy(&store_err)

	store_err = transition_work_item(store, "active-work", WORK_ITEM_CANCELLED, now_ms+3)
	testing.expect_value(t, store_err.kind, Store_Error_Kind.None)
	closing, closing_found, closing_err := get_session(store, "session-close")
	defer session_destroy(&closing)
	defer store_error_destroy(&closing_err)
	testing.expect(t, closing_found)
	testing.expect_value(t, closing.status, SESSION_CLOSED)
	testing.expect(t, closing.has_closed_at && closing.closed_at_ms == now_ms+3)
	store_err = create_session(store, "session-empty", "Empty close", now_ms+4)
	testing.expect_value(t, store_err.kind, Store_Error_Kind.None)
	store_error_destroy(&store_err)
	empty_request, empty_close_err := request_session_close(store, "session-empty", now_ms+5)
	defer session_close_request_destroy(&empty_request)
	defer store_error_destroy(&empty_close_err)
	testing.expect_value(t, empty_close_err.kind, Store_Error_Kind.None)
	testing.expect(t, empty_request.session_closed)
	testing.expect_value(t, len(empty_request.active_work_item_ids), 0)
	close_store_err := close(&store)
	defer store_error_destroy(&close_store_err)
	testing.expect_value(t, close_store_err.kind, Store_Error_Kind.None)
}

@(test)
test_store_enforces_profile_and_session_foreign_keys :: proc(t: ^testing.T) {
	directory, path := store_test_database(t)
	defer {
		_ = os.remove_all(directory)
		delete(directory)
		delete(path)
	}
	store, open_err := open(path)
	defer store_error_destroy(&open_err)
	testing.expect_value(t, open_err.kind, Store_Error_Kind.None)

	now_ms := i64(1_800_000_000_000)
	error := create_session(store, "session-a", "Foreign keys", now_ms)
	defer store_error_destroy(&error)
	testing.expect_value(t, error.kind, Store_Error_Kind.None)
	error = create_profile(store, "profile-a", "test-provider", "model-a", "off", now_ms)
	testing.expect_value(t, error.kind, Store_Error_Kind.None)

	error = create_work_item(store, "missing-profile", "session-a", "profile-missing", "request", now_ms, 0, false)
	testing.expect_value(t, error.kind, Store_Error_Kind.SQLite)
	store_error_destroy(&error)
	error = create_work_item(store, "missing-session", "session-missing", "profile-a", "request", now_ms, 0, false)
	testing.expect_value(t, error.kind, Store_Error_Kind.Not_Found)

	items, items_err := list_work_items_by_session(store, "session-a")
	defer work_items_destroy(items)
	defer store_error_destroy(&items_err)
	testing.expect_value(t, items_err.kind, Store_Error_Kind.None)
	testing.expect_value(t, len(items), 0)
	close_err := close(&store)
	defer store_error_destroy(&close_err)
	testing.expect_value(t, close_err.kind, Store_Error_Kind.None)
}

store_test_database :: proc(t: ^testing.T) -> (directory, path: string) {
	err: os.Error
	directory, err = os.make_directory_temp("", "oreo-store-*", context.allocator)
	testing.expect_value(t, err, os.Error(nil))
	path, err = filepath.join({directory, "sessions.db"}, context.allocator)
	testing.expect(t, err == nil)
	return
}
