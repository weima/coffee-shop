# Coffee Shop Implementation Plan

**Reason for existence:** plan and verify Coffee Shop's end-to-end workflow: a main-agent/Barista session receives natural-language Orders (Pi first; Oreo may take this role once stable); a foreground Coffee Shop host starts interactive agent sessions in isolated Herdr workspaces and relays completion or input requests back to the Barista. This plan follows [the architecture](docs/architecture.md) and does not authorize code changes by itself.

## Target user workflow

1. For the first usable path, the developer starts Pi from `~/work/coffee-shop`; this main agent session is the user-facing Barista. Oreo may take this role later once stable.
2. The active main-agent harness starts Coffee Shop from the `coffee-shop` executable or `odin run src`. The foreground controller stays ready for structured dispatch and control requests; it is not a detached daemon.
3. The developer gives the main agent a natural-language task for a repository.
4. The Barista interprets and decomposes the Order, then sends Coffee Shop an explicit Recipe/dispatch request.
5. Coffee Shop creates a Herdr workspace and isolated Git worktree(s), then starts an interactive Pi worker session. Oreo may be evaluated as an alternative only after the Pi-based Coffee Shop flow is usable.
6. The worker changes only its worktree. The developer can follow up in the Herdr pane. `needs_input` and completion events return through Coffee Shop to the main agent; user replies route to the same session.
7. The Barista reports the outcome. A person reviews and controls integration.

**Input boundary:** The active main-agent window receives raw user text. Coffee Shop waits for structured dispatch/control requests and does not interpret Orders. The local transport is still to be selected.

## Current state and gap

The implemented `brew`/`status`/`cancel`/`collect` CLI is one-shot. `brew` accepts a prepared Recipe, runs `pi --mode json --print --no-session` Workers, waits for terminal Shots, and exits. The current activity socket carries best-effort progress only; there is no interactive Worker, persistent foreground control loop, or live `needs_input`/completion bridge to the main agent. The completed slices below are the compatibility foundation, not proof that the target workflow is implemented. Oreo's separate Host/Session work may support a later main or worker harness, but Coffee Shop's first usable path must work with Pi alone and must not depend on Oreo or Rachel.

## Next interactive-workflow phases

| Slice | Result | Gate |
| --- | --- | --- |
| A. Lock the interactive contract | Structured dispatch, session identity, input/result events, transport, and shutdown rules | The main agent can issue a request and address a reply to the correct session without parsing terminal text |
| B. Add the foreground host | Coffee Shop starts from Pi as an executable or `odin run src`, handles multiple requests, and exits cleanly | Fake-client test proves it remains ready between requests; it never daemonizes |
| C. Start interactive Pi sessions | Herdr worker sessions remain open for follow-up and work only in isolated Stations | Fake harness verifies session startup, input, and output without an AI service |
| D. Bridge events and replies | Each Station reports turns to the parent and relays replies to its agent; the host relays Station reports to the main agent | Tests cover turn reports, reply relay, agent exit, duplicate events, and failed delivery |
| E. Persist and recover sessions | Preserve history across host/session close and reopen; report unfinished work honestly | Reopen tests retrieve closed sessions and never replay side effects automatically |
| F. Verify the full workflow | Main-agent Order → Coffee Shop → Herdr → interactive Pi worker → main agent | Full E2E passes on Linux and macOS after phases A–E are green; no allocator-leak warnings |
| G. Optional improvements | Evaluate Oreo for the main or worker agent role, or Rachel as a developer aid, only after the core flow is usable and Oreo is stable | Neither is needed to pass the Coffee Shop usability gate; treat each as a separately approved enhancement |

**Phase E status: implemented.** The host durably records per-request history, lists recovered sessions, reports unconfirmed Stations as unfinished, and performs no automatic replay after restart.

### Station (phase D design)

A **Station** is a `coffee-shop station` process that runs in a Herdr pane for one Shot. It is harness-neutral:

1. It launches the agent command (Pi or Oreo) and speaks the Pi RPC subset on the agent's stdin/stdout: `prompt` in, `agent_end` out.
2. It reports each completed turn to the parent Coffee Shop over the activity socket (`turn_done`, then `agent_exited`).
3. Lines typed into the Station's pane are replies. The Station sends each one to the agent as a follow-up prompt. Closing the pane's stdin ends the agent and the Station.

Each Station runs `pi --mode rpc -e <coffee-shop extension>` next to the user's installed extensions. The extension (`extensions/coffee-shop.ts`) is compiled into the binary and written to `<state>/host/extensions/` at host start. It adds the `coffee_shop_ask` tool, which raises a `select` dialog that reaches the main agent as `needs_input`.

The host relays Station reports to the main agent. Replies go to the Station, never to the host.

Implemented: the `station` command and its fake-agent test (`src/station.odin`); the host listener on `<state>/host/activity.sock`, which relays Station reports to stdout as `station_report` events (`src/host.odin`); and Station panes launched by dispatch in place of raw `pi`. Still to do: replies routed from the host to a Station, `needs_input`, and the report size limit (currently truncated to the activity limit).

## Completed one-shot foundation

The slices below document the existing CLI behavior and its regression gates. All are implemented; retain them for compatibility while the interactive flow is built.

### Slice 0 — Lock contracts before coding

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

**Gate (passed for the one-shot baseline):** The input, CLI, state location and format, lifecycle, cancellation, concurrency, Herdr launch, retention, and Filter contracts above were fixed. These contracts describe the legacy CLI foundation and remain regression requirements; they do not replace the interactive target workflow at the top. Preserve the boundaries: one local machine, Pi, Herdr, no detached daemon, no automatic merge, and no publishing.

### Slice 1 — Establish the Odin CLI shell

- Confirm the Odin compiler and local Pi/Herdr prerequisites needed for development and document the supported environment.
- Create the smallest buildable Odin program and CLI entry point.
- Add command parsing, `--help`, concise diagnostics, and non-zero exit codes for invalid input.
- Keep command handling thin; defer worktree, process, and persistence logic to later slices.

**Gate:** The program builds; help lists the supported commands; invalid or incomplete arguments fail before creating files, worktrees, or processes.

### Slice 2 — Validate Recipes and model work

- Implement the Recipe format and validation from Slice 0.
- Keep the validated Recipe as ordered Shot specifications; add Brew identity and Station paths in the later persistence and worktree slices.
- Validate that the Beans path is a Git repository, Shot identifiers are unique, and required task text is present.
- Reject unsupported or ambiguous input before changing repository or state.

**Gate:** Tests cover a valid Recipe and malformed, incomplete, duplicate, and unsafe path inputs. No invalid Recipe creates a Station or starts a Worker.

### Slice 3 — Add durable Brew state

- Implement the Register as current Brew and Shot status, and the Receipt as append-only status events.
- Centralize allowed state transitions and record each transition with enough context to diagnose failures.
- Make state writes resilient to interruption; preserve the last valid state and report corrupt or conflicting records as incomplete/unknown.
- Make repeated reads and state updates safe; do not turn uncertainty into success.

**Gate:** Tests cover every allowed transition, reject invalid transitions, reload state in a fresh process, and verify malformed or interrupted writes do not erase valid evidence.

### Slice 4 — Create Stations and dispatch Workers

- Create one Git worktree per Shot, with no shared Station between Workers in a Brew.
- Create one Herdr workspace per Brew and one tab per Shot; start each Pi Worker in its Station.
- Add an internal Worker subcommand that accepts validated Brew/Shot IDs, loads task data from state, and starts Pi with an argument vector. Keep prompts out of Herdr's command string.
- Keep a per-Brew supervisor active only for the lifetime of `brew`; maintain at most two Workers and start queued Shots as slots open. Continue queued independent Shots after a failure; cancelling the Brew cancels queued Shots and interrupts active Workers.
- Record each Station path, Herdr workspace/tab identity, launch result, and process outcome.
- On partial launch failure, record which Shots started and leave their Stations available for inspection.
- A Recipe may assign a normal Shot to add unit/component or end-to-end tests from the target repository's `standards.md`. Supply the Taste-Driven Development skill as Worker guidance without installing it into the target repository; do not create a special test-authoring component.
- Keep shell command construction out of the task-data path.

**Gate:** A local test with a temporary Git repository and fake Pi executable proves two Shots use distinct worktrees and Herdr tabs. Tests cover missing executables, Herdr launch failure, and non-zero Worker exit without contacting GitHub or an AI service.

### Slice 5 — Report status and recover

- Implement `status` using Register/Receipt records plus available Herdr/process evidence.
- On restart, reconcile persisted state with observable Worker state; mark uncertain work interrupted or unknown, never completed without evidence.
- Implement the cancellation behavior selected in Slice 0 and record its outcome.
- Ensure status and cancellation can be repeated without duplicating or hiding events.

**Gate:** Tests simulate restart, missing sessions, stale records, and repeated cancellation. Status distinguishes completed, failed, active, and uncertain Workers correctly.

### Slice 6 — Collect results and prepare the Tray

- Implement `collect` to gather each Shot's report and Filter evidence.
- Run a separate one-shot, read-only Pi review of the selected changes against the Beans repository's root `standards.md`.
- Discover unit/component and end-to-end test commands from the repository's existing manifests and test configuration, then run them unchanged. For MFEs, use Playwright only for browser behavior that unit/component tests cannot prove, following the repository's conventions.
- Report review findings, missing standards, ambiguous test commands, unavailable setup, and test failures explicitly. Filter does not fix code, override commands, or hide findings.
- Build the Tray from Worker reports and Filter evidence. Identify any decisions needed from the developer. Do not merge, publish, or remove unreviewed Stations.
- Make collection repeatable without losing or duplicating evidence.

**Gate:** Tests cover successful, failed, and missing reports; review against `standards.md`; test discovery without command overrides; failing or unavailable test evidence; and repeated collection. The Tray reports every Shot outcome, evidence, and unresolved decision.

### Slice 7 — Verify the vertical slice and dogfood

- Run Odin compiler checks and the focused tests for input validation, state transitions, process boundaries, recovery, and collection.
- Run a local end-to-end Brew with fake Workers in a temporary repository. Verify status after restart and collect a Tray.
- Run one small real Pi dogfood task only after the fake-worker workflow passes; keep it local and review the returned Station manually.
- Update the README with verified prerequisites, commands, workflow, and limitations.

**Release gate:** A multi-Shot Brew completes without GitHub access or a second coordinator; Stations remain isolated and available for human review; the Register and Receipt survive restart; the Tray contains check evidence; documentation matches observed behavior.

## Verification status

Slices 0–7 are implemented. `just test` runs 93 tests, including four end-to-end tests (`src/e2e_test.odin`) that drive the real binary with fake `herdr` and `pi`. The interactive workflow at the top of this plan is not implemented or verified; the evidence below applies to the one-shot foundation. Everything below was also run by hand against real Herdr and Pi, with up to three Shots and two Workers in parallel, from inside a Herdr pane and from a plain terminal with every `HERDR_*` variable removed.

| Release gate | Evidence |
| --- | --- |
| A multi-Shot Brew completes without GitHub access or a second coordinator | End-to-end test: three Shots, one failing, no network. Live Brews with real Pi. |
| Stations remain isolated and available for human review | End-to-end test: each Shot's output exists only in its own Station and never in the Beans repository; one Herdr tab per Shot. Nothing is deleted by `collect`. |
| The Register and Receipt survive restart | End-to-end tests run `status` and `collect` as fresh processes, then kill the supervisor with `SIGKILL` and recover both Shots' results. A third test cancels a running Brew: Workers end, queued Shots are cancelled, and a repeat `cancel` changes nothing. A fourth shows `brew` exiting 1, with the Brew ID and Herdr's message, when no Herdr server is running. |
| The Tray contains check evidence | End-to-end test: review text, a passing `make test`, the failing Shot's reason, and the decisions list. A repeat `collect` is byte-identical. |
| Documentation matches observed behaviour | README requirements, usage and limitations were written from the runs above. |

**macOS arm64 verification (2026-10-10).** `odin check src`, `odin build src`, and `TZ=UTC odin test src -define:ODIN_TEST_THREADS=1` pass with the pinned Odin `dev-2026-10` compiler; all 160 tests passed. A real, read-only Pi/Herdr smoke Brew (`brew-20261010T024929Z-4106`) passed with Pi `1.1.0` and Herdr `0.9.3`: its Shot completed, `status` and `collect` succeeded, and it made no Station changes. Filter correctly reported that there were no changes to review and no test configuration in the fixture. The temporary smoke repository and retained Brew state remain under `/private/tmp/csmr` and `/private/tmp/csms` for inspection.

Known gaps, deliberately not hidden:

- Linux, WSL and macOS are supported. Linux process identity uses `/proc`; macOS uses Darwin's process-usage API. Native Windows is unsupported.
- Task decomposition, merging, publishing and cleanup stay manual by design.

## Verification and implementation references

Use the [Odin in Practice](https://github.com/weima/odin-in-practice) chapters as implementation references:

- [Odin foundations](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/odin-foundations.md) — package structure and build loop.
- [CLI and Linux](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/cli-linux.md) — CLI contracts, argument parsing, errors, allocators, environment, and child processes.
- [Memory and error philosophy](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/memory-philosophy.md) — ownership, allocation lifetime, error handling, and rollback boundaries.
- [Parallel programming](https://github.com/weima/odin-in-practice/blob/main/docs/chapters/parallel-programming.md) — bounded concurrency, cancellation, and completion evidence.

Pass child-process arguments as an argument vector. Distinguish a launch error from a Worker that starts and exits with an error. Give each allocated buffer and operating-system resource a clear owner.

## Roadmap: v0.2.0

These items document the one-shot v0.2 foundation built by dogfooding v0.1 on the [Odin in Practice](https://github.com/weima/odin-in-practice) book. They are compatibility contracts, not the target interactive loop above. Items 2–7 are implemented in this Station; acceptance gates not run are explicitly marked pending below. Blend remains a separate proposal and is out of scope.

### 1. Show that a Worker is alive — implemented

**Problem.** Workers run `pi --print`, which prints only its final answer. A running Worker's pane shows just the command line, and `status` says only `running`, so a busy Worker and a dead one look the same for the first ten minutes or more.

**Goal.** A small progress report that answers "is it alive, and what is it doing?" without flooding the terminal.

- `status` shows, for each running Shot, one line with: time running, time since the last activity, and a short description of that activity when known. For example `alpha  running  4m12s  active 8s ago`.
- Activity is evidence, not a guess. Candidate signals: the newest file change in the Station, and Pi's own event stream (`pi --mode json` reports tool calls and messages; the Worker would keep the latest one, and the final answer must still be captured as the report).
- A Worker that is alive but quiet past a threshold is flagged (`quiet for 12m`). It is never killed automatically; there is still no timeout.
- Default output stays one line per Shot. A single per-Brew summary line gives counts (running, queued, done).
- Liveness keeps using the existing process identity, so `running` still means "the Worker process exists".

**Implementation.** Workers parse Pi's JSON event stream and send bounded summaries over a per-Brew Unix-domain stream socket. The supervisor persists the latest event per Shot; `status` shows elapsed time, activity age, and description on one line. Activity is best-effort and never changes process-identity liveness. A Worker quiet for 12 minutes is marked quiet, not killed. The final assistant response remains the collected report. There is no `--watch` mode.

**Verification.** `TZ=UTC just test` passed all 115 tests; `just check` and `just build` pass. Real-Pi Brew `brew-20261008T163704Z-2395480` showed live activity in `status` while its Shot was running and then collected the final report successfully; the Station had no changes. A fake-Pi end-to-end test verifies tool activity is visible before Pi exits.

### 2. Choose the model and thinking level per task, and publish a Recipe schema — implemented; gate partial

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

### 3. Name the repository in the workspace — implemented; gate partial (real Herdr pending)

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

### 4. Allow up to five Workers at once — implemented; gate partial

**Problem.** v0.1 fixes the Scale at two active Workers. A Recipe with more Shots queues the rest, so wall-clock time is roughly the number of Shots divided by two. The first Odin book Brew had six independent Shots and needed three rounds.

**Goal.** The maximum concurrency is five.

- The Scale limit rises from two to five. Shots beyond the limit still wait in the queue and start as slots free up.
- `status` and the per-Brew summary line show how many Workers are running out of the limit, for example `3 of 5 running, 2 queued`.
- The limit stays a single, visible constant. Nothing else about scheduling changes.

**Open questions.**

- Whether the default stays at two with five as a ceiling the Recipe can opt into (for example an optional `workers` field of 1-5), or whether five becomes the default. Five concurrent Pi sessions mean five times the model usage and rate-limit pressure, so an opt-in is the more cautious choice.
- Whether five is a hard cap or merely the default ceiling, given more Shots can be queued.

**Gate.** An end-to-end test with seven Shots proves that exactly five Workers run at once and two wait, then cancels and checks all seven end cancelled; the existing cancel and recovery tests pass at the new limit. A real Brew confirms five Workers run side by side without exhausting Herdr tabs or the machine.

### 5. Read prompts from files and share common instructions — implemented; gate partial (real Pi pending)

**Problem.** Today a prompt, and the order, must be an inline JSON string. A realistic prompt is several paragraphs, so the author escapes every quote and newline by hand or generates the Recipe with a script. The first Odin book Brew did the latter: six Shots, about 35 KB of JSON. Worse, a ~3 KB block of shared rules was pasted into every Shot. Repeating shared text in every Shot is not acceptable: it is hard to review, easy to let drift between Shots, and it costs tokens six times. It needs a real solution, not a convention.

**Goal.** Long text lives in plain Markdown files, and text shared by every Shot is written once.

- **`prompt_file`.** A Shot has either `prompt` or `prompt_file`, never both and never neither, for example `{ "id": "durable-files", "prompt_file": "prompts/durable-files.md" }`.
- **`order_file`.** The Recipe has either `order` or `order_file`, with the same rules.
- **Shared instructions.** The Recipe has an optional `preamble` or `preamble_file`: text every Worker receives, written once. It is not repeated in each Shot. The Tray and `status` show only that a preamble was used, with its file name and size, never the full text.
- **Paths.** A file path is relative to the directory of the Recipe file, not the current directory, so a Recipe works from anywhere. It must stay inside that directory; an absolute path or a `..` that escapes it is rejected.
- **Validation first.** Every file is read once, before any Station or Herdr workspace exists. A missing, unreadable, empty or non-UTF-8 file, or one over the size cap, fails `brew` with an error that names the Shot and the file.
- **One snapshot per Brew, shared by every Worker.** Each file is copied once into the Brew's state directory, and Workers read it from there. Nothing is copied or pasted per Shot. Editing or deleting a source file while the Brew runs changes nothing, and `collect` and recovery never depend on it.

**How `order` and the preamble differ.** Every Worker already receives `Order: <order>` as shared context, so the order is shared today. But the order is also printed in `status`, the Register and every Tray, so it should stay a short statement of intent that a person reads. The preamble is for long standing rules (coding standards, forbidden actions, how to report) that Workers need and a reader of the Tray does not. With `order_file`, a long order should be shown in the Tray as its first paragraph plus a pointer to the full text, not inlined.

**Reading from a common location.** A Shot can already do this by hand today: put the shared rules in one file at a stable path and have each prompt begin "read that file first and follow it". It needs no code, and the Odin book Brew now does exactly that (the book repository's own `workers.md`). It is the right interim answer, and its weaknesses are why the feature is still worth building: nothing guarantees a Worker actually reads the file, the file can change underneath a running Brew, and the rules arrive as ordinary prompt text rather than as standing instructions. Having Coffee Shop deliver one shared snapshot itself removes all three.

**Delivering long text to Pi.** Today the order and prompt travel as one command-line argument, and Linux caps a single argument at 131,071 bytes (measured on this machine: 131,071 bytes is accepted, 131,072 fails with `Argument list too long`). Pi's help shows two options that could avoid the cap: `--append-system-prompt <text or file>` for the shared preamble, and `@file` arguments for message text. The proposal is to deliver the preamble that way, which also means identical shared text per Shot; whether providers then cache the shared prefix is something to measure, not assume. All of this must be verified against Pi `1.1.0` before it is relied on.

**Size limit.** No number is chosen yet. Two facts constrain it: the 131,071-byte argument cap if any text still goes through the command line, and the model's context window. The plan is to decide after measuring: if long text is delivered by file, the cap becomes a sanity limit set from Pi's actual behaviour; until that is verified, treat 128 KiB as the ceiling for anything passed as an argument.

**Open questions.**

- The exact names (`preamble` versus something like `instructions`), and whether a Shot can opt out of the preamble.
- Whether Pi's `@file` and `--append-system-prompt <file>` behave as the help text suggests with `--print` and `--no-session`.
- The size cap, once delivery by file is verified.

**Dependency.** The schema in item 2 must describe the `prompt`/`prompt_file`, `order`/`order_file` and `preamble`/`preamble_file` choices (for example with `oneOf`), and its tests must cover each form.

**Gate.** Tests cover: a prompt, an order and a preamble each read from a file next to the Recipe; resolution relative to the Recipe's directory rather than the working directory; rejection of a missing, empty, non-UTF-8, over-cap and escaping path, and of both or neither of an inline value and a file; a preamble written once reaching every Worker exactly once; and a Brew that still collects after the source files are deleted. No Station is created when validation fails. A real Brew confirms Pi receives the preamble.

### 6. A Shot is completed only when it says it is — implemented; gate partial (real Pi pending)

**Problem.** Coffee Shop records a Shot as `completed` whenever Pi exits with code 0. Pi in `--print` mode exits 0 whenever its turn ends, and a turn can end without the work being done. Two real Shots in the Odin book Brew did this:

- `ownership-traps` ended its turn with a plan and the question "May I proceed with that design?". Nobody can answer in print mode, so it exited 0 with an empty Changes list.
- `verify-entrypoint` ended with "I fixed the `check` recipe and restarted the requested verification sequence." and no results.

Both were recorded `completed`, and the Tray's decisions list said nothing. Only the Barista reading every report caught them. A read-only task legitimately changes nothing, so "no changes" alone cannot be the signal, and guessing from the text (for example a trailing `?`) is fragile.

**Goal.** `completed` means the Worker said it finished. Anything else is visible and fails safe.

- **A completion marker.** Coffee Shop appends a short, Coffee Shop-owned instruction to every Worker prompt: finish the final message with a line `CS-DONE` only when the work is complete and verified, or with `CS-BLOCKED: <reason>` when it cannot be. The instruction is not part of the user's prompt and is not repeated in the Recipe.
- **A new terminal state, `incomplete`.** A Worker that exits 0 without `CS-DONE` (a question, a progress note, a missing marker) or with `CS-BLOCKED` ends `incomplete`, not `completed`. `status` and `collect` show it, `collect` exits non-zero as for any non-completed Shot, and the Tray's decisions list names the Shot and quotes the last lines of its final message or the blocked reason.
- **Fails safe.** If a Worker forgets the marker, the cost is a visible `incomplete` the Barista checks, never a silently accepted result. The marker line is removed from the report that `collect` shows.
- **Optional change expectation.** A Shot may declare `"expect_changes": true` (item 2's schema gains the field). A Shot that says it is done but left its Station unchanged is then `incomplete` too. The default is false, because reading and analysis Shots change nothing.
- **Lifecycle.** `running` may now also move to `incomplete`. The transition table, Brew status derivation (`incomplete` counts as not completed), recovery and cancellation all need updating. A Register from v0.1 is unaffected: only Brews created by v0.2 require the marker.

**Open questions.**

- The marker wording, and whether `CS-BLOCKED` should be its own visible state or fold into `incomplete` with a reason (the proposal is to fold it in).
- Whether Coffee Shop should send one automatic follow-up ("you ended without CS-DONE; continue") to a Worker whose last message looks like a progress note. It would rescue many cases but spends more model time and sits uneasily with "no automatic actions"; the proposal is no.
- Re-running a single Shot. Today this needs a new Recipe and a new Brew, which is what the Odin book Brew did for `ownership-traps`. A command to re-run one Shot of an existing Brew is a natural follow-up, but is not part of this item.
- Delivery: the instruction could ride in the same channel as the shared preamble of item 5 (a system-prompt addition) instead of being appended to the prompt text. Decide with item 5.

**Gate.** Tests with a fake Pi cover: a final message ending in `CS-DONE` is `completed`; a message ending in a question, a progress note, or nothing is `incomplete`; `CS-BLOCKED: reason` is `incomplete` with the reason shown; the marker is stripped from the report; `expect_changes` with and without changes; the transition matrix; Brew status and `collect`'s exit code with an `incomplete` Shot; and recovery of an `incomplete` Shot after the supervisor is killed. A real Brew reproduces the `ownership-traps` situation and shows it flagged instead of completed.

### 7. Per-repository Worker rules — implemented; gate partial (real Worker reading pending)

**Problem.** Rules for working in a repository belong to that repository, but while dogfooding the Odin book the Worker rules lived in Coffee Shop's own repo, at an absolute path every prompt had to quote. Coffee Shop gives a Barista no place to put them, and nothing tells Workers to look. The Filter has the matching gap: the book had no `standards.md`, so its review reported "standards.md is missing in the Beans repository; no review was performed".

**Goal.** Each repository owns two plain files at its root, and Coffee Shop makes Workers read them without the Barista having to remember.

- **`standards.md`** (exists in v0.1): what a correct change is. The Filter's review checks against it, and Workers read it.
- **`workers.md`** (new): how an automated Worker must behave in this repository: its scope and the files it must not touch, the commands that verify its work, and the report to give.
- **Automatic delivery.** When a Station contains `workers.md` or `standards.md`, Coffee Shop adds an instruction to every Worker prompt to read them first. The files come from the Station, which is the Beans' base commit, so the rules a Brew ran under are reproducible and a later edit cannot change them.
- **Why not `AGENTS.md`.** Pi already loads `AGENTS.md` from the Station, so it reaches Workers today. But it also governs interactive sessions in the repository, and Worker-only rules such as "never ask for confirmation, nobody will answer" are wrong for a person who is in the loop.
- **Three layers, each with one owner.** The repository owns `standards.md` and `workers.md`. The Brew owns the order, prompts, and shared preamble of item 5. The legacy one-shot Worker contract owns the completion marker of item 6 and has no mid-run input channel. This rule does not apply to target interactive sessions: they must surface `needs_input` and accept a routed reply.

**Open questions.**

- Whether the file is `workers.md` or lives in a `.coffee-shop/` directory.
- What the Tray says when neither file exists. Today it only reports a missing `standards.md` when the review cannot run.
- Whether a Recipe can name extra files for one Brew, which is item 5's preamble by another route.

**Gate.** Tests cover: a Station with both files, one, and neither; the instruction reaching every Worker's prompt exactly once; the rules coming from the base commit and not from later edits to the Beans; and the Tray's wording when a file is absent. A real Brew confirms a Worker reads `workers.md` without being told in its prompt.

### v0.2.0 implementation decisions and evidence

- Model inheritance uses Recipe-level `model`/`thinking` defaults with Shot-level overrides; the Filter has independent `review_model`/`review_thinking`. Models are plain argv tokens and are not preflighted against `pi --list-models`. `recipe.schema.json` describes the strict JSON surface.
- Repository naming uses the sanitized final component of the resolved Beans path. Brew IDs stay time-sortable and unchanged; Recipes cannot override the repository name; Shot tab labels stay `Shot <id>`. Old Registers without a repository name retain a derived display name and their legacy branch display.
- Scale defaults to two; `workers` opts into 1–5. Five is the hard cap.
- `order_file`, `prompt_file`, and `preamble_file` are Recipe-directory-relative and reject traversal/absolute paths. Their text is validated before Station creation and retained in Brew state; the preamble is delivered through Pi 1.1.0 `--append-system-prompt <text>`. Pi's 1.1.0 help confirms text/file support and `@file` support; Coffee Shop does not rely on `@file`, instead passing bounded text as argv.
- Workers finish with `CS-DONE` or `CS-BLOCKED: <reason>`. Missing/blocked markers produce `incomplete`; no automatic follow-up is sent. v0.1 Registers do not require markers.
- Root `workers.md` and `standards.md` are instructed once in each Worker prompt when present; `AGENTS.md` remains Pi-managed.
- Evidence run for this implementation: `TZ=UTC just test` (129 tests passed on three consecutive runs), `just check`, and `git diff --check` pass. The seven-Shot cancellation gate is now a test: five Workers run and two queue, and cancellation settles in about 4 seconds with a modelled 4-second exit delay. Cancellation was slow because the supervisor waited for each Worker in turn; it now waits once on a shared deadline. Two concurrency defects found while running the suite in parallel are fixed: a Worker's exit could be recorded before its result was read, and concurrent processes could read the Register and Receipt mid-write. Processes now take `state.lock` (shared for reads, exclusive for writes), which passed 12 of 12 e2e-subset runs where the earlier build failed about one run in ten. Still not covered: file size/UTF-8/empty/missing cases, schema/parser equivalence beyond `review_model`, all repository slug variants, change expectation, recovery of incomplete outcomes, policy-file variants/base-commit stability, and every collect outcome. Real-Pi/Herdr gates for model settings, preamble delivery, the real incomplete-response scenario, and the real seven-Shot cancellation were not run. No Blend code was added.

**Real Herdr and Pi runs (2026-10-08, model `github-copilot/claude-haiku-4.5`, thinking off).** Each run used real Herdr and real Pi, from a Beans repository with root `standards.md` and `workers.md`.

- Item 3, Herdr label: the workspace read `repo · brew-20261008T231727Z-3375987`.
- Item 7, Worker rules: the Shot's prompt did not mention `workers.md`. The Worker created `proof.txt` containing `HELLO` (brew-20261008T231727Z-3375987).
- Item 5, preamble: Pi received the preamble. The Shot reported `PREAMBLE-OK` (brew-20261008T231935Z-3381856).
- Item 6, completion: a Shot told to finish with `CS-BLOCKED` ended `incomplete` with the reason shown, while the other Shot in the same Brew completed (brew-20261008T231935Z-3381856). The first run of this check showed `missing CS-DONE` instead of the reason. That was fixed: a block line followed by other text now names its reason, and a unit test covers it.
- Item 4, five Workers: five Shots started within about 0.2 seconds of each other, so all five ran at once (brew-20261008T232006Z-3383324).
- Item 2, model and thinking: the Tray records the requested model and thinking level. That the Shot ran on that model was not checked.
- Item 8, server: each run used the per-repository server. The idle-exit behaviour is covered by an end-to-end test; killing the server during a real run was not done.

Authoring note: a preamble that asks for a line after the completion marker conflicts with the marker rule. The marker must still end the final message, so the preamble must ask for its line before the marker.

Gates still not exercised for real: item 6 with a live Pi failure, and the model check in item 2.

### 8. Coordinate Brew state through one server per resource — implemented (stages 1–5 of 5); real-run evidence in the v0.2 section above

**Stage 3 as built.** `src/server_api.odin`: one request and one response per connection, each a JSON line on `server.sock` in the server's directory. Two operations: `snapshot` returns the Register; `transition` changes one Shot through `transition_shot`. Every request must name a Brew of the server's repository and carry that Brew's token. A socket path longer than the Unix limit is refused at open; the server directory name therefore must stay short, and a long `CS_STATE_DIR` can exceed the limit. **Stage 4 as built.** `brew`, `status`, `cancel`, `collect` and Workers reach Brew state only through the repository's server. A client that cannot reach it starts it (`__server`), retries up to six times with a half-second pause, then aborts with the cause. There is no fallback to files. `state.lock` is removed; the server is the only writer after launch. `brew` creates a Brew's files before its first Worker exists. Commands read only the repository path and Brew token from `register.json`, to find their server. The server exits after 30 seconds with no active Brew. Stage 5 adds startup replay of the Receipt and the kill-mid-write and simultaneous-start gates.

**Decision.** Workers keep writing their result file, and the supervisor keeps its 100 ms poll. A push from the Worker would save at most about 100 ms per Shot, and it would add a second result path. Revisit only if measurements show the poll matters.

**Problem.** The supervisor, Workers, and the `status`, `cancel` and `collect` commands all read and write `register.json` and `receipt.ndjson`. Writes are serialized by `state.lock`. That is correct, but every process must follow the locking protocol, and a reader has no consistent snapshot unless it takes the lock. Different repositories, such as GAC and MFE, need separate coordination, so each repository needs its own server.

**Goal.** One server per resource (a Beans repository) serializes all writes to the Brews on that repository and answers reads over its Unix socket. The files stay the source of truth. Servers for different repositories run independently.

**Layout.**

```
~/.coffee-shop/
  brew-<id>/                 one per Brew, unchanged
    register.json            Register, including the Brew token
    receipt.ndjson           Receipt
    state.lock               retired in stage 4, when the server becomes the only writer
  servers/<name>-<hash>/     one per resource
    server.json              pid, start time, generation, last heartbeat, socket path, repository path
    server.lock              election lock for this resource
    server.sock              Unix socket
```

`<hash>` is derived from the absolute repository path, so two repositories with the same name do not collide. There is no global index file: a command finds its server from its repository path.

**Identity.**

- Brew token: `<brew-id>-<guid>`, a random GUID appended to the Brew ID, written to `register.json` when the Brew is created and unchanged for the Brew's life. Workers receive it at launch, together with their server's socket path. It lets a server and its Workers recognise each other within one Brew. It is not a security measure; the socket is user-only.
- Server id: `<name>-<hash>`, the name of the server's directory. It is derived from the repository's absolute path, so it is the same on every start, and it survives a deleted `server.json`. A restarted server keeps its id. Workers are launched with the server id and socket path, and both are unchanged by a restart, so Workers from before the restart still reach the server.
- Server generation: a counter in `server.json`, incremented on each start under `server.lock`. It counts restarts for diagnosis only; no Worker or client relies on it.
- A request carrying another Brew's token, or aimed at a server for a different repository, is rejected.
- Election and liveness: a server is alive while it holds `server.lock`. Commands test liveness by trying that lock without waiting; the heartbeat in `server.json` is for display and diagnosis only.
- `state.lock` is retired in stage 4. The server serializes all writes after launch, so no lock is needed between processes.
- Election lock identity: a lock belongs to the file it was taken on. A server stops, without touching the socket path, once its lock file is no longer the one at its path (the directory was removed and recreated). Found by the killed-server gate: a live server from an earlier test kept its lock on a deleted file, and a new server acquired a second lock on the recreated one.

**Lifecycle.**

- Heartbeat: the server rewrites `server.json` about once a second.
- Start: a command or Worker that finds no live server (heartbeat stale or process gone) starts one. Only one start wins: the new server takes an exclusive `flock` on `server.lock` before writing `server.json`.
- Startup recovery: before serving, the server replays Receipt events that are ahead of the Register, so a crash between the two writes is repaired.
- Idle exit: the server exits after a timeout (default 30 seconds) with no non-terminal Brew on its repository. The next command restarts it. There is no global daemon.
- No fallback. Every reader and writer of Brew state goes through the server. If the server cannot be reached, the client waits and retries a fixed number of times (starting the server if none is running), then aborts with an error that names the cause, such as a socket path that is too long or a directory that cannot be written. Commands never read or write `register.json` directly.
- A Brew uses exactly one server, for its repository. Cross-repository Brews are out of scope.

**Gate.**

- Killing the server mid-write, then running any command, restarts it, and the Register matches the Receipt after replay.
- Two simultaneous starts for one repository yield exactly one server. A different repository gets its own server.
- A request carrying another Brew's token is rejected.
- A Worker keeps working across a server restart without any change to its launch parameters.
- A server with no active Brew exits within the timeout, and the next command restarts it.
- `status` works with the server absent.
- The full suite passes three times in a row without a flake.

## Deferred roadmap: v0.3.0

After the interactive workflow is verified, Coffee Shop may act as a human manager: a developer delegates several tasks at once, each Brew produces its own reviewable commit, and five tasks run side by side. That needs two things. It must stay fast enough that the machine does not stall with five Workers running, and it must stay cheap enough that a day of running does not run up a model bill. Both need measurements before anything is tuned, so profiling comes first.

### 1. Profile the code with Spall

- Use `core:prof/spall` (Odin's Spall trace format) to span: CLI commands, Brew dispatch, server request handling, Register and Receipt writes, the Worker loop, Pi JSON parsing, settle, Filter checks, Git worktree creation, and Herdr calls.
- Off by default with no cost when off. A `CS_SPALL_FILE` environment variable names the trace file, as `CS_LOG_LEVEL` does for logs.
- **Gate.** A trace of a five-Shot Brew opens in the Spall viewer, and the top spans are recorded in this section with their share of wall time.

### 2. Profile the resource use

- Sample each process of a Brew (supervisor, server, Workers, Pi children): CPU time, resident memory, open file descriptors, and child process count, from `/proc`.
- Show them with `status --usage`, with per-Brew totals.
- **Gate.** Five concurrent Shots run on this machine with a recorded peak CPU and memory budget, and the default concurrency is chosen from those numbers, not guessed.

### 3. Account for tokens and cost

- Confirm which usage fields Pi 1.1.0 reports in its JSON events before relying on them.
- Record per Shot: model, input, output and cache tokens, and estimated cost. Keep these in the Register and Receipt, and show running totals in `status` and in the Tray.
- Optional Recipe budget, in tokens or estimated cost. A Brew launches no new Shot once it is reached. Whether running Shots finish or are cancelled is an open question.
- **Gate.** For a real Brew, the recorded tokens match the provider's usage for the same run, within a stated tolerance.

### 4. Five tasks at once, one commit each

- A Scale limit that spans every Brew on the machine, not just one Brew, so five tasks cannot exceed the budget from item 2 together.
- Each task's changes become their own commit, made by a Pull after it passes Taste (see item 5). Blend then combines a Brew's commits into one.
- **Gate.** Five Brews for five tasks run together. Each produces one commit on its own branch, and none of them interferes with another.

### 5. Research, then execute in small commits

A Brew for an Order that is too large to brew in one go runs in five steps:

1. **Grind.** The Barista splits the Order into very small pieces and tags each as research or execution. This is the Grinder step from the vocabulary, applied before Shots are created.
2. **Cupping.** A Cupper is a Worker running a research Shot. Cupping has no side effects, like a pure function: it reads the repository and returns findings, and nothing else changes. It runs Pi with read-only tools only (`read`, `grep`, `find`, `ls`, as the Filter's review already does), so it cannot write files, run shell commands, or touch package caches. Its findings are the Shot report, which the supervisor records as it records any other report. A Cupping Shot whose Station changes anyway is `incomplete`.
3. **Dial-in.** The Barista summarises the Cupping notes, decides which pieces can be executed, and re-splits the parallel ones into Pulls. Dependent pieces stay in sequence.
4. **Pull.** A Pull is an execution Shot, run by a Worker in its own Station. Before it commits, the Worker runs its verification commands and must pass them; this check is the **Taste**. Each Pull that passes Taste makes its own commit on its own branch. A Pull that fails Taste is `incomplete` and makes no commit.
5. **Blend.** The Barista combines the commits of a Brew's Pulls into one reviewed commit, using the Blend operation. Blend changes the commit history it is given; it does not add work of its own.

Names to avoid for these steps: research (use Cupping), task (use Shot), commit squash (use Blend).

**Gate.** A research-plus-execution Order runs end to end. Cuppers run with read-only tools and leave the Station unchanged, every Pull passes Taste before its commit, and Blend produces one commit whose tree matches the combined Pulls.

### Open questions

- Whether Dial-in is a Barista step only, or can also be a Worker step.
- Where the machine-wide limit is kept, since Brews on different repositories have separate servers.
- Whether a budget stops running Shots or only stops new ones.
- Whether Blend is part of v0.3, since per-task commits depend on it.

## Scope guardrails

The target is one machine, a main-agent/Barista session (Pi first), a foreground Coffee Shop host, and Herdr. Pi is required for the first usable path. Oreo may take the main or worker agent role after the Pi-based flow is usable and Oreo is stable; Rachel is an optional developer aid. Neither is a core dependency. Keep task decomposition with the Barista and integration decisions with the developer. The foreground host is in scope; a detached daemon is not. Do not add remote workers, unrelated agent harnesses, tmux or zmx backends, Relay, automatic merge, PR creation, publishing, or a general configuration system without a separately approved requirement.
