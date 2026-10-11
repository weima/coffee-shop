package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The first interactive slice is only the public controller seam: a foreground
// host accepts structured dispatches, acknowledges each request in order, and
// stays ready until the harness explicitly shuts it down. No Pi or Herdr is
// involved in this contract test.
@(test)
test_foreground_host_accepts_dispatches_and_stays_ready :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(HOST_TEST_TEMP_DIR, "coffee-shop-host-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	input_path := fmt.aprintf("%s/requests.ndjson", root)
	defer delete(input_path)
	input := `{"type":"dispatch","request_id":"order-1","repo":"/tmp/beans","recipe":{"order":"first order","shots":[{"id":"shot-a","prompt":"inspect the repository"}]}}
{"type":"dispatch","request_id":"order-2","repo":"/tmp/beans","recipe":{"order":"second order","shots":[{"id":"shot-b","prompt":"inspect the tests"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`
	write_err := os.write_entire_file(input_path, input, os.Permissions{.Read_User, .Write_User})
	testing.expect_value(t, write_err, os.Error(nil))
	if write_err != nil {
		return
	}

	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `cat "$1" | odin run src -- host`, "coffee-shop-host-test", input_path},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)

	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state.success, string(stderr))
	testing.expect(t, strings.contains(string(stdout), `{"type":"ready","protocol":1}`), string(stdout))
	testing.expect(t, strings.contains(string(stdout), `{"type":"dispatch_accepted","request_id":"order-1"}`), string(stdout))
	testing.expect(t, strings.contains(string(stdout), `{"type":"dispatch_accepted","request_id":"order-2"}`), string(stdout))
	testing.expect(t, strings.contains(string(stdout), `{"type":"stopped","request_id":"shutdown-1"}`), string(stdout))
}

HOST_TEST_TEMP_DIR :: "/private/tmp" when ODIN_OS == .Darwin else "/tmp"
