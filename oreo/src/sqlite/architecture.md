# SQLite Binding Architecture

## Purpose

Provide the smallest Odin-facing boundary needed for Oreo to use the official SQLite C library. This is not an ORM and does not own Oreo's session schema.

## Ownership boundaries

| Component | Owns |
|---|---|
| `oreo/src/sqlite` | SQLite C declarations, database/statement handles, value binding and extraction, transactions, and SQLite error reporting. |
| Oreo session store | Tables, indexes, migrations, SQL statements, session/work-item models, metadata lookup, and persistence policy. |
| SQLite amalgamation | Upstream SQLite engine implementation, pinned to an exact official release. |

## API scope

Expose only the operations needed by the session store:

- Open and close a database connection.
- Prepare and finalize a statement.
- Bind supported values and step through results.
- Read supported column values.
- Begin, commit, and roll back transactions.
- Return SQLite result codes and useful error messages.

No reflection-based row mapping, query builder, ORM, connection pool, or broad re-export of the SQLite API is planned for v1.

## Resource and error behavior

- A database handle owns its SQLite connection; a statement handle owns its prepared statement.
- Statements must be finalized before their connection is closed.
- Recoverable SQLite failures are returned to the caller, not converted to panics. The store maps low-level failures to Oreo-level errors.
- The store uses bound parameters for data values. It does not interpolate user-provided values into SQL text.
- A failed store transaction is rolled back before the connection is reused.
- The store owns synchronization for its connection and transaction sequences; the binding does not promise that arbitrary concurrent use of one statement is safe.

## Build and distribution

- Compile the official SQLite amalgamation into Oreo; do not link against a system SQLite installation.
- Pin the release and record its source URL, checksum, build options, and notices.
- Confirm the C compilation/linking path with the active Odin toolchain before finalizing build scripts. A native C compiler may still be a build prerequisite; SQLite itself is not a separately installed runtime dependency.

## Testing

All tests use the real bundled SQLite implementation.

- Binding tests cover open/close, statements, parameter binding, result extraction, transaction commit/rollback, and error paths.
- Store end-to-end tests use an isolated temporary database file, write and query session metadata, close the connection, reopen the file, and confirm the data remains.
- CI runs the same tests on Linux and macOS. No SQLite server or test mock is used.

## References

The implementation is original Oreo code. The following repositories were consulted for Odin/C API binding patterns and API usability; their implementation code is not copied:

- [blob1807/odin_sqlite3_bindings](https://github.com/blob1807/odin_sqlite3_bindings)
- [saenai255/odin-sqlite3](https://github.com/saenai255/odin-sqlite3)

SQLite source is public domain according to the [official SQLite copyright page](https://sqlite.org/copyright.html). Preserve the notices that accompany the pinned source release.
