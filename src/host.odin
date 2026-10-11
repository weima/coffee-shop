package main

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

HOST_PROTOCOL :: 1

// Compiled into the binary, so a Station can load it from any install location.
HOST_EXTENSION_SOURCE :: #load("../extensions/coffee-shop.ts", string)
HOST_RELAY_POLL :: 20 * time.Millisecond

// Set once by run_host and read by dispatch when it launches Station panes.
host_report_socket: string
host_station_executable: string
host_extension_path: string
host_history_root: string

// The stdin loop and the relay thread both write events; one lock keeps lines whole.
host_output_mutex: sync.Mutex

// Pane of each started Station, so a reply can be typed into the right pane.
Host_Session :: struct {
	request_id: string,
	shot_id:    string,
	pane_id:    string,
}
host_sessions: [dynamic]Host_Session

HOST_REPLY_MAX :: 4096

// One line on stdout per event. Encoded with json.marshal so that free-form
// reasons from Git or Herdr cannot break the framing.
Host_Event :: struct {
	type:        string `json:"type"`,
	request_id:  string `json:"request_id"`,
	shot_id:     string `json:"shot_id,omitempty"`,
	pane_id:     string `json:"pane_id,omitempty"`,
	kind:        string `json:"kind,omitempty"`,
	description: string `json:"description,omitempty"`,
	reason:      string `json:"reason,omitempty"`,
}

// Foreground host: reads one JSON request per line from stdin and answers on
// stdout. It exits on shutdown or end of input; it never daemonizes. While it
// runs, a relay thread forwards Station reports to stdout as station_report.
run_host :: proc() -> int {
	state_root, state_err := default_state_root(context.temp_allocator)
	if state_err != "" {
		host_write_line(fmt.tprintf(`{{"type":"error","reason":"%s"}}`, state_err))
		return 1
	}
	host_dir, _ := filepath.join({state_root, "host"}, context.temp_allocator)
	if !os.is_directory(host_dir) && os.make_directory_all(host_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		host_write_line(`{"type":"error","reason":"could not create the host directory"}`)
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
	host_extension_path = extension_path
	host_history_root = strings.clone(host_dir, context.allocator)
	socket_path, _ := filepath.join({host_dir, "activity.sock"}, context.allocator)
	listener, listener_ok := activity_listener_open(socket_path)
	if !listener_ok {
		host_write_line(`{"type":"error","reason":"could not open the host report socket"}`)
		return 1
	}
	defer activity_listener_close(&listener)
	executable_info, info_err := os.current_process_info({.Executable_Path}, context.allocator)
	if info_err != nil || executable_info.executable_path == "" {
		host_write_line(`{"type":"error","reason":"could not locate the Coffee Shop executable"}`)
		return 1
	}
	host_report_socket = socket_path
	host_station_executable = executable_info.executable_path

	relay := new(Host_Relay)
	relay.listener = listener
	_ = thread.create_and_start_with_data(relay, host_relay_reports, self_cleanup = true)

	host_write_line(fmt.tprintf(`{{"type":"ready","protocol":%d}}`, HOST_PROTOCOL))
	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, os.to_reader(os.stdin))
	defer bufio.scanner_destroy(&scanner)
	for bufio.scanner_scan(&scanner) {
		stop := host_handle_line(bufio.scanner_text(&scanner))
		free_all(context.temp_allocator)
		if stop {
			break
		}
	}
	return 0
}

Host_Relay :: struct {
	listener: Activity_Listener,
}

// Owns the listener: only this thread reads it. Polls because the listener is
// non-blocking and must not hold up the stdin loop.
host_relay_reports :: proc(data: rawptr) {
	relay := (^Host_Relay)(data)
	for {
		result := activity_listener_receive(&relay.listener)
		switch result.kind {
		case .Message:
			host_emit(Host_Event{
				type = "station_report",
				request_id = result.message.brew_id,
				shot_id = result.message.shot_id,
				kind = result.message.kind,
				description = result.message.description,
			})
			destroy_struct(&result.message)
		case .Unavailable:
			time.sleep(HOST_RELAY_POLL)
		case .Malformed:
		case .Failed:
			return
		}
		free_all(context.temp_allocator)
	}
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
	case "dispatch":
		host_dispatch(root, request_id)
	case "reply":
		host_reply(root, request_id)
	case "shutdown":
		host_write_line(fmt.tprintf(`{{"type":"stopped","request_id":"%s"}}`, request_id))
		return true
	case:
		host_emit(Host_Event{type = "error", request_id = request_id, reason = "unknown request type"})
	}
	return false
}

// Validates the dispatch, then starts one interactive Pi session per Shot: a
// Station (Git worktree) and a Herdr tab, with the Shot's prompt typed into the
// pane. Each Shot ends in session_started or session_failed.
// shortcut: the host blocks while sessions start; phase D relays reports but
// replies are not yet routed back from the host.
host_dispatch :: proc(root: json.Object, request_id: string) {
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
		append(&ids, id)
		append(&prompts, prompt)
	}

	host_emit(Host_Event{type = "dispatch_accepted", request_id = request_id})
	host_start_sessions(repo, request_id, ids[:], prompts[:])
}

host_start_sessions :: proc(repo, request_id: string, ids, prompts: []string) {
	state_root, state_err := default_state_root(context.temp_allocator)
	if state_err != "" {
		for id in ids {
			host_session_failed(request_id, id, state_err)
		}
		return
	}
	stations_dir, _ := filepath.join({state_root, "host", request_id, "stations"}, context.temp_allocator)
	if os.make_directory_all(stations_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		for id in ids {
			host_session_failed(request_id, id, "could not create the Stations directory")
		}
		return
	}

	herdr := "herdr"
	workspace_id := ""
	for id, i in ids {
		station, _ := filepath.join({stations_dir, id}, context.temp_allocator)
		branch := fmt.tprintf("cs-host-%s-%s", request_id, id)
		if git_err := create_git_worktree(repo, branch, station, context.temp_allocator); git_err != "" {
			host_session_failed(request_id, id, git_err)
			continue
		}

		pane_id: string
		if workspace_id == "" {
			workspace, herdr_err := herdr_create_workspace(herdr, station, repository_name(repo), request_id, context.temp_allocator)
			if herdr_err != "" {
				host_session_failed(request_id, id, fmt.tprintf("Herdr workspace launch failed: %s", herdr_err))
				continue
			}
			if rename_err := herdr_rename_tab(herdr, workspace.result.tab.tab_id, id); rename_err != "" {
				host_session_failed(request_id, id, fmt.tprintf("Herdr could not label the Shot tab: %s", rename_err))
				continue
			}
			workspace_id = workspace.result.workspace.workspace_id
			pane_id = workspace.result.root_pane.pane_id
		} else {
			tab, tab_err := herdr_create_tab(herdr, workspace_id, id, station, context.temp_allocator)
			if tab_err != "" {
				host_session_failed(request_id, id, fmt.tprintf("Herdr tab launch failed: %s", tab_err))
				continue
			}
			pane_id = tab.result.root_pane.pane_id
		}

		command := host_station_command(host_station_executable, host_report_socket, host_extension_path, id, request_id, prompts[i])
		if run_err := herdr_run_worker(herdr, pane_id, command); run_err != "" {
			host_session_failed(request_id, id, fmt.tprintf("could not start the Station: %s", run_err))
			continue
		}
		append(&host_sessions, Host_Session{request_id = strings.clone(request_id), shot_id = strings.clone(id), pane_id = strings.clone(pane_id)})
		host_emit(Host_Event{type = "session_started", request_id = request_id, shot_id = id, pane_id = pane_id})
	}
}

// Types a reply into a Station's pane. The Station reads it from stdin and either
// answers the agent's pending dialog or sends it as a follow-up prompt.
host_reply :: proc(root: json.Object, request_id: string) {
	shot_id, shot_ok := host_string(root, "shot_id")
	message, message_ok := host_string(root, "message")
	if !shot_ok || !valid_shot_id(shot_id) {
		host_emit(Host_Event{type = "error", request_id = request_id, reason = "reply needs a valid shot_id"})
		return
	}
	message = strings.trim_space(message)
	if !message_ok || message == "" || len(message) > HOST_REPLY_MAX || strings.contains_any(message, "\r\n") {
		host_emit(Host_Event{type = "error", request_id = request_id, shot_id = shot_id, reason = "reply must be one non-empty line"})
		return
	}
	for session in host_sessions {
		if session.request_id == request_id && session.shot_id == shot_id {
			if err := herdr_run_worker("herdr", session.pane_id, message); err != "" {
				host_emit(Host_Event{type = "error", request_id = request_id, shot_id = shot_id, reason = fmt.tprintf("could not send the reply: %s", err)})
				return
			}
			host_emit(Host_Event{type = "reply_sent", request_id = request_id, shot_id = shot_id})
			return
		}
	}
	host_emit(Host_Event{type = "error", request_id = request_id, shot_id = shot_id, reason = "no Station is running for that shot"})
}

// The Station runs in the Herdr pane and launches the agent. Only the prompt and
// the report path are quoted; the IDs are already restricted to safe characters.
host_station_command :: proc(executable, report, extension, shot_id, request_id, prompt: string) -> string {
	quoted_executable := shell_quote(executable)
	defer delete(quoted_executable)
	quoted_report := shell_quote(report)
	defer delete(quoted_report)
	quoted_extension := shell_quote(extension)
	defer delete(quoted_extension)
	quoted_prompt := shell_quote(prompt)
	defer delete(quoted_prompt)
	return fmt.tprintf("%s station --report %s --station %s --brew %s --prompt %s -- pi --mode rpc -e %s", quoted_executable, quoted_report, shot_id, request_id, quoted_prompt, quoted_extension)
}

host_session_failed :: proc(request_id, shot_id, reason: string) {
	host_emit(Host_Event{type = "session_failed", request_id = request_id, shot_id = shot_id, reason = reason})
}

host_emit :: proc(event: Host_Event) {
	data, err := json.marshal(event, {}, context.temp_allocator)
	if err != nil {
		host_write_line(`{"type":"error","reason":"could not encode event"}`)
		return
	}

	sync.mutex_lock(&host_output_mutex)
	defer sync.mutex_unlock(&host_output_mutex)
	if host_history_event(event) && !host_history_append(event, data) {
		return
	}
	fmt.println(string(data))
}

host_write_line :: proc(line: string) {
	sync.mutex_lock(&host_output_mutex)
	defer sync.mutex_unlock(&host_output_mutex)
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
