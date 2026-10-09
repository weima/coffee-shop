# SQLite Binding Implementation Plan

The binding is a narrow, first-party package under `oreo/src/sqlite`. The session store remains the owner of Oreo's tables and queries. The full Oreo plan is in [`oreo/PLAN.md`](../../PLAN.md).

## Slices

| Slice | Work | Acceptance gate |
|---|---|---|
| 0. Build spike | Select and pin an official SQLite amalgamation release; prove Odin can compile/link it on Linux and macOS; open/close both memory and temporary file databases. | Reproducible local build with no system SQLite library; source URL, version, checksum, and notices recorded. |
| 1. Minimal binding | Add connection and statement handles, prepare/step/finalize, value binding and extraction, transaction controls, and error reporting. | Focused tests pass against the real SQLite engine; no copied Odin-binding code; ownership and cleanup are verified. |
| 2. Store integration | Let Oreo's store create and own session/work-item tables and metadata indexes using the binding. | Store end-to-end tests insert and retrieve metadata through the store, then close/reopen the file and verify persistence. |
| 3. Platform hardening | Run the binding and store tests on Linux and macOS; verify C compiler/linker prerequisites and pinned build options. | Both targets pass the same real-SQLite test suite and document exact setup commands. |

## Test requirements

- Use the bundled engine; do not mock SQLite.
- Use an in-memory database for isolated binding tests where persistence is not under test.
- Use a temporary file-backed database for persistence and store end-to-end tests; never modify a developer's `~/.oreo/sessions.db` during tests.
- Cover invalid SQL, bind/type errors, transaction rollback, and cleanup on partial failure.
- Keep tests deterministic and remove only the temporary database files they create.

## Deferred

- Full SQLite API coverage, ORM/query builder, reflection mapping, FTS, connection pooling, and cross-process coordination.
- Performance optimization beyond verifying that expected Oreo queue/session workloads are practical.
