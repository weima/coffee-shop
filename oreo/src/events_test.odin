package oreo

// Tests for the event vocabulary. event_emit is the whole behavior: a nil
// callback is ignored and a non-nil one receives the event unchanged.

import "core:sync"
import "core:testing"

@(private)
Event_Test_Recorder :: struct {
	mutex: sync.Mutex,
	calls: int,
	event: Agent_Event,
}

@(private)
event_test_recorder: Event_Test_Recorder

@(private)
event_test_record :: proc(event: Agent_Event) {
	sync.mutex_lock(&event_test_recorder.mutex)
	defer sync.mutex_unlock(&event_test_recorder.mutex)
	event_test_recorder.calls += 1
	event_test_recorder.event = event
}

@(test)
test_event_emit_with_nil_callback_does_nothing :: proc(t: ^testing.T) {
	// A nil callback must be accepted and ignored without touching the event.
	event_emit(nil, Agent_Event{kind = .Needs_Input, session_id = "s", work_item_id = "w", message = "m"})
}

@(test)
test_event_emit_calls_non_nil_callback_once :: proc(t: ^testing.T) {
	sync.mutex_lock(&event_test_recorder.mutex)
	event_test_recorder.calls = 0
	event_test_recorder.event = {}
	sync.mutex_unlock(&event_test_recorder.mutex)

	want := Agent_Event{
		kind         = .Progress,
		session_id   = "session-1",
		work_item_id = "item-1",
		message      = "working",
	}
	event_emit(event_test_record, want)

	sync.mutex_lock(&event_test_recorder.mutex)
	calls := event_test_recorder.calls
	got := event_test_recorder.event
	sync.mutex_unlock(&event_test_recorder.mutex)

	testing.expect_value(t, calls, 1)
	testing.expect_value(t, got.kind, want.kind)
	testing.expect_value(t, got.session_id, want.session_id)
	testing.expect_value(t, got.work_item_id, want.work_item_id)
	testing.expect_value(t, got.message, want.message)
}
