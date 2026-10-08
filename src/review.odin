package main

import "core:fmt"
import "core:os"
import "base:runtime"
import "core:strings"

Review_Result :: struct {
	performed: bool,
	findings:  string,
	detail:    string,
}

review_station :: proc(station_path, base_ref, pi: string, max_diff_bytes := 60000, allocator := context.allocator) -> Review_Result {
	if !os.exists(fmt.tprintf("%s/standards.md", station_path)) {
		return review_result(false, "", "standards.md is missing in the Beans repository; no review was performed", allocator)
	}

	diff_state, diff_bytes, diff_stderr, diff_err := os.process_exec(os.Process_Desc{
		working_dir = station_path,
		command = []string{"git", "-C", station_path, "diff", base_ref},
	}, allocator)
	defer delete(diff_bytes, allocator)
	defer delete(diff_stderr, allocator)
	if diff_err != nil || !diff_state.success || diff_state.exit_code != 0 {
		reason := review_git_error("git diff", diff_state.exit_code, diff_stderr)
		if diff_err != nil {
			reason = fmt.tprintf("could not start Git diff: %v", diff_err)
		}
		return review_result(false, "", reason, allocator)
	}

	files_state, files_bytes, files_stderr, files_err := os.process_exec(os.Process_Desc{
		working_dir = station_path,
		command = []string{"git", "-C", station_path, "ls-files", "--others", "--exclude-standard"},
	}, allocator)
	defer delete(files_bytes, allocator)
	defer delete(files_stderr, allocator)
	if files_err != nil || !files_state.success || files_state.exit_code != 0 {
		reason := review_git_error("git ls-files", files_state.exit_code, files_stderr)
		if files_err != nil {
			reason = fmt.tprintf("could not start Git ls-files: %v", files_err)
		}
		return review_result(false, "", reason, allocator)
	}

	if len(diff_bytes) == 0 && len(files_bytes) == 0 {
		return review_result(false, "", "no changes to review", allocator)
	}
	truncated := max_diff_bytes < len(diff_bytes)
	if truncated {
		diff_bytes = diff_bytes[:max(0, max_diff_bytes)]
	}
	prompt := review_prompt(transmute(string)diff_bytes, transmute(string)files_bytes, truncated, allocator)
	defer delete(prompt, allocator)

	command := [9]string{pi, "--print", "--no-session", "--no-extensions", "--no-mcp", "--tools", "read,grep,find,ls", "--", prompt}
	state, stdout, stderr, run_err := os.process_exec(os.Process_Desc{working_dir = station_path, command = command[:]}, allocator)
	defer delete(stdout, allocator)
	defer delete(stderr, allocator)
	if run_err != nil {
		return review_result(false, "", fmt.tprintf("could not start Pi: %v", run_err), allocator)
	}
	if !state.success || state.exit_code != 0 {
		return review_result(false, "", fmt.tprintf("Pi exited with code %d", state.exit_code), allocator)
	}
	return review_result(true, strings.trim_space(transmute(string)stdout), "", allocator)
}

review_prompt :: proc(diff, untracked: string, diff_truncated: bool, allocator := context.allocator) -> string {
	truncation_note := ""
	if diff_truncated {
		truncation_note = "\nThe diff was truncated to the configured byte limit; review only the included start of it.\n"
	}
	previous_allocator := context.allocator
	context.allocator = allocator
	defer context.allocator = previous_allocator
	return fmt.aprintf("You are performing a read-only review. Read standards.md in the repository root and check the change below against it. Report concrete findings with file and line and a severity (high/medium/low). Say \"No findings\" when there are none. Do not modify files; never modify files in the repository. Keep your answer under 400 words.%s\nDiff:\n%s\nUntracked files:\n%s", truncation_note, diff, untracked)
}

destroy_review_result :: proc(result: ^Review_Result, allocator := context.allocator) {
	delete(result.findings, allocator)
	delete(result.detail, allocator)
	result^ = Review_Result{}
}

review_result :: proc(performed: bool, findings, detail: string, allocator: runtime.Allocator) -> Review_Result {
	owned_findings, findings_err := strings.clone(findings, allocator)
	owned_detail, detail_err := strings.clone(detail, allocator)
	if findings_err != nil || detail_err != nil {
		delete(owned_findings, allocator)
		delete(owned_detail, allocator)
		return Review_Result{}
	}
	return Review_Result{performed = performed, findings = owned_findings, detail = owned_detail}
}

review_git_error :: proc(operation: string, exit_code: int, stderr: []byte) -> string {
	message := strings.trim_space(transmute(string)stderr)
	if message != "" {
		return fmt.tprintf("Git %s failed: %s", operation, message)
	}
	return fmt.tprintf("Git %s failed with code %d", operation, exit_code)
}
