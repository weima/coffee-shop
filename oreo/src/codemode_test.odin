package oreo

// The codemode tool's tests: the default set carries it, one real script runs
// in a temporary work directory and reports its output, a gate rejection
// compiles and runs nothing, a script reaches the tool API, a non-zero exit
// keeps its output, and no call leaves its work directory behind.
//
// Every case that runs the tool goes through codemode_test_run, which is
// serialized by codemode_test_lock so the work directory it observes belongs to
// the call the test just made.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
test_codemode_tool_is_in_the_default_set :: proc(t: ^testing.T) {
	found := false
	for spec in runtime_default_tools().specs {
		if spec.name != CODEMODE_TOOL_NAME {
			continue
		}
		found = true
		testing.expect(t, len(spec.description) > 0)
		testing.expect(t, strings.contains(spec.description, "Odin"))
		testing.expect(t, codemode_test_schema_requires_source(spec.parameters_json))
	}
	testing.expect(t, found, "the default tool set does not include codemode")
}

@(test)
test_codemode_runs_a_script_and_returns_its_output :: proc(t: ^testing.T) {
	outcome, work_dir := codemode_test_run(
		t,
		`
package main

import "core:fmt"

main :: proc() {
	fmt.println("codemode-hello")
}
`,
	)
	defer delete(work_dir)
	defer delete(outcome.output)

	testing.expect(t, outcome.ok)
	testing.expect(t, strings.contains(outcome.output, "codemode-hello"))
}

@(test)
test_codemode_gate_rejection_compiles_and_runs_nothing :: proc(t: ^testing.T) {
	// TEMP_DIR here is the test's own marker directory, not the work directory
	// the tool creates inside the system temporary directory.
	marker_dir, dir_err := os.make_directory_temp(TEMP_DIR, "oreo-marker-*", context.allocator)
	testing.expect_value(t, dir_err, os.Error(nil))
	defer {
		_ = os.remove_all(marker_dir)
		delete(marker_dir)
	}
	marker := fmt.aprintf("%s/ran.txt", marker_dir)
	defer delete(marker)

	// core:os is refused by the gate, but the import and the call are valid
	// Odin, so a run that skipped the gate would compile and write the marker.
	source := strings.concatenate(
		{
			`
package main

import "core:fmt"
import "core:os"

main :: proc() {
	if err := os.write_entire_file_from_string("`,
			marker,
			`", "ran"); err != nil {
		fmt.eprintln("the marker could not be written")
	}
	fmt.println("the gate let this run")
}
`,
		},
	)
	defer delete(source)

	outcome, work_dir := codemode_test_run(t, source)
	defer delete(work_dir)
	defer delete(outcome.output)

	testing.expect(t, !outcome.ok)
	// The gate's own reason, not a compiler message: it names the refused
	// import and says it is not allowed.
	testing.expect(t, strings.contains(outcome.output, "core:os"))
	testing.expect(t, strings.contains(outcome.output, "not allowed"))
	// The call failed before anything ran, so the marker was never written.
	testing.expect(t, !os.exists(marker))
}

@(test)
test_codemode_script_reaches_the_tool_api :: proc(t: ^testing.T) {
	// The script cannot print a constant and pass: execute goes out to the host
	// through oreo:script, and its answer is what comes back.
	outcome, work_dir := codemode_test_run(
		t,
		`
package main

import "core:fmt"
import "oreo:script"

main :: proc() {
	output, code, err := script.execute("printf codemode-execute")
	defer delete(output)
	defer script.error_destroy(&err)
	if err.message != "" {
		fmt.eprintln(err.message)
	}
	fmt.println(output)
	fmt.printfln("code=%d", code)
}
`,
	)
	defer delete(work_dir)
	defer delete(outcome.output)

	testing.expect(t, outcome.ok)
	testing.expect(t, strings.contains(outcome.output, "codemode-execute"))
	testing.expect(t, strings.contains(outcome.output, "code=0"))
}

@(test)
test_codemode_nonzero_exit_keeps_its_output :: proc(t: ^testing.T) {
	// No allowlisted package can choose an exit code, so the script dies by
	// indexing out of bounds after it prints.
	outcome, work_dir := codemode_test_run(
		t,
		`
package main

import "core:fmt"

main :: proc() {
	fmt.println("about to stop")
	values := []int{0}
	index := 1
	fmt.println(values[index])
}
`,
	)
	defer delete(work_dir)
	defer delete(outcome.output)

	testing.expect(t, !outcome.ok)
	// Both the output the script managed to write and the reason are reported.
	testing.expect(t, strings.contains(outcome.output, "about to stop"))
	testing.expect(t, strings.contains(outcome.output, "exited with code"))
}

@(test)
test_codemode_truncated_output_names_the_file_holding_it :: proc(t: ^testing.T) {
	// 20,000 bytes against the script runner's 10,000 byte cap.
	outcome, work_dir := codemode_test_run(
		t,
		`
package main

import "core:fmt"

main :: proc() {
	for _ in 0 ..< 2000 {
		fmt.print("aaaaaaaaaa\n")
	}
}
`,
	)
	defer delete(work_dir)
	defer delete(outcome.output)

	testing.expect(t, outcome.ok)
	testing.expect(t, strings.contains(outcome.output, "truncated"))

	// The complete text is the removed work directory's sibling, and the
	// outcome names it.
	kept := fmt.aprintf("%s-output.txt", work_dir, allocator = context.allocator)
	defer {
		_ = os.remove(kept)
		delete(kept)
	}
	testing.expect(t, os.exists(kept))
	testing.expect(t, strings.contains(outcome.output, kept))
	full, read_err := os.read_entire_file_from_path(kept, context.allocator)
	defer delete(full)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, len(full), 2000 * 11)
}

@(private)
codemode_test_lock: sync.Mutex

// codemode_test_work_dir is the directory the call in flight is using. The
// observer clones it, because codemode frees its own copy when the call ends.
@(private)
codemode_test_work_dir: string

// codemode_test_observe_work_dir records the work directory of the call in
// flight. It runs on the thread inside codemode_invoke, which holds
// codemode_test_lock.
@(private)
codemode_test_observe_work_dir :: proc(path: string) {
	codemode_test_work_dir = strings.clone(path, context.allocator)
}

// codemode_test_run invokes the tool with the raw script source, checks that
// the call removed its temporary work directory, and returns the outcome plus
// the path that directory had. The caller owns the returned path.
@(private)
codemode_test_run :: proc(t: ^testing.T, source: string) -> (Tool_Outcome, string) {
	sync.mutex_lock(&codemode_test_lock)
	defer sync.mutex_unlock(&codemode_test_lock)

	codemode_test_work_dir = ""
	codemode_work_dir_observer = codemode_test_observe_work_dir
	defer codemode_work_dir_observer = nil

	outcome := runtime_default_tools().invoke(CODEMODE_TOOL_NAME, source, context.allocator)

	testing.expectf(t, codemode_test_work_dir != "", "codemode created no work directory")
	testing.expectf(
		t,
		!os.exists(codemode_test_work_dir),
		"the temporary work directory %q survived the call",
		codemode_test_work_dir,
	)

	// The observer's copy is freed here, on the thread that made it.
	work_dir := strings.clone(codemode_test_work_dir, context.allocator)
	delete(codemode_test_work_dir, context.allocator)
	codemode_test_work_dir = ""
	return outcome, work_dir
}

// codemode_test_schema_requires_source reports whether the tool's parameters are
// a JSON object that declares source as a required property.
@(private)
codemode_test_schema_requires_source :: proc(parameters_json: string) -> bool {
	value, parse_err := json.parse_string(parameters_json, .JSON, false, context.allocator)
	if parse_err != .None {
		return false
	}
	defer json.destroy_value(value, context.allocator)

	schema, is_object := value.(json.Object)
	if !is_object {
		return false
	}
	properties, has_properties := schema["properties"].(json.Object)
	if !has_properties {
		return false
	}
	if _, has_source := properties["source"]; !has_source {
		return false
	}
	required, has_required := schema["required"].(json.Array)
	if !has_required {
		return false
	}
	for item in required {
		if text, is_string := item.(json.String); is_string && string(text) == "source" {
			return true
		}
	}
	return false
}
