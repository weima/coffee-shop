# Oreo Implementation Plan

Build Oreo as an independent Odin agent harness in `oreo/`, with source in `oreo/src/` and package assets in `oreo/assets/`. This plan follows the confirmed requirements in [Architecture](architecture.md); that document is the design source of truth.

Oreo's first milestone is a provider-neutral, long-lived in-process host for task sessions, each of which can submit many work items to a shared thread pool. Live provider authentication comes later. Pi is a behavioral reference only; Oreo has no Pi runtime or credential dependency.

## Delivery slices

| Slice | Result | Gate |
|---|---|---|
| 0. Define the core contract | Public session lifecycle, config defaults, caller events, pool ownership, cancellation, and supported platforms are specified. | Open decisions affecting the public API are resolved; testable core acceptance criteria are recorded. |
| 1. Build the provider-neutral core | Odin package, per-task session state, shared worker-pool integration, explicit provider/model/thinking settings on each work item, event/input handoff, config loading, and fake provider. | `odin check` and offline tests pass on Linux and macOS; separate task sessions can schedule work, pause for input, resume, return results, and close using the agreed worker-wait policy. |
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
- **Scheduling:** Oreo uses a thread pool to manage work items; task decomposition remains with the consumer. User-decision waits pause the affected work; whether that releases its worker is an implementation detail to confirm.
- **Provider settings:** every dispatched work item receives explicit provider, model, and thinking-level values. How these inherit from session/config defaults or override them per work item remains open. Account choice is not a session setting. Defaults belong in `~/.oreo/config.json`; Odin's `core:encoding/json` makes JSON suitable.
- **Session lifetime:** a session remains open across turns until `/quit` or caller closure. Exact CLI-versus-library representation of `/quit` remains open.
- **Events:** emit an event when the agent needs an external decision, plus occasional progress updates and final results. The event and resume API shape remains open.
- **Behavior:** mirror Pi's relevant agent-loop defaults and behavior, and match its `read`, `write`, and `execute` tool behavior. Pi remains a reference, never a runtime dependency.
- **Login UX:** expose a copyable URL so the user can authenticate manually. Provider-specific challenge details remain subject to contract verification.
- **Platforms:** Linux, including WSL, and macOS are initial targets. Windows is out of scope.
- **Accounts:** keep work and personal credentials side by side in Oreo-owned storage; never share Pi credentials.

## Open decisions and gates

- Define the public session/event contract, including caller replies, cancellation, shutdown, and whether `/quit` is CLI input or an API operation.
- Confirm that a session awaiting user input releases its worker and resumes through the pool when the caller replies; this is the recommended interpretation of the pause requirement.
- Define how the default account is selected per provider, without adding account selection to the session settings.
- Define worker-count configuration and behavior above the queue's 1,000-item target; benchmark memory, throughput, and backpressure. Active worker count is an implementation choice, not a 1,000-thread requirement.
- Define how provider/model/thinking defaults flow from global config to task session to individual work item, and which levels may override them.
- Verify which Pi loop defaults and behaviors are in scope; document the selected behavior rather than importing Pi configuration.
- Before live auth, verify provider authorization, Oreo-owned client registrations, redirects, scopes, endpoints, and model/API capabilities.
- Define credential-file update/locking and the exact login/re-login event payload before implementing auth.

## Explicit exclusions

- No Pi package, executable, session file, or credential-store dependency.
- No separate Oreo process per session.
- No task decomposition, worktree management, plugin system, or extra initial tool set.
- No Windows target and no live credentials in automated tests.
