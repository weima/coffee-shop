package sqlite

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_open_memory_uses_pinned_sqlite_and_closes_cleanly :: proc(t: ^testing.T) {
	db, err := open_memory()
	defer error_destroy(&err)
	testing.expect_value(t, err.code, SQLITE_OK)
	testing.expect_value(t, sqlite_version_number(), 3_054_000)

	close_err := close(&db)
	defer error_destroy(&close_err)
	testing.expect_value(t, close_err.code, SQLITE_OK)
}

@(test)
test_open_file_creates_and_closes_database :: proc(t: ^testing.T) {
	directory, temp_err := os.make_directory_temp("", "oreo-sqlite-*", context.allocator)
	testing.expect_value(t, temp_err, os.Error(nil))
	defer os.remove_all(directory)
	defer delete(directory)

	path, path_err := filepath.join({directory, "sessions.db"}, context.allocator)
	testing.expect(t, path_err == nil)
	defer delete(path)

	db, err := open_file(path)
	defer error_destroy(&err)
	testing.expect_value(t, err.code, SQLITE_OK)
	close_err := close(&db)
	defer error_destroy(&close_err)
	testing.expect_value(t, close_err.code, SQLITE_OK)
	testing.expect(t, os.exists(path), "opening a file database creates it")
}

@(test)
test_prepared_statement_binds_and_extracts_values :: proc(t: ^testing.T) {
	db, open_err := open_memory()
	defer error_destroy(&open_err)
	testing.expect_value(t, open_err.code, SQLITE_OK)
	ddl_err := execute(db, "CREATE TABLE values_table (text_value TEXT, int_value INTEGER, blob_value BLOB, null_value TEXT)")
	defer error_destroy(&ddl_err)
	testing.expect_value(t, ddl_err.code, SQLITE_OK)

	insert, prepare_err := prepare(db, "INSERT INTO values_table VALUES (?1, ?2, ?3, ?4)")
	defer {
		finalize_err := finalize(&insert)
		error_destroy(&finalize_err)
		error_destroy(&prepare_err)
	}
	testing.expect_value(t, prepare_err.code, SQLITE_OK)
	text, text_err := strings.clone("hello")
	testing.expect(t, text_err == nil)
	testing.expect_value(t, bind_text(insert, 1, text).code, SQLITE_OK)
	delete(text)
	testing.expect_value(t, bind_int64(insert, 2, 42).code, SQLITE_OK)
	blob, blob_alloc_err := make([]byte, 3, context.allocator)
	testing.expect(t, blob_alloc_err == nil)
	blob[0], blob[1], blob[2] = 0, 1, 255
	testing.expect_value(t, bind_blob(insert, 3, blob).code, SQLITE_OK)
	blob[1] = 99
	delete(blob)
	testing.expect_value(t, bind_null(insert, 4).code, SQLITE_OK)
	result, step_err := step(insert)
	defer error_destroy(&step_err)
	testing.expect_value(t, step_err.code, SQLITE_OK)
	testing.expect_value(t, result, Step_Result.Done)
	finalize_insert_err := finalize(&insert)
	defer error_destroy(&finalize_insert_err)
	testing.expect_value(t, finalize_insert_err.code, SQLITE_OK)

	query, query_err := prepare(db, "SELECT text_value, int_value, blob_value, null_value FROM values_table")
	defer {
		finalize_err := finalize(&query)
		error_destroy(&finalize_err)
		error_destroy(&query_err)
	}
	testing.expect_value(t, query_err.code, SQLITE_OK)
	query_result, query_step_err := step(query)
	defer error_destroy(&query_step_err)
	testing.expect_value(t, query_step_err.code, SQLITE_OK)
	testing.expect_value(t, query_result, Step_Result.Row)
	text_value, text_is_null, text_value_err := column_text(query, 0)
	defer error_destroy(&text_value_err)
	defer delete(text_value)
	testing.expect_value(t, text_value_err.code, SQLITE_OK)
	testing.expect(t, !text_is_null)
	testing.expect_value(t, text_value, "hello")
	int_value, int_value_err := column_int64(query, 1)
	defer error_destroy(&int_value_err)
	testing.expect_value(t, int_value_err.code, SQLITE_OK)
	testing.expect_value(t, int_value, i64(42))
	blob_value, blob_is_null, blob_value_err := column_blob(query, 2)
	defer error_destroy(&blob_value_err)
	defer delete(blob_value)
	testing.expect_value(t, blob_value_err.code, SQLITE_OK)
	testing.expect(t, !blob_is_null)
	testing.expect(t, len(blob_value) == 3 && blob_value[0] == 0 && blob_value[1] == 1 && blob_value[2] == 255)
	null_value, null_is_null, null_value_err := column_text(query, 3)
	defer error_destroy(&null_value_err)
	defer delete(null_value)
	testing.expect_value(t, null_value_err.code, SQLITE_OK)
	testing.expect(t, null_is_null)
	testing.expect_value(t, null_value, "")
}

@(test)
test_empty_text_and_blob_are_not_null :: proc(t: ^testing.T) {
	db, open_err := open_memory()
	defer error_destroy(&open_err)
	testing.expect_value(t, open_err.code, SQLITE_OK)
	defer {
		close_err := close(&db)
		error_destroy(&close_err)
	}

	statement, prepare_err := prepare(db, "SELECT ?1, ?2")
	defer {
		finalize_err := finalize(&statement)
		error_destroy(&finalize_err)
		error_destroy(&prepare_err)
	}
	testing.expect_value(t, prepare_err.code, SQLITE_OK)
	testing.expect_value(t, bind_text(statement, 1, "").code, SQLITE_OK)
	testing.expect_value(t, bind_blob(statement, 2, []byte{}).code, SQLITE_OK)
	result, step_err := step(statement)
	defer error_destroy(&step_err)
	testing.expect_value(t, step_err.code, SQLITE_OK)
	testing.expect_value(t, result, Step_Result.Row)

	text, text_is_null, text_err := column_text(statement, 0)
	defer delete(text)
	defer error_destroy(&text_err)
	testing.expect_value(t, text_err.code, SQLITE_OK)
	testing.expect(t, !text_is_null)
	testing.expect_value(t, text, "")
	blob, blob_is_null, blob_err := column_blob(statement, 1)
	defer delete(blob)
	defer error_destroy(&blob_err)
	testing.expect_value(t, blob_err.code, SQLITE_OK)
	testing.expect(t, !blob_is_null)
	testing.expect_value(t, len(blob), 0)
}

@(test)
test_sql_and_bind_errors_are_reported :: proc(t: ^testing.T) {
	db, open_err := open_memory()
	defer error_destroy(&open_err)
	testing.expect_value(t, open_err.code, SQLITE_OK)
	defer {
		close_err := close(&db)
		error_destroy(&close_err)
	}

	_, invalid_sql_err := prepare(db, "SELEC bad syntax")
	defer error_destroy(&invalid_sql_err)
	testing.expect(t, invalid_sql_err.code != SQLITE_OK)
	testing.expect(t, len(invalid_sql_err.message) > 0)

	statement, prepare_err := prepare(db, "SELECT ?1")
	defer {
		finalize_err := finalize(&statement)
		error_destroy(&finalize_err)
		error_destroy(&prepare_err)
	}
	testing.expect_value(t, prepare_err.code, SQLITE_OK)
	bind_err := bind_int64(statement, 0, 7)
	defer error_destroy(&bind_err)
	testing.expect_value(t, bind_err.code, SQLITE_RANGE)
}

@(test)
test_close_waits_for_prepared_statements_to_be_finalized :: proc(t: ^testing.T) {
	db, open_err := open_memory()
	defer error_destroy(&open_err)
	testing.expect_value(t, open_err.code, SQLITE_OK)
	statement, prepare_err := prepare(db, "SELECT 1")
	defer error_destroy(&prepare_err)
	testing.expect_value(t, prepare_err.code, SQLITE_OK)

	busy_err := close(&db)
	testing.expect(t, busy_err.code != SQLITE_OK, "SQLite refuses close while a statement is active")
	error_destroy(&busy_err)
	finalize_err := finalize(&statement)
	defer error_destroy(&finalize_err)
	testing.expect_value(t, finalize_err.code, SQLITE_OK)
	close_err := close(&db)
	defer error_destroy(&close_err)
	testing.expect_value(t, close_err.code, SQLITE_OK)
}

@(test)
test_transaction_commit_and_rollback :: proc(t: ^testing.T) {
	db, open_err := open_memory()
	defer error_destroy(&open_err)
	testing.expect_value(t, open_err.code, SQLITE_OK)
	defer {
		close_err := close(&db)
		error_destroy(&close_err)
	}
	ddl_err := execute(db, "CREATE TABLE ids (id INTEGER PRIMARY KEY)")
	defer error_destroy(&ddl_err)
	testing.expect_value(t, ddl_err.code, SQLITE_OK)

	begin_err := begin(db)
	defer error_destroy(&begin_err)
	testing.expect_value(t, begin_err.code, SQLITE_OK)
	rollback_insert, rollback_prepare_err := prepare(db, "INSERT INTO ids VALUES (?1)")
	defer {
		finalize_err := finalize(&rollback_insert)
		error_destroy(&finalize_err)
		error_destroy(&rollback_prepare_err)
	}
	testing.expect_value(t, rollback_prepare_err.code, SQLITE_OK)
	testing.expect_value(t, bind_int64(rollback_insert, 1, 1).code, SQLITE_OK)
	insert_result, insert_step_err := step(rollback_insert)
	defer error_destroy(&insert_step_err)
	testing.expect_value(t, insert_step_err.code, SQLITE_OK)
	testing.expect_value(t, insert_result, Step_Result.Done)
	rollback_finalize_err := finalize(&rollback_insert)
	defer error_destroy(&rollback_finalize_err)
	testing.expect_value(t, rollback_finalize_err.code, SQLITE_OK)
	rollback_err := rollback(db)
	defer error_destroy(&rollback_err)
	testing.expect_value(t, rollback_err.code, SQLITE_OK)

	commit_begin_err := begin(db)
	defer error_destroy(&commit_begin_err)
	testing.expect_value(t, commit_begin_err.code, SQLITE_OK)
	commit_insert, commit_prepare_err := prepare(db, "INSERT INTO ids VALUES (?1)")
	defer {
		finalize_err := finalize(&commit_insert)
		error_destroy(&finalize_err)
		error_destroy(&commit_prepare_err)
	}
	testing.expect_value(t, commit_prepare_err.code, SQLITE_OK)
	testing.expect_value(t, bind_int64(commit_insert, 1, 2).code, SQLITE_OK)
	commit_insert_result, commit_insert_step_err := step(commit_insert)
	defer error_destroy(&commit_insert_step_err)
	testing.expect_value(t, commit_insert_step_err.code, SQLITE_OK)
	testing.expect_value(t, commit_insert_result, Step_Result.Done)
	commit_insert_finalize_err := finalize(&commit_insert)
	defer error_destroy(&commit_insert_finalize_err)
	testing.expect_value(t, commit_insert_finalize_err.code, SQLITE_OK)
	commit_err := commit(db)
	defer error_destroy(&commit_err)
	testing.expect_value(t, commit_err.code, SQLITE_OK)

	count_stmt, count_prepare_err := prepare(db, "SELECT count(*) FROM ids")
	defer {
		finalize_err := finalize(&count_stmt)
		error_destroy(&finalize_err)
		error_destroy(&count_prepare_err)
	}
	testing.expect_value(t, count_prepare_err.code, SQLITE_OK)
	count_result, count_step_err := step(count_stmt)
	defer error_destroy(&count_step_err)
	testing.expect_value(t, count_step_err.code, SQLITE_OK)
	testing.expect_value(t, count_result, Step_Result.Row)
	count, count_err := column_int64(count_stmt, 0)
	defer error_destroy(&count_err)
	testing.expect_value(t, count_err.code, SQLITE_OK)
	testing.expect_value(t, count, i64(1))
}

@(test)
test_open_file_rejects_empty_and_nul_paths :: proc(t: ^testing.T) {
	for path in ([]string{"", "bad\x00path"}) {
		db, err := open_file(path)
		testing.expect_value(t, err.code, SQLITE_MISUSE)
		error_destroy(&err)
		close_err := close(&db)
		testing.expect_value(t, close_err.code, SQLITE_OK)
		error_destroy(&close_err)
	}
}

@(test)
test_open_file_failure_returns_sqlite_error :: proc(t: ^testing.T) {
	directory, temp_err := os.make_directory_temp("", "oreo-sqlite-*", context.allocator)
	testing.expect_value(t, temp_err, os.Error(nil))
	defer os.remove_all(directory)
	defer delete(directory)

	path, path_err := filepath.join({directory, "missing", "sessions.db"}, context.allocator)
	testing.expect(t, path_err == nil)
	defer delete(path)

	db, err := open_file(path)
	defer error_destroy(&err)
	testing.expect(t, err.code != SQLITE_OK, "opening below a missing directory must fail")
	testing.expect(t, len(err.message) > 0, "SQLite errors include a message")
	close_err := close(&db)
	defer error_destroy(&close_err)
	testing.expect_value(t, close_err.code, SQLITE_OK)
}
