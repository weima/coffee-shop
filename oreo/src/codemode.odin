package oreo

// Oreo code mode, third slice: the "codemode" tool. One model-chosen Odin
// script replaces several tool-call turns, and only the script's output enters
// the conversation, because the tool results it consumes never leave the
// script. See oreo/code-mode.md, "What code mode changes".
//
// The tool's whole argument is the script source - not JSON and not a markdown
// fence - so it never passes through runtime_invoke's JSON-object parse. Every
// script goes through script_gate before script_run writes, compiles, or runs
// anything, and each call gets a temporary work directory that is removed on
// every path.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

CODEMODE_TOOL_NAME :: "codemode"

// The temporary work directory's name pattern. Each call's directory is unique
// under this prefix in the temporary directory.
CODEMODE_WORK_DIR_PATTERN :: "oreo-codemode-*"

CODEMODE_TOOL_DESCRIPTION :: "Run one Odin script that makes several tool calls, or filters large output, in one turn, so only the script's result reaches you. The argument is the complete Odin source, raw: not JSON and not a markdown fence. The script language is Odin, not JavaScript. A script may import only core:fmt, core:strings, core:strconv, core:slice, core:sort, core:encoding/json, core:math, and oreo:script; core:os and every other import are refused before anything is compiled. It reaches the outside world through oreo:script: read(path, offset, limit) returns a numbered line window, write(path, content) writes a file, execute(command, working_directory) runs a command and returns its merged output with its exit code, and text(value) adds a value to this tool's output, which is what you see."

CODEMODE_TOOL_PARAMETERS_JSON :: `{"type":"object","properties":{"source":{"type":"string","description":"The complete Odin script source, raw and without a markdown fence."}},"required":["source"]}`

CODEMODE_TOOL_SPEC :: Tool_Spec{
	name            = CODEMODE_TOOL_NAME,
	description     = CODEMODE_TOOL_DESCRIPTION,
	parameters_json = CODEMODE_TOOL_PARAMETERS_JSON,
}

// codemode_work_dir_observer, when set, is handed the temporary work directory
// of the call in flight, just after it is created. The codemode tests set it to
// prove that the directory is removed on every path; production leaves it nil.
@(private)
codemode_work_dir_observer: proc(path: string)

// codemode_invoke runs one code-mode script. Its whole argument is the script
// source. A gate rejection is a failed outcome carrying the gate's reason, and
// nothing was written, compiled, or run.
codemode_invoke :: proc(name, arguments_json: string, allocator: runtime.Allocator) -> Tool_Outcome {
	source := strings.trim_space(arguments_json)
	if len(source) == 0 {
		return Tool_Outcome {
			ok     = false,
			output = fmt.aprintf("%s requires the Odin script source as its argument", name, allocator = allocator),
		}
	}

	work_dir, dir_err := os.make_directory_temp("", CODEMODE_WORK_DIR_PATTERN, allocator)
	if dir_err != nil {
		return Tool_Outcome {
			ok     = false,
			output = fmt.aprintf("%s could not create a temporary work directory: %v", name, dir_err, allocator = allocator),
		}
	}
	// One block, so the directory is removed while its path is still valid.
	defer {
		_ = os.remove_all(work_dir)
		delete(work_dir, allocator)
	}
	if codemode_work_dir_observer != nil {
		codemode_work_dir_observer(work_dir)
	}

	// A generated script that imports "oreo:script" needs the compiler to
	// resolve the collection this package was built with. #file names the
	// source tree, and the compiler runs with the work directory as its own, so
	// the collection path cannot be relative to it.
	collection := fmt.aprintf("-collection:oreo=%s", filepath.dir(#file), allocator = allocator)
	defer delete(collection, allocator)

	result := script_run(
		Script_Run_Config {
			source = source,
			work_dir = work_dir,
			extra_compile_args = []string{collection},
		},
		allocator,
	)
	defer codemode_result_destroy(&result, allocator)

	if !result.ok {
		// The reason carries the gate's rejection, the compiler's diagnostic, or
		// the exit code, and the run's output is preserved when it had any.
		if len(result.output) == 0 {
			return Tool_Outcome{ok = false, output = strings.clone(result.reason, allocator)}
		}
		return Tool_Outcome {
			ok     = false,
			output = fmt.aprintf("%s\n%s", result.output, result.reason, allocator = allocator),
		}
	}

	if result.output_truncated {
		// The complete text lives in the work directory, which is about to be
		// removed, so it is moved beside it and named in the outcome.
		kept := codemode_keep_full_output(work_dir, result.full_output_path, allocator)
		defer delete(kept, allocator)
		if kept == "" {
			return Tool_Outcome {
				ok     = true,
				output = fmt.aprintf("%s\n[output truncated; the complete text could not be kept]", result.output, allocator = allocator),
			}
		}
		return Tool_Outcome {
			ok     = true,
			output = fmt.aprintf("%s\n[output truncated; the complete text is in %s]", result.output, kept, allocator = allocator),
		}
	}

	return Tool_Outcome{ok = true, output = strings.clone(result.output, allocator)}
}

// runtime_invoke_with_codemode is the default tool set's invoke. codemode is
// dispatched before runtime_invoke's JSON-object parse, because its argument is
// the raw script source.
@(private)
runtime_invoke_with_codemode :: proc(name, arguments_json: string, allocator: runtime.Allocator) -> Tool_Outcome {
	if name == CODEMODE_TOOL_NAME {
		return codemode_invoke(name, arguments_json, allocator)
	}
	return runtime_invoke(name, arguments_json, allocator)
}

// codemode_keep_full_output moves a truncated run's complete output out of its
// work directory and returns the new path. The work directory's name is already
// unique, so this file's is too. The caller owns the returned path; "" means
// the text could not be kept.
@(private)
codemode_keep_full_output :: proc(work_dir, full_output_path: string, allocator: runtime.Allocator) -> string {
	if full_output_path == "" {
		return ""
	}
	kept := fmt.aprintf("%s-output.txt", work_dir, allocator = allocator)
	if os.rename(full_output_path, kept) != nil {
		delete(kept, allocator)
		return ""
	}
	return kept
}

@(private)
codemode_result_destroy :: proc(result: ^Script_Run_Result, allocator: runtime.Allocator) {
	delete(result.reason, allocator)
	delete(result.output, allocator)
	delete(result.full_output_path, allocator)
	result^ = Script_Run_Result{}
}
