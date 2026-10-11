package oreo

import "core:os"
import "core:path/filepath"
import "core:testing"

TEMP_DIR :: "/private/tmp" when ODIN_OS == .Darwin else "/tmp"

@(test)
test_closed_session_survives_host_restart :: proc(t: ^testing.T) {
	directory, directory_err := os.make_directory_temp(TEMP_DIR, "oreo-host-*", context.allocator)
	testing.expect_value(t, directory_err, os.Error(nil))
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	path, path_err := filepath.join({directory, "sessions.db"}, context.allocator)
	testing.expect(t, path_err == nil)
	defer delete(path)

	host, open_err := open_host(path)
	defer host_error_destroy(&open_err)
	testing.expect_value(t, open_err.kind, Host_Error_Kind.None)

	session, create_err := create_session(host, "provider-neutral task")
	defer session_destroy(&session)
	defer host_error_destroy(&create_err)
	testing.expect_value(t, create_err.kind, Host_Error_Kind.None)
	testing.expect(t, len(session.id) > 0)

	close_err := close_session(host, session.id)
	defer host_error_destroy(&close_err)
	testing.expect_value(t, close_err.kind, Host_Error_Kind.None)

	closed, found, find_err := find_session(host, session.id)
	defer session_destroy(&closed)
	defer host_error_destroy(&find_err)
	testing.expect_value(t, find_err.kind, Host_Error_Kind.None)
	testing.expect(t, found)
	testing.expect_value(t, closed.status, SESSION_CLOSED)
	testing.expect_value(t, closed.title, "provider-neutral task")

	close_host_err := close_host(&host)
	defer host_error_destroy(&close_host_err)
	testing.expect_value(t, close_host_err.kind, Host_Error_Kind.None)

	reopened, reopen_err := open_host(path)
	defer host_error_destroy(&reopen_err)
	testing.expect_value(t, reopen_err.kind, Host_Error_Kind.None)

	restarted, restart_found, restart_err := find_session(reopened, session.id)
	defer session_destroy(&restarted)
	defer host_error_destroy(&restart_err)
	testing.expect_value(t, restart_err.kind, Host_Error_Kind.None)
	testing.expect(t, restart_found)
	testing.expect_value(t, restarted.status, SESSION_CLOSED)
	testing.expect_value(t, restarted.title, "provider-neutral task")

	close_err = close_host(&reopened)
	testing.expect_value(t, close_err.kind, Host_Error_Kind.None)
}
