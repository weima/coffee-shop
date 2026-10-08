# Coffee Shop Implementation Plan

Build Coffee Shop as a local Odin CLI that dispatches explicit work to parallel Pi workers. The Barista prepares a Recipe; Coffee Shop creates an isolated Station for each Shot, runs Workers in tmux, records their state, and returns an Oreo for human review. This plan turns [the architecture](docs/architecture.md) into ordered implementation slices. It does not authorize code changes by itself.

## Delivery path

Implement the slices in order. Each slice has a concrete result and a gate; do not start the next slice until the current gate passes. Resolve the open contracts in Slice 0 before choosing file formats or process behavior.

| Slice | Result | Depends on |
| --- | --- | --- |
| 0. Lock contracts | Decisions for CLI, Recipe, state, concurrency, and lifecycle | Architecture review |
| 1. Project and CLI shell | Buildable Odin CLI with help and validation | 0 |
| 2. Recipe and domain model | Validated Brew and Shot inputs | 1 |
| 3. Durable state | Register and Receipt with tested transitions | 2 |
| 4. Station and Worker dispatch | Isolated worktrees and tmux Pi workers | 3 |
| 5. Status and recovery | Honest state after process restarts | 4 |
| 6. Collection and Oreo | Reviewable results with Filter evidence | 5 |
| 7. End-to-end dogfood | Verified local workflow and accurate docs | 1–6 |

## Slice 0 — Lock contracts before coding

Record the decisions in [the architecture](docs/architecture.md) or this plan. Prefer the smallest contract that supports the initial single-machine workflow.

- Define the Recipe file format, required fields, and how a Barista supplies its path and the Beans repository path.
- Define CLI command names, arguments, output, and exit behavior for `brew`, `status`, `cancel`, and `collect`.
- Choose the Register and Receipt location, record format, retention, and handling of missing, malformed, or partially written records.
- Define allowed Brew and Shot states and transitions, including how interrupted work is represented.
- Choose the Scale default and upper bound, and the timeout behavior, if any.
- Define how the CLI identifies and invokes the Pi executable and tmux; keep executable paths and arguments distinct from task text.
- Define when a Station may be removed. Until then, retain it for human review.
- Require a root-level `standards.md` in the Beans repository for code review and test-authoring guidance.
- Define how Coffee Shop supplies `standards.md` and the Taste-Driven Development skill to a test-authoring Worker without modifying the Beans repository.
- Define how Filter discovers existing unit/component and end-to-end test commands. It must preserve repository scripts and configuration; ambiguous discovery is reported, not guessed.

**Gate:** Every item above has a recorded decision. The decisions preserve the architecture boundaries: one local machine, Pi, tmux, no daemon, no automatic merge, and no publishing.

## Slice 1 — Establish the Odin CLI shell

- Confirm the Odin compiler and local Pi/tmux prerequisites needed for development and document the supported environment.
- Create the smallest buildable Odin program and CLI entry point.
- Add command parsing, `--help`, concise diagnostics, and non-zero exit codes for invalid input.
- Keep command handling thin; defer worktree, process, and persistence logic to later slices.

**Gate:** The program builds; help lists the supported commands; invalid or incomplete arguments fail before creating files, worktrees, or processes.

## Slice 2 — Validate Recipes and model work

- Implement the Recipe format and validation from Slice 0.
- Represent a Brew and its ordered Shots, including the identifiers and paths needed by later slices.
- Validate that the Beans path is a Git repository, Shot identifiers are unique, and required task text is present.
- Reject unsupported or ambiguous input before changing repository or state.

**Gate:** Tests cover a valid Recipe and malformed, incomplete, duplicate, and unsafe path inputs. No invalid Recipe creates a Station or starts a Worker.

## Slice 3 — Add durable Brew state

- Implement the Register as current Brew and Shot status, and the Receipt as append-only status events.
- Centralize allowed state transitions and record each transition with enough context to diagnose failures.
- Make state writes resilient to interruption; preserve the last valid state and report corrupt or conflicting records as incomplete/unknown.
- Make repeated reads and state updates safe; do not turn uncertainty into success.

**Gate:** Tests cover every allowed transition, reject invalid transitions, reload state in a fresh process, and verify malformed or interrupted writes do not erase valid evidence.

## Slice 4 — Create Stations and dispatch Workers

- Create one Git worktree per Shot, with no shared Station between Workers in a Brew.
- Start one tmux session and Pi process per Shot, passing the executable and argument vector separately from task text.
- Enforce the Scale and record each Station path, tmux session identity, launch result, and process outcome.
- On partial launch failure, record which Shots started and leave their Stations available for inspection.
- A Recipe may assign a normal Shot to add unit/component or end-to-end tests from the target repository's `standards.md`. Supply the Taste-Driven Development skill as Worker guidance without installing it into the target repository; do not create a special test-authoring component.
- Keep shell command construction out of the task-data path.

**Gate:** A local test with a temporary Git repository and fake Pi executable proves two Shots use distinct worktrees and sessions. Tests cover missing executables, tmux launch failure, and non-zero Worker exit without contacting GitHub or an AI service.

## Slice 5 — Report status and recover

- Implement `status` using Register/Receipt records plus available tmux/process evidence.
- On restart, reconcile persisted state with observable Worker state; mark uncertain work interrupted or unknown, never completed without evidence.
- Implement the cancellation behavior selected in Slice 0 and record its outcome.
- Ensure status and cancellation can be repeated without duplicating or hiding events.

**Gate:** Tests simulate restart, missing sessions, stale records, and repeated cancellation. Status distinguishes completed, failed, active, and uncertain Workers correctly.

## Slice 6 — Collect results and prepare the Oreo

- Implement `collect` to gather each Shot's report and Filter evidence.
- Review selected changes against the Beans repository's root `standards.md`.
- Discover and run the repository's existing unit/component and end-to-end test commands without changing scripts, configuration, or test selection. For MFEs, use Playwright only for browser behavior that unit/component tests cannot prove, following the repository's conventions.
- Report missing standards, ambiguous test commands, unavailable setup, and test failures explicitly; do not guess, override commands, or hide failures.
- Build the Oreo from Worker reports and Filter evidence. Identify any decisions needed from the developer. Do not merge, publish, or remove unreviewed Stations.
- Make collection repeatable without losing or duplicating evidence.

**Gate:** Tests cover successful, failed, and missing reports; review against `standards.md`; test discovery without command overrides; failing or unavailable test evidence; and repeated collection. The Oreo reports every Shot outcome, evidence, and unresolved decision.

## Slice 7 — Verify the vertical slice and dogfood

- Run Odin compiler checks and the focused tests for input validation, state transitions, process boundaries, recovery, and collection.
- Run a local end-to-end Brew with fake Workers in a temporary repository. Verify status after restart and collect an Oreo.
- Run one small real Pi dogfood task only after the fake-worker workflow passes; keep it local and review the returned Station manually.
- Update the README with verified prerequisites, commands, workflow, and limitations.

**Release gate:** A multi-Shot Brew completes without GitHub access or a second coordinator; Stations remain isolated and available for human review; the Register and Receipt survive restart; the Oreo contains check evidence; documentation matches observed behavior.

## Verification and implementation references

Use the [Odin in Practice](https://github.com/weima/odin-in-practice) chapters as implementation references:

- [Odin foundations](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/odin-foundations.md) — package structure and build loop.
- [CLI and Linux](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/cli-linux.md) — CLI contracts, argument parsing, errors, allocators, environment, and child processes.
- [Memory and error philosophy](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/memory-philosophy.md) — ownership, allocation lifetime, error handling, and rollback boundaries.
- [Parallel programming](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/parallel-programming.md) — bounded concurrency, cancellation, and completion evidence.

Pass child-process arguments as an argument vector. Distinguish a launch error from a Worker that starts and exits with an error. Give each allocated buffer and operating-system resource a clear owner.

## Scope guardrails

The first release targets one machine, Pi, and tmux. Keep task decomposition with the Barista and integration decisions with the developer. Do not add remote workers, other agent harnesses, a daemon or watcher, Relay, automatic merge, PR creation, publishing, or a general configuration system without a separately approved requirement.
