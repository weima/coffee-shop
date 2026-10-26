package main

import "core:encoding/json"
import "core:fmt"
import "base:runtime"
import "core:log"
import "core:os"
import "core:strings"

// The Herdr implementation of Session_Surface. It owns every Herdr CLI invocation,
// the argument vectors, and the parsing of Herdr's JSON replies.

herdr_ops := Session_Ops{
	workspace_create  = herdr_workspace_create,
	workspace_label   = herdr_workspace_label_get,
	workspace_close   = herdr_workspace_close,
	tab_create        = herdr_tab_create,
	tab_close         = herdr_tab_close,
	tab_rename        = herdr_tab_rename,
	tab_count         = herdr_tab_count_of,
	pane_run          = herdr_pane_run,
	pane_reset        = herdr_pane_reset,
	pane_close        = herdr_pane_close,
	pane_get          = herdr_pane_get,
	pane_process_info = herdr_pane_process_info,
}

herdr_session_surface :: proc(herdr: string, call: Surface_Call) -> Session_Surface {
	return Session_Surface{handle = herdr, call = call, ops = &herdr_ops}
}

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

Herdr_Error_Response :: struct {
	error: struct {
		message: string,
	},
}

// The default PR transport: the Herdr CLI with trimmed output.
herdr_cli_call :: proc(args: []string) -> (out, detail: string, ok: bool) {
	command := make([]string, len(args)+1, context.temp_allocator)
	command[0] = "herdr"
	copy(command[1:], args)
	return run_tool(command, "")
}

// Runs one Herdr command. With an injected transport the buffers are temp-owned and
// herdr_release leaves them alone.
herdr_exec :: proc(s: Session_Surface, args: []string, allocator := context.allocator) -> (stdout, stderr: []byte, err: string) {
	if s.call != nil {
		out, detail, ok := s.call(args)
		return transmute([]byte)out, nil, ok ? "" : detail
	}
	return run_herdr(s.handle, args, allocator)
}

herdr_release :: proc(s: Session_Surface, stdout, stderr: []byte, allocator := context.allocator) {
	if s.call == nil {
		delete(stdout, allocator)
		delete(stderr, allocator)
	}
}

run_herdr :: proc(herdr: string, args: []string, allocator := context.allocator) -> (stdout, stderr: []byte, err: string) {
	span_begin("herdr call")
	defer span_end()
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
		owned_detail, clone_err := strings.clone(detail, context.temp_allocator)
		if clone_err != nil {
			return stdout, stderr, "Herdr command failed"
		}
		return stdout, stderr, owned_detail
	}
	return stdout, stderr, ""
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

// Moves the parsed ids into the caller's allocator and frees the parse.
herdr_opened :: proc(response: ^Herdr_Response, allocator: runtime.Allocator) -> Opened_Pane {
	opened := Opened_Pane{
		workspace_id = strings.clone(response.result.workspace.workspace_id, allocator),
		tab_id       = strings.clone(response.result.tab.tab_id, allocator),
		pane_id      = strings.clone(response.result.root_pane.pane_id, allocator),
	}
	destroy_struct(response, allocator)
	return opened
}

herdr_workspace_create :: proc(s: Session_Surface, cwd, label: string, allocator := context.allocator) -> (opened: Opened_Pane, err: string) {
	stdout, stderr, run_err := herdr_exec(s, []string{"workspace", "create", "--cwd", cwd, "--label", label, "--no-focus"}, allocator)
	defer herdr_release(s, stdout, stderr, allocator)
	if run_err != "" {
		return {}, run_err
	}
	response: Herdr_Response
	if json.unmarshal_string(transmute(string)stdout, &response, .JSON, allocator) != nil || response.result.type != "workspace_created" || response.result.workspace.workspace_id == "" || response.result.tab.tab_id == "" || response.result.root_pane.pane_id == "" {
		destroy_struct(&response, allocator)
		return {}, "Herdr returned an invalid workspace response"
	}
	return herdr_opened(&response, allocator), ""
}

herdr_tab_create :: proc(s: Session_Surface, workspace_id, shot_id, cwd: string, allocator := context.allocator) -> (opened: Opened_Pane, err: string) {
	label := fmt.tprintf("Shot %s", shot_id)
	stdout, stderr, run_err := herdr_exec(s, []string{"tab", "create", "--workspace", workspace_id, "--cwd", cwd, "--label", label, "--no-focus"}, allocator)
	defer herdr_release(s, stdout, stderr, allocator)
	if run_err != "" {
		return {}, run_err
	}
	response: Herdr_Response
	if json.unmarshal_string(transmute(string)stdout, &response, .JSON, allocator) != nil || response.result.type != "tab_created" || response.result.tab.tab_id == "" || response.result.root_pane.pane_id == "" {
		destroy_struct(&response, allocator)
		return {}, "Herdr returned an invalid tab response"
	}
	return herdr_opened(&response, allocator), ""
}

herdr_tab_rename :: proc(s: Session_Surface, tab_id, shot_id: string) -> string {
	label := fmt.tprintf("Shot %s", shot_id)
	stdout, stderr, err := herdr_exec(s, []string{"tab", "rename", tab_id, label})
	defer herdr_release(s, stdout, stderr)
	return err
}

herdr_pane_run :: proc(s: Session_Surface, pane_id, command: string) -> string {
	stdout, stderr, err := herdr_exec(s, []string{"pane", "run", pane_id, command})
	defer herdr_release(s, stdout, stderr)
	return err
}

// Closing the tab hangs up the Station's terminal. The outcome is the caller's to ignore.
herdr_tab_close :: proc(s: Session_Surface, tab_id: string) -> bool {
	stdout, stderr, err := herdr_exec(s, []string{"tab", "close", tab_id})
	defer herdr_release(s, stdout, stderr)
	return err == ""
}

herdr_workspace_close :: proc(s: Session_Surface, workspace_id: string) -> bool {
	stdout, stderr, err := herdr_exec(s, []string{"workspace", "close", workspace_id})
	defer herdr_release(s, stdout, stderr)
	return err == ""
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

// "" label with ok = true means the reply could not be read.
herdr_workspace_label_get :: proc(s: Session_Surface, workspace_id: string) -> (label, detail: string, ok: bool) {
	out, err := herdr_temp_call(s, []string{"workspace", "get", workspace_id})
	if err != "" {
		return "", err, false
	}
	response: Herdr_Workspace_Response
	if json.unmarshal_string(out, &response, .JSON, context.temp_allocator) != nil {
		return "", "", true
	}
	return response.result.workspace.label, "", true
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

herdr_tab_count_of :: proc(s: Session_Surface, workspace_id: string) -> (count: int, ok: bool) {
	out, err := herdr_temp_call(s, []string{"tab", "list", "--workspace", workspace_id})
	if err != "" {
		return 0, false
	}
	response: Herdr_Tab_Response
	if json.unmarshal_string(out, &response, .JSON, context.temp_allocator) != nil {
		return -1, true
	}
	return len(response.result.tabs), true
}

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

herdr_pane_get :: proc(s: Session_Surface, pane_id: string) -> (tab_id, workspace_id: string, ok: bool) {
	out, err := herdr_temp_call(s, []string{"pane", "get", pane_id})
	if err != "" {
		return "", "", false
	}
	response: Herdr_Pane_Response
	if json.unmarshal_string(out, &response, .JSON, context.temp_allocator) != nil {
		return "", "", true
	}
	return response.result.pane.tab_id, response.result.pane.workspace_id, true
}

// Output and error text both live on the temp allocator, like the PR transport.
herdr_temp_call :: proc(s: Session_Surface, args: []string) -> (out, err: string) {
	if s.call != nil {
		text, detail, ok := s.call(args)
		return text, ok ? "" : detail
	}
	stdout, _, run_err := run_herdr(s.handle, args, context.temp_allocator)
	return string(stdout), run_err
}

// The pool's reset types a printf into the pane. Herdr takes the workspace id
// first here, unlike pane_run; that argument order is preserved as it was.
herdr_pane_reset :: proc(s: Session_Surface, workspace_id, pane_id: string) -> bool {
	cmd := []string{
		s.handle, "pane", "run", workspace_id, pane_id,
		"printf '%s' '" + PANE_RESET_SEQUENCE + "'",
	}
	result, _, stderr, exec_err := os.process_exec(os.Process_Desc{command = cmd}, context.temp_allocator)
	// stdout and stderr belong to the temp allocator; freeing them would be an
	// invalid free, which aborts the process inside libmalloc. The arena reclaims them.
	if exec_err != nil || !result.success {
		when ODIN_DEBUG {
			log_pane_failure("pane reset", pane_id, exec_err, string(stderr))
		}
		return false
	}
	return true
}

herdr_pane_close :: proc(s: Session_Surface, workspace_id, pane_id: string) -> bool {
	cmd := []string{s.handle, "pane", "close", workspace_id, pane_id}
	result, stdout, stderr, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	if err != nil || !result.success {
		when ODIN_DEBUG {
			log_pane_failure("pane close", pane_id, err, string(stderr))
		}
		return false
	}
	return true
}

// The foreground process group Herdr reports for the pane is the Station the
// pane's shell started. A pane whose command has not started yet reports the
// shell itself, which is not the Station, and a missing or unreadable answer
// leaves the identity unknown rather than guessing.
herdr_pane_process_info :: proc(s: Session_Surface, pane_id: string) -> Process_Identity {
	stdout, _, run_err := run_herdr(s.handle, []string{"pane", "process-info", "--pane", pane_id}, context.temp_allocator)
	if run_err != "" {
		return {}
	}
	response: Herdr_Process_Info_Response
	if json.unmarshal_string(string(stdout), &response, .JSON, context.temp_allocator) != nil {
		return {}
	}
	info := response.result.process_info
	if pid := info.foreground_process_group_id; pid > 0 && pid != info.shell_pid {
		return Process_Identity{pid = pid}
	}
	for process in info.foreground_processes {
		if process.pid > 0 && process.pid != info.shell_pid {
			return Process_Identity{pid = process.pid}
		}
	}
	return {}
}

Herdr_Process_Info_Response :: struct {
	result: Herdr_Process_Info_Result,
}

Herdr_Process_Info_Result :: struct {
	type:         string,
	process_info: Herdr_Process_Info,
}

Herdr_Pane_Process :: struct {
	pid: int `json:"pid"`,
}

Herdr_Process_Info :: struct {
	pane_id:                     string `json:"pane_id"`,
	shell_pid:                   int `json:"shell_pid"`,
	foreground_process_group_id: int `json:"foreground_process_group_id"`,
	foreground_processes:        [dynamic]Herdr_Pane_Process `json:"foreground_processes"`,
}

log_pane_failure :: proc(what, pane_id: string, err: os.Error, stderr: string) {
	log.warnf("%s: pane %s failed: %v, %s", what, pane_id, err, stderr)
}
