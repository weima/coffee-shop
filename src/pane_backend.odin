package main

import "core:fmt"
import "core:os"

// Session_Surface is a Station's session surface: the place a Station runs, is
// started in, can be asked about, and is torn down. Every host, dispatch, settle,
// pool and PR call that used to run the Herdr CLI goes through it, so a backend can
// be swapped without touching a call site. session_surface_open is the one place a
// backend is chosen; it picks Herdr (pane_backend_herdr.odin) or headless (pane_backend_headless.odin).
//
// The operations are exactly the twelve the code performed, nothing more:
// workspace create/get/close, tab create/close/rename/list, pane run/close/get/
// process-info. pane_reset is the pool's terminal reset, which Herdr runs as a
// `pane run`, so it is the Herdr `pane run` operation too.
//
// WHAT A BACKEND OWES A CALLER (both Herdr and headless meet it):
//   - tab_create/workspace_create give back ids that the other operations accept; pane_run
//     with a command starts the Station, and pane_run with a later message delivers it to
//     the Station's input (Herdr types it; headless writes a line to stdin).
//   - pane_process_info reports a process identity, or the zero value when unknown; it
//     never guesses. The Station also reports its own pid, and cancel prefers that.
//   - tab_close/pane_close end what runs there and report whether anything was closed; a
//     second close is false, not a crash. pane_reset is safe to call and may do nothing.
//   - Errors are returned as a reason string, never a panic, and nothing is retried.
// The headless backend (pane_backend_headless.odin) sends Station stdout/stderr to
// <state root>/host/<request>/logs/<shot>.log, bounded; it has no pane pool, and the host
// then limits concurrency through pane_backend_headless_slots.odin instead.
Session_Surface :: struct {
	handle: string,       // backend-defined and opaque to callers (Herdr: the CLI path)
	call:   Surface_Call, // optional transport override, used by PR tests; nil = backend default
	ops:    ^Session_Ops,
}

// A raw transport call: the backend's arguments in, trimmed output out.
Surface_Call :: proc(args: []string) -> (out, detail: string, ok: bool)

// Ids of what a create operation opened. The strings are owned by the caller's allocator.
Opened_Pane :: struct {
	workspace_id: string,
	tab_id:       string,
	pane_id:      string,
}

Session_Ops :: struct {
	workspace_create:  proc(s: Session_Surface, cwd, label: string, allocator := context.allocator) -> (opened: Opened_Pane, err: string),
	workspace_label:   proc(s: Session_Surface, workspace_id: string) -> (label, detail: string, ok: bool), // workspace get
	workspace_close:   proc(s: Session_Surface, workspace_id: string) -> bool,
	tab_create:        proc(s: Session_Surface, workspace_id, shot_id, cwd: string, allocator := context.allocator) -> (opened: Opened_Pane, err: string),
	tab_close:         proc(s: Session_Surface, tab_id: string) -> bool,
	tab_rename:        proc(s: Session_Surface, tab_id, shot_id: string) -> (err: string),
	tab_count:         proc(s: Session_Surface, workspace_id: string) -> (count: int, ok: bool), // tab list; -1 if unreadable
	pane_run:          proc(s: Session_Surface, pane_id, command: string) -> (err: string),
	pane_reset:        proc(s: Session_Surface, workspace_id, pane_id: string) -> (ok: bool),
	pane_close:        proc(s: Session_Surface, workspace_id, pane_id: string) -> (ok: bool),
	pane_get:          proc(s: Session_Surface, pane_id: string) -> (tab_id, workspace_id: string, ok: bool),
	pane_process_info: proc(s: Session_Surface, pane_id: string) -> Process_Identity, // zero value if unknown
}

Pane_Backend :: enum {
	HERDR,
	HEADLESS,
}

PANE_BACKEND_ENV :: "CS_PANE_BACKEND"

// "" and "herdr" select Herdr (today's behaviour); "headless" selects headless. Anything
// else is an error that names the value, never a silent fallback.
pane_backend_parse :: proc(value: string) -> (backend: Pane_Backend, err: string) {
	switch value {
	case "", "herdr":
		return .HERDR, ""
	case "headless":
		return .HEADLESS, ""
	}
	return .HERDR, fmt.tprintf("%s=%q is not a pane backend; use herdr or headless", PANE_BACKEND_ENV, value)
}

pane_backend_from_env :: proc() -> (backend: Pane_Backend, err: string) {
	return pane_backend_parse(os.get_env(PANE_BACKEND_ENV, context.temp_allocator))
}

pane_backend_is_headless :: proc() -> bool {
	backend, err := pane_backend_from_env()
	return err == "" && backend == .HEADLESS
}

// The single backend selection point. handle is what callers already thread through
// as the Herdr executable path; headless ignores it and uses the state root. The host
// checks the variable at startup, so an invalid value reaching here is a bug: fail loudly.
session_surface_open :: proc(handle: string) -> Session_Surface {
	backend, err := pane_backend_from_env()
	if err != "" {
		panic(err)
	}
	if backend == .HEADLESS {
		root, root_err := default_state_root(context.temp_allocator)
		if root_err != "" {
			panic(root_err)
		}
		return headless_session_surface(root)
	}
	return herdr_session_surface(handle, nil)
}

// As session_surface_open, but over an injected transport (PR tests fake it).
session_surface_over :: proc(handle: string, call: Surface_Call) -> Session_Surface {
	return herdr_session_surface(handle, call)
}
