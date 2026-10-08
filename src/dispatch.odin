package main

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

Herdr_Response :: struct {
	id: string,
	result: Herdr_Result,
}

Herdr_Result :: struct {
	type: string,
	workspace: Herdr_Workspace,
	tab: Herdr_Tab,
	root_pane: Herdr_Pane,
}

Herdr_Workspace :: struct {
	workspace_id: string,
}

Herdr_Tab :: struct {
	tab_id: string,
}

Herdr_Pane :: struct {
	pane_id: string,
}

Worker_Result :: struct {
	brew_id: string,
	shot_id: string,
	started: bool,
	exit_code: int,
	success: bool,
	detail: string,
}

Pi_Run_Result :: struct {
	process_state: os.Process_State,
	started: bool,
	stream_ok: bool,
	stderr: []byte,
	error: string,
}

run_brew :: proc(repo, recipe_path: string) -> (brew_id: string, err: string) {
	state_root, state_err := default_state_root()
	if state_err != "" {
		return "", state_err
	}
	defer delete(state_root)

	process_info, process_err := os.current_process_info({.Executable_Path}, context.allocator)
	defer os.free_process_info(process_info, context.allocator)
	if process_err != nil || process_info.executable_path == "" {
		return "", "could not locate the Coffee Shop executable for Worker tabs"
	}

	brew_id, err = run_brew_with(repo, recipe_path, state_root, process_info.executable_path, "herdr")
	if err == "" && brew_id != "" {
		err = brew_launch_failure(state_root, brew_id)
	}
	return brew_id, err
}

run_brew_with :: proc(repo_path, recipe_path, state_root, executable, herdr: string) -> (brew_id: string, err: string) {
	// Symlinks and later commands run from other directories, so use an absolute path.
	repo, abs_err := filepath.abs(repo_path)
	if abs_err != nil {
		return "", "could not resolve the Beans path"
	}
	defer delete(repo)
	valid, repo_err := is_git_repository(repo)
	if repo_err != "" {
		return "", repo_err
	}
	if !valid {
		return "", "Beans path is not a Git repository"
	}

	recipe, recipe_err := load_recipe(recipe_path)
	if recipe_err != "" {
		return "", recipe_err
	}
	defer destroy_recipe(&recipe)
	if share_err := validate_shared_paths(repo, recipe.share[:]); share_err != "" {
		return "", share_err
	}
	if exclude_err := exclude_shared_paths(repo, recipe.share[:]); exclude_err != "" {
		return "", exclude_err
	}

	brew_id = next_brew_id(state_root, time.now())
	brew_dir := state_file_path(state_root, brew_id)
	defer delete(brew_dir)
	register, state_error := register_from_recipe(brew_id, repo, recipe)
	if state_error.kind != .None {
		return brew_id, "could not allocate Brew state"
	}
	defer destroy_register(&register)
	base_commit, base_err := git_head_commit(repo)
	if base_err != "" {
		return brew_id, base_err
	}
	register.base_commit = base_commit
	if state_error = create_state(brew_dir, &register); state_error.kind != .None {
		return brew_id, state_error_message(state_error)
	}

	stations_dir := state_file_path(brew_dir, "stations")
	defer delete(stations_dir)
	if os.make_directory_all(stations_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return brew_id, "could not create the Stations directory"
	}
	results_dir := state_file_path(brew_dir, "results")
	defer delete(results_dir)
	if os.make_directory_all(results_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return brew_id, "could not create the Worker results directory"
	}
	// Create shared directories before any Worker starts; two Workers creating
	// reports/ at the same time can make one of them fail.
	reports_dir := state_file_path(brew_dir, "reports")
	defer delete(reports_dir)
	if os.make_directory_all(reports_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return brew_id, "could not create the reports directory"
	}
	workers_dir := state_file_path(brew_dir, "workers")
	defer delete(workers_dir)
	if os.make_directory_all(workers_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return brew_id, "could not create the Worker status directory"
	}

	for shot, i in recipe.shots {
		station_path := state_file_path(stations_dir, shot.id)
		branch := fmt.tprintf("coffee-shop-%s-%s", brew_id, shot.id)
		git_err := create_git_worktree(repo, branch, station_path)
		if git_err != "" {
			delete(station_path)
			if state_error = transition_shot(brew_dir, &register, shot.id, SHOT_FAILED, git_err); state_error.kind != .None {
				return brew_id, state_error_message(state_error)
			}
			continue
		}
		station_copy, clone_err := strings.clone(station_path)
		delete(station_path)
		if clone_err != nil {
			return brew_id, "could not save Station path"
		}
		register.shots[i].station_path = station_copy
		if link_err := link_shared_paths(repo, station_copy, register.share[:]); link_err != "" {
			if state_error = transition_shot(brew_dir, &register, shot.id, SHOT_FAILED, link_err); state_error.kind != .None {
				return brew_id, state_error_message(state_error)
			}
			continue
		}
		if state_error := save_register_metadata(brew_dir, register); state_error.kind != .None {
			return brew_id, state_error_message(state_error)
		}
	}

	first_station := -1
	for shot, i in register.shots {
		if shot.station_path != "" {
			first_station = i
			break
		}
	}
	if first_station < 0 {
		return brew_id, ""
	}

	workspace, herdr_err := herdr_create_workspace(herdr, register.shots[first_station].station_path, brew_id)
	if herdr_err != "" {
		for shot in register.shots {
			if shot.status == SHOT_QUEUED {
				if state_error := transition_shot(brew_dir, &register, shot.id, SHOT_FAILED, fmt.tprintf("Herdr workspace launch failed: %s", herdr_err)); state_error.kind != .None {
					return brew_id, state_error_message(state_error)
				}
			}
		}
		return brew_id, ""
	}
	herdr_workspace_id, clone_err := strings.clone(workspace.result.workspace.workspace_id)
	first_tab_id, tab_clone_err := strings.clone(workspace.result.tab.tab_id)
	first_pane_id, pane_clone_err := strings.clone(workspace.result.root_pane.pane_id)
	destroy_herdr_response(&workspace)
	if clone_err != nil || tab_clone_err != nil || pane_clone_err != nil {
		return brew_id, "could not save Herdr workspace identity"
	}
	register.herdr_workspace_id = herdr_workspace_id
	register.shots[first_station].herdr_tab_id = first_tab_id
	register.shots[first_station].herdr_pane_id = first_pane_id
	if state_error = save_register_metadata(brew_dir, register); state_error.kind != .None {
		return brew_id, state_error_message(state_error)
	}
	if rename_err := herdr_rename_tab(herdr, register.shots[first_station].herdr_tab_id, register.shots[first_station].id); rename_err != "" {
		if state_error = transition_shot(brew_dir, &register, register.shots[first_station].id, SHOT_FAILED, fmt.tprintf("Herdr could not label the initial Shot tab: %s", rename_err)); state_error.kind != .None {
			return brew_id, state_error_message(state_error)
		}
	}

	for shot, i in register.shots {
		if shot.status != SHOT_QUEUED || shot.station_path == "" || i == first_station {
			continue
		}
		tab, tab_err := herdr_create_tab(herdr, register.herdr_workspace_id, shot.id, shot.station_path)
		if tab_err != "" {
			if state_error := transition_shot(brew_dir, &register, shot.id, SHOT_FAILED, fmt.tprintf("Herdr tab launch failed: %s", tab_err)); state_error.kind != .None {
				return brew_id, state_error_message(state_error)
			}
			continue
		}
		tab_copy, tab_clone_err := strings.clone(tab.result.tab.tab_id)
		pane_copy, pane_clone_err := strings.clone(tab.result.root_pane.pane_id)
		destroy_herdr_response(&tab)
		if tab_clone_err != nil || pane_clone_err != nil {
			return brew_id, "could not save Herdr tab identity"
		}
		register.shots[i].herdr_tab_id = tab_copy
		register.shots[i].herdr_pane_id = pane_copy
		if state_error = save_register_metadata(brew_dir, register); state_error.kind != .None {
			return brew_id, state_error_message(state_error)
		}
	}

	if !write_supervisor(brew_dir) {
		return brew_id, "could not record the Brew supervisor"
	}
	if state_error := dispatch_workers(brew_dir, &register, executable, state_root, herdr); state_error.kind != .None {
		return brew_id, state_error_message(state_error)
	}
	return brew_id, ""
}

// Stations are created from HEAD, so record exactly which commit that is.
git_head_commit :: proc(repo: string, allocator := context.allocator) -> (commit: string, err: string) {
	state, stdout, stderr, run_err := os.process_exec(os.Process_Desc{
		command = []string{"git", "-C", repo, "rev-parse", "--verify", "HEAD"},
	}, allocator)
	defer delete(stdout, allocator)
	defer delete(stderr, allocator)
	if run_err != nil {
		return "", "could not run Git to read the Beans HEAD commit"
	}
	if !state.success || state.exit_code != 0 {
		return "", "the Beans repository has no HEAD commit"
	}
	cloned, clone_err := strings.clone(strings.trim_space(string(stdout)), allocator)
	if clone_err != nil {
		return "", "could not allocate the Beans base commit"
	}
	return cloned, ""
}

create_git_worktree :: proc(repo, branch, path: string, allocator := context.allocator) -> string {
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{
		command = []string{"git", "-C", repo, "worktree", "add", "-b", branch, path, "HEAD"},
	}, allocator)
	defer delete(stdout, allocator)
	defer delete(stderr, allocator)
	if err != nil {
		return "could not run Git to create Station"
	}
	if !state.success || state.exit_code != 0 {
		detail := strings.trim_space(transmute(string)stderr)
		if detail == "" {
			detail = strings.trim_space(transmute(string)stdout)
		}
		if detail == "" {
			return "Git could not create the Station"
		}
		return fmt.tprintf("Git could not create the Station: %s", detail)
	}
	return ""
}

herdr_create_workspace :: proc(herdr, cwd, brew_id: string, allocator := context.allocator) -> (response: Herdr_Response, err: string) {
	label := fmt.tprintf("Coffee Shop %s", brew_id)
	stdout, stderr, run_err := run_herdr(herdr, []string{"workspace", "create", "--cwd", cwd, "--label", label, "--no-focus"}, allocator)
	defer delete(stdout, allocator)
	defer delete(stderr, allocator)
	if run_err != "" {
		return Herdr_Response{}, run_err
	}
	if json.unmarshal_string(transmute(string)stdout, &response, .JSON, allocator) != nil || response.result.type != "workspace_created" || response.result.workspace.workspace_id == "" || response.result.tab.tab_id == "" || response.result.root_pane.pane_id == "" {
		destroy_herdr_response(&response, allocator)
		return Herdr_Response{}, "Herdr returned an invalid workspace response"
	}
	return response, ""
}

herdr_create_tab :: proc(herdr, workspace_id, shot_id, cwd: string, allocator := context.allocator) -> (response: Herdr_Response, err: string) {
	label := fmt.tprintf("Shot %s", shot_id)
	stdout, stderr, run_err := run_herdr(herdr, []string{"tab", "create", "--workspace", workspace_id, "--cwd", cwd, "--label", label, "--no-focus"}, allocator)
	defer delete(stdout, allocator)
	defer delete(stderr, allocator)
	if run_err != "" {
		return Herdr_Response{}, run_err
	}
	if json.unmarshal_string(transmute(string)stdout, &response, .JSON, allocator) != nil || response.result.type != "tab_created" || response.result.tab.tab_id == "" || response.result.root_pane.pane_id == "" {
		destroy_herdr_response(&response, allocator)
		return Herdr_Response{}, "Herdr returned an invalid tab response"
	}
	return response, ""
}

run_herdr :: proc(herdr: string, args: []string, allocator := context.allocator) -> (stdout, stderr: []byte, err: string) {
	command := make([]string, 1+len(args), allocator)
	command[0] = herdr
	copy(command[1:], args)
	defer delete(command, allocator)
	process_state, child_stdout, child_stderr, process_err := os.process_exec(os.Process_Desc{command = command}, allocator)
	stdout = child_stdout
	stderr = child_stderr
	if process_err != nil {
		return stdout, stderr, "could not run Herdr"
	}
	if !process_state.success || process_state.exit_code != 0 {
		detail := strings.trim_space(transmute(string)stderr)
		if detail == "" {
			detail = strings.trim_space(transmute(string)stdout)
		}
		if message := herdr_error_message(detail); message != "" {
			detail = message
		}
		if detail == "" {
			detail = "Herdr command failed"
		}
		return stdout, stderr, detail
	}
	return stdout, stderr, ""
}

Herdr_Error_Response :: struct {
	error: struct {
		message: string,
	},
}

// Herdr reports failures as {"id":...,"error":{"code":...,"message":...}}. Return
// the message so a Shot's failure reads as a sentence; "" if text is not that shape.
// The result is allocated on the temp allocator.
herdr_error_message :: proc(text: string) -> string {
	response: Herdr_Error_Response
	if json.unmarshal_string(text, &response, .JSON, context.temp_allocator) != nil {
		return ""
	}
	return response.error.message
}

destroy_herdr_response :: proc(response: ^Herdr_Response, allocator := context.allocator) {
	delete(response.id, allocator)
	delete(response.result.type, allocator)
	delete(response.result.workspace.workspace_id, allocator)
	delete(response.result.tab.tab_id, allocator)
	delete(response.result.root_pane.pane_id, allocator)
	response^ = Herdr_Response{}
}

dispatch_workers :: proc(directory: string, register: ^Register, executable, state_root, herdr: string) -> State_Error {
	socket_path := activity_socket_path(directory)
	defer delete(socket_path)
	listener, listening := activity_listener_open(socket_path)
	defer activity_listener_close(&listener)

	launched := make([]bool, len(register.shots))
	defer delete(launched)

	for {
		if cancel_requested(directory) {
			return settle_brew(directory, register, herdr, .Cancel)
		}
		if err := settle_brew(directory, register, herdr, .Observe); err.kind != .None {
			return err
		}
		if listening {
			drain_worker_activity(directory, register^, &listener)
		}

		active := 0
		for shot, index in register.shots {
			if launched[index] && !is_terminal(shot.status) {
				active += 1
			}
		}
		for index in 0 ..< len(register.shots) {
			if active >= SCALE {
				break
			}
			shot := &register.shots[index]
			if launched[index] || shot.status != SHOT_QUEUED {
				continue
			}
			if shot.herdr_pane_id == "" {
				if err := transition_shot(directory, register, shot.id, SHOT_FAILED, "Shot has no Herdr tab"); err.kind != .None {
					return err
				}
				continue
			}

			command, _ := worker_command(executable, state_root, register.brew_id, shot.id)
			launch_err := herdr_run_worker(herdr, shot.herdr_pane_id, command)
			delete(command)
			if launch_err != "" {
				if err := transition_shot(directory, register, shot.id, SHOT_FAILED, fmt.tprintf("Worker launch failed: %s", launch_err)); err.kind != .None {
					return err
				}
				continue
			}
			launched[index] = true
			active += 1
		}

		if all_terminal(register^) {
			return State_Error{}
		}
		time.sleep(100 * time.Millisecond)
	}
}

ACTIVITY_DRAIN_LIMIT :: 64

drain_worker_activity :: proc(directory: string, register: Register, listener: ^Activity_Listener) {
	for _ in 0 ..< ACTIVITY_DRAIN_LIMIT {
		result := activity_listener_receive(listener)
		switch result.kind {
		case .Message:
			shot_index := find_shot(register, result.message.shot_id)
			if result.message.brew_id != register.brew_id || shot_index < 0 ||
				register.shots[shot_index].status != SHOT_RUNNING {
				activity_message_destroy(&result.message)
				continue
			}
			now_ns := time.now()._nsec
			if result.message.timestamp_ns > now_ns {
				result.message.timestamp_ns = now_ns
			}
			_ = write_activity_record(directory, result.message)
			activity_message_destroy(&result.message)
		case .Malformed:
			continue
		case .Unavailable, .Failed:
			return
		}
	}
}

herdr_rename_tab :: proc(herdr, tab_id, shot_id: string) -> string {
	label := fmt.tprintf("Shot %s", shot_id)
	stdout, stderr, err := run_herdr(herdr, []string{"tab", "rename", tab_id, label})
	defer delete(stdout)
	defer delete(stderr)
	return err
}

herdr_run_worker :: proc(herdr, pane_id, command: string) -> string {
	stdout, stderr, err := run_herdr(herdr, []string{"pane", "run", pane_id, command})
	defer delete(stdout)
	defer delete(stderr)
	return err
}

// The command text holds only Coffee Shop's own paths and validated IDs, never
// task text. Paths are single-quoted for the Herdr pane's shell.
worker_command :: proc(executable, state_root, brew_id, shot_id: string) -> (command: string, err: string) {
	quoted_executable := shell_quote(executable)
	defer delete(quoted_executable)
	quoted_state_root := shell_quote(state_root)
	defer delete(quoted_state_root)
	command = fmt.aprintf("%s __worker --state-root %s --brew-id %s --shot-id %s", quoted_executable, quoted_state_root, brew_id, shot_id)
	return command, ""
}

shell_quote :: proc(value: string) -> string {
	escaped, _ := strings.replace_all(value, "'", "'\\''", context.temp_allocator)
	return fmt.aprintf("'%s'", escaped)
}

run_pi_json_with_activity :: proc(
	pi, working_dir, prompt, brew_dir, brew_id, shot_id: string,
	parser: ^Pi_Event_State,
	sender: ^Activity_Sender,
	allocator := context.allocator,
) -> Pi_Run_Result {
	result: Pi_Run_Result
	stderr_name := fmt.aprintf("%s.stderr.log", shot_id)
	defer delete(stderr_name)
	reports_dir := state_file_path(brew_dir, "reports")
	defer delete(reports_dir)
	stderr_path := state_file_path(reports_dir, stderr_name)
	defer delete(stderr_path)
	stderr_file, stderr_open_err := os.create(stderr_path)
	if stderr_open_err != nil {
		result.error = "could not create Pi stderr log"
		return result
	}

	stdout_read, stdout_write, pipe_err := os.pipe()
	if pipe_err != nil {
		_ = os.close(stderr_file)
		result.error = "could not create Pi output pipe"
		return result
	}
	defer os.close(stdout_read)
	process, start_err := os.process_start(os.Process_Desc{
		working_dir = working_dir,
		command = []string{pi, "--mode", "json", "--print", "--no-session", "--", prompt},
		stdout = stdout_write,
		stderr = stderr_file,
	})
	_ = os.close(stdout_write)
	_ = os.close(stderr_file)
	if start_err != nil {
		_ = os.remove(stderr_path)
		result.error = fmt.aprintf("could not start Pi: %v", start_err)
		return result
	}

	result.started = true
	result.stream_ok = read_pi_event_stream(stdout_read, parser, sender, brew_id, shot_id)
	if !result.stream_ok {
		result.error = "could not read Pi JSON event stream"
		_ = os.process_kill(process)
	}
	result.process_state, start_err = os.process_wait(process)
	if start_err != nil && result.error == "" {
		result.error = fmt.aprintf("could not wait for Pi: %v", start_err)
	}

	stderr, stderr_err := os.read_entire_file(stderr_path, allocator)
	if stderr_err != nil {
		delete(stderr)
		if result.error == "" {
			result.error = "could not read Pi stderr log"
		}
	} else {
		result.stderr = stderr
	}
	return result
}

read_pi_event_stream :: proc(
	stdout: ^os.File,
	parser: ^Pi_Event_State,
	sender: ^Activity_Sender,
	brew_id, shot_id: string,
) -> bool {
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_reader(stdout))
	defer bufio.reader_destroy(&reader)

	line: [PI_EVENT_LINE_MAX]u8
	line_len := 0
	discarding := false
	for {
		fragment, read_err := bufio.reader_read_slice(&reader, '\n')
		if !discarding {
			if len(fragment) > len(line)-line_len {
				line_len = 0
				discarding = true
			} else {
				copy(line[line_len:], fragment)
				line_len += len(fragment)
			}
		}
		if read_err == .Buffer_Full {
			continue
		}
		if read_err == .EOF {
			if !discarding && line_len > 0 {
				pi_event_stream_line(parser, sender, brew_id, shot_id, string(line[:line_len]))
			}
			return true
		}
		if read_err != nil {
			return false
		}
		if !discarding && line_len > 0 {
			pi_event_stream_line(parser, sender, brew_id, shot_id, string(line[:line_len]))
		}
		line_len = 0
		discarding = false
	}
}

pi_event_stream_line :: proc(
	parser: ^Pi_Event_State,
	sender: ^Activity_Sender,
	brew_id, shot_id, line: string,
) {
	if !pi_event_consume(parser, line) || sender.fd < 0 {
		return
	}
	_ = activity_sender_send(sender, Activity_Message{
		brew_id = brew_id,
		shot_id = shot_id,
		kind = parser.last_kind,
		description = parser.last_description,
		timestamp_ns = time.now()._nsec,
	})
}

pi_run_result_destroy :: proc(result: ^Pi_Run_Result, allocator := context.allocator) {
	delete(result.stderr, allocator)
	delete(result.error, allocator)
	result^ = Pi_Run_Result{}
}

run_worker :: proc(state_root, brew_id, shot_id: string) -> int {
	return run_worker_with(state_root, brew_id, shot_id, "pi")
}

run_worker_with :: proc(state_root, brew_id, shot_id, pi: string) -> int {
	if !valid_shot_id(brew_id) || !valid_shot_id(shot_id) {
		write_error("Worker IDs are invalid")
		return 2
	}
	brew_dir := state_file_path(state_root, brew_id)
	defer delete(brew_dir)
	if !write_worker_started(brew_dir, shot_id) {
		write_error("Worker could not record that it started")
		return 2
	}

	brew_copy, brew_clone_err := strings.clone(brew_id)
	shot_copy, shot_clone_err := strings.clone(shot_id)
	if brew_clone_err != nil || shot_clone_err != nil {
		delete(brew_copy)
		delete(shot_copy)
		write_error("Worker could not allocate its result")
		return 2
	}
	result := Worker_Result{brew_id = brew_copy, shot_id = shot_copy, started = true}
	result_path := worker_result_path(brew_dir, shot_id)
	defer delete(result_path)

	register, state_err := read_state(brew_dir)
	if state_err.kind != .None {
		result.detail = fmt.aprintf("could not read Brew state: %s", state_error_message(state_err))
		if !write_worker_result(result_path, result) {
			write_error("Worker could not persist its result")
			destroy_worker_result(&result)
			return 2
		}
		destroy_worker_result(&result)
		return 1
	}
	defer destroy_register(&register)
	index := find_shot(register, shot_id)
	if index < 0 || register.shots[index].station_path == "" {
		result.detail = fmt.aprintf("Worker Shot %s has no Station", shot_id)
		if !write_worker_result(result_path, result) {
			write_error("Worker could not persist its result")
			destroy_worker_result(&result)
			return 2
		}
		destroy_worker_result(&result)
		return 1
	}

	prompt := fmt.aprintf("Order: %s\n\nShot: %s", register.order, register.shots[index].prompt)
	defer delete(prompt)
	activity_path := activity_socket_path(brew_dir)
	defer delete(activity_path)
	sender, sender_open := activity_sender_open(activity_path)
	if !sender_open {
		sender = Activity_Sender{fd = -1}
	}
	defer activity_sender_close(&sender)
	if sender.fd >= 0 {
		_ = activity_sender_send(&sender, Activity_Message{
			brew_id = brew_id,
			shot_id = shot_id,
			kind = "starting",
			description = "Starting Pi",
			timestamp_ns = time.now()._nsec,
		})
	}
	parser: Pi_Event_State
	defer pi_event_state_destroy(&parser)
	run_result := run_pi_json_with_activity(
		pi, register.shots[index].station_path, prompt, brew_dir, brew_id, shot_id,
		&parser, &sender,
	)
	defer pi_run_result_destroy(&run_result)
	result.exit_code = run_result.process_state.exit_code
	if !run_result.started {
		result.detail = strings.clone(run_result.error)
	} else {
		result.success = run_result.process_state.success &&
			run_result.process_state.exit_code == 0 && run_result.stream_ok && run_result.error == ""
		switch {
		case run_result.error != "":
			result.detail = strings.clone(run_result.error)
		case result.success:
			result.detail = strings.clone("Pi exited with code 0")
		case:
			result.detail = fmt.aprintf("Pi exited with code %d", run_result.process_state.exit_code)
		}
		report := transmute([]byte)parser.final_report
		if !write_shot_output(brew_dir, shot_id, report, run_result.stderr) {
			result.success = false
			delete(result.detail)
			result.detail = strings.clone("Pi output could not be written to the Brew state")
		}
		if parser.final_report != "" {
			fmt.print(parser.final_report)
			if parser.final_report[len(parser.final_report)-1] != '\n' {
				fmt.println()
			}
		}
		if len(run_result.stderr) > 0 {
			fmt.eprint(transmute(string)run_result.stderr)
		}
	}

	if !write_worker_result(result_path, result) {
		write_error("Worker could not persist its result")
		destroy_worker_result(&result)
		return 2
	}
	code := result.exit_code
	if code == 0 && !result.success {
		code = 1
	}
	destroy_worker_result(&result)
	return code
}

// Reports live in the Brew's state directory, not the Station, so they never
// show up as uncommitted changes in the Worker's worktree.
write_shot_output :: proc(brew_dir, shot_id: string, stdout, stderr: []byte) -> bool {
	reports_dir := state_file_path(brew_dir, "reports")
	defer delete(reports_dir)
	if !os.is_dir(reports_dir) {
		return false
	}
	report_name := strings.concatenate({shot_id, ".md"})
	defer delete(report_name)
	report_path := state_file_path(reports_dir, report_name)
	defer delete(report_path)
	if os.write_entire_file(report_path, stdout, os.Permissions{.Read_User, .Write_User}) != nil {
		return false
	}
	stderr_name := strings.concatenate({shot_id, ".stderr.log"})
	defer delete(stderr_name)
	stderr_path := state_file_path(reports_dir, stderr_name)
	defer delete(stderr_path)
	return os.write_entire_file(stderr_path, stderr, os.Permissions{.Read_User, .Write_User}) == nil
}

write_worker_result :: proc(path: string, result: Worker_Result) -> bool {
	temp_path, alloc_err := strings.concatenate({path, ".tmp"})
	if alloc_err != nil {
		return false
	}
	defer delete(temp_path)
	data, err := json.marshal(result, json.Marshal_Options{spec = .JSON, pretty = true})
	if err != nil {
		delete(data)
		return false
	}
	defer delete(data)
	if write_all_to_file(temp_path, data, os.O_WRONLY|os.O_CREATE|os.O_TRUNC).kind != .None {
		_ = os.remove(temp_path)
		return false
	}
	if os.rename(temp_path, path) != nil {
		_ = os.remove(temp_path)
		return false
	}
	return true
}

read_worker_result :: proc(path: string) -> (result: Worker_Result, err: string) {
	data, io_err := os.read_entire_file(path, context.allocator)
	if io_err != nil {
		delete(data)
		return Worker_Result{}, "could not read Worker result"
	}
	defer delete(data)
	if json.unmarshal_string(transmute(string)data, &result) != nil || result.brew_id == "" || result.shot_id == "" {
		destroy_worker_result(&result)
		return Worker_Result{}, "Worker result is malformed"
	}
	return result, ""
}

destroy_worker_result :: proc(result: ^Worker_Result) {
	delete(result.brew_id)
	delete(result.shot_id)
	delete(result.detail)
	result^ = Worker_Result{}
}

worker_result_path :: proc(directory, shot_id: string) -> string {
	results_dir := state_file_path(directory, "results")
	defer delete(results_dir)
	filename, err := strings.concatenate({shot_id, ".json"})
	assert(err == nil, "could not build Worker result filename")
	defer delete(filename)
	return state_file_path(results_dir, filename)
}

worker_started_path :: proc(directory, shot_id: string) -> string {
	workers_dir := state_file_path(directory, "workers")
	defer delete(workers_dir)
	filename, err := strings.concatenate({shot_id, ".started"})
	assert(err == nil, "could not build Worker marker filename")
	defer delete(filename)
	return state_file_path(workers_dir, filename)
}

write_worker_started :: proc(directory, shot_id: string) -> bool {
	path := worker_started_path(directory, shot_id)
	defer delete(path)
	identity, ok := current_identity()
	if !ok || !write_identity_file(path, identity) {
		return false
	}
	_ = write_worker_started_at(directory, shot_id, time.now()._nsec)
	return true
}

state_error_message :: proc(err: State_Error) -> string {
	switch err.kind {
	case .Corrupt_Register: return "Register is missing or corrupt"
	case .Corrupt_Receipt: return "Receipt is missing or corrupt"
	case .Malformed_Receipt: return fmt.tprintf("Receipt line %d is malformed or incomplete", err.line)
	case .Conflicting_Records: return "Register and Receipt records conflict; Brew state is unknown"
	case .Invalid_Transition: return "Shot state transition is invalid"
	case .Cancellation_Pending: return "Shot cancellation is pending"
	case .Shot_Not_Found: return "Shot is missing from the Register"
	case .Already_Exists: return "Brew state already exists"
	case .Invalid_Register: return "Register is invalid"
	case .Out_Of_Memory: return "not enough memory to update Brew state"
	case .IO_Error: return "could not read or write Brew state"
	case .None: return ""
	}
	return "unknown state error"
}

// Brew IDs are "brew-<UTC time>-<pid>", so sorting by name sorts by start time.
// The ID is never reused: if the directory exists (same second, same process),
// a counter is appended, which still sorts after the original.
next_brew_id :: proc(state_root: string, now: time.Time) -> string {
	year, month, day := time.date(now)
	hour, minute, second := time.clock(now)
	pid := os.get_pid()
	base := fmt.aprintf("brew-%04d%02d%02dT%02d%02d%02dZ-%d", year, int(month), day, hour, minute, second, pid)
	brew_id := base
	for sequence := 1; ; sequence += 1 {
		brew_path := state_file_path(state_root, brew_id)
		exists := os.exists(brew_path)
		delete(brew_path)
		if !exists {
			if sequence > 1 {
				delete(base)
			}
			return brew_id
		}
		if sequence > 1 {
			delete(brew_id)
		}
		brew_id = fmt.aprintf("%s-%d", base, sequence)
	}
}

// State lives in $CS_STATE_DIR when set, otherwise in ~/.coffee-shop. No
// platform-specific directory convention is assumed.
default_state_root :: proc(allocator := context.allocator) -> (path: string, err: string) {
	override := os.get_env("CS_STATE_DIR", context.temp_allocator)
	home := ""
	if override == "" {
		home_dir, home_err := os.user_home_dir(context.temp_allocator)
		if home_err == nil {
			home = home_dir
		}
	}
	return resolve_state_root(override, home, allocator)
}

resolve_state_root :: proc(override, home: string, allocator := context.allocator) -> (path: string, err: string) {
	if override != "" {
		if !filepath.is_abs(override) {
			return "", "CS_STATE_DIR must be an absolute path"
		}
		cloned, clone_err := strings.clone(override, allocator)
		if clone_err != nil {
			return "", "could not allocate the Coffee Shop state path"
		}
		return cloned, ""
	}
	if home == "" {
		return "", "set CS_STATE_DIR: could not locate the home directory"
	}
	joined, join_err := filepath.join([]string{home, ".coffee-shop"}, allocator)
	if join_err != nil {
		return "", "could not allocate the Coffee Shop state path"
	}
	return joined, ""
}
