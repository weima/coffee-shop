package main

import "core:bufio"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"

HOST_PROTOCOL :: 1

// Compiled into the binary, so a Station can load it from any install location.
HOST_EXTENSION_SOURCE :: #load("../extensions/coffee-shop.ts", string)
HOST_OREO_EXTENSION_SOURCE :: #load("../extensions/oreo/index.ts", string)
HOST_OREO_PROTOCOL_SOURCE :: #load("../extensions/oreo/protocol.ts", string)

// Byte limit for one request line, the scanner token limit this loop replaces.
HOST_LINE_MAX :: bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE

// A short poll wait, so a Station report is relayed promptly while an idle host
// still sleeps instead of spinning.
HOST_LOOP_POLL_MS :: 20

// Set once by run_host and read by dispatch when it launches Station panes.
host_report_socket: string
host_herdr_exe := "herdr" // tests point this at a fake
host_station_executable: string
host_extension_path: string
host_oreo_extension_path: string
host_oreo_host_path: string
host_history_root: string

HOST_LOCK_FILE_NAME :: "host.lock"

// Pane of each started Station, so a reply can be typed into the right pane and a
// cancel can find the Station's process at cancel time.
Host_Session :: struct {
	request_id: string,
	shot_id:    string,
	pane_id:    string,
	exited:     bool, // agent_exited was reported; the Station may still run its Taste
	station:    Process_Identity, // reported by the Station itself; zero until it does
	agent_pid:  int,
}
host_sessions: [dynamic]Host_Session

HOST_REPLY_MAX :: 4096

// Byte length of a received stdin line. A union so that events that do not carry
// it leave it nil, and json's omitempty then drops the field entirely.
Host_Byte_Count :: union {
	int,
}

// One line on stdout per event. Encoded with json.marshal so that free-form
// reasons from Git or Herdr cannot break the framing.
Host_Event :: struct {
	type:        string `json:"type"`,
	request_id:  string `json:"request_id"`,
	// Only set on received events, so an unanswered request can be told apart
	// from one that was never read. A nil union field is omitted, unlike a zero
	// int, which json's omitempty never drops.
	bytes:       Host_Byte_Count `json:"bytes,omitempty"`,
	shot_id:     string `json:"shot_id,omitempty"`,
	pane_id:     string `json:"pane_id,omitempty"`,
	kind:        string `json:"kind,omitempty"`,
	description: string `json:"description,omitempty"`,
	reason:      string `json:"reason,omitempty"`,
	branch:      string `json:"branch,omitempty"`,
	commit:      string `json:"commit,omitempty"`,
}

// Foreground host: reads one JSON request per line from stdin and answers on
// stdout. It exits on shutdown or end of input; it never daemonizes. While it
// runs, a relay thread forwards Station reports to stdout as station_report.
run_host :: proc() -> int {
	_ = spans_init("host")
	defer spans_close()
	span_begin("host start")
	span_started := true
	defer if span_started {span_end()}
	state_root, state_err := default_state_root(context.temp_allocator)
	if state_err != "" {
		host_write_line(fmt.tprintf(`{{"type":"error","reason":"%s"}}`, state_err))
		return 1
	}
	if _, backend_err := pane_backend_from_env(); backend_err != "" {
		host_emit(Host_Event{type = "error", reason = backend_err})
		return 1
	}
	host_dir, _ := filepath.join({state_root, "host"}, context.temp_allocator)
	if !os.is_directory(host_dir) && os.make_directory_all(host_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		host_write_line(`{"type":"error","reason":"could not create the host directory"}`)
		return 1
	}
	// The request socket lives here, so only the user may enter it, whatever the umask or an older install left.
	if !host_dir_make_private(host_dir) {
		host_write_line(`{"type":"error","reason":"could not make the host directory private"}`)
		return 1
	}
	extension_dir, _ := filepath.join({host_dir, "extensions"}, context.allocator)
	if !os.is_directory(extension_dir) && os.make_directory_all(extension_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		host_write_line(`{"type":"error","reason":"could not create the extension directory"}`)
		return 1
	}
	extension_path, _ := filepath.join({extension_dir, "coffee-shop.ts"}, context.allocator)
	if os.write_entire_file(extension_path, HOST_EXTENSION_SOURCE, os.Permissions{.Read_User, .Write_User}) != nil {
		host_write_line(`{"type":"error","reason":"could not write the Coffee Shop extension"}`)
		return 1
	}
	oreo_dir, _ := filepath.join({extension_dir, "oreo"}, context.temp_allocator)
	if os.make_directory_all(oreo_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil && !os.is_directory(oreo_dir) {
		host_write_line(`{"type":"error","reason":"could not create the Oreo extension directory"}`)
		return 1
	}
	host_oreo_extension_path, _ = filepath.join({oreo_dir, "index.ts"}, context.allocator)
	oreo_protocol_path, _ := filepath.join({oreo_dir, "protocol.ts"}, context.temp_allocator)
	if os.write_entire_file(host_oreo_extension_path, HOST_OREO_EXTENSION_SOURCE, os.Permissions{.Read_User, .Write_User}) != nil ||
		os.write_entire_file(oreo_protocol_path, HOST_OREO_PROTOCOL_SOURCE, os.Permissions{.Read_User, .Write_User}) != nil {
		host_write_line(`{"type":"error","reason":"could not write the Oreo extension"}`)
		return 1
	}
	host_extension_path = extension_path
	host_history_root = strings.clone(host_dir, context.allocator)
	spool_dir, _ := filepath.join({host_dir, STATION_SPOOL_DIR_NAME}, context.temp_allocator)
	if !os.is_directory(spool_dir) && os.make_directory_all(spool_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		host_write_line(`{"type":"error","reason":"could not create the report spool"}`)
		return 1
	}
	host_lock, lock_ok := host_acquire_lock(host_dir)
	if !lock_ok {
		write_error("another host is already running")
		return 1
	}
	defer file_lock_release(host_lock)
	socket_path, _ := filepath.join({host_dir, "activity.sock"}, context.allocator)
	// A host that was killed leaves its socket behind, and bind would refuse it.
	// The host lock proves that a leftover socket cannot belong to a live host.
	activity_unlink(socket_path)
	listener, listener_ok := activity_listener_open(socket_path)
	if !listener_ok {
		host_write_line(`{"type":"error","reason":"could not open the host report socket"}`)
		return 1
	}
	defer activity_listener_close(&listener)
	requests, requests_ok := host_request_listener_open(host_dir)
	if !requests_ok {
		host_write_line(`{"type":"error","reason":"could not open the host request socket"}`)
		return 1
	}
	defer activity_listener_close(&requests)
	executable_info, info_err := os.current_process_info({.Executable_Path}, context.allocator)
	if info_err != nil || executable_info.executable_path == "" {
		host_write_line(`{"type":"error","reason":"could not locate the Coffee Shop executable"}`)
		return 1
	}
	host_report_socket = socket_path
	host_station_executable = executable_info.executable_path
	if configured_host, configured := os.lookup_env("OREO_HOST", context.temp_allocator); configured && configured_host != "" {
		host_oreo_host_path = strings.clone(configured_host, context.allocator)
	} else {
		executable_dir := filepath.dir(executable_info.executable_path)
		host_oreo_host_path, _ = filepath.join({executable_dir, "oreo", "bin", "oreo-host.bin"}, context.allocator)
	}

	host_write_line(fmt.tprintf(`{{"type":"ready","protocol":%d}}`, HOST_PROTOCOL))
	span_end() // host start ends once the host is ready
	span_started = false
	// Initialize dispatch pool and recover from previous crash.
	host_dispatch_init(host_pane_pool.workspace_id)
	recovery_ok, _ := host_pool_recover(state_root, "herdr")
	if !recovery_ok {
		when ODIN_DEBUG {
			log.warnf("run_host: pool recovery incomplete")
		}
	}
	// Initialize progress supervision ledger and rebuild from persisted history.
	if !progress_supervision_init(host_history_root) {
		// Ledger init failure is not fatal; continue with empty ledger.
	}
	host_recover_spool()
	defer {
		// Persist pool state and close all host-owned panes on exit.
		_, _ = host_pool_persist(state_root)
		_ = host_dispatch_cleanup("herdr")
	}
	host_loop(&listener, &requests)
	return 0
}

// One request line accumulated across stdin reads. The buffer is owned by the loop
// rather than the temp allocator, so the per-line free cannot disturb it.
Host_Line :: struct {
	data:       [HOST_LINE_MAX]u8,
	len:        int,
	discarding: bool, // an overlong line is being dropped up to its newline
	dropped:    int,  // bytes counted in the overlong line, for the error event
}

// Serves stdin requests and Station reports from one poll over two descriptors on
// one thread. stdin keeps the blocking default and is read only after poll reports
// it ready; the listener is non-blocking and is drained every turn.
host_loop :: proc(listener, requests: ^Activity_Listener) {
	line: Host_Line
	chunk: [4096]u8
	for {
		fds := [3]posix.pollfd{
			{fd = posix.STDIN_FILENO, events = {.IN}},
			{fd = listener.fd, events = {.IN}},
			{fd = requests.fd, events = {.IN}},
		}
		_ = posix.poll(raw_data(fds[:]), posix.nfds_t(len(fds)), HOST_LOOP_POLL_MS)
		host_serve_requests(requests)
		free_all(context.temp_allocator)

		// Reports arrive on accepted clients, which poll on the listener cannot
		// signal, so drain every turn instead of only on a new connection.
		host_relay_pending(listener)
		host_sample_sessions_throttled()

		if fds[0].revents == {} {
			continue
		}
		count := posix.read(posix.STDIN_FILENO, raw_data(chunk[:]), len(chunk))
		if count > 0 {
			if host_stdin_consume(&line, chunk[:int(count)]) {
				return
			}
			continue
		}
		if count < 0 {
			err := posix.get_errno()
			if err == .EINTR || err == .EAGAIN || err == .EWOULDBLOCK {
				continue
			}
			host_emit(Host_Event{type = "error", reason = fmt.tprintf("stdin read failed: %v", err)})
		}
		// End of input. A last line without its newline is still a request, as the
		// scanner treated it.
		host_stdin_finish(&line)
		return
	}
}

// Forwards every Station report already waiting, then checks for stale and needs_input Stations.
// The listener and its clients are non-blocking, so this never holds up stdin.
host_relay_pending :: proc(listener: ^Activity_Listener) {
	for {
		result := activity_listener_receive(listener)
		switch result.kind {
		case .Message:
			host_relay_message(result.message)
			destroy_struct(&result.message)
		case .Unavailable:
			// Check for stale and needs_input after processing all available messages.
			_ = progress_supervision_check_and_emit()
			if host_any_session_exited() {
				_ = host_reap_gone_sessions(default_process_commands())
			}
			return
		case .Malformed:
		case .Failed:
			return
		}
		free_all(context.temp_allocator)
	}
}

// Relays one report. The history record is written before stdout is, and only then is
// the spooled copy removed, so a crash at any point leaves the report recoverable.
host_relay_message :: proc(message: Activity_Message) {
	span_begin("report relay")
	defer span_end()
	// Record in progress ledger before emitting.
	if message.kind == ACTIVITY_KIND_STATION_PID {
		host_record_station_pid(message)
		return
	}
	progress_supervision_record_report(message.brew_id, message.shot_id, message.kind)

	relayed := host_emit(Host_Event{
		type = "station_report",
		request_id = message.brew_id,
		shot_id = message.shot_id,
		kind = message.kind,
		description = host_report_text(message.description),
	})
	if !relayed {
		return
	}

	// Remove spool file after successful relay.
	if message.spool != "" {
		spool_path, _ := filepath.join({host_history_root, STATION_SPOOL_DIR_NAME, message.spool}, context.temp_allocator)
		_ = os.remove(spool_path)
	}

	// Handle pool reclamation for different report kinds.
	switch message.kind {
	case "needs_input":
		// Pin pane until reply or cancel.
		for session in host_sessions {
			if session.request_id == message.brew_id && session.shot_id == message.shot_id {
				host_pane_pin(session.pane_id)
				break
			}
		}

	case "process_gone":
		host_release_session(message.brew_id, message.shot_id, message.kind)

	case "agent_exited":
		// Not terminal: a Taste may still report. host_reap_gone_sessions releases the
		// pane if the Station then exits without a terminal report.
		for i in 0..<len(host_sessions) {
			if host_sessions[i].request_id == message.brew_id && host_sessions[i].shot_id == message.shot_id {
				host_sessions[i].exited = true
				break
			}
		}

	case "reply_received":
		// User replied to needs_input. Unpin and mark reclaimable.
		pane_id := ""
		for i in 0..<len(host_sessions) {
			if host_sessions[i].request_id == message.brew_id && host_sessions[i].shot_id == message.shot_id {
				pane_id = host_sessions[i].pane_id
				break
			}
		}

		if pane_id != "" {
			host_pane_unpin(pane_id)
			host_pane_mark_terminal(pane_id)
		}

	case "cancelled":
		// User or system cancelled needs_input. Unpin and mark reclaimable.
		pane_id := ""
		for i in 0..<len(host_sessions) {
			if host_sessions[i].request_id == message.brew_id && host_sessions[i].shot_id == message.shot_id {
				pane_id = host_sessions[i].pane_id
				break
			}
		}

		if pane_id != "" {
			host_pane_unpin(pane_id)
			host_pane_mark_terminal(pane_id)
		}

	case "pulled", "taste_failed", "incomplete", "session_failed":
		host_release_session(message.brew_id, message.shot_id, message.kind)
	}
}

// Records the identity a Station reported about itself and drops its spooled copy; it is
// not a user-facing report. A malformed or unknown report leaves the session unrecorded.
host_record_station_pid :: proc(message: Activity_Message) {
	if identity, agent_pid, ok := parse_station_pid(message.description); ok {
		for i in 0..<len(host_sessions) {
			if host_sessions[i].request_id == message.brew_id && host_sessions[i].shot_id == message.shot_id {
				host_sessions[i].station = identity
				host_sessions[i].agent_pid = agent_pid
				break
			}
		}
	}
	if message.spool != "" {
		spool_path, _ := filepath.join({host_history_root, STATION_SPOOL_DIR_NAME, message.spool}, context.temp_allocator)
		_ = os.remove(spool_path)
	}
}

// The reported Station pid, or 0 if it never reported or that process is no longer the
// one that reported (pid reuse: the start time differs).
session_station_pid :: proc(session: Host_Session) -> int {
	if session.station.pid > 0 && identity_liveness(session.station) == .Alive {
		return session.station.pid
	}
	return 0
}

HOST_SAMPLE_INTERVAL :: 2 * time.Second
host_last_sample: time.Tick

// Instrumentation only: samples every live session at most once per interval, so
// the recorded value is a peak over the Station's life.
host_sample_sessions_throttled :: proc() {
	if len(host_sessions) == 0 || time.tick_since(host_last_sample) < HOST_SAMPLE_INTERVAL {
		return
	}
	host_last_sample = time.tick_now()
	for session in host_sessions {
		host_sample_session(session)
	}
}

// Finds the Station's pid from its own arguments (no herdr call, no child process) and folds
// one reading into <state>/host/<request>/workers/<shot>.resource. Never waits on anything.
// A Station that cannot be found adds nothing: unknown stays unknown.
host_sample_session :: proc(session: Host_Session) {
	state_root, err := default_state_root(context.temp_allocator)
	if err != "" {
		return
	}
	_ = sample_station(state_root, session.request_id, session.shot_id, session_station_pid(session))
}

// Ends a Shot's session: frees its pane and machine slot, then starts queued Shots.
// Used by a terminal report, process_gone, and a Station found gone with no report.
host_release_session :: proc(request_id, shot_id, kind: string) {
	pane_id := ""
	for session in host_sessions {
		if session.request_id == request_id && session.shot_id == shot_id {
			host_sample_session(session) // last look before the pane is reclaimed
			break
		}
	}
	for i in 0..<len(host_sessions) {
		if host_sessions[i].request_id == request_id && host_sessions[i].shot_id == shot_id {
			delete(host_sessions[i].request_id)
			delete(host_sessions[i].shot_id)
			pane_id = strings.clone(host_sessions[i].pane_id, context.temp_allocator)
			delete(host_sessions[i].pane_id)
			unordered_remove(&host_sessions, i)
			break
		}
	}
	if pane_id == "" {
		return
	}
	progress_supervision_finish(request_id, shot_id)
	host_pane_mark_terminal(pane_id)
	state_root, _ := default_state_root(context.temp_allocator)
	_, _ = host_report_make_durable(state_root, request_id, shot_id, kind)
	if pane_backend_is_headless() {
		// The Station is done: reap it and free its session. No clearing, no reuse.
		surface := session_surface_open(host_herdr_exe)
		_ = surface.ops.tab_close(surface, pane_id)
	} else if !pane_prepare_for_reuse(session_surface_open(host_herdr_exe), host_pane_pool.workspace_id, pane_id) {
		when ODIN_DEBUG {
			log.warnf("host_release_session: pane clear failed for %s", pane_id)
		}
	}
	if !host_pane_reclaim(pane_id) {
		when ODIN_DEBUG {
			log.warnf("host_release_session: pane reclaim failed for %s", pane_id)
		}
	}
	dequeued := host_dispatch_dequeue_shots()
	defer delete(dequeued)
	host_retry_dequeued_shots(dequeued[:], state_root)
	for shot in dequeued {
		host_dispatch_queued_shot_destroy(shot)
	}
}

// A Station that reported agent_exited and whose process is gone, with no terminal
// report, will never report again: release it. A pinned (needs_input) pane is never
// released here; only a reply or cancel unpins it.
host_reap_gone_sessions :: proc(commands: []Process_Command) -> int {
	gone := make([dynamic][2]string, 0, 4, context.temp_allocator)
	for session in host_sessions {
		if !session.exited || host_pane_is_pinned(session.pane_id) {
			continue
		}
		if host_station_is_live(commands, session.request_id, session.shot_id) {
			continue
		}
		append(&gone, [2]string{strings.clone(session.request_id, context.temp_allocator), strings.clone(session.shot_id, context.temp_allocator)})
	}
	for pair in gone {
		host_release_session(pair[0], pair[1], "agent_exited")
	}
	return len(gone)
}

// Process liveness comes from pr.odin's process enumeration (--brew/--station argv).
host_station_is_live :: proc(commands: []Process_Command, request_id, shot_id: string) -> bool {
	for station in live_stations(commands, request_id) {
		if station.shot_id == shot_id {
			return true
		}
	}
	return false
}

host_pane_is_pinned :: proc(pane_id: string) -> bool {
	idx, found := pane_pool_find(&host_pane_pool, pane_id)
	return found && host_pane_pool.panes[idx].state == .WAITING_FOR_HUMAN
}

host_any_session_exited :: proc() -> bool {
	for session in host_sessions {
		if session.exited {
			return true
		}
	}
	return false
}

// Relays every report a Station spooled that no host relayed, oldest first. It runs
// once at start, before any Station of this host exists, so it never races a live
// relay. An unreadable entry stays on disk for inspection.
host_recover_spool :: proc() {
	spool_dir, _ := filepath.join({host_history_root, STATION_SPOOL_DIR_NAME}, context.allocator)
	defer delete(spool_dir)
	entries, read_err := os.read_all_directory_by_path(spool_dir, context.temp_allocator)
	if read_err != nil {
		return
	}
	names: [dynamic]string // outlives the free_all below
	defer {
		for name in names {
			delete(name)
		}
		delete(names)
	}
	for entry in entries {
		if entry.type == .Regular && strings.has_suffix(entry.name, ".json") {
			append(&names, strings.clone(entry.name))
		}
	}
	slice.sort(names[:])
	for name in names {
		path, _ := filepath.join({spool_dir, name}, context.temp_allocator)
		data, file_err := os.read_entire_file(path, context.temp_allocator)
		message: Activity_Message
		if file_err != nil || json.unmarshal(data, &message, .JSON, context.temp_allocator) != nil || !activity_valid_message(message) || message.spool != name {
			continue
		}
		host_relay_message(message)
		free_all(context.temp_allocator)
	}
}

// Appends one stdin read to the accumulator and handles every complete line in it.
// A read may carry several lines or half of one; only a newline releases a line.
// Returns true when a handled line asked the host to stop.
host_stdin_consume :: proc(line: ^Host_Line, chunk: []u8) -> bool {
	for byte in chunk {
		if byte == '\n' {
			if line.discarding {
				host_emit_overlong(line.dropped)
				line.discarding = false
				line.dropped = 0
				line.len = 0
				continue
			}
			stop := host_handle_stdin_line(host_line_text(line))
			line.len = 0
			if stop {
				return true
			}
			continue
		}
		if line.discarding {
			line.dropped += 1
			continue
		}
		if line.len == HOST_LINE_MAX {
			line.discarding = true
			line.dropped = line.len + 1
			line.len = 0
			continue
		}
		line.data[line.len] = byte
		line.len += 1
	}
	return false
}

// End of input. A pending line that never got its newline is still a request; a
// pending overlong line reports its limit error. Either way the loop then stops.
host_stdin_finish :: proc(line: ^Host_Line) {
	if line.discarding {
		host_emit_overlong(line.dropped)
		return
	}
	if line.len == 0 {
		return
	}
	_ = host_handle_stdin_line(host_line_text(line))
}

// The line as the scanner yielded it: without the newline and without one trailing
// carriage return.
host_line_text :: proc(line: ^Host_Line) -> string {
	text := string(line.data[:line.len])
	if strings.has_suffix(text, "\r") {
		text = text[:len(text) - 1]
	}
	return text
}

// One received event per line, emitted before the line is handled. Returns true
// when the host must stop.
host_handle_stdin_line :: proc(text: string) -> bool {
	host_emit_received(text)
	stop := host_handle_line(text)
	free_all(context.temp_allocator)
	return stop
}

// Request-socket intake. Only `reply` with exactly its four fields is accepted, so
// nothing in a socket request can name a repo, command, path or shell. It reaches
// the same host_reply as the stdin path; "" means delivered, else the reason.
host_handle_request_line :: proc(text: string) -> string {
	host_emit_received(text)
	value, parse_err := json.parse_string(text, .JSON, false, context.temp_allocator)
	if parse_err != .None {
		return "invalid json"
	}
	root, is_object := value.(json.Object)
	if !is_object {
		return "request must be an object"
	}
	if type_name, _ := root["type"].(json.String); type_name != "reply" {
		return "the request socket accepts only reply requests"
	}
	for key in root {
		if key != "type" && key != "request_id" && key != "shot_id" && key != "message" {
			return fmt.tprintf("unexpected field %q", key)
		}
	}
	request_id := host_request_id(root)
	if request_id == "" {
		return "request_id must be a valid shot-style identifier (letters, digits, - or _, up to 64)"
	}
	return host_reply(root, request_id)
}

// The line limit is a protocol guard, not a fatal error: name the limit and the
// byte count, drop the rest of the line, and keep serving.
host_emit_overlong :: proc(bytes: int) {
	host_emit(Host_Event{type = "error", reason = fmt.tprintf("stdin line of %d bytes exceeds the %d-byte limit", bytes, HOST_LINE_MAX)})
	free_all(context.temp_allocator)
}

// A Station sends a long report as "file:<path>". Only regular files resolved
// under this host's real reports directory are read; anything else is refused.
host_report_text :: proc(description: string) -> string {
	if !strings.has_prefix(description, STATION_FILE_PREFIX) {
		return description
	}
	path := description[len(STATION_FILE_PREFIX):]
	reports_dir, _ := filepath.join({host_history_root, "reports"}, context.temp_allocator)
	reports_real, reports_err := os.get_absolute_path(reports_dir, context.temp_allocator)
	file_info, info_err := os.lstat(path, context.temp_allocator)
	if reports_err != nil || info_err != nil || file_info.type != .Regular {
		return fmt.tprintf("Report location refused: %s", path)
	}
	resolved, resolve_err := os.get_absolute_path(path, context.temp_allocator)
	inside := resolve_err == nil && strings.has_prefix(resolved, reports_real) &&
		len(resolved) > len(reports_real) && resolved[len(reports_real)] == '/'
	if !inside || strings.contains(path, "..") {
		return fmt.tprintf("Report location refused: %s", path)
	}
	data, err := os.read_entire_file(resolved, context.temp_allocator)
	if err != nil {
		return fmt.tprintf("Report file could not be read: %s", path)
	}
	return string(data)
}

host_acquire_lock :: proc(directory: string) -> (file: ^os.File, ok: bool) {
	path := state_file_path(directory, HOST_LOCK_FILE_NAME, context.temp_allocator)
	opened, open_err := os.open(path, os.O_RDWR|os.O_CREATE, private_file_permissions())
	if open_err != nil {
		return nil, false
	}
	if !server_lock_try(opened) {
		_ = os.close(opened)
		return nil, false
	}
	return opened, true
}

// One received event per line, emitted before the line is handled. The request
// id is empty unless the line parses as an object with a valid one; a malformed
// line still reports its byte length rather than failing the loop.
host_emit_received :: proc(line: string) {
	request_id := ""
	value, parse_err := json.parse_string(line, .JSON, false, context.temp_allocator)
	if parse_err == .None {
		if root, is_object := value.(json.Object); is_object {
			request_id = host_request_id(root)
		}
	}
	host_emit(Host_Event{type = "received", request_id = request_id, bytes = len(line)})
}

// Returns true when the host must stop.
host_handle_line :: proc(line: string) -> bool {
	value, parse_err := json.parse_string(line, .JSON, false, context.temp_allocator)
	if parse_err != .None {
		host_write_line(`{"type":"error","reason":"invalid json"}`)
		return false
	}
	defer json.destroy_value(value, context.temp_allocator)

	root, is_object := value.(json.Object)
	if !is_object {
		host_write_line(`{"type":"error","reason":"request must be an object"}`)
		return false
	}

	type_name, _ := root["type"].(json.String)
	if type_name == "sessions" {
		host_list_sessions()
		return false
	}

	request_id := host_request_id(root)
	if request_id == "" {
		host_write_line(`{"type":"error","reason":"request_id must be a valid shot-style identifier (letters, digits, - or _, up to 64)"}`)
		return false
	}

	switch type_name {
	case "cancel":
		host_cancel(root, request_id)
	case "dispatch":
		host_dispatch(root, request_id)
	case "reply":
		host_reply(root, request_id)
	case "blend":
		host_blend(root, request_id)
	case "shutdown":
		host_write_line(fmt.tprintf(`{{"type":"stopped","request_id":"%s"}}`, request_id))
		return true
	case:
		host_emit(Host_Event{type = "error", request_id = request_id, reason = "unknown request type"})
	}
	return false
}

// Validates the dispatch, then starts one interactive Pi session per Shot: a
// Station (Git worktree) and a Herdr tab, with the Shot's prompt read from a
// file by the Station. Each Shot ends in session_started or session_failed.
// shortcut: the host blocks while sessions start; phase D relays reports but
// replies are not yet routed back from the host.
host_dispatch :: proc(root: json.Object, request_id: string) {
	span_begin("dispatch request")
	defer span_end()
	repo, repo_ok := host_string(root, "repo")
	if !repo_ok || !filepath.is_abs(repo) {
		host_emit(Host_Event{type = "error", request_id = request_id, reason = "repo must be an absolute path"})
		return
	}
	valid, repo_err := is_git_repository(repo, context.temp_allocator)
	if repo_err != "" || !valid {
		host_emit(Host_Event{type = "error", request_id = request_id, reason = "repo is not a Git repository"})
		return
	}

	recipe, recipe_ok := root["recipe"].(json.Object)
	shots_value, shots_found := recipe["shots"]
	shots, shots_ok := shots_value.(json.Array)
	if !recipe_ok || !shots_found || !shots_ok || len(shots) == 0 {
		host_emit(Host_Event{type = "error", request_id = request_id, reason = "recipe needs at least one shot"})
		return
	}

	ids := make([dynamic]string, context.temp_allocator)
	prompts := make([dynamic]string, context.temp_allocator)
	models := make([dynamic]string, context.temp_allocator)
	providers := make([dynamic]string, context.temp_allocator)
	thinkings := make([dynamic]string, context.temp_allocator)
	kinds := make([dynamic]string, context.temp_allocator)
	runtimes := make([dynamic]string, context.temp_allocator)
	tastes := make([dynamic]string, context.temp_allocator)
	messages := make([dynamic]string, context.temp_allocator)
	options := make([dynamic]Shot_Options, context.temp_allocator)
	for shot_value in shots {
		shot, is_shot := shot_value.(json.Object)
		id, id_ok := host_string(shot, "id")
		prompt, prompt_ok := host_string(shot, "prompt")
		if !is_shot || !id_ok || !valid_shot_id(id) || !prompt_ok || strings.trim_space(prompt) == "" {
			host_emit(Host_Event{type = "error", request_id = request_id, reason = "each shot needs a valid id and a prompt"})
			return
		}
		for existing in ids {
			if existing == id {
				host_emit(Host_Event{type = "error", request_id = request_id, reason = "shot ids must be unique"})
				return
			}
		}
		model := ""
		if model_value, model_found := shot["model"]; model_found {
			model_ok := false
			model, model_ok = model_value.(json.String)
			if !model_ok || !valid_host_model(model) {
				host_emit(Host_Event{type = "error", request_id = request_id, shot_id = id, reason = "shot model must be 1 to 80 characters using letters, digits, /, ., -, _, or :"})
				return
			}
		}
		thinking := ""
		if thinking_value, thinking_found := shot["thinking"]; thinking_found {
			thinking_ok := false
			thinking, thinking_ok = thinking_value.(json.String)
			if !thinking_ok || !valid_thinking(thinking) {
				host_emit(Host_Event{type = "error", request_id = request_id, shot_id = id, reason = "shot thinking must be off, minimal, low, medium, high, xhigh, or max"})
				return
			}
		}
		kind := SHOT_KIND_EXECUTE
		if kind_value, kind_found := shot["kind"]; kind_found {
			kind_ok := false
			kind, kind_ok = kind_value.(json.String)
			if !kind_ok || !valid_shot_kind(kind) {
				host_emit(Host_Event{type = "error", request_id = request_id, shot_id = id, reason = "shot kind must be execute or research"})
				return
			}
		}
		runtime := SHOT_RUNTIME_PI
		if runtime_value, runtime_found := shot["runtime"]; runtime_found {
			runtime_ok := false
			runtime, runtime_ok = runtime_value.(json.String)
			if !runtime_ok || !valid_shot_runtime(runtime) {
				host_emit(Host_Event{type = "error", request_id = request_id, shot_id = id, reason = "shot runtime must be pi or oreo"})
				return
			}
		}
		provider := ""
		if runtime == SHOT_RUNTIME_OREO {
			if kind != SHOT_KIND_EXECUTE {
				host_emit(Host_Event{type = "error", request_id = request_id, shot_id = id, reason = "oreo runtime requires an execute Shot"})
				return
			}
			route_provider, route_model, route_ok := host_oreo_model_route(model)
			if !route_ok {
				host_emit(Host_Event{type = "error", request_id = request_id, shot_id = id, reason = "oreo requires a valid provider/model pair"})
				return
			}
			provider = route_provider
			model = route_model
			if thinking == "" {
				host_emit(Host_Event{type = "error", request_id = request_id, shot_id = id, reason = "oreo requires an explicit thinking level"})
				return
			}
		}
		taste, message, taste_reason := host_shot_taste(shot, kind)
		if taste_reason != "" {
			host_emit(Host_Event{type = "error", request_id = request_id, shot_id = id, reason = taste_reason})
			return
		}

		shot_options, options_reason := host_shot_options(shot)
		if options_reason != "" {
			host_emit(Host_Event{type = "error", request_id = request_id, shot_id = id, reason = options_reason})
			return
		}

		append(&options, shot_options)
		append(&ids, id)
		append(&prompts, prompt)
		append(&models, model)
		append(&providers, provider)
		append(&thinkings, thinking)
		append(&kinds, kind)
		append(&runtimes, runtime)
		append(&tastes, taste)
		append(&messages, message)
	}

	owned_repo, _ := strings.clone(repo, context.allocator)
	defer delete(owned_repo)
	owned_request_id, _ := strings.clone(request_id, context.allocator)
	defer delete(owned_request_id)
	owned_ids := host_clone_string_slice(ids[:])
	defer host_delete_string_slice(owned_ids)
	owned_prompts := host_clone_string_slice(prompts[:])
	defer host_delete_string_slice(owned_prompts)
	owned_models := host_clone_string_slice(models[:])
	defer host_delete_string_slice(owned_models)
	owned_providers := host_clone_string_slice(providers[:])
	defer host_delete_string_slice(owned_providers)
	owned_thinkings := host_clone_string_slice(thinkings[:])
	defer host_delete_string_slice(owned_thinkings)
	owned_kinds := host_clone_string_slice(kinds[:])
	defer host_delete_string_slice(owned_kinds)
	owned_runtimes := host_clone_string_slice(runtimes[:])
	defer host_delete_string_slice(owned_runtimes)
	owned_tastes := host_clone_string_slice(tastes[:])
	defer host_delete_string_slice(owned_tastes)
	owned_messages := host_clone_string_slice(messages[:])
	defer host_delete_string_slice(owned_messages)

	host_emit(Host_Event{type = "dispatch_accepted", request_id = owned_request_id})
	host_start_sessions_owned(owned_repo, owned_request_id, owned_ids, owned_prompts, owned_models, owned_providers, owned_thinkings, owned_kinds, owned_runtimes, owned_tastes, owned_messages, options[:])
}

// Per-Shot dispatch options. Absent fields keep today's behaviour: not interactive,
// codemode on. Construct with codemode = true unless the Shot turned it off.
Shot_Options :: struct {
	interactive: bool,
	codemode:    bool,
}

// Queued Shots live in host_dispatch_queue, which has no options field, so a queued
// Shot's options wait here until it launches.
host_queued_options: map[string]Shot_Options

host_queued_options_remember :: proc(request_id, shot_id: string, options: Shot_Options) {
	host_queued_options[fmt.aprintf("%s/%s", request_id, shot_id)] = options
}

host_queued_options_take :: proc(request_id, shot_id: string) -> Shot_Options {
	key := fmt.tprintf("%s/%s", request_id, shot_id)
	stored_key, options := delete_key(&host_queued_options, key)
	if stored_key == "" {
		return Shot_Options{codemode = true}
	}
	delete(stored_key)
	return options
}

host_shot_options :: proc(shot: json.Object) -> (options: Shot_Options, reason: string) {
	options.codemode = true
	if value, found := shot["interactive"]; found {
		ok := false
		options.interactive, ok = value.(json.Boolean)
		if !ok {
			return {}, "shot interactive must be true or false"
		}
	}
	if value, found := shot["codemode"]; found {
		ok := false
		options.codemode, ok = value.(json.Boolean)
		if !ok {
			return {}, "shot codemode must be true or false"
		}
	}
	return options, ""
}

// A Shot with a taste is a Pull: it needs a commit message, and only an execute Shot
// may commit. Both are checked here, before any worktree or Herdr call.
host_shot_taste :: proc(shot: json.Object, kind: string) -> (taste, message, reason: string) {
	taste_value, taste_found := shot["taste"]
	message_value, message_found := shot["message"]
	if !taste_found {
		if message_found {
			return "", "", "shot message needs a taste"
		}
		return "", "", ""
	}
	taste_ok := false
	taste, taste_ok = taste_value.(json.String)
	if !taste_ok || !valid_shot_taste(taste) {
		return "", "", "shot taste must be a command of 1 to 512 characters on one line"
	}
	if kind != SHOT_KIND_EXECUTE {
		return "", "", "shot taste needs an execute kind"
	}
	message_ok := false
	if message_found {
		message, message_ok = message_value.(json.String)
	}
	if !message_ok || !valid_commit_message(message) {
		return "", "", "shot message is required with a taste and must be 1 to 200 characters on one line"
	}
	return taste, message, ""
}

HOST_TASTE_MAX :: 512
HOST_COMMIT_MESSAGE_MAX :: 200

valid_shot_taste :: proc(taste: string) -> bool {
	return strings.trim_space(taste) != "" && strings.rune_count(taste) <= HOST_TASTE_MAX && !strings.contains_any(taste, "\r\n")
}

valid_commit_message :: proc(message: string) -> bool {
	return strings.trim_space(message) != "" && strings.rune_count(message) <= HOST_COMMIT_MESSAGE_MAX && !strings.contains_any(message, "\r\n")
}

// shortcut: Shot tabs are not closed when a Shot finishes, so a repository's workspace keeps every tab; close each tab when its Shot ends, once Shots report completion through the host.
// Every Shot prompt starts with this line, so agent replies stay short.
HOST_REPLY_STYLE :: "Keep replies concise: lead with the answer, use short lists, and skip restating the question and filler."

host_clone_string_slice :: proc(values: []string) -> []string {
	owned := make([]string, len(values), context.allocator)
	for value, index in values {
		owned[index], _ = strings.clone(value, context.allocator)
	}
	return owned
}

host_delete_string_slice :: proc(values: []string) {
	for value in values {
		delete(value)
	}
	delete(values)
}

host_start_sessions_owned :: proc(repo, request_id: string, ids, prompts, models, providers, thinkings, kinds, runtimes, tastes, messages: []string, options: []Shot_Options) {
	if _, launch_err := child_launch_argv(host_station_executable); launch_err != "" {
		for id in ids {
			host_session_failed(request_id, id, launch_err)
		}
		return
	}

	state_root, state_err := default_state_root(context.allocator)
	defer delete(state_root)
	if state_err != "" {
		for id in ids {
			host_session_failed(request_id, id, state_err)
		}
		return
	}
	prompts_dir, _ := filepath.join({state_root, "host", request_id, "prompts"}, context.allocator)
	defer delete(prompts_dir)
	if os.make_directory_all(prompts_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		for id in ids {
			host_session_failed(request_id, id, "could not create the prompts directory")
		}
		return
	}
	stations_dir, _ := filepath.join({state_root, "host", request_id, "stations"}, context.allocator)
	defer delete(stations_dir)
	if os.make_directory_all(stations_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		for id in ids {
			host_session_failed(request_id, id, "could not create the Stations directory")
		}
		return
	}

	herdr := "herdr"
	for id, i in ids {
		prompt_name := fmt.aprintf("%s.md", id)
		defer delete(prompt_name)
		prompt_path, _ := filepath.join({prompts_dir, prompt_name}, context.allocator)
		defer delete(prompt_path)
		prompt_text := fmt.tprintf("%s\n\n%s", HOST_REPLY_STYLE, prompts[i])
		if os.write_entire_file(prompt_path, prompt_text, private_file_permissions()) != nil {
			host_session_failed(request_id, id, "could not write the prompt file")
			continue
		}
		station, _ := filepath.join({stations_dir, id}, context.allocator)
		defer delete(station)
		branch := fmt.aprintf("cs-host-%s-%s", request_id, id)
		defer delete(branch)
		if git_err := create_git_worktree(repo, branch, station, context.temp_allocator); git_err != "" {
			host_session_failed(request_id, id, git_err)
			continue
		}

		// Try to acquire a pane from the pool (may queue if at capacity).
		pool_pane_id, queued, acquire_ok := host_dispatch_acquire(request_id, id)
		if !acquire_ok {
			host_session_failed(request_id, id, "dispatch pool error")
			continue
		}
		if queued {
			// Pane not available; Shot is queued for retry when pane reclaims.
			// Store full metadata now for auto-retry.
			host_dispatch_queue_store_metadata(request_id, id, repo, prompts[i], models[i], providers[i], thinkings[i], kinds[i], runtimes[i], tastes[i], messages[i], station)
			host_queued_options_remember(request_id, id, options[i])
			host_emit(Host_Event{type = "dispatch_queued", request_id = request_id, shot_id = id})
			continue
		}

		// Acquired pane; proceed with Station launch.
		pane_id, pane_err := host_open_shot_pane(herdr, state_root, repo, request_id, id, station)
		if pane_err != "" {
			host_pane_mark_terminal(pool_pane_id)
			_ = host_pane_reclaim(pool_pane_id)
			host_session_failed(request_id, id, pane_err)
			continue
		}
		if pane_err != "" {
			host_session_failed(request_id, id, pane_err)
			continue
		}

		launch, launch_err := child_launch_argv(host_station_executable)
		if launch_err != "" {
			host_pane_mark_terminal(pool_pane_id)
			_ = host_pane_reclaim(pool_pane_id)
			host_session_failed(request_id, id, launch_err)
			continue
		}
		extension := host_extension_path
		if runtimes[i] == SHOT_RUNTIME_OREO {
			extension = host_oreo_extension_path
		}
		launcher := child_shell_prefix(launch)
		command := host_spall_env_prefix(os.get_env(SPANS_ENV, context.temp_allocator), host_station_command(launcher, host_report_socket, extension, host_oreo_host_path, id, request_id, prompt_path, models[i], providers[i], thinkings[i], kinds[i], runtimes[i], tastes[i], messages[i], options[i]))
		if !host_station_command_is_ascii(command) {
			delete(command)
			host_pane_mark_terminal(pool_pane_id)
			_ = host_pane_reclaim(pool_pane_id)
			host_session_failed(request_id, id, "generated Station command contains non-ASCII bytes")
			continue
		}
		surface := session_surface_open(herdr)
		run_err := surface.ops.pane_run(surface, pane_id, command)
		delete(command)
		if run_err != "" {
			host_pane_mark_terminal(pool_pane_id)
			_ = host_pane_reclaim(pool_pane_id)
			host_session_failed(request_id, id, fmt.tprintf("could not start the Station: %s", run_err))
			continue
		}
		// Record session with pool-owned pane.
		append(&host_sessions, Host_Session{request_id = strings.clone(request_id), shot_id = strings.clone(id), pane_id = strings.clone(pool_pane_id)})
		host_emit(Host_Event{type = "session_started", request_id = request_id, shot_id = id, pane_id = pane_id})
		// Track in progress ledger.
		progress_supervision_add_station(request_id, id, pane_id)
		host_sample_session(host_sessions[len(host_sessions) - 1])
	}
}

// Opens the Shot's tab in the repository's workspace. The saved workspace is reused.
// If none is saved or Herdr rejects it, a new workspace is created and saved; its
// default tab then serves this Shot. A save that fails only warns: the Shot still runs.
host_open_shot_pane :: proc(herdr, state_root, repo, request_id, shot_id, station: string) -> (pane_id, err: string) {
	if pane_backend_is_headless() {
		// No workspace or tab: the Shot gets a session whose log is under this request.
		surface := session_surface_open(herdr)
		opened, open_err := surface.ops.tab_create(surface, request_id, shot_id, station, context.temp_allocator)
		return opened.pane_id, open_err
	}
	name := repository_name(repo)
	defer delete(name)
	workspaces_dir, _ := filepath.join({state_root, "host", "workspaces"}, context.temp_allocator)
	if os.make_directory_all(workspaces_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil && !os.exists(workspaces_dir) {
		return "", "could not create the Herdr workspaces directory"
	}
	saved_path := state_file_path(workspaces_dir, host_workspace_file_name(repo), context.temp_allocator)
	surface := session_surface_open(herdr)
	if saved_id := host_saved_workspace_id(saved_path); saved_id != "" {
		tab, tab_err := surface.ops.tab_create(surface, saved_id, shot_id, station, context.temp_allocator)
		if tab_err == "" {
			return tab.pane_id, ""
		}
	}
	workspace, herdr_err := surface.ops.workspace_create(surface, station, name, context.temp_allocator)
	if herdr_err != "" {
		return "", fmt.tprintf("Herdr workspace launch failed: %s", herdr_err)
	}
	if write_err := os.write_entire_file(saved_path, workspace.workspace_id, private_file_permissions()); write_err != nil {
		host_emit(Host_Event{type = "warning", request_id = request_id, shot_id = shot_id, reason = "could not save the workspace id; the next dispatch will create a new workspace"})
	}
	// Initialize pool with actual workspace ID on first workspace creation.
	if host_pane_pool.workspace_id == "" || host_pane_pool.workspace_id == "ws-host-default" {
		host_pane_pool.workspace_id = strings.clone(workspace.workspace_id, context.allocator)
	}
	if rename_err := surface.ops.tab_rename(surface, workspace.tab_id, shot_id); rename_err != "" {
		return "", fmt.tprintf("Herdr could not label the Shot tab: %s", rename_err)
	}
	return workspace.pane_id, ""
}

// Keyed by the full repository path, so two repositories with the same name never
// share a workspace. The name part keeps the file readable; both parts are filesystem-safe.
host_workspace_file_name :: proc(repo: string) -> string {
	name := repository_name(repo)
	defer delete(name)
	digest := hash.hash_string(.SHA256, repo, context.temp_allocator)
	digest_hex, _ := hex.encode(digest, context.temp_allocator)
	return fmt.tprintf("%s-%s.txt", name, string(digest_hex))
}

// A missing or unreadable file means no workspace is saved for the repository.
host_saved_workspace_id :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return strings.trim_space(string(data))
}

// Cancels running Stations. A named shot_id signals just that Station; an omitted
// shot_id signals every Station. Only a recorded positive PID is signalled with
// SIGTERM, so the Station's own handler closes the agent's input; nothing is
// killed and no Herdr pane is closed.
host_cancel :: proc(root: json.Object, request_id: string) {
	shot_id, has_shot := host_string(root, "shot_id")
	if has_shot && !valid_shot_id(shot_id) {
		host_emit(Host_Event{type = "error", request_id = request_id, reason = "cancel needs a valid shot_id"})
		return
	}
	if !has_shot {
		if len(host_sessions) == 0 {
			host_emit(Host_Event{type = "cancelled", request_id = request_id, reason = "no Stations are running"})
			return
		}
		for session in host_sessions {
			host_cancel_session(request_id, session)
		}
		return
	}
	matched := false
	for session in host_sessions {
		if session.shot_id != shot_id {
			continue
		}
		matched = true
		host_cancel_session(request_id, session)
	}
	if !matched {
		host_emit(Host_Event{type = "cancelled", request_id = request_id, shot_id = shot_id, reason = "no Station is running for that shot"})
	}
}

// A positive PID the Station reported (else the pane reports now) is asked to stop. A missing or unreadable identity
// is not an error; it is reported as a reason instead of a signal.
host_cancel_session :: proc(request_id: string, session: Host_Session) {
	// The Station's own report first; the pane's foreground (read at cancel time, and only
	// the Station once it is running) is the fallback for one that never reported.
	identity := session.station
	if session_station_pid(session) == 0 {
		identity = host_pane_identity("herdr", session.pane_id)
	}
	if identity.pid > 0 {
		stop_worker_gracefully(identity)
		host_emit(Host_Event{type = "cancelled", request_id = request_id, shot_id = session.shot_id})
		return
	}
	host_emit(Host_Event{type = "cancelled", request_id = request_id, shot_id = session.shot_id, reason = "the Station process could not be identified"})
}

// The foreground process group Herdr reports for the pane is the Station the
// pane's shell started. A pane whose command has not started yet reports the
// shell itself, which is not the Station, and a missing or unreadable answer
// leaves the identity unknown rather than guessing.
host_pane_identity :: proc(herdr, pane_id: string) -> Process_Identity {
	surface := session_surface_open(herdr)
	return surface.ops.pane_process_info(surface, pane_id)
}

// Types a reply into a Station's pane. The Station reads it from stdin and either
// answers the agent's pending dialog or sends it as a follow-up prompt.
host_reply :: proc(root: json.Object, request_id: string) -> (reason: string) {
	shot_id, shot_ok := host_string(root, "shot_id")
	message, message_ok := host_string(root, "message")
	if !shot_ok || !valid_shot_id(shot_id) {
		reason = "reply needs a valid shot_id"
		host_emit(Host_Event{type = "error", request_id = request_id, reason = reason})
		return reason
	}
	message = strings.trim_space(message)
	if !message_ok || message == "" || len(message) > HOST_REPLY_MAX || strings.contains_any(message, "\r\n") {
		reason = "reply must be one non-empty line"
		host_emit(Host_Event{type = "error", request_id = request_id, shot_id = shot_id, reason = reason})
		return reason
	}
	for session in host_sessions {
		if session.request_id == request_id && session.shot_id == shot_id {
			surface := session_surface_open(host_herdr_exe)
			if err := surface.ops.pane_run(surface, session.pane_id, message); err != "" {
				reason = fmt.tprintf("could not send the reply: %s", err)
				host_emit(Host_Event{type = "error", request_id = request_id, shot_id = shot_id, reason = reason})
				return reason
			}
			host_emit(Host_Event{type = "reply_sent", request_id = request_id, shot_id = shot_id})
			return ""
		}
	}
	reason = "no Station is running for that shot"
	host_emit(Host_Event{type = "error", request_id = request_id, shot_id = shot_id, reason = reason})
	return reason
}

// Herdr's command argument is ASCII-only; checking the encoded bytes also catches
// a command invalidated by a temporary-allocation lifetime error.
host_station_command_is_ascii :: proc(command: string) -> bool {
	for index in 0 ..< len(command) {
		if command[index] > 0x7f {
			return false
		}
	}
	return true
}

// The Station runs in the Herdr pane and launches the agent. Paths and the
// optional model and thinking level are quoted; the IDs are already restricted
// to safe characters.
// A research Shot gets scratch-write tools; the Station then checks that it left the source as it found it.
// A Pull passes its taste and message to the Station, which commits only if the taste passes.
// Herdr panes do not inherit the host's environment, so pass the trace base on the
// command line; each Station then writes "<base>.<station id>.<pid>".
host_spall_env_prefix :: proc(base, command: string) -> string {
	if base == "" {
		return command
	}
	defer delete(command)
	quoted := shell_quote(base)
	defer delete(quoted)
	return fmt.aprintf("%s=%s %s", SPANS_ENV, quoted, command)
}

host_station_command :: proc(launcher, report, extension, oreo_host, shot_id, request_id, prompt_file, model, provider, thinking, kind, runtime, taste, message: string, options := Shot_Options{codemode = true}) -> string {
	quoted_report := shell_quote(report)
	defer delete(quoted_report)
	quoted_extension := shell_quote(extension)
	defer delete(quoted_extension)
	quoted_prompt_file := shell_quote(prompt_file)
	defer delete(quoted_prompt_file)
	model_argument := ""
	if model != "" {
		quoted_model := shell_quote(model)
		defer delete(quoted_model)
		model_argument = fmt.aprintf(" --model %s", quoted_model)
	}
	thinking_argument := ""
	if thinking != "" {
		quoted_thinking := shell_quote(thinking)
		defer delete(quoted_thinking)
		thinking_argument = fmt.aprintf(" --thinking %s", quoted_thinking)
	}
	tools_argument := ""
	if kind == SHOT_KIND_RESEARCH {
		tools_argument = " --tools read,grep,find,ls,write,codemode"
	} else if options.codemode {
		tools_argument = " --tools +codemode"
	}
	options_argument := ""
	if options.interactive {
		options_argument = " --interactive"
	}
	if !options.codemode {
		options_argument = fmt.tprintf("%s --codemode false", options_argument)
	}
	taste_argument := ""
	if taste != "" {
		quoted_taste := shell_quote(taste)
		defer delete(quoted_taste)
		quoted_message := shell_quote(message)
		defer delete(quoted_message)
		taste_argument = fmt.aprintf(" --taste %s --message %s", quoted_taste, quoted_message)
	}
	command := ""
	if runtime == SHOT_RUNTIME_OREO {
		quoted_oreo_host := shell_quote(oreo_host)
		defer delete(quoted_oreo_host)
		quoted_provider := shell_quote(provider)
		defer delete(quoted_provider)
		quoted_model := shell_quote(model)
		defer delete(quoted_model)
		quoted_thinking := shell_quote(thinking)
		defer delete(quoted_thinking)
		command = fmt.aprintf("%s station --kind %s --report %s --station %s --brew %s --prompt-file %s%s%s -- env OREO_HOST=%s OREO_PROVIDER=%s OREO_MODEL=%s OREO_THINKING=%s OREO_SESSION_ID=%s pi --mode rpc --no-tools --no-mcp --no-extensions --model '%s/%s' --thinking %s -e %s", launcher, kind, quoted_report, shot_id, request_id, quoted_prompt_file, taste_argument, options_argument, quoted_oreo_host, quoted_provider, quoted_model, quoted_thinking, shot_id, provider, model, thinking, quoted_extension)
	} else {
		command = fmt.aprintf("%s station --kind %s --report %s --station %s --brew %s --prompt-file %s%s%s -- pi --mode rpc%s%s%s -e %s", launcher, kind, quoted_report, shot_id, request_id, quoted_prompt_file, taste_argument, options_argument, tools_argument, model_argument, thinking_argument, quoted_extension)
	}
	if model_argument != "" {
		delete(model_argument)
	}
	if thinking_argument != "" {
		delete(thinking_argument)
	}
	if taste_argument != "" {
		delete(taste_argument)
	}
	return command
}

// A Blend request is validated in full before any Git call. Its repository and
// branch checks run next, and then blend_run does the work.
host_blend :: proc(root: json.Object, request_id: string) {
	request, reason := blend_parse(root)
	if reason == "" {
		reason = blend_check_repository(request)
	}
	if reason != "" {
		host_emit(Host_Event{type = "error", request_id = request_id, reason = reason})
		return
	}
	blend_run(request_id, request)
}

host_session_failed :: proc(request_id, shot_id, reason: string) {
	host_emit(Host_Event{type = "session_failed", request_id = request_id, shot_id = shot_id, reason = reason})
}

SHOT_KIND_EXECUTE :: "execute"
SHOT_KIND_RESEARCH :: "research"
SHOT_RUNTIME_PI :: "pi"
SHOT_RUNTIME_OREO :: "oreo"
// Research and review may write scratch files and run codemode; the Station or review checks the source.
SCRATCH_WRITE_TOOLS :: "read,grep,find,ls,write,codemode"

valid_shot_kind :: proc(kind: string) -> bool {
	return kind == SHOT_KIND_EXECUTE || kind == SHOT_KIND_RESEARCH
}

valid_shot_runtime :: proc(runtime: string) -> bool {
	return runtime == SHOT_RUNTIME_PI || runtime == SHOT_RUNTIME_OREO
}

host_oreo_model_route :: proc(route: string) -> (provider, model: string, ok: bool) {
	separator := strings.index_byte(route, '/')
	if separator <= 0 || separator == len(route)-1 || strings.index_byte(route[separator+1:], '/') >= 0 {
		return "", "", false
	}
	provider = route[:separator]
	model = route[separator+1:]
	if !host_model_token(provider) || !host_model_token(model) {
		return "", "", false
	}
	return provider, model, true
}

host_model_token :: proc(token: string) -> bool {
	if len(token) == 0 || len(token) > 80 {
		return false
	}
	for c in token {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_' || c == ':' {
			continue
		}
		return false
	}
	return true
}

valid_host_model :: proc(model: string) -> bool {
	if len(model) < 1 || len(model) > 80 {
		return false
	}
	for c in model {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '/' || c == '.' || c == '-' || c == '_' || c == ':' {
			continue
		}
		return false
	}
	return true
}

// Every caller runs on the one loop thread, so stdout writes cannot interleave and
// need no lock.
host_emit :: proc(event: Host_Event) -> bool {
	data, err := json.marshal(event, {}, context.temp_allocator)
	if err != nil {
		host_write_line(`{"type":"error","reason":"could not encode event"}`)
		return false
	}

	if host_history_event(event) && !host_history_append(event, data) {
		return false
	}
	fmt.println(string(data))
	return true
}

host_write_line :: proc(line: string) {
	fmt.println(line)
}

host_string :: proc(object: json.Object, key: string) -> (string, bool) {
	value, found := object[key]
	if !found {
		return "", false
	}
	text, is_string := value.(json.String)
	return text, is_string
}

// The ID becomes a branch name, a path and an activity-socket field, so it uses
// the same rules as Shot IDs. Hyphens and underscores are allowed; dots are not.
host_request_id :: proc(root: json.Object) -> string {
	id, ok := host_string(root, "request_id")
	if !ok || !valid_shot_id(id) {
		return ""
	}
	return id
}

// Pool integration helpers wired into host dispatch and relay.

// Check if a report kind is terminal (work is done, pane can be reclaimed).
is_terminal_report :: proc(kind: string) -> bool {
	switch kind {
	case "pulled", "taste_failed", "incomplete", "session_failed":
		return true
	}
	return false
}

// Auto-retry queued Shots when a pane is reclaimed.
// Called from host_relay_message after dequeue, before emit.
host_retry_dequeued_shots :: proc(dequeued: []Queued_Shot, state_root: string) {
	herdr := host_herdr_exe
	for queued_shot in dequeued {
		req_id := queued_shot.request_id
		shot_id := queued_shot.shot_id
		pane_id := queued_shot.pane_id
		host_emit(Host_Event{type = "dispatch_dequeued", request_id = req_id, shot_id = shot_id})

		// Open pane (workspace tab).
		pane_from_herdr, pane_err := host_open_shot_pane(herdr, state_root, queued_shot.repo, req_id, shot_id, queued_shot.station_path)
		if pane_err != "" {
			host_pane_mark_terminal(pane_id)
			_ = host_pane_reclaim(pane_id)
			host_session_failed(req_id, shot_id, pane_err)
			continue
		}

		// Launch Station.
		launch, launch_err := child_launch_argv(host_station_executable)
		if launch_err != "" {
			host_pane_mark_terminal(pane_id)
			_ = host_pane_reclaim(pane_id)
			host_session_failed(req_id, shot_id, launch_err)
			continue
		}

		extension := host_extension_path
		if queued_shot.runtime == SHOT_RUNTIME_OREO {
			extension = host_oreo_extension_path
		}
		launcher := child_shell_prefix(launch)

		// Re-read prompt file (it was written during initial dispatch).
		prompt_name := fmt.aprintf("%s.md", shot_id)
		defer delete(prompt_name)
		prompts_dir, _ := filepath.join({state_root, "host", req_id, "prompts"}, context.temp_allocator)
		prompt_path, _ := filepath.join({prompts_dir, prompt_name}, context.temp_allocator)

		command := host_spall_env_prefix(os.get_env(SPANS_ENV, context.temp_allocator), host_station_command(launcher, host_report_socket, extension, host_oreo_host_path, shot_id, req_id, prompt_path, queued_shot.model, queued_shot.provider, queued_shot.thinking, queued_shot.kind, queued_shot.runtime, queued_shot.taste, queued_shot.message, host_queued_options_take(req_id, shot_id)))
		if !host_station_command_is_ascii(command) {
			delete(command)
			host_pane_mark_terminal(pane_id)
			_ = host_pane_reclaim(pane_id)
			host_session_failed(req_id, shot_id, "generated Station command contains non-ASCII bytes")
			continue
		}

		surface := session_surface_open(herdr)
		run_err := surface.ops.pane_run(surface, pane_from_herdr, command)
		delete(command)
		if run_err != "" {
			host_pane_mark_terminal(pane_id)
			_ = host_pane_reclaim(pane_id)
			host_session_failed(req_id, shot_id, fmt.tprintf("queued retry failed: %s", run_err))
			continue
		}

		// Record session with pool pane.
		append(&host_sessions, Host_Session{request_id = strings.clone(req_id), shot_id = strings.clone(shot_id), pane_id = strings.clone(pane_id)})
		host_emit(Host_Event{type = "session_started", request_id = req_id, shot_id = shot_id, pane_id = pane_from_herdr})

		when ODIN_DEBUG {
			log.infof("host_retry_dequeued_shots: relaunched %s/%s from queue", req_id, shot_id)
		}
	}
}
