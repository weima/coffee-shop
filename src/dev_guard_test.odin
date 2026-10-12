package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The staleness decision on its own, with no file system and no built binary.
@(test)
test_staleness_compares_against_the_newest_source :: proc(t: ^testing.T) {
	now := time.now()
	sources := []Source_Stamp{
		{path = "src/a.odin", mtime = time.time_add(now, -2 * time.Hour)},
		{path = "src/b.odin", mtime = time.time_add(now, -1 * time.Hour)},
	}

	stale: bool
	newest: Source_Stamp

	// Newer than every source: fresh.
	_, stale = newest_newer_source(time.time_add(now, time.Hour), sources)
	testing.expect(t, !stale, "an executable newer than every source is fresh")

	// Older than one source.
	newest, stale = newest_newer_source(time.time_add(now, -90 * time.Minute), sources)
	testing.expect(t, stale, "an executable older than a source is stale")
	testing.expect_value(t, newest.path, "src/b.odin")

	// Older than several: the newest of them is the one named.
	newest, stale = newest_newer_source(time.time_add(now, -3 * time.Hour), sources)
	testing.expect(t, stale, "an executable older than every source is stale")
	testing.expect_value(t, newest.path, "src/b.odin")

	// Equal timestamps are not stale.
	_, stale = newest_newer_source(time.time_add(now, -time.Hour), sources)
	testing.expect(t, !stale, "a source written at the same time as the executable is not newer")

	// No sources at all cannot be stale.
	_, stale = newest_newer_source(now, nil)
	testing.expect(t, !stale, "an empty source set is never stale")
}

// The CLI itself, launched as a separate process, so a refusal is a real non-zero
// exit with a real message. Each launch gets its own temporary CS_STATE_DIR.
@(test)
test_stale_executable_is_refused :: proc(t: ^testing.T) {
	root, repo, exe := dev_guard_fixture(t, stale = true)
	code, errout := dev_guard_run(exe, fmt.tprintf("%s/state", root), "dev", repo)

	testing.expect(t, code != 0, "a stale executable must be refused")
	testing.expect(t, strings.contains(errout, exe), "the message names the stale executable")
	testing.expect(t, strings.contains(errout, "src/main.odin"), "the message names the newer source")
	source := fmt.tprintf("%s/src/main.odin", repo)
	source_mtime, mtime_err := os.last_write_time_by_name(source)
	testing.expect(t, mtime_err == nil, "the fixture source is readable")
	testing.expect(t, strings.contains(errout, fmt.tprintf("%v", source_mtime)), "the message carries the newer source's timestamp")
	testing.expect(t, strings.contains(errout, "odin run"), "the message says to launch through odin run")
}

@(test)
test_fresh_executable_is_allowed :: proc(t: ^testing.T) {
	root, repo, exe := dev_guard_fixture(t, stale = false)
	code, errout := dev_guard_run(exe, fmt.tprintf("%s/state", root), "dev", repo)

	testing.expect_value(t, code, 0)
	testing.expect(t, !strings.contains(errout, "stale"), errout)
}

@(test)
test_dev_mode_without_a_repo_warns_and_still_runs :: proc(t: ^testing.T) {
	root, _, exe := dev_guard_fixture(t, stale = true)
	code, errout := dev_guard_run(exe, fmt.tprintf("%s/state", root), "dev", "")

	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(errout, "inactive"), "the warning says the guard is inactive")
	testing.expect(t, strings.contains(errout, "CS_DEV_REPO"), "the warning names the variable that enables the guard")
}

@(test)
test_unset_dev_mode_skips_the_check :: proc(t: ^testing.T) {
	root, repo, exe := dev_guard_fixture(t, stale = true)
	code, errout := dev_guard_run(exe, fmt.tprintf("%s/state", root), "", repo)

	testing.expect_value(t, code, 0)
	testing.expect(t, !strings.contains(errout, "stale"), "no CS_MODE means no staleness check")
}

// A built CLI, a source tree, and an executable with a controlled timestamp. The
// source is written now, so touching either file into the past is enough to pick
// the wanted direction without waiting for the clock.
dev_guard_fixture :: proc(t: ^testing.T, stale: bool) -> (root, repo, exe: string) {
	objects, err := os.make_directory_temp(TEMP_DIR, "coffee-shop-dev-guard-*", context.temp_allocator)
	testing.expect(t, err == nil, "temporary directory")
	if err != nil {
		return
	}
	root = objects
	repo = fmt.tprintf("%s/repo", root)
	_ = os.make_directory_all(fmt.tprintf("%s/src", repo))
	source := fmt.tprintf("%s/src/main.odin", repo)
	_ = os.write_entire_file(source, "package main\n", os.Permissions{.Read_User, .Write_User})

	exe = fmt.tprintf("%s/coffee-shop", root)
	copy_err := os.copy_file(exe, dev_guard_build(t))
	testing.expect(t, copy_err == nil, "copy the built executable")

	if stale {
		dev_guard_set_mtime(t, exe, "200001010000")
	} else {
		dev_guard_set_mtime(t, source, "200001010000")
	}
	return
}

// Built on demand because only a real build produces a real executable.
dev_guard_build :: proc(t: ^testing.T) -> string {
	bin, err := os.make_directory_temp(TEMP_DIR, "coffee-shop-dev-guard-bin-*", context.temp_allocator)
	testing.expect(t, err == nil, "temporary build directory")
	if err != nil {
		return ""
	}
	binary := fmt.tprintf("%s/coffee-shop", bin)
	code, _, build_err := e2e_exec([]string{"odin", "build", "src", fmt.tprintf("-out:%s", binary)}, nil)
	testing.expect(t, code == 0, build_err)
	return binary
}

dev_guard_set_mtime :: proc(t: ^testing.T, path, stamp: string) {
	code, _, err := e2e_exec([]string{"touch", "-t", stamp, path}, nil)
	testing.expect(t, code == 0, err)
}

dev_guard_run :: proc(exe, state, mode, repo: string) -> (code: int, stderr: string) {
	environment := make([dynamic]string, context.temp_allocator)
	append(&environment, fmt.tprintf("PATH=%s", os.get_env("PATH", context.temp_allocator)))
	append(&environment, fmt.tprintf("CS_STATE_DIR=%s", state))
	if mode != "" {
		append(&environment, fmt.tprintf("CS_MODE=%s", mode))
	}
	if repo != "" {
		append(&environment, fmt.tprintf("CS_DEV_REPO=%s", repo))
	}
	code, _, stderr = e2e_exec([]string{exe, "--help"}, environment[:])
	return
}
