package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

headless_test_root :: proc() -> string {
	root, err := os.make_directory_temp(HOST_TEST_TEMP_DIR, "coffee-shop-headless-*", context.allocator)
	assert(err == nil, "cannot create the test state root")
	return root
}

// Polls the file until it contains want or five seconds pass.
headless_wait_for :: proc(path, want: string) -> bool {
	for _ in 0 ..< 500 {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err == nil && strings.contains(string(data), want) {
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

@(test)
test_headless_start_output_input_close :: proc(t: ^testing.T) {
	root := headless_test_root()
	defer delete(root)
	defer os.remove_all(root)
	s := headless_session_surface(root)
	opened, open_err := s.ops.tab_create(s, "req-a", "shot-a", root, context.temp_allocator)
	testing.expect_value(t, open_err, "")
	log_path := fmt.tprintf("%s/host/req-a/logs/shot-a.log", root)
	// `status --stations` and `log` must name the file the Station actually writes.
	testing.expect_value(t, station_log_path(root, "req-a", "shot-a"), log_path)

	// exec leaves no grandchild holding the output pipe, so close can finish the log.
	run_err := s.ops.pane_run(s, opened.pane_id, "echo started; echo oops 1>&2; read line; echo got:$line; exec sleep 30")
	testing.expect_value(t, run_err, "")
	testing.expect(t, headless_wait_for(log_path, "started"), "stdout lands in the named log")
	testing.expect(t, headless_wait_for(log_path, "oops"), "stderr lands in the same log")

	info := s.ops.pane_process_info(s, opened.pane_id)
	testing.expect(t, info.pid > 0, "the child's pid is reported")

	testing.expect_value(t, s.ops.pane_run(s, opened.pane_id, "ping"), "")
	testing.expect(t, headless_wait_for(log_path, "got:ping"), "input reaches the child's stdin")

	testing.expect(t, s.ops.tab_close(s, opened.tab_id), "close succeeds")
	testing.expect(t, posix.kill(posix.pid_t(info.pid), posix.Signal(0)) != .OK, "close terminates the child")
	testing.expect(t, !s.ops.tab_close(s, opened.tab_id), "a second close reports nothing closed")
	_, _, found := s.ops.pane_get(s, opened.pane_id)
	testing.expect(t, !found, "a closed session is gone")
}

@(test)
test_headless_log_is_bounded :: proc(t: ^testing.T) {
	root := headless_test_root()
	defer delete(root)
	defer os.remove_all(root)
	key, err := headless_session_open(root, "req-b", "shot-b", root, 1024)
	testing.expect_value(t, err, "")
	s := headless_session_surface(root)
	command := "i=0; while [ $i -lt 3000 ]; do echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; i=$((i+1)); done; echo FINISHED"
	testing.expect_value(t, s.ops.pane_run(s, key, command), "")
	log_path := fmt.tprintf("%s/host/req-b/logs/shot-b.log", root)
	testing.expect(t, headless_wait_for(log_path, "FINISHED"), "the run completes and the newest output is kept")
	testing.expect(t, s.ops.tab_close(s, key), "close")
	current, _ := os.stat(log_path, context.temp_allocator)
	previous, prev_err := os.stat(fmt.tprintf("%s.1", log_path), context.temp_allocator)
	testing.expect(t, prev_err == nil, "an older generation was rotated out")
	testing.expect(t, current.size <= 1024 && previous.size <= 1024, "each generation stays within the bound")
}

@(test)
test_headless_slots_limit :: proc(t: ^testing.T) {
	root := headless_test_root()
	defer delete(root)
	defer os.remove_all(root)
	headless_slots_init(root, 2)
	defer headless_slots_destroy()
	a, a_ok := headless_slot_acquire("r", "a")
	b, b_ok := headless_slot_acquire("r", "b")
	_, c_ok := headless_slot_acquire("r", "c")
	testing.expect(t, a_ok && b_ok, "slots up to the limit are granted")
	testing.expect(t, !c_ok, "the limit still applies with no pool")
	testing.expect(t, headless_slot_release(a), "release frees the slot")
	testing.expect(t, !headless_slot_release(a), "release is idempotent")
	c, c_ok2 := headless_slot_acquire("r", "c")
	testing.expect(t, c_ok2, "a freed slot can be taken")
	delete(a)
	delete(b)
	delete(c)
}

// The load-dependent half of the test above, made deterministic: one write larger
// than the whole bound must keep its newest bytes, not its first. A full pipe under
// load hands the pump exactly such a chunk at the end of a run, so losing the tail
// loses the run's final line.
@(test)
test_headless_oversized_chunk_keeps_the_tail :: proc(t: ^testing.T) {
	root := headless_test_root()
	defer delete(root)
	defer os.remove_all(root)
	key, err := headless_session_open(root, "req-c", "shot-c", root, 32)
	testing.expect_value(t, err, "")
	s := headless_session_surface(root)
	command := `printf '%s%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' TARGET`
	testing.expect_value(t, s.ops.pane_run(s, key, command), "")
	log_path := fmt.tprintf("%s/host/req-c/logs/shot-c.log", root)
	testing.expect(t, headless_wait_for(log_path, "TARGET"), "the newest bytes of an oversized chunk are kept")
	testing.expect(t, s.ops.tab_close(s, key), "close")
	info, _ := os.stat(log_path, context.temp_allocator)
	testing.expect(t, info.size <= 32, "the rotation still keeps each generation within the bound")
}
