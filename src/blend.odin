package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

HOST_BLEND_BRANCH_MAX :: 64

Blend_Request :: struct {
	repo:    string,
	base:    string,
	commits: []string,
	branch:  string,
	message: string,
}

// Shape checks only: no Git call happens here, so an invalid request changes nothing.
blend_parse :: proc(root: json.Object) -> (request: Blend_Request, reason: string) {
	repo, repo_ok := host_string(root, "repo")
	base, base_ok := host_string(root, "base")
	branch, branch_ok := host_string(root, "branch")
	message, message_ok := host_string(root, "message")
	if !repo_ok || !filepath.is_abs(repo) {
		return Blend_Request{}, "repo must be an absolute path"
	}
	if !base_ok || !valid_commit_hash(base) {
		return Blend_Request{}, "base must be 7 to 40 lowercase hex characters"
	}
	if !branch_ok || !valid_blend_branch(branch) {
		return Blend_Request{}, "branch must be 1 to 64 characters using letters, digits, - or _"
	}
	if !message_ok || !valid_commit_message(message) {
		return Blend_Request{}, "message must be 1 to 200 characters on one line"
	}
	commits, commits_reason := blend_parse_commits(root)
	if commits_reason != "" {
		return Blend_Request{}, commits_reason
	}
	return Blend_Request{repo = repo, base = base, commits = commits, branch = branch, message = message}, ""
}

blend_parse_commits :: proc(root: json.Object) -> ([]string, string) {
	value, found := root["commits"]
	list, is_list := value.(json.Array)
	if !found || !is_list || len(list) < HOST_BLEND_COMMITS_MIN || len(list) > HOST_BLEND_COMMITS_MAX {
		return nil, "commits must list 2 to 20 commit hashes"
	}
	commits := make([]string, len(list), context.temp_allocator)
	for item, i in list {
		hash, is_string := item.(json.String)
		if !is_string || !valid_commit_hash(hash) {
			return nil, "each commit must be 7 to 40 lowercase hex characters"
		}
		if slice_contains(commits[:i], hash) {
			return nil, "commits must not repeat"
		}
		commits[i] = hash
	}
	return commits, ""
}

valid_blend_branch :: proc(branch: string) -> bool {
	if len(branch) < 1 || len(branch) > HOST_BLEND_BRANCH_MAX {
		return false
	}
	for c in branch {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_':
		case:
			return false
		}
	}
	return true
}

// Git checks that need the repository: it must be one, and the branch must be new.
blend_check_repository :: proc(request: Blend_Request) -> string {
	valid, repo_err := is_git_repository(request.repo, context.temp_allocator)
	if repo_err != "" || !valid {
		return "repo is not a Git repository"
	}
	_, _, exists := blend_git(request.repo, "rev-parse", "--verify", "--quiet", fmt.tprintf("refs/heads/%s", request.branch))
	if exists {
		return "branch already exists"
	}
	return ""
}

// Blend builds one commit on a new branch in a temporary worktree. Any failure after
// the branch exists removes the worktree and the branch, so nothing is left behind.
// The worktree lives under the state root, so a failed run leaves nothing in the Beans.
blend_run :: proc(request_id: string, request: Blend_Request, state_root: string) -> (ok: bool) {
	blend_root, _ := filepath.join({state_root, request_id}, context.temp_allocator)
	worktree, _ := filepath.join({blend_root, "blend"}, context.temp_allocator)
	if _, detail, ok := blend_git(request.repo, "worktree", "add", "-b", request.branch, worktree, request.base); !ok {
		blend_failed(request_id, "", fmt.tprintf("Git could not create the temporary worktree: %s", detail))
		return false
	}
	if failed, detail := blend_pick_all(worktree, request.commits); failed != "" {
		blend_failed_after_branch(request_id, request, worktree, failed, fmt.tprintf("cherry-pick failed: %s", detail))
		return false
	}
	if _, detail, ok := blend_git(worktree, "commit", "-m", request.message); !ok {
		blend_failed_after_branch(request_id, request, worktree, "", fmt.tprintf("commit failed: %s", detail))
		return false
	}
	short, short_detail, short_ok := blend_git(worktree, "rev-parse", "--short", "HEAD")
	if !short_ok {
		blend_failed_after_branch(request_id, request, worktree, "", fmt.tprintf("could not read the new commit: %s", short_detail))
		return false
	}
	// The commit is made and the branch stays, so a worktree that will not go is a warning.
	warning := ""
	if _, detail, ok := blend_git(request.repo, "worktree", "remove", "--force", worktree); !ok {
		warning = fmt.tprintf("the temporary worktree could not be removed: %s", detail)
	}
	host_emit(Host_Event{type = "blended", request_id = request_id, branch = request.branch, commit = short, reason = warning})
	return true
}

// The seam the host drives: one request object in a file, the host's event stream out.
// The file, not argv, keeps the request text away from any shell.
run_blend_command :: proc(request_file: string) -> int {
	data, read_err := os.read_entire_file(request_file, context.allocator)
	if read_err != nil {
		write_error("could not read the blend request file")
		return 1
	}
	defer delete(data)
	value, parse_err := json.parse(data, .JSON, false, context.temp_allocator)
	if parse_err != .None {
		write_error("the blend request is not valid JSON")
		return 1
	}
	root, is_object := value.(json.Object)
	if !is_object {
		write_error("the blend request must be a JSON object")
		return 1
	}
	request_id, id_ok := host_string(root, "request_id")
	if !id_ok || !valid_shot_id(request_id) {
		write_error("the blend request needs a valid request_id")
		return 1
	}
	request, reason := blend_parse(root)
	if reason == "" {
		reason = blend_check_repository(request)
	}
	if reason != "" {
		host_emit(Host_Event{type = "error", request_id = request_id, reason = reason})
		return 1
	}
	state_root, state_err := default_state_root(context.temp_allocator)
	if state_err != "" {
		write_error(state_err)
		return 1
	}
	return 0 if blend_run(request_id, request, state_root) else 1
}

// Applies each commit without committing. It returns the failing commit and Git's
// detail, or an empty commit when every pick applies.
blend_pick_all :: proc(worktree: string, commits: []string) -> (failed, detail: string) {
	for commit in commits {
		if _, git_detail, ok := blend_git(worktree, "cherry-pick", "-n", commit); !ok {
			_, _, _ = blend_git(worktree, "cherry-pick", "--abort")
			return commit, git_detail
		}
	}
	return "", ""
}

blend_failed_after_branch :: proc(request_id: string, request: Blend_Request, worktree, commit, reason: string) {
	detail := reason
	if cleanup := blend_abandon(request, worktree); cleanup != "" {
		detail = fmt.tprintf("%s; %s", reason, cleanup)
	}
	blend_failed(request_id, commit, detail)
}

// The worktree goes first: Git will not delete a branch that a worktree has checked out.
// update-ref deletes the branch this Blend created, without a force flag.
blend_abandon :: proc(request: Blend_Request, worktree: string) -> string {
	if _, detail, ok := blend_git(request.repo, "worktree", "remove", "--force", worktree); !ok {
		return fmt.tprintf("the temporary worktree could not be removed: %s", detail)
	}
	if _, detail, ok := blend_git(request.repo, "update-ref", "-d", fmt.tprintf("refs/heads/%s", request.branch)); !ok {
		return fmt.tprintf("the branch could not be deleted: %s", detail)
	}
	return ""
}

blend_failed :: proc(request_id, commit, reason: string) {
	host_emit(Host_Event{type = "blend_failed", request_id = request_id, commit = commit, reason = reason})
}

// Runs Git in dir from an argument vector, never a shell string. On success it returns
// the trimmed stdout; on failure, Git's stderr or stdout as the detail.
blend_git :: proc(dir: string, args: ..string) -> (out, detail: string, ok: bool) {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "git", "-C", dir)
	append(&command, ..args)
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = command[:]}, context.temp_allocator)
	if err != nil {
		return "", "could not run Git", false
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
		detail = "Git failed"
	}
	return "", detail, false
}
