package store

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"
import sqlite "oreo:sqlite"

SCHEMA_VERSION :: 1
SCHEMA_V1 :: #load("schema.sql", string)

@(private)
Schema_Migration :: struct {
	version: i64,
	sql: string,
}

@(private)
SCHEMA_MIGRATIONS :: [1]Schema_Migration{{version = 1, sql = SCHEMA_V1}}

SESSION_OPEN :: "open"
SESSION_CLOSING :: "closing"
SESSION_CLOSED :: "closed"

WORK_ITEM_QUEUED :: "queued"
WORK_ITEM_RUNNING :: "running"
WORK_ITEM_NEEDS_INPUT :: "needs_input"
WORK_ITEM_COMPLETED :: "completed"
WORK_ITEM_FAILED :: "failed"
WORK_ITEM_CANCELLED :: "cancelled"
WORK_ITEM_INTERRUPTED :: "interrupted"
WORK_ITEM_EXPIRED :: "expired"

Store_Error_Kind :: enum {
	None,
	SQLite,
	Invalid_Argument,
	Invalid_State,
	Not_Found,
	Unsupported_Schema,
	Corrupt_Data,
	Out_Of_Memory,
	Closed,
}

Store_Error :: struct {
	kind: Store_Error_Kind,
	sqlite_code: c.int,
	message: string,
}

Provider_Profile_Metadata :: struct {
	profile_id: string,
	provider: string,
	model: string,
	thinking: string,
	created_at_ms: i64,
}

Session_Metadata :: struct {
	session_id: string,
	title: string,
	status: string,
	created_at_ms: i64,
	updated_at_ms: i64,
	closed_at_ms: i64,
	has_closed_at: bool,
}

Work_Item_Metadata :: struct {
	work_item_id: string,
	session_id: string,
	profile_id: string,
	request: string,
	status: string,
	created_at_ms: i64,
	queued_at_ms: i64,
	started_at_ms: i64,
	has_started_at: bool,
	expires_at_ms: i64,
	has_expires_at: bool,
	cancel_requested_at_ms: i64,
	has_cancel_requested_at: bool,
	finished_at_ms: i64,
	has_finished_at: bool,
}

Work_Item_Record :: struct {
	sequence_no: i64,
	kind: string,
	payload_json: string,
	created_at_ms: i64,
}

Session_Close_Request :: struct {
	session_closed: bool,
	active_work_item_ids: [dynamic]string,
}

@(private)
Store_Bind_Text :: struct {
	index: int,
	value: string,
}

Store_State :: struct {
	database: sqlite.Database,
	mutex: sync.Mutex,
	allocator: runtime.Allocator,
}

// Store is an opaque handle to one synchronized SQLite connection.
Store :: distinct ^Store_State

open :: proc(path: string, allocator := context.allocator) -> (Store, Store_Error) {
	database, sqlite_err := sqlite.open_file(path, allocator)
	if sqlite_err.code != 0 {
		return Store(nil), store_sqlite_error(sqlite_err, allocator)
	}
	sqlite.error_destroy(&sqlite_err, allocator)

	foreign_keys_err := sqlite.execute(database, "PRAGMA foreign_keys = ON", allocator)
	if foreign_keys_err.code != 0 {
		store_err := store_sqlite_error(foreign_keys_err, allocator)
		close_store_database(&database, allocator)
		return Store(nil), store_err
	}
	sqlite.error_destroy(&foreign_keys_err, allocator)

	if err := install_schema(database, allocator); err.kind != .None {
		close_store_database(&database, allocator)
		return Store(nil), err
	}

	state, alloc_err := new(Store_State, allocator)
	if alloc_err != nil {
		close_store_database(&database, allocator)
		return Store(nil), store_error(.Out_Of_Memory, "could not allocate the session store", allocator)
	}
	state^ = Store_State{database = database, allocator = allocator}
	return Store(state), Store_Error{}
}

// close refuses to discard the handle if SQLite reports an active statement or transaction.
close :: proc(store: ^Store, allocator := context.allocator) -> Store_Error {
	if store == nil || store^ == Store(nil) {
		return Store_Error{}
	}
	state := cast(^Store_State)store^
	sync.mutex_lock(&state.mutex)
	close_err := sqlite.close(&state.database, allocator)
	if close_err.code != 0 {
		error := store_sqlite_error(close_err, allocator)
		sync.mutex_unlock(&state.mutex)
		return error
	}
	sqlite.error_destroy(&close_err, allocator)
	state_allocator := state.allocator
	sync.mutex_unlock(&state.mutex)
	_ = mem.free(state, state_allocator)
	store^ = Store(nil)
	return Store_Error{}
}

create_session :: proc(store: Store, session_id, title: string, created_at_ms: i64, allocator := context.allocator) -> Store_Error {
	if !valid_text_id(session_id) || created_at_ms < 0 {
		return store_error(.Invalid_Argument, "session id and non-negative creation time are required", allocator)
	}
	state, err := store_lock(store, allocator)
	if err.kind != .None {
		return err
	}
	defer sync.mutex_unlock(&state.mutex)

	statement, prepare_err := store_prepare(state.database, "INSERT INTO sessions(session_id,title,status,created_at_ms,updated_at_ms,closed_at_ms) VALUES(?1,?2,'open',?3,?3,NULL)", allocator)
	if prepare_err.kind != .None {
		return prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	for binding in ([]Store_Bind_Text{
		{index = 1, value = session_id},
		{index = 2, value = title},
	}) {
		if bind_err := store_bind_text(statement, binding.index, binding.value, allocator); bind_err.kind != .None {
			return bind_err
		}
	}
	if bind_err := store_bind_int64(statement, 3, created_at_ms, allocator); bind_err.kind != .None {
		return bind_err
	}
	result, step_err := store_step(statement, allocator)
	if step_err.kind != .None {
		return step_err
	}
	if result != .Done {
		return store_error(.Corrupt_Data, "session insert unexpectedly returned a row", allocator)
	}
	return Store_Error{}
}

create_profile :: proc(store: Store, profile_id, provider, model, thinking: string, created_at_ms: i64, allocator := context.allocator) -> Store_Error {
	for value in ([]string{profile_id, provider, model, thinking}) {
		if !valid_text_id(value) {
			return store_error(.Invalid_Argument, "profile id, provider, model, and thinking level must be non-empty and NUL-free", allocator)
		}
	}
	if created_at_ms < 0 {
		return store_error(.Invalid_Argument, "profile creation time must be non-negative", allocator)
	}
	state, err := store_lock(store, allocator)
	if err.kind != .None {
		return err
	}
	defer sync.mutex_unlock(&state.mutex)

	statement, prepare_err := store_prepare(state.database, "INSERT INTO provider_profiles(profile_id,provider,model,thinking,created_at_ms) VALUES(?1,?2,?3,?4,?5)", allocator)
	if prepare_err.kind != .None {
		return prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	for binding in ([]Store_Bind_Text{
		{index = 1, value = profile_id},
		{index = 2, value = provider},
		{index = 3, value = model},
		{index = 4, value = thinking},
	}) {
		if bind_err := store_bind_text(statement, binding.index, binding.value, allocator); bind_err.kind != .None {
			return bind_err
		}
	}
	if bind_err := store_bind_int64(statement, 5, created_at_ms, allocator); bind_err.kind != .None {
		return bind_err
	}
	result, step_err := store_step(statement, allocator)
	if step_err.kind != .None {
		return step_err
	}
	if result != .Done {
		return store_error(.Corrupt_Data, "profile insert unexpectedly returned a row", allocator)
	}
	return Store_Error{}
}

create_work_item :: proc(store: Store, work_item_id, session_id, profile_id, request: string, created_at_ms, expires_at_ms: i64, has_expiry: bool, allocator := context.allocator) -> Store_Error {
	for value in ([]string{work_item_id, session_id, profile_id}) {
		if !valid_text_id(value) {
			return store_error(.Invalid_Argument, "work-item, session, and profile ids must be non-empty and NUL-free", allocator)
		}
	}
	if len(request) == 0 || created_at_ms < 0 || (has_expiry && expires_at_ms < created_at_ms) {
		return store_error(.Invalid_Argument, "work-item request and valid timestamps are required", allocator)
	}
	state, err := store_lock(store, allocator)
	if err.kind != .None {
		return err
	}
	defer sync.mutex_unlock(&state.mutex)

	if txn_err := store_sqlite_error(sqlite.begin(state.database, allocator), allocator); txn_err.kind != .None {
		return txn_err
	}
	session_status, found, status_err := read_session_status(state.database, session_id, allocator)
	defer delete(session_status, allocator)
	if status_err.kind != .None {
		store_rollback(&state.database, allocator)
		return status_err
	}
	if !found {
		store_rollback(&state.database, allocator)
		return store_error(.Not_Found, "session was not found", allocator)
	}
	if session_status != SESSION_OPEN {
		store_rollback(&state.database, allocator)
		return store_error(.Invalid_State, "cannot add work to a session that is closing or closed", allocator)
	}
	if insert_err := insert_work_item(state.database, work_item_id, session_id, profile_id, request, created_at_ms, expires_at_ms, has_expiry, allocator); insert_err.kind != .None {
		store_rollback(&state.database, allocator)
		return insert_err
	}
	if update_err := update_session_time(state.database, session_id, created_at_ms, allocator); update_err.kind != .None {
		store_rollback(&state.database, allocator)
		return update_err
	}
	if commit_err := store_sqlite_error(sqlite.commit(state.database, allocator), allocator); commit_err.kind != .None {
		store_rollback(&state.database, allocator)
		return commit_err
	}
	return Store_Error{}
}

@(private)
insert_work_item :: proc(database: sqlite.Database, work_item_id, session_id, profile_id, request: string, created_at_ms, expires_at_ms: i64, has_expiry: bool, allocator: runtime.Allocator) -> Store_Error {
	statement, prepare_err := store_prepare(database, "INSERT INTO work_items(work_item_id,session_id,profile_id,request,status,created_at_ms,queued_at_ms,expires_at_ms) VALUES(?1,?2,?3,?4,'queued',?5,?5,?6)", allocator)
	if prepare_err.kind != .None {
		return prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	for binding in ([]Store_Bind_Text{
		{index = 1, value = work_item_id},
		{index = 2, value = session_id},
		{index = 3, value = profile_id},
		{index = 4, value = request},
	}) {
		if bind_err := store_bind_text(statement, binding.index, binding.value, allocator); bind_err.kind != .None {
			return bind_err
		}
	}
	if bind_err := store_bind_int64(statement, 5, created_at_ms, allocator); bind_err.kind != .None {
		return bind_err
	}
	if has_expiry {
		if bind_err := store_bind_int64(statement, 6, expires_at_ms, allocator); bind_err.kind != .None {
			return bind_err
		}
	} else if bind_err := store_bind_null(statement, 6, allocator); bind_err.kind != .None {
		return bind_err
	}
	result, step_err := store_step(statement, allocator)
	if step_err.kind != .None {
		return step_err
	}
	if result != .Done {
		return store_error(.Corrupt_Data, "work-item insert unexpectedly returned a row", allocator)
	}
	return Store_Error{}
}

@(private)
update_session_time :: proc(database: sqlite.Database, session_id: string, timestamp_ms: i64, allocator: runtime.Allocator) -> Store_Error {
	statement, prepare_err := store_prepare(database, "UPDATE sessions SET updated_at_ms = MAX(updated_at_ms, ?1) WHERE session_id = ?2", allocator)
	if prepare_err.kind != .None {
		return prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_int64(statement, 1, timestamp_ms, allocator); bind_err.kind != .None {
		return bind_err
	}
	if bind_err := store_bind_text(statement, 2, session_id, allocator); bind_err.kind != .None {
		return bind_err
	}
	result, step_err := store_step(statement, allocator)
	if step_err.kind != .None {
		return step_err
	}
	if result != .Done {
		return store_error(.Corrupt_Data, "session update unexpectedly returned a row", allocator)
	}
	return Store_Error{}
}

@(private)
update_session_time_for_work_item :: proc(database: sqlite.Database, work_item_id: string, timestamp_ms: i64, allocator: runtime.Allocator) -> Store_Error {
	statement, prepare_err := store_prepare(database, "UPDATE sessions SET updated_at_ms = MAX(updated_at_ms, ?1) WHERE session_id = (SELECT session_id FROM work_items WHERE work_item_id = ?2)", allocator)
	if prepare_err.kind != .None {
		return prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_int64(statement, 1, timestamp_ms, allocator); bind_err.kind != .None {
		return bind_err
	}
	if bind_err := store_bind_text(statement, 2, work_item_id, allocator); bind_err.kind != .None {
		return bind_err
	}
	result, step_err := store_step(statement, allocator)
	if step_err.kind != .None {
		return step_err
	}
	if result != .Done {
		return store_error(.Corrupt_Data, "session update unexpectedly returned a row", allocator)
	}
	return Store_Error{}
}

get_profile :: proc(store: Store, profile_id: string, allocator := context.allocator) -> (profile: Provider_Profile_Metadata, found: bool, err: Store_Error) {
	state, lock_err := store_lock(store, allocator)
	if lock_err.kind != .None {
		return {}, false, lock_err
	}
	defer sync.mutex_unlock(&state.mutex)

	statement, prepare_err := store_prepare(state.database, "SELECT profile_id,provider,model,thinking,created_at_ms FROM provider_profiles WHERE profile_id=?1", allocator)
	if prepare_err.kind != .None {
		return {}, false, prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_text(statement, 1, profile_id, allocator); bind_err.kind != .None {
		return {}, false, bind_err
	}
	result, step_err := store_step(statement, allocator)
	if step_err.kind != .None {
		return {}, false, step_err
	}
	if result == .Done {
		return {}, false, Store_Error{}
	}
	profile, err = read_profile(statement, allocator)
	if err.kind != .None {
		return {}, false, err
	}
	return profile, true, Store_Error{}
}

get_session :: proc(store: Store, session_id: string, allocator := context.allocator) -> (session: Session_Metadata, found: bool, err: Store_Error) {
	state, lock_err := store_lock(store, allocator)
	if lock_err.kind != .None {
		return {}, false, lock_err
	}
	defer sync.mutex_unlock(&state.mutex)

	statement, prepare_err := store_prepare(state.database, "SELECT session_id,title,status,created_at_ms,updated_at_ms,closed_at_ms FROM sessions WHERE session_id=?1", allocator)
	if prepare_err.kind != .None {
		return {}, false, prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_text(statement, 1, session_id, allocator); bind_err.kind != .None {
		return {}, false, bind_err
	}
	result, step_err := store_step(statement, allocator)
	if step_err.kind != .None {
		return {}, false, step_err
	}
	if result == .Done {
		return {}, false, Store_Error{}
	}
	session, err = read_session(statement, allocator)
	if err.kind != .None {
		return {}, false, err
	}
	return session, true, Store_Error{}
}

find_sessions_by_title :: proc(store: Store, title: string, limit: int, allocator := context.allocator) -> (sessions: [dynamic]Session_Metadata, err: Store_Error) {
	if limit <= 0 {
		return nil, store_error(.Invalid_Argument, "session query limit must be positive", allocator)
	}
	state, lock_err := store_lock(store, allocator)
	if lock_err.kind != .None {
		return nil, lock_err
	}
	defer sync.mutex_unlock(&state.mutex)

	alloc_err: runtime.Allocator_Error
	sessions, alloc_err = make([dynamic]Session_Metadata, 0, min(limit, 16), allocator)
	if alloc_err != nil {
		return nil, store_error(.Out_Of_Memory, "could not allocate session results", allocator)
	}
	results_transferred := false
	defer if !results_transferred { sessions_destroy(sessions, allocator) }
	statement, prepare_err := store_prepare(state.database, "SELECT session_id,title,status,created_at_ms,updated_at_ms,closed_at_ms FROM sessions WHERE title=?1 ORDER BY updated_at_ms DESC,session_id LIMIT ?2", allocator)
	if prepare_err.kind != .None {
		return nil, prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_text(statement, 1, title, allocator); bind_err.kind != .None {
		return nil, bind_err
	}
	if bind_err := store_bind_int64(statement, 2, i64(limit), allocator); bind_err.kind != .None {
		return nil, bind_err
	}
	for {
		result, step_err := store_step(statement, allocator)
		if step_err.kind != .None {
			return nil, step_err
		}
		if result == .Done {
			results_transferred = true
			return sessions, Store_Error{}
		}
		session, row_err := read_session(statement, allocator)
		if row_err.kind != .None {
			return nil, row_err
		}
		_, append_err := append(&sessions, session)
		if append_err != nil {
			session_destroy(&session, allocator)
			return nil, store_error(.Out_Of_Memory, "could not grow session results", allocator)
		}
	}
}

list_work_items_by_session :: proc(store: Store, session_id: string, allocator := context.allocator) -> (items: [dynamic]Work_Item_Metadata, err: Store_Error) {
	state, lock_err := store_lock(store, allocator)
	if lock_err.kind != .None {
		return nil, lock_err
	}
	defer sync.mutex_unlock(&state.mutex)

	alloc_err: runtime.Allocator_Error
	items, alloc_err = make([dynamic]Work_Item_Metadata, 0, 16, allocator)
	if alloc_err != nil {
		return nil, store_error(.Out_Of_Memory, "could not allocate work-item results", allocator)
	}
	results_transferred := false
	defer if !results_transferred { work_items_destroy(items, allocator) }
	statement, prepare_err := store_prepare(state.database, "SELECT work_item_id,session_id,profile_id,request,status,created_at_ms,queued_at_ms,started_at_ms,expires_at_ms,cancel_requested_at_ms,finished_at_ms FROM work_items WHERE session_id=?1 ORDER BY created_at_ms,work_item_id", allocator)
	if prepare_err.kind != .None {
		return nil, prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_text(statement, 1, session_id, allocator); bind_err.kind != .None {
		return nil, bind_err
	}
	for {
		result, step_err := store_step(statement, allocator)
		if step_err.kind != .None {
			return nil, step_err
		}
		if result == .Done {
			results_transferred = true
			return items, Store_Error{}
		}
		item, row_err := read_work_item(statement, allocator)
		if row_err.kind != .None {
			return nil, row_err
		}
		_, append_err := append(&items, item)
		if append_err != nil {
			work_item_destroy(&item, allocator)
			return nil, store_error(.Out_Of_Memory, "could not grow work-item results", allocator)
		}
	}
}

get_work_item :: proc(store: Store, work_item_id: string, allocator := context.allocator) -> (item: Work_Item_Metadata, found: bool, err: Store_Error) {
	state, lock_err := store_lock(store, allocator)
	if lock_err.kind != .None {
		return {}, false, lock_err
	}
	defer sync.mutex_unlock(&state.mutex)

	statement, prepare_err := store_prepare(state.database, "SELECT work_item_id,session_id,profile_id,request,status,created_at_ms,queued_at_ms,started_at_ms,expires_at_ms,cancel_requested_at_ms,finished_at_ms FROM work_items WHERE work_item_id=?1", allocator)
	if prepare_err.kind != .None {
		return {}, false, prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_text(statement, 1, work_item_id, allocator); bind_err.kind != .None {
		return {}, false, bind_err
	}
	result, step_err := store_step(statement, allocator)
	if step_err.kind != .None {
		return {}, false, step_err
	}
	if result == .Done {
		return {}, false, Store_Error{}
	}
	item, err = read_work_item(statement, allocator)
	if err.kind != .None {
		return {}, false, err
	}
	return item, true, Store_Error{}
}

// transition_work_item persists one legal state change and updates its parent session atomically.
transition_work_item :: proc(store: Store, work_item_id, to_status: string, at_ms: i64, allocator := context.allocator) -> Store_Error {
	if !valid_text_id(work_item_id) || at_ms < 0 || !valid_work_item_status(to_status) {
		return store_error(.Invalid_Argument, "work-item id, known status, and non-negative time are required", allocator)
	}
	state, lock_err := store_lock(store, allocator)
	if lock_err.kind != .None {
		return lock_err
	}
	defer sync.mutex_unlock(&state.mutex)
	if err := store_sqlite_error(sqlite.begin(state.database, allocator), allocator); err.kind != .None {
		return err
	}

	current_status, session_id, found, read_err := read_work_item_state(state.database, work_item_id, allocator)
	defer delete(current_status, allocator)
	if read_err.kind != .None {
		store_rollback(&state.database, allocator)
		return read_err
	}
	if !found {
		store_rollback(&state.database, allocator)
		return store_error(.Not_Found, "work item was not found", allocator)
	}
	defer delete(session_id, allocator)
	if !valid_work_item_transition(current_status, to_status) {
		store_rollback(&state.database, allocator)
		return store_error(.Invalid_State, "work-item state transition is not allowed", allocator)
	}
	statement, prepare_err := store_prepare(
		state.database,
		"UPDATE work_items SET status=?1, started_at_ms=CASE WHEN ?1='running' THEN COALESCE(started_at_ms,?2) ELSE started_at_ms END, queued_at_ms=CASE WHEN ?1='queued' THEN ?2 ELSE queued_at_ms END, finished_at_ms=CASE WHEN ?1 IN ('completed','failed','cancelled','interrupted','expired') THEN ?2 ELSE NULL END WHERE work_item_id=?3 AND status=?4",
		allocator,
	)
	if prepare_err.kind != .None {
		store_rollback(&state.database, allocator)
		return prepare_err
	}
	if err := store_bind_text(statement, 1, to_status, allocator); err.kind != .None {
		store_finalize_and_destroy(&statement, allocator)
		store_rollback(&state.database, allocator)
		return err
	}
	if err := store_bind_int64(statement, 2, at_ms, allocator); err.kind != .None {
		store_finalize_and_destroy(&statement, allocator)
		store_rollback(&state.database, allocator)
		return err
	}
	if err := store_bind_text(statement, 3, work_item_id, allocator); err.kind != .None {
		store_finalize_and_destroy(&statement, allocator)
		store_rollback(&state.database, allocator)
		return err
	}
	if err := store_bind_text(statement, 4, current_status, allocator); err.kind != .None {
		store_finalize_and_destroy(&statement, allocator)
		store_rollback(&state.database, allocator)
		return err
	}
	result, step_err := store_step(statement, allocator)
	finalize_err := store_finalize(&statement, allocator)
	if step_err.kind != .None {
		store_error_destroy(&finalize_err, allocator)
		store_rollback(&state.database, allocator)
		return step_err
	}
	if finalize_err.kind != .None {
		store_rollback(&state.database, allocator)
		return finalize_err
	}
	if result != .Done {
		store_rollback(&state.database, allocator)
		return store_error(.Corrupt_Data, "work-item update unexpectedly returned a row", allocator)
	}
	if err := update_session_time(state.database, session_id, at_ms, allocator); err.kind != .None {
		store_rollback(&state.database, allocator)
		return err
	}
	if is_terminal_work_item_status(to_status) {
		if err := close_session_if_drained(state.database, session_id, at_ms, allocator); err.kind != .None {
			store_rollback(&state.database, allocator)
			return err
		}
	}
	if err := store_sqlite_error(sqlite.commit(state.database, allocator), allocator); err.kind != .None {
		store_rollback(&state.database, allocator)
		return err
	}
	return Store_Error{}
}

// request_session_close stops queued work and returns active IDs for cooperative cancellation by the host.
request_session_close :: proc(store: Store, session_id: string, at_ms: i64, allocator := context.allocator) -> (request: Session_Close_Request, err: Store_Error) {
	if !valid_text_id(session_id) || at_ms < 0 {
		return {}, store_error(.Invalid_Argument, "session id and non-negative time are required", allocator)
	}
	state, lock_err := store_lock(store, allocator)
	if lock_err.kind != .None {
		return {}, lock_err
	}
	defer sync.mutex_unlock(&state.mutex)
	if begin_err := store_sqlite_error(sqlite.begin(state.database, allocator), allocator); begin_err.kind != .None {
		return {}, begin_err
	}
	request_transferred := false
	defer if !request_transferred { session_close_request_destroy(&request, allocator) }

	session_status, found, status_err := read_session_status(state.database, session_id, allocator)
	defer delete(session_status, allocator)
	if status_err.kind != .None {
		store_rollback(&state.database, allocator)
		return {}, status_err
	}
	if !found {
		store_rollback(&state.database, allocator)
		return {}, store_error(.Not_Found, "session was not found", allocator)
	}
	if session_status == SESSION_CLOSED {
		store_rollback(&state.database, allocator)
		request.session_closed = true
		request_transferred = true
		return request, Store_Error{}
	}
	if close_err := set_session_closing(state.database, session_id, at_ms, allocator); close_err.kind != .None {
		store_rollback(&state.database, allocator)
		return {}, close_err
	}
	if cancel_err := cancel_session_waiting_work(state.database, session_id, at_ms, allocator); cancel_err.kind != .None {
		store_rollback(&state.database, allocator)
		return {}, cancel_err
	}
	if cancel_err := request_active_work_cancellation(state.database, session_id, at_ms, allocator); cancel_err.kind != .None {
		store_rollback(&state.database, allocator)
		return {}, cancel_err
	}
	request.active_work_item_ids, err = list_active_work_item_ids(state.database, session_id, allocator)
	if err.kind != .None {
		store_rollback(&state.database, allocator)
		return {}, err
	}
	if len(request.active_work_item_ids) == 0 {
		if close_err := close_session_if_drained(state.database, session_id, at_ms, allocator); close_err.kind != .None {
			store_rollback(&state.database, allocator)
			return {}, close_err
		}
		request.session_closed = true
	}
	if commit_err := store_sqlite_error(sqlite.commit(state.database, allocator), allocator); commit_err.kind != .None {
		store_rollback(&state.database, allocator)
		return {}, commit_err
	}
	request_transferred = true
	return request, Store_Error{}
}

read_session_status :: proc(database: sqlite.Database, session_id: string, allocator: runtime.Allocator) -> (status: string, found: bool, err: Store_Error) {
	statement, prepare_err := store_prepare(database, "SELECT status FROM sessions WHERE session_id=?1", allocator)
	if prepare_err.kind != .None {
		return "", false, prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_text(statement, 1, session_id, allocator); bind_err.kind != .None {
		return "", false, bind_err
	}
	result, step_err := store_step(statement, allocator)
	if step_err.kind != .None {
		return "", false, step_err
	}
	if result == .Done {
		return "", false, Store_Error{}
	}
	status, err = column_text(statement, 0, allocator)
	return status, true, err
}

set_session_closing :: proc(database: sqlite.Database, session_id: string, at_ms: i64, allocator: runtime.Allocator) -> Store_Error {
	statement, prepare_err := store_prepare(database, "UPDATE sessions SET status='closing',closed_at_ms=NULL,updated_at_ms=MAX(updated_at_ms,?1) WHERE session_id=?2", allocator)
	if prepare_err.kind != .None { return prepare_err }
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_int64(statement, 1, at_ms, allocator); bind_err.kind != .None { return bind_err }
	if bind_err := store_bind_text(statement, 2, session_id, allocator); bind_err.kind != .None { return bind_err }
	_, step_err := store_step(statement, allocator)
	return step_err
}

cancel_session_waiting_work :: proc(database: sqlite.Database, session_id: string, at_ms: i64, allocator: runtime.Allocator) -> Store_Error {
	statement, prepare_err := store_prepare(database, "UPDATE work_items SET status='cancelled',cancel_requested_at_ms=COALESCE(cancel_requested_at_ms,?1),finished_at_ms=?1 WHERE session_id=?2 AND status IN ('queued','needs_input')", allocator)
	if prepare_err.kind != .None { return prepare_err }
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_int64(statement, 1, at_ms, allocator); bind_err.kind != .None { return bind_err }
	if bind_err := store_bind_text(statement, 2, session_id, allocator); bind_err.kind != .None { return bind_err }
	_, step_err := store_step(statement, allocator)
	return step_err
}

request_active_work_cancellation :: proc(database: sqlite.Database, session_id: string, at_ms: i64, allocator: runtime.Allocator) -> Store_Error {
	statement, prepare_err := store_prepare(database, "UPDATE work_items SET cancel_requested_at_ms=COALESCE(cancel_requested_at_ms,?1) WHERE session_id=?2 AND status='running'", allocator)
	if prepare_err.kind != .None { return prepare_err }
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_int64(statement, 1, at_ms, allocator); bind_err.kind != .None { return bind_err }
	if bind_err := store_bind_text(statement, 2, session_id, allocator); bind_err.kind != .None { return bind_err }
	_, step_err := store_step(statement, allocator)
	return step_err
}

list_active_work_item_ids :: proc(database: sqlite.Database, session_id: string, allocator: runtime.Allocator) -> (ids: [dynamic]string, err: Store_Error) {
	statement, prepare_err := store_prepare(database, "SELECT work_item_id FROM work_items WHERE session_id=?1 AND status='running' ORDER BY created_at_ms,work_item_id", allocator)
	if prepare_err.kind != .None { return nil, prepare_err }
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_text(statement, 1, session_id, allocator); bind_err.kind != .None { return nil, bind_err }
	ids = make([dynamic]string, 0, allocator)
	transferred := false
	defer if !transferred { for id in ids { delete(id, allocator) }; delete(ids) }
	for {
		result, step_err := store_step(statement, allocator)
		if step_err.kind != .None { return nil, step_err }
		if result == .Done { transferred = true; return ids, Store_Error{} }
		id, id_err := column_text(statement, 0, allocator)
		if id_err.kind != .None { return nil, id_err }
		_, append_err := append(&ids, id)
		if append_err != nil {
			delete(id, allocator)
			return nil, store_error(.Out_Of_Memory, "could not collect active work-item IDs", allocator)
		}
	}
}

close_session_if_drained :: proc(database: sqlite.Database, session_id: string, at_ms: i64, allocator: runtime.Allocator) -> Store_Error {
	statement, prepare_err := store_prepare(database, "UPDATE sessions SET status='closed',closed_at_ms=?1,updated_at_ms=MAX(updated_at_ms,?1) WHERE session_id=?2 AND status='closing' AND NOT EXISTS (SELECT 1 FROM work_items WHERE session_id=?2 AND status IN ('running','needs_input'))", allocator)
	if prepare_err.kind != .None { return prepare_err }
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_int64(statement, 1, at_ms, allocator); bind_err.kind != .None { return bind_err }
	if bind_err := store_bind_text(statement, 2, session_id, allocator); bind_err.kind != .None { return bind_err }
	_, step_err := store_step(statement, allocator)
	return step_err
}

is_terminal_work_item_status :: proc(status: string) -> bool {
	return status == WORK_ITEM_COMPLETED || status == WORK_ITEM_FAILED || status == WORK_ITEM_CANCELLED ||
		status == WORK_ITEM_INTERRUPTED || status == WORK_ITEM_EXPIRED
}

@(private)
read_work_item_state :: proc(database: sqlite.Database, work_item_id: string, allocator: runtime.Allocator) -> (status, session_id: string, found: bool, err: Store_Error) {
	statement, prepare_err := store_prepare(database, "SELECT status,session_id FROM work_items WHERE work_item_id=?1", allocator)
	if prepare_err.kind != .None {
		return "", "", false, prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_text(statement, 1, work_item_id, allocator); bind_err.kind != .None {
		return "", "", false, bind_err
	}
	result, step_err := store_step(statement, allocator)
	if step_err.kind != .None {
		return "", "", false, step_err
	}
	if result == .Done {
		return "", "", false, Store_Error{}
	}
	status, err = column_text(statement, 0, allocator)
	if err.kind != .None {
		return "", "", false, err
	}
	session_id, err = column_text(statement, 1, allocator)
	if err.kind != .None {
		delete(status, allocator)
		return "", "", false, err
	}
	return status, session_id, true, Store_Error{}
}

@(private)
valid_work_item_status :: proc(status: string) -> bool {
	return status == WORK_ITEM_QUEUED || status == WORK_ITEM_RUNNING || status == WORK_ITEM_NEEDS_INPUT ||
		status == WORK_ITEM_COMPLETED || status == WORK_ITEM_FAILED || status == WORK_ITEM_CANCELLED ||
		status == WORK_ITEM_INTERRUPTED || status == WORK_ITEM_EXPIRED
}

@(private)
valid_work_item_transition :: proc(from, to: string) -> bool {
	switch from {
	case WORK_ITEM_QUEUED:
		return to == WORK_ITEM_RUNNING || to == WORK_ITEM_FAILED || to == WORK_ITEM_CANCELLED ||
			to == WORK_ITEM_INTERRUPTED || to == WORK_ITEM_EXPIRED
	case WORK_ITEM_RUNNING:
		return to == WORK_ITEM_NEEDS_INPUT || to == WORK_ITEM_COMPLETED || to == WORK_ITEM_FAILED ||
			to == WORK_ITEM_CANCELLED || to == WORK_ITEM_INTERRUPTED
	case WORK_ITEM_NEEDS_INPUT:
		return to == WORK_ITEM_QUEUED || to == WORK_ITEM_CANCELLED || to == WORK_ITEM_INTERRUPTED
	}
	return false
}

next_record_sequence :: proc(database: sqlite.Database, work_item_id: string, allocator: runtime.Allocator) -> (i64, Store_Error) {
	statement, prepare_err := store_prepare(database, "SELECT COALESCE(MAX(sequence_no),0)+1 FROM work_item_records WHERE work_item_id=?1", allocator)
	if prepare_err.kind != .None {
		return 0, prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_text(statement, 1, work_item_id, allocator); bind_err.kind != .None {
		return 0, bind_err
	}
	result, step_err := store_step(statement, allocator)
	if step_err.kind != .None {
		return 0, step_err
	}
	if result != .Row {
		return 0, store_error(.Corrupt_Data, "record sequence query returned no row", allocator)
	}
	return column_int64(statement, 0, allocator)
}

append_record :: proc(store: Store, work_item_id, kind, payload_json: string, created_at_ms: i64, allocator := context.allocator) -> (sequence_no: i64, err: Store_Error) {
	if !valid_text_id(work_item_id) || created_at_ms < 0 || !record_kind_valid(kind) || !json_object_valid(payload_json, allocator) {
		return 0, store_error(.Invalid_Argument, "record id, kind, timestamp, and JSON object payload are required", allocator)
	}
	state, lock_err := store_lock(store, allocator)
	if lock_err.kind != .None {
		return 0, lock_err
	}
	defer sync.mutex_unlock(&state.mutex)

	if txn_err := store_sqlite_error(sqlite.begin(state.database, allocator), allocator); txn_err.kind != .None {
		return 0, txn_err
	}
	next_sequence, sequence_err := next_record_sequence(state.database, work_item_id, allocator)
	if sequence_err.kind != .None {
		store_rollback(&state.database, allocator)
		return 0, sequence_err
	}
	statement, prepare_err := store_prepare(state.database, "INSERT INTO work_item_records(work_item_id,sequence_no,kind,payload_json,created_at_ms) VALUES(?1,?2,?3,?4,?5)", allocator)
	if prepare_err.kind != .None {
		store_rollback(&state.database, allocator)
		return 0, prepare_err
	}
	if err := store_bind_text(statement, 1, work_item_id, allocator); err.kind != .None {
		store_finalize_and_destroy(&statement, allocator)
		store_rollback(&state.database, allocator)
		return 0, err
	}
	if err := store_bind_int64(statement, 2, next_sequence, allocator); err.kind != .None {
		store_finalize_and_destroy(&statement, allocator)
		store_rollback(&state.database, allocator)
		return 0, err
	}
	if err := store_bind_text(statement, 3, kind, allocator); err.kind != .None {
		store_finalize_and_destroy(&statement, allocator)
		store_rollback(&state.database, allocator)
		return 0, err
	}
	if err := store_bind_text(statement, 4, payload_json, allocator); err.kind != .None {
		store_finalize_and_destroy(&statement, allocator)
		store_rollback(&state.database, allocator)
		return 0, err
	}
	if err := store_bind_int64(statement, 5, created_at_ms, allocator); err.kind != .None {
		store_finalize_and_destroy(&statement, allocator)
		store_rollback(&state.database, allocator)
		return 0, err
	}
	result, step_err := store_step(statement, allocator)
	finalize_err := store_finalize(&statement, allocator)
	if step_err.kind != .None {
		store_error_destroy(&finalize_err, allocator)
		store_rollback(&state.database, allocator)
		return 0, step_err
	}
	if finalize_err.kind != .None {
		store_rollback(&state.database, allocator)
		return 0, finalize_err
	}
	if result != .Done {
		store_rollback(&state.database, allocator)
		return 0, store_error(.Corrupt_Data, "record insert unexpectedly returned a row", allocator)
	}
	if update_err := update_session_time_for_work_item(state.database, work_item_id, created_at_ms, allocator); update_err.kind != .None {
		store_rollback(&state.database, allocator)
		return 0, update_err
	}
	if commit_err := store_sqlite_error(sqlite.commit(state.database, allocator), allocator); commit_err.kind != .None {
		store_rollback(&state.database, allocator)
		return 0, commit_err
	}
	return next_sequence, Store_Error{}
}

list_work_item_records :: proc(store: Store, work_item_id: string, allocator := context.allocator) -> (records: [dynamic]Work_Item_Record, err: Store_Error) {
	state, lock_err := store_lock(store, allocator)
	if lock_err.kind != .None {
		return nil, lock_err
	}
	defer sync.mutex_unlock(&state.mutex)

	alloc_err: runtime.Allocator_Error
	records, alloc_err = make([dynamic]Work_Item_Record, 0, 16, allocator)
	if alloc_err != nil {
		return nil, store_error(.Out_Of_Memory, "could not allocate record results", allocator)
	}
	results_transferred := false
	defer if !results_transferred { records_destroy(records, allocator) }
	statement, prepare_err := store_prepare(state.database, "SELECT sequence_no,kind,payload_json,created_at_ms FROM work_item_records WHERE work_item_id=?1 ORDER BY sequence_no", allocator)
	if prepare_err.kind != .None {
		return nil, prepare_err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	if bind_err := store_bind_text(statement, 1, work_item_id, allocator); bind_err.kind != .None {
		return nil, bind_err
	}
	for {
		result, step_err := store_step(statement, allocator)
		if step_err.kind != .None {
			return nil, step_err
		}
		if result == .Done {
			results_transferred = true
			return records, Store_Error{}
		}
		record, row_err := read_record(statement, allocator)
		if row_err.kind != .None {
			return nil, row_err
		}
		_, append_err := append(&records, record)
		if append_err != nil {
			record_destroy(&record, allocator)
			return nil, store_error(.Out_Of_Memory, "could not grow record results", allocator)
		}
	}
}

store_lock :: proc(store: Store, allocator: runtime.Allocator) -> (state: ^Store_State, err: Store_Error) {
	if store == Store(nil) {
		return nil, store_error(.Closed, "store is closed", allocator)
	}
	state = cast(^Store_State)store
	sync.mutex_lock(&state.mutex)
	return state, Store_Error{}
}

store_prepare :: proc(database: sqlite.Database, sql: string, allocator: runtime.Allocator) -> (sqlite.Statement, Store_Error) {
	statement, err := sqlite.prepare(database, sql, allocator)
	return statement, store_sqlite_error(err, allocator)
}

store_bind_text :: proc(statement: sqlite.Statement, index: int, value: string, allocator: runtime.Allocator) -> Store_Error {
	return store_sqlite_error(sqlite.bind_text(statement, index, value, allocator), allocator)
}

store_bind_int64 :: proc(statement: sqlite.Statement, index: int, value: i64, allocator: runtime.Allocator) -> Store_Error {
	return store_sqlite_error(sqlite.bind_int64(statement, index, value, allocator), allocator)
}

store_bind_null :: proc(statement: sqlite.Statement, index: int, allocator: runtime.Allocator) -> Store_Error {
	return store_sqlite_error(sqlite.bind_null(statement, index, allocator), allocator)
}

store_step :: proc(statement: sqlite.Statement, allocator: runtime.Allocator) -> (sqlite.Step_Result, Store_Error) {
	result, err := sqlite.step(statement, allocator)
	return result, store_sqlite_error(err, allocator)
}

store_finalize :: proc(statement: ^sqlite.Statement, allocator: runtime.Allocator) -> Store_Error {
	return store_sqlite_error(sqlite.finalize(statement, allocator), allocator)
}

store_finalize_and_destroy :: proc(statement: ^sqlite.Statement, allocator: runtime.Allocator) {
	err := store_finalize(statement, allocator)
	store_error_destroy(&err, allocator)
}

store_rollback :: proc(database: ^sqlite.Database, allocator: runtime.Allocator) {
	err := sqlite.rollback(database^, allocator)
	sqlite.error_destroy(&err, allocator)
}

store_sqlite_error :: proc(err: sqlite.Error, allocator: runtime.Allocator) -> Store_Error {
	if err.code == 0 {
		return Store_Error{}
	}
	message := err.message
	return Store_Error{kind = .SQLite, sqlite_code = err.code, message = message}
}

read_schema_version :: proc(database: sqlite.Database, allocator: runtime.Allocator) -> (i64, Store_Error) {
	statement, err := store_prepare(database, "PRAGMA user_version", allocator)
	if err.kind != .None {
		return 0, err
	}
	defer store_finalize_and_destroy(&statement, allocator)
	result, step_err := store_step(statement, allocator)
	if step_err.kind != .None {
		return 0, step_err
	}
	if result != .Row {
		return 0, store_error(.Corrupt_Data, "SQLite did not return schema version", allocator)
	}
	version, column_err := sqlite.column_int64(statement, 0, allocator)
	return version, store_sqlite_error(column_err, allocator)
}

install_schema :: proc(database: sqlite.Database, allocator: runtime.Allocator) -> Store_Error {
	migrations := SCHEMA_MIGRATIONS
	return apply_schema_migrations(database, migrations[:], SCHEMA_VERSION, allocator)
}

@(private)
apply_schema_migrations :: proc(
	database: sqlite.Database,
	migrations: []Schema_Migration,
	supported_version: i64,
	allocator := context.allocator,
) -> Store_Error {
	if err := validate_schema_migrations(migrations, supported_version, allocator); err.kind != .None {
		return err
	}
	version, err := read_schema_version(database, allocator)
	if err.kind != .None {
		return err
	}
	if version < 0 || version > supported_version {
		return store_error(.Unsupported_Schema, "unsupported Oreo database schema version", allocator)
	}
	for migration in migrations {
		if migration.version > version {
			if err := apply_schema_migration(database, migration, allocator); err.kind != .None {
				return err
			}
			version = migration.version
		}
	}
	if version != supported_version {
		return store_error(.Corrupt_Data, "schema migration registry did not reach the supported version", allocator)
	}
	return Store_Error{}
}

@(private)
validate_schema_migrations :: proc(migrations: []Schema_Migration, supported_version: i64, allocator: runtime.Allocator) -> Store_Error {
	for migration, index in migrations {
		if migration.version != i64(index+1) {
			return store_error(.Corrupt_Data, "schema migrations must be ordered and contiguous from version 1", allocator)
		}
	}
	if len(migrations) == 0 || i64(len(migrations)) != supported_version {
		return store_error(.Corrupt_Data, "schema migration registry does not match the supported version", allocator)
	}
	return Store_Error{}
}

@(private)
apply_schema_migration :: proc(database: sqlite.Database, migration: Schema_Migration, allocator: runtime.Allocator) -> Store_Error {
	database_copy := database
	if begin_err := store_sqlite_error(sqlite.begin(database, allocator), allocator); begin_err.kind != .None {
		return begin_err
	}
	if execute_err := store_sqlite_error(sqlite.execute(database, migration.sql, allocator), allocator); execute_err.kind != .None {
		store_rollback(&database_copy, allocator)
		return execute_err
	}
	version, version_err := read_schema_version(database, allocator)
	if version_err.kind != .None {
		store_rollback(&database_copy, allocator)
		return version_err
	}
	if version != migration.version {
		store_rollback(&database_copy, allocator)
		return store_error(.Corrupt_Data, "schema migration did not set its declared user_version", allocator)
	}
	if commit_err := store_sqlite_error(sqlite.commit(database, allocator), allocator); commit_err.kind != .None {
		store_rollback(&database_copy, allocator)
		return commit_err
	}
	return Store_Error{}
}

close_store_database :: proc(database: ^sqlite.Database, allocator: runtime.Allocator) {
	err := sqlite.close(database, allocator)
	sqlite.error_destroy(&err, allocator)
}

read_profile :: proc(statement: sqlite.Statement, allocator: runtime.Allocator) -> (Provider_Profile_Metadata, Store_Error) {
	profile: Provider_Profile_Metadata
	var_err := Store_Error{}
	profile.profile_id, var_err = column_text(statement, 0, allocator); if var_err.kind != .None { return profile, var_err }
	profile.provider, var_err = column_text(statement, 1, allocator); if var_err.kind != .None { profile_destroy(&profile, allocator); return {}, var_err }
	profile.model, var_err = column_text(statement, 2, allocator); if var_err.kind != .None { profile_destroy(&profile, allocator); return {}, var_err }
	profile.thinking, var_err = column_text(statement, 3, allocator); if var_err.kind != .None { profile_destroy(&profile, allocator); return {}, var_err }
	profile.created_at_ms, var_err = column_int64(statement, 4, allocator); if var_err.kind != .None { profile_destroy(&profile, allocator); return {}, var_err }
	return profile, Store_Error{}
}

read_session :: proc(statement: sqlite.Statement, allocator: runtime.Allocator) -> (Session_Metadata, Store_Error) {
	session: Session_Metadata
	var_err := Store_Error{}
	session.session_id, var_err = column_text(statement, 0, allocator); if var_err.kind != .None { return session, var_err }
	session.title, var_err = column_text(statement, 1, allocator); if var_err.kind != .None { session_destroy(&session, allocator); return {}, var_err }
	session.status, var_err = column_text(statement, 2, allocator); if var_err.kind != .None { session_destroy(&session, allocator); return {}, var_err }
	session.created_at_ms, var_err = column_int64(statement, 3, allocator); if var_err.kind != .None { session_destroy(&session, allocator); return {}, var_err }
	session.updated_at_ms, var_err = column_int64(statement, 4, allocator); if var_err.kind != .None { session_destroy(&session, allocator); return {}, var_err }
	session.closed_at_ms, session.has_closed_at, var_err = column_optional_int64(statement, 5, allocator)
	if var_err.kind != .None { session_destroy(&session, allocator); return {}, var_err }
	return session, Store_Error{}
}

read_work_item :: proc(statement: sqlite.Statement, allocator: runtime.Allocator) -> (Work_Item_Metadata, Store_Error) {
	item: Work_Item_Metadata
	var_err := Store_Error{}
	item.work_item_id, var_err = column_text(statement, 0, allocator); if var_err.kind != .None { return item, var_err }
	item.session_id, var_err = column_text(statement, 1, allocator); if var_err.kind != .None { work_item_destroy(&item, allocator); return {}, var_err }
	item.profile_id, var_err = column_text(statement, 2, allocator); if var_err.kind != .None { work_item_destroy(&item, allocator); return {}, var_err }
	item.request, var_err = column_text(statement, 3, allocator); if var_err.kind != .None { work_item_destroy(&item, allocator); return {}, var_err }
	item.status, var_err = column_text(statement, 4, allocator); if var_err.kind != .None { work_item_destroy(&item, allocator); return {}, var_err }
	item.created_at_ms, var_err = column_int64(statement, 5, allocator); if var_err.kind != .None { work_item_destroy(&item, allocator); return {}, var_err }
	item.queued_at_ms, var_err = column_int64(statement, 6, allocator); if var_err.kind != .None { work_item_destroy(&item, allocator); return {}, var_err }
	item.started_at_ms, item.has_started_at, var_err = column_optional_int64(statement, 7, allocator)
	if var_err.kind != .None { work_item_destroy(&item, allocator); return {}, var_err }
	item.expires_at_ms, item.has_expires_at, var_err = column_optional_int64(statement, 8, allocator)
	if var_err.kind != .None { work_item_destroy(&item, allocator); return {}, var_err }
	item.cancel_requested_at_ms, item.has_cancel_requested_at, var_err = column_optional_int64(statement, 9, allocator)
	if var_err.kind != .None { work_item_destroy(&item, allocator); return {}, var_err }
	item.finished_at_ms, item.has_finished_at, var_err = column_optional_int64(statement, 10, allocator)
	if var_err.kind != .None { work_item_destroy(&item, allocator); return {}, var_err }
	return item, Store_Error{}
}

read_record :: proc(statement: sqlite.Statement, allocator: runtime.Allocator) -> (Work_Item_Record, Store_Error) {
	record: Work_Item_Record
	var_err := Store_Error{}
	record.sequence_no, var_err = column_int64(statement, 0, allocator); if var_err.kind != .None { return record, var_err }
	record.kind, var_err = column_text(statement, 1, allocator); if var_err.kind != .None { record_destroy(&record, allocator); return {}, var_err }
	record.payload_json, var_err = column_text(statement, 2, allocator); if var_err.kind != .None { record_destroy(&record, allocator); return {}, var_err }
	record.created_at_ms, var_err = column_int64(statement, 3, allocator); if var_err.kind != .None { record_destroy(&record, allocator); return {}, var_err }
	return record, Store_Error{}
}

column_text :: proc(statement: sqlite.Statement, index: int, allocator: runtime.Allocator) -> (string, Store_Error) {
	value, is_null, err := sqlite.column_text(statement, index, allocator)
	mapped := store_sqlite_error(err, allocator)
	if mapped.kind != .None {
		return "", mapped
	}
	if is_null {
		delete(value, allocator)
		return "", store_error(.Corrupt_Data, "required metadata column is NULL", allocator)
	}
	return value, Store_Error{}
}

column_int64 :: proc(statement: sqlite.Statement, index: int, allocator: runtime.Allocator) -> (i64, Store_Error) {
	value, err := sqlite.column_int64(statement, index, allocator)
	return value, store_sqlite_error(err, allocator)
}

column_optional_int64 :: proc(statement: sqlite.Statement, index: int, allocator: runtime.Allocator) -> (value: i64, present: bool, err: Store_Error) {
	kind, sqlite_err := sqlite.column_type(statement, index, allocator)
	err = store_sqlite_error(sqlite_err, allocator)
	if err.kind != .None || kind == .Null {
		return 0, false, err
	}
	value, err = column_int64(statement, index, allocator)
	return value, true, err
}

json_object_valid :: proc(text: string, allocator: runtime.Allocator) -> bool {
	previous_allocator := context.allocator
	defer context.allocator = previous_allocator
	value, parse_err := json.parse_string(text, .JSON, false, allocator)
	if parse_err != .None {
		json.destroy_value(value, allocator)
		return false
	}
	is_object := false
	#partial switch v in value {
	case json.Object:
		is_object = true
	}
	json.destroy_value(value, allocator)
	return is_object
}

record_kind_valid :: proc(kind: string) -> bool {
	return kind == "assistant_message" || kind == "tool_call" || kind == "tool_result" ||
		kind == "needs_input" || kind == "input_response" || kind == "progress" || kind == "final_result"
}

valid_text_id :: proc(value: string) -> bool {
	return len(value) > 0 && strings.index_byte(value, 0) < 0
}

profile_destroy :: proc(profile: ^Provider_Profile_Metadata, allocator := context.allocator) {
	delete(profile.profile_id, allocator)
	delete(profile.provider, allocator)
	delete(profile.model, allocator)
	delete(profile.thinking, allocator)
	profile^ = Provider_Profile_Metadata{}
}

session_destroy :: proc(session: ^Session_Metadata, allocator := context.allocator) {
	delete(session.session_id, allocator)
	delete(session.title, allocator)
	delete(session.status, allocator)
	session^ = Session_Metadata{}
}

sessions_destroy :: proc(sessions: [dynamic]Session_Metadata, allocator := context.allocator) {
	for &session in sessions {
		session_destroy(&session, allocator)
	}
	delete(sessions)
}

work_item_destroy :: proc(item: ^Work_Item_Metadata, allocator := context.allocator) {
	delete(item.work_item_id, allocator)
	delete(item.session_id, allocator)
	delete(item.profile_id, allocator)
	delete(item.request, allocator)
	delete(item.status, allocator)
	item^ = Work_Item_Metadata{}
}

work_items_destroy :: proc(items: [dynamic]Work_Item_Metadata, allocator := context.allocator) {
	for &item in items {
		work_item_destroy(&item, allocator)
	}
	delete(items)
}

record_destroy :: proc(record: ^Work_Item_Record, allocator := context.allocator) {
	delete(record.kind, allocator)
	delete(record.payload_json, allocator)
	record^ = Work_Item_Record{}
}

records_destroy :: proc(records: [dynamic]Work_Item_Record, allocator := context.allocator) {
	for &record in records {
		record_destroy(&record, allocator)
	}
	delete(records)
}

session_close_request_destroy :: proc(request: ^Session_Close_Request, allocator := context.allocator) {
	for id in request.active_work_item_ids {
		delete(id, allocator)
	}
	delete(request.active_work_item_ids)
	request^ = Session_Close_Request{}
}

store_error :: proc(kind: Store_Error_Kind, message: string, allocator: runtime.Allocator) -> Store_Error {
	owned, _ := strings.clone(message, allocator)
	return Store_Error{kind = kind, message = owned}
}

store_error_destroy :: proc(err: ^Store_Error, allocator := context.allocator) {
	delete(err.message, allocator)
	err^ = Store_Error{}
}
