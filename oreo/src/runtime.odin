package oreo

// This slice wires the agent loop and the default tools into the worker pool.
// A caller submits a work item to the pool; a pool worker runs runtime_work,
// which resolves the profile, builds the prompt, runs the loop against the
// runtime's provider and tools, records the outcome in the store, and reports
// the result back to the pool.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import store "oreo:store"

// Runtime is one host's agent runtime: the model provider, the tools offered to
// the provider, the optional event callback, and the worker count pool_start
// runs with.
Runtime :: struct {
	provider: Provider,
	tools:    Tool_Set,
	events:   Event_Fn,
	workers:  int,
}

// NEEDS_INPUT starts the final agent text when the agent needs a human answer.
// runtime_work strips the marker, reports the rest as the question, and pauses
// the work item until a caller replies through pool_resume.
RUNTIME_NEEDS_INPUT_MARKER :: "NEEDS_INPUT:"

// The store's record kinds for one finished run. The kind names the lifecycle
// event; the payload says whether the run produced text, a question, or a
// provider error.
RUNTIME_FINAL_RECORD_KIND :: "final_result"
RUNTIME_NEEDS_INPUT_RECORD_KIND :: "needs_input"

@(private)
Runtime_Text_Payload :: struct {
	text: string,
}

@(private)
Runtime_Question_Payload :: struct {
	question: string,
}

@(private)
Runtime_Error_Payload :: struct {
	message: string,
}

// Runtime_Handle is what the pool's Work_Fn can reach: the runtime the caller
// started and the host that owns the store it records into.
@(private)
Runtime_Handle :: struct {
	runtime: Runtime,
	host:    Host,
}

// Work_Fn carries no user data, so the current runtime lives in a package-level
// handle, exactly as the pool tests keep their fake state.
@(private)
runtime_current: Runtime_Handle

// runtime_retained holds every output string the runtime returned to the pool.
// The pool borrows Work_Item_Result.output for its event and never releases it,
// so the runtime keeps ownership and frees the strings in runtime_release once
// the pool has stopped.
@(private)
runtime_retained: [dynamic]string

@(private)
runtime_mutex: sync.Mutex

// runtime_start stores `runtime` for the pool's Work_Fn and starts a pool of at
// most five workers. Only one runtime is current at a time; stop its pool (and
// call runtime_release) before starting another.
runtime_start :: proc(host: Host, runtime: Runtime) -> (Pool, Host_Error) {
	sync.mutex_lock(&runtime_mutex)
	delete(runtime_retained)
	runtime_retained = make([dynamic]string, 0, 8, context.allocator)
	runtime_current = Runtime_Handle{runtime = runtime, host = host}
	sync.mutex_unlock(&runtime_mutex)
	return pool_start(host, clamp(runtime.workers, 1, 5), runtime_work, runtime.events)
}

// runtime_release frees the outputs the pool borrowed. Call it after pool_stop,
// when no worker can still be running its event callback.
@(private)
runtime_release :: proc() {
	sync.mutex_lock(&runtime_mutex)
	defer sync.mutex_unlock(&runtime_mutex)
	for output in runtime_retained {
		delete(output, context.allocator)
	}
	delete(runtime_retained)
	runtime_retained = nil
}

// runtime_work is the Work_Fn the pool runs.
runtime_work :: proc(input: Work_Item_Input) -> Work_Item_Result {
	allocator := context.allocator
	handle := runtime_handle()

	// Step 1: the explicit settings win; empty ones come from the config. The
	// resolved profile is the validated effective provider, model, and thinking
	// level for this run.
	profile, profile_err := profile_resolve(input.provider, input.model, input.thinking, allocator)
	if profile_err.kind != .None {
		defer config_error_destroy(&profile_err, allocator)
		return runtime_failed(profile_err.message, allocator)
	}
	defer profile_resolved_destroy(&profile, allocator)

	// Step 2: a resumed item appends the caller's reply to the same request.
	prompt, prompt_ok := runtime_initial_prompt(input, allocator)
	if !prompt_ok {
		return runtime_failed("could not allocate the initial prompt", allocator)
	}
	defer delete(prompt, allocator)

	// Step 3: the current runtime's provider and tools.
	result, run_err := agent_run(handle.runtime.provider, handle.runtime.tools, prompt, 0, allocator)
	if run_err.kind != .None {
		defer agent_error_destroy(&run_err, allocator)
		return runtime_failed_run(handle.host, input, run_err.message, allocator)
	}
	// The loop owns the conversation; this proc owns the final text.
	text := result.text
	result.text = ""
	defer destroy_agent_messages(result.messages, allocator)

	// Steps 4 to 6: record the outcome and report it to the pool.
	return runtime_finish(handle.host, input, text, allocator)
}

// runtime_finish records one completed run and decides whether the item
// finished or paused. Ownership of `text` moves to the runtime handle.
@(private)
runtime_finish :: proc(host: Host, input: Work_Item_Input, text: string, allocator: runtime.Allocator) -> Work_Item_Result {
	if strings.has_prefix(text, RUNTIME_NEEDS_INPUT_MARKER) {
		question, _ := strings.clone(strings.trim_space(text[len(RUNTIME_NEEDS_INPUT_MARKER):]), allocator)
		runtime_retain(text)
		runtime_retain(question)
		if record_err := runtime_record(host, input.work_item_id, RUNTIME_NEEDS_INPUT_RECORD_KIND, Runtime_Question_Payload{question = question}, allocator); record_err.kind != .None {
			return runtime_adopted(record_err.message)
		}
		return Work_Item_Result{ok = true, needs_input = true, output = question}
	}
	runtime_retain(text)
	if record_err := runtime_record(host, input.work_item_id, RUNTIME_FINAL_RECORD_KIND, Runtime_Text_Payload{text = text}, allocator); record_err.kind != .None {
		return runtime_adopted(record_err.message)
	}
	return Work_Item_Result{ok = true, output = text}
}

// runtime_failed_run records a provider failure and returns it.
@(private)
runtime_failed_run :: proc(host: Host, input: Work_Item_Input, message: string, allocator: runtime.Allocator) -> Work_Item_Result {
	if record_err := runtime_record(host, input.work_item_id, RUNTIME_FINAL_RECORD_KIND, Runtime_Error_Payload{message = message}, allocator); record_err.kind != .None {
		return runtime_adopted(record_err.message)
	}
	return runtime_failed(message, allocator)
}

// runtime_record appends one outcome as an ordered work-item record. The
// payload struct becomes the JSON object the store requires.
@(private)
runtime_record :: proc(host: Host, work_item_id, kind: string, payload: any, allocator: runtime.Allocator) -> Host_Error {
	store_handle, store_err := pool_store(host)
	if store_err.kind != .None {
		return store_err
	}
	encoded, marshal_err := json.marshal(payload, allocator = allocator)
	if marshal_err != nil {
		return host_error(.Internal, "could not encode the work item outcome")
	}
	defer delete(encoded, allocator)
	if _, record_err := store.append_record(store_handle, work_item_id, kind, string(encoded), current_time_ms(), allocator); record_err.kind != .None {
		return host_store_error(record_err)
	}
	return Host_Error{}
}

// runtime_failed returns a failed result with an owned copy of `message`.
@(private)
runtime_failed :: proc(message: string, allocator: runtime.Allocator) -> Work_Item_Result {
	output, _ := strings.clone(message, allocator)
	runtime_retain(output)
	return Work_Item_Result{ok = false, output = output}
}

// runtime_adopted retains an owned failure message and reports it.
@(private)
runtime_adopted :: proc(message: string) -> Work_Item_Result {
	runtime_retain(message)
	return Work_Item_Result{ok = false, output = message}
}

// runtime_initial_prompt owns the returned string.
@(private)
runtime_initial_prompt :: proc(input: Work_Item_Input, allocator: runtime.Allocator) -> (prompt: string, ok: bool) {
	if len(input.resumed_input) == 0 {
		cloned, clone_err := strings.clone(input.request, allocator)
		if clone_err != nil {
			return "", false
		}
		return cloned, true
	}
	joined, join_err := strings.concatenate({input.request, "\n", input.resumed_input}, allocator)
	if join_err != nil {
		return "", false
	}
	return joined, true
}

@(private)
runtime_handle :: proc() -> Runtime_Handle {
	sync.mutex_lock(&runtime_mutex)
	defer sync.mutex_unlock(&runtime_mutex)
	return runtime_current
}

@(private)
runtime_retain :: proc(output: string) {
	if len(output) == 0 {
		return
	}
	sync.mutex_lock(&runtime_mutex)
	defer sync.mutex_unlock(&runtime_mutex)
	_, _ = append(&runtime_retained, output)
}

// The default tool set: the read, write, execute, and codemode specs plus one
// invoke that dispatches on the tool name. A bad name or bad arguments become a
// failed outcome with an explanation; they never crash the harness.
@(private)
RUNTIME_TOOL_SPECS := [4]Tool_Spec{
	{
		name = "read",
		description = "Read a text file, optionally limited to a window of lines.",
		parameters_json = `{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"]}`,
	},
	{
		name = "write",
		description = "Write a text file, creating parent directories as needed.",
		parameters_json = `{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}`,
	},
	{
		name = "execute",
		description = "Run a shell command and return its merged standard output and error.",
		parameters_json = `{"type":"object","properties":{"command":{"type":"string"},"working_directory":{"type":"string"}},"required":["command"]}`,
	},
	CODEMODE_TOOL_SPEC,
}

runtime_default_tools :: proc() -> Tool_Set {
	return Tool_Set{specs = RUNTIME_TOOL_SPECS[:], invoke = runtime_invoke_with_codemode}
}

@(private)
runtime_invoke :: proc(name, arguments_json: string, allocator: runtime.Allocator) -> Tool_Outcome {
	value, parse_err := json.parse_string(arguments_json, .JSON, false, allocator)
	if parse_err != .None {
		json.destroy_value(value, allocator)
		return runtime_tool_failuref(allocator, "arguments for %s are not valid JSON", name)
	}
	defer json.destroy_value(value, allocator)
	arguments, is_object := value.(json.Object)
	if !is_object {
		return runtime_tool_failuref(allocator, "arguments for %s must be a JSON object", name)
	}
	switch name {
	case "read":
		return runtime_invoke_read(arguments, allocator)
	case "write":
		return runtime_invoke_write(arguments, allocator)
	case "execute":
		return runtime_invoke_execute(arguments, allocator)
	}
	return runtime_tool_failuref(allocator, "unknown tool %q", name)
}

@(private)
runtime_invoke_read :: proc(arguments: json.Object, allocator: runtime.Allocator) -> Tool_Outcome {
	path, path_ok := runtime_string_argument(arguments, "path")
	if !path_ok {
		return runtime_tool_failuref(allocator, "read requires a string path")
	}
	offset, offset_ok := runtime_int_argument(arguments, "offset")
	if !offset_ok {
		return runtime_tool_failuref(allocator, "read offset must be an integer")
	}
	limit, limit_ok := runtime_int_argument(arguments, "limit")
	if !limit_ok {
		return runtime_tool_failuref(allocator, "read limit must be an integer")
	}
	content, tool_err := tool_read(path, offset, limit, allocator)
	if tool_err.kind != .None {
		return runtime_tool_error_outcome(&tool_err, allocator)
	}
	return Tool_Outcome{ok = true, output = content}
}

@(private)
runtime_invoke_write :: proc(arguments: json.Object, allocator: runtime.Allocator) -> Tool_Outcome {
	path, path_ok := runtime_string_argument(arguments, "path")
	if !path_ok {
		return runtime_tool_failuref(allocator, "write requires a string path")
	}
	content, content_ok := runtime_string_argument(arguments, "content")
	if !content_ok {
		return runtime_tool_failuref(allocator, "write requires string content")
	}
	if tool_err := tool_write(path, content); tool_err.kind != .None {
		return runtime_tool_error_outcome(&tool_err, allocator)
	}
	summary := fmt.aprintf("wrote %d bytes to %s", len(content), path, allocator = allocator)
	return Tool_Outcome{ok = true, output = summary}
}

@(private)
runtime_invoke_execute :: proc(arguments: json.Object, allocator: runtime.Allocator) -> Tool_Outcome {
	command, command_ok := runtime_string_argument(arguments, "command")
	if !command_ok {
		return runtime_tool_failuref(allocator, "execute requires a string command")
	}
	working_directory, directory_ok := runtime_string_argument(arguments, "working_directory")
	if !directory_ok && runtime_argument_present(arguments, "working_directory") {
		return runtime_tool_failuref(allocator, "execute working_directory must be a string")
	}
	output, exit_code, tool_err := tool_execute(command, working_directory, allocator)
	if tool_err.kind != .None {
		return runtime_tool_error_outcome(&tool_err, allocator)
	}
	if exit_code == 0 {
		return Tool_Outcome{ok = true, output = output}
	}
	// A non-zero exit code is a normal result; report it with the output.
	reported := fmt.aprintf("%s\n(exit code %d)", output, exit_code, allocator = allocator)
	delete(output, allocator)
	return Tool_Outcome{ok = true, output = reported}
}

// runtime_tool_error_outcome copies the tool's message, so the outcome stays
// valid after the tool error is released.
@(private)
runtime_tool_error_outcome :: proc(tool_err: ^Tool_Error, allocator: runtime.Allocator) -> Tool_Outcome {
	output, _ := strings.clone(tool_err.message, allocator)
	tool_error_destroy(tool_err)
	return Tool_Outcome{ok = false, output = output}
}

@(private)
runtime_tool_failuref :: proc(allocator: runtime.Allocator, format: string, args: ..any) -> Tool_Outcome {
	return Tool_Outcome{ok = false, output = fmt.aprintf(format, ..args, allocator = allocator)}
}

// runtime_string_argument returns a string field. `ok` is false when the field
// is absent or is not a string.
@(private)
runtime_string_argument :: proc(arguments: json.Object, key: string) -> (value: string, ok: bool) {
	raw, present := arguments[key]
	if !present {
		return "", false
	}
	text, is_string := raw.(json.String)
	if !is_string {
		return "", false
	}
	return string(text), true
}

// runtime_int_argument returns an integer field. `ok` is true when the field is
// absent or is a number.
@(private)
runtime_int_argument :: proc(arguments: json.Object, key: string) -> (value: int, ok: bool) {
	raw, present := arguments[key]
	if !present {
		return 0, true
	}
	#partial switch number in raw {
	case json.Integer:
		return int(number), true
	case json.Float:
		return int(number), true
	}
	return 0, false
}

@(private)
runtime_argument_present :: proc(arguments: json.Object, key: string) -> bool {
	_, present := arguments[key]
	return present
}
