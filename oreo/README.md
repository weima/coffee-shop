# Oreo

Oreo is a small Odin agent harness intended to be used as a library by Coffee Shop and, once mature, published from its own repository. Delivery (extension, library, or executable) is under review. It hosts one in-memory session per top-level task; each session can submit many work items to a shared thread pool in one long-lived process. **Oreo ships as a pi extension and depends on the pi runtime. All provider login and model calls go through pi's auth and model layer; Oreo implements no OAuth flow of its own.** Pi also remains the behavioral reference for agent-loop defaults and built-in tools.

> **Status:** Oreo implementation is underway. The bundled SQLite 3.54.0 binding and metadata store pass 17 real-engine tests on macOS. The store persists work-item transitions, session-close cancellation, and versioned schema migrations; Linux verification, worker execution, and the provider-neutral host remain pending.

## What Oreo will provide

- A long-lived Odin host with per-task sessions, durable structured context storage, and a shared worker pool for each session's work items.
- Provider login and model requests for OpenAI Codex and GitHub Copilot through pi's auth and model layer, after the provider-neutral core is established.
- Pi-compatible `read`, `write`, and `execute` tools, plus events for external input, progress, and final results.
- A small Odin library API that Coffee Shop can call.

A typical workload is about 5 task sessions with 5 concurrent work items each (about 25 worker jobs). The stretch target is at least 1,000 queued/retained work items; Oreo does not need 1,000 active threads. Coffee Shop owns task decomposition and worktrees. Every work item uses explicit provider, model, and thinking-level settings. Session history lives in a structured database and remains findable after close/restart; active work may be cached in memory. User-input waits persist context and release the worker; `close(session)` cooperatively cancels that session's work but preserves its history.

## Authentication

Login goes through pi. Each user logs in through pi with their own account; Oreo does not implement its own OAuth flow and does not register its own client ID. Oreo does not read or write another harness's credential store. How work and personal accounts stay separate under pi is not yet specified. The earlier personal import exception (`OREO_PERSONAL_IMPORT=codex,copilot`) is superseded, because no import is needed; see [architecture](architecture.md#runtime-decision-2026-10-10) and the [earlier record](architecture.md#personal-import-exception). Provider terms must be checked before any public release; personal use is not affected.

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
