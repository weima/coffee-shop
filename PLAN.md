# Coffee Shop Implementation Plan

Build Coffee Shop as a local Odin CLI that dispatches explicit work to parallel Pi Workers. The Barista prepares a Recipe; Coffee Shop creates an isolated Station for each Shot, runs Workers in Herdr tabs, records their state, and returns an Oreo for human review. This plan turns [the architecture](docs/architecture.md) into ordered implementation slices. It does not authorize code changes by itself.

## Delivery path

Implement the slices in order. Each slice has a concrete result and a gate; do not start the next slice until the current gate passes. Resolve the open contracts in Slice 0 before choosing file formats or process behavior.

| Slice | Result | Depends on |
| --- | --- | --- |
| 0. Lock contracts | Decisions for CLI, Recipe, state, concurrency, and lifecycle | Architecture review |
| 1. Project and CLI shell | Buildable Odin CLI with help and validation | 0 |
| 2. Recipe and input validation | Validated Recipe/Shot inputs and Beans repository | 1 |
| 3. Durable state | Register and Receipt with tested transitions | 2 |
| 4. Station and Worker dispatch | Isolated worktrees and Herdr Pi workers | 3 |
| 5. Status and recovery | Honest state after process restarts | 4 |
| 6. Collection and Oreo | Reviewable results with Filter evidence | 5 |
| 7. End-to-end dogfood | Verified local workflow and accurate docs | 1–6 |

## Slice 0 — Lock contracts before coding

Record the decisions in [the architecture](docs/architecture.md) or this plan. Prefer the smallest contract that supports the initial single-machine workflow.

- Recipe input is strict JSON with a non-empty `order` and `shots` array. Each Shot has a non-empty `prompt` and a unique 1–64 character ASCII `id` matching `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`. The Beans repository path is a separate CLI argument.
- CLI: `coffee-shop brew --repo <path> --recipe <recipe.json>`; `status`, `cancel`, and `collect` take a Brew ID.
- Store each Brew under `$CS_STATE_DIR/<brew-id>/` (default `~/.coffee-shop/<brew-id>/`), with current state in `register.json` and append-only events in `receipt.ndjson`. Retain records indefinitely in v1; report corrupt or partial records without automatic repair.
- Shot states are `queued`, `running`, `completed`, `failed`, `cancelled`, and `interrupted`. Queued launch failures become `failed`; active cancellation is a request until Worker exit is confirmed. Derive Brew status from its Shots.
- Use a fixed Scale of two active Workers and no automatic timeout. `brew` runs a per-Brew supervisor that schedules queued Shots and exits when the Brew is terminal; it is not a daemon.
- Use `pi --print --no-session`; create one Herdr workspace per Brew and one tab per Shot. Herdr's command string launches a hidden Coffee Shop Worker subcommand with validated IDs only; the Worker subcommand reads task text from state and starts Pi with an argument vector.
- Keep Stations and state after collection. Coffee Shop never auto-deletes them; users remove reviewed Stations and state manually. No cleanup command in v1.
- Require a root-level `standards.md` in the Beans repository for code review and test-authoring guidance. Supply the Taste-Driven Development skill to test-authoring Workers without installing it into Beans.
- Filter uses a separate one-shot Pi reviewer against `standards.md`, then discovers unit/component and end-to-end test commands from existing manifests and test configuration. It preserves scripts and configuration; ambiguous discovery is reported, not guessed.

**Gate:** The input, CLI, state location and format, lifecycle, cancellation, concurrency, Herdr launch, retention, and Filter contracts above are fixed. Slice 1 is complete on the toolchain recorded in the README; proceed to Recipe validation. Preserve the boundaries: one local machine, Pi, Herdr, no daemon, no automatic merge, and no publishing.

## Slice 1 — Establish the Odin CLI shell

- Confirm the Odin compiler and local Pi/Herdr prerequisites needed for development and document the supported environment.
- Create the smallest buildable Odin program and CLI entry point.
- Add command parsing, `--help`, concise diagnostics, and non-zero exit codes for invalid input.
- Keep command handling thin; defer worktree, process, and persistence logic to later slices.

**Gate:** The program builds; help lists the supported commands; invalid or incomplete arguments fail before creating files, worktrees, or processes.

## Slice 2 — Validate Recipes and model work

- Implement the Recipe format and validation from Slice 0.
- Keep the validated Recipe as ordered Shot specifications; add Brew identity and Station paths in the later persistence and worktree slices.
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
- Create one Herdr workspace per Brew and one tab per Shot; start each Pi Worker in its Station.
- Add an internal Worker subcommand that accepts validated Brew/Shot IDs, loads task data from state, and starts Pi with an argument vector. Keep prompts out of Herdr's command string.
- Keep a per-Brew supervisor active only for the lifetime of `brew`; maintain at most two Workers and start queued Shots as slots open. Continue queued independent Shots after a failure; cancelling the Brew cancels queued Shots and interrupts active Workers.
- Record each Station path, Herdr workspace/tab identity, launch result, and process outcome.
- On partial launch failure, record which Shots started and leave their Stations available for inspection.
- A Recipe may assign a normal Shot to add unit/component or end-to-end tests from the target repository's `standards.md`. Supply the Taste-Driven Development skill as Worker guidance without installing it into the target repository; do not create a special test-authoring component.
- Keep shell command construction out of the task-data path.

**Gate:** A local test with a temporary Git repository and fake Pi executable proves two Shots use distinct worktrees and Herdr tabs. Tests cover missing executables, Herdr launch failure, and non-zero Worker exit without contacting GitHub or an AI service.

## Slice 5 — Report status and recover

- Implement `status` using Register/Receipt records plus available Herdr/process evidence.
- On restart, reconcile persisted state with observable Worker state; mark uncertain work interrupted or unknown, never completed without evidence.
- Implement the cancellation behavior selected in Slice 0 and record its outcome.
- Ensure status and cancellation can be repeated without duplicating or hiding events.

**Gate:** Tests simulate restart, missing sessions, stale records, and repeated cancellation. Status distinguishes completed, failed, active, and uncertain Workers correctly.

## Slice 6 — Collect results and prepare the Oreo

- Implement `collect` to gather each Shot's report and Filter evidence.
- Run a separate one-shot, read-only Pi review of the selected changes against the Beans repository's root `standards.md`.
- Discover unit/component and end-to-end test commands from the repository's existing manifests and test configuration, then run them unchanged. For MFEs, use Playwright only for browser behavior that unit/component tests cannot prove, following the repository's conventions.
- Report review findings, missing standards, ambiguous test commands, unavailable setup, and test failures explicitly. Filter does not fix code, override commands, or hide findings.
- Build the Oreo from Worker reports and Filter evidence. Identify any decisions needed from the developer. Do not merge, publish, or remove unreviewed Stations.
- Make collection repeatable without losing or duplicating evidence.

**Gate:** Tests cover successful, failed, and missing reports; review against `standards.md`; test discovery without command overrides; failing or unavailable test evidence; and repeated collection. The Oreo reports every Shot outcome, evidence, and unresolved decision.

## Slice 7 — Verify the vertical slice and dogfood

- Run Odin compiler checks and the focused tests for input validation, state transitions, process boundaries, recovery, and collection.
- Run a local end-to-end Brew with fake Workers in a temporary repository. Verify status after restart and collect an Oreo.
- Run one small real Pi dogfood task only after the fake-worker workflow passes; keep it local and review the returned Station manually.
- Update the README with verified prerequisites, commands, workflow, and limitations.

**Release gate:** A multi-Shot Brew completes without GitHub access or a second coordinator; Stations remain isolated and available for human review; the Register and Receipt survive restart; the Oreo contains check evidence; documentation matches observed behavior.

## Verification status

Slices 0–7 are implemented. `just test` runs 93 tests, including four end-to-end tests (`src/e2e_test.odin`) that drive the real binary with fake `herdr` and `pi`. Everything below was also run by hand against real Herdr and Pi, with up to three Shots and two Workers in parallel, from inside a Herdr pane and from a plain terminal with every `HERDR_*` variable removed.

| Release gate | Evidence |
| --- | --- |
| A multi-Shot Brew completes without GitHub access or a second coordinator | End-to-end test: three Shots, one failing, no network. Live Brews with real Pi. |
| Stations remain isolated and available for human review | End-to-end test: each Shot's output exists only in its own Station and never in the Beans repository; one Herdr tab per Shot. Nothing is deleted by `collect`. |
| The Register and Receipt survive restart | End-to-end tests run `status` and `collect` as fresh processes, then kill the supervisor with `SIGKILL` and recover both Shots' results. A third test cancels a running Brew: Workers end, queued Shots are cancelled, and a repeat `cancel` changes nothing. A fourth shows `brew` exiting 1, with the Brew ID and Herdr's message, when no Herdr server is running. |
| The Oreo contains check evidence | End-to-end test: review text, a passing `make test`, the failing Shot's reason, and the decisions list. A repeat `collect` is byte-identical. |
| Documentation matches observed behaviour | README requirements, usage and limitations were written from the runs above. |

Known gaps, deliberately not hidden:

- Only Linux and WSL are supported; macOS needs a `ps`-based process-identity fallback.
- Task decomposition, merging, publishing and cleanup stay manual by design.

## Verification and implementation references

Use the [Odin in Practice](https://github.com/weima/odin-in-practice) chapters as implementation references:

- [Odin foundations](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/odin-foundations.md) — package structure and build loop.
- [CLI and Linux](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/cli-linux.md) — CLI contracts, argument parsing, errors, allocators, environment, and child processes.
- [Memory and error philosophy](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/memory-philosophy.md) — ownership, allocation lifetime, error handling, and rollback boundaries.
- [Parallel programming](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/parallel-programming.md) — bounded concurrency, cancellation, and completion evidence.

Pass child-process arguments as an argument vector. Distinguish a launch error from a Worker that starts and exits with an error. Give each allocated buffer and operating-system resource a clear owner.

## Roadmap: v0.2.0

These items came from dogfooding v0.1 (see [the Odin book dogfood](docs/dogfood-odin-book.md)). They are planned, not started; the contracts below are proposals to settle before coding.

### 1. Show that a Worker is alive

**Problem.** Workers run `pi --print`, which prints only its final answer. A running Worker's pane shows just the command line, and `status` says only `running`, so a busy Worker and a dead one look the same for the first ten minutes or more.

**Goal.** A small progress report that answers "is it alive, and what is it doing?" without flooding the terminal.

- `status` shows, for each running Shot, one line with: time running, time since the last activity, and a short description of that activity when known. For example `alpha  running  4m12s  active 8s ago`.
- Activity is evidence, not a guess. Candidate signals: the newest file change in the Station, and Pi's own event stream (`pi --mode json` reports tool calls and messages; the Worker would keep the latest one, and the final answer must still be captured as the report).
- A Worker that is alive but quiet past a threshold is flagged (`quiet for 12m`). It is never killed automatically; there is still no timeout.
- Default output stays one line per Shot. A single per-Brew summary line gives counts (running, queued, done).
- Liveness keeps using the existing process identity, so `running` still means "the Worker process exists".

**Open questions.** Whether to switch the Worker to `--mode json` (richer activity, but the report must be reassembled from events) or to rely on Station changes and a Worker heartbeat file; whether `status` should offer a follow mode (`--watch`).

**Gate.** Tests show a running Shot with recent activity, a running Shot that has been quiet past the threshold, and a dead Worker, each reported distinctly; output is bounded; a real Brew shows progress while Pi is still working.

### 2. Choose the model and thinking level per task, and publish a Recipe schema

**Problem.** Every Shot uses Pi's default model and thinking level, so a quick edit and a deep analysis cost the same, and there is no machine-readable description of the Recipe.

**Goal.** The Recipe can say which model and thinking level each Shot starts with, and a JSON Schema file describes the whole Recipe.

- Each Shot accepts optional `model` and `thinking` fields. The Recipe accepts optional defaults that Shots inherit, so one line can set them for a whole Brew. A field on a Shot overrides the default.
- `thinking` is one of Pi's levels: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`. `model` is passed to Pi's `--model` as given (Pi accepts a provider/id pattern); Coffee Shop validates that it is a plain token and does not interpret it. Both are passed to Pi as separate arguments, never through a shell.
- The Filter's one-shot review can have its own `model` and `thinking`, because reviewing and building usually want different settings.
- Unknown fields stay rejected, so a typo such as `thinkng` fails loudly instead of being ignored.
- A schema file, `recipe.schema.json` (JSON Schema 2020-12), describes every field. A test validates the example Recipes against it and checks that the schema and the parser agree, so the two cannot drift. There is no schema file in v0.1; the Recipe is validated only in code.
- The chosen model and thinking level are recorded in the Register and shown by `status` and `collect`, so a result can be traced to the settings that produced it.

**Open questions.** Whether `model` should be checked against `pi --list-models` before the Brew starts (earlier failure, but needs Pi at validation time and can be slow); the exact default-inheritance syntax.

**Gate.** Tests cover: a Shot-level setting reaching Pi's argument vector, a default inherited and then overridden, invalid thinking levels and malformed model values rejected before any Station is created, the review settings, and schema/parser agreement. A real Brew confirms a Shot actually starts with the requested model and thinking level.

### 3. Name the repository in the workspace

**Problem.** Everything Coffee Shop names carries "Coffee Shop" and nothing says which repository the work is on. Herdr shows `Coffee Shop brew-20261008T054914Z-1834813` whether the Beans is the Odin book or Coffee Shop itself, so with several Brews open you cannot tell them apart. The same is true of the Git branches (`coffee-shop-<brew-id>-<shot-id>`) and of a plain listing of the state directory.

**Goal.** The Beans repository's name is visible wherever a person looks at a Brew.

- The Herdr workspace label starts with the repository name, for example `odin-in-practice · brew-20261008T054914Z`, so the project is the first thing in the sidebar. The product name is no longer the prefix.
- `status` and `collect` headings show the repository name next to the Brew ID. `collect` already prints the Beans path; this puts the name where it is read first.
- The name is the final component of the Beans repository's root directory, resolved to an absolute path, so `--repo .` and a linked worktree still produce a sensible name. It is sanitized to safe characters and truncated to a fixed length, because it also appears in Git branch names and must not contain `/`.
- Git branches follow the same rule, for example `cs-<repo>-<brew-id>-<shot-id>`. Branch names must stay free of `/`.
- The repository name is stored in the Register, so it is shown even if the directory is later renamed, and Brews created by v0.1 (without a name) still display correctly.

**Open questions.**

- Whether the Brew ID itself should carry the repository slug, so a plain `ls` of the state directory is readable. That changes the ID format again; the current IDs sort by time and old ones must keep working.
- Whether the Recipe may override the name, for a repository whose directory name is not meaningful (for example a checkout called `app`).
- Whether tab labels should change. They sit inside a workspace that already names the repository, so the proposal is to leave `Shot <id>` as it is.

**Gate.** Tests cover name derivation from a relative path, from a linked worktree, from a name with unsafe characters or excessive length, and from an old Register with no name. A real Brew shows the repository name in the Herdr sidebar and in `status` and `collect`.

### 4. Allow up to five Workers at once

**Problem.** v0.1 fixes the Scale at two active Workers. A Recipe with more Shots queues the rest, so wall-clock time is roughly the number of Shots divided by two. The first Odin book Brew had six independent Shots and needed three rounds.

**Goal.** The maximum concurrency is five.

- The Scale limit rises from two to five. Shots beyond the limit still wait in the queue and start as slots free up.
- `status` and the per-Brew summary line show how many Workers are running out of the limit, for example `3 of 5 running, 2 queued`.
- The limit stays a single, visible constant. Nothing else about scheduling changes.

**Open questions.**

- Whether the default stays at two with five as a ceiling the Recipe can opt into (for example an optional `workers` field of 1-5), or whether five becomes the default. Five concurrent Pi sessions mean five times the model usage and rate-limit pressure, so an opt-in is the more cautious choice.
- Whether five is a hard cap or merely the default ceiling, given more Shots can be queued.

**Gate.** An end-to-end test with seven Shots proves that exactly five Workers run at once and two wait, then cancels and checks all seven end cancelled; the existing cancel and recovery tests pass at the new limit. A real Brew confirms five Workers run side by side without exhausting Herdr tabs or the machine.

### 5. Read prompts from files and share common instructions

**Problem.** Today a prompt, and the order, must be an inline JSON string. A realistic prompt is several paragraphs, so the author escapes every quote and newline by hand or generates the Recipe with a script. The first Odin book Brew did the latter: six Shots, about 35 KB of JSON. Worse, a ~3 KB block of shared rules was pasted into every Shot. Repeating shared text in every Shot is not acceptable: it is hard to review, easy to let drift between Shots, and it costs tokens six times. It needs a real solution, not a convention.

**Goal.** Long text lives in plain Markdown files, and text shared by every Shot is written once.

- **`prompt_file`.** A Shot has either `prompt` or `prompt_file`, never both and never neither, for example `{ "id": "durable-files", "prompt_file": "prompts/durable-files.md" }`.
- **`order_file`.** The Recipe has either `order` or `order_file`, with the same rules.
- **Shared instructions.** The Recipe has an optional `preamble` or `preamble_file`: text every Worker receives, written once. It is not repeated in each Shot. The Oreo and `status` show only that a preamble was used, with its file name and size, never the full text.
- **Paths.** A file path is relative to the directory of the Recipe file, not the current directory, so a Recipe works from anywhere. It must stay inside that directory; an absolute path or a `..` that escapes it is rejected.
- **Validation first.** Every file is read once, before any Station or Herdr workspace exists. A missing, unreadable, empty or non-UTF-8 file, or one over the size cap, fails `brew` with an error that names the Shot and the file.
- **One snapshot per Brew, shared by every Worker.** Each file is copied once into the Brew's state directory, and Workers read it from there. Nothing is copied or pasted per Shot. Editing or deleting a source file while the Brew runs changes nothing, and `collect` and recovery never depend on it.

**How `order` and the preamble differ.** Every Worker already receives `Order: <order>` as shared context, so the order is shared today. But the order is also printed in `status`, the Register and every Oreo, so it should stay a short statement of intent that a person reads. The preamble is for long standing rules (coding standards, forbidden actions, how to report) that Workers need and a reader of the Oreo does not. With `order_file`, a long order should be shown in the Oreo as its first paragraph plus a pointer to the full text, not inlined.

**Reading from a common location.** A Shot can already do this by hand today: put the shared rules in one file at a stable path and have each prompt begin "read that file first and follow it". It needs no code, and the Odin book Brew now does exactly that (the book repository's own `workers.md`). It is the right interim answer, and its weaknesses are why the feature is still worth building: nothing guarantees a Worker actually reads the file, the file can change underneath a running Brew, and the rules arrive as ordinary prompt text rather than as standing instructions. Having Coffee Shop deliver one shared snapshot itself removes all three.

**Delivering long text to Pi.** Today the order and prompt travel as one command-line argument, and Linux caps a single argument at 131,071 bytes (measured on this machine: 131,071 bytes is accepted, 131,072 fails with `Argument list too long`). Pi's help shows two options that could avoid the cap: `--append-system-prompt <text or file>` for the shared preamble, and `@file` arguments for message text. The proposal is to deliver the preamble that way, which also means identical shared text per Shot; whether providers then cache the shared prefix is something to measure, not assume. All of this must be verified against Pi `1.1.0` before it is relied on.

**Size limit.** No number is chosen yet. Two facts constrain it: the 131,071-byte argument cap if any text still goes through the command line, and the model's context window. The plan is to decide after measuring: if long text is delivered by file, the cap becomes a sanity limit set from Pi's actual behaviour; until that is verified, treat 128 KiB as the ceiling for anything passed as an argument.

**Open questions.**

- The exact names (`preamble` versus something like `instructions`), and whether a Shot can opt out of the preamble.
- Whether Pi's `@file` and `--append-system-prompt <file>` behave as the help text suggests with `--print` and `--no-session`.
- The size cap, once delivery by file is verified.

**Dependency.** The schema in item 2 must describe the `prompt`/`prompt_file`, `order`/`order_file` and `preamble`/`preamble_file` choices (for example with `oneOf`), and its tests must cover each form.

**Gate.** Tests cover: a prompt, an order and a preamble each read from a file next to the Recipe; resolution relative to the Recipe's directory rather than the working directory; rejection of a missing, empty, non-UTF-8, over-cap and escaping path, and of both or neither of an inline value and a file; a preamble written once reaching every Worker exactly once; and a Brew that still collects after the source files are deleted. No Station is created when validation fails. A real Brew confirms Pi receives the preamble.

### 6. A Shot is completed only when it says it is

**Problem.** Coffee Shop records a Shot as `completed` whenever Pi exits with code 0. Pi in `--print` mode exits 0 whenever its turn ends, and a turn can end without the work being done. Two real Shots in the Odin book Brew did this:

- `ownership-traps` ended its turn with a plan and the question "May I proceed with that design?". Nobody can answer in print mode, so it exited 0 with an empty Changes list.
- `verify-entrypoint` ended with "I fixed the `check` recipe and restarted the requested verification sequence." and no results.

Both were recorded `completed`, and the Oreo's decisions list said nothing. Only the Barista reading every report caught them. A read-only task legitimately changes nothing, so "no changes" alone cannot be the signal, and guessing from the text (for example a trailing `?`) is fragile.

**Goal.** `completed` means the Worker said it finished. Anything else is visible and fails safe.

- **A completion marker.** Coffee Shop appends a short, Coffee Shop-owned instruction to every Worker prompt: finish the final message with a line `CS-DONE` only when the work is complete and verified, or with `CS-BLOCKED: <reason>` when it cannot be. The instruction is not part of the user's prompt and is not repeated in the Recipe.
- **A new terminal state, `incomplete`.** A Worker that exits 0 without `CS-DONE` (a question, a progress note, a missing marker) or with `CS-BLOCKED` ends `incomplete`, not `completed`. `status` and `collect` show it, `collect` exits non-zero as for any non-completed Shot, and the Oreo's decisions list names the Shot and quotes the last lines of its final message or the blocked reason.
- **Fails safe.** If a Worker forgets the marker, the cost is a visible `incomplete` the Barista checks, never a silently accepted result. The marker line is removed from the report that `collect` shows.
- **Optional change expectation.** A Shot may declare `"expect_changes": true` (item 2's schema gains the field). A Shot that says it is done but left its Station unchanged is then `incomplete` too. The default is false, because reading and analysis Shots change nothing.
- **Lifecycle.** `running` may now also move to `incomplete`. The transition table, Brew status derivation (`incomplete` counts as not completed), recovery and cancellation all need updating. A Register from v0.1 is unaffected: only Brews created by v0.2 require the marker.

**Open questions.**

- The marker wording, and whether `CS-BLOCKED` should be its own visible state or fold into `incomplete` with a reason (the proposal is to fold it in).
- Whether Coffee Shop should send one automatic follow-up ("you ended without CS-DONE; continue") to a Worker whose last message looks like a progress note. It would rescue many cases but spends more model time and sits uneasily with "no automatic actions"; the proposal is no.
- Re-running a single Shot. Today this needs a new Recipe and a new Brew, which is what the Odin book Brew did for `ownership-traps`. A command to re-run one Shot of an existing Brew is a natural follow-up, but is not part of this item.
- Delivery: the instruction could ride in the same channel as the shared preamble of item 5 (a system-prompt addition) instead of being appended to the prompt text. Decide with item 5.

**Gate.** Tests with a fake Pi cover: a final message ending in `CS-DONE` is `completed`; a message ending in a question, a progress note, or nothing is `incomplete`; `CS-BLOCKED: reason` is `incomplete` with the reason shown; the marker is stripped from the report; `expect_changes` with and without changes; the transition matrix; Brew status and `collect`'s exit code with an `incomplete` Shot; and recovery of an `incomplete` Shot after the supervisor is killed. A real Brew reproduces the `ownership-traps` situation and shows it flagged instead of completed.

### 7. Per-repository Worker rules

**Problem.** Rules for working in a repository belong to that repository, but while dogfooding the Odin book the Worker rules lived in Coffee Shop's own repo, at an absolute path every prompt had to quote. Coffee Shop gives a Barista no place to put them, and nothing tells Workers to look. The Filter has the matching gap: the book had no `standards.md`, so its review reported "standards.md is missing in the Beans repository; no review was performed".

**Goal.** Each repository owns two plain files at its root, and Coffee Shop makes Workers read them without the Barista having to remember.

- **`standards.md`** (exists in v0.1): what a correct change is. The Filter's review checks against it, and Workers read it.
- **`workers.md`** (new): how an automated Worker must behave in this repository: its scope and the files it must not touch, the commands that verify its work, and the report to give.
- **Automatic delivery.** When a Station contains `workers.md` or `standards.md`, Coffee Shop adds an instruction to every Worker prompt to read them first. The files come from the Station, which is the Beans' base commit, so the rules a Brew ran under are reproducible and a later edit cannot change them.
- **Why not `AGENTS.md`.** Pi already loads `AGENTS.md` from the Station, so it reaches Workers today. But it also governs interactive sessions in the repository, and Worker-only rules such as "never ask for confirmation, nobody will answer" are wrong for a person who is in the loop.
- **Three layers, each with one owner.** The repository owns `standards.md` and `workers.md`. The Brew owns the order, the prompts and the shared preamble of item 5, which describe this piece of work. Coffee Shop owns behaviour that is true for every Worker everywhere (the completion marker of item 6, and "you are not interactive"), so a repository need not repeat it. Until item 6 exists, a repository's `workers.md` carries those two rules itself, as the book's does.

**Open questions.**

- Whether the file is `workers.md` or lives in a `.coffee-shop/` directory.
- What the Oreo says when neither file exists. Today it only reports a missing `standards.md` when the review cannot run.
- Whether a Recipe can name extra files for one Brew, which is item 5's preamble by another route.

**Gate.** Tests cover: a Station with both files, one, and neither; the instruction reaching every Worker's prompt exactly once; the rules coming from the base commit and not from later edits to the Beans; and the Oreo's wording when a file is absent. A real Brew confirms a Worker reads `workers.md` without being told in its prompt.

## Scope guardrails

The first release targets one machine, Pi, and Herdr. Keep task decomposition with the Barista and integration decisions with the developer. Do not add remote workers, other agent harnesses, tmux or zmx backends, a daemon or watcher, Relay, automatic merge, PR creation, publishing, or a general configuration system without a separately approved requirement.
