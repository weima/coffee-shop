package oreo

// Oreo code mode, second slice: compile one gated script and run it as a
// short-lived process, under a wall-clock deadline and with bounded output.
// A host-side script server listens on a socket inside the work directory
// while the child runs, so the script can call back through oreo:script.
// See oreo/code-mode.md, "Process model" and "Containment and limits".
//
// DOCUMENTED LIMITATION - there is no memory ceiling here. code-mode.md records
// that macOS does not enforce RLIMIT_AS (measured: with `ulimit -v 200000` set,
// a process allocated 400 MB anyway). Imposing an address-space cap is therefore
// a separate, platform-dependent problem. The deadline and the output cap are
// what contain a script in this slice; do not read them as a memory limit.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

SCRIPT_RUN_DEFAULT_TIMEOUT_MS :: 60_000
SCRIPT_RUN_DEFAULT_MAX_OUTPUT :: 10_000
SCRIPT_RUN_OMISSION_FMT :: "\n... <omitted %d bytes> ...\n"

// The host socket lives inside the work directory, so removing the directory
// removes it and the script's socket path never outlives the run.
SCRIPT_RUN_SOCKET_NAME :: "script.sock"

// The server thread polls the listener on this interval, so it notices the run
// being over instead of waiting for the deadline. Small enough that stopping it
// after a fast script adds no noticeable latency.
@(private)
SCRIPT_RUN_SERVE_POLL_MS :: 5

// Everything the server thread needs. `stop` is written by the run thread and
// read by the server thread, so it is only touched through sync atomics.
@(private)
Script_Run_Serve_Job :: struct {
	server:     ^Script_Server,
	deadline:   time.Tick,
	timeout_ms: int,
	allocator:  runtime.Allocator,
	stop:       bool,
}

// How often the parent checks a running child against the deadline. Small enough
// that a kill lands near the deadline, large enough not to spin a core.
@(private)
SCRIPT_RUN_POLL_INTERVAL :: 2 * time.Millisecond

Script_Run_Config :: struct {
	source:             string,
	work_dir:           string,
	timeout_ms:         int,
	max_output_bytes:   int,
	extra_compile_args: []string,
}

Script_Run_Result :: struct {
	ok:               bool,
	reason:           string,
	output:           string,
	output_truncated: bool,
	full_output_path: string,
	exit_code:        int,
	timed_out:        bool,
	wall_ms:          i64,
}

// script_run gates, writes, compiles, and runs one script in config.work_dir.
// The caller owns every string in the result. A non-zero exit is a normal
// result: ok is false, exit_code is set, and the output is preserved.
script_run :: proc(config: Script_Run_Config, allocator := context.allocator) -> Script_Run_Result {
	result: Script_Run_Result

	// Gate first. A rejected script is written nowhere, compiled never, and run
	// never; that ordering is the point of the gate.
	gate_ok, gate_reason := script_gate(config.source, allocator)
	if !gate_ok {
		result.reason = gate_reason
		return result
	}
	delete(gate_reason, allocator)

	timeout_ms := config.timeout_ms > 0 ? config.timeout_ms : SCRIPT_RUN_DEFAULT_TIMEOUT_MS
	max_output := config.max_output_bytes > 0 ? config.max_output_bytes : SCRIPT_RUN_DEFAULT_MAX_OUTPUT
	timeout := time.Duration(timeout_ms) * time.Millisecond
	// Compile and run share this deadline.
	deadline := time.tick_now()

	script_path := fmt.aprintf("%s/script.odin", config.work_dir, allocator = allocator)
	defer delete(script_path, allocator)
	binary_path := fmt.aprintf("%s/script", config.work_dir, allocator = allocator)
	defer delete(binary_path, allocator)

	if write_err := os.write_entire_file_from_string(script_path, config.source); write_err != nil {
		result.reason = fmt.aprintf("could not write %s: %v", script_path, write_err, allocator = allocator)
		return result
	}

	out_arg := fmt.aprintf("-out:%s", binary_path, allocator = allocator)
	defer delete(out_arg, allocator)
	compile: [dynamic]string
	compile.allocator = allocator
	defer delete(compile)
	append(&compile, "odin", "build", script_path, "-file", out_arg, "-o:minimal")
	append(&compile, ..config.extra_compile_args)

	// nil env: the compiler inherits the parent's environment, PATH included.
	compile_output, compile_exit, compile_timed_out, compile_err := script_run_capture(
		compile[:],
		config.work_dir,
		deadline,
		timeout,
		nil,
		allocator,
	)
	defer delete(compile_output, allocator)
	if compile_err != "" {
		result.reason = strings.clone(compile_err, allocator)
		return result
	}
	if compile_timed_out {
		result.timed_out = true
		result.reason = strings.clone("compilation exceeded the deadline", allocator)
		return result
	}
	if compile_exit != 0 {
		result.reason = script_run_reason(
			compile_output,
			max_output,
			"the Odin compiler rejected the script",
			allocator,
		)
		return result
	}

	// The script can call back only if a socket is already listening, so the
	// server starts before the child. It goes inside work_dir, and
	// script_server_stop unlinks it on every exit path below.
	socket_path := fmt.aprintf("%s/%s", config.work_dir, SCRIPT_RUN_SOCKET_NAME, allocator = allocator)
	defer delete(socket_path, allocator)

	server, server_err := script_server_start(socket_path)
	if server_err.kind != .None {
		result.reason = strings.clone(server_err.message, allocator)
		host_error_destroy(&server_err)
		return result
	}
	// Registered before the thread's cleanup, so LIFO order joins the thread
	// before the socket file is removed.
	defer {
		stop_err := script_server_stop(&server)
		host_error_destroy(&stop_err)
	}

	// The child gets the parent's environment plus the socket path; without the
	// parent's environment it would lose PATH and find no tools at all.
	env: [dynamic]string
	env.allocator = allocator
	defer {
		for entry in env {
			delete(entry, allocator)
		}
		delete(env)
	}
	parent_env, parent_env_err := os.environ(allocator)
	if parent_env_err != nil {
		result.reason = strings.clone("could not read the parent environment", allocator)
		return result
	}
	// The slice memory only: its strings move into env and are freed there. A
	// parent value for the socket variable is dropped, so the appended one is
	// the only definition the child sees.
	defer delete(parent_env, allocator)
	for entry in parent_env {
		if strings.has_prefix(entry, SCRIPT_SERVER_ENV + "=") {
			delete(entry, allocator)
			continue
		}
		append(&env, entry)
	}
	append(&env, fmt.aprintf("%s=%s", SCRIPT_SERVER_ENV, socket_path, allocator = allocator))

	// Serving runs on its own thread so draining the child's output here cannot
	// deadlock with a script that is blocked waiting for a reply.
	job := Script_Run_Serve_Job {
		server     = &server,
		deadline   = deadline,
		timeout_ms = timeout_ms,
		allocator  = allocator,
	}
	worker := thread.create(script_run_serve_thread)
	if worker != nil {
		worker.data = rawptr(&job)
		thread.start(worker)
	}
	// Whatever ends the child, the thread is told to stop and is joined here,
	// before the server is stopped: no server thread outlives this call.
	defer {
		sync.atomic_store(&job.stop, true)
		if worker != nil {
			thread.destroy(worker)
		}
	}

	run_start := time.tick_now()
	run_output, exit_code, timed_out, run_err := script_run_capture(
		[]string{binary_path},
		config.work_dir,
		deadline,
		timeout,
		env[:],
		allocator,
	)
	defer delete(run_output, allocator)
	result.wall_ms = i64(time.tick_since(run_start)) / i64(time.Millisecond)
	result.exit_code = exit_code
	if run_err != "" {
		result.reason = strings.clone(run_err, allocator)
		return result
	}

	// Bound the output. Truncation writes the complete text to output.txt and
	// never splits a UTF-8 rune.
	bounded, truncated := script_run_bound_output(run_output, max_output, allocator)
	result.output = bounded
	result.output_truncated = truncated
	if truncated {
		output_path := fmt.aprintf("%s/output.txt", config.work_dir, allocator = allocator)
		if write_err := os.write_entire_file_from_string(output_path, run_output); write_err == nil {
			result.full_output_path = output_path
		} else {
			delete(output_path, allocator)
		}
	}

	result.timed_out = timed_out
	if timed_out {
		// The child was killed at the deadline; the output it managed to write
		// is preserved above.
		result.reason = fmt.aprintf("script exceeded the %d ms deadline", timeout_ms, allocator = allocator)
		return result
	}

	result.ok = exit_code == 0
	if !result.ok {
		result.reason = fmt.aprintf("script exited with code %d", exit_code, allocator = allocator)
	}
	return result
}

// script_run_serve_thread waits for one script connection and answers it,
// returning when the connection closes, the deadline passes, or the run ends.
// It cannot outlive the deadline: every wait is bounded by the remaining real
// time, and the listener is handed to script_server_serve_one only once poll
// says a connection is waiting, so a script that never connects is not waited
// on at all.
@(private)
script_run_serve_thread :: proc(worker: ^thread.Thread) {
	job := cast(^Script_Run_Serve_Job)worker.data
	context.allocator = job.allocator

	for {
		if sync.atomic_load(&job.stop) {
			return
		}
		remaining_ms := job.timeout_ms - int(time.tick_since(job.deadline) / time.Millisecond)
		if remaining_ms <= 0 {
			return
		}
		poll_fds: [1]posix.pollfd
		poll_fds[0] = {fd = job.server.fd, events = {.IN}}
		ready := posix.poll(&poll_fds[0], 1, c.int(min(remaining_ms, SCRIPT_RUN_SERVE_POLL_MS)))
		if ready <= 0 || .IN not_in poll_fds[0].revents {
			continue
		}
		// A connection is waiting. The protocol gives a script exactly one, so
		// answering it and returning is the whole job.
		serve_err: Host_Error
		_, serve_err = script_server_serve_one(job.server, remaining_ms)
		host_error_destroy(&serve_err)
		return
	}
}

// script_run_capture starts command with stdout and stderr on one pipe, so the
// two streams interleave in the order they were written, and returns the merged
// output. env is the child's whole environment; nil inherits the parent's. It
// returns as soon as the child exits or the shared deadline passes. On the
// deadline it SIGKILLs the child, reaps it, and reports timed_out. The caller
// owns output.
@(private)
script_run_capture :: proc(
	command: []string,
	work_dir: string,
	deadline: time.Tick,
	timeout: time.Duration,
	env: []string,
	allocator: runtime.Allocator,
) -> (output: string, exit_code: int, timed_out: bool, err: string) {
	read_end, write_end, pipe_err := os.pipe()
	if pipe_err != nil {
		return "", 0, false, "could not create an output pipe"
	}
	// One write end for both streams keeps their relative order in the pipe.
	process, start_err := os.process_start(os.Process_Desc{
		working_dir = work_dir,
		command     = command,
		env         = env,
		stdout      = write_end,
		stderr      = write_end,
	})
	_ = os.close(write_end)
	if start_err != nil {
		_ = os.close(read_end)
		return "", 0, false, fmt.aprintf("could not start %q", command[0], allocator = allocator)
	}

	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	buffer: [4096]u8
	state: os.Process_State

	for {
		for {
			has_data, has_err := os.pipe_has_data(read_end)
			if has_err != nil || !has_data {
				break
			}
			n, read_err := os.read(read_end, buffer[:])
			if n > 0 {
				strings.write_bytes(&builder, buffer[:n])
			}
			if read_err != nil {
				break
			}
			// A chatty child must not be able to outrun the deadline.
			if time.tick_since(deadline) >= timeout {
				timed_out = true
				break
			}
		}
		if timed_out {
			break
		}

		// A zero timeout polls the child without blocking.
		waited, _ := os.process_wait(process, 0)
		if waited.exited {
			state = waited
			break
		}
		if time.tick_since(deadline) >= timeout {
			timed_out = true
			break
		}
		time.sleep(SCRIPT_RUN_POLL_INTERVAL)
	}

	if timed_out {
		_ = os.process_kill(process)
		state, _ = os.process_wait(process)
	}

	// The child is gone, so all of its output is already in the pipe: drain it so
	// no captured line is lost to the deadline or to the exit.
	for {
		has_data, has_err := os.pipe_has_data(read_end)
		if has_err != nil || !has_data {
			break
		}
		n, read_err := os.read(read_end, buffer[:])
		if n > 0 {
			strings.write_bytes(&builder, buffer[:n])
		}
		if read_err != nil {
			break
		}
	}
	_ = os.close(read_end)

	return strings.to_string(builder), state.exit_code, timed_out, ""
}

// script_run_bound_output caps text at max_bytes, keeping the first and last
// halves around SCRIPT_RUN_OMISSION_FMT, which names the dropped byte count.
// Both cut points are moved to rune boundaries, so no UTF-8 rune is split. The
// caller owns the returned string.
@(private)
script_run_bound_output :: proc(text: string, max_bytes: int, allocator: runtime.Allocator) -> (bounded: string, truncated: bool) {
	if len(text) <= max_bytes {
		return strings.clone(text, allocator), false
	}
	half := max_bytes / 2
	head := half
	for head > 0 && script_run_is_continuation(text[head]) {
		head -= 1
	}
	tail_start := len(text) - (max_bytes - half)
	for tail_start < len(text) && script_run_is_continuation(text[tail_start]) {
		tail_start += 1
	}
	omitted := len(text) - head - (len(text) - tail_start)

	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, text[:head])
	fmt.sbprintf(&builder, SCRIPT_RUN_OMISSION_FMT, omitted)
	strings.write_string(&builder, text[tail_start:])
	return strings.to_string(builder), true
}

// A UTF-8 continuation byte is 10xxxxxx.
@(private)
script_run_is_continuation :: proc(b: byte) -> bool {
	return b & 0b1100_0000 == 0b1000_0000
}

// script_run_reason turns a bounded command output into a caller owned reason,
// falling back to a sentence when the command failed without saying anything.
@(private)
script_run_reason :: proc(output: string, max_output: int, fallback: string, allocator: runtime.Allocator) -> string {
	bounded, _ := script_run_bound_output(output, max_output, allocator)
	if strings.trim_space(bounded) == "" {
		delete(bounded, allocator)
		return strings.clone(fallback, allocator)
	}
	return bounded
}
