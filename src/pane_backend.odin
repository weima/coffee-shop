package main

// Session_Surface is a Station's session surface: the place a Station runs, is
// started in, can be asked about, and is torn down. Every host, dispatch, settle,
// pool and PR call that used to run the Herdr CLI goes through it, so a backend can
// be swapped without touching a call site. session_surface_open is the one place a
// backend is chosen; today it always returns the Herdr one (pane_backend_herdr.odin).
//
// The operations are exactly the twelve the code performed, nothing more:
// workspace create/get/close, tab create/close/rename/list, pane run/close/get/
// process-info. pane_reset is the pool's terminal reset, which Herdr runs as a
// `pane run`, so it is the Herdr `pane run` operation too.
//
// WHAT A HEADLESS BACKEND MUST PROVIDE (not implemented in this Pull):
//   - Station stdio goes to a per-Shot log file instead of a terminal. pane_run
//     starts the Station command with stdout and stderr redirected to that log, and
//     the Opened_Pane ids it hands back name the Shot's log/process, not a pane.
//   - Replies reach the Station through the host's existing `reply` request, so
//     host_reply's pane_run of a message must become a write to the Station's stdin.
//     process_info must report the Station's own pid (no shell wraps it).
//   - There is no pane pool at all: no pane is kept, cleared or reused. pane_close
//     and pane_reset are no-ops that succeed, and the pool is never initialised.
//   - Workspaces and tabs have no meaning: workspace_create/tab_create just
//     allocate a Shot session, and the get/list/close operations are answered
//     from that state so `pull` clean-up still works.
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

// The single backend selection point. handle is what callers already thread through
// as the Herdr executable path.
session_surface_open :: proc(handle: string) -> Session_Surface {
	return herdr_session_surface(handle, nil)
}

// As session_surface_open, but over an injected transport (PR tests fake it).
session_surface_over :: proc(handle: string, call: Surface_Call) -> Session_Surface {
	return herdr_session_surface(handle, call)
}
