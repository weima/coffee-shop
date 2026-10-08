package main

import "core:fmt"
import "core:os"
import "core:strings"

// Shared paths are linked, not copied, so a Station can use the Beans'
// installed dependencies without duplicating them. Only gitignored paths are
// allowed: a tracked path would collide with the Station's own checkout, and an
// ignored one never shows up as a change.
validate_shared_paths :: proc(repo: string, share: []string) -> string {
	for path in share {
		full := fmt.tprintf("%s/%s", repo, path)
		if !os.exists(full) {
			return fmt.tprintf("shared path %q does not exist in the Beans repository", path)
		}
		state, stdout, stderr, err := os.process_exec(os.Process_Desc{
			command = []string{"git", "-C", repo, "check-ignore", "-q", "--", path},
		}, context.allocator)
		delete(stdout)
		delete(stderr)
		if err != nil {
			return "could not run Git to check shared paths"
		}
		// Exit code 1 means "not ignored"; anything else but 0 is a Git failure.
		if state.exit_code == 1 {
			return fmt.tprintf("shared path %q must be gitignored so it never appears in a Station's changes", path)
		}
		if !state.success {
			return fmt.tprintf("could not check whether shared path %q is gitignored", path)
		}
	}
	return ""
}

// A ".gitignore" line such as "node_modules/" matches only directories, so a
// symlink to one would show up as an untracked change in every Station. Anchored
// entries without a trailing slash match the symlink too. They go in the
// repository's shared info/exclude file, which linked worktrees also read; they
// are redundant for the Beans' real directories, which are already ignored.
exclude_shared_paths :: proc(repo: string, share: []string) -> string {
	if len(share) == 0 {
		return ""
	}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{
		command = []string{"git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude"},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	if err != nil || !state.success {
		return "could not locate the Beans repository's info/exclude file"
	}
	exclude_path := strings.clone(strings.trim_space(string(stdout)), context.temp_allocator)

	existing, _ := os.read_entire_file(exclude_path, context.temp_allocator)
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, string(existing))
	if len(existing) > 0 && existing[len(existing) - 1] != '\n' {
		strings.write_byte(&builder, '\n')
	}
	changed := false
	for path in share {
		entry := fmt.tprintf("/%s", path)
		already := false
		remaining := string(existing)
		for line in strings.split_lines_iterator(&remaining) {
			if line == entry {
				already = true
			}
		}
		if !already {
			fmt.sbprintfln(&builder, "%s", entry)
			changed = true
		}
	}
	if !changed {
		return ""
	}
	if slash := strings.last_index_byte(exclude_path, '/'); slash >= 0 {
		directory := exclude_path[:slash]
		if !os.is_dir(directory) && os.make_directory_all(directory, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
			return "could not create the Beans repository's info directory"
		}
	}
	if os.write_entire_file(exclude_path, strings.to_string(builder), os.Permissions{.Read_User, .Write_User}) != nil {
		return "could not update the Beans repository's info/exclude file"
	}
	return ""
}

link_shared_paths :: proc(repo, station_path: string, share: []string) -> string {
	for path in share {
		target := fmt.tprintf("%s/%s", station_path, path)
		if os.exists(target) {
			return fmt.tprintf("the Station already contains shared path %q", path)
		}
		if slash := strings.last_index_byte(path, '/'); slash >= 0 {
			parent := fmt.tprintf("%s/%s", station_path, path[:slash])
			if !os.is_dir(parent) && os.make_directory_all(parent, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil && !os.is_dir(parent) {
				return fmt.tprintf("could not create the parent directory for shared path %q", path)
			}
		}
		if err := os.symlink(fmt.tprintf("%s/%s", repo, path), target); err != nil {
			return fmt.tprintf("could not link shared path %q: %v", path, err)
		}
	}
	return ""
}

// Dependency directories that are usually gitignored and therefore missing from
// a fresh Station. Used only to suggest sharing; nothing is shared automatically.
COMMON_DEPENDENCY_PATHS :: [?]string{"node_modules", "vendor/bundle", ".bundle", ".venv"}

share_suggestions :: proc(beans_path, station_path: string, share: []string) -> [dynamic]string {
	suggestions: [dynamic]string
	for candidate in COMMON_DEPENDENCY_PATHS {
		already_shared := false
		for path in share {
			if path == candidate {
				already_shared = true
			}
		}
		if already_shared || !os.exists(fmt.tprintf("%s/%s", beans_path, candidate)) || os.exists(fmt.tprintf("%s/%s", station_path, candidate)) {
			continue
		}
		append(&suggestions, fmt.aprintf("Beans has %q but this Station does not; if the checks need it, add it to the Recipe's \"share\" list", candidate))
	}
	return suggestions
}
