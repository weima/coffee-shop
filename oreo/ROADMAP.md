# Oreo Roadmap

Oreo grows from a small, usable Odin agent loop into a library Coffee Shop can consume, then into an independently maintainable repository. The consumer—not Oreo—sets session concurrency and machine resource limits.

## First usable release

- Build a standalone Odin package with Codex and GitHub Copilot provider adapters.
- Implement provider OAuth login and token refresh with Oreo-owned credential storage.
- Support a single caller-owned session with `read`, `write`, and `execute` tools.
- Verify provider behavior with fake-server tests and keep live authentication out of CI.

**Exit condition:** a consumer can authenticate, make a model request, handle a tool call, and receive a final answer through Oreo's public API.

## Coffee Shop adoption

- Integrate Oreo as a library behind Coffee Shop's Worker boundary.
- Keep Coffee Shop responsible for task scheduling, worktrees, durable state, and parallelism.
- Compare the new path with the current Worker flow using deterministic fake-provider end-to-end tests before changing defaults.

**Exit condition:** Coffee Shop can complete and report a small local task through Oreo without launching an external provider CLI process.

## Repository extraction

- Move the top-level `oreo/` package and its documentation to a dedicated repository.
- Keep the public API independent of Coffee Shop terms and internal data types.
- Add standalone build/test instructions and version the library API when consumers need compatibility guarantees.

**Exit condition:** Oreo builds and tests from its own repository, and Coffee Shop consumes it through the chosen local or versioned dependency mechanism.

## Later, only when needed

- Additional providers, tools, richer session persistence, and other consumer integrations.
- Any shared resource controls only if a consumer asks for a reusable primitive; machine-wide concurrency policy remains with that consumer.
