package sqlite

import "base:runtime"
import "core:c"
import "core:strings"

@(private)
SQLite3 :: struct {}
@(private)
SQLite3_Statement :: struct {}

foreign import sqlite_c "system:c"
foreign sqlite_c {
	@(private)
	sqlite3_open_v2 :: proc(filename: cstring, db: ^^SQLite3, flags: c.int, vfs: cstring) -> c.int ---
	@(private)
	sqlite3_close :: proc(db: ^SQLite3) -> c.int ---
	@(private)
	sqlite3_errmsg :: proc(db: ^SQLite3) -> cstring ---
	@(private)
	sqlite3_errstr :: proc(code: c.int) -> cstring ---
	@(private)
	sqlite3_libversion_number :: proc() -> c.int ---
	@(private)
	sqlite3_exec :: proc(db: ^SQLite3, sql: cstring, callback: rawptr, callback_data: rawptr, error_message: ^^u8) -> c.int ---
	@(private)
	sqlite3_prepare_v2 :: proc(db: ^SQLite3, sql: cstring, byte_count: c.int, statement: ^^SQLite3_Statement, tail: ^cstring) -> c.int ---
	@(private)
	sqlite3_finalize :: proc(statement: ^SQLite3_Statement) -> c.int ---
	@(private)
	sqlite3_step :: proc(statement: ^SQLite3_Statement) -> c.int ---
	@(private)
	sqlite3_db_handle :: proc(statement: ^SQLite3_Statement) -> ^SQLite3 ---
	@(private)
	sqlite3_bind_int64 :: proc(statement: ^SQLite3_Statement, index: c.int, value: c.int64_t) -> c.int ---
	@(private)
	sqlite3_bind_double :: proc(statement: ^SQLite3_Statement, index: c.int, value: c.double) -> c.int ---
	@(private)
	sqlite3_bind_text64 :: proc(statement: ^SQLite3_Statement, index: c.int, value: cstring, byte_count: c.uint64_t, destructor: rawptr, encoding: c.uchar) -> c.int ---
	@(private)
	sqlite3_bind_blob64 :: proc(statement: ^SQLite3_Statement, index: c.int, value: rawptr, byte_count: c.uint64_t, destructor: rawptr) -> c.int ---
	@(private)
	sqlite3_bind_zeroblob64 :: proc(statement: ^SQLite3_Statement, index: c.int, byte_count: c.uint64_t) -> c.int ---
	@(private)
	sqlite3_bind_null :: proc(statement: ^SQLite3_Statement, index: c.int) -> c.int ---
	@(private)
	sqlite3_column_count :: proc(statement: ^SQLite3_Statement) -> c.int ---
	@(private)
	sqlite3_column_type :: proc(statement: ^SQLite3_Statement, index: c.int) -> c.int ---
	@(private)
	sqlite3_column_int64 :: proc(statement: ^SQLite3_Statement, index: c.int) -> c.int64_t ---
	@(private)
	sqlite3_column_double :: proc(statement: ^SQLite3_Statement, index: c.int) -> c.double ---
	@(private)
	sqlite3_column_text :: proc(statement: ^SQLite3_Statement, index: c.int) -> [^]u8 ---
	@(private)
	sqlite3_column_blob :: proc(statement: ^SQLite3_Statement, index: c.int) -> rawptr ---
	@(private)
	sqlite3_column_bytes :: proc(statement: ^SQLite3_Statement, index: c.int) -> c.int ---
}

@(private) SQLITE_OK :: c.int(0)
@(private) SQLITE_ERROR :: c.int(1)
@(private) SQLITE_NOMEM :: c.int(7)
@(private) SQLITE_TOOBIG :: c.int(18)
@(private) SQLITE_MISUSE :: c.int(21)
@(private) SQLITE_RANGE :: c.int(25)
@(private) SQLITE_ROW :: c.int(100)
@(private) SQLITE_DONE :: c.int(101)

@(private) SQLITE_OPEN_READWRITE :: c.int(0x00000002)
@(private) SQLITE_OPEN_CREATE :: c.int(0x00000004)
@(private) SQLITE_OPEN_FULLMUTEX :: c.int(0x00010000)
@(private) SQLITE_UTF8 :: c.uchar(1)

// SQLite defines SQLITE_TRANSIENT as (sqlite3_destructor_type)-1; rawptr preserves that ABI sentinel.
@(private) SQLITE_TRANSIENT :: cast(rawptr)~uintptr(0)

// Database is an opaque SQLite connection handle. Use close rather than freeing the handle.
Database :: distinct ^SQLite3

// Statement is an opaque prepared-statement handle. Finalize it before closing its database.
Statement :: distinct ^SQLite3_Statement

Error :: struct {
	code: c.int,
	message: string,
}

Step_Result :: enum {
	Row,
	Done,
}

Column_Type :: enum {
	Integer,
	Float,
	Text,
	Blob,
	Null,
}

// Opens an isolated SQLite in-memory database using the same bundled engine as file databases.
open_memory :: proc(allocator := context.allocator) -> (Database, Error) {
	return open_path(":memory:", allocator)
}

// Opens or creates a file-backed database. Oreo's store, not this binding, owns its schema.
open_file :: proc(path: string, allocator := context.allocator) -> (Database, Error) {
	if len(path) == 0 || strings.index_byte(path, 0) >= 0 {
		return Database(nil), error_make(SQLITE_MISUSE, "database path must be non-empty and contain no NUL byte", allocator)
	}
	return open_path(path, allocator)
}

@(private)
open_path :: proc(path: string, allocator: runtime.Allocator) -> (Database, Error) {
	c_path, alloc_err := strings.clone_to_cstring(path, allocator)
	if alloc_err != nil {
		return Database(nil), error_make(SQLITE_NOMEM, "could not allocate database path", allocator)
	}
	defer delete(c_path, allocator)

	handle: ^SQLite3
	flags := SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
	code := sqlite3_open_v2(c_path, &handle, flags, nil)
	if code != SQLITE_OK {
		err := sqlite_error(handle, code, allocator)
		if handle != nil {
			_ = sqlite3_close(handle)
		}
		return Database(nil), err
	}
	return Database(handle), Error{}
}

// Closes a database connection. A failed close leaves the handle available for cleanup/retry.
close :: proc(db: ^Database, allocator := context.allocator) -> Error {
	if db == nil || db^ == Database(nil) {
		return Error{code = SQLITE_OK}
	}
	handle := cast(^SQLite3)db^
	code := sqlite3_close(handle)
	if code != SQLITE_OK {
		return sqlite_error(handle, code, allocator)
	}
	db^ = Database(nil)
	return Error{code = SQLITE_OK}
}

// execute runs fixed schema or transaction-control SQL. Bind data with prepared statements.
execute :: proc(db: Database, sql: string, allocator := context.allocator) -> Error {
	handle := cast(^SQLite3)db
	if handle == nil || len(sql) == 0 || strings.index_byte(sql, 0) >= 0 {
		return error_make(SQLITE_MISUSE, "database handle and non-empty NUL-free SQL are required", allocator)
	}
	c_sql, alloc_err := strings.clone_to_cstring(sql, allocator)
	if alloc_err != nil {
		return error_make(SQLITE_NOMEM, "could not allocate SQL text", allocator)
	}
	defer delete(c_sql, allocator)

	code := sqlite3_exec(handle, c_sql, nil, nil, nil)
	if code != SQLITE_OK {
		return sqlite_error(handle, code, allocator)
	}
	return Error{code = SQLITE_OK}
}

// begin uses an immediate transaction so a write lock is acquired before store mutations start.
begin :: proc(db: Database, allocator := context.allocator) -> Error {
	return execute(db, "BEGIN IMMEDIATE", allocator)
}

commit :: proc(db: Database, allocator := context.allocator) -> Error {
	return execute(db, "COMMIT", allocator)
}

rollback :: proc(db: Database, allocator := context.allocator) -> Error {
	return execute(db, "ROLLBACK", allocator)
}

sqlite_version_number :: proc() -> c.int {
	return sqlite3_libversion_number()
}

prepare :: proc(db: Database, sql: string, allocator := context.allocator) -> (Statement, Error) {
	handle := cast(^SQLite3)db
	if handle == nil || len(sql) == 0 || strings.index_byte(sql, 0) >= 0 {
		return Statement(nil), error_make(SQLITE_MISUSE, "database handle and non-empty NUL-free SQL are required", allocator)
	}
	c_sql, alloc_err := strings.clone_to_cstring(sql, allocator)
	if alloc_err != nil {
		return Statement(nil), error_make(SQLITE_NOMEM, "could not allocate SQL text", allocator)
	}
	defer delete(c_sql, allocator)

	statement: ^SQLite3_Statement
	code := sqlite3_prepare_v2(handle, c_sql, -1, &statement, nil)
	if code != SQLITE_OK {
		err := sqlite_error(handle, code, allocator)
		if statement != nil {
			_ = sqlite3_finalize(statement)
		}
		return Statement(nil), err
	}
	if statement == nil {
		return Statement(nil), error_make(SQLITE_ERROR, "SQL contains no statement", allocator)
	}
	return Statement(statement), Error{code = SQLITE_OK}
}

step :: proc(statement: Statement, allocator := context.allocator) -> (Step_Result, Error) {
	handle := cast(^SQLite3_Statement)statement
	if handle == nil {
		return .Done, error_make(SQLITE_MISUSE, "statement handle is required", allocator)
	}
	code := sqlite3_step(handle)
	switch code {
	case SQLITE_ROW:
		return .Row, Error{code = SQLITE_OK}
	case SQLITE_DONE:
		return .Done, Error{code = SQLITE_OK}
	}
	return .Done, sqlite_error(sqlite3_db_handle(handle), code, allocator)
}

// finalize releases the statement even when SQLite reports its last execution error.
finalize :: proc(statement: ^Statement, allocator := context.allocator) -> Error {
	if statement == nil || statement^ == Statement(nil) {
		return Error{code = SQLITE_OK}
	}
	handle := cast(^SQLite3_Statement)statement^
	db_handle := sqlite3_db_handle(handle)
	code := sqlite3_finalize(handle)
	statement^ = Statement(nil)
	if code != SQLITE_OK {
		return sqlite_error(db_handle, code, allocator)
	}
	return Error{code = SQLITE_OK}
}

bind_int64 :: proc(statement: Statement, index: int, value: i64, allocator := context.allocator) -> Error {
	handle := cast(^SQLite3_Statement)statement
	if handle == nil {
		return error_make(SQLITE_MISUSE, "statement handle is required", allocator)
	}
	code := sqlite3_bind_int64(handle, c.int(index), c.int64_t(value))
	return sqlite_error(sqlite3_db_handle(handle), code, allocator) if code != SQLITE_OK else Error{code = SQLITE_OK}
}

bind_double :: proc(statement: Statement, index: int, value: f64, allocator := context.allocator) -> Error {
	handle := cast(^SQLite3_Statement)statement
	if handle == nil {
		return error_make(SQLITE_MISUSE, "statement handle is required", allocator)
	}
	code := sqlite3_bind_double(handle, c.int(index), c.double(value))
	return sqlite_error(sqlite3_db_handle(handle), code, allocator) if code != SQLITE_OK else Error{code = SQLITE_OK}
}

bind_text :: proc(statement: Statement, index: int, value: string, allocator := context.allocator) -> Error {
	handle := cast(^SQLite3_Statement)statement
	if handle == nil {
		return error_make(SQLITE_MISUSE, "statement handle is required", allocator)
	}
	c_value, alloc_err := strings.clone_to_cstring(value, allocator)
	if alloc_err != nil {
		return error_make(SQLITE_NOMEM, "could not allocate bound text", allocator)
	}
	defer delete(c_value, allocator)
	code := sqlite3_bind_text64(handle, c.int(index), c_value, c.uint64_t(len(value)), SQLITE_TRANSIENT, SQLITE_UTF8)
	return sqlite_error(sqlite3_db_handle(handle), code, allocator) if code != SQLITE_OK else Error{code = SQLITE_OK}
}

bind_blob :: proc(statement: Statement, index: int, value: []byte, allocator := context.allocator) -> Error {
	handle := cast(^SQLite3_Statement)statement
	if handle == nil {
		return error_make(SQLITE_MISUSE, "statement handle is required", allocator)
	}
	code := SQLITE_OK
	if len(value) == 0 {
		code = sqlite3_bind_zeroblob64(handle, c.int(index), 0)
	} else {
		code = sqlite3_bind_blob64(handle, c.int(index), raw_data(value), c.uint64_t(len(value)), SQLITE_TRANSIENT)
	}
	return sqlite_error(sqlite3_db_handle(handle), code, allocator) if code != SQLITE_OK else Error{code = SQLITE_OK}
}

bind_null :: proc(statement: Statement, index: int, allocator := context.allocator) -> Error {
	handle := cast(^SQLite3_Statement)statement
	if handle == nil {
		return error_make(SQLITE_MISUSE, "statement handle is required", allocator)
	}
	code := sqlite3_bind_null(handle, c.int(index))
	return sqlite_error(sqlite3_db_handle(handle), code, allocator) if code != SQLITE_OK else Error{code = SQLITE_OK}
}

column_type :: proc(statement: Statement, index: int, allocator := context.allocator) -> (Column_Type, Error) {
	handle := cast(^SQLite3_Statement)statement
	if err := validate_column(handle, index, allocator); err.code != SQLITE_OK {
		return .Null, err
	}
	switch sqlite3_column_type(handle, c.int(index)) {
	case 1: return .Integer, Error{code = SQLITE_OK}
	case 2: return .Float, Error{code = SQLITE_OK}
	case 3: return .Text, Error{code = SQLITE_OK}
	case 4: return .Blob, Error{code = SQLITE_OK}
	case 5: return .Null, Error{code = SQLITE_OK}
	}
	return .Null, error_make(SQLITE_MISUSE, "SQLite returned an unknown column type", allocator)
}

column_int64 :: proc(statement: Statement, index: int, allocator := context.allocator) -> (i64, Error) {
	handle := cast(^SQLite3_Statement)statement
	if err := validate_column(handle, index, allocator); err.code != SQLITE_OK {
		return 0, err
	}
	return i64(sqlite3_column_int64(handle, c.int(index))), Error{code = SQLITE_OK}
}

column_double :: proc(statement: Statement, index: int, allocator := context.allocator) -> (f64, Error) {
	handle := cast(^SQLite3_Statement)statement
	if err := validate_column(handle, index, allocator); err.code != SQLITE_OK {
		return 0, err
	}
	return f64(sqlite3_column_double(handle, c.int(index))), Error{code = SQLITE_OK}
}

column_text :: proc(statement: Statement, index: int, allocator := context.allocator) -> (value: string, is_null: bool, err: Error) {
	handle := cast(^SQLite3_Statement)statement
	if err = validate_column(handle, index, allocator); err.code != SQLITE_OK {
		return "", false, err
	}
	if sqlite3_column_type(handle, c.int(index)) == 5 {
		return "", true, Error{code = SQLITE_OK}
	}
	byte_count := int(sqlite3_column_bytes(handle, c.int(index)))
	if byte_count == 0 {
		owned_text, alloc_err := strings.clone("", allocator)
		if alloc_err != nil {
			return "", false, error_make(SQLITE_NOMEM, "could not allocate column text", allocator)
		}
		return owned_text, false, Error{code = SQLITE_OK}
	}
	text := sqlite3_column_text(handle, c.int(index))
	if text == nil {
		return "", false, sqlite_error(sqlite3_db_handle(handle), SQLITE_NOMEM, allocator)
	}
	owned_text, alloc_err := strings.clone(string(text[:byte_count]), allocator)
	if alloc_err != nil {
		return "", false, error_make(SQLITE_NOMEM, "could not allocate column text", allocator)
	}
	return owned_text, false, Error{code = SQLITE_OK}
}

column_blob :: proc(statement: Statement, index: int, allocator := context.allocator) -> (value: []byte, is_null: bool, err: Error) {
	handle := cast(^SQLite3_Statement)statement
	if err = validate_column(handle, index, allocator); err.code != SQLITE_OK {
		return nil, false, err
	}
	if sqlite3_column_type(handle, c.int(index)) == 5 {
		return nil, true, Error{code = SQLITE_OK}
	}
	byte_count := int(sqlite3_column_bytes(handle, c.int(index)))
	blob_copy, alloc_err := make([]byte, byte_count, allocator)
	if alloc_err != nil {
		return nil, false, error_make(SQLITE_NOMEM, "could not allocate column blob", allocator)
	}
	if byte_count > 0 {
		blob := sqlite3_column_blob(handle, c.int(index))
		if blob == nil {
			delete(blob_copy, allocator)
			return nil, false, sqlite_error(sqlite3_db_handle(handle), SQLITE_NOMEM, allocator)
		}
		blob_bytes := cast([^]byte)blob
		copy(blob_copy, blob_bytes[:byte_count])
	}
	return blob_copy, false, Error{code = SQLITE_OK}
}

@(private)
validate_column :: proc(handle: ^SQLite3_Statement, index: int, allocator: runtime.Allocator) -> Error {
	if handle == nil {
		return error_make(SQLITE_MISUSE, "statement handle is required", allocator)
	}
	if index < 0 || index >= int(sqlite3_column_count(handle)) {
		return error_make(SQLITE_RANGE, "column index is out of range", allocator)
	}
	return Error{code = SQLITE_OK}
}

@(private)
error_make :: proc(code: c.int, message: string, allocator: runtime.Allocator) -> Error {
	owned, _ := strings.clone(message, allocator)
	return Error{code = code, message = owned}
}

@(private)
sqlite_error :: proc(handle: ^SQLite3, code: c.int, allocator: runtime.Allocator) -> Error {
	message := sqlite3_errstr(code)
	if handle != nil {
		message = sqlite3_errmsg(handle)
	}
	if message == nil {
		return Error{code = code}
	}
	owned, _ := strings.clone_from_cstring(message, allocator)
	return Error{code = code, message = owned}
}

error_destroy :: proc(err: ^Error, allocator := context.allocator) {
	delete(err.message, allocator)
	err^ = Error{code = SQLITE_OK}
}
