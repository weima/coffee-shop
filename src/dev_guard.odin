package main

import "core:fmt"
import "core:os"
import "base:runtime"
import "core:strings"
import "core:time"

// Development guard. With `CS_MODE=dev` the binary refuses to run when it is older
// than the source it was built from, so a copied binary from an earlier build
// announces itself instead of quietly running behaviour the source has changed.
// Unset `CS_MODE`, or any other value, means no check at all.

// A source file and when it was last written.
Source_Stamp :: struct {
	path:  string,
	mtime: time.Time,
}

// The staleness rule, with no file system access so the decision can be tested on
// its own. The executable is stale when a source is strictly newer than it, and
// the newest such source is returned so the message can name it. Equal timestamps
// are not stale, and no sources at all cannot be stale.
newest_newer_source :: proc(exe_time: time.Time, sources: []Source_Stamp) -> (Source_Stamp, bool) {
	newest: Source_Stamp
	found := false
	for source in sources {
		if time.diff(exe_time, source.mtime) <= 0 {
			continue
		}
		if !found || time.diff(newest.mtime, source.mtime) > 0 {
			newest = source
			found = true
		}
	}
	return newest, found
}

Dev_Guard_Outcome :: enum {
	Ok,
	Inactive,
	Stale,
}

Dev_Guard_Report :: struct {
	outcome: Dev_Guard_Outcome,
	message: string,
}

// One directory listing and one stat per source file, no recursion and no child
// process, so this is cheap and cannot hang. A source tree the guard cannot read
// leaves it inactive: a guard that cannot see the sources must not block a launch,
// but it must say so. Test files are not part of a built binary and are ignored.
dev_guard_evaluate :: proc(exe_path, repo: string, allocator: runtime.Allocator) -> Dev_Guard_Report {
	src_dir := fmt.tprintf("%s/src", repo)
	entries, read_err := os.read_all_directory_by_path(src_dir, context.temp_allocator)
	if read_err != nil {
		return {
			.Inactive,
			fmt.aprintf("coffee-shop: CS_MODE=dev but %s could not be read (%v), so the staleness guard is inactive.", src_dir, read_err, allocator = allocator),
		}
	}

	exe_time, exe_err := os.last_write_time_by_name(exe_path)
	if exe_err != nil {
		return {
			.Inactive,
			fmt.aprintf("coffee-shop: CS_MODE=dev but the executable %s could not be read (%v), so the staleness guard is inactive.", exe_path, exe_err, allocator = allocator),
		}
	}

	sources := make([dynamic]Source_Stamp, context.temp_allocator)
	for entry in entries {
		if !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_test.odin") {
			continue
		}
		path := fmt.tprintf("%s/%s", src_dir, entry.name)
		mtime, mtime_err := os.last_write_time_by_name(path)
		if mtime_err != nil {
			return {
				.Inactive,
				fmt.aprintf("coffee-shop: CS_MODE=dev but %s could not be read (%v), so the staleness guard is inactive.", path, mtime_err, allocator = allocator),
			}
		}
		append(&sources, Source_Stamp{path = path, mtime = mtime})
	}

	newest, stale := newest_newer_source(exe_time, sources[:])
	if !stale {
		return {.Ok, ""}
	}

	message := fmt.aprintf(
		"coffee-shop: stale development build: %s was built at %v, but %s was written later, at %v.\n"+
		"coffee-shop: this executable is not the code in the source tree, so it can behave differently from the source.\n"+
		"coffee-shop: launch through `odin run src` instead of reusing an older build.",
		exe_path, exe_time, newest.path, newest.mtime, allocator = allocator,
	)
	return {.Stale, message}
}

// Runs once per launch, before any work. Returns the exit code after printing the
// report to stderr.
dev_guard_check :: proc() -> int {
	if os.get_env("CS_MODE", context.temp_allocator) != "dev" {
		return 0
	}

	stderr := os.to_stream(os.stderr)
	repo := os.get_env("CS_DEV_REPO", context.temp_allocator)
	if repo == "" {
		fmt.wprintln(stderr, "coffee-shop: CS_MODE=dev but CS_DEV_REPO is unset, so the staleness guard is inactive. Set CS_DEV_REPO to the checkout root to enable it.")
		return 0
	}

	exe, exe_err := os.get_executable_path(context.temp_allocator)
	if exe_err != nil {
		fmt.wprintfln(stderr, "coffee-shop: CS_MODE=dev but the executable path could not be read (%v), so the staleness guard is inactive.", exe_err)
		return 0
	}

	report := dev_guard_evaluate(exe, repo, context.temp_allocator)
	if report.message != "" {
		fmt.wprintln(stderr, report.message)
	}
	if report.outcome == .Stale {
		return 1
	}
	return 0
}
