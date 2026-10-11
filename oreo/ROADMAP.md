# Oreo Roadmap

Oreo grows from a provider-neutral Odin session host, run as a separate process started by the pi extension, into a pi extension Coffee Shop can use now. Library and executable delivery follow later, and then extraction into an independently maintainable repository. [Architecture](architecture.md) is the source of truth for confirmed design decisions.

## Core harness

- Build a long-lived Odin host process, started by the pi extension as a separate OS process, with one session per top-level task, persistent structured context storage, and a shared bounded worker pool for its work items.
- Implement task-session turns, per-work-item provider/model/thinking settings given as a prompt instruction, Pi-referenced agent-loop behavior, and `read`, `write`, and `execute` tools running in Odin, against a fake provider.
- Emit external-input events and occasional progress updates; persist context when work pauses for a decision, release the worker, and resume after caller input.
- Support Linux (including WSL) and macOS.

**Exit condition:** a caller can create sessions, run a tool round-trip, receive a final result, pause for user input and resume, and close a session without a separate process per session.

## Provider integration

- Confirm, through pi, login and model requests for the first providers to test, OpenAI Codex and GitHub Copilot, including endpoints, scopes, and model APIs as pi exposes them. Oreo performs no login and registers no OAuth client.
- Send model requests through pi's model layer after the core harness is established. Login, re-login, and token storage stay in pi; the end user chooses the default account in the Coffee Shop config.

**Exit condition:** fake-server tests cover provider behavior without live credentials, and separately approved manual smoke tests prove pi login and one small task per provider.

## Scale and Coffee Shop adoption

- Measure about 25 concurrent work items as a typical workload and at least 1,000 queued/retained work items as the stretch target; there is no requirement for 1,000 simultaneously active threads.
- Verify `Queue_Full`, work-item TTL expiry, and cooperative cancellation when a session closes.
- Tune the bounded worker pool and event delivery based on measurements.
- Integrate Oreo behind Coffee Shop's Worker boundary while Coffee Shop keeps task decomposition, worktrees, and durable task state.

**Exit condition:** benchmark results record memory and scheduling behavior; Coffee Shop completes a small local task through Oreo without launching an external agent CLI per session.

## Repository extraction

- Move the top-level `oreo/` package and its documentation to a dedicated repository.
- Keep the public API independent of Coffee Shop terms and internal data types.
- Add standalone build/test instructions and version the library API when consumers need compatibility guarantees.

**Exit condition:** Oreo builds and tests from its own repository, and Coffee Shop consumes it through the chosen local or versioned dependency mechanism.

## Later, only when needed

- Additional providers, tools, richer session search/retention options, and other consumer integrations.
- Resource policies beyond the bounded session worker pool only when a consumer need and measurements justify them.
