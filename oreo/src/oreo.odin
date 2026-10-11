package oreo

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:time"
import store "oreo:store"

// The closed session status as persisted by the store. Session status values are
// the store's vocabulary; the host does not invent its own.
SESSION_CLOSED :: store.SESSION_CLOSED

Host_Error_Kind :: enum {
	None,
	Invalid_Argument,
	Out_Of_Memory,
	Closed,
	Store,
	Internal,
}

// Host_Error owns its message text. Call host_error_destroy on every value,
// including a zero value, when it is no longer needed.
Host_Error :: struct {
	kind: Host_Error_Kind,
	message: string,
}

// Session is the caller-visible view of one top-level task. The caller owns the
// three strings; call session_destroy to release them.
Session :: struct {
	id: string,
	title: string,
	status: string,
}

@(private)
Host_State :: struct {
	store: store.Store,
}

// Host is an opaque handle to one open session store.
Host :: distinct ^Host_State

// open_host opens the SQLite database at path, applying pending schema
// migrations. The host owns the connection until close_host.
open_host :: proc(path: string) -> (Host, Host_Error) {
	opened, store_err := store.open(path)
	if store_err.kind != .None {
		return Host(nil), host_store_error(store_err)
	}
	state, alloc_err := new(Host_State)
	if alloc_err != nil {
		close_err := store.close(&opened)
		store.store_error_destroy(&close_err)
		return Host(nil), host_error(.Out_Of_Memory, "could not allocate the Oreo host")
	}
	state.store = opened
	return Host(state), Host_Error{}
}

close_host :: proc(host: ^Host) -> Host_Error {
	if host == nil || host^ == Host(nil) {
		return Host_Error{}
	}
	state := cast(^Host_State)host^
	close_err := store.close(&state.store)
	if close_err.kind != .None {
		return host_store_error(close_err)
	}
	free(state)
	host^ = Host(nil)
	return Host_Error{}
}

// create_session starts a durable session with a generated opaque id.
create_session :: proc(host: Host, title: string) -> (Session, Host_Error) {
	state, state_err := host_state(host)
	if state_err.kind != .None {
		return {}, state_err
	}
	if !valid_text(title) {
		return {}, host_error(.Invalid_Argument, "session title must be NUL-free")
	}
	session_id, id_err := new_session_id()
	if id_err.kind != .None {
		return {}, id_err
	}
	defer delete(session_id)

	create_err := store.create_session(state.store, session_id, title, current_time_ms())
	if create_err.kind != .None {
		return {}, host_store_error(create_err)
	}
	session, found, find_err := find_session(host, session_id)
	if find_err.kind != .None {
		return {}, find_err
	}
	if !found {
		return {}, host_error(.Internal, "created session could not be read back")
	}
	return session, Host_Error{}
}

find_session :: proc(host: Host, session_id: string) -> (session: Session, found: bool, err: Host_Error) {
	state, state_err := host_state(host)
	if state_err.kind != .None {
		return {}, false, state_err
	}
	if !valid_text(session_id) {
		return {}, false, host_error(.Invalid_Argument, "session id must be NUL-free")
	}
	metadata, metadata_found, store_err := store.get_session(state.store, session_id)
	if store_err.kind != .None {
		return {}, false, host_store_error(store_err)
	}
	if !metadata_found {
		return {}, false, Host_Error{}
	}
	// Ownership of the metadata strings moves to the caller-visible session.
	return Session{id = metadata.session_id, title = metadata.title, status = metadata.status}, true, Host_Error{}
}

// close_session cooperatively closes the session and preserves its history.
close_session :: proc(host: Host, session_id: string) -> Host_Error {
	state, state_err := host_state(host)
	if state_err.kind != .None {
		return state_err
	}
	if !valid_text(session_id) {
		return host_error(.Invalid_Argument, "session id must be NUL-free")
	}
	request, store_err := store.request_session_close(state.store, session_id, current_time_ms())
	if store_err.kind != .None {
		return host_store_error(store_err)
	}
	// No worker pool exists yet, so there are no active work items to
	// acknowledge; the store has already cancelled any queued work.
	store.session_close_request_destroy(&request)
	return Host_Error{}
}

session_destroy :: proc(session: ^Session) {
	delete(session.id)
	delete(session.title)
	delete(session.status)
	session^ = Session{}
}

host_error_destroy :: proc(err: ^Host_Error) {
	delete(err.message)
	err^ = Host_Error{}
}

@(private)
host_state :: proc(host: Host) -> (^Host_State, Host_Error) {
	if host == Host(nil) {
		return nil, host_error(.Closed, "host is closed")
	}
	return cast(^Host_State)host, Host_Error{}
}

@(private)
new_session_id :: proc() -> (string, Host_Error) {
	id := fmt.aprintf("%016x%016x", rand.uint64(), rand.uint64())
	if len(id) == 0 {
		return "", host_error(.Out_Of_Memory, "could not allocate a session id")
	}
	return id, Host_Error{}
}

@(private)
current_time_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

@(private)
valid_text :: proc(value: string) -> bool {
	return strings.index_byte(value, 0) < 0
}

@(private)
host_error :: proc(kind: Host_Error_Kind, message: string) -> Host_Error {
	owned, _ := strings.clone(message)
	return Host_Error{kind = kind, message = owned}
}

// host_store_error takes ownership of the store error's message.
@(private)
host_store_error :: proc(err: store.Store_Error) -> Host_Error {
	return Host_Error{kind = .Store, message = err.message}
}
