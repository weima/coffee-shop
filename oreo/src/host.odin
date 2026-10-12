package oreo

// The assembled host: one process that serves the bridge protocol on its input
// and output streams, runs submitted work items through the real agent loop,
// and forwards every model turn to the pi extension as a `model_request`. See
// oreo/bridge.md, "Process model", "Wire protocol", and "The Odin
// counterpart".
//
// The host's single peer is the pi extension, which spawns this process and
// owns its pipes. Exactly one thread reads the input stream: host_loop. It
// routes each line by type, handing `model_response` and `model_error` to the
// work item waiting on that request id and every other line to the transport
// handler. Workers never read the input; provider_remote's read_line blocks on
// the slot the loop fills, so a worker can never starve the loop.
//
// One stream carries both protocols: client to host (`submit`, `resume`,
// `close_session`, `quit`), host to client (`ready`, `accepted`, `closed`,
// `stopped`, `event`, `error`), host to extension (`model_request`), and
// extension to host (`model_response`, `model_error`).

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import store "oreo:store"

// A submit names a session the host has not seen; the host owns the session
// store, so it opens that session on first use.
@(private)
HOST_SESSION_TITLE :: "oreo"

// The store the host owns. An explicit path wins; otherwise OREO_STORE, and
// otherwise the default under the user's home directory.
@(private)
HOST_STORE_ENV :: "OREO_STORE"
@(private)
HOST_HOME_ENV :: "HOME"
@(private)
HOST_TRACE_ENV :: "OREO_HOST_TRACE"
@(private)
HOST_STORE_DIRECTORY :: ".oreo"
@(private)
HOST_STORE_FILE :: "sessions.db"

// host_trace_path is where the bridge writes its trace when OREO_HOST_TRACE is
// set. A fixed path lets the log be tailed from outside the process; host_run
// truncates it so each run's log stands alone.
@(private)
HOST_TRACE_PATH :: "/tmp/oreo-deadlock.log"

// host_trace_enabled turns on the bridge's file trace. It is off unless
// OREO_HOST_TRACE is set, and it never touches the protocol stream.
@(private)
host_trace_enabled: bool

@(private)
host_trace_mutex: sync.Mutex

// host_trace appends one line per event: a millisecond timestamp, the thread,
// the request id when there is one, and the event. Opening in append mode on
// every line keeps the log coherent when several threads trace at once.
@(private)
host_trace :: proc(request_id, format: string, args: ..any) {
	if !host_trace_enabled {
		return
	}
	sync.mutex_lock(&host_trace_mutex)
	defer sync.mutex_unlock(&host_trace_mutex)
	file, open_err := os.open(HOST_TRACE_PATH, {.Append, .Create, .Write})
	if open_err != nil {
		return
	}
	defer os.close(file)

	event_buffer: [768]byte
	event := fmt.bprintf(event_buffer[:], format, ..args)
	line_buffer: [1024]byte
	timestamp := time.time_to_unix_nano(time.now()) / 1_000_000
	line := fmt.bprintf(
		line_buffer[:],
		"[%d] t=%d id=%s %s\n",
		timestamp,
		sync.current_thread_id(),
		request_id,
		event,
	)
	_, _ = os.write(file, transmute([]byte)line)
}

// host_model_timeout_ms bounds one wait for a model reply, so a dead extension
// fails the work item instead of hanging a worker. It is a variable so a test
// can shorten it.
@(private)
host_model_timeout_ms: int = 120_000

// host_bridge_active is the one bridge a running host serves. The provider
// callbacks carry no user data of their own, so the current bridge lives here,
// exactly as the pool keeps its Work_Fn state at package scope. host_run holds
// transport_serve_lock for its whole life, so only one bridge is current.
@(private)
host_bridge_active: ^Host_Bridge

// Host_Bridge is the shared state of one running host. Its mutex guards the
// waiting map and every slot in it; its condition is signalled when a reply is
// parked for a waiting worker.
@(private)
Host_Bridge :: struct {
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	waiting: map[string]^Host_Slot,
	host:    Host,
	// state is the transport state whose output and mutex every stdout line,
	// protocol reply or model request, is written through.
	state:   ^Transport_State,
}

// Host_Slot is one work item's half of the bridge: the request it is waiting on
// and the reply the serving loop parked for it. A slot lives on the worker's
// stack for the duration of one provider_remote_complete call.
@(private)
Host_Slot :: struct {
	bridge:     ^Host_Bridge,
	request_id: string,
	reply:      string,
	ready:      bool,
}

// Host_Bridge_Line is the minimum of every inbound line the host needs in order
// to route it. Fields that do not belong to a line stay empty.
@(private)
Host_Bridge_Line :: struct {
	message_type: string `json:"type"`,
	request_id:   string,
	session_id:   string,
}

// host_run serves the bridge on input and output and returns a process exit
// status: 0 after a clean stop, 1 when the host could not start or serve. An
// empty store_path resolves OREO_STORE, then $HOME/.oreo/sessions.db.
host_run :: proc(store_path: string, input: io.Reader, output: io.Writer) -> int {
	// One process serves one protocol stream; transport_serve takes the same
	// lock, so a second server cannot steal the relay.
	sync.mutex_lock(&transport_serve_lock)
	defer sync.mutex_unlock(&transport_serve_lock)

	path, owns_path, path_err := host_store_path(store_path)
	if path_err.kind != .None {
		defer host_error_destroy(&path_err)
		host_report(path_err.message)
		return 1
	}
	defer if owns_path {
		delete(path)
	}

	host, open_err := open_host(path)
	if open_err.kind != .None {
		defer host_error_destroy(&open_err)
		host_report(open_err.message)
		return 1
	}
	defer {
		close_err := close_host(&host)
		host_error_destroy(&close_err)
	}

	bridge, bridge_err := host_bridge_new(host, output)
	if bridge_err.kind != .None {
		defer host_error_destroy(&bridge_err)
		host_report(bridge_err.message)
		return 1
	}
	defer host_bridge_destroy(bridge)

	host_bridge_active = bridge
	transport_active = bridge.state
	defer {
		transport_active = nil
		host_bridge_active = nil
	}

	trace := os.get_env(HOST_TRACE_ENV, context.allocator)
	if len(trace) > 0 {
		host_trace_enabled = true
		// A fresh log per run, so a tail is only about this run.
		if file, create_err := os.create(HOST_TRACE_PATH); create_err == nil {
			os.close(file)
		}
	}
	delete(trace)

	// The ready line precedes the first read, so the extension can synchronize
	// on it before sending work.
	if ready_err := transport_write_message(bridge.state, Transport_Ready_Message{
		message_type = "ready",
		protocol     = TRANSPORT_PROTOCOL,
	}); ready_err.kind != .None {
		defer host_error_destroy(&ready_err)
		host_report(ready_err.message)
		return 1
	}

	pool, pool_err := pool_start(host, 1, host_work, transport_relay)
	if pool_err.kind != .None {
		defer host_error_destroy(&pool_err)
		host_report(pool_err.message)
		return 1
	}

	loop_err := host_loop(bridge, &pool, input)
	// The pool is joined before the stopped reply, so no worker can emit an
	// event after it, and before the retained outputs are released.
	stop_err := pool_stop(&pool, true)
	runtime_release()

	if loop_err.kind != .None {
		host_error_destroy(&stop_err)
		defer host_error_destroy(&loop_err)
		host_report(loop_err.message)
		return 1
	}
	if bridge.state.quit_requested {
		stopped_err := transport_write_message(bridge.state, Transport_Stopped_Message{message_type = "stopped"})
		if stop_err.kind != .None {
			host_error_destroy(&stopped_err)
			defer host_error_destroy(&stop_err)
			host_report(stop_err.message)
			return 1
		}
		if stopped_err.kind != .None {
			defer host_error_destroy(&stopped_err)
			host_report(stopped_err.message)
			return 1
		}
		return 0
	}
	if stop_err.kind != .None {
		defer host_error_destroy(&stop_err)
		host_report(stop_err.message)
		return 1
	}
	return 0
}

// host_loop reads every line and routes it. A model reply goes to the worker
// waiting on its request id; every other line goes to the transport handler.
@(private)
host_loop :: proc(bridge: ^Host_Bridge, pool: ^Pool, input: io.Reader) -> Host_Error {
	reader: bufio.Reader
	bufio.reader_init(&reader, input)
	defer bufio.reader_destroy(&reader)

	for {
		line, read_err := bufio.reader_read_string(&reader, '\n')
		if read_err != nil && read_err != .EOF {
			delete(line)
			return host_error(.Internal, "could not read the host input")
		}
		if len(line) == 0 && read_err == .EOF {
			return Host_Error{}
		}
		trimmed := strings.trim_right(line, "\r\n")
		action, handle_err := host_handle_line(bridge, pool, trimmed)
		delete(line)
		if handle_err.kind != .None {
			return handle_err
		}
		if action == .Quit || read_err == .EOF {
			return Host_Error{}
		}
	}
}

// host_handle_line routes one line: a model reply is parked for its worker,
// anything else is the transport's.
@(private)
host_handle_line :: proc(bridge: ^Host_Bridge, pool: ^Pool, line: string) -> (Transport_Action, Host_Error) {
	decoded: Host_Bridge_Line
	if json.unmarshal_string(line, &decoded, .JSON) != nil {
		// A malformed line is the transport's to report and skip.
		return transport_handle_line(bridge.state, pool, line)
	}
	defer {
		delete(decoded.message_type)
		delete(decoded.request_id)
		delete(decoded.session_id)
	}

	switch decoded.message_type {
	case "model_response", "model_error":
		host_deliver_reply(bridge, decoded.request_id, line)
		return .Continue, Host_Error{}
	case "submit":
		// The wire protocol has no session-creation message, so the host opens
		// the session a submit names before the transport accepts the work.
		host_ensure_session(bridge, decoded.session_id)
	}
	return transport_handle_line(bridge.state, pool, line)
}

// host_deliver_reply parks one line for the worker registered under request_id.
// A reply for an unknown or already-finished request is dropped.
@(private)
host_deliver_reply :: proc(bridge: ^Host_Bridge, request_id, line: string) {
	if len(request_id) == 0 {
		return
	}
	sync.mutex_lock(&bridge.mutex)
	defer sync.mutex_unlock(&bridge.mutex)
	slot, found := bridge.waiting[request_id]
	host_trace(request_id, "reply found=%v", found)
	if !found {
		return
	}
	delete(slot.reply)
	slot.reply, _ = strings.clone(line)
	slot.ready = true
	sync.cond_broadcast(&bridge.cond)
}

// host_ensure_session creates the session a submit names when it does not exist
// yet, so a fresh extension session can submit work without a create message.
@(private)
host_ensure_session :: proc(bridge: ^Host_Bridge, session_id: string) {
	if len(session_id) == 0 {
		return
	}
	existing, found, find_err := find_session(bridge.host, session_id)
	if find_err.kind != .None {
		host_error_destroy(&find_err)
		return
	}
	if found {
		session_destroy(&existing)
		return
	}
	store_handle, store_err := pool_store(bridge.host)
	if store_err.kind != .None {
		host_error_destroy(&store_err)
		return
	}
	create_err := store.create_session(store_handle, session_id, HOST_SESSION_TITLE, current_time_ms())
	store.store_error_destroy(&create_err)
}

@(private)
host_bridge_new :: proc(host: Host, output: io.Writer) -> (^Host_Bridge, Host_Error) {
	state, state_err := new(Transport_State)
	if state_err != nil {
		return nil, host_error(.Out_Of_Memory, "could not allocate the transport state")
	}
	state.output = output
	state.host = host

	bridge, bridge_err := new(Host_Bridge)
	if bridge_err != nil {
		free(state)
		return nil, host_error(.Out_Of_Memory, "could not allocate the host bridge")
	}
	bridge.host = host
	bridge.state = state
	bridge.waiting = make(map[string]^Host_Slot)
	return bridge, Host_Error{}
}

@(private)
host_bridge_destroy :: proc(bridge: ^Host_Bridge) {
	// Every slot belongs to a joined worker and has deregistered itself.
	delete(bridge.waiting)
	free(bridge.state)
	free(bridge)
}

// host_work is the pool's Work_Fn: one work item through the real agent loop
// with a remote provider. Each item gets its own provider state and bridge slot,
// so several workers never share a resolved profile.
@(private)
host_work :: proc(input: Work_Item_Input) -> Work_Item_Result {
	allocator := context.allocator
	bridge := host_bridge_active
	if bridge == nil {
		return Work_Item_Result{ok = false}
	}

	profile, profile_err := profile_resolve(input.provider, input.model, input.thinking, allocator)
	if profile_err.kind != .None {
		defer config_error_destroy(&profile_err, allocator)
		return runtime_failed(profile_err.message, allocator)
	}
	defer profile_resolved_destroy(&profile, allocator)

	prompt, prompt_ok := runtime_initial_prompt(input, allocator)
	if !prompt_ok {
		return runtime_failed("could not allocate the initial prompt", allocator)
	}
	defer delete(prompt, allocator)

	slot: Host_Slot
	slot.bridge = bridge
	state: Provider_Remote_State
	state.provider = profile.provider
	state.model = profile.model
	state.thinking = profile.thinking
	state.data = rawptr(&slot)
	provider := provider_remote(Remote_Transport{
		user       = rawptr(&state),
		write_line = host_write_line,
		read_line  = host_read_line,
	}, nil, host_model_timeout_ms)

	result, run_err := agent_run(provider, runtime_default_tools(), prompt, 0, allocator)
	if run_err.kind != .None {
		defer agent_error_destroy(&run_err, allocator)
		return runtime_failed_run(bridge.host, input, run_err.message, allocator)
	}
	text := result.text
	result.text = ""
	defer destroy_agent_messages(result.messages, allocator)
	return runtime_finish(bridge.host, input, text, allocator)
}

// host_write_line is provider_remote's write_line: it registers this item's
// slot under the request id it just wrote, then writes the line to stdout under
// the transport's output mutex. Ownership of request_id moves to the slot.
@(private)
host_write_line :: proc(user: rawptr, line: string) -> bool {
	// provider_remote hands back its own state, whose `data` is this item's slot.
	remote := cast(^Provider_Remote_State)user
	slot := cast(^Host_Slot)remote.data
	bridge := slot.bridge
	request_id, id_ok := host_request_id(line)
	if !id_ok || len(request_id) == 0 {
		delete(request_id)
		return false
	}
	host_trace(request_id, "handoff registering")

	sync.mutex_lock(&bridge.mutex)
	host_slot_unregister_locked(bridge, slot)
	slot.request_id = request_id
	bridge.waiting[request_id] = slot
	sync.mutex_unlock(&bridge.mutex)

	host_trace(request_id, "handoff registered")
	if host_write_output(bridge, line) {
		host_trace(request_id, "handoff wrote ok")
		return true
	}
	host_trace(request_id, "handoff write failed")
	// A request the extension never receives must not leave a stale slot.
	sync.mutex_lock(&bridge.mutex)
	host_slot_unregister_locked(bridge, slot)
	sync.mutex_unlock(&bridge.mutex)
	return false
}

// host_read_line is provider_remote's read_line: it blocks until the loop parks
// a reply for this item, bounded by timeout_ms. The caller owns the line.
@(private)
host_read_line :: proc(user: rawptr, timeout_ms: int) -> (string, bool) {
	remote := cast(^Provider_Remote_State)user
	slot := cast(^Host_Slot)remote.data
	bridge := slot.bridge
	timeout := time.Duration(max(timeout_ms, 0)) * time.Millisecond
	start := time.now()
	host_trace(slot.request_id, "wait enter timeout=%dms", timeout_ms)

	sync.mutex_lock(&bridge.mutex)
	for !slot.ready {
		remaining := timeout - time.since(start)
		if remaining <= 0 {
			break
		}
		if !sync.cond_wait_with_timeout(&bridge.cond, &bridge.mutex, remaining) {
			break
		}
	}
	if !slot.ready {
		host_trace(slot.request_id, "wait timeout")
		host_slot_unregister_locked(bridge, slot)
		sync.mutex_unlock(&bridge.mutex)
		return "", false
	}
	reply := slot.reply
	slot.reply = ""
	slot.ready = false
	host_trace(slot.request_id, "wait woke ready")
	host_slot_unregister_locked(bridge, slot)
	sync.mutex_unlock(&bridge.mutex)
	return reply, true
}

// host_slot_unregister_locked removes a slot from the waiting map and releases
// its request id. The bridge mutex must be held.
@(private)
host_slot_unregister_locked :: proc(bridge: ^Host_Bridge, slot: ^Host_Slot) {
	if len(slot.request_id) == 0 {
		return
	}
	if registered, found := bridge.waiting[slot.request_id]; found && registered == slot {
		delete_key(&bridge.waiting, slot.request_id)
	}
	delete(slot.request_id)
	slot.request_id = ""
}

// host_write_output writes one already-framed line under the transport's output
// mutex, the same mutex transport_write_message holds, so protocol replies and
// model requests never interleave inside a line.
@(private)
host_write_output :: proc(bridge: ^Host_Bridge, line: string) -> bool {
	host_trace("", "output lock acquire")
	sync.mutex_lock(&bridge.state.mutex)
	written := transport_write_all(bridge.state.output, transmute([]byte)line) == nil
	host_trace("", "output lock release")
	sync.mutex_unlock(&bridge.state.mutex)
	return written
}

@(private)
Host_Request_Id :: struct {
	request_id: string,
}

// host_request_id reads the request id out of a model request line. The caller
// owns the returned string.
@(private)
host_request_id :: proc(line: string) -> (string, bool) {
	parsed: Host_Request_Id
	if json.unmarshal_string(line, &parsed, .JSON) != nil {
		return "", false
	}
	return parsed.request_id, true
}

// host_store_path resolves the store path. An explicit path is borrowed;
// otherwise OREO_STORE, and otherwise $HOME/.oreo/sessions.db. The caller owns
// the path only when `owned` is true.
@(private)
host_store_path :: proc(store_path: string) -> (path: string, owned: bool, err: Host_Error) {
	if len(store_path) > 0 {
		return store_path, false, Host_Error{}
	}
	if env := os.get_env(HOST_STORE_ENV, context.allocator); len(env) > 0 {
		return env, true, Host_Error{}
	}
	home := os.get_env(HOST_HOME_ENV, context.allocator)
	defer delete(home)
	if len(home) == 0 {
		return "", false, host_error(.Invalid_Argument, "HOME is not set, so the Oreo store path is unknown")
	}
	joined, join_err := filepath.join({home, HOST_STORE_DIRECTORY, HOST_STORE_FILE})
	if join_err != nil {
		return "", false, host_error(.Out_Of_Memory, "could not allocate the Oreo store path")
	}
	// A fresh machine has no ~/.oreo yet.
	directory := filepath.dir(joined)
	if !os.exists(directory) {
		if directory_err := os.make_directory_all(directory); directory_err != nil {
			delete(joined)
			return "", false, host_error(.Internal, "could not create the Oreo store directory")
		}
	}
	return joined, true, Host_Error{}
}

// host_report writes a host diagnostic to stderr, which the extension forwards
// to pi's log. Stderr is never protocol.
@(private)
host_report :: proc(message: string) {
	fmt.eprintf("[oreo-host] %s\n", message)
}
