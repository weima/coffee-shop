package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

repository_name :: proc(repo: string) -> string {
	end := len(repo)
	for end > 1 && repo[end-1] == '/' { end -= 1 }
	start := end
	for start > 0 && repo[start-1] != '/' { start -= 1 }
	base := repo[start:end]
	bytes: [dynamic]u8
	defer delete(bytes)
	for c in base {
		if len(bytes) >= 32 { break }
		switch c {
		case 'a'..='z', 'A'..='Z', '0'..='9', '-', '_': append(&bytes, u8(c))
		case: append(&bytes, '-');
		}
	}
	name := strings.trim(string(bytes[:]), "-")
	return name == "" ? strings.clone("repository") : strings.clone(name)
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

shell_quote :: proc(value: string) -> string {
	escaped, was_allocation := strings.replace_all(value, "'", "'\\''", context.allocator)
	quoted := fmt.aprintf("'%s'", escaped)
	if was_allocation {
		delete(escaped)
	}
	return quoted
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
