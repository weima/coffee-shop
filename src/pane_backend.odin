package main

// Session keys keep the wire's pane_id field stable while the host runs headless.
Session_Surface :: struct {
	handle: string,
	ops:    ^Session_Ops,
}

Opened_Pane :: struct {
	workspace_id: string,
	tab_id:       string,
	pane_id:      string,
}

Session_Ops :: struct {
	workspace_create:  proc(s: Session_Surface, cwd, label: string, allocator := context.allocator) -> (opened: Opened_Pane, err: string),
	workspace_label:   proc(s: Session_Surface, workspace_id: string) -> (label, detail: string, ok: bool),
	workspace_close:   proc(s: Session_Surface, workspace_id: string) -> bool,
	tab_create:        proc(s: Session_Surface, workspace_id, shot_id, cwd: string, allocator := context.allocator) -> (opened: Opened_Pane, err: string),
	tab_close:         proc(s: Session_Surface, tab_id: string) -> bool,
	tab_rename:        proc(s: Session_Surface, tab_id, shot_id: string) -> (err: string),
	tab_count:         proc(s: Session_Surface, workspace_id: string) -> (count: int, ok: bool),
	pane_run:          proc(s: Session_Surface, pane_id, command: string) -> (err: string),
	pane_reset:        proc(s: Session_Surface, workspace_id, pane_id: string) -> (ok: bool),
	pane_close:        proc(s: Session_Surface, workspace_id, pane_id: string) -> (ok: bool),
	pane_get:          proc(s: Session_Surface, pane_id: string) -> (tab_id, workspace_id: string, ok: bool),
	pane_process_info: proc(s: Session_Surface, pane_id: string) -> Process_Identity,
}

session_surface_open :: proc(handle: string) -> Session_Surface {
	if handle != "" {
		return headless_session_surface(handle)
	}
	root, err := default_state_root(context.temp_allocator)
	if err != "" {
		panic(err)
	}
	return headless_session_surface(root)
}
