package rachel_e2e

import "core:fmt"
import "core:os"
import "core:testing"

NEW_PROCEDURE_MODULE :: `package demo

// one returns 1.
one :: proc() -> int {
	return 1
}

multiply :: proc(a, b: int) -> int {
	return a * b
}
`

@(test)
test_watch_loop_reacts_to_a_saved_file :: proc(t: ^testing.T) {
	if !require_layout(t) {
		return
	}
	build := build_rachel(t)
	defer build_destroy(&build)
	if build.binary == "" {
		return
	}
	project := make_project(t)
	defer project_destroy(&project)
	if project == "" {
		return
	}
	// fmt.tprintf lives in a temporary ring, so a stored path must be heap-owned.
	module_path := fmt.aprintf("%s/module.odin", project, allocator = context.allocator)
	defer delete(module_path, context.allocator)
	justfile_path := fmt.aprintf("%s/justfile", project, allocator = context.allocator)
	defer delete(justfile_path, context.allocator)
	companion_path := fmt.aprintf("%s/module_test.odin", project, allocator = context.allocator)
	defer delete(companion_path, context.allocator)
	log_path := fmt.aprintf("%s/watch.log", build.dir, allocator = context.allocator)
	defer delete(log_path, context.allocator)
	write_file(t, justfile_path, CUSTOM_JUSTFILE)
	write_file(t, module_path, VALID_MODULE)
	process, start_err := spawn_to_log([]string{build.binary, project}, log_path)
	testing.expectf(t, start_err == nil, "cannot start rachel: %v", start_err)
	if start_err != nil {
		return
	}
	defer stop_process(process)

	testing.expectf(t, wait_file_contains(log_path, "[OK] just check", 15_000), "no startup check, log: %s", file_text(log_path))

	write_file(t, module_path, NEW_PROCEDURE_MODULE)
	testing.expectf(t, wait_file_contains(log_path, "[WARN] new procedure multiply", 15_000), "no contract warning, log: %s", file_text(log_path))
	testing.expectf(t, wait_file_contains(log_path, "Created companion test file", 15_000), "no companion test, log: %s", file_text(log_path))
	testing.expectf(t, wait_file_contains(log_path, "[OK] just test", 15_000), "no package test, log: %s", file_text(log_path))

	testing.expectf(t, os.is_file(companion_path), "companion test file missing")
	testing.expectf(
		t,
		file_count(log_path, "Created companion test file") == 1,
		"companion test was created %d times; the watcher is looping",
		file_count(log_path, "Created companion test file"),
	)
}
