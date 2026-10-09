# Oreo SQLite Binding

A small, first-party Odin binding to the SQLite C API for Oreo. Oreo's session store owns the database schema and SQL queries; this package only owns the binding boundary and SQLite resource lifecycle.

## Status

Design and implementation plan approved. The binding and its real-SQLite end-to-end tests are not implemented yet.

## Scope

- Bind only the SQLite operations Oreo needs: open/close, prepare/step/finalize, bind/read values, transactions, and errors.
- Build SQLite from a pinned official amalgamation. Oreo users will not need to install a system SQLite library or run a database server.
- Keep session tables, metadata indexes, and session queries in Oreo's store layer.
- Keep the API narrow. Add general-purpose features only when Oreo needs them.

## Verification

Tests will use the bundled SQLite engine, not a mock. Unit tests may use an in-memory database. End-to-end tests will create a temporary file-backed database, exercise the Oreo store, close and reopen the database, and verify that session metadata persists.

The exact build/test commands will be added after the Odin-to-C build integration is verified on Linux and macOS.

## References and attribution

The Odin binding design was informed by these community projects:

- [blob1807/odin_sqlite3_bindings](https://github.com/blob1807/odin_sqlite3_bindings)
- [saenai255/odin-sqlite3](https://github.com/saenai255/odin-sqlite3)

They are references, not source dependencies; the initial Oreo binding will be written fresh and will not copy their implementation. SQLite's official source is [dedicated to the public domain](https://sqlite.org/copyright.html). Keep the notices distributed with the selected SQLite release.
