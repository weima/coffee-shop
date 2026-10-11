# Oreo

Oreo is a small Odin agent harness intended to be used as a library by Coffee Shop and, once mature, published from its own repository. It hosts one in-memory session per top-level task; each session can submit many work items to a shared thread pool in one long-lived process. **Pi is the behavioral reference for provider authentication, agent-loop defaults, and built-in tools only; Oreo will not depend on Pi's code, executable, runtime, or credential store.**

> **Status:** Oreo implementation is underway. The bundled SQLite 3.54.0 binding and metadata store pass 17 real-engine tests on macOS. The store persists work-item transitions, session-close cancellation, and versioned schema migrations; Linux verification, worker execution, and the provider-neutral host remain pending.

## What Oreo will provide

- A long-lived Odin host with per-task sessions, durable structured context storage, and a shared worker pool for each session's work items.
- Provider authentication and model requests for OpenAI Codex and GitHub Copilot, after the provider-neutral core is established and provider contracts are verified.
- Pi-compatible `read`, `write`, and `execute` tools, plus events for external input, progress, and final results.
- A small Odin library API that Coffee Shop can call.

A typical workload is about 5 task sessions with 5 concurrent work items each (about 25 worker jobs). The stretch target is at least 1,000 queued/retained work items; Oreo does not need 1,000 active threads. Coffee Shop owns task decomposition and worktrees. Every work item uses explicit provider, model, and thinking-level settings. Session history lives in a structured database and remains findable after close/restart; active work may be cached in memory. User-input waits persist context and release the worker; `close(session)` cooperatively cancels that session's work but preserves its history.

## Authentication

Oreo will implement the provider-specific OAuth flows directly and store credentials separately in `~/.oreo/auth.json` with owner-only permissions. It will not read or write another harness's credential store. Provider client identifiers and endpoints must be checked for authorized use before release.

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

The following Pi source files are behavioral references for OAuth, credential handling, and built-in tool contracts. Oreo will implement the behavior independently.

- [OpenAI Codex OAuth](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/oauth/openai-codex.ts)
- [GitHub Copilot OAuth](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/oauth/github-copilot.ts)
- [Credential storage](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/auth-storage.ts)
- [Read tool](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/read.ts)
- [Write tool](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/write.ts)
- [Bash tool (`execute` reference)](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/bash.ts)
