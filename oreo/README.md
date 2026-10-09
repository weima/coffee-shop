# Oreo

Oreo is a small Odin agent harness intended to be used as a library by Coffee Shop and, once mature, published from its own repository. It hosts one in-memory session per top-level task; each session can submit many work items to a shared thread pool in one long-lived process. **Pi is the behavioral reference for provider authentication, agent-loop defaults, and built-in tools only; Oreo will not depend on Pi's code, executable, runtime, or credential store.**

> **Status:** design and planning only. The Odin implementation has not started.

## What Oreo will provide

- A long-lived Odin host with per-task in-memory sessions and a shared worker pool for each session's work items.
- Provider authentication and model requests for OpenAI Codex and GitHub Copilot, after the provider-neutral core is established and provider contracts are verified.
- Pi-compatible `read`, `write`, and `execute` tools, plus events for external input, progress, and final results.
- A small Odin library API that Coffee Shop can call.

A typical workload is about 5 task sessions with 5 concurrent work items each (about 25 worker jobs). The stretch target is at least 1,000 queued/retained work items; Oreo does not need 1,000 active threads. Coffee Shop owns task decomposition and worktrees. Every dispatched work item carries provider, model, and thinking-level settings. The recommended design pauses work awaiting user input and releases its worker; confirm this detail in the core API design.

## Authentication

Oreo will implement the provider-specific OAuth flows directly and store credentials separately in `~/.oreo/auth.json` with owner-only permissions. It will not read or write another harness's credential store. Provider client identifiers and endpoints must be checked for authorized use before release.

## Design documents

- [Architecture](architecture.md) — authoritative design decisions, session lifecycle, pool direction, provider boundaries, and tools.
- [Implementation plan](PLAN.md) — staged work, open decisions, and verification gates.
- [Roadmap](ROADMAP.md) — first usable release, Coffee Shop adoption, and future repository extraction.

## Reference implementation

The following Pi source files are behavioral references for OAuth, credential handling, and built-in tool contracts. Oreo will implement the behavior independently.

- [OpenAI Codex OAuth](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/oauth/openai-codex.ts)
- [GitHub Copilot OAuth](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/oauth/github-copilot.ts)
- [Credential storage](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/auth-storage.ts)
- [Read tool](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/read.ts)
- [Write tool](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/write.ts)
- [Bash tool (`execute` reference)](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/bash.ts)
