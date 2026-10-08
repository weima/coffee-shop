package main

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

Active_Worker :: struct {
	shot_index: int,
	result_path: string,
	started_path: string,
	running_recorded: bool,
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

	return run_brew_with(repo, recipe_path, state_root, process_info.executable_path, "herdr")
}

run_brew_with :: proc(repo, recipe_path, state_root, executable, herdr: string) -> (brew_id: string, err: string) {
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

	brew_id = next_brew_id(state_root)
	brew_dir := state_file_path(state_root, brew_id)
	defer delete(brew_dir)
	register, state_error := register_from_recipe(brew_id, repo, recipe)
	if state_error.kind != .None {
		return brew_id, "could not allocate Brew state"
	}
	defer destroy_register(&register)
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

	if state_error := dispatch_workers(brew_dir, &register, executable, herdr); state_error.kind != .None {
		return brew_id, state_error_message(state_error)
	}
	return brew_id, ""
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
		if detail == "" {
			detail = "Herdr command failed"
		}
		return stdout, stderr, detail
	}
	return stdout, stderr, ""
}

destroy_herdr_response :: proc(response: ^Herdr_Response, allocator := context.allocator) {
	delete(response.id, allocator)
	delete(response.result.type, allocator)
	delete(response.result.workspace.workspace_id, allocator)
	delete(response.result.tab.tab_id, allocator)
	delete(response.result.root_pane.pane_id, allocator)
	response^ = Herdr_Response{}
}

dispatch_workers :: proc(directory: string, register: ^Register, executable, herdr: string) -> State_Error {
	active: [2]Active_Worker
	active_count := 0
	next_shot := 0

	for {
		for active_count < len(active) && next_shot < len(register.shots) {
			index := next_shot
			next_shot += 1
			shot := &register.shots[index]
			if shot.status != SHOT_QUEUED || shot.herdr_pane_id == "" {
				continue
			}

			command, quote_err := worker_command(executable, register.brew_id, shot.id)
			if quote_err != "" {
				if err := transition_shot(directory, register, shot.id, SHOT_FAILED, quote_err); err.kind != .None {
					return err
				}
				continue
			}
			launch_err := herdr_run_worker(herdr, shot.herdr_pane_id, command)
			delete(command)
			if launch_err != "" {
				if err := transition_shot(directory, register, shot.id, SHOT_FAILED, fmt.tprintf("Worker launch failed: %s", launch_err)); err.kind != .None {
					return err
				}
				continue
			}
			result_path := worker_result_path(directory, shot.id)
			started_path := worker_started_path(directory, shot.id)
			active[active_count] = Active_Worker{shot_index = index, result_path = result_path, started_path = started_path}
			active_count += 1
		}

		if active_count == 0 {
			if next_shot >= len(register.shots) {
				return State_Error{}
			}
			continue
		}

		made_progress := false
		for i := 0; i < active_count; {
			result_ready := os.exists(active[i].result_path)
			started := os.exists(active[i].started_path)
			if !active[i].running_recorded && (started || result_ready) {
				shot_id := register.shots[active[i].shot_index].id
				if err := transition_shot(directory, register, shot_id, SHOT_RUNNING, "Worker started"); err.kind != .None {
					return err
				}
				active[i].running_recorded = true
				made_progress = true
			}
			if !result_ready {
				i += 1
				continue
			}
			result, err := read_worker_result(active[i].result_path)
			if err != "" || result.brew_id != register.brew_id || result.shot_id != register.shots[active[i].shot_index].id {
				destroy_worker_result(&result)
				return State_Error{kind = .Corrupt_Register}
			}
			shot_id := register.shots[active[i].shot_index].id
			next_state := SHOT_FAILED
			if result.started && result.success {
				next_state = SHOT_COMPLETED
			}
			if state_err := transition_shot(directory, register, shot_id, next_state, result.detail); state_err.kind != .None {
				destroy_worker_result(&result)
				return state_err
			}
			destroy_worker_result(&result)
			delete(active[i].result_path)
			delete(active[i].started_path)
			active_count -= 1
			active[i] = active[active_count]
			made_progress = true
		}
		if !made_progress {
			time.sleep(100 * time.Millisecond)
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

worker_command :: proc(executable, brew_id, shot_id: string) -> (command: string, err: string) {
	escaped, allocated := strings.replace_all(executable, "'", "'\\''")
	defer if allocated { delete(escaped) }
	quoted_executable := fmt.tprintf("'%s'", escaped)
	command = fmt.aprintf("%s __worker --brew-id %s --shot-id %s", quoted_executable, brew_id, shot_id)
	return command, ""
}

run_worker :: proc(brew_id, shot_id: string) -> int {
	state_root, err := default_state_root()
	if err != "" {
		write_error(err)
		return 2
	}
	defer delete(state_root)
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
	process_state, stdout, stderr, run_err := os.process_exec(os.Process_Desc{
		working_dir = register.shots[index].station_path,
		command = []string{pi, "--print", "--no-session", "--", prompt},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	if run_err != nil {
		result.detail = fmt.aprintf("could not start Pi: %v", run_err)
	} else {
		result.exit_code = process_state.exit_code
		result.success = process_state.success && process_state.exit_code == 0
		if result.success {
			result.detail = strings.clone("Pi exited with code 0")
		} else {
			result.detail = fmt.aprintf("Pi exited with code %d", process_state.exit_code)
		}
		if !write_station_output(register.shots[index].station_path, stdout, stderr) {
			result.success = false
			delete(result.detail)
			result.detail = strings.clone("Pi output could not be written to the Station")
		}
		if len(stdout) > 0 {
			fmt.print(transmute(string)stdout)
		}
		if len(stderr) > 0 {
			fmt.eprint(transmute(string)stderr)
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

write_station_output :: proc(station_path: string, stdout, stderr: []byte) -> bool {
	report_path := state_file_path(station_path, "coffee-shop-report.md")
	defer delete(report_path)
	if os.write_entire_file(report_path, stdout, os.Permissions{.Read_User, .Write_User}) != nil {
		return false
	}
	stderr_path := state_file_path(station_path, "coffee-shop-stderr.log")
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
	temp_path, err := strings.concatenate({path, ".tmp"})
	if err != nil {
		return false
	}
	defer delete(temp_path)
	marker := "started\n"
	if write_all_to_file(temp_path, transmute([]byte)marker, os.O_WRONLY|os.O_CREATE|os.O_TRUNC).kind != .None {
		_ = os.remove(temp_path)
		return false
	}
	if os.rename(temp_path, path) != nil {
		_ = os.remove(temp_path)
		return false
	}
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
	case .IO_Error: return "could not write Brew state"
	case .None: return ""
	}
	return "unknown state error"
}

next_brew_id :: proc(state_root: string) -> string {
	pid := os.get_pid()
	for sequence := 0; ; sequence += 1 {
		brew_id := fmt.aprintf("brew-%d-%d", pid, sequence)
		brew_path := state_file_path(state_root, brew_id)
		exists := os.exists(brew_path)
		delete(brew_path)
		if !exists {
			return brew_id
		}
		delete(brew_id)
	}
}

default_state_root :: proc(allocator := context.allocator) -> (path: string, err: string) {
	state_home, os_err := os.user_state_dir(allocator)
	if os_err != nil {
		delete(state_home, allocator)
		return "", "could not locate the user's state directory"
	}
	joined, alloc_err := filepath.join([]string{state_home, "coffee-shop"}, allocator)
	delete(state_home, allocator)
	if alloc_err != nil {
		return "", "could not allocate the Coffee Shop state path"
	}
	path = joined
	return path, ""
}
