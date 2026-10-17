package main

import "core:os"
import "core:path/filepath"
import "core:prof/spall"
import "core:sync"
import "core:testing"

// The profiler is process-global and tests run in parallel, so they take turns.
@(private = "file")
spans_test_lock: sync.Mutex

@(private = "file")
spans_test_path :: proc(name: string) -> string {
	dir := os.get_env("TMPDIR", context.temp_allocator)
	path, _ := filepath.join({dir == "" ? "/tmp" : dir, name}, context.temp_allocator)
	_ = os.remove(path)
	return path
}

@(test)
test_spans_off_writes_nothing :: proc(t: ^testing.T) {
	sync.mutex_guard(&spans_test_lock)
	path := spans_test_path("cs-spans-off.spall")
	_ = os.unset_env(SPANS_ENV)
	testing.expect(t, !spans_init("x"))
	span_begin("a")
	span_end()
	testing.expect_value(t, spans_buffered(), 0)
	testing.expect(t, !os.exists(path))
	_ = os.set_env(SPANS_ENV, "")
	testing.expect(t, !spans_init())
	_ = os.unset_env(SPANS_ENV)
}

@(test)
test_spans_pair_writes_buffer_and_valid_header :: proc(t: ^testing.T) {
	sync.mutex_guard(&spans_test_lock)
	path := spans_test_path("cs-spans-on.spall")
	_ = os.set_env(SPANS_ENV, path)
	defer _ = os.unset_env(SPANS_ENV)
	defer _ = os.remove(path)
	testing.expect(t, spans_init())
	base := spans_buffered()
	span_begin("outer")
	span_begin("inner")
	span_end()
	span_end()
	testing.expect(t, spans_buffered() > base)
	spans_close()
	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, err == nil)
	testing.expect(t, len(data) > size_of(spall.Manual_Stream_Header))
	if len(data) >= size_of(spall.Manual_Stream_Header) {
		header := (^spall.Manual_Stream_Header)(raw_data(data))^
		testing.expect_value(t, header.magic, spall.MANUAL_MAGIC)
		testing.expect_value(t, header.version, 3)
	}
}

@(test)
test_spans_begin_without_end_writes_no_event :: proc(t: ^testing.T) {
	sync.mutex_guard(&spans_test_lock)
	path := spans_test_path("cs-spans-open.spall")
	testing.expect(t, spans_open(path))
	defer _ = os.remove(path)
	base := spans_buffered()
	span_begin("never-ends")
	span_begin("nested")
	span_end() // closes nested only; the outer span is still open
	testing.expect_value(t, spans_buffered(), base)
	spans_close()
}
