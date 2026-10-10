# Oreo SQLite Binding

A small, first-party Odin binding to the SQLite C API for Oreo. Oreo's session store owns the database schema and SQL queries; this package only owns the binding boundary and SQLite resource lifecycle.

## Status

The official SQLite 3.54.0 amalgamation is bundled. The binding supports connection lifecycle, fixed SQL execution, prepared statements, integer/double/text/blob/null binding, column reads, and transactions. The Oreo store initializes v1 schema, persists/retrieves session, profile, work-item, and ordered-record metadata, guards work-item transitions, and persists session-close cancellation requests. Nine binding tests and four store tests pass on macOS; Linux verification and worker execution remain pending.

## Scope

- Bind only the SQLite operations Oreo needs: open/close, prepare/step/finalize, bind/read values, transactions, and errors.
- Build SQLite from a pinned official amalgamation. Oreo users will not need to install a system SQLite library or run a database server.
- Keep session tables, metadata indexes, and session queries in Oreo's store layer.
- Keep the API narrow. Add general-purpose features only when Oreo needs them.

## Verification

Run the focused checks from the repository root:

```sh
cd oreo && just test
```

The `test` recipe depends on `check`.

The `just` recipes compile the bundled amalgamation and link it into Odin's real-SQLite tests; they do not use a mock or system SQLite library. Binding tests cover memory/file open and close, the bundled engine version, prepared statements, value binding and extraction, invalid SQL/binds, transaction commit/rollback, and cleanup. Store tests apply the documented schema, verify foreign keys and ordered records, then close/reopen a temporary database to prove metadata persistence. These tests are verified on macOS; run the same recipes on Linux before closing platform hardening.

## References and attribution

The Odin binding design was informed by these community projects:

- [blob1807/odin_sqlite3_bindings](https://github.com/blob1807/odin_sqlite3_bindings)
- [saenai255/odin-sqlite3](https://github.com/saenai255/odin-sqlite3)

They are references, not source dependencies; the initial Oreo binding will be written fresh and will not copy their implementation. SQLite's official source is [dedicated to the public domain](https://sqlite.org/copyright.html). Keep the notices distributed with the selected SQLite release.
