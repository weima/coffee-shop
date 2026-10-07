# Coffee Shop Implementation Roadmap

## Purpose

Build a small Odin CLI that lets an active Pi session dispatch independent work to parallel Pi workers. Each Worker gets an isolated Git worktree and visible tmux session. A person reviews the results and decides whether to integrate them.

This roadmap describes the work. It does not start implementation.

## Architecture baseline

- The active Pi session is the **Barista**. It interprets the **Order** and prepares a **Recipe** with explicit **Shots**.
- Coffee Shop is a deterministic Odin CLI, not an AI coordinator.
- Each Shot runs in one Pi **Worker** and one isolated Git worktree, called a **Station**.
- One local machine, Pi, and tmux are the initial target.
- The **Register** stores current Brew and Shot status. The **Receipt** stores status events.
- The **Oreo** presents outcomes, evidence, and decisions for human review.
- Coffee Shop does not merge or publish work. It has no daemon or always-on watcher.

See [the architecture](docs/architecture.md) and [the vocabulary](specs/UBIQUITOUS_LANGUAGE_LATEST.md).

## Roadmap at a glance

| Milestone | Outcome | Depends on |
| --- | --- | --- |
| 0. Resolve contracts | User-approved inputs, state location, process, and cancellation rules | Architecture review |
| 1. CLI foundation | Odin CLI validates a Recipe and provides clear help and errors | Milestone 0 |
| 2. Durable Brew state | Register and Receipt preserve Brew and Shot lifecycle | Milestone 1 |
| 3. Isolated dispatch | Pi Workers run concurrently in tmux, each in its own Station | Milestone 2 |
| 4. Recovery and collection | Status, cancellation, and Oreo work after restarts | Milestone 3 |
| 5. Verification and dogfood | Tested local workflow and user-facing docs | Milestones 1–4 |

Each milestone ends with its acceptance checks. Stop and revise the plan if an acceptance check requires an excluded feature such as a daemon or second harness.

## Milestones

### 0. Resolve contracts before coding

Confirm the choices that affect file formats and process control:

- Recipe directory layout and the command syntax for `brew`, `status`, `collect`, and `cancel`.
- Register and Receipt location, retention, and behavior when records are missing or malformed.
- Maximum concurrent Workers and timeout behavior.
- Whether cancellation terminates a Worker or asks it to stop at a safe point.
- How tmux starts Pi with task text as data, not as shell syntax.
- When a Station becomes safe to remove after the person reviews its Oreo.

**Exit check:** Record each choice in the architecture or plan. Do not add a general configuration system unless a real choice needs runtime configuration.

### 1. Build the CLI foundation

- Create a small Odin package with one entry point and focused modules for arguments, domain records, and process boundaries.
- Add help and input validation for the chosen command set.
- Validate repository paths and Recipe contents before making a Station or starting a process.
- Return concise errors with non-zero exit codes. Keep diagnostics separate from machine-readable output.

**Exit checks:**

- Help describes each command and required input.
- Invalid input exits before any worktree, tmux session, or state file is created.
- Odin's compiler checks the CLI package, and focused tests cover valid and invalid arguments.

### 2. Add durable Brew and Shot state

- Define the Brew and Shot state transitions, including queued, running, completed, failed, cancelled, and interrupted.
- Write current state to the Register and append transitions to the Receipt.
- Make state updates safe against partial writes and repeated status reads.
- Treat missing, malformed, or conflicting state as unknown or incomplete, never as success.

**Exit checks:**

- State survives a Coffee Shop process restart.
- Tests cover every allowed transition and reject invalid transitions.
- A damaged Register or Receipt produces an actionable error and does not erase evidence.

### 3. Dispatch isolated Pi Workers

- Create one Git worktree per Shot.
- Start one Pi Worker in a dedicated tmux session for each Station.
- Keep task text and command arguments separate. Do not assemble a shell command from Order or Shot text.
- Enforce the Scale so the number of active Workers stays within the agreed limit.
- Record session identity, Station path, launch result, and Worker exit result.

**Exit checks:**

- Two parallel Shots use different worktrees and tmux sessions.
- A missing Pi executable, tmux failure, or Worker non-zero exit is visible in status.
- Tests use a temporary Git repository and a fake Pi executable. They do not contact GitHub or an AI service.

### 4. Recover, cancel, and collect

- Make `status` inspect durable records and current tmux and worktree evidence.
- Mark a Worker interrupted when Coffee Shop cannot prove that it is active or complete.
- Implement the agreed cancellation behavior and record its result.
- Let `collect` create an Oreo only from collected Worker results and Filter evidence.
- Keep Stations until a person reviews the Oreo. Do not merge, publish, or delete unreviewed work.

**Exit checks:**

- Restarting Coffee Shop preserves Brew and Shot records.
- Status never reports an uncertain Worker as completed.
- Cancellation and collection are repeatable without duplicating or hiding results.
- The Oreo names each Shot's outcome, evidence, and any decision needed.

### 5. Verify and dogfood the vertical slice

- Run Odin compiler checks and focused Odin tests.
- Test invalid input, process launch failure, non-zero Worker exit, malformed state, cancellation, and interrupted sessions.
- Run a local end-to-end Brew with fake Workers in a temporary repository.
- Run one small real Pi dogfood task only after the fake-worker path passes.
- Update the README with verified setup, commands, and known limits.

**Exit checks:**

- A multi-Shot Brew reaches an Oreo without GitHub access or a second AI coordinator.
- Each Station remains isolated until human review.
- The README matches the behavior that the tests and dogfood run prove.
- The person can inspect and integrate results without Coffee Shop doing it automatically.

## Odin reference

Use [Odin in Practice](https://github.com/weima/odin-in-practice) as the implementation guide:

- [Odin foundations](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/odin-foundations.md): package structure, procedure contracts, and build loop.
- [CLI and Linux](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/cli-linux.md): CLI contracts, argument parsing, errors and cleanup, allocators, environment, and child processes.
- [Memory and error philosophy](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/memory-philosophy.md): ownership, allocation lifetime, error handling, and rollback boundaries.
- [Parallel programming](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/parallel-programming.md): bounded concurrency, cancellation, and completion evidence.

Pass child-process arguments as an argument vector. Distinguish a process-launch error from a Worker that starts and exits with an error. Give each allocated buffer and operating-system resource a clear owner.

## Out of scope

- Automatic task decomposition by a separate model call.
- Persistent second mates, remote Workers, and fleet synchronization.
- Other agent harnesses or tmux alternatives.
- An always-on watcher, background daemon, Relay, or public integrations.
- Automatic merge, pull request creation, or publishing.

## Completion definition

The first release is complete when a Barista can submit a Recipe, run multiple isolated Pi Workers in tmux, inspect durable status after a restart, collect an Oreo with evidence, and make the integration decision manually. The README must describe only verified behavior.
