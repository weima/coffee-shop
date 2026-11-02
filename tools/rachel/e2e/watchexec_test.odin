package rachel_e2e

import "core:fmt"
import "core:os"
import "core:testing"

BROKEN_SUB_MODULE :: `package sub

two :: proc() -> int {
	return
}
`

@(test)
test_watchexec_batches_narrow_the_check :: proc(t: ^testing.T) {
	if !require_layout(t) {
		return
	}
	if !has_watchexec() {
		fmt.println("SKIP: watchexec is not installed")
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
	sub_dir := fmt.aprintf("%s/sub", project, allocator = context.allocator)
	defer delete(sub_dir, context.allocator)
	if err := os.make_directory(sub_dir); err != nil {
		testing.expectf(t, false, "cannot create %s: %v", sub_dir, err)
		return
	}
	sub_module := fmt.aprintf("%s/other.odin", sub_dir, allocator = context.allocator)
	defer delete(sub_module, context.allocator)
	module_path := fmt.aprintf("%s/module.odin", project, allocator = context.allocator)
	defer delete(module_path, context.allocator)
	log_path := fmt.aprintf("%s/watchexec.log", build.dir, allocator = context.allocator)
	defer delete(log_path, context.allocator)
	// No justfile: Rachel's generated one takes a package argument, so the check
	// count distinguishes a narrowed check from a whole-project one.
	write_file(t, module_path, VALID_MODULE)
	write_file(t, sub_module, "package sub\n\n// two returns 2.\ntwo :: proc() -> int {\n\treturn 2\n}\n")

	process, start_err := spawn_to_log(
		[]string{
			"watchexec",
			"-q",
			"-w",
			project,
			"-d",
			"300ms",
			"-f",
			"*.odin",
			"--emit-events-to=environment",
			"--",
			build.binary,
			"check",
			"--from-env",
			project,
		},
		log_path,
	)
	testing.expectf(t, start_err == nil, "cannot start watchexec: %v", start_err)
	if start_err != nil {
		return
	}
	defer stop_process(process)

	testing.expectf(t, wait_file_contains(log_path, "rachel: ok (2 checked)", 20_000), "no startup verdict, log: %s", file_text(log_path))

	write_file(t, sub_module, BROKEN_SUB_MODULE)
	testing.expectf(
		t,
		wait_file_contains(log_path, "rachel: fail (1 of 1, 1 error)", 20_000),
		"no narrowed failure verdict, log: %s",
		file_text(log_path),
	)
	testing.expectf(t, file_contains(log_path, "sub/other.odin"), "verdict does not name the changed file")
	testing.expectf(t, file_count(log_path, "[Running:") == 0, "watchexec banners leaked into the verdict stream")

	write_file(t, sub_module, "package sub\n\n// two returns 2.\ntwo :: proc() -> int {\n\treturn 2\n}\n")
	testing.expectf(
		t,
		wait_file_contains(log_path, "rachel: ok (1 checked)", 20_000),
		"no recovery verdict, log: %s",
		file_text(log_path),
	)
}
