package oreo

// The event vocabulary the worker pool reports through an optional callback:
// a work item that paused for external input, a worker that started an item,
// and an item that finished with a final result.

Agent_Event_Kind :: enum {
	Needs_Input,
	Progress,
	Final_Result,
}

// Agent_Event carries one event. The three strings are borrowed from the
// emitting call and are valid only for the duration of the Event_Fn call, so a
// handler that keeps them must copy them.
Agent_Event :: struct {
	kind:         Agent_Event_Kind,
	session_id:   string,
	work_item_id: string,
	message:      string,
}

Event_Fn :: #type proc(event: Agent_Event)

// event_emit delivers one event to a callback and does nothing when the
// callback is nil, so callers need no nil check of their own.
event_emit :: proc(events: Event_Fn, event: Agent_Event) {
	if events != nil {
		events(event)
	}
}
