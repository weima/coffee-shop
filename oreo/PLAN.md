# Oreo Implementation Plan

**Why Oreo exists.** pi is very capable, but it's too heavy for parallel jobs. So we want to fire up light-weight oreo to do what pi does. Oreo runs light-weight agents that do what pi does, in parallel. It is a pi extension and uses pi's runtime and login.

Success is many concurrent jobs at much lower memory and CPU than one pi process per job; threshold to be set from the spike measurements.

Build Oreo as an independent Odin agent harness in `oreo/`, with source in `oreo/src/` and package assets in `oreo/assets/`. This plan follows the confirmed requirements in [Architecture](architecture.md); that document is the design source of truth.

Oreo's first milestone is a provider-neutral, long-lived host for task sessions, run as a separate OS process started by the pi extension (third round, A3). Each session can submit many work items to a shared thread pool. Provider login stays in pi; Oreo does no auth work (fourth round, F2). Oreo ships as a pi extension and depends on the pi runtime (2026-10-10 decision; see [architecture](architecture.md#runtime-decision-2026-10-10)). The agent loop and the `read`, `write`, and `execute` tools run in Odin (third round, A4); a thin pi extension bridges the host to pi's model layer (confirmed 2026-10-11; [bridge spec](bridge.md)). Its provider-neutral structure stays inside Oreo.

## Delivery slices

| Slice | Result | Gate |
|---|---|---|
| 0. Finalize the core contract | Turn the confirmed lifecycle and persistence requirements into a small public API and test cases. | API shape and implementation defaults are documented; no remaining user decision blocks the provider-neutral core. |
| 1. Build the provider-neutral core | Odin package, per-task session state, structured database storage, shared worker-pool integration, explicit provider/model/thinking settings on each work item (given as an instruction in its prompt, A2), event/input handoff, config loading (Oreo reads its own `~/.oreo/config.json`, 2026-10-11), and fake provider. | `odin check` and offline tests pass on Linux and macOS; sessions pause/resume and their stored context remains queryable after close and process restart. |
| 2. Match Pi's agent loop and tools | Independently implement the agreed agent-loop defaults and `read`, `write`, and `execute` behavior. The loop and the three tools run in Odin (A4). | Tests cover turn/tool-call behavior, progress/final results, external-input pause/resume, and tool failures against verified Pi reference contracts. |
| 3. Verify provider contracts | Record provider contracts for Codex and GitHub Copilot, the first providers to test. Auth details are reference only (third round, A6; fourth round, F2): not an Oreo task. Oreo registers no client (2026-10-10). Other providers come from pi's ecosystem (second round, item 5). | Provider-specific contracts are documented. No Pi client IDs or undocumented endpoints are assumed reusable. |
| 4. Send model requests through pi | Send model requests through pi's model layer via the bridge ([spec](bridge.md)): the extension is spawned by pi and answers the host's `model_request` through `ctx.modelRegistry.complete`. The end user logs in to each provider in pi beforehand. Login, token handling, and client registration are pi's responsibility; Oreo performs none of them (third round, A2; fourth round, F2). | An approved smoke test of one model request per provider through pi confirms that the chosen provider, model, and thinking level are supported by the parent pi; automated tests use no live credentials. |
| 5. Measure worker scale | Exercise normal and stress workloads with the worker pool and event delivery. | Record throughput, queue behavior, worker count, and memory for about 25 concurrent work items and at least 1,000 queued/retained work items; no target is set for simultaneously active threads. |
| 6. Integrate with Coffee Shop | Consume Oreo through its public boundary (the pi extension for now; library delivery is later, second round item 1) while Coffee Shop retains task decomposition, worktrees, and durable task state. Provider access goes through pi (2026-10-10), which supersedes the earlier direct Copilot route. | Fake-provider end-to-end tests pass; adoption does not require an external agent CLI process per session. |
| 7. Prepare extraction | Make package paths, build instructions, notices, and tests independent of Coffee Shop-specific code. | Oreo builds and tests from its own repository and Coffee Shop consumes only the public API. |

## Current progress

- The SQLite amalgamation and binding are implemented; the store applies source-controlled schema migrations in version order, persists/retrieves metadata and ordered records, validates work-item transitions, and coordinates session-close cancellation.
- The provider-neutral core is implemented and merged (PRs #69 and #70): the session host over the store, the `~/.oreo/config.json` default provider/model/thinking, the `read`, `write`, and `execute` tools, a bounded worker pool with cooperative cancellation and `needs_input` pause/resume, the `needs_input`/`progress`/`final_result` events, the provider-neutral agent loop with a tool round-trip, profile resolution, the end-to-end runtime that runs a work item through the pool, and the JSON-lines host transport over stdin and stdout.
- `cd oreo && just test` passes 9 binding, 8 store, and 43 oreo tests against bundled SQLite on macOS, and the Coffee Shop suite passes 207 tests. Linux verification remains pending.
- **Next: the bridge** ([spec](bridge.md)). The pi extension under `extensions/oreo/` spawns the Odin host and answers its `model_request` lines through `ctx.modelRegistry.complete`, so credentials never leave pi. The Odin side adds `provider_remote`, a `Provider` implemented over the transport. The bridge spike is answered rather than assumed: pi's `ExtensionContext` exposes the model runtime (`docs/extensions.md:211-212`), which is what the plan was waiting on.
- Remaining after the bridge: the model smoke test, one real request on the chosen provider with the user already logged in to pi; then the v0.4 gate rerun with Oreo as the runtime.
- Still open: the resource spike (how many `createAgentSession` sessions fit in one pi process, and their memory and CPU cost); delivery stays a pi extension for now, with library and executable delivery later (second round, item 1); whether Codex stays a first test provider.
- **Thinking-enabled requests** (2026-10-11): untested for `forceAdaptiveThinking` models. The bridge spec leaves the default thinking level open and defers which store fields the request builder consumes ([spec](bridge.md), Open items).

## Confirmed requirements

- **Providers:** the provider list comes from pi's ecosystem; it is no longer limited to Codex and GitHub Copilot (second round, item 5). Codex and GitHub Copilot are the first providers to test, accessed through pi's auth and model layer. Live checks are one model request per provider through pi; Oreo does no auth work. No legal or provider-terms check (developer decision, 2026-10-10: Oreo is a pi plugin).
- **Runtime:** one long-lived Oreo host process holds in-memory task sessions. The pi extension starts it as a separate OS process (third round, A3). Each task gets its own session; one session can submit many work items to a shared thread pool.
- **Scale:** the typical example is 5 task sessions with about 5 concurrent work items each (about 25 worker jobs). The stretch target is at least 1,000 queued/retained work items; there is no requirement for 1,000 active threads.
- **Scheduling:** Oreo uses a shared thread pool for work items; task decomposition remains with the consumer. User-input waits persist context, pause work, release the worker, and resume after the caller responds.
- **Provider settings:** each work item must carry explicit provider, model, and thinking-level settings. An internal profile ID may deduplicate those values, but must not make them implicit. Defaults live in Oreo's own config file, `~/.oreo/config.json`, read by Oreo itself, with `OREO_CONFIG` overriding the path (developer decision, 2026-10-11; this settles the earlier A1 question about the Coffee Shop config file and the open relation to `~/.oreo/config.json`). The built-in default provider, model, and thinking level are used when the file is absent.
- **Session lifetime:** the library exposes `close(session)`. The host receives `/quit` relayed by the pi extension (proposed) and calls it. Closing a session cooperatively cancels queued/active work so workers return to the pool, while preserving history.
- **Context and queue:** persist structured session/work-item context in SQLite at `~/.oreo/sessions.db`; bundle SQLite source so users need no system installation. Context remains findable after close/restart. Retain at least 1,000 queued work items and return `Queue_Full` at capacity. V1 lookup is by metadata, not full text. The v1 tables and indexes are defined in [the database schema](schema.md). End-to-end tests use the real bundled engine and a temporary file-backed database.
- **Events:** emit external-input, progress, and final-result events. Their exact Odin payloads are implementation details for the core slice, not a pending user decision.
- **Behavior:** mirror Pi's relevant agent-loop defaults and behavior, and match its `read`, `write`, and `execute` tool behavior. Pi is a runtime dependency since 2026-10-10 (Oreo ships as a pi extension). It also remains the reference for agent-loop and tool behavior, and the agent loop stays in Odin (second round, item 2).
- **Login UX:** pi's responsibility (2026-10-10; fourth round, F2). Oreo exposes no login URL or login UI. The earlier Oreo design exposed a copyable URL; that is superseded.
- **Platforms:** Linux, including WSL, and macOS are initial targets. Windows is out of scope.
- **Accounts:** the end user chooses the default account in the Coffee Shop config, which also sets the default provider, model, and thinking level (third round, A1). Work and personal accounts are authorized in pi; pi holds the logins. Oreo implements no OAuth flow and registers no client ID. Whether a session also chooses its account is open (second round, item 6). The earlier personal import exception is superseded ([record](architecture.md#personal-import-exception)).
- **Work items:** each work item is given an instruction for its provider, model, and thinking level, which is part of its prompt. The chosen values must be supported by the parent pi, and the end user must have logged in to them in pi beforehand. Oreo does not perform login (third round, A2).
- **Host process:** the host is a separate OS process, started by the pi extension. Sessions run inside that one process (third round, A3).
- **Tools:** `read`, `write`, and `execute` run in Odin (third round, A4).
- **Model source:** model metadata is read from pi's live store (`~/.pi/agent/models-store.json`, key `github-copilot` for Copilot), read-only; Oreo uses no bundled static catalog (2026-10-11; [architecture](architecture.md#model-source-2026-10-11)).

## Implementation work and later gates

The requirements above are settled. The following are implementation tasks, not unanswered user decisions; choose conservative defaults and record them in the architecture as they are implemented.

### Provider-neutral core

- Define the event payloads and exact cancellation/shutdown API around the confirmed lifecycle: `Needs_Input`, progress, final result, and `close(session)`.
- Choose a conservative configurable worker count. The queue must retain at least 1,000 pending items and report `Queue_Full`; benchmark before tuning concurrency.
- Require explicit provider/model/thinking settings on submitted work items. If profiles are used internally, resolve them before dispatch.
- Derive the relevant agent-loop behavior from Pi's reference implementation and document the independent Oreo behavior.
- Build SQLite from a pinned official amalgamation and implement the fresh thin Odin binding. The store owns schema and SQL. Verify Linux/macOS build integration, metadata indexes, connection synchronization, and real file-backed end-to-end tests.
- **Schema evolution:** use SQLite `PRAGMA user_version` with ordered, source-controlled, one-version-at-a-time migrations. Treat the current v1 schema as the initial migration; apply pending migrations sequentially in transactions and update the version atomically. Reject databases newer than the binary supports, preserve user data, and do not add a Rails-style migration framework or destructive reset path in v1. Test upgrades from each supported prior-version fixture, data preservation, failure rollback, and reopen/idempotency.
- On restart, preserve all history and mark unfinished work interrupted; do not automatically repeat tool/provider actions in v1.
- Apply TTL to pending queue work; mark expired items but retain their context/history. Do not expire completed session history by default.

### Provider and account notes

- No legal or provider-terms check (developer decision, 2026-10-10: Oreo is a pi plugin). Superseded: the pre-release gate (third round, A5). Oreo registers no client and does no auth work (fourth round, F2).
- Default-account selection is settled by the end user's choice in the Coffee Shop config (third round, A1). Credential-file updates are pi's, not Oreo's (2026-10-10). These do not block the provider-neutral core or SQLite binding. Still open: whether a session chooses its work or personal account (second round, item 6).

## Explicit exclusions

- No dependency on pi session files. Pi is a runtime dependency since 2026-10-10, which supersedes the earlier "no Pi package, executable, or credential-store dependency".
- No separate Oreo process per session.
- No task decomposition, worktree management, plugin system, or extra initial tool set.
- No Windows target and no live credentials in automated tests.
- No login, OAuth flow, token handling, or client registration in Oreo; these are pi's responsibility (fourth round, F2).
