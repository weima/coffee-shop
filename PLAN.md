# Coffee Time Implementation Plan

## Goal

Build a small Odin CLI that lets an active Pi session dispatch independent work to parallel Pi workers. Each worker gets an isolated Git worktree and visible tmux session. A human reviews the collected results and decides whether to integrate them.

This is a plan, not approval to begin implementation.

## Agreed direction

- The active Pi session is the **Barista** and owns task decomposition.
- Coffee Time is a deterministic Odin CLI, not a second AI coordinator.
- A **Recipe** contains an Order and explicit **Shots**.
- Each Shot runs as one Pi **Worker** in its own Git worktree, called a **Station**.
- The first version targets one local machine, Pi, and tmux.
- Current status is stored in the **Register**. Status events are stored in the **Receipt**.
- The Barista presents the **Oreo** for human review. Coffee Time does not merge or publish changes.
- There is no always-on watcher, remote worker, Relay, second mate, or alternate backend.

## Implementation steps

### 1. Define the CLI and input contract

- Choose a small command set for starting a Brew, checking status, collecting results, and cancelling work.
- Define a simple Recipe layout that does not need a new parser dependency.
- Validate repository paths, Shot names, and required inputs before creating worktrees or processes.
- Document the chosen commands and their failure behavior.

**Acceptance:** Invalid input fails before side effects. Help text shows the required inputs and commands.

### 2. Add the Brew and Shot state model

- Store a durable Register for current Brew and Shot states.
- Append state transitions to the Receipt.
- Define explicit states for queued, running, completed, failed, cancelled, and interrupted work.
- Make status reads tolerate a missing or malformed record without reporting success.

**Acceptance:** A state transition is recorded once and survives a CLI restart. Invalid state is reported as unknown or failed, never completed.

### 3. Create isolated Stations and Pi Workers

- Create one Git worktree per Shot.
- Start one Pi CLI process in a tmux session for each Shot.
- Pass commands and task text as separate arguments. Do not interpolate task text into a shell command.
- Enforce the Scale so a Brew does not exceed its configured concurrency limit.
- Capture each Worker result and exit status in its Station.

**Acceptance:** Two concurrent Shots use different worktrees and tmux sessions. A launch error or non-zero exit is visible in status and results.

### 4. Recover and collect work

- Make status inspection derive from durable records and the current tmux/worktree evidence.
- Mark work interrupted when the CLI cannot prove that a Worker is active or complete.
- Allow explicit collection of completed results into an Oreo.
- Keep worktrees until a person reviews the Oreo; do not auto-merge or auto-delete unreviewed changes.

**Acceptance:** Restarting Coffee Time does not lose the Brew record. Collection includes each Shot's outcome, check evidence, and any human decision required.

### 5. Verify the vertical slice

- Add focused Odin tests for CLI validation, state transitions, and result collection.
- Use temporary repositories and fake Pi executables for process and worktree tests.
- Test missing executables, worker failures, malformed state, cancellation, and interrupted sessions.
- Run the documented Odin checks and update the README with verified setup and usage instructions.

**Acceptance:** The end-to-end test dispatches multiple fake Workers, keeps their Stations isolated, records outcomes, and produces an Oreo without contacting GitHub or an AI service.

## Odin reference

Use [Odin in Practice](https://github.com/weima/odin-in-practice) as the implementation guide:

- [Odin foundations](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/odin-foundations.md): package structure, procedure contracts, and build loop.
- [CLI and Linux](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/cli-linux.md): CLI contracts, argument parsing, errors and cleanup, allocators, environment, and child processes.
- [Memory and error philosophy](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/memory-philosophy.md): ownership, allocation lifetime, error handling, and rollback boundaries.
- [Parallel programming](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/parallel-programming.md): bounded concurrency, process/thread distinction, cancellation, and completion evidence.

Follow the book's advice to pass an argument vector to child processes, distinguish process-launch errors from child exit failures, and assign clear owners to buffers and resources.

## Out of scope

- Automatic decomposition by a separate model call.
- Persistent second mates, remote workers, and fleet synchronization.
- Multiple agent harnesses or session backends.
- Always-on watcher, background daemon, Relay, and public integrations.
- Automatic branch merge, pull request creation, and publishing.

## Open decisions before coding

- Exact CLI syntax and Recipe directory layout.
- Location and retention policy for Register and Receipt data.
- Default concurrency limit and Worker timeout behavior.
- Whether cancellation stops the Pi process immediately or asks it to finish safely.
