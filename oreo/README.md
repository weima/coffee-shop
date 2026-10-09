# Oreo

Oreo is a small Odin agent harness intended to be used as a library by Coffee Shop and, once mature, published from its own repository. **Pi is the reference implementation for provider authentication and agent-loop behavior only; Oreo will not depend on Pi's code, executable, runtime, or credential store.**

> **Status:** design and planning only. The Odin implementation has not started.

## What Oreo will provide

- Direct provider authentication and model requests for OpenAI Codex and GitHub Copilot.
- A caller-owned session loop with three tools: `read`, `write`, and `execute`.
- A small Odin library API that Coffee Shop can call.

Oreo does not schedule work or set a global session limit. Consumers choose their own concurrency and are responsible for the resource limits of the machine.

## Authentication

Oreo will implement the provider-specific OAuth flows directly and store credentials separately in `~/.oreo/auth.json` with owner-only permissions. It will not read or write another harness's credential store. Provider client identifiers and endpoints must be checked for authorized use before release.

## Design documents

- [Architecture](architecture.md) — responsibilities, session flow, provider boundaries, and tools.
- [Implementation plan](PLAN.md) — staged work and verification gates.
- [Roadmap](ROADMAP.md) — first usable release, Coffee Shop adoption, and future repository extraction.

## Reference implementation

The following Pi source files are behavioral references for OAuth, credential handling, and built-in tool contracts. Oreo will implement the behavior independently.

- [OpenAI Codex OAuth](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/oauth/openai-codex.ts)
- [GitHub Copilot OAuth](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/oauth/github-copilot.ts)
- [Credential storage](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/auth-storage.ts)
- [Read tool](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/read.ts)
- [Write tool](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/write.ts)
- [Bash tool (`execute` reference)](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/bash.ts)
