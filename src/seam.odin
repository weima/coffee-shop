package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"

Seam_Error :: struct {
	type:   string `json:"type"`,
	reason: string `json:"reason"`,
}

// The seam the Go orchestrator drives. Repository work stays in Odin, but it becomes an
// explicit command instead of a host-internal call, so orchestration can run in another
// process without linking this code.
//
// Both commands print exactly one JSON object on stdout and exit non-zero on failure, so
// a caller reports the reason verbatim instead of parsing prose:
//
//	{"type":"error","reason":"..."}
//
// On success they print nothing and exit 0.

SEAM_BRANCH_MAX :: 64

// A worktree branch is a Git ref the host generates (`cs-host-<request>-<shot>`), so the
// same shape rule as a Blend branch applies: no spaces, no path syntax, no shell
// metacharacters.
valid_seam_branch :: proc(branch: string) -> bool {
	if len(branch) < 1 || len(branch) > SEAM_BRANCH_MAX {
		return false
	}
	for c in branch {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_':
		case:
			return false
		}
	}
	// A leading '-' would be read as an option by Git.
	return branch[0] != '-'
}

// Creates the Shot's worktree at `dir` on a new `branch`. Nothing is created unless every
// check passes: an existing directory, a non-repository or a bad branch changes nothing.
prepare_worktree :: proc(repo, branch, dir: string) -> (reason: string) {
	if !filepath.is_abs(repo) {
		return "repo must be an absolute path"
	}
	if !filepath.is_abs(dir) {
		return "dir must be an absolute path"
	}
	if !valid_seam_branch(branch) {
		return "branch must be 1 to 64 characters using letters, digits, - or _"
	}
	valid, repo_err := is_git_repository(repo, context.temp_allocator)
	if repo_err != "" {
		return repo_err
	}
	if !valid {
		return "repo is not a Git repository"
	}
	if os.exists(dir) {
		return "dir already exists"
	}
	if create_err := create_git_worktree(repo, branch, dir, context.temp_allocator); create_err != "" {
		return create_err
	}
	return ""
}

// Removes the worktree at `dir`, which must belong to `repo`. A missing directory is
// already released, so it is not an error: a retry after a crash must succeed.
release_worktree :: proc(repo, dir: string) -> (reason: string) {
	if !filepath.is_abs(repo) {
		return "repo must be an absolute path"
	}
	if !filepath.is_abs(dir) {
		return "dir must be an absolute path"
	}
	if !os.exists(dir) {
		return ""
	}
	if remove_err := remove_worktree(repo, dir, default_pr_backend()); remove_err != "" {
		return remove_err
	}
	return ""
}

// run_prepare and run_release are the CLI handlers: one JSON object on failure.
run_prepare :: proc(repo, branch, dir: string) -> int {
	if reason := prepare_worktree(repo, branch, dir); reason != "" {
		write_seam_error(reason)
		return 1
	}
	return 0
}

run_release :: proc(repo, dir: string) -> int {
	if reason := release_worktree(repo, dir); reason != "" {
		write_seam_error(reason)
		return 1
	}
	return 0
}

write_seam_error :: proc(reason: string) {
	message := Seam_Error{type = "error", reason = reason}
	data, err := json.marshal(message, {}, context.temp_allocator)
	if err != nil {
		fmt.println(`{"type":"error","reason":"could not encode the reason"}`)
		return
	}
	fmt.println(string(data))
}
