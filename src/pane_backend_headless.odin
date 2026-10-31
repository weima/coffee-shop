package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

// The headless implementation of Session_Surface: a Station is a plain child process
// (`/bin/sh -c <command>`), with no Herdr, workspace, tab or pane. Its stdout and stderr
// go to <state root>/host/<request>/logs/<shot>.log, input is written to its stdin, and
// closing the session terminates it.
//
// Vocabulary: the "workspace" id is the request id, and the tab and pane ids are both the
// session key "<request>/<shot>". tab_create allocates the session; the first pane_run
// starts the command; later pane_run calls write one line to the child's stdin.
//
// Log bound: HEADLESS_LOG_MAX per file, two files (<shot>.log and <shot>.log.1, the previous
// generation), so a Shot's output never exceeds 2 * HEADLESS_LOG_MAX = 16 MiB however long it
// runs. 8 MiB holds hours of normal Station output and still leaves the newest text and the
// start of the oldest generation for diagnosis; a Station that spams is capped, not stopped.
HEADLESS_LOG_MAX :: 8 * 1024 * 1024
HEADLESS_TERM_GRACE :: 2 * time.Second

headless_ops := Session_Ops{
	workspace_create  = headless_workspace_create,
	workspace_label   = headless_workspace_label,
	workspace_close   = headless_workspace_close,
	tab_create        = headless_tab_create,
	tab_close         = headless_tab_close,
	tab_rename        = headless_tab_rename,
	tab_count         = headless_tab_count,
	pane_run          = headless_pane_run,
	pane_reset        = headless_pane_reset,
	pane_close        = headless_pane_close,
	pane_get          = headless_pane_get,
	pane_process_info = headless_pane_process_info,
}

// handle is the state root; the logs live under it.
headless_session_surface :: proc(state_root: string) -> Session_Surface {
	return Session_Surface{handle = state_root, ops = &headless_ops}
}

Headless_Session :: struct {
	key, request_id, shot_id, cwd, log_path: string,
	log_max:  int,
	process:  os.Process,
	started:  bool,
	stdin:    ^os.File,
	pump:     ^thread.Thread,
	pump_done: bool, // atomic: the pump saw EOF and closed its files
	pump_read: ^os.File,
	pump_file: ^os.File,
}

headless_sessions: [dynamic]^Headless_Session
headless_lock: sync.Mutex

headless_find :: proc(key: string) -> ^Headless_Session {
	for session in headless_sessions {
		if session.key == key {
			return session
		}
	}
	return nil
}

// Allocates a Shot session (nothing runs yet). log_max is a parameter so a test can use a small bound.
headless_session_open :: proc(state_root, request_id, shot_id, cwd: string, log_max := HEADLESS_LOG_MAX) -> (key, err: string) {
	logs_dir, _ := filepath.join({state_root, "host", request_id, "logs"}, context.temp_allocator)
	if os.make_directory_all(logs_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil && !os.is_directory(logs_dir) {
		return "", "could not create the Shot log directory"
	}
	session := new(Headless_Session)
	session.key = fmt.aprintf("%s/%s", request_id, shot_id)
	session.request_id = strings.clone(request_id)
	session.shot_id = strings.clone(shot_id)
	session.cwd = strings.clone(cwd)
	session.log_path = fmt.aprintf("%s/%s.log", logs_dir, shot_id)
	session.log_max = log_max
	sync.mutex_guard(&headless_lock)
	if headless_find(session.key) != nil {
		headless_session_free(session)
		return "", "a session for that Shot already exists"
	}
	if headless_sessions.allocator.procedure == nil {
		// The table outlives any one caller's allocator (tests give each thread its own).
		headless_sessions = make([dynamic]^Headless_Session, 0, 8, runtime.heap_allocator())
	}
	append(&headless_sessions, session)
	return strings.clone(session.key, context.temp_allocator), ""
}

headless_session_free :: proc(session: ^Headless_Session) {
	delete(session.key)
	delete(session.request_id)
	delete(session.shot_id)
	delete(session.cwd)
	delete(session.log_path)
	free(session)
}

headless_workspace_create :: proc(s: Session_Surface, cwd, label: string, allocator := context.allocator) -> (opened: Opened_Pane, err: string) {
	return Opened_Pane{workspace_id = strings.clone(label, allocator)}, ""
}

headless_workspace_label :: proc(s: Session_Surface, workspace_id: string) -> (label, detail: string, ok: bool) {
	return workspace_id, "", true
}

headless_workspace_close :: proc(s: Session_Surface, workspace_id: string) -> bool {
	keys := make([dynamic]string, context.temp_allocator)
	{
		sync.mutex_guard(&headless_lock)
		for session in headless_sessions {
			if session.request_id == workspace_id {
				append(&keys, strings.clone(session.key, context.temp_allocator))
			}
		}
	}
	ok := true
	for key in keys {
		ok = headless_close(key) && ok
	}
	return ok
}

headless_tab_create :: proc(s: Session_Surface, workspace_id, shot_id, cwd: string, allocator := context.allocator) -> (opened: Opened_Pane, err: string) {
	key, open_err := headless_session_open(s.handle, workspace_id, shot_id, cwd)
	if open_err != "" {
		return {}, open_err
	}
	return Opened_Pane{
		workspace_id = strings.clone(workspace_id, allocator),
		tab_id = strings.clone(key, allocator),
		pane_id = strings.clone(key, allocator),
	}, ""
}

headless_tab_close :: proc(s: Session_Surface, tab_id: string) -> bool {
	return headless_close(tab_id)
}

headless_tab_rename :: proc(s: Session_Surface, tab_id, shot_id: string) -> string {
	return ""
}

headless_tab_count :: proc(s: Session_Surface, workspace_id: string) -> (count: int, ok: bool) {
	sync.mutex_guard(&headless_lock)
	for session in headless_sessions {
		if session.request_id == workspace_id {
			count += 1
		}
	}
	return count, true
}

// The first call starts the command; later calls send one line to the child's stdin.
headless_pane_run :: proc(s: Session_Surface, pane_id, command: string) -> string {
	sync.mutex_guard(&headless_lock)
	session := headless_find(pane_id)
	if session == nil {
		return "no such headless session"
	}
	if session.started {
		return headless_write_line(session, command)
	}
	return headless_start(session, command)
}

headless_write_line :: proc(session: ^Headless_Session, line: string) -> string {
	if session.stdin == nil {
		return "the Station's input is closed"
	}
	text := fmt.tprintf("%s\n", line)
	if _, err := os.write(session.stdin, transmute([]byte)text); err != nil {
		return "could not write to the Station's input"
	}
	return ""
}

headless_start :: proc(session: ^Headless_Session, command: string) -> string {
	out_read, out_write, out_err := os.pipe()
	if out_err != nil {
		return "could not create the Station output pipe"
	}
	in_read, in_write, in_err := os.pipe()
	if in_err != nil {
		_ = os.close(out_read)
		_ = os.close(out_write)
		return "could not create the Station input pipe"
	}
	log_file, log_err := os.create(session.log_path)
	if log_err != nil {
		for f in ([4]^os.File{out_read, out_write, in_read, in_write}) { _ = os.close(f) }
		return "could not create the Shot log"
	}
	process, start_err := os.process_start(os.Process_Desc{
		working_dir = session.cwd,
		command = {"/bin/sh", "-c", command},
		stdin = in_read, stdout = out_write, stderr = out_write,
	})
	_ = os.close(out_write)
	_ = os.close(in_read)
	if start_err != nil {
		_ = os.close(out_read)
		_ = os.close(in_write)
		_ = os.close(log_file)
		return "could not start the Station process"
	}
	session.process, session.started, session.stdin = process, true, in_write
	session.pump_read, session.pump_file = out_read, log_file
	session.pump = thread.create_and_start_with_poly_data(session, headless_pump)
	return ""
}

// Copies the child's merged output into the log, rotating at log_max so it stays bounded.
headless_pump :: proc(session: ^Headless_Session) {
	buf: [8192]byte
	written := 0
	for {
		n, err := os.read(session.pump_read, buf[:])
		if n > 0 {
			chunk := buf[:n]
			if written + n > session.log_max {
				_ = os.close(session.pump_file)
				old := fmt.tprintf("%s.1", session.log_path)
				_ = os.rename(session.log_path, old)
				session.pump_file, _ = os.create(session.log_path)
				written = 0
				// One read can exceed the whole bound. Keep its newest bytes, not its first:
				// the bounded log exists to hold the tail of a run, and a full pipe under load
				// delivers exactly that chunk at the end.
				if len(chunk) > session.log_max {
					chunk = chunk[len(chunk) - session.log_max:]
				}
			}
			if session.pump_file != nil {
				_, _ = os.write(session.pump_file, chunk)
				written += len(chunk)
			}
		}
		if err != nil || n == 0 {
			break
		}
	}
	sync.atomic_store(&session.pump_done, true)
}

headless_pane_reset :: proc(s: Session_Surface, workspace_id, pane_id: string) -> bool {
	return true // nothing to clear: no terminal, no reuse
}

headless_pane_close :: proc(s: Session_Surface, workspace_id, pane_id: string) -> bool {
	return headless_close(pane_id)
}

headless_pane_get :: proc(s: Session_Surface, pane_id: string) -> (tab_id, workspace_id: string, ok: bool) {
	sync.mutex_guard(&headless_lock)
	session := headless_find(pane_id)
	if session == nil {
		return "", "", false
	}
	return session.key, session.request_id, true
}

// The child is the shell that runs the command, which normally execs the Station; the
// Station also reports its own pid, and the host prefers that.
headless_pane_process_info :: proc(s: Session_Surface, pane_id: string) -> Process_Identity {
	sync.mutex_guard(&headless_lock)
	session := headless_find(pane_id)
	if session == nil || !session.started {
		return {}
	}
	identity := Process_Identity{pid = session.process.pid}
	if start, ok := process_start_time(session.process.pid); ok {
		identity.start_time = start
	}
	return identity
}

// Terminates the child (SIGTERM, then SIGKILL after the grace), reaps it, and frees the session.
headless_close :: proc(key: string) -> bool {
	sync.mutex_guard(&headless_lock)
	index := -1
	for session, i in headless_sessions {
		if session.key == key {
			index = i
		}
	}
	if index < 0 {
		return false
	}
	session := headless_sessions[index]
	unordered_remove(&headless_sessions, index)
	if session.stdin != nil {
		_ = os.close(session.stdin)
	}
	if session.started {
		headless_terminate(session.process.pid)
		if !headless_finish_pump(session) {
			return true // the pump still uses the session; see headless_finish_pump
		}
	}
	headless_session_free(session)
	return true
}

headless_terminate :: proc(pid: int) {
	_ = posix.kill(posix.pid_t(pid), .SIGTERM)
	deadline := time.time_add(time.now(), HEADLESS_TERM_GRACE)
	status: i32
	for {
		if r := posix.waitpid(posix.pid_t(pid), &status, {.NOHANG}); r != 0 {
			return // exited and reaped, or already reaped
		}
		if time.diff(time.now(), deadline) <= 0 {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	_ = posix.kill(posix.pid_t(pid), .SIGKILL)
	_ = posix.waitpid(posix.pid_t(pid), &status, {})
}

// The pump ends at EOF once every holder of the pipe has exited. If a descendant outlived the
// Station, give up after the grace and leak the pump rather than free what it still uses.
// shortcut: a surviving grandchild leaks one thread and its files until it exits.
headless_finish_pump :: proc(session: ^Headless_Session) -> (finished: bool) {
	deadline := time.time_add(time.now(), HEADLESS_TERM_GRACE)
	for !sync.atomic_load(&session.pump_done) {
		if time.diff(time.now(), deadline) <= 0 {
			return false
		}
		time.sleep(5 * time.Millisecond)
	}
	thread.join(session.pump)
	thread.destroy(session.pump)
	_ = os.close(session.pump_read)
	if session.pump_file != nil {
		_ = os.close(session.pump_file)
	}
	return true
}
