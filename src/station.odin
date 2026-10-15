package main

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:terminal/ansi"
import "core:thread"
import "core:time"

// Station runs one agent session and relays between it and the parent Coffee
// Shop. The agent speaks the Pi RPC subset on stdin/stdout (prompt in, agent_end
// out), so Pi or Oreo can run here if it speaks the same subset.
//
// Lines typed into the Station's pane, or sent there by the host, are replies.
// A reply answers a pending dialog if the agent asked one; otherwise it is a
// follow-up prompt. Closing stdin ends the session.
// A research Shot and a Pull are one turn: the Station closes the agent's input
// after the first agent_end, so the agent exits and the post-exit checks run.
// shortcut: one report per turn and per dialog, truncated to the activity limit;
// dialog timeouts are not tracked, so a late answer can reach the next prompt.

Station_Prompt :: struct {
	type:              string `json:"type"`,
	message:           string `json:"message"`,
	streamingBehavior: string `json:"streamingBehavior,omitempty"`,
}

Dialog_Value_Response :: struct {
	type:  string `json:"type"`,
	id:    string `json:"id"`,
	value: string `json:"value"`,
}

Dialog_Confirm_Response :: struct {
	type:      string `json:"type"`,
	id:        string `json:"id"`,
	confirmed: bool `json:"confirmed"`,
}

Dialog_Cancel_Response :: struct {
	type:      string `json:"type"`,
	id:        string `json:"id"`,
	cancelled: bool `json:"cancelled"`,
}

// Asks Pi for its session stats. The Station sends it once, as the session ends.
Station_Stats_Request :: struct {
	type: string `json:"type"`,
}

// A dialog the agent is blocked on. Strings are owned.
Station_Dialog :: struct {
	active:  bool,
	id:      string,
	method:  string,
	options: []string,
}

// The mutex guards the dialog and the agent's input: a reply is written before the
// input is closed, or it is dropped. `agent_closed` is atomic because the reader
// thread and the main flow both consult it; the close itself is decided by
// station_close_file's atomic exchange on `agent`, so it happens once.
Station_Relay :: struct {
	input:        ^os.File,
	agent:        ^os.File,
	mutex:        sync.Mutex,
	dialog:       Station_Dialog,
	display:      ^Station_Display,
	one_turn:     bool,
	agent_closed: bool,
	cancelled:    bool,
	reader_done:  ^bool,
	// Turn deadline state; all atomic. A turn runs from a prompt to its agent_end.
	turn_active:      bool,
	last_output_ns:   i64,
	deadline_expired: bool,
	watchdog_stop:    bool,
}

// A turn with no agent output for this long is a provider that never replied: the
// Station kills the agent and fails the Shot. Pi streams while it generates, so
// quiet this long is not work in progress. Twice the 12-minute quiet mark of
// docs/architecture.md, so a long silent tool call is not mistaken for a hang.
// CS_STATION_TURN_DEADLINE_SECONDS overrides it, for tests.
// shortcut: only the agent process is killed, not children it spawned.
STATION_TURN_DEADLINE_SECONDS :: 1800
STATION_TURN_DEADLINE_ENV :: "CS_STATION_TURN_DEADLINE_SECONDS"

station_turn_deadline_seconds :: proc() -> int {
	text := os.get_env(STATION_TURN_DEADLINE_ENV, context.temp_allocator)
	if value, ok := strconv.parse_int(text); ok && value > 0 {
		return value
	}
	return STATION_TURN_DEADLINE_SECONDS
}

Station_Watchdog :: struct {
	relay:            ^Station_Relay,
	process:          os.Process,
	deadline_seconds: int,
}

// Kills the agent when a turn has had no output past the deadline. A pending dialog
// is waiting on a person, so it is exempt.
station_watchdog :: proc(data: rawptr) {
	watchdog := (^Station_Watchdog)(data)
	relay := watchdog.relay
	limit := i64(watchdog.deadline_seconds) * i64(time.Second)
	for !sync.atomic_load(&relay.watchdog_stop) {
		time.sleep(STATION_RELAY_POLL_MS * time.Millisecond)
		if !sync.atomic_load(&relay.turn_active) {
			continue
		}
		sync.mutex_lock(&relay.mutex)
		waiting := relay.dialog.active
		sync.mutex_unlock(&relay.mutex)
		if waiting {
			continue
		}
		if time.now()._nsec - sync.atomic_load(&relay.last_output_ns) < limit {
			continue
		}
		sync.atomic_store(&relay.deadline_expired, true)
		_ = os.process_kill(watchdog.process)
		return
	}
}

station_turn_started :: proc(relay: ^Station_Relay) {
	sync.atomic_store(&relay.last_output_ns, time.now()._nsec)
	sync.atomic_store(&relay.turn_active, true)
}

// The SIGTERM handler sets only this flag. It must never read the relay: the main
// flow frees the relay, so a handler on another thread could read freed memory.
// The reader polls this flag every STATION_RELAY_POLL_MS, and the main flow reads
// it at the point it decides the exit status.
station_cancel_requested: bool

STATION_CANCELLED_EXIT_CODE :: 130
STATION_RELAY_POLL_MS :: 100

// Closes a File once. The atomic exchange takes the pointer and clears the field in
// one step, so exactly one caller ever closes a given File and no caller can act on a
// pointer another thread has already freed. It takes no lock, so it cannot deadlock,
// including on a thread a signal handler was delivered to.
station_close_file :: proc(file: ^^os.File) {
	value := sync.atomic_exchange(file, nil)
	if value == nil {
		return
	}
	_ = os.close(value)
}

station_free_display :: proc(display: ^^Station_Display) {
	if display^ == nil {
		return
	}
	station_display_stop(display^)
	free(display^)
	display^ = nil
}

// The main flow owns all of shutdown, including the join, the cleanup and the
// exit status. Marking the relay cancelled wakes the polling reader on ordinary
// EOF paths too.
station_orderly_shutdown :: proc(relay_ptr: ^^Station_Relay, reader: ^thread.Thread) -> int {
	relay := relay_ptr^
	if relay == nil {
		return 0
	}
	cancelled_before := sync.atomic_load(&relay.cancelled)
	sync.atomic_store(&relay.cancelled, true)
	sync.atomic_store(&relay.agent_closed, true)
	if reader != nil {
		thread.join(reader)
		thread.destroy(reader)
	}
	sync.mutex_lock(&relay.mutex)
	station_dialog_clear(&relay.dialog)
	sync.mutex_unlock(&relay.mutex)
	station_free_display(&relay.display)
	station_close_file(&relay.input)
	station_close_file(&relay.agent)
	free(relay)
	relay_ptr^ = nil
	// Decide the status only now, so a cancel that arrived while shutdown was
	// running is not lost. A cancel can still arrive after this read.
	if cancelled_before || sync.atomic_load(&station_cancel_requested) {
		return STATION_CANCELLED_EXIT_CODE
	}
	return 0
}

run_station :: proc(report_path, station_id, brew_id, prompt, prompt_file, shot_kind, taste, message: string, agent: []string) -> int {
	first_prompt := prompt
	prompt_data: []byte
	if prompt_file != "" {
		read_err: os.Error
		prompt_data, read_err = os.read_entire_file(prompt_file, context.allocator)
		if read_err != nil {
			write_error("could not read the prompt file")
			return 1
		}
		first_prompt = string(prompt_data)
	}
	defer delete(prompt_data)
	sender, sender_ok := activity_sender_open(report_path)
	if !sender_ok {
		write_error("could not reach the parent Coffee Shop")
		return 1
	}
	defer activity_sender_close(&sender)

	base_head := strings.clone(station_head()) // the read loop frees the temp allocator
	defer delete(base_head)
	display := new(Station_Display)
	station_display_start(display, fmt.tprintf("Shot %s  ·  brew %s", station_id, brew_id))

	agent_in_read, agent_in_write, in_err := os.pipe()
	agent_out_read, agent_out_write, out_err := os.pipe()
	if in_err != nil || out_err != nil {
		station_close_file(&agent_in_read)
		station_close_file(&agent_in_write)
		station_close_file(&agent_out_read)
		station_close_file(&agent_out_write)
		station_free_display(&display)
		write_error("could not create the agent pipes")
		return 1
	}
	input, input_err := os.clone(os.stdin)
	if input_err != nil {
		station_close_file(&agent_in_read)
		station_close_file(&agent_in_write)
		station_close_file(&agent_out_read)
		station_close_file(&agent_out_write)
		station_free_display(&display)
		write_error("could not clone Station input")
		return 1
	}
	process, start_err := os.process_start(os.Process_Desc{
		command = agent,
		stdin = agent_in_read,
		stdout = agent_out_write,
		stderr = os.stderr,
	})
	station_close_file(&agent_in_read)
	station_close_file(&agent_out_write)
	if start_err != nil {
		station_close_file(&agent_in_write)
		station_close_file(&agent_out_read)
		station_close_file(&input)
		station_free_display(&display)
		write_error("could not start the agent")
		return 1
	}
	// Install the handler before the first prompt, so a cancel that arrives once the
	// agent is running is always handled.
	relay := new(Station_Relay)
	relay.input = input
	relay.agent = agent_in_write
	relay.display = display
	relay.one_turn = shot_kind == SHOT_KIND_RESEARCH || taste != ""
	station_install_sigterm()
	station_turn_started(relay)
	if !station_write_prompt(agent_in_write, first_prompt, "") {
		write_error("could not send the first prompt to the agent")
		_ = station_orderly_shutdown(&relay, nil)
		_, _ = os.process_wait(process)
		station_close_file(&agent_out_read)
		return 1
	}
	station_display_line(display, station_style(ansi.FAINT, fmt.tprintf("sent the first prompt to the agent")))
	reader_thread := thread.create_and_start_with_data(relay, station_relay_replies, self_cleanup = false)
	if reader_thread == nil {
		_ = station_orderly_shutdown(&relay, nil)
		_, _ = os.process_wait(process)
		station_close_file(&agent_out_read)
		return 1
	}

	watchdog := Station_Watchdog{relay = relay, process = process, deadline_seconds = station_turn_deadline_seconds()}
	watchdog_thread := thread.create_and_start_with_data(&watchdog, station_watchdog, self_cleanup = false)

	parser: Pi_Event_State
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_reader(agent_out_read))
	defer bufio.reader_destroy(&reader)
	for {
		line, read_err := bufio.reader_read_string(&reader, '\n', context.temp_allocator)
		if read_err != nil {
			break
		}
		text := strings.trim_right(line, "\r\n")
		station_handle_agent_line(relay, &sender, brew_id, station_id, &parser, text)
		free_all(context.temp_allocator)
	}

	sync.atomic_store(&relay.watchdog_stop, true)
	if watchdog_thread != nil {
		thread.join(watchdog_thread)
		thread.destroy(watchdog_thread)
	}
	deadline_expired := sync.atomic_load(&relay.deadline_expired)
	state, wait_err := os.process_wait(process)
	shutdown_status := station_orderly_shutdown(&relay, reader_thread)
	station_close_file(&agent_out_read)
	fmt.println("Agent exited.")
	station_report(&sender, brew_id, station_id, "agent_exited", "Agent exited")
	if shutdown_status == STATION_CANCELLED_EXIT_CODE {
		return shutdown_status
	}
	if deadline_expired {
		station_report(&sender, brew_id, station_id, "incomplete", fmt.tprintf("Agent gave no reply for %d seconds; the Station stopped it", watchdog.deadline_seconds))
		return 1
	}
	if shot_kind == SHOT_KIND_RESEARCH && !station_research_clean(&sender, brew_id, station_id) {
		return 1
	}
	if wait_err != nil || !state.success {
		return 1
	}
	if taste == "" {
		return 0
	}
	return station_pull(&sender, brew_id, station_id, taste, message, base_head)
}

// A Pull commits only after its Taste passes. The Taste's output stays on the
// Station's stdout; reports carry the outcome, never the output. The Taste runs
// even when the agent committed its own work: a clean tree whose HEAD moved since
// the Station started is that commit, reported as pulled once the Taste passes.
station_pull :: proc(sender: ^Activity_Sender, brew_id, station_id, taste, message, base_head: string) -> int {
	exit_code, ran := station_run_taste(taste)
	if !ran {
		station_report(sender, brew_id, station_id, "taste_failed", "Taste could not run")
		return 1
	}
	if exit_code != 0 {
		station_report(sender, brew_id, station_id, "taste_failed", fmt.tprintf("Taste exited with code %d", exit_code))
		return 1
	}
	state, changes, _, status_err := os.process_exec(os.Process_Desc{command = {"git", "status", "--porcelain"}}, context.temp_allocator)
	if status_err != nil || !state.success {
		station_report(sender, brew_id, station_id, "taste_failed", "Taste could not check the changes")
		return 1
	}
	if len(changes) == 0 && base_head != "" && station_head() != base_head {
		return station_report_pulled(sender, brew_id, station_id)
	}
	if len(changes) == 0 {
		station_report(sender, brew_id, station_id, "taste_passed", "Taste passed with no changes")
		return 0
	}
	return station_commit(sender, brew_id, station_id, message)
}

// The taste runs through sh in the Station's directory. Its stdin is closed so it
// cannot take lines typed into the Station's pane.
station_run_taste :: proc(taste: string) -> (exit_code: int, ran: bool) {
	process, start_err := os.process_start(os.Process_Desc{command = {"sh", "-c", taste}, stdout = os.stdout, stderr = os.stderr})
	if start_err != nil {
		return 0, false
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		return 0, false
	}
	return state.exit_code, true
}

// Stages every change and commits it with the Pull's message, using the repository's
// Git configuration. The report carries the short hash of the new commit.
station_commit :: proc(sender: ^Activity_Sender, brew_id, station_id, message: string) -> int {
	add_state, _, _, add_err := os.process_exec(os.Process_Desc{command = {"git", "add", "-A"}}, context.temp_allocator)
	commit_state, _, _, commit_err := os.process_exec(os.Process_Desc{command = {"git", "commit", "-m", message}}, context.temp_allocator)
	if add_err != nil || !add_state.success || commit_err != nil || !commit_state.success {
		station_report(sender, brew_id, station_id, "taste_failed", "commit failed")
		return 1
	}
	return station_report_pulled(sender, brew_id, station_id)
}

// The full HEAD hash in the Station's directory, or empty when Git cannot say.
// The string lives in the temp allocator.
station_head :: proc() -> string {
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = {"git", "rev-parse", "HEAD"}}, context.temp_allocator)
	if err != nil || !state.success {
		return ""
	}
	return strings.trim_space(string(stdout))
}

// Reports `pulled` with the short hash of HEAD.
station_report_pulled :: proc(sender: ^Activity_Sender, brew_id, station_id: string) -> int {
	hash_state, hash_stdout, _, hash_err := os.process_exec(os.Process_Desc{command = {"git", "rev-parse", "--short", "HEAD"}}, context.temp_allocator)
	description := "Committed; the commit hash is unavailable"
	if hash_err == nil && hash_state.success {
		description = strings.trim_space(string(hash_stdout))
	}
	station_report(sender, brew_id, station_id, "pulled", description)
	return 0
}

// Scratch files a research or review Shot writes under .scratch/ are not source.
SCRATCH_PATHSPEC :: ":(exclude).scratch"

// A research Station must leave the source as it found it. Git reports any change
// outside .scratch/, and a failed check counts as incomplete too. The report carries counts, not paths.
station_research_clean :: proc(sender: ^Activity_Sender, brew_id, station_id: string) -> bool {
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = {"git", "status", "--porcelain", "-uall", "--", ".", SCRATCH_PATHSPEC}}, context.temp_allocator)
	if err != nil || !state.success {
		station_report(sender, brew_id, station_id, "incomplete", "Cupping Station could not check its changes")
		return false
	}
	changed := 0
	for line in strings.split_lines(string(stdout), context.temp_allocator) {
		if line != "" {
			changed += 1
		}
	}
	if changed == 0 {
		return true
	}
	station_report(sender, brew_id, station_id, "incomplete", fmt.tprintf("Cupping Station changed %d paths", changed))
	return false
}

STATION_BASH_COMMAND_MAX :: 40

// Extracts the display step before the shared Pi event parser consumes the line.
station_progress_event :: proc(line: string) -> (event_type, step: string, ok: bool) {
	value, parse_err := json.parse_string(line, .JSON, false, context.temp_allocator)
	if parse_err != .None {
		return
	}
	defer json.destroy_value(value, context.temp_allocator)
	root, is_object := value.(json.Object)
	if !is_object {
		return
	}
	event_type = pi_event_string(root, "type")
	switch event_type {
	case "turn_start":
		return event_type, "thinking", true
	case "tool_execution_start":
		step = station_tool_step(root)
		if step == "" {
			return "", "", false
		}
		return event_type, step, true
	case "tool_execution_end", "message_update":
		return event_type, "thinking", true
	}
	return "", "", false
}

station_tool_step :: proc(root: json.Object) -> string {
	tool_name := pi_event_string(root, "toolName")
	if tool_name == "" {
		return ""
	}
	args: json.Object
	if args_value, found := root["args"]; found {
		if object, is_object := args_value.(json.Object); is_object {
			args = object
		}
	}
	switch tool_name {
	case "read":
		path := station_tool_argument(args, "path")
		if path == "" {
			return "reading"
		}
		return fmt.tprintf("reading %s", path)
	case "edit", "write":
		path := station_tool_argument(args, "path")
		if path == "" {
			return "editing"
		}
		return fmt.tprintf("editing %s", path)
	case "bash":
		command := station_tool_argument(args, "command")
		if len(command) > STATION_BASH_COMMAND_MAX {
			command = command[:STATION_BASH_COMMAND_MAX]
		}
		if command == "" {
			return "running bash"
		}
		return fmt.tprintf("running %s", command)
	case "grep", "find", "ls":
		return "searching"
	}
	return fmt.tprintf("running %s", tool_name)
}

station_tool_argument :: proc(args: json.Object, key: string) -> string {
	value, found := args[key]
	if !found {
		return ""
	}
	text, is_text := value.(json.String)
	if !is_text {
		return ""
	}
	return text
}

// UI requests are handled here. Other output updates progress, and a finished
// turn is reported to the parent.
station_handle_agent_line :: proc(
	relay: ^Station_Relay,
	sender: ^Activity_Sender,
	brew_id, station_id: string,
	parser: ^Pi_Event_State,
	text: string,
) {
	value, parse_err := json.parse_string(text, .JSON, false, context.temp_allocator)
	if parse_err == .None {
		if root, ok := value.(json.Object); ok {
			switch pi_event_string(root, "type") {
			case "extension_ui_request":
				// Only dialogs need handling; other UI requests are display-only.
				_ = station_dialog_request(relay, sender, brew_id, station_id, root)
				return
			case "response":
				if pi_event_string(root, "command") == "get_session_stats" {
					station_report_session_stats(sender, brew_id, station_id, root)
					return
				}
			}
		}
	}

	// Any other agent output means the agent moved past a dialog it had open.
	sync.atomic_store(&relay.last_output_ns, time.now()._nsec)
	sync.mutex_lock(&relay.mutex)
	station_dialog_clear(&relay.dialog)
	sync.mutex_unlock(&relay.mutex)

	if event_type, step, ok := station_progress_event(text); ok {
		station_display_progress(relay.display, event_type, step)
	}
	_ = pi_event_consume(parser, text)
	if station_is_turn_end(text) {
		sync.atomic_store(&relay.turn_active, false)
		report := parser.final_report
		if report == "" {
			report = "Turn finished without a text reply."
		}
		station_display_line(relay.display, report)
		if !relay.one_turn {
			station_display_status(relay.display, "Waiting for your reply")
		}
		station_report(sender, brew_id, station_id, "turn_done", report)
		if relay.one_turn {
			station_relay_close_agent(relay)
		}
	}
}

// Closes the agent's input once. The agent exits when its input closes, and the
// relay thread may still be writing, so both happen under the relay's mutex. Pi is
// asked for its stats first, so it can answer before the Station exits.
// station_close_file's atomic exchange is the single decider, so a shutdown that
// runs later — or a SIGTERM that arrives during the write — cannot close the same
// File twice.
station_relay_close_agent :: proc(relay: ^Station_Relay) {
	sync.mutex_lock(&relay.mutex)
	defer sync.mutex_unlock(&relay.mutex)
	if sync.atomic_load(&relay.agent_closed) {
		return
	}
	station_write_stats_request(relay.agent)
	sync.atomic_store(&relay.agent_closed, true)
	station_close_file(&relay.agent)
}

// The SIGTERM handler sets one atomic flag and nothing else: no relay read, no
// close, no allocation, no lock, no wait. The reader sees the flag within one
// poll interval and closes the agent's input; the main flow joins it.
station_signal_term :: proc "c" (sig: posix.Signal) {
	sync.atomic_store(&station_cancel_requested, true)
}

station_install_sigterm :: proc() {
	action: posix.sigaction_t
	action.sa_handler = station_signal_term
	posix.sigemptyset(&action.sa_mask)
	action.sa_flags = {}
	_ = posix.sigaction(.SIGTERM, &action, nil)
}

// A usage report is advisory: a failed or unreadable response sends nothing and
// never fails the Station, the same rule the activity reports follow.
station_report_session_stats :: proc(sender: ^Activity_Sender, brew_id, station_id: string, root: json.Object) {
	success, success_ok := root["success"].(json.Boolean)
	if !success_ok || !success {
		return
	}
	data_value, found := root["data"]
	if !found {
		return
	}
	data, marshal_err := json.marshal(data_value, {}, context.temp_allocator)
	if marshal_err != nil {
		return
	}
	stats, ok := pi_session_stats_parse(data)
	if !ok {
		return
	}
	station_report(sender, brew_id, station_id, "usage", pi_session_stats_description(stats))
}

// Fire-and-forget UI requests need no answer. Dialogs make the agent wait, so they
// are reported as needs_input and kept until a reply arrives.
station_dialog_request :: proc(
	relay: ^Station_Relay,
	sender: ^Activity_Sender,
	brew_id, station_id: string,
	root: json.Object,
) -> bool {
	method := pi_event_string(root, "method")
	switch method {
	case "select", "confirm", "input", "editor":
	case:
		return false
	}
	id := pi_event_string(root, "id")
	if id == "" {
		return false
	}
	title := pi_event_string(root, "title")
	options: [dynamic]string
	if options_value, found := root["options"]; found {
		if list, is_list := options_value.(json.Array); is_list {
			for item in list {
				if text, is_text := item.(json.String); is_text {
					append(&options, strings.clone(text))
				}
			}
		}
	}

	question := title
	if method == "select" && len(options) > 0 {
		question = fmt.tprintf("%s [%s]", title, strings.join(options[:], " / ", context.temp_allocator))
	}
	hint := station_style(ansi.FAINT, "  (reply in this pane or from the main agent)")
	station_display_line(relay.display, fmt.tprintf("%s%s", station_style(ansi.BOLD+";"+ansi.FG_YELLOW, fmt.tprintf("? %s", question)), hint))
	station_display_status(relay.display, "Waiting for an answer")

	sync.mutex_lock(&relay.mutex)
	station_dialog_clear(&relay.dialog)
	relay.dialog = Station_Dialog{active = true, id = strings.clone(id), method = strings.clone(method), options = options[:]}
	sync.mutex_unlock(&relay.mutex)

	station_report(sender, brew_id, station_id, "needs_input", question)
	return true
}

station_dialog_clear :: proc(dialog: ^Station_Dialog) {
	if !dialog.active {
		return
	}
	delete(dialog.id)
	delete(dialog.method)
	for option in dialog.options {
		delete(option)
	}
	delete(dialog.options)
	dialog^ = {}
}

// Every non-empty stdin line is a reply: it answers the pending dialog if there is
// one, otherwise it is a follow-up prompt. Polling gives cancellation a bounded
// wake-up time, so the main flow can always join this thread.
station_relay_reply_line :: proc(relay: ^Station_Relay, text: string) -> bool {
	trimmed := strings.trim_space(text)
	if trimmed == "" {
		return true
	}

	// A reply after the close is dropped without a report.
	sync.mutex_lock(&relay.mutex)
	defer sync.mutex_unlock(&relay.mutex)
	if sync.atomic_load(&relay.agent_closed) {
		return false
	}
	if relay.dialog.active {
		response := station_dialog_response(relay.dialog, trimmed)
		station_dialog_clear(&relay.dialog)
		sync.atomic_store(&relay.last_output_ns, time.now()._nsec)
		return station_write_line(relay.agent, response)
	}
	station_turn_started(relay)
	return station_write_prompt(relay.agent, trimmed, "followUp")
}

station_relay_replies :: proc(data: rawptr) {
	relay := (^Station_Relay)(data)
	defer {
		if relay.reader_done != nil {
			sync.atomic_store(relay.reader_done, true)
		}
	}
	defer station_relay_close_agent(relay)

	line: [dynamic]byte
	defer delete(line)
	for {
		if sync.atomic_load(&relay.cancelled) || sync.atomic_load(&station_cancel_requested) {
			break
		}
		fds := [1]posix.pollfd{{
			fd = posix.FD(os.fd(relay.input)),
			events = {.IN, .HUP, .ERR},
		}}
		poll_result := posix.poll(&fds[0], 1, STATION_RELAY_POLL_MS)
		if poll_result < 0 {
			break
		}
		if poll_result == 0 {
			continue
		}
		if .IN not_in fds[0].revents && .HUP not_in fds[0].revents {
			break
		}
		character: byte
		read_count := posix.read(fds[0].fd, &character, 1)
		if read_count <= 0 {
			break
		}
		if character == '\n' {
			if !station_relay_reply_line(relay, string(line[:])) {
				break
			}
			resize(&line, 0)
			continue
		}
		append(&line, character)
	}
	if len(line) > 0 && !sync.atomic_load(&relay.cancelled) && !sync.atomic_load(&station_cancel_requested) {
		_ = station_relay_reply_line(relay, string(line[:]))
	}
}

// Builds the agent's answer to a dialog from a typed reply. Unmatched select
// options and unclear confirm answers are cancelled rather than guessed.
station_dialog_response :: proc(dialog: Station_Dialog, reply: string) -> string {
	data: []byte
	err: json.Marshal_Error
	switch dialog.method {
	case "confirm":
		lower := strings.to_lower(reply, context.temp_allocator)
		switch lower {
		case "yes", "y":
			data, err = json.marshal(Dialog_Confirm_Response{type = "extension_ui_response", id = dialog.id, confirmed = true}, {}, context.temp_allocator)
		case "no", "n":
			data, err = json.marshal(Dialog_Confirm_Response{type = "extension_ui_response", id = dialog.id, confirmed = false}, {}, context.temp_allocator)
		case:
			data, err = json.marshal(Dialog_Cancel_Response{type = "extension_ui_response", id = dialog.id, cancelled = true}, {}, context.temp_allocator)
		}
	case "select":
		if !slice_contains(dialog.options, reply) {
			data, err = json.marshal(Dialog_Cancel_Response{type = "extension_ui_response", id = dialog.id, cancelled = true}, {}, context.temp_allocator)
			break
		}
		data, err = json.marshal(Dialog_Value_Response{type = "extension_ui_response", id = dialog.id, value = reply}, {}, context.temp_allocator)
	case:
		data, err = json.marshal(Dialog_Value_Response{type = "extension_ui_response", id = dialog.id, value = reply}, {}, context.temp_allocator)
	}
	if err != nil {
		return `{"type":"extension_ui_response","cancelled":true}`
	}
	return string(data)
}

slice_contains :: proc(items: []string, value: string) -> bool {
	for item in items {
		if item == value {
			return true
		}
	}
	return false
}

station_write_prompt :: proc(file: ^os.File, message, behavior: string) -> bool {
	data, err := json.marshal(Station_Prompt{type = "prompt", message = message, streamingBehavior = behavior}, {}, context.temp_allocator)
	if err != nil {
		return false
	}
	return station_write_line(file, string(data))
}

station_write_stats_request :: proc(file: ^os.File) -> bool {
	data, err := json.marshal(Station_Stats_Request{type = "get_session_stats"}, {}, context.temp_allocator)
	if err != nil {
		return false
	}
	return station_write_line(file, string(data))
}

station_write_line :: proc(file: ^os.File, line: string) -> bool {
	if _, write_err := os.write_string(file, line); write_err != nil {
		return false
	}
	_, newline_err := os.write_string(file, "\n")
	return newline_err == nil
}

station_is_turn_end :: proc(line: string) -> bool {
	value, err := json.parse_string(line, .JSON, false, context.temp_allocator)
	if err != .None {
		return false
	}
	root, ok := value.(json.Object)
	return ok && pi_event_string(root, "type") == "agent_end"
}

// Reports that fit the activity limit travel inline. A longer report is written to
// <host>/reports/ and the socket carries "file:" plus its path, so the host can
// relay the whole text. If the file cannot be written, the report is truncated.
station_report :: proc(sender: ^Activity_Sender, brew_id, station_id, kind, description: string) {
	text := description
	if len(text) > ACTIVITY_MAX_DESCRIPTION {
		text = text[:ACTIVITY_MAX_DESCRIPTION]
		if path, ok := station_write_report_file(sender.path, brew_id, station_id, kind, description); ok {
			text = fmt.tprintf("%s%s", STATION_FILE_PREFIX, path)
			delete(path, context.allocator)
		}
	}
	message := Activity_Message{
		brew_id = brew_id,
		shot_id = station_id,
		kind = kind,
		description = text,
		timestamp_ns = time.now()._nsec,
	}
	message.spool = station_spool_report(sender.path, message)
	_ = activity_sender_send(sender, message)
}

STATION_SPOOL_DIR_NAME :: "spool"

// Writes the report durably in <host>/spool/ before it is sent, so a host that dies
// with the message unread cannot lose it. The host makes the directory; a socket
// without one (a dispatch run) is not spooled. Returns the entry name, or "".
station_spool_report :: proc(socket_path: string, message: Activity_Message) -> string {
	slash := strings.last_index_byte(socket_path, '/')
	if slash < 0 {
		return ""
	}
	spool_dir, _ := filepath.join({socket_path[:slash], STATION_SPOOL_DIR_NAME}, context.temp_allocator)
	if !os.is_directory(spool_dir) {
		return ""
	}
	name := fmt.tprintf("%020d-%s.json", message.timestamp_ns, random_token(context.temp_allocator))
	spooled := message
	spooled.spool = name
	data, marshal_err := json.marshal(spooled, {}, context.temp_allocator)
	if marshal_err != nil {
		return ""
	}
	path, _ := filepath.join({spool_dir, name}, context.temp_allocator)
	temp_path := fmt.tprintf("%s.tmp", path)
	if write_all_to_file(temp_path, data, os.O_WRONLY|os.O_CREATE|os.O_EXCL).kind != .None || os.rename(temp_path, path) != nil {
		_ = os.remove(temp_path)
		return ""
	}
	return name
}

STATION_FILE_PREFIX :: "file:"

station_write_report_file :: proc(socket_path, brew_id, station_id, kind, text: string) -> (path: string, ok: bool) {
	if !valid_shot_id(station_id) || !valid_shot_id(brew_id) {
		return "", false
	}
	switch kind {
	case "turn_done", "needs_input", "agent_exited":
	case:
		return "", false
	}

	slash := strings.last_index_byte(socket_path, '/')
	if slash < 0 {
		return "", false
	}
	host_dir := socket_path[:slash]
	reports_dir, _ := filepath.join({host_dir, "reports"}, context.temp_allocator)
	if !os.is_directory(reports_dir) && os.make_directory_all(reports_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return "", false
	}
	name := fmt.tprintf("%s-%s-%s-%s.txt", brew_id, station_id, kind, random_token(context.temp_allocator))
	temp_path, _ := filepath.join({reports_dir, name}, context.temp_allocator)
	if err := write_all_to_file(temp_path, transmute([]byte)text, os.O_WRONLY|os.O_CREATE|os.O_EXCL); err.kind != .None {
		_ = os.remove(temp_path)
		return "", false
	}
	owned_path, clone_err := strings.clone(temp_path, context.allocator)
	if clone_err != nil {
		_ = os.remove(temp_path)
		return "", false
	}
	return owned_path, true
}
