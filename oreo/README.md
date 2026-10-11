# Oreo

**Why Oreo exists.** pi is very capable, but it's too heavy for parallel jobs. So we want to fire up light-weight oreo to do what pi does. Oreo runs light-weight agents that do what pi does, in parallel. It is a pi extension and uses pi's runtime and login.

Oreo is a small Odin agent harness. It ships as a pi extension for now; library and executable delivery are later. Coffee Shop consumes it through that extension for now; a library API comes later, and Oreo may be published from its own repository once mature. It hosts one in-memory session per top-level task; each session can submit many work items to a shared thread pool in one long-lived host process, which the pi extension starts as a separate OS process. **Oreo is a pi extension and depends on the pi runtime. The agent loop and the `read`, `write`, and `execute` tools run in Odin; a thin bridge gives the Odin host access to pi's model layer (proposed, pending the spike). The end user logs in to providers in pi beforehand; Oreo performs no login and implements no OAuth flow, token handling, or client registration of its own; these are pi's responsibility.** Pi also remains the behavioral reference for agent-loop defaults and built-in tools.

> **Status:** Oreo implementation is underway. The bundled SQLite 3.54.0 binding and metadata store pass 17 real-engine tests on macOS. The store persists work-item transitions, session-close cancellation, and versioned schema migrations; Linux verification, worker execution, and the provider-neutral host remain pending.

## What Oreo will provide

- A long-lived Odin host process, started by the pi extension, with per-task sessions, durable structured context storage, and a shared worker pool for each session's work items.
- Model requests through pi's model layer, after the provider-neutral core is established. Providers come from pi's ecosystem; OpenAI Codex and GitHub Copilot are the first to test.
- Pi-compatible `read`, `write`, and `execute` tools, running in Odin, plus events for external input, progress, and final results.
- A pi extension for Coffee Shop now. A small Odin library API comes later.

A typical workload is about 5 task sessions with 5 concurrent work items each (about 25 worker jobs). The stretch target is at least 1,000 queued/retained work items; Oreo does not need 1,000 active threads. Coffee Shop owns task decomposition and worktrees. Each work item's prompt carries an instruction naming its provider, model, and thinking level; the parent pi must support them. Session history lives in a structured database and remains findable after close/restart; active work may be cached in memory. User-input waits persist context and release the worker; `close(session)` cooperatively cancels that session's work but preserves its history.

## Authentication (pi's responsibility)

Login goes through pi. The end user logs in to each provider in pi beforehand; Oreo performs no login. The end user chooses the default account, provider, model, and thinking level in a Coffee Shop config file (format not yet specified). Whether a session also chooses its account is not yet specified. Oreo does not implement its own OAuth flow, does not register its own client ID, and does not read or write another harness's credential store. The earlier personal import exception (`OREO_PERSONAL_IMPORT=codex,copilot`) is superseded, because no import is needed; see [architecture](architecture.md#runtime-decision-2026-10-10) and the [earlier record](architecture.md#personal-import-exception). No legal or provider-terms check (developer decision, 2026-10-10: Oreo is a pi plugin).

## Development

From the repository root, run the Oreo package tests with:

```sh
cd oreo && just test
```

`just check` is also available as a type-check-only command. The test recipe compiles and links the bundled amalgamation with the platform C compiler; it does not use system SQLite.

## Design documents

- [Architecture](architecture.md) — authoritative design decisions, session lifecycle, pool direction, provider boundaries, and tools.
- [Implementation plan](PLAN.md) — staged work, open decisions, and verification gates.
- [Roadmap](ROADMAP.md) — first usable release, Coffee Shop adoption, and future repository extraction.
- [Database schema](schema.md) — v1 SQLite tables, lifecycle constraints, and metadata indexes.
- [SQLite binding subproject](src/sqlite/README.md) — minimal Odin/C API boundary, bundled SQLite source, and real-database test plan.

## Reference implementation

The following Pi source files are behavioral references for built-in tool contracts. The OAuth and credential-handling links are the record of the earlier design; login now goes through pi.

- [OpenAI Codex OAuth](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/oauth/openai-codex.ts)
- [GitHub Copilot OAuth](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/oauth/github-copilot.ts)
- [Credential storage](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/auth-storage.ts)
- [Read tool](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/read.ts)
- [Write tool](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/write.ts)
- [Bash tool (`execute` reference)](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/bash.ts)
