# Oreo SQLite Binding Design

## Decision

Create a fresh, minimal Odin SQLite binding inside Oreo at `oreo/src/sqlite/`. Bundle the official SQLite amalgamation so Oreo users do not need to install a system SQLite library. The session store—not the binding—owns session tables, indexes, and SQL queries.

## Boundaries

The binding exposes only connection/statement lifecycle, parameter binding, result access, transactions, and errors. It is not an ORM and does not promise broad SQLite API coverage. The bundled SQLite version, checksum, build options, and notices will be pinned and recorded after a Linux/macOS build spike confirms the Odin/C integration.

The two existing Odin bindings—[blob1807/odin_sqlite3_bindings](https://github.com/blob1807/odin_sqlite3_bindings) and [saenai255/odin-sqlite3](https://github.com/saenai255/odin-sqlite3)—are credited as design references. Their implementation code will not be copied in the initial package. SQLite's official source is public domain; preserve the notices accompanying the selected release.

## Verification

Tests must use the real bundled SQLite engine. Binding tests may use an in-memory database. Store end-to-end tests use an isolated temporary file-backed database, exercise metadata writes/queries, close and reopen the database, and verify persistence. They must not modify a developer's normal Oreo database.

The subproject's README, architecture, plan, and roadmap are maintained in `oreo/src/sqlite/` and define the detailed package contract and delivery slices.
