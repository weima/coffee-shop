package main

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
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
	return opened, true
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
	if !acquired_ok {
		return nil, {}, false
	}
	previous, has_previous := server_read_record(directory)
	generation := 1
	if has_previous {
		generation = previous.generation + 1
		server_record_destroy(&previous)
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
		state_unlock(acquired)
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
		server_record_destroy(&record)
		return {}, false
	}
	return record, true
}

server_write_record :: proc(directory: string, record: Server_Record) -> bool {
	data, marshal_err := json.marshal(record, json.Marshal_Options{spec = .JSON})
	defer delete(data)
	if marshal_err != nil {
		return false
	}
	path := state_file_path(directory, SERVER_RECORD_FILE_NAME)
	defer delete(path)
	return write_file_atomic(path, data)
}

server_record_destroy :: proc(record: ^Server_Record) {
	delete(record.id)
	delete(record.socket_path)
	delete(record.repository_path)
	record^ = Server_Record{}
}
