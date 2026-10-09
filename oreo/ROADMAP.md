# Oreo Roadmap

Oreo grows from a provider-neutral, in-process Odin session host into a library Coffee Shop can consume, then into an independently maintainable repository. [Architecture](architecture.md) is the source of truth for confirmed design decisions.

## Core harness

- Build a long-lived Odin host with one in-memory session per top-level task and a shared bounded worker pool for its work items.
- Implement task-session turns, per-work-item provider/model/thinking settings, Pi-referenced agent-loop behavior, and `read`, `write`, and `execute` tools against a fake provider.
- Emit external-input events and occasional progress updates. Recommended: suspend sessions awaiting a decision without occupying a worker; confirm this in the core contract.
- Support Linux (including WSL) and macOS.

**Exit condition:** a caller can create sessions, run a tool round-trip, receive a final result, pause for user input and resume, and close a session without a separate process per session.

## Provider integration

- Verify authorized Codex and GitHub Copilot OAuth clients, endpoints, scopes, and model APIs.
- Add provider login/re-login with a copyable URL, token storage/refresh, and model requests only after the core harness is established.
- Keep work and personal credentials side by side in Oreo's own store.

**Exit condition:** fake-server tests cover provider behavior without live credentials, and separately approved manual smoke tests prove supported login and one small task per provider.

## Scale and Coffee Shop adoption

- Measure about 25 concurrent work items as a typical workload and at least 1,000 queued/retained work items as the stretch target; there is no requirement for 1,000 simultaneously active threads.
- Tune the bounded worker pool and event delivery based on measurements.
- Integrate Oreo behind Coffee Shop's Worker boundary while Coffee Shop keeps task decomposition, worktrees, and durable task state.

**Exit condition:** benchmark results record memory and scheduling behavior; Coffee Shop completes a small local task through Oreo without launching an external agent CLI per session.

## Repository extraction

- Move the top-level `oreo/` package and its documentation to a dedicated repository.
- Keep the public API independent of Coffee Shop terms and internal data types.
- Add standalone build/test instructions and version the library API when consumers need compatibility guarantees.

**Exit condition:** Oreo builds and tests from its own repository, and Coffee Shop consumes it through the chosen local or versioned dependency mechanism.

## Later, only when needed

- Additional providers, tools, richer session persistence, and other consumer integrations.
- Resource policies beyond the bounded session worker pool only when a consumer need and measurements justify them.
