# Oreo Implementation Plan

Build Oreo as an independent Odin agent harness in the top-level `oreo/` package, with Odin code in `oreo/src/` and package-owned assets in `oreo/assets/`. Keep the public library boundary small so Coffee Shop can consume it and the package can later move to its own repository.

## Delivery slices

| Slice | Result | Gate |
|---|---|---|
| 0. Confirm provider contracts | Auth and API assumptions are checked against Pi's behavior and provider requirements. | Oreo's authorized client registrations and redirects, supported APIs, session settings, and tool contracts are documented; login, refresh, chat, tool-call, and cancellation behavior is explicit; client-ID and endpoint reuse is resolved. |
| 1. Establish the Odin package | A buildable package with its minimal public session and provider interfaces. | `odin check` succeeds; package tests run without network access. |
| 2. Add credential storage and login | Oreo-owned private credential storage and provider login flows. | Fake-server tests cover success, malformed responses, cancellation, expiry, and refresh for each provider. No test uses live credentials. |
| 3. Implement provider requests | Direct provider API calls, streaming responses, tool-call parsing, and normalized errors. | Recorded or synthetic fixtures cover text, tool calls, usage, provider errors, and interrupted streams. |
| 4. Add the session/tool loop | A caller can run a session with `read`, `write`, and `execute`, receive a final answer, or cancel it. | Fake-provider tests prove tool calls round-trip correctly and execution failures are returned as tool results. |
| 5. Integrate with Coffee Shop | Coffee Shop can use Oreo through its library boundary instead of launching an external agent CLI for the selected workflow. | A local end-to-end test uses a fake provider; a separately approved real-provider smoke test confirms login and one small task. |
| 6. Prepare extraction | Package paths, build instructions, license notices, and tests work without Coffee Shop-specific code. | The package builds and tests independently; Coffee Shop consumes only its public API. |

## Decisions established

- OAuth uses Codex and GitHub Copilot subscription flows modeled on Pi, but Oreo implements them independently and stores credentials in its own `~/.oreo/auth.json`.
- Retain work and personal accounts. Codex browser login may use a temporary `127.0.0.1` callback; Codex headless login and Copilot login use device-code flows, subject to provider support.
- Refresh credentials and provide a re-login path if refresh fails or credentials expire.
- Session-level provider, model, and thinking choices override Oreo defaults when supplied; otherwise use the default configuration.
- `read`, `write`, and `execute` follow Pi's corresponding built-in tool behavior; `execute` corresponds to Pi's `bash` tool.
- The consumer owns concurrency and machine resource limits. No plugin system is planned for the initial package.

## Remaining implementation gates

- Confirm provider authorization, Oreo-owned client registration, redirect URI, scopes, supported endpoints, and model/API capabilities. Do not assume Pi client IDs or undocumented endpoints are reusable.
- Choose how sessions select between work and personal credentials, and define the default-config location/schema.
- Define credential-file update/locking, the caller-facing re-login handoff, and the public cancellation contract.
- Transcribe and verify the exact Pi-compatible tool schemas/output behavior and provider request/stream/tool-call contracts before implementation.

Do not silently assume provider endpoints, OAuth clients, or subscription access are stable, authorized, or supported contracts. Confirm them before shipping an auth flow.

## Explicit exclusions

- No dependency on another agent harness's packages, executable, session files, or credential storage.
- No worker pool, global session cap, concurrency scheduler, or machine-wide memory manager; the consumer owns those decisions.
- No plugin system, task planner, worktree manager, UI, or extra tool set in the initial package.
- No live-provider credentials in automated tests.
