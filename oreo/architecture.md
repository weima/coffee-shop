# Oreo Architecture

Oreo is a small, standalone Odin agent harness. It starts as its own package in this repository, exposes a library API for Coffee Shop, and should be extractable into an independent repository.

Pi is a behavioral reference only. Oreo independently implements its auth, agent loop, and tools in Odin; it has no Pi code, runtime, executable, credential-store, or plugin dependency.

Oreo calls provider-owned endpoints directly and does not host a public OAuth service. Pi reference sources are listed in [Oreo's README](README.md#reference-implementation).

## System boundary

![Oreo system architecture, including Oreo the American Shorthair mascot](assets/architecture-diagram.svg)

[PNG preview](assets/architecture-diagram.png) · [Open the self-contained HTML diagram](assets/architecture-diagram.html).

Oreo is a long-lived in-process host. A session represents one top-level task or working context—for example, Coffee Shop work and Odin-book work use separate sessions. Each session can submit many subtask work items to a shared native thread pool; pool threads are reusable workers, not sessions. The user's typical example is 5 task sessions with about 5 concurrent work items each (about 25 worker jobs). The stretch target is to accept and retain 1,000 queued work items; there is no requirement to run 1,000 threads at once. The user-input wait pauses the affected work; the recommendation is to keep its state in memory and release the worker. Confirm that scheduling detail in the core API design.

## Session configuration and accounts

- Keep work and personal subscription credentials side by side in Oreo's own credential store; logging into one must not overwrite the other.
- A session represents one task and does not select a work or personal account. Account resolution belongs to provider configuration/authentication and remains to be specified.
- Every work item dispatched to a pool worker must carry explicit provider, model, and thinking-level settings so a reused worker knows how to contact the provider. Resolve these from `~/.oreo/config.json`, the parent session, or a per-work-item override; precedence remains open.
- Store defaults in `~/.oreo/config.json`; JSON is a practical format supported by Odin's `core:encoding/json`, not a format mandated by Odin.
- The default account per provider and the config schema remain open decisions.

## Responsibilities

| Oreo owns | Its consumer owns |
|---|---|
| In-memory task sessions and a shared worker pool for ready work | Top-level task decomposition and which sessions to create |
| Provider login, token refresh, and model requests | Repository/worktree setup and cleanup |
| Pi-compatible agent-loop and built-in tool behavior | Receiving events and supplying requested user input |
| `read`, `write`, and `execute` tools and Oreo's credential storage | Machine-wide resource policy; pool configuration contract is still open |

Oreo coordinates execution of submitted subtask work items through its shared pool; it does not decide the top-level task decomposition or manage worktrees. Each queued work item carries its own resolved provider/model/thinking settings. Use a bounded worker count and retain at least 1,000 queued work items; worker count and overload behavior remain implementation details to benchmark.

## Session flow and events

1. The consumer creates a session for a top-level task; it remains open across turns until `/quit` or caller closure.
2. The session submits subtask work items. Before a worker runs one, Oreo resolves and passes explicit provider/model/thinking settings with that work item; the worker does not rely on stale thread-local provider configuration.
3. A final answer completes a work item or turn, not necessarily the parent session.
4. When an agent needs a user decision, Oreo emits a `Needs_Input` event identifying the session and work item, then pauses that work. Recommended: release the worker while waiting and reschedule on the caller's response. Confirm this detail in the core API design.
5. Otherwise, the caller receives the final result and occasional progress updates. Cancellation, shutdown, and exact event/API shapes remain to be defined.

The session is an in-memory logical state, not a permanently blocked OS thread. Whether `/quit` is literal CLI input or a caller API command is still open.

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
- Proposed: work waiting for user input is suspended in memory and releases its worker; the caller's response schedules that work item again. Confirm this before implementation. Blocking provider I/O may still occupy a worker and must be included in scale tests.
- Initial platform targets are Linux (including WSL) and macOS. Windows is out of scope.
- No plugin system in the initial design. Add extension mechanisms only if a real consumer need justifies their API, lifecycle, loading, and security complexity.
- Additional tools or providers are added only when a consumer needs them.
