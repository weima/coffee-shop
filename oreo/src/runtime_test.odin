package oreo

// Tests for the runtime slice: the worker pool runs real work items through
// runtime_work, the default tools, and a scriptable in-file fake provider.
// Nothing here touches the network or a model.

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import store "oreo:store"

// The runtime tests share one package-level runtime handle, fake provider, and
// event log, so they run one at a time.
@(private)
runtime_test_lock: sync.Mutex

// Runtime_Test_Provider is this file's scriptable provider. It serves a deep
// clone of each scripted response, records a deep clone of every request, and
// can echo the last tool message as its answer so a test proves the tool output
// reached the provider.
@(private)
Runtime_Test_Provider :: struct {
	script:              []Provider_Response,
	index:               int,
	received:            [dynamic][]Agent_Message,
	error_kind:          Provider_Error_Kind,
	error_message:       string,
	reflect_tool_result: bool,
}

@(private)
runtime_test_provider :: proc(script: []Provider_Response) -> Runtime_Test_Provider {
	return Runtime_Test_Provider{script = script}
}

@(private)
runtime_test_provider_complete :: proc(
	user: rawptr,
	request: Provider_Request,
	allocator: runtime.Allocator,
) -> (Provider_Response, Provider_Error) {
	fake := cast(^Runtime_Test_Provider)user
	if fake.error_kind != .None {
		return {}, Provider_Error{
			kind = fake.error_kind,
			message = runtime_test_clone(fake.error_message, allocator),
		}
	}
	recorded := runtime_test_clone_messages(request.messages, allocator)
	if _, append_err := append(&fake.received, recorded); append_err != nil {
		runtime_test_destroy_messages(recorded, allocator)
		return {}, Provider_Error{
			kind = .Out_Of_Memory,
			message = runtime_test_clone("could not record the request", allocator),
		}
	}
	if fake.index < len(fake.script) {
		response := fake.script[fake.index]
		fake.index += 1
		return Provider_Response{
			text = runtime_test_clone(response.text, allocator),
			tool_calls = runtime_test_clone_calls(response.tool_calls, allocator),
		}, Provider_Error{}
	}
	if fake.reflect_tool_result {
		for index := len(request.messages) - 1; index >= 0; index -= 1 {
			if request.messages[index].role == .Tool {
				return Provider_Response{text = runtime_test_clone(request.messages[index].text, allocator)}, Provider_Error{}
			}
		}
	}
	return Provider_Response{text = runtime_test_clone("", allocator)}, Provider_Error{}
}

// runtime_test_provider_destroy releases the recorded requests and the script.
@(private)
runtime_test_provider_destroy :: proc(fake: ^Runtime_Test_Provider) {
	for recorded in fake.received {
		runtime_test_destroy_messages(recorded, context.allocator)
	}
	delete(fake.received)
	for response in fake.script {
		delete(response.text, context.allocator)
		runtime_test_destroy_calls(response.tool_calls, context.allocator)
	}
	fake^ = Runtime_Test_Provider{}
}

@(private)
Runtime_Test_Read_Arguments :: struct {
	path: string,
}

@(private)
Runtime_Test_Write_Arguments :: struct {
	path:    string,
	content: string,
}

@(private)
runtime_test_text :: proc(text: string) -> Provider_Response {
	return Provider_Response{text = runtime_test_clone(text, context.allocator)}
}

// runtime_test_call borrows its three strings; runtime_test_calls deep-copies
// the calls that a script actually owns.
@(private)
runtime_test_call :: proc(id, name, arguments_json: string) -> Agent_Tool_Call {
	return Agent_Tool_Call{id = id, name = name, arguments_json = arguments_json}
}

@(private)
runtime_test_calls :: proc(calls: []Agent_Tool_Call, allocator: runtime.Allocator) -> []Agent_Tool_Call {
	if len(calls) == 0 {
		return nil
	}
	copied := make([]Agent_Tool_Call, len(calls), allocator)
	for call, index in calls {
		copied[index] = Agent_Tool_Call{
			id = runtime_test_clone(call.id, allocator),
			name = runtime_test_clone(call.name, allocator),
			arguments_json = runtime_test_clone(call.arguments_json, allocator),
		}
	}
	return copied
}

@(private)
runtime_test_destroy_calls :: proc(calls: []Agent_Tool_Call, allocator: runtime.Allocator) {
	for index in 0 ..< len(calls) {
		call := &calls[index]
		delete(call.id, allocator)
		delete(call.name, allocator)
		delete(call.arguments_json, allocator)
	}
	delete(calls, allocator)
}

@(private)
runtime_test_clone_messages :: proc(messages: []Agent_Message, allocator: runtime.Allocator) -> []Agent_Message {
	if len(messages) == 0 {
		return nil
	}
	copied := make([]Agent_Message, len(messages), allocator)
	for message, index in messages {
		copied[index] = Agent_Message{
			role = message.role,
			text = runtime_test_clone(message.text, allocator),
			tool_calls = runtime_test_clone_calls(message.tool_calls, allocator),
			tool_call_id = runtime_test_clone(message.tool_call_id, allocator),
		}
	}
	return copied
}

@(private)
runtime_test_clone_calls :: proc(calls: []Agent_Tool_Call, allocator: runtime.Allocator) -> []Agent_Tool_Call {
	if len(calls) == 0 {
		return nil
	}
	copied := make([]Agent_Tool_Call, len(calls), allocator)
	for call, index in calls {
		copied[index] = Agent_Tool_Call{
			id = runtime_test_clone(call.id, allocator),
			name = runtime_test_clone(call.name, allocator),
			arguments_json = runtime_test_clone(call.arguments_json, allocator),
		}
	}
	return copied
}

@(private)
runtime_test_destroy_messages :: proc(messages: []Agent_Message, allocator: runtime.Allocator) {
	for index in 0 ..< len(messages) {
		message := &messages[index]
		delete(message.text, allocator)
		delete(message.tool_call_id, allocator)
		runtime_test_destroy_calls(message.tool_calls, allocator)
	}
	delete(messages, allocator)
}

@(private)
runtime_test_clone :: proc(value: string, allocator: runtime.Allocator) -> string {
	cloned, _ := strings.clone(value, allocator)
	return cloned
}

// The event log records copies: Agent_Event strings are borrowed by the pool.
@(private)
Runtime_Test_Event_Log :: struct {
	mutex:  sync.Mutex,
	events: [dynamic]Agent_Event,
}

@(private)
runtime_test_events: Runtime_Test_Event_Log

@(private)
runtime_test_record_event :: proc(event: Agent_Event) {
	sync.mutex_lock(&runtime_test_events.mutex)
	defer sync.mutex_unlock(&runtime_test_events.mutex)
	_, _ = append(&runtime_test_events.events, Agent_Event{
		kind         = event.kind,
		session_id   = runtime_test_clone(event.session_id, context.allocator),
		work_item_id = runtime_test_clone(event.work_item_id, context.allocator),
		message      = runtime_test_clone(event.message, context.allocator),
	})
}

@(private)
runtime_test_events_clear :: proc() {
	sync.mutex_lock(&runtime_test_events.mutex)
	defer sync.mutex_unlock(&runtime_test_events.mutex)
	for event in runtime_test_events.events {
		delete(event.session_id)
		delete(event.work_item_id)
		delete(event.message)
	}
	delete(runtime_test_events.events)
	runtime_test_events.events = nil
}

@(private)
runtime_test_event_count :: proc(kind: Agent_Event_Kind) -> int {
	sync.mutex_lock(&runtime_test_events.mutex)
	defer sync.mutex_unlock(&runtime_test_events.mutex)
	count := 0
	for event in runtime_test_events.events {
		if event.kind == kind {
			count += 1
		}
	}
	return count
}

@(private)
runtime_test_find_event :: proc(kind: Agent_Event_Kind) -> (Agent_Event, bool) {
	sync.mutex_lock(&runtime_test_events.mutex)
	defer sync.mutex_unlock(&runtime_test_events.mutex)
	for event in runtime_test_events.events {
		if event.kind == kind {
			return event, true
		}
	}
	return {}, false
}

@(private)
runtime_test_host :: proc(t: ^testing.T) -> (Host, string, string) {
	directory, directory_err := os.make_directory_temp(TEMP_DIR, "oreo-runtime-*", context.allocator)
	testing.expect_value(t, directory_err, os.Error(nil))
	path, path_err := filepath.join({directory, "sessions.db"}, context.allocator)
	testing.expect(t, path_err == nil)
	host, open_err := open_host(path)
	host_error_destroy(&open_err)
	testing.expect_value(t, open_err.kind, Host_Error_Kind.None)
	return host, directory, path
}

@(private)
runtime_test_cleanup :: proc(host: ^Host, directory, path: string) {
	close_err := close_host(host)
	host_error_destroy(&close_err)
	_ = os.remove_all(directory)
	delete(directory)
	delete(path)
}

@(private)
runtime_test_store :: proc(t: ^testing.T, host: Host) -> store.Store {
	store_handle, store_err := pool_store(host)
	defer host_error_destroy(&store_err)
	testing.expect_value(t, store_err.kind, Host_Error_Kind.None)
	return store_handle
}

// runtime_test_record_has_field checks one ordered record whose JSON payload has
// `key` set to `want`.
@(private)
runtime_test_record_has_field :: proc(records: [dynamic]store.Work_Item_Record, kind, key, want: string) -> bool {
	allocator := context.allocator
	for record in records {
		if record.kind != kind {
			continue
		}
		value, parse_err := json.parse_string(record.payload_json, .JSON, false, allocator)
		if parse_err != .None {
			json.destroy_value(value, allocator)
			continue
		}
		found := false
		if object, is_object := value.(json.Object); is_object {
			if text, is_string := object[key].(json.String); is_string {
				found = string(text) == want
			}
		}
		json.destroy_value(value, allocator)
		if found {
			return true
		}
	}
	return false
}

@(test)
test_runtime_completes_a_work_item :: proc(t: ^testing.T) {
	sync.mutex_lock(&runtime_test_lock)
	defer sync.mutex_unlock(&runtime_test_lock)
	host, directory, path := runtime_test_host(t)
	defer runtime_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "runtime completes")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	script := []Provider_Response{runtime_test_text("all done")}
	fake := runtime_test_provider(script)
	defer runtime_test_provider_destroy(&fake)
	runtime_test_events_clear()
	defer runtime_test_events_clear()

	pool, pool_err := runtime_start(host, Runtime{
		provider = Provider{user = rawptr(&fake), complete = runtime_test_provider_complete},
		tools    = runtime_default_tools(),
		events   = runtime_test_record_event,
		workers  = 1,
	})
	defer host_error_destroy(&pool_err)
	testing.expect_value(t, pool_err.kind, Host_Error_Kind.None)

	item_id, submit_err := pool_submit(pool, session.id, "fake-provider", "fake-model", "low", "do the work")
	defer delete(item_id)
	defer host_error_destroy(&submit_err)
	testing.expect_value(t, submit_err.kind, Host_Error_Kind.None)

	testing.expect(t, pool_wait_idle(pool, 30_000), "the pool did not become idle")
	stop_err := pool_stop(&pool, false)
	testing.expect_value(t, stop_err.kind, Host_Error_Kind.None)
	host_error_destroy(&stop_err)
	runtime_release()

	store_handle := runtime_test_store(t, host)
	item, found, item_err := store.get_work_item(store_handle, item_id)
	defer store.work_item_destroy(&item)
	defer store.store_error_destroy(&item_err)
	testing.expect(t, found)
	testing.expect_value(t, item_err.kind, store.Store_Error_Kind.None)
	testing.expect_value(t, item.status, store.WORK_ITEM_COMPLETED)

	records, records_err := store.list_work_item_records(store_handle, item_id)
	defer store.records_destroy(records)
	testing.expect_value(t, records_err.kind, store.Store_Error_Kind.None)
	testing.expect(
		t,
		runtime_test_record_has_field(records, RUNTIME_FINAL_RECORD_KIND, "text", "all done"),
		"the final text was not recorded",
	)

	event, event_found := runtime_test_find_event(.Final_Result)
	testing.expect(t, event_found)
	testing.expect_value(t, event.work_item_id, item_id)
	testing.expect_value(t, event.message, "all done")
}

@(test)
test_runtime_tool_round_trip_reads_a_file :: proc(t: ^testing.T) {
	sync.mutex_lock(&runtime_test_lock)
	defer sync.mutex_unlock(&runtime_test_lock)
	host, directory, path := runtime_test_host(t)
	defer runtime_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "runtime tools")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	file_path, join_err := filepath.join({directory, "note.txt"}, context.allocator)
	defer delete(file_path)
	testing.expect(t, join_err == nil)
	testing.expect(t, os.write_entire_file(file_path, "file line one\nfile line two\n") == nil)

	arguments, marshal_err := json.marshal(Runtime_Test_Read_Arguments{path = file_path}, allocator = context.allocator)
	defer delete(arguments)
	testing.expect(t, marshal_err == nil)
	script := []Provider_Response{
		Provider_Response{
			tool_calls = runtime_test_calls(
				[]Agent_Tool_Call{runtime_test_call("call-1", "read", string(arguments))},
				context.allocator,
			),
		},
	}
	fake := runtime_test_provider(script)
	fake.reflect_tool_result = true
	defer runtime_test_provider_destroy(&fake)
	runtime_test_events_clear()
	defer runtime_test_events_clear()

	pool, pool_err := runtime_start(host, Runtime{
		provider = Provider{user = rawptr(&fake), complete = runtime_test_provider_complete},
		tools    = runtime_default_tools(),
		events   = runtime_test_record_event,
		workers  = 1,
	})
	defer host_error_destroy(&pool_err)
	testing.expect_value(t, pool_err.kind, Host_Error_Kind.None)

	item_id, submit_err := pool_submit(pool, session.id, "fake-provider", "fake-model", "low", "read the note")
	defer delete(item_id)
	defer host_error_destroy(&submit_err)
	testing.expect_value(t, submit_err.kind, Host_Error_Kind.None)

	testing.expect(t, pool_wait_idle(pool, 30_000), "the pool did not become idle")
	stop_err := pool_stop(&pool, false)
	testing.expect_value(t, stop_err.kind, Host_Error_Kind.None)
	host_error_destroy(&stop_err)
	runtime_release()

	expected := "1\tfile line one\n2\tfile line two"
	event, event_found := runtime_test_find_event(.Final_Result)
	testing.expect(t, event_found)
	testing.expect_value(t, event.message, expected)

	// The provider's second turn saw the real read output as a tool message.
	testing.expect_value(t, len(fake.received), 2)
	second := fake.received[1]
	testing.expect_value(t, len(second), 3)
	testing.expect_value(t, second[1].role, Agent_Message_Role.Assistant)
	testing.expect_value(t, len(second[1].tool_calls), 1)
	testing.expect_value(t, second[1].tool_calls[0].name, "read")
	testing.expect_value(t, second[2].role, Agent_Message_Role.Tool)
	testing.expect_value(t, second[2].tool_call_id, "call-1")
	testing.expect_value(t, second[2].text, expected)
}

@(test)
test_runtime_provider_error_fails_the_item :: proc(t: ^testing.T) {
	sync.mutex_lock(&runtime_test_lock)
	defer sync.mutex_unlock(&runtime_test_lock)
	host, directory, path := runtime_test_host(t)
	defer runtime_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "runtime failure")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	fake := runtime_test_provider(nil)
	fake.error_kind = .Unavailable
	fake.error_message = "provider is offline"
	defer runtime_test_provider_destroy(&fake)
	runtime_test_events_clear()
	defer runtime_test_events_clear()

	pool, pool_err := runtime_start(host, Runtime{
		provider = Provider{user = rawptr(&fake), complete = runtime_test_provider_complete},
		tools    = runtime_default_tools(),
		events   = runtime_test_record_event,
		workers  = 1,
	})
	defer host_error_destroy(&pool_err)
	testing.expect_value(t, pool_err.kind, Host_Error_Kind.None)

	item_id, submit_err := pool_submit(pool, session.id, "fake-provider", "fake-model", "low", "anything")
	defer delete(item_id)
	defer host_error_destroy(&submit_err)
	testing.expect_value(t, submit_err.kind, Host_Error_Kind.None)

	testing.expect(t, pool_wait_idle(pool, 30_000), "the pool did not become idle")
	stop_err := pool_stop(&pool, false)
	testing.expect_value(t, stop_err.kind, Host_Error_Kind.None)
	host_error_destroy(&stop_err)
	runtime_release()

	store_handle := runtime_test_store(t, host)
	item, found, item_err := store.get_work_item(store_handle, item_id)
	defer store.work_item_destroy(&item)
	defer store.store_error_destroy(&item_err)
	testing.expect(t, found)
	testing.expect_value(t, item_err.kind, store.Store_Error_Kind.None)
	testing.expect_value(t, item.status, store.WORK_ITEM_FAILED)

	records, records_err := store.list_work_item_records(store_handle, item_id)
	defer store.records_destroy(records)
	testing.expect_value(t, records_err.kind, store.Store_Error_Kind.None)
	testing.expect(
		t,
		runtime_test_record_has_field(records, RUNTIME_FINAL_RECORD_KIND, "message", "provider is offline"),
		"the provider error was not recorded",
	)
	testing.expect_value(t, runtime_test_event_count(.Final_Result), 0)
}

@(test)
test_runtime_pauses_for_input_and_resumes :: proc(t: ^testing.T) {
	sync.mutex_lock(&runtime_test_lock)
	defer sync.mutex_unlock(&runtime_test_lock)
	host, directory, path := runtime_test_host(t)
	defer runtime_test_cleanup(&host, directory, path)
	session, session_err := create_session(host, "runtime pause")
	defer session_destroy(&session)
	defer host_error_destroy(&session_err)
	testing.expect_value(t, session_err.kind, Host_Error_Kind.None)

	script := []Provider_Response{
		runtime_test_text("NEEDS_INPUT: which branch?"),
		runtime_test_text("resumed and done"),
	}
	fake := runtime_test_provider(script)
	defer runtime_test_provider_destroy(&fake)
	runtime_test_events_clear()
	defer runtime_test_events_clear()

	pool, pool_err := runtime_start(host, Runtime{
		provider = Provider{user = rawptr(&fake), complete = runtime_test_provider_complete},
		tools    = runtime_default_tools(),
		events   = runtime_test_record_event,
		workers  = 1,
	})
	defer host_error_destroy(&pool_err)
	testing.expect_value(t, pool_err.kind, Host_Error_Kind.None)

	item_id, submit_err := pool_submit(pool, session.id, "fake-provider", "fake-model", "low", "start the work")
	defer delete(item_id)
	defer host_error_destroy(&submit_err)
	testing.expect_value(t, submit_err.kind, Host_Error_Kind.None)

	testing.expect(t, pool_wait_idle(pool, 30_000), "the pool did not become idle while paused")
	store_handle := runtime_test_store(t, host)
	item, found, item_err := store.get_work_item(store_handle, item_id)
	defer store.work_item_destroy(&item)
	defer store.store_error_destroy(&item_err)
	testing.expect(t, found)
	testing.expect_value(t, item_err.kind, store.Store_Error_Kind.None)
	testing.expect_value(t, item.status, store.WORK_ITEM_NEEDS_INPUT)

	pause_event, pause_found := runtime_test_find_event(.Needs_Input)
	testing.expect(t, pause_found)
	testing.expect_value(t, pause_event.work_item_id, item_id)
	testing.expect_value(t, pause_event.message, "which branch?")

	resume_err := pool_resume(pool, item_id, "the caller reply")
	defer host_error_destroy(&resume_err)
	testing.expect_value(t, resume_err.kind, Host_Error_Kind.None)

	testing.expect(t, pool_wait_idle(pool, 30_000), "the pool did not finish the resumed item")
	stop_err := pool_stop(&pool, false)
	testing.expect_value(t, stop_err.kind, Host_Error_Kind.None)
	host_error_destroy(&stop_err)
	runtime_release()

	finished, finished_found, finished_err := store.get_work_item(store_handle, item_id)
	defer store.work_item_destroy(&finished)
	defer store.store_error_destroy(&finished_err)
	testing.expect(t, finished_found)
	testing.expect_value(t, finished_err.kind, store.Store_Error_Kind.None)
	testing.expect_value(t, finished.status, store.WORK_ITEM_COMPLETED)

	// The second run saw the caller's reply in its prompt.
	testing.expect_value(t, len(fake.received), 2)
	testing.expect(t, len(fake.received[1]) >= 1)
	testing.expect(
		t,
		strings.contains(fake.received[1][0].text, "the caller reply"),
		"the resumed run did not see the caller reply",
	)
	final_event, final_found := runtime_test_find_event(.Final_Result)
	testing.expect(t, final_found)
	testing.expect_value(t, final_event.work_item_id, item_id)
	testing.expect_value(t, final_event.message, "resumed and done")
}

@(test)
test_runtime_tools_reject_bad_names_and_arguments :: proc(t: ^testing.T) {
	sync.mutex_lock(&runtime_test_lock)
	defer sync.mutex_unlock(&runtime_test_lock)
	directory, directory_err := os.make_directory_temp(TEMP_DIR, "oreo-runtime-tools-*", context.allocator)
	testing.expect_value(t, directory_err, os.Error(nil))
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}

	tools := runtime_default_tools()
	testing.expect_value(t, len(tools.specs), 4)
	testing.expect_value(t, tools.specs[0].name, "read")
	testing.expect_value(t, tools.specs[1].name, "write")
	testing.expect_value(t, tools.specs[2].name, "execute")
	testing.expect_value(t, tools.specs[3].name, CODEMODE_TOOL_NAME)

	bad_calls := []struct {
		name:      string,
		arguments: string,
	}{
		{"browse", `{"path":"x"}`}, // unknown tool name
		{"read", `{not json`}, // malformed JSON
		{"read", `["path"]`}, // not a JSON object
		{"read", `{"path":7}`}, // wrong field type
		{"read", `{}`}, // missing required field
		{"write", `{"path":"x"}`}, // missing required field
	}
	for call in bad_calls {
		outcome := tools.invoke(call.name, call.arguments, context.allocator)
		testing.expectf(t, !outcome.ok, "%s accepted %s", call.name, call.arguments)
		testing.expectf(t, len(outcome.output) > 0, "%s gave no explanation for %s", call.name, call.arguments)
		delete(outcome.output)
	}

	// A missing file is a failed outcome, not a crash.
	absent, absent_err := filepath.join({directory, "absent.txt"}, context.allocator)
	defer delete(absent)
	testing.expect(t, absent_err == nil)
	absent_arguments, absent_marshal_err := json.marshal(Runtime_Test_Read_Arguments{path = absent}, allocator = context.allocator)
	defer delete(absent_arguments)
	testing.expect(t, absent_marshal_err == nil)
	outcome := tools.invoke("read", string(absent_arguments), context.allocator)
	testing.expect(t, !outcome.ok)
	testing.expect(t, len(outcome.output) > 0)
	delete(outcome.output)

	// The write and read dispatches work end to end.
	written, written_err := filepath.join({directory, "made.txt"}, context.allocator)
	defer delete(written)
	testing.expect(t, written_err == nil)
	write_arguments, write_marshal_err := json.marshal(
		Runtime_Test_Write_Arguments{path = written, content = "hello\nworld\n"},
		allocator = context.allocator,
	)
	defer delete(write_arguments)
	testing.expect(t, write_marshal_err == nil)
	write_outcome := tools.invoke("write", string(write_arguments), context.allocator)
	testing.expect(t, write_outcome.ok)
	delete(write_outcome.output)

	read_arguments, read_marshal_err := json.marshal(Runtime_Test_Read_Arguments{path = written}, allocator = context.allocator)
	defer delete(read_arguments)
	testing.expect(t, read_marshal_err == nil)
	read_outcome := tools.invoke("read", string(read_arguments), context.allocator)
	testing.expect(t, read_outcome.ok)
	testing.expect_value(t, read_outcome.output, "1\thello\n2\tworld")
	delete(read_outcome.output)
}
