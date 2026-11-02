package rachel_e2e

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

TYPED_PROCEDURE :: `
// twice returns n doubled.
twice :: proc(n: int) -> int {
	return n * 2
}
`

TYPING_CHAR_DELAY :: 25 * time.Millisecond
TYPING_LINE_DELAY :: 150 * time.Millisecond

// A human types continuously, with short pauses at line ends. The quiet window has
// to hold through that, or every keystroke produces a syntax-error verdict.
@(test)
test_human_speed_typing_never_reports_a_broken_file :: proc(t: ^testing.T) {
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
	module_path := fmt.aprintf("%s/module.odin", project, allocator = context.allocator)
	defer delete(module_path, context.allocator)
	justfile_path := fmt.aprintf("%s/justfile", project, allocator = context.allocator)
	defer delete(justfile_path, context.allocator)
	log_path := fmt.aprintf("%s/typing.log", build.dir, allocator = context.allocator)
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

	file, open_err := os.open(module_path, {.Write, .Append})
	testing.expectf(t, open_err == nil, "cannot open %s: %v", module_path, open_err)
	if open_err != nil {
		return
	}
	payload := TYPED_PROCEDURE
	for i in 0 ..< len(payload) {
		_, _ = os.write_string(file, payload[i:i + 1])
		if payload[i] == '\n' {
			time.sleep(TYPING_LINE_DELAY)
		} else {
			time.sleep(TYPING_CHAR_DELAY)
		}
	}
	os.close(file)

	testing.expectf(t, wait_file_count(log_path, "[OK] just check", 2, 20_000), "no check after typing, log: %s", file_text(log_path))
	failed := file_count(log_path, "[ERROR] just check failed")
	testing.expectf(t, failed == 0, "Rachel checked a half-typed file %d time(s); the quiet window did not hold, log: %s", failed, file_text(log_path))
}
