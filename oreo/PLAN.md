# Oreo Implementation Plan

Build Oreo as an independent Odin agent harness in the top-level `oreo/` package. Keep the public library boundary small so Coffee Shop can consume it and the package can later move to its own repository.

## Delivery slices

| Slice | Result | Gate |
|---|---|---|
| 0. Confirm provider contracts | Auth and API assumptions are checked against the reference implementation and provider requirements. | The required login, refresh, chat, tool-call, and cancellation behavior is documented; client-ID and endpoint reuse is explicitly resolved. |
| 1. Establish the Odin package | A buildable package with its minimal public session and provider interfaces. | `odin check` succeeds; package tests run without network access. |
| 2. Add credential storage and login | Oreo-owned private credential storage and provider login flows. | Fake-server tests cover success, malformed responses, cancellation, expiry, and refresh for each provider. No test uses live credentials. |
| 3. Implement provider requests | Direct provider API calls, streaming responses, tool-call parsing, and normalized errors. | Recorded or synthetic fixtures cover text, tool calls, usage, provider errors, and interrupted streams. |
| 4. Add the session/tool loop | A caller can run a session with `read`, `write`, and `execute`, receive a final answer, or cancel it. | Fake-provider tests prove tool calls round-trip correctly and execution failures are returned as tool results. |
| 5. Integrate with Coffee Shop | Coffee Shop can use Oreo through its library boundary instead of launching an external agent CLI for the selected workflow. | A local end-to-end test uses a fake provider; a separately approved real-provider smoke test confirms login and one small task. |
| 6. Prepare extraction | Package paths, build instructions, license notices, and tests work without Coffee Shop-specific code. | The package builds and tests independently; Coffee Shop consumes only its public API. |

## Contracts to settle before implementation

- Which provider API variants and model capabilities the first release supports.
- The exact login interaction surface for browser callback and device-code flows.
- Whether the reference OAuth client identifiers and Copilot endpoints may be used by Oreo, or Oreo needs its own registered client.
- The credential-file update/locking strategy and the public session cancellation contract.
- Exact `read`, `write`, and `execute` arguments and result format.

Do not silently assume that provider endpoints or client IDs are stable, authorized, or supported contracts. Confirm them before shipping an auth flow.

## Explicit exclusions

- No dependency on another agent harness's packages, executable, session files, or credential storage.
- No worker pool, global session cap, concurrency scheduler, or machine-wide memory manager; the consumer owns those decisions.
- No task planner, worktree manager, UI, or extra tool set in the initial package.
- No live-provider credentials in automated tests.
