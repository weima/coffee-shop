# Oreo Architecture

Oreo is a small, standalone Odin agent harness. It starts as its own package in this repository, exposes a library API for Coffee Shop, and should be extractable into an independent repository.

Pi is a behavioral reference only. Oreo independently implements its auth, agent loop, and tools in Odin; it has no Pi code, runtime, executable, credential-store, or plugin dependency.

Oreo calls provider-owned endpoints directly and does not host a public OAuth service. Pi reference sources are listed in [Oreo's README](README.md#reference-implementation).

## System boundary

![Oreo system architecture, including Oreo the American Shorthair mascot](assets/architecture-diagram.svg)

[PNG preview](assets/architecture-diagram.png) · [Open the self-contained HTML diagram](assets/architecture-diagram.html).

Oreo is a long-lived in-process host. A session represents one top-level task or working context—for example, Coffee Shop work and Odin-book work use separate sessions. Each session can submit many subtask work items to a shared native thread pool; pool threads are reusable workers, not sessions. The user's typical example is 5 task sessions with about 5 concurrent work items each (about 25 worker jobs). The stretch target is to accept and retain 1,000 queued work items; there is no requirement to run 1,000 threads at once. When work needs a user decision, pause it, retain its context in memory, release its worker, and resume after the caller responds.

## Session configuration and accounts

- Keep work and personal subscription credentials side by side in Oreo's own credential store; logging into one must not overwrite the other.
- A session represents one task and does not select a work or personal account. Account resolution belongs to provider configuration/authentication and remains to be specified.
- Every work item must use a specific provider, model, and thinking level. The selected values must be explicit when it is dispatched; workers must not rely on settings left by a previous job.
- To avoid copying repeated strings into work items, recommended: store immutable provider/model/thinking profiles once in a shared registry and put a compact profile ID on each work item. This is a proposed representation, not a selected database/library.
- Store defaults in `~/.oreo/config.json`; JSON is a practical format supported by Odin's `core:encoding/json`, not a format mandated by Odin. How defaults, task-session values, and work-item choices resolve remains open.
- The default account per provider and the config schema remain open decisions.

## Responsibilities

| Oreo owns | Its consumer owns |
|---|---|
| In-memory task sessions and a shared worker pool for ready work | Top-level task decomposition and which sessions to create |
| Provider login, token refresh, and model requests | Repository/worktree setup and cleanup |
| Pi-compatible agent-loop and built-in tool behavior | Receiving events and supplying requested user input |
| `read`, `write`, and `execute` tools and Oreo's credential storage | Machine-wide resource policy; pool configuration contract is still open |

Oreo coordinates execution of submitted subtask work items through its shared pool; it does not decide the top-level task decomposition or manage worktrees. Each queued work item carries its own resolved provider/model/thinking settings. Use a bounded worker count and retain at least 1,000 queued work items; worker count and overload behavior remain implementation details to benchmark.

## Session state, lifecycle, and events

- A session is created for one top-level task. The library exposes `close(session)`; the host's main thread receives `/quit` from the user and calls it.
- Closing a session prevents new work and cancels all its queued and active work items. Cancellation is cooperative: active work stops and returns its OS thread to the pool; Oreo does not destroy pool threads. Release in-memory working copies after active workers stop, but preserve the database history for later retrieval.
- When a work item needs a user decision, Oreo emits a `Needs_Input` event identifying the session and work item, pauses the work, retains its context in memory, and releases the worker. The caller's response resumes that work item through the pool.
- A final result completes a work item or turn, not necessarily its parent session. The caller also receives occasional progress updates.
- Work queue submissions return a clear `Queue_Full` result when capacity is reached. The queue must retain at least 1,000 pending work items. Work items also have a TTL; whether it applies to queue wait, execution time, or session idleness remains open. Expiry must not silently erase persisted session history.
- Exact event/API shapes, cancellation delivery, and host shutdown behavior remain to be defined.

## Structured context storage and database candidates

- Persist session and work-item context in a structured database, not loose ad-hoc files. Completed and closed session history must remain findable after process restart.
- `~/.oreo/sessions.db` is an acceptable database path. Use file-backed persistence by default; an in-memory mode may be useful for tests or explicitly temporary sessions, but cannot satisfy restart retrieval.
- Store sessions, work items, ordered conversation/tool records, lifecycle state, expiry timestamps, and provider-setting profiles with stable IDs. Work items refer to profile IDs rather than copying provider/model/thinking strings. The shared profile contains those values once.
- While running, workers may cache current context in memory; the database remains the durable source of truth. On user-input pause, persist continuation state before releasing the worker. On close, mark/cancel work but retain its history.
- V1 retrieval is by session metadata; full-text search over conversations/tool output is out of scope. Define the exact metadata fields and indexes with the schema. Job TTL may expire pending execution, but must not delete session history by default. Whether crashed in-progress jobs resume automatically remains open.

| Candidate | Strengths | Costs / fit |
|---|---|---|
| [SQLite](https://github.com/sqlite/sqlite) | SQL tables, transactions, indexes, and optional full-text search suit structured history and retrieval. File-backed and in-memory modes. | Selected for Oreo. Use a file-backed database by default; verify the Odin binding, build/link path, and multi-thread connection policy. |
| [UnQLite](https://github.com/symisc/unqlite) | Embedded C database; persistent and `:mem:` modes; KV and JSON/document APIs; optional thread support; BSD-2-Clause license. | No Odin binding found. KV/document APIs mean Oreo likely owns secondary indexes and more query behavior; compile with thread support and handle write contention. |
| [LMDB](https://github.com/LMDB/lmdb/tree/mdb.master3/libraries/liblmdb) | Compact, transactional, memory-mapped KV store; concurrent readers and one writer; OpenLDAP Public License. | No Odin binding found; persistent-file design and low-level API require Oreo-owned encoding, indexes, and query semantics; writes serialize. |

**Decision:** use SQLite with the persistent database at `~/.oreo/sessions.db`; in-memory mode is for tests or explicitly temporary use. V1 retrieval is by session metadata, not full-text search. Bundle the official SQLite amalgamation so Oreo users do not need to install a system SQLite library. Write a fresh minimal Odin binding over SQLite's C API; the session store owns schema and queries. The detailed package design and test gates are in [`src/sqlite/architecture.md`](src/sqlite/architecture.md) and [`src/sqlite/PLAN.md`](src/sqlite/PLAN.md).
## Providers and authentication

Oreo independently implements the provider-specific flows in Odin, following Pi's flow behavior while calling provider-owned endpoints with client registration authorized for Oreo. Do not assume Pi's client IDs are reusable:

- **OpenAI Codex:** subscription OAuth with PKCE. Browser login uses a temporary callback listener bound to `127.0.0.1`; the user has approved a loopback redirect URI. Codex device-code login is the headless path, subject to provider support and Oreo's client registration.
- **GitHub Copilot:** subscription login through GitHub's device-code flow, followed by the Copilot token exchange.
- **Expiry and manual login:** refresh tokens when possible. For login or re-login, Oreo should expose a copyable URL for the user to open manually and report the resulting authentication state to its caller. The exact provider-specific challenge fields and handoff remain to be specified.

Live auth implementation is deferred until the provider-neutral core is in place. Provider authorization, client registration, endpoint support, and model/API capabilities remain release gates.

These are provider-specific flows, not one generic OAuth implementation. Do not assume undocumented provider endpoints are reusable. There is no public Oreo OAuth endpoint. The loopback listener exists only during Codex browser login and closes when the flow ends.

Store credentials in Oreo's separate `~/.oreo/auth.json` with owner-only permissions. It must retain both work and personal accounts. Never log tokens or authorization headers. Reference source links are in [Oreo's README](README.md#reference-implementation).

### Authentication sequence

![Oreo authentication sequence](assets/auth-flow.svg)

[PNG preview](assets/auth-flow.png) · [Open the self-contained HTML diagram](assets/auth-flow.html).

The sequence is a design sketch. Confirm Oreo's provider client registrations and endpoint support before implementation.

## Tools

Oreo starts with three tools:

| Tool | Responsibility |
|---|---|
| `read` | Read a file from the caller's working context. |
| `write` | Create or replace a file in that context. |
| `execute` | Run a requested command and return its result to the model. |

`execute` is Oreo's name for the command tool corresponding to Pi's `bash` tool; it does not imply a security sandbox. Unless the consumer supplies an operating-system boundary, tool actions have the permissions of the Oreo process. The three tools follow Pi's observable behavior and contracts, implemented independently; their exact schemas and output handling must be checked against the reference before coding.

## Concurrency references and package boundaries

- Odin source belongs under `oreo/src/`; package-owned art and diagrams belong under `oreo/assets/`. The mascot is Oreo, the American Shorthair cat.
- Oreo is an Odin package/library first, not a wrapper around provider command-line processes. Many in-memory task sessions share one long-lived host process; each session may have many concurrent pool work items.
- Provider clients and OAuth flows are implemented in Oreo after the provider-neutral core is established.
- Coffee Shop may call Oreo as a library but retains responsibility for task decomposition, worktrees, and durable task state. Oreo owns scheduling ready session work on its bounded worker pool.
- **Worker-pool reference:** Odin's `core:thread.Pool` is the simplest starting point for a fixed native worker pool. Its task queue is unbounded and completed tasks remain stored until collected, so verify backpressure and lifecycle needs before adopting it directly.
- **Bounded-queue alternative:** use fixed `core:thread` workers consuming typed `Work_Item` messages from a buffered `core:sync/chan.Chan(Work_Item)`. Size the queue for at least 1,000 pending jobs and define behavior beyond that capacity; this provides backpressure without an external dependency.
- **Pub/sub distinction:** `core:sync/chan` is a thread-safe multi-producer/multi-consumer channel, not broadcast; each message is consumed by one receiver. For caller events, use a per-session/per-caller output channel, or a dispatcher that fans out to separate subscriber queues when multiple subscribers need every event. Keep `Needs_Input` lossless; progress may be coalesced.
- **Work-item payload:** include session ID, work-item ID, provider, model, thinking level, and task input/context. Pool workers are reused, so provider settings belong on each work item, not in persistent worker-thread state.
- **Initial recommendation:** use only in-process Odin primitives. NATS, RabbitMQ, or Redis add a separate service and are unnecessary unless Oreo later needs cross-process/machine delivery or durable queues. Exact queue/event design remains proposed until the core contract is approved.
- Work waiting for user input is suspended in memory and releases its worker; the caller's response schedules that work item again. Closing a session cancels its child jobs cooperatively so OS threads return to the pool. Blocking provider I/O may still occupy a worker and must be included in scale tests.
- Initial platform targets are Linux (including WSL) and macOS. Windows is out of scope.
- No plugin system in the initial design. Add extension mechanisms only if a real consumer need justifies their API, lifecycle, loading, and security complexity.
- Additional tools or providers are added only when a consumer needs them.
