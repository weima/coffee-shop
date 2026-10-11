# Oreo Implementation Plan

Build Oreo as an independent Odin agent harness in `oreo/`, with source in `oreo/src/` and package assets in `oreo/assets/`. This plan follows the confirmed requirements in [Architecture](architecture.md); that document is the design source of truth.

Oreo's first milestone is a provider-neutral, long-lived in-process host for task sessions, each of which can submit many work items to a shared thread pool. Live provider authentication comes later, through pi's auth and model layer. Oreo ships as a pi extension and depends on the pi runtime (2026-10-10 decision; see [architecture](architecture.md#runtime-decision-2026-10-10)). The agent loop stays in Odin; a thin pi extension bridges the host to pi's model and auth layer (proposed, pending the spike; see [second-round decisions](architecture.md#decisions-2026-10-10-second-round)). Its provider-neutral structure stays inside Oreo.

## Delivery slices

| Slice | Result | Gate |
|---|---|---|
| 0. Finalize the core contract | Turn the confirmed lifecycle and persistence requirements into a small public API and test cases. | API shape and implementation defaults are documented; no remaining user decision blocks the provider-neutral core. |
| 1. Build the provider-neutral core | Odin package, per-task session state, structured database storage, shared worker-pool integration, explicit provider/model/thinking settings on each work item, event/input handoff, config loading, and fake provider. | `odin check` and offline tests pass on Linux and macOS; sessions pause/resume and their stored context remains queryable after close and process restart. |
| 2. Match Pi's agent loop and tools | Independently implement the agreed agent-loop defaults and `read`, `write`, and `execute` behavior. | Tests cover turn/tool-call behavior, progress/final results, external-input pause/resume, and tool failures against verified Pi reference contracts. |
| 3. Verify provider contracts | Record provider contracts for Codex and GitHub Copilot, the first providers to test. Oreo registers no client (2026-10-10). Other providers come from pi's ecosystem (second round, item 5). | Provider-specific contracts are documented. No Pi client IDs or undocumented endpoints are assumed reusable. |
| 4. Add provider auth and requests | Use pi's auth and model layer through the bridge (proposed, pending the spike); no Oreo OAuth flow. | An approved smoke test through pi's login confirms each provider; automated tests use no live credentials. |
| 5. Measure worker scale | Exercise normal and stress workloads with the worker pool and event delivery. | Record throughput, queue behavior, worker count, and memory for about 25 concurrent work items and at least 1,000 queued/retained work items; no target is set for simultaneously active threads. |
| 6. Integrate with Coffee Shop | Consume Oreo through its public boundary (the pi extension for now; library delivery is later, second round item 1) while Coffee Shop retains task decomposition, worktrees, and durable task state. Provider access goes through pi (2026-10-10), which supersedes the earlier direct Copilot route. | Fake-provider end-to-end tests pass; adoption does not require an external agent CLI process per session. |
| 7. Prepare extraction | Make package paths, build instructions, notices, and tests independent of Coffee Shop-specific code. | Oreo builds and tests from its own repository and Coffee Shop consumes only the public API. |

## Current progress

- The SQLite amalgamation and binding are implemented; the store applies source-controlled schema migrations in version order, persists/retrieves metadata and ordered records, validates work-item transitions, and coordinates session-close cancellation.
- `cd oreo && just test` passes nine binding tests and eight store tests against bundled SQLite on macOS. Linux verification and worker execution remain pending.
- The full Coffee Shop test suite passes after extending an E2E activity readiness window for parallel test load. The provider-neutral host, worker pool, and task lifecycle are the next implementation slices.
- **Next session** (2026-10-10 runtime decision; the GitHub OAuth App step is dropped):
  1. Bridge spike (proposed, second round item 2): a pi extension bridges the Odin host to pi's model and auth layer, with the planned transport as JSON lines over a local pipe. Validate that the host gets model access without credentials leaving pi, and record the process model.
  2. Resource spike: how many `createAgentSession` sessions fit in one pi process, whether they reuse one login, and their memory and CPU cost. Measure before the plan depends on it.
  3. Provider terms: accepted by developer, not verified (second round, item 3). The check against the provider terms has not been done. Whether it is still required before public release is an open question.
  4. Delivery is decided: pi extension for now; library and executable delivery are later (second round, item 1).
  5. Auth slice: a smoke test through pi's login, then one model request per provider. Codex and GitHub Copilot are the first providers to test. Codex was tabled earlier; its status now needs confirmation.

## Confirmed requirements

- **Providers:** the provider list comes from pi's ecosystem; it is no longer limited to Codex and GitHub Copilot (second round, item 5). Codex and GitHub Copilot are the first providers to test, accessed through pi's auth and model layer. Live auth is a smoke test through pi's login. Provider terms are accepted by the developer but not verified (second round, item 3).
- **Runtime:** one long-lived Oreo host holds in-memory task sessions. Each task gets its own session; one session can submit many work items to a shared thread pool.
- **Scale:** the typical example is 5 task sessions with about 5 concurrent work items each (about 25 worker jobs). The stretch target is at least 1,000 queued/retained work items; there is no requirement for 1,000 active threads.
- **Scheduling:** Oreo uses a shared thread pool for work items; task decomposition remains with the consumer. User-input waits persist context, pause work, release the worker, and resume after the caller responds.
- **Provider settings:** each work item must carry explicit provider, model, and thinking-level settings. An internal profile ID may deduplicate those values, but must not make them implicit. Defaults belong in `~/.oreo/config.json`; Odin's `core:encoding/json` is suitable.
- **Session lifetime:** the library exposes `close(session)`. The host's main thread receives `/quit` and calls it. Closing a session cooperatively cancels queued/active work so workers return to the pool, while preserving history.
- **Context and queue:** persist structured session/work-item context in SQLite at `~/.oreo/sessions.db`; bundle SQLite source so users need no system installation. Context remains findable after close/restart. Retain at least 1,000 queued work items and return `Queue_Full` at capacity. V1 lookup is by metadata, not full text. The v1 tables and indexes are defined in [the database schema](schema.md). End-to-end tests use the real bundled engine and a temporary file-backed database.
- **Events:** emit external-input, progress, and final-result events. Their exact Odin payloads are implementation details for the core slice, not a pending user decision.
- **Behavior:** mirror Pi's relevant agent-loop defaults and behavior, and match its `read`, `write`, and `execute` tool behavior. Pi is a runtime dependency since 2026-10-10 (Oreo ships as a pi extension). It also remains the reference for agent-loop and tool behavior, and the agent loop stays in Odin (second round, item 2).
- **Login UX:** login goes through pi (2026-10-10). Whether pi's login offers a copyable URL is to be confirmed in the smoke test; the earlier Oreo design exposed one.
- **Platforms:** Linux, including WSL, and macOS are initial targets. Windows is out of scope.
- **Accounts:** resolved (second round, item 6). The developer authorizes work and personal accounts in pi and chooses provider, model, and thinking level for each session. Oreo does the same per session. pi holds the logins; Oreo implements no OAuth flow and registers no client ID. The earlier personal import exception is superseded ([record](architecture.md#personal-import-exception)).

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

### Provider-auth gate

- Oreo registers no client (2026-10-10). Provider terms: accepted by developer, not verified (second round, item 3). Whether an extension of pi falls under pi's provider registration has never been checked against the provider terms. Whether that check is still required before public release is an open question. Personal use is not affected.
- During the auth slice, settle default-account selection. Credential-file updates are pi's, not Oreo's (2026-10-10). These do not block the provider-neutral core or SQLite binding. Also settle whether a session chooses its work or personal account (second round, item 6).

## Explicit exclusions

- No dependency on pi session files. Pi is a runtime dependency since 2026-10-10, which supersedes the earlier "no Pi package, executable, or credential-store dependency".
- No separate Oreo process per session.
- No task decomposition, worktree management, plugin system, or extra initial tool set.
- No Windows target and no live credentials in automated tests.
