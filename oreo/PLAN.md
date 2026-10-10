# Oreo Implementation Plan

Build Oreo as an independent Odin agent harness in `oreo/`, with source in `oreo/src/` and package assets in `oreo/assets/`. This plan follows the confirmed requirements in [Architecture](architecture.md); that document is the design source of truth.

Oreo's first milestone is a provider-neutral, long-lived in-process host for task sessions, each of which can submit many work items to a shared thread pool. Live provider authentication comes later. Pi is a behavioral reference only; Oreo has no Pi runtime or credential dependency.

## Delivery slices

| Slice | Result | Gate |
|---|---|---|
| 0. Finalize the core contract | Turn the confirmed lifecycle and persistence requirements into a small public API and test cases. | API shape and implementation defaults are documented; no remaining user decision blocks the provider-neutral core. |
| 1. Build the provider-neutral core | Odin package, per-task session state, structured database storage, shared worker-pool integration, explicit provider/model/thinking settings on each work item, event/input handoff, config loading, and fake provider. | `odin check` and offline tests pass on Linux and macOS; sessions pause/resume and their stored context remains queryable after close and process restart. |
| 2. Match Pi's agent loop and tools | Independently implement the agreed agent-loop defaults and `read`, `write`, and `execute` behavior. | Tests cover turn/tool-call behavior, progress/final results, external-input pause/resume, and tool failures against verified Pi reference contracts. |
| 3. Verify provider contracts | Confirm authorized Oreo client registrations, redirects, scopes, endpoints, and model/API capabilities for Codex and GitHub Copilot. | Provider-specific contracts are documented. No Pi client IDs or undocumented endpoints are assumed reusable. |
| 4. Add provider auth and requests | Implement login/re-login handoff, credential storage, refresh, provider requests, streaming/tool-call parsing, and normalized errors. | Fake-server tests cover success and failure paths without live credentials; approved manual smoke tests confirm each provider. |
| 5. Measure worker scale | Exercise normal and stress workloads with the worker pool and event delivery. | Record throughput, queue behavior, worker count, and memory for about 25 concurrent work items and at least 1,000 queued/retained work items; no target is set for simultaneously active threads. |
| 6. Integrate with Coffee Shop | Consume Oreo through its library boundary while Coffee Shop retains task decomposition, worktrees, and durable task state. | Fake-provider end-to-end tests pass; adoption does not require an external agent CLI process per session. |
| 7. Prepare extraction | Make package paths, build instructions, notices, and tests independent of Coffee Shop-specific code. | Oreo builds and tests from its own repository and Coffee Shop consumes only the public API. |

## Confirmed requirements

- **Providers:** Codex and GitHub Copilot are first. Implement the provider-neutral core before live auth; live auth remains gated on authorized client/API contracts.
- **Runtime:** one long-lived Oreo host holds in-memory task sessions. Each task gets its own session; one session can submit many work items to a shared thread pool.
- **Scale:** the typical example is 5 task sessions with about 5 concurrent work items each (about 25 worker jobs). The stretch target is at least 1,000 queued/retained work items; there is no requirement for 1,000 active threads.
- **Scheduling:** Oreo uses a shared thread pool for work items; task decomposition remains with the consumer. User-input waits persist context, pause work, release the worker, and resume after the caller responds.
- **Provider settings:** each work item must carry explicit provider, model, and thinking-level settings. An internal profile ID may deduplicate those values, but must not make them implicit. Defaults belong in `~/.oreo/config.json`; Odin's `core:encoding/json` is suitable.
- **Session lifetime:** the library exposes `close(session)`. The host's main thread receives `/quit` and calls it. Closing a session cooperatively cancels queued/active work so workers return to the pool, while preserving history.
- **Context and queue:** persist structured session/work-item context in SQLite at `~/.oreo/sessions.db`; bundle SQLite source so users need no system installation. Context remains findable after close/restart. Retain at least 1,000 queued work items and return `Queue_Full` at capacity. V1 lookup is by metadata, not full text. The v1 tables and indexes are defined in [the database schema](schema.md). End-to-end tests use the real bundled engine and a temporary file-backed database.
- **Events:** emit external-input, progress, and final-result events. Their exact Odin payloads are implementation details for the core slice, not a pending user decision.
- **Behavior:** mirror Pi's relevant agent-loop defaults and behavior, and match its `read`, `write`, and `execute` tool behavior. Pi remains a reference, never a runtime dependency.
- **Login UX:** expose a copyable URL so the user can authenticate manually. Provider-specific challenge details remain subject to contract verification.
- **Platforms:** Linux, including WSL, and macOS are initial targets. Windows is out of scope.
- **Accounts:** keep work and personal credentials side by side in Oreo-owned storage; never share Pi credentials.

## Implementation work and later gates

The requirements above are settled. The following are implementation tasks, not unanswered user decisions; choose conservative defaults and record them in the architecture as they are implemented.

### Provider-neutral core

- Define the event payloads and exact cancellation/shutdown API around the confirmed lifecycle: `Needs_Input`, progress, final result, and `close(session)`.
- Choose a conservative configurable worker count. The queue must retain at least 1,000 pending items and report `Queue_Full`; benchmark before tuning concurrency.
- Require explicit provider/model/thinking settings on submitted work items. If profiles are used internally, resolve them before dispatch.
- Derive the relevant agent-loop behavior from Pi's reference implementation and document the independent Oreo behavior.
- Build SQLite from a pinned official amalgamation and implement the fresh thin Odin binding. The store owns schema and SQL. Verify Linux/macOS build integration, metadata indexes, connection synchronization, and real file-backed end-to-end tests.
- On restart, preserve all history and mark unfinished work interrupted; do not automatically repeat tool/provider actions in v1.
- Apply TTL to pending queue work; mark expired items but retain their context/history. Do not expire completed session history by default.

### Provider-auth gate

- Before live auth, verify authorized Oreo client registrations, redirects, scopes, endpoints, and model/API capabilities for Codex and GitHub Copilot.
- During the auth slice, settle default-account selection and implement safe credential-file updates. These do not block the provider-neutral core or SQLite binding.

## Explicit exclusions

- No Pi package, executable, session file, or credential-store dependency.
- No separate Oreo process per session.
- No task decomposition, worktree management, plugin system, or extra initial tool set.
- No Windows target and no live credentials in automated tests.
