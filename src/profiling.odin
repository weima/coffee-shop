package main

import "base:runtime"
import "core:os"
import "core:prof/spall"
import "core:strings"
import "core:sync"

// Spall profiling, off unless CS_SPALL_FILE names a trace file.
//
// API: spans_init / spans_close, and span_begin / span_end around a named span.
// Span names must be static strings; they are held until the outermost span ends.
//
// A span is written only once its outermost span has ended, so a begin with no
// matching end writes no event and the trace never holds an unbalanced stack.
// When profiling is off, span_begin and span_end are one branch on spans_enabled.

SPANS_ENV :: "CS_SPALL_FILE"
SPANS_PENDING_MAX :: 128

Span_Mark :: struct {
	name:  string,
	ts:    u64,
	begin: bool,
}

Span_Pending :: struct {
	marks: [SPANS_PENDING_MAX]Span_Mark,
	count: int,
	depth: int,
	lost:  bool, // the log overflowed; drop this tree rather than write it unbalanced
}

spans_enabled: bool
spans_ctx: spall.Context
spans_buffer: spall.Buffer
spans_backing: []u8
spans_lock: sync.Mutex
@(thread_local) spans_pending: Span_Pending

// Starts profiling when CS_SPALL_FILE is set and non-empty. A non-empty suffix is
// appended to the file name ("<file>.<suffix>") so each process writes its own file.
// Call spans_close once on clean exit. Returns whether profiling is on.
spans_init :: proc(suffix := "") -> bool {
	path, found := os.lookup_env(SPANS_ENV, context.temp_allocator)
	if !found || path == "" {
		return false
	}
	if suffix != "" {
		path = strings.concatenate({path, ".", suffix}, context.temp_allocator)
	}
	return spans_open(path)
}

spans_open :: proc(path: string) -> bool {
	if spans_enabled {
		return true
	}
	// Scale 1 and no cycle counter: no startup calibration sleep.
	ctx, ok := spall.context_create_with_scale(path, false, 1)
	if !ok {
		return false
	}
	spans_pending = {} // drop any tree an earlier session left open on this thread
	spans_ctx = ctx
	spans_backing = make([]u8, spall.BUFFER_DEFAULT_SIZE)
	spans_buffer = spall.buffer_create(spans_backing, u32(sync.current_thread_id()))
	spans_enabled = true
	return true
}

// Flushes the buffer, closes the file, and turns profiling off.
spans_close :: proc() {
	if !spans_enabled {
		return
	}
	sync.mutex_lock(&spans_lock)
	defer sync.mutex_unlock(&spans_lock)
	spans_enabled = false
	spans_pending = {}
	spall.buffer_destroy(&spans_ctx, &spans_buffer)
	spall.context_destroy(&spans_ctx)
	delete(spans_backing)
	spans_backing = nil
}

// Bytes in the unflushed buffer, for tests; 0 when profiling is off.
spans_buffered :: proc() -> int {
	return spans_buffer.head if spans_enabled else 0
}

span_begin :: proc(name: string) {
	if !spans_enabled {
		return
	}
	span_mark(name, true)
}

span_end :: proc() {
	if !spans_enabled {
		return
	}
	pending := &spans_pending
	if pending.depth == 0 {
		return // an end with no begin
	}
	span_mark("", false)
	pending.depth -= 1
	if pending.depth == 0 {
		span_commit(pending)
	}
}

span_mark :: proc(name: string, begin: bool) {
	pending := &spans_pending
	if begin {
		pending.depth += 1
	}
	if pending.count >= SPANS_PENDING_MAX {
		pending.lost = true
		return
	}
	pending.marks[pending.count] = Span_Mark{name = name, ts = spall._trace_now(&spans_ctx), begin = begin}
	pending.count += 1
}

// Writes one finished span tree, in order, under the lock, as this thread's events.
span_commit :: proc(pending: ^Span_Pending) {
	defer pending^ = Span_Pending{}
	if pending.lost {
		return
	}
	sync.mutex_lock(&spans_lock)
	defer sync.mutex_unlock(&spans_lock)
	if !spans_enabled {
		return
	}
	tid := u32(sync.current_thread_id())
	if spans_buffer.tid != tid {
		spall.buffer_flush(&spans_ctx, &spans_buffer)
		spans_buffer.tid = tid
	}
	for mark in pending.marks[:pending.count] {
		span_write(mark)
	}
}

span_write :: proc(mark: Span_Mark) {
	if spans_buffer.head + spall.BEGIN_EVENT_MAX > len(spans_buffer.data) {
		spall.buffer_flush(&spans_ctx, &spans_buffer)
	}
	data := spans_buffer.data[spans_buffer.head:]
	if mark.begin {
		spans_buffer.head += spall._build_begin(data, mark.name, "", mark.ts)
	} else {
		spans_buffer.head += spall._build_end(data, mark.ts)
	}
}
