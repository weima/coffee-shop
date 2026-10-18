package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Turning a completed Pull into a PR, and cleaning up a merged run.
//
// A "run" is one foreground-host dispatch, named by its request id. Its state is
// under <state>/host/<run>/: history.ndjson (Station reports), stations/<shot>
// (the Pull's Station worktree), and pr/<shot>.json (what `pr` recorded). The
// base branch's worktree is the developer's own worktree that the Station was
// branched from; `pr` fast-forwards it and `cleanup` removes it.
//
// Every Git, gh, Herdr and process call goes through Pr_Backend, so a test can
// substitute them and needs no GitHub remote, Herdr server, or live Station.

Pr_Backend :: struct {
	git:       proc(directory: string, args: []string) -> (out, detail: string, ok: bool),
	gh:        proc(directory: string, args: []string) -> (out, detail: string, ok: bool),
	herdr:     proc(args: []string) -> (out, detail: string, ok: bool),
	processes: proc() -> []Process_Command,
}

Process_Command :: struct {
	pid:  int,
	args: []string,
}

Live_Station :: struct {
	pid:     int,
	shot_id: string,
}

Pr_Record :: struct {
	shot_id:  string `json:"shot_id"`,
	branch:   string `json:"branch"`,
	worktree: string `json:"worktree"`,
	commit:   string `json:"commit"`,
}

Run_Event :: struct {
	type:        string `json:"type"`,
	request_id:  string `json:"request_id"`,
	shot_id:     string `json:"shot_id"`,
	pane_id:     string `json:"pane_id"`,
	kind:        string `json:"kind"`,
	description: string `json:"description"`,
}

Shot_Evidence :: struct {
	terminal:     bool,
	taste_passed: bool,
	taste_failed: bool,
	pulled:       bool,
	commit:       string,
}

// ---------------------------------------------------------------------------
// Backend defaults

default_pr_backend :: proc() -> Pr_Backend {
	return Pr_Backend{
		git = real_git,
		gh = real_gh,
		herdr = real_herdr,
		processes = default_process_commands,
	}
}

real_git :: proc(directory: string, args: []string) -> (out, detail: string, ok: bool) {
	command := make([dynamic]string, 0, len(args)+3, context.temp_allocator)
	append(&command, "git", "-C", directory)
	append(&command, ..args)
	return run_tool(command[:], "")
}

real_gh :: proc(directory: string, args: []string) -> (out, detail: string, ok: bool) {
	command := make([dynamic]string, 0, len(args)+1, context.temp_allocator)
	append(&command, "gh")
	append(&command, ..args)
	return run_tool(command[:], directory)
}

real_herdr :: proc(args: []string) -> (out, detail: string, ok: bool) {
	command := make([]string, len(args)+1, context.temp_allocator)
	command[0] = "herdr"
	copy(command[1:], args)
	return run_tool(command, "")
}

run_tool :: proc(command: []string, working_dir: string) -> (out, detail: string, ok: bool) {
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = command, working_dir = working_dir}, context.temp_allocator)
	if err != nil {
		return "", "could not run the command", false
	}
	text := strings.trim_space(string(stdout))
	if state.success && state.exit_code == 0 {
		return text, "", true
	}
	detail = strings.trim_space(string(stderr))
	if detail == "" {
		detail = text
	}
	if detail == "" {
		detail = "the command failed"
	}
	return "", detail, false
}

// ---------------------------------------------------------------------------
// Process enumeration: a Station is found by its --brew argument, never by the
// process name (under `odin run` the name is a temp binary).

when ODIN_OS == .Darwin {
	default_process_commands :: proc() -> []Process_Command {
		return process_commands_ps()
	}
} else {
	default_process_commands :: proc() -> []Process_Command {
		return process_commands_proc()
	}
}

process_commands_proc :: proc() -> []Process_Command {
	commands := make([dynamic]Process_Command, 0, 64, context.temp_allocator)
	entries, read_err := os.read_all_directory_by_path("/proc", context.temp_allocator)
	if read_err != nil {
		return commands[:]
	}
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for entry in entries {
		pid, numeric := strconv.parse_int(entry.name)
		if !numeric || pid <= 0 {
			continue
		}
		data, data_err := os.read_entire_file(fmt.tprintf("/proc/%s/cmdline", entry.name), context.temp_allocator)
		if data_err != nil || len(data) == 0 {
			continue
		}
		args := split_nul(string(data))
		if len(args) == 0 {
			continue
		}
		append(&commands, Process_Command{pid = pid, args = args})
	}
	return commands[:]
}

process_commands_ps :: proc() -> []Process_Command {
	commands := make([dynamic]Process_Command, 0, 64, context.temp_allocator)
	stdout, _ := exec_reaped({"ps", "-axo", "pid=,command="}, context.temp_allocator)
	if len(stdout) == 0 {
		return commands[:]
	}
	remaining := string(stdout)
	for line in strings.split_lines_iterator(&remaining) {
		trimmed := strings.trim_space(line)
		space := strings.index_byte(trimmed, ' ')
		if space < 0 {
			continue
		}
		pid, numeric := strconv.parse_int(trimmed[:space])
		if !numeric {
			continue
		}
		args := strings.fields(trimmed[space+1:], context.temp_allocator)
		append(&commands, Process_Command{pid = pid, args = args})
	}
	return commands[:]
}

split_nul :: proc(text: string) -> []string {
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	start := 0
	for i in 0 ..= len(text) {
		if i == len(text) || text[i] == 0 {
			if i > start {
				append(&parts, text[start:i])
			}
			start = i + 1
		}
	}
	return parts[:]
}

// A Station for this run is any live process whose argv carries --brew <run>.
live_stations :: proc(commands: []Process_Command, run_id: string) -> []Live_Station {
	live := make([dynamic]Live_Station, 0, 4, context.temp_allocator)
	for command in commands {
		if !has_brew_argument(command.args, run_id) {
			continue
		}
		append(&live, Live_Station{pid = command.pid, shot_id = station_argument(command.args)})
	}
	return live[:]
}

has_brew_argument :: proc(args: []string, run_id: string) -> bool {
	for arg, i in args {
		if arg == "--brew" && i+1 < len(args) && args[i+1] == run_id {
			return true
		}
	}
	return false
}

station_argument :: proc(args: []string) -> string {
	for arg, i in args {
		if arg == "--station" && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Run state

run_directory :: proc(state_root, run_id: string) -> string {
	host_dir := state_file_path(state_root, "host", context.temp_allocator)
	return state_file_path(host_dir, run_id, context.temp_allocator)
}

station_directory :: proc(run_dir, shot_id: string) -> string {
	stations_dir := state_file_path(run_dir, "stations", context.temp_allocator)
	return state_file_path(stations_dir, shot_id, context.temp_allocator)
}

read_run_events :: proc(state_root, run_id: string) -> (events: [dynamic]Run_Event, err: string) {
	history_path := state_file_path(run_directory(state_root, run_id), HOST_HISTORY_FILE_NAME, context.temp_allocator)
	data, read_err := os.read_entire_file(history_path, context.temp_allocator)
	if read_err != nil {
		return {}, fmt.tprintf("no run named %s", run_id)
	}
	events = make([dynamic]Run_Event, 0, 8, context.temp_allocator)
	remaining := string(data)
	for line in strings.split_lines_iterator(&remaining) {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		event: Run_Event
		if json.unmarshal_string(trimmed, &event, .JSON, context.temp_allocator) != nil {
			continue
		}
		append(&events, event)
	}
	return events, ""
}

// A Pull's evidence: it reached a terminal state, and Taste passed with a commit.
shot_evidence :: proc(events: []Run_Event, shot_id: string) -> Shot_Evidence {
	evidence: Shot_Evidence
	for event in events {
		if event.type != "station_report" || event.shot_id != shot_id {
			continue
		}
		switch event.kind {
		case "agent_exited":
			evidence.terminal = true
		case "taste_passed":
			evidence.taste_passed = true
		case "taste_failed":
			evidence.taste_failed = true
		case "pulled":
			evidence.taste_passed = true
			evidence.pulled = true
			if description := strings.trim_space(event.description); valid_commit_hash(description) {
				evidence.commit = description
			}
		}
	}
	return evidence
}

run_panes :: proc(events: []Run_Event) -> []string {
	panes := make([dynamic]string, 0, 4, context.temp_allocator)
	for event in events {
		if event.type == "session_started" && event.pane_id != "" {
			append(&panes, event.pane_id)
		}
	}
	return panes[:]
}

workspace_of_pane :: proc(pane: string) -> string {
	if colon := strings.index_byte(pane, ':'); colon >= 0 {
		return pane[:colon]
	}
	return ""
}

// ---------------------------------------------------------------------------
// Git helpers

find_worktree_for_branch :: proc(directory, branch: string, backend: Pr_Backend) -> (path, err: string) {
	out, detail, ok := backend.git(directory, {"worktree", "list", "--porcelain"})
	if !ok {
		return "", fmt.tprintf("could not list the repository's worktrees: %s", detail)
	}
	current := ""
	remaining := out
	for line in strings.split_lines_iterator(&remaining) {
		trimmed := strings.trim_space(line)
		switch {
		case strings.has_prefix(trimmed, "worktree "):
			current = trimmed[len("worktree "):]
		case strings.has_prefix(trimmed, "branch refs/heads/"):
			if trimmed[len("branch refs/heads/"):] == branch {
				return current, ""
			}
		}
	}
	return "", fmt.tprintf("no worktree has branch %s checked out; pass --branch", branch)
}

remove_worktree :: proc(directory, path: string, backend: Pr_Backend) -> string {
	if !os.exists(path) {
		return ""
	}
	if _, detail, ok := backend.git(directory, {"worktree", "remove", path}); !ok {
		return fmt.tprintf("could not remove worktree %s: %s", path, detail)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Herdr helpers

Herdr_Pane_Info :: struct {
	tab_id:       string `json:"tab_id"`,
	workspace_id: string `json:"workspace_id"`,
}
Herdr_Pane_Result :: struct {
	pane: Herdr_Pane_Info `json:"pane"`,
}
Herdr_Pane_Response :: struct {
	result: Herdr_Pane_Result `json:"result"`,
}

Herdr_Workspace_Info :: struct {
	workspace_id: string `json:"workspace_id"`,
	label:        string `json:"label"`,
}
Herdr_Workspace_Result :: struct {
	workspace: Herdr_Workspace_Info `json:"workspace"`,
}
Herdr_Workspace_Response :: struct {
	result: Herdr_Workspace_Result `json:"result"`,
}

Herdr_Tab_Info :: struct {
	tab_id: string `json:"tab_id"`,
}
Herdr_Tab_Result :: struct {
	tabs: [dynamic]Herdr_Tab_Info `json:"tabs"`,
}
Herdr_Tab_Response :: struct {
	result: Herdr_Tab_Result `json:"result"`,
}

herdr_pane_ids :: proc(out: string) -> (tab_id, workspace_id: string) {
	response: Herdr_Pane_Response
	if json.unmarshal_string(out, &response, .JSON, context.temp_allocator) != nil {
		return "", ""
	}
	return response.result.pane.tab_id, response.result.pane.workspace_id
}

herdr_workspace_label :: proc(out: string) -> string {
	response: Herdr_Workspace_Response
	if json.unmarshal_string(out, &response, .JSON, context.temp_allocator) != nil {
		return ""
	}
	return response.result.workspace.label
}

herdr_tab_count :: proc(out: string) -> int {
	response: Herdr_Tab_Response
	if json.unmarshal_string(out, &response, .JSON, context.temp_allocator) != nil {
		return -1
	}
	return len(response.result.tabs)
}

// Closes only the run's own tabs. A workspace is closed only when those tabs
// were its last, so a workspace shared with the developer is never removed.
close_run_herdr :: proc(events: []Run_Event, extra_workspace: string, backend: Pr_Backend) -> (tabs_closed, workspaces_closed: int) {
	tabs := make([dynamic]string, 0, 4, context.temp_allocator)
	workspaces := make([dynamic]string, 0, 2, context.temp_allocator)
	for event in events {
		if event.type != "session_started" || event.pane_id == "" {
			continue
		}
		out, _, ok := backend.herdr({"pane", "get", event.pane_id})
		if !ok {
			continue
		}
		tab_id, workspace_id := herdr_pane_ids(out)
		if tab_id != "" && !slice_contains(tabs[:], tab_id) {
			append(&tabs, tab_id)
		}
		if workspace_id != "" && !slice_contains(workspaces[:], workspace_id) {
			append(&workspaces, workspace_id)
		}
	}
	if extra_workspace != "" && !slice_contains(workspaces[:], extra_workspace) {
		append(&workspaces, extra_workspace)
	}
	for tab in tabs {
		if _, _, ok := backend.herdr({"tab", "close", tab}); ok {
			tabs_closed += 1
		}
	}
	for workspace in workspaces {
		out, _, ok := backend.herdr({"tab", "list", "--workspace", workspace})
		if !ok || herdr_tab_count(out) != 0 {
			continue
		}
		if _, _, closed := backend.herdr({"workspace", "close", workspace}); closed {
			workspaces_closed += 1
		}
	}
	return tabs_closed, workspaces_closed
}

// ---------------------------------------------------------------------------
// PR records

pr_record_directory :: proc(run_dir: string) -> string {
	return state_file_path(run_dir, "pr", context.temp_allocator)
}

write_pr_record :: proc(run_dir: string, record: Pr_Record) -> string {
	pr_dir := pr_record_directory(run_dir)
	if !os.is_directory(pr_dir) {
		if os.make_directory_all(pr_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
			return "could not create the PR record directory"
		}
	}
	path := state_file_path(pr_dir, fmt.tprintf("%s.json", record.shot_id), context.temp_allocator)
	data, marshal_err := json.marshal(record, {}, context.temp_allocator)
	if marshal_err != nil {
		return "could not encode the PR record"
	}
	if write_err := write_all_to_file(path, data, os.O_WRONLY|os.O_CREATE|os.O_TRUNC); write_err.kind != .None {
		return "could not write the PR record"
	}
	return ""
}

read_pr_records :: proc(run_dir: string) -> []Pr_Record {
	records := make([dynamic]Pr_Record, 0, 2, context.temp_allocator)
	entries, read_err := os.read_all_directory_by_path(pr_record_directory(run_dir), context.temp_allocator)
	if read_err != nil {
		return records[:]
	}
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for entry in entries {
		if entry.type != .Regular {
			continue
		}
		path := state_file_path(pr_record_directory(run_dir), entry.name, context.temp_allocator)
		data, data_err := os.read_entire_file(path, context.temp_allocator)
		if data_err != nil {
			continue
		}
		record: Pr_Record
		if json.unmarshal(data, &record, .JSON, context.temp_allocator) != nil {
			continue
		}
		append(&records, record)
	}
	return records[:]
}

// ---------------------------------------------------------------------------
// Operations

run_pr :: proc(run_id, shot_id, branch, remote, message: string, blend: bool) -> int {
	state_root, state_err := default_state_root()
	if state_err != "" {
		write_error(state_err)
		return 2
	}
	defer delete(state_root)
	output, err := pr_operation(state_root, run_id, shot_id, branch, remote, message, blend, default_pr_backend())
	if err != "" {
		write_error(err)
		return 1
	}
	fmt.print(output)
	return 0
}

run_cleanup :: proc(run_id, branch, workspace: string) -> int {
	state_root, state_err := default_state_root()
	if state_err != "" {
		write_error(state_err)
		return 2
	}
	defer delete(state_root)
	output, err := cleanup_operation(state_root, run_id, branch, workspace, default_pr_backend())
	if err != "" {
		write_error(err)
		return 1
	}
	fmt.print(output)
	return 0
}

pr_operation :: proc(
	state_root, run_id, shot_id, branch, remote, message: string,
	blend: bool,
	backend: Pr_Backend,
) -> (output, err: string) {
	if !valid_shot_id(run_id) {
		return "", "run ID is invalid"
	}
	if !valid_shot_id(shot_id) {
		return "", "Shot ID is invalid"
	}
	remote_name := remote
	if remote_name == "" {
		remote_name = "origin"
	}
	run_dir := run_directory(state_root, run_id)
	if !os.is_directory(run_dir) {
		return "", fmt.tprintf("no run named %s", run_id)
	}
	station := station_directory(run_dir, shot_id)
	if !os.is_directory(station) {
		return "", fmt.tprintf("run %s has no Station for Shot %s", run_id, shot_id)
	}

	events, events_err := read_run_events(state_root, run_id)
	if events_err != "" {
		return "", events_err
	}
	evidence := shot_evidence(events[:], shot_id)
	if !evidence.terminal {
		return "", fmt.tprintf("Shot %s has no terminal state; it is still working or its exit was never recorded", shot_id)
	}
	if evidence.taste_failed {
		return "", fmt.tprintf("Shot %s did not pass Taste; it is never turned into a PR", shot_id)
	}
	if !evidence.taste_passed {
		return "", fmt.tprintf("Shot %s has no recorded Taste evidence; it is not a Pull", shot_id)
	}
	if !evidence.pulled {
		return "", fmt.tprintf("Shot %s passed Taste with no commit; there is nothing to turn into a PR", shot_id)
	}

	head, head_detail, head_ok := backend.git(station, {"rev-parse", "HEAD"})
	if !head_ok {
		return "", fmt.tprintf("could not read the Pull's commit: %s", head_detail)
	}
	head = strings.trim_space(head)
	if !valid_commit_hash(head) {
		return "", "the Station HEAD is not a commit"
	}
	if evidence.commit != "" && !strings.has_prefix(head, evidence.commit) {
		return "", fmt.tprintf("the Station HEAD %s is not the recorded Pull commit %s", short_commit(head), evidence.commit)
	}

	dev_branch := branch
	if dev_branch == "" {
		dev_branch, err = discover_branch(events[:], backend)
		if err != "" {
			return "", err
		}
	}
	dev_worktree, find_err := find_worktree_for_branch(station, dev_branch, backend)
	if find_err != "" {
		return "", find_err
	}

	target := head
	if blend {
		pulls, pulls_err := run_pull_commits(events[:], station, backend)
		if pulls_err != "" {
			return "", pulls_err
		}
		switch {
		case len(pulls) < HOST_BLEND_COMMITS_MIN:
			return "", "A single Pull never needs Blend; Blend combines the 2 to 20 commits of a multi-Pull run. Run `pr` without --blend for one Pull."
		case len(pulls) > HOST_BLEND_COMMITS_MAX:
			return "", fmt.tprintf("Blend combines 2 to 20 commits; this run has %d Pull commits", len(pulls))
		}
		if message == "" {
			return "", "--blend needs --message for the combined commit"
		}
		base, base_detail, base_ok := backend.git(dev_worktree, {"rev-parse", "HEAD"})
		if !base_ok {
			return "", fmt.tprintf("could not read the base commit: %s", base_detail)
		}
		blended, blend_err := blend_pull_commits(run_dir, dev_worktree, strings.trim_space(base), message, pulls, backend)
		if blend_err != "" {
			return "", blend_err
		}
		target = blended
	}

	// The base branch moves only by fast-forward; a non-fast-forward is refused
	// rather than forced.
	if _, detail, ok := backend.git(dev_worktree, {"merge", "--ff-only", target}); !ok {
		return "", fmt.tprintf("refusing to force %s to the Pull commit: %s", dev_branch, detail)
	}
	if record_err := write_pr_record(run_dir, Pr_Record{shot_id = shot_id, branch = dev_branch, worktree = dev_worktree, commit = target}); record_err != "" {
		return "", record_err
	}
	if _, detail, ok := backend.git(dev_worktree, {"push", remote_name, dev_branch}); !ok {
		return "", fmt.tprintf("could not push %s to %s: %s", dev_branch, remote_name, detail)
	}
	pr_out, detail, ok := backend.gh(dev_worktree, {"pr", "create", "--head", dev_branch, "--fill"})
	if !ok {
		return "", fmt.tprintf("could not open the PR: %s", detail)
	}
	url := strings.trim_space(pr_out)
	if url == "" {
		return "", "gh did not print a PR URL"
	}

	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&builder, "%s", url)
	fmt.sbprintfln(&builder, "Waiting on the developer to merge the PR.")
	return strings.to_string(builder), ""
}

discover_branch :: proc(events: []Run_Event, backend: Pr_Backend) -> (branch, err: string) {
	for event in events {
		if event.type != "session_started" || event.pane_id == "" {
			continue
		}
		workspace := workspace_of_pane(event.pane_id)
		if workspace == "" {
			continue
		}
		out, detail, ok := backend.herdr({"workspace", "get", workspace})
		if !ok {
			return "", fmt.tprintf("could not read the run's workspace: %s", detail)
		}
		label := herdr_workspace_label(out)
		if label == "" {
			return "", "the run's workspace has no label to name the base branch; pass --branch"
		}
		return label, ""
	}
	return "", "the run has no started Station to name the base branch; pass --branch"
}

run_pull_commits :: proc(events: []Run_Event, station: string, backend: Pr_Backend) -> (commits: []string, err: string) {
	pulls := make([dynamic]string, 0, 4, context.temp_allocator)
	for event in events {
		if event.type != "station_report" || event.kind != "pulled" {
			continue
		}
		short := strings.trim_space(event.description)
		if !valid_commit_hash(short) {
			continue
		}
		out, detail, ok := backend.git(station, {"rev-parse", short})
		if !ok {
			return nil, fmt.tprintf("could not resolve Pull commit %s: %s", short, detail)
		}
		full := strings.trim_space(out)
		if !slice_contains(pulls[:], full) {
			append(&pulls, full)
		}
	}
	return pulls[:], ""
}

// Cherry-picks the run's Pull commits into one commit on a temporary branch from
// the base. Any failure removes the temporary worktree and branch and changes
// nothing else.
blend_pull_commits :: proc(run_dir, base_dir, base, message: string, commits: []string, backend: Pr_Backend) -> (commit, err: string) {
	tmp_branch := fmt.tprintf("cs-blend-%s", run_dir_base(run_dir))
	tmp_path := state_file_path(run_dir, "blend", context.temp_allocator)
	if os.exists(tmp_path) {
		_ = os.remove_all(tmp_path)
	}
	abandon := proc(base_dir, tmp_path, tmp_branch: string, backend: Pr_Backend) {
		_, _, _ = backend.git(base_dir, {"worktree", "remove", "--force", tmp_path})
		_, _, _ = backend.git(base_dir, {"update-ref", "-d", fmt.tprintf("refs/heads/%s", tmp_branch)})
	}
	if _, detail, ok := backend.git(base_dir, {"worktree", "add", "-b", tmp_branch, tmp_path, base}); !ok {
		return "", fmt.tprintf("could not create the blend worktree: %s", detail)
	}
	for pick in commits {
		if _, detail, ok := backend.git(tmp_path, {"cherry-pick", "-n", pick}); !ok {
			_, _, _ = backend.git(tmp_path, {"cherry-pick", "--abort"})
			abandon(base_dir, tmp_path, tmp_branch, backend)
			return "", fmt.tprintf("Blend conflict on %s: %s", short_commit(pick), detail)
		}
	}
	if _, detail, ok := backend.git(tmp_path, {"commit", "-m", message}); !ok {
		abandon(base_dir, tmp_path, tmp_branch, backend)
		return "", fmt.tprintf("could not create the blended commit: %s", detail)
	}
	out, detail, ok := backend.git(tmp_path, {"rev-parse", "HEAD"})
	if !ok {
		abandon(base_dir, tmp_path, tmp_branch, backend)
		return "", fmt.tprintf("could not read the blended commit: %s", detail)
	}
	blended := strings.trim_space(out)
	abandon(base_dir, tmp_path, tmp_branch, backend)
	return blended, ""
}

run_dir_base :: proc(run_dir: string) -> string {
	if slash := strings.last_index_byte(run_dir, '/'); slash >= 0 {
		return run_dir[slash+1:]
	}
	return run_dir
}

short_commit :: proc(commit: string) -> string {
	if len(commit) <= 8 {
		return commit
	}
	return commit[:8]
}

cleanup_operation :: proc(state_root, run_id, branch, workspace: string, backend: Pr_Backend) -> (output, err: string) {
	if !valid_shot_id(run_id) {
		return "", "run ID is invalid"
	}
	run_dir := run_directory(state_root, run_id)
	if !os.is_directory(run_dir) {
		return "", fmt.tprintf("no run named %s", run_id)
	}

	// A run with a live Station is never cleaned up. The Station is found by its
	// --brew argument, not by the process name, which says nothing under `odin run`.
	live := live_stations(backend.processes(), run_id)
	if len(live) > 0 {
		builder := strings.builder_make(context.temp_allocator)
		fmt.sbprintfln(&builder, "Refusing to clean run %s: %d Station(s) still working", run_id, len(live))
		for station in live {
			if station.shot_id != "" {
				fmt.sbprintfln(&builder, "  Station %s (pid %d)", station.shot_id, station.pid)
			} else {
				fmt.sbprintfln(&builder, "  Station pid %d", station.pid)
			}
		}
		return "", strings.to_string(builder)
	}

	events, events_err := read_run_events(state_root, run_id)
	if events_err != "" {
		return "", events_err
	}

	// Record what the PR command fast-forwarded before the worktrees go, so only
	// this run's base worktree is removed. --branch is a fallback.
	dev_worktrees := make([dynamic]string, 0, 2, context.temp_allocator)
	for record in read_pr_records(run_dir) {
		if record.worktree != "" && !slice_contains(dev_worktrees[:], record.worktree) {
			append(&dev_worktrees, record.worktree)
		}
	}
	if branch != "" {
		if path, find_err := find_worktree_for_branch(first_station(run_dir), branch, backend); find_err == "" && !slice_contains(dev_worktrees[:], path) {
			append(&dev_worktrees, path)
		}
	}

	tabs_closed, workspaces_closed := close_run_herdr(events[:], workspace, backend)

	removed_stations := 0
	stations_dir := state_file_path(run_dir, "stations", context.temp_allocator)
	if entries, read_err := os.read_all_directory_by_path(stations_dir, context.temp_allocator); read_err == nil {
		defer os.file_info_slice_delete(entries, context.temp_allocator)
		for entry in entries {
			if entry.type != .Directory {
				continue
			}
			station := state_file_path(stations_dir, entry.name, context.temp_allocator)
			if remove_worktree(station, station, backend) == "" {
				removed_stations += 1
			}
		}
	}

	removed_base := 0
	for worktree in dev_worktrees {
		if remove_worktree(worktree, worktree, backend) == "" {
			removed_base += 1
		}
	}

	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&builder, "Cleaned run %s: closed %d tab(s) and %d workspace(s), removed %d Station worktree(s) and %d base worktree(s).", run_id, tabs_closed, workspaces_closed, removed_stations, removed_base)
	fmt.sbprintln(&builder, "Brew state, reports and prompts were kept.")
	return strings.to_string(builder), ""
}

// Any Station worktree still on disk can name the repository for a --branch
// lookup. A missing one is not an error; the PR record is the primary source.
first_station :: proc(run_dir: string) -> string {
	stations_dir := state_file_path(run_dir, "stations", context.temp_allocator)
	entries, read_err := os.read_all_directory_by_path(stations_dir, context.temp_allocator)
	if read_err != nil {
		return ""
	}
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for entry in entries {
		if entry.type == .Directory {
			return state_file_path(stations_dir, entry.name, context.temp_allocator)
		}
	}
	return ""
}
