package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:hash"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

SERVER_DIRECTORY_NAME :: "servers"
SERVER_LOCK_FILE_NAME :: "server.lock"
SERVER_RECORD_FILE_NAME :: "server.json"

// Server_Record is what server.json holds. The id comes from the repository, so a
// restart keeps it; generation only counts starts. Nothing else depends on it.
Server_Record :: struct {
	id: string,
	pid: int,
	generation: int,
	heartbeat_ns: i64,
	socket_path: string,
	repository_path: string,
}

// The id is the repository's name plus a hash of its absolute path. Every start
// for that repository computes the same id, even if server.json is lost.
server_id :: proc(repository: string, allocator := context.allocator) -> string {
	name := repository_name(repository)
	defer delete(name)
	sum := hash.fnv64a(transmute([]byte)repository)
	return fmt.aprintf("%s-%016x", name, sum, allocator = allocator)
}

server_directory :: proc(state_root, id: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s/%s/%s", state_root, SERVER_DIRECTORY_NAME, id, allocator = allocator)
}

// Takes the election lock without waiting. The returned file must stay open for
// as long as the server runs: the kernel drops the lock when it closes.
server_acquire :: proc(directory: string) -> (file: ^os.File, ok: bool) {
	if !os.exists(directory) && os.make_directory_all(directory, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return nil, false
	}
	path := state_file_path(directory, SERVER_LOCK_FILE_NAME)
	defer delete(path)
	opened, open_err := os.open(path, os.O_RDWR|os.O_CREATE, private_file_permissions())
	if open_err != nil {
		return nil, false
	}
	if linux.flock(linux.Fd(os.fd(opened)), {.EX, .NB}) != .NONE {
		_ = os.close(opened)
		return nil, false
	}
	if !server_lock_is_current(directory, opened) {
		file_lock_release(opened)
		return nil, false
	}
	return opened, true
}

// A lock belongs to the file it was taken on. If the directory was removed and
// recreated, the path names a new file, and a lock on the old one proves nothing.
// Such a server must stop without touching the socket path, which now belongs to
// its successor.
server_lock_is_current :: proc(directory: string, lock: ^os.File) -> bool {
	path := state_file_path(directory, SERVER_LOCK_FILE_NAME)
	defer delete(path)
	on_path, path_err := os.stat(path, context.allocator)
	if path_err != nil {
		return false
	}
	defer os.file_info_delete(on_path, context.allocator)
	held, held_err := os.fstat(lock, context.allocator)
	if held_err != nil {
		return false
	}
	defer os.file_info_delete(held, context.allocator)
	return on_path.inode == held.inode
}

// True while another process holds the election lock. A missing lock file means
// no server has ever started here.
server_running :: proc(directory: string) -> bool {
	path := state_file_path(directory, SERVER_LOCK_FILE_NAME)
	defer delete(path)
	opened, open_err := os.open(path, os.O_RDWR)
	if open_err != nil {
		return false
	}
	fd := linux.Fd(os.fd(opened))
	if linux.flock(fd, {.EX, .NB}) != .NONE {
		_ = os.close(opened)
		return true
	}
	_ = linux.flock(fd, {.UN})
	_ = os.close(opened)
	return false
}

// Claims the server for a resource and records this start. The caller keeps the
// returned lock file open for the server's life. The id is passed in unchanged
// from the previous start; only the generation advances.
server_start :: proc(directory, id, repository_path, socket_path: string) -> (lock: ^os.File, record: Server_Record, ok: bool) {
	acquired, acquired_ok := server_acquire(directory)
	log.debugf("election dir=%s acquired=%v", directory, acquired_ok)
	if !acquired_ok {
		return nil, {}, false
	}
	previous, has_previous := server_read_record(directory)
	generation := 1
	if has_previous {
		generation = previous.generation + 1
		destroy_struct(&previous)
	}
	record = Server_Record{
		id = id,
		pid = os.get_pid(),
		generation = generation,
		heartbeat_ns = time.now()._nsec,
		socket_path = socket_path,
		repository_path = repository_path,
	}
	if !server_write_record(directory, record) {
		file_lock_release(acquired)
		return nil, {}, false
	}
	return acquired, record, true
}

// Rewrites server.json with a fresh heartbeat. The heartbeat is for display and
// diagnosis; liveness comes from the election lock.
server_heartbeat :: proc(directory: string, record: ^Server_Record) -> bool {
	record.heartbeat_ns = time.now()._nsec
	return server_write_record(directory, record^)
}

server_read_record :: proc(directory: string) -> (record: Server_Record, ok: bool) {
	path := state_file_path(directory, SERVER_RECORD_FILE_NAME)
	defer delete(path)
	data, read_err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	if read_err != nil {
		return {}, false
	}
	if json.unmarshal_string(transmute(string)data, &record, .JSON) != nil {
		destroy_struct(&record)
		return {}, false
	}
	return record, true
}

server_write_record :: proc(directory: string, record: Server_Record) -> bool {
	log.debugf("record write dir=%s generation=%d pid=%d", directory, record.generation, record.pid)
	data, marshal_err := json.marshal(record, json.Marshal_Options{spec = .JSON})
	defer delete(data)
	if marshal_err != nil {
		return false
	}
	path := state_file_path(directory, SERVER_RECORD_FILE_NAME)
	defer delete(path)
	return write_file_atomic(path, data)
}

// Releases the election lock. Closing the file is what lets a new server start.
file_lock_release :: proc(file: ^os.File) {
	_ = linux.flock(linux.Fd(os.fd(file)), {.UN})
	_ = os.close(file)
}

// True while some Brew on this repository has a Shot that has not finished.
repository_has_active_brew :: proc(state_root, repository: string) -> bool {
	handle, open_err := os.open(state_root)
	if open_err != nil {
		return false
	}
	defer os.close(handle)
	entries, read_err := os.read_dir(handle, -1, context.allocator)
	defer os.file_info_slice_delete(entries, context.allocator)
	if read_err != nil {
		return false
	}
	for entry in entries {
		if !strings.has_prefix(entry.name, "brew-") {
			continue
		}
		brew_dir := state_file_path(state_root, entry.name)
		brew_repository, brew_token, ok := brew_identity(brew_dir)
		active := false
		if ok && brew_repository == repository {
			register, state_err := read_state_recovering(brew_dir)
			active = state_err.kind == .None && !all_terminal(register)
			destroy_struct(&register)
		}
		delete(brew_repository)
		delete(brew_token)
		delete(brew_dir)
		if active {
			return true
		}
	}
	return false
}

SERVER_HEARTBEAT_NS :: 1_000_000_000
SERVER_IDLE_NS :: 30 * 1_000_000_000

// The __server process: one per repository. It exits quietly if another server
// already holds the repository, and after a period with no active Brew.
run_server :: proc(state_root, repository: string) -> int {
	log.debugf("server start repository=%s state=%s", repository, state_root)
	id := server_id(repository)
	defer delete(id)
	directory := server_directory(state_root, id)
	defer delete(directory)
	socket_path, path_err := strings.concatenate({directory, "/", SERVER_SOCKET_NAME})
	if path_err != nil {
		write_error("could not build the server socket path")
		return 2
	}
	defer delete(socket_path)

	lock, started_record, started := server_start(directory, id, repository, socket_path)
	if !started {
		if server_running(directory) {
			return 0
		}
		write_error("could not start the server")
		return 2
	}
	defer file_lock_release(lock)
	record := started_record
	api, api_ok := server_api_open(state_root, repository, directory)
	if !api_ok {
		write_error("the server socket could not be opened")
		return 2
	}
	defer if api.listener >= 0 {
		server_api_close(&api)
	}

	last_beat := time.now()._nsec
	last_active := last_beat
	for {
		if !server_lock_is_current(directory, lock) {
			server_api_abandon(&api)
			return 0
		}
		server_api_serve_one(&api, 100)
		now := time.now()._nsec
		if now - last_beat >= SERVER_HEARTBEAT_NS {
			last_beat = now
			_ = server_heartbeat(directory, &record)
			if repository_has_active_brew(state_root, repository) {
				last_active = now
			}
		}
		if now - last_active >= SERVER_IDLE_NS {
			return 0
		}
	}
}
