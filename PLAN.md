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

**The interactive workflow is implemented.** A foreground host reads one JSON request per line and creates a Herdr workspace with an isolated Git worktree per Shot; each Shot runs in an interactive Pi **Station** in a pane, reporting every turn over the activity socket and accepting lines typed into its pane as replies to its agent. `needs_input` reaches the main agent, and completion is reported with the commit and hash, the failure, or the reason.

The one-shot `brew`/`status`/`cancel`/`collect` CLI remains as the **compatibility foundation**: it runs `pi --mode json --print --no-session` Workers and exits, and its contracts in the appendix must not regress.

What remains is in **v0.4**: Oreo as the runtime, the code mode's token measurement, the profiling, and the Station tab pool. Oreo's separate Host/Session work may take either agent role, but Coffee Shop's first usable path works with Pi alone and does not depend on Oreo or Rachel.

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

Long prompts travel in per-Shot files, and a Shot may choose a model. Shots open as tabs in one Herdr workspace per repository.

The host relays Station reports to the main agent. Replies go to the Station, never to the host.

Implemented: the `station` command and its fake-agent test (`src/station.odin`); the host listener on `<state>/host/activity.sock`, which relays Station reports to stdout as `station_report` events (`src/host.odin`); and Station panes launched by dispatch in place of raw `pi`. Reports longer than the activity limit are written to `<state>/host/reports/` and relayed in full; the socket carries only the `file:` path. Still to do: dialog timeouts.

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

Slices 0–7 are implemented. `just test` ran 93 tests when these slices landed (277 at the v0.3 release), including four end-to-end tests (`src/e2e_test.odin`) that drive the real binary with fake `herdr` and `pi`. The interactive workflow at the top of this plan is not implemented or verified; the evidence below applies to the one-shot foundation. Everything below was also run by hand against real Herdr and Pi, with up to three Shots and two Workers in parallel, from inside a Herdr pane and from a plain terminal with every `HERDR_*` variable removed.

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

## Appendix: shipped contracts (the one-shot foundation and v0.2)

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

## Roadmap: v0.3.0 — done, and this is the release

Everything below shipped. What remains is v0.4. The per-version contracts that used to live under their own roadmap headings are retained as an appendix at the end of this plan, because they describe behaviour that must not regress — not because the versions matter.

**The Station model.** A Station is a `coffee-shop station` process in a Herdr pane for one Shot, harness-neutral: it launches the agent, speaks the Pi RPC subset, reports each turn over the activity socket, and forwards lines typed into its pane as replies. The host is a foreground process that reads one JSON request per line, creates a Herdr workspace and an isolated Git worktree per Shot, and relays Station reports to the main agent. Exactly one thread reads the input stream; workers never do. Shots open as tabs in one workspace per repository, and long prompts travel in per-Shot files.

**The Shot surface**, all per Shot and validated before anything is created:

| field | contract |
|---|---|
| `id`, `prompt` | required; the id is a safe token, the prompt non-empty |
| `kind` | `execute` or `research`; a research Shot gets a read-only tool allowlist (`read`, `grep`, `find`, `ls`) and can **never** receive `codemode` |
| `taste`, `message` | a Pull runs its Taste before committing and commits only if it passes; a failed Taste is `incomplete` and makes no commit |
| `model`, `thinking` | per Shot; a model is **always** supplied and never a provider-less default |
| `codemode` | `on` or `off`, absent meaning on; an execute Shot gets `--tools +codemode` unless told otherwise, and any other value fails loudly |

**Oreo code mode is built.** Odin is the script language, compiled and run as a short-lived process (measured at 0.15 s, with no standing engine to amortize); `core/odin` is the static gate that refuses imports outside an allowlist, `foreign` blocks and `#load` before anything runs; the runner carries a wall-clock deadline and a bounded output; a process — not a threadpool — is the containment unit; and the `codemode` tool is in Oreo's default tool set and now reaches execute Shots. What it has never had is its *decision*: the token-delta measurement listed in v0.4.

**The working flow ships with it.** Cupping (research Shots that cannot change the Station), Taste before a commit, a Pull whose changes become its own commit only after Taste passes, Blend for combining the 2–20 commits of a multi-Pull run, a Pull → PR operation that verifies recorded Taste evidence and refuses a non-fast-forward, and cleanup that refuses to touch a run whose Station is still alive and names it.

**Reporting and lifecycle.** Every Station reports turn, usage (tokens, and cost when the provider prices the model) and outcome; `status` shows what is in flight and how each Station ended; the register receives a Station's usage and outcome on the production path; a cancelled Station frees what it owns and exits `130`; and the display draws a four-row block in which no row can wrap.

**Evidence.** The flow ran end to end on pi Stations with independent verification of every Pull; five Stations ran in one batch; the suite passes with `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`; and each fix was verified against its commit, with a load-bearing proof wherever a test claimed a property.

**Gates deliberately NOT met, and carried into v0.4:** the flow with Oreo as the runtime; the code mode's token-delta measurement; the profiling this milestone listed; and the two checks in v0.4 item 4.

## Roadmap: v0.4.0 — everything outstanding

v0.3 is concluded, and **everything still live lives here** — one milestone ahead instead of a tail of them.

The shape is unchanged. The flow runs on **pi** Stations first, so it works at the scale it already has; then **Oreo** becomes the runtime, which is what makes hundreds of parallel agents affordable. Oreo has its own plan in `oreo/PLAN.md`.

### 0. Live right now — none of this is in the v0.3 release

Three branches are written, committed and **unmerged**, because each was still awaiting its own verification when v0.3 was cut:

| branch | commit | what it is |
|---|---|---|
| `cs-host-codemode-field-1-cmfield` | `b3d6c5b` | codemode as a per-Shot input instead of a process environment variable |
| `cs-host-oreo-quit-2-oquit2` | `2549f88` | a `quit` wakes a blocked wait instead of waiting out the model timeout |
| `cs-host-oreo-model-1-omodel` | `d536063` | Oreo's provider and model are supplied together, never defaulted |

Still live from v0.3's own dogfooding, and not fixed by any of those:

- **The report relay is a single point of failure.** When the host died mid-session, four Stations kept working and committing while their terminal reports were never relayed; two of those completions were found only by inspecting branches by hand. Panes were the accidental backup. This is item 3.1 below, and it gates the pool.
- **A Station has no model-reply deadline.** A provider response that never arrives hangs the Station and its agent for as long as the turn lasts — measured at over two hours — instead of failing the work item. The Oreo host has such a bound; the pi Station path does not.

### 1. The flow's two open gates

The five steps and their implementations are recorded in v0.3. What remains is what they did not prove, plus two defects that verification found.

**Gate.** A research-plus-execution Order runs end to end: Cuppers run with read-only tools and leave the Station unchanged, every Pull passes Taste before its commit, and Blend produces one commit whose tree matches the combined Pulls. Every part exists and is exercised daily, but the gate has never been run as a single demonstration.

**Gate.** The same run passes with **Oreo as the runtime** (item 2).

Two defects, both found by verification rather than by a failing test, and both open:

- **The Taste is bypassed when an agent commits its own Pull.** The Station then finds a clean tree and reports `taste_passed — no changes` instead of `pulled`, so a Taste that failed would leave a commit behind that looks reviewable.
- **A Shot with no Taste stays interactive by design** (`relay.one_turn = research || taste != ""`), so a verification dispatched without one never ends and holds its tab. Every verification now carries a clean-tree Taste as a workaround; the shape itself is unfixed.

### 2. Oreo as the runtime

**The measurement comes first, because it decides whether any of this is worth building.** v0.5's own gate said so: *"Before any of it is built, measure Pi's own `codemode` on real Stations through the per-Station usage report; if that delta is small, the feature is not worth building in any language."* That measurement has still never been taken, which means the code below was written ahead of its own decision criterion.

- **Measure Pi's `codemode` on real Stations.** The mechanism now exists: the per-Shot `codemode` field runs the same task with and without the tool, and every Station reports `total` tokens. Dispatch the identical task twice and compare. **Gate.** A repeated task shows a material token delta, or v0.5's conclusion is that code mode was not worth building.
- **Oreo's code mode** is the script-based execution model in [oreo/code-mode.md](oreo/code-mode.md): Odin as the script language, compiled and run as a short-lived process (measured at 0.15 s, with no standing engine to amortize); `core/odin` as the static gate that refuses imports outside an allowlist, `foreign` blocks and `#load` before anything runs; a process as the containment unit rather than a threadpool. Containment is platform-dependent — macOS does not enforce `RLIMIT_AS` — so any per-script memory ceiling must be verified on each platform. The assumption to test is **model competence**: Odin is stricter than JavaScript, and every rejected script costs a turn, which is the cost the feature exists to reduce.
- **A per-work-item model route.** Coffee Shop tells Oreo which model to use, per work item, matching the task's complexity; when it has no preference it sends **the model it is itself using**; and in all circumstances it sends one. Oreo must not carry a default of its own. The pi path already does this (`--model` per Shot, defaulting to the orchestrator's own); Oreo's equivalent is the thing to build. **Gate.** No global or provider-less default decides a model anywhere; each work item carries provider and model together, and an incomplete pair fails loudly.

### 3. Station tabs are a pool, not a leak

The design (retired with v0.5 Wave 3): a tab is an **allocated resource**, drawn from a bounded pool and returned for reuse rather than abandoned. This exists because every dispatch created a tab and nothing owned its lifetime: one session left 21 stale panes in the Station workspace, enough that the developer could feel the rendering drag, and the cleanup that followed had to guess from the process list — and closed a pane inside the developer's own workspace while guessing. Lifetime belongs to the **dispatcher**, which knows what an outside script cannot: it allocated the pane, it holds the session table, it receives every report, and it can run a command in an existing pane.

1. **Durable reports first — the prerequisite, not a companion.** Reclaiming a tab assumes the report channel survived the run, and today it does not: when the host died mid-session, four Stations kept working and committing while their terminal reports were never relayed, and two completions were found only by inspecting branches by hand. Panes were the accidental backup. Write each report durably before relaying it, and recover unrelayed ones on restart. **Gate.** Kill the host mid-run; every completion is still reported or recoverable after restart, without reading a pane.
2. **The pool.** Dispatch acquires a tab; a terminal report, or a process gone with no report, makes it reclaimable; the pool is bounded by the concurrency limit and emptied when the host exits. **Gate.** Dispatch more Shots than the limit; the workspace never holds more than the limit of tabs, every Shot still runs, and the run ends with no manual cleanup.
3. **Reuse, not recreate.** Run the next Station command in a freed pane, clearing it and **re-asserting the terminal state** first — auto-wrap on, cursor visible, attributes reset — because the previous occupant may have died mid-draw. **Gate.** A reused tab shows no row from its previous occupant, and two consecutive runs of the same size do not grow the tab count.
4. **A tab that needs a human is pinned.** `needs_input` holds its tab until the question is answered or the run is cancelled, never released by a timeout. **Gate.** A question stays visible and answerable while other Shots are dispatched, and that tab is not reused meanwhile.
5. **Exact recovery after a crash.** The host persists the panes it owns, so recovery closes precisely those instead of inferring from process arguments and directories. **Gate.** Kill the host; recovery reclaims exactly its own tabs and touches no other pane.

### 4. Two checks the flow still needs

6. **A suite never runs concurrently with a Station's own.** Today this is a rule the Barista follows by hand, and this repository has measured what concurrent suites do: failures that vanish on re-run, which is worse than no check because a flake reported as real is a false finding. Make it a check — a lock a suite takes, or the host refusing to dispatch while one is held. **Gate.** Two suites started at once cannot overlap, and the second reports why instead of flaking.
7. **A cancel is honoured even when the reader is mid-write.** The flag cannot interrupt a reply write blocked on a full agent pipe; the old handler's direct `close` would have raised `EPIPE`, and that mechanism was removed because it read a pointer the main flow frees — a use-after-free. Make the cancel effective again without reintroducing that. **Gate.** A Station blocked writing to a full pipe stops promptly, and the use-after-free stays impossible.

### 5. Profiling the host and the Stations

8. **Profile the code with Spall.** Span the host, dispatch, Station startup, the report relay and the Herdr calls; off by default with no cost when off, behind a `CS_SPALL_FILE` variable as `CS_LOG_LEVEL` names logs. **Gate.** A five-Station trace opens in the Spall viewer and the top spans are recorded here.
9. **Profile the resource use.** Sample each Station and each pi child for CPU, resident memory, open file descriptors and child count: from `/proc` on Linux and WSL, from Darwin's process APIs on macOS, marking anything Darwin cannot expose as "to be verified". **Gate.** Five Stations run with a recorded peak CPU and memory budget, and the default concurrency is chosen from those numbers rather than guessed.
10. **A machine-wide concurrency limit** spanning Brews and Stations, so five Stations cannot exceed that budget together. **Gate.** Five Stations run together with no interference, and a sixth waits.

### 6. Residuals carried from dogfooding

11. **The display's remaining edges**, from the v0.6 display fix: assert the **emitted escape bytes** in the `clear` path as well as the draw path, and by suffix or exact sequence rather than presence, since swapping the two emissions currently leaves every test green while the terminal is left with auto-wrap off; emit `DECAWM_ON` once at display start so a pane recovers even after a panic abandons it mid-draw (a panic cannot run `defer`, and the developer's shell otherwise inherits no-auto-wrap until `reset`); and treat control characters other than CR and LF, which can still make a row occupy two visual rows.
12. **`workers.md` and the flow disagree** about committing: the file tells every Worker "Do not commit", while the flow requires the Station to commit the Pull after Taste. An agent obeying the file and an agent committing on its own both occur, and the second bypasses the Taste gate. Decide which is intended and make the two agree.
13. **Active-Station ledger and progress-supervision safeguard.** **Problem:** Station reports land in the host pane, but the coordinator can miss them; a Station can sit at "Waiting for your reply" without the user being told. Panes are not a reliable relay. **Goal:** Surface `needs_input` and stale-Station warnings durably and immediately, so the coordinator relays pending reports before ending a turn. **Implementation:** `progress_ledger.odin` tracks each Station by request_id+shot_id with pane_id, phase, last_progress time, and report kind; `progress_supervision.odin` integrates with the host relay thread, rebuilds the ledger from host history on restart, and emits "needs_input_alert" and "stale_warning" Host_Events to stdout. `progress_supervision_test.odin` covers rebuild, stale detection, needs_input alerting, and terminal settlement; `host_integration_test.odin` verifies events through the real host path. **Coordinator responsibility:** The Barista or supervisor must watch the host stdout event stream, parse JSON events, and relay alerts: on "needs_input_alert", tell the user immediately (do not end turn); on "stale_warning", inform the user (advisory, not auto-cancel). See EVENT_WATCH_PATH.md for precise watch/consume implementation and limitations. **Acceptance criteria:** Every Station tracked durably; needs_input alert and stale warning reach host stdout; coordinator relays alerts before ending turn (operational, not code-enforced); stale warning never auto-cancels (10 min is advisory threshold); host restart rebuilds ledger and resumes detection; relay thread runs in existing host loop with no other changes to Station behavior. **Gate.** Multi-Station dispatch surfaces alerts correctly in stdout; host restart rebuilds ledger; integration tests pass; coordinator documentation is clear about automatic vs. manual relay.

## Roadmap: v0.5.0 — top priority: remove the Herdr dependency

**Priority, decided 2026-10-17.** Removing Herdr is v0.5's first work item. The developer reached this after three days of running Coffee Shop on Windows under WSL2: the difference between macOS and Windows WSL2 is stark enough that removing Herdr outranks everything else in v0.5. That is direct experience, and it outranks the second-hand analysis that first raised the subject, so the ordering no longer waits on a measurement and the redesign must not wait on a release deciding whether the problem is real.

**How to remove it.** Put a pane-backend seam behind the existing `herdr_*` procedures with at least `herdr` and `none`. Land `none` first: a Station's stdio goes to a per-Shot log; the human channel becomes `status`, a log tail, alerts and a routed reply, which the host already accepts; and the pane pool, clearing, reuse and pane-based recovery are deleted, because they exist only to manage scarce and stateful panes. Keep Herdr optional for macOS rather than deleting it in the same step. Do **not** implement a terminal emulator or PTY capture — that is Herdr's slow part, and it is the work being removed. If live multi-pane watching turns out to be essential, tmux is the one to adopt, with its config surface and its daemon as known costs; the guardrails below currently exclude tmux and zmx and would have to be amended deliberately.

**Why this is on the table.** A report (2026-10-17, second-hand analysis, **not reproduced here**) says Herdr performs badly on WSL2 under Windows: Herdr captures terminal input, output and TUI events, which is already costly on native macOS and Linux, and Windows adds the ConPTY layer with different Unicode width tables and VT handling, so scrolling and resizing corrupt layout and slow down. The generic WSL2 factors are separate and worth ruling out first: project files on the Windows side through `/mnt/c` (9P translation) and default resource limits.

The developer's own experience is the decisive evidence here: three days on Windows under WSL2 produced a difference against macOS that is stark enough to reorder the roadmap, so this is not a hypothesis awaiting proof. Local measurements agree in kind: one long session left **21 stale panes** in a Station workspace, enough that the developer could feel the rendering drag on macOS, which is why the tab pool exists (item 3); and the v0.4 five-Station trace shows a dispatch making **thirteen** `herdr call` spans at 6.1 ms mean, so every dispatch pays the terminal manager again and again.

**The measurement now sizes the fix, not the decision.** Record wall-clock time per Shot, host CPU, and the developer-visible responsiveness on WSL2 with the project inside the Linux filesystem, then repeat on macOS, so that the before and after of the removal is a number. Do not spend a release on deciding whether the penalty is real: it has been paid for three days.

**What does not change either way.** The guardrails below still hold until amended deliberately, and this section does not by itself authorise code changes beyond the removal itself.

**What the dependency actually is, measured 2026-10-17.** Twelve operations, and one client:

| Area | Operations |
|---|---|
| Workspace | `workspace create`, `workspace get`, `workspace close` |
| Tab | `tab create`, `tab close`, `tab rename`, `tab list` |
| Pane | `pane run`, `pane close`, `pane get`, `pane process-info` |

`src/dispatch.odin` is the client (57 mentions). The pane *lifecycle* sits in `src/pane_pool.odin`, `src/host_pane_pool.odin`, `src/pane_clear.odin`, `src/host_pool_persistence.odin`, `src/host_dispatch_queue.odin` and `src/host.odin`; `src/pr.odin` finds panes by scanning process arguments; six test files fake Herdr.

**What does not depend on Herdr.** The activity-socket relay, the Station's Pi-RPC pipe protocol, the isolated Git worktrees, the Register, Receipt, reports and Tray, Taste, Blend, the five-Shot concurrency limit (now the machine-wide slot limit of item 10) and the state server all run without it. Herdr supplies *presentation and pane lifecycle*, not the workflow. Removing it removes a layer rather than the product.

**What still needs a replacement, in rough order of difficulty:**

1. **The human channel.** Today the developer watches a pane and types a reply into it, and `herdr workspace focus` is the jump-to affordance. The host already accepts a routed `reply` request, so the routing exists; what is missing is a way to *see* live output and to *type* a reply without a pane.
2. **The pane pool and its recovery.** Reuse, pinning, clearing and exact crash recovery (item 3.3–3.5) exist only because panes are scarce and stateful resources. Removing panes removes most of the need.
3. **`pr.odin`'s pane discovery and cleanup**, which currently identifies a run's panes from process arguments.
4. **Six test files** that fake Herdr, plus `host_contract_test.odin` and the e2e path.

**Open questions this section does not answer.** Whether anything replaces a pane at all — the guardrails exclude tmux and zmx, so dropping Herdr means either no multiplexer or a deliberately amended guardrail. Whether the developer still follows a Shot live, or only reads its report afterwards. And whether the reported WSL2 cost is Herdr at all, which the measurement above settles.

### The work, in waves

Each wave is chosen so that the Shots in it own disjoint files. A Pull that needs a file another Pull in the same wave owns is held to the next wave, because a merge conflict costs more than the wait.

**Wave 1.**

1. **The pane-backend seam.** Today all twelve Herdr operations are called from `src/dispatch.odin`, and the pane lifecycle is spread across `src/pane_pool.odin`, `src/host_pane_pool.odin`, `src/pane_clear.odin`, `src/host_pool_persistence.odin`, `src/host_dispatch_queue.odin` and `src/host.odin`. This Pull defines the interface, routes every call site through it, and **changes no behaviour**: the suite must stay green with the same test count. It also states what a headless implementation must provide, so wave 2 needs no call-site changes.
2. **An Oreo turn must end.** A two-line edit under the Oreo runtime hung for twelve minutes at 0.0% CPU with no reports; the reply deadline did not bound it and a routed cancel did not interrupt it. A turn must complete, fail with a reason, or report `incomplete` on a deadline, and cancel must reach it. The Pi path must not change.
3. **The test-isolation rule, written down.** Three separate flaky fixes in one day had one cause: process-global and machine-global state is shared between tests under a ten-thread runner. The rule belongs in `standards.md`, with the remedies this codebase already uses.

**Wave 2.**

4. **The headless backend.** Station stdio to a per-Shot log, replies through the host's existing `reply` request, no pane pool at all, and the pane-clearing and reuse paths skipped when the backend is headless. Gates: the five-Station run completes headless with five Shots and a sixth waiting; a `needs_input` reply still reaches the Station; a reused backend shows no row from its predecessor.
5. **The human channel.** `status` must name what is running without a pane; a log tail and a `reply` command must exist; the progress ledger's alerts must still fire. Gate: a developer can follow a run and answer a question with no pane and no Herdr server installed.

**Wave 3.**

6. **Delete the pane paths** once nothing uses them, and amend the guardrail line that names Herdr as in scope — deliberately, in its own commit, saying which guarantee is being traded.
7. **Measure the removal.** The same five-Shot run on WSL2 and on macOS, wall-clock per Shot and host CPU, so the before and after is a number rather than a claim.

**Deliberately out of scope for v0.5:** reintroducing a multiplexer. If live multi-pane watching turns out to be essential, that is a new requirement with its own decision, not a fallback built into this one.

## v0.5 completion record (2026-10-31)

**Closed partially, and the record says so.** Five defects were found and fixed, two gates passed, and the release's headline item — deleting the Herdr dependency — **did not happen**. It is carried into v0.6 rather than claimed here.

**Shipped.**

- **Reply delivery without a pane (#142).** The host listens on `<state>/host/requests.sock` (0700 directory, 0600 socket) and accepts only `reply` with exactly its four fields, so a separate `coffee-shop reply` process can answer a Station and no socket request can name a repo, command or path. Exit codes: 0 delivered, 1 no host, 4 socket unreachable, 5 refused. The same change fixed two gaps between #138 and #139: `status --stations` and `log` named `<request>/<shot>.log` while the headless backend wrote `<request>/logs/<shot>.log`, and the headless log kept the **first** bytes of an oversized read instead of the newest, so a run under load lost the tail it was read for.
- **A cancel reaches a turn in flight (#143).** The cancel flag was only read by the typed-input reader; the main flow sits in a blocking read on the agent's stdout, so a Station waiting on a provider reply ignored a cancel until the agent answered or the 30-minute deadline fired. The watchdog thread now stops the agent for a cancel as well as a deadline, and the main flow reaps in bounded steps and escalates SIGTERM → SIGKILL, so a Station can neither block forever on an agent that will not go nor exit and leave it running.
- **The progress ledger owns its keys (#144).** The ledger stored each Station's map key and ids from `context.temp_allocator`, which the host frees every turn, so the first report after a turn compared against freed memory and crashed the host in `string_eq`. This is what ended both v0.5 gate attempts. The ledger now copies its keys and ids and frees them on destroy.
- **One timestamp format, and elapsed-time reporting (#145).** Every host event carries `at` (appended last, so existing field order is preserved) and permanent Station log lines are stamped: RFC 3339 UTC, exactly three millisecond digits. The Five-Station report now prints per-Shot elapsed time from `session_started` to the terminal report, plus the request span.
- **Pi Stations default to `opencode-go/deepseek-v4.1-flash` (#146).** An explicit Shot model still overrides it; Oreo still requires its own provider/model route; one-shot Brew Workers are unchanged.

**Gates.**

- **Headless five-plus-one run: PASS on its own terms.** With `herdr` absent from `PATH` and `CS_PANE_BACKEND=headless`, six Shots reached terminal reports, `gate-s6` went `dispatch_queued` → `dispatch_dequeued` → `session_started`, and 5 Stations started before it. A separate Shot raised `needs_input`, `coffee-shop reply` returned 0, `reply_sent` was recorded, and that Station then reached `taste_passed`. Host exit 0, no error events, request elapsed **145.970 s**, Station memory peaks 283–521 MiB.
- **Sustained-overlap evidence: NOT PROVEN, and one attempt hung.** In the timed run the agents moved their `sleep` into background tasks and exited early, so the five Slots were not held for the intended period. A rerun that put `sleep 90` in the Shot's Taste queued the sixth Shot correctly but never produced its terminal report within 30 minutes: two Stations reported `agent_exited` and then nothing, three logged only their first prompt. The cause is unconfirmed. Treat "five Shots genuinely overlap and the sixth waits for a real slot" as unproven.
- **WSL2/macOS before-and-after measurement: NOT DONE.** It needs the WSL2 machine.
- **Suite:** 395 tests green, no memory failures, at `991612a`.

**Defects found by running the gates rather than by tests:** the ledger use-after-free above; the headless log keeping the wrong end of an oversized read; `status`/`log` pointing at a path the headless backend never wrote; and the hostile load test's request-timeout flake under a 10-thread runner.

**Carried into v0.6:** deleting the Herdr/pane paths (Wave 3 items 6–7 above, still open), the WSL2 measurement, and the unproven sustained-overlap gate.

## v0.4 completion record (2026-10-26)

**Shipped on Pi.** Every gate below was run and its evidence recorded; none is asserted from a summary.

- **Item 1(a), the end-to-end Order: PASS.** Two cuppers left their Stations untouched — no commit and no modified file in either. Two Pulls each passed a Taste *before* committing and each touched exactly one file. Blend produced **one** commit whose tree is identical, file by file, to the two Pulls', with no third file differing.
- **Item 1(b), the same under Oreo: DEFERRED, with a correction to the original finding.** A two-line documentation edit under the Oreo runtime produced **no output for twelve minutes at 0.0% CPU**, and a routed cancel did not interrupt it, so the two processes had to be killed by hand. The first write-up of this said the model-reply deadline *did not bound* the run; **that was wrong**. The bound is `STATION_TURN_DEADLINE_SECONDS :: 1800` — thirty minutes — and the run was killed at twelve, well inside it. The deadline would have ended the turn at thirty. What stands, and is reproducible on the Pi path as well, is that **a cancel does not interrupt a Station blocked waiting on a model reply**: it was requested twice against a blocked Station and had no effect either time. The guardrails make Pi the required path and Oreo optional, so v0.4 ships on Pi. The concrete tasks are therefore: make cancel effective while a turn is in flight, and decide whether a thirty-minute silent wait is an acceptable default.
- **Item 2, the `codemode` measurement: MEASURED, and inconclusive for its purpose.** The same grep-countable task, dispatched twice with byte-identical requests except the `codemode` key: **108,907 against 108,890 total tokens**, a delta of 17 (0.016%), both answers correct, and **both arms answered with `grep`** — the enabled arm never used the tool. That says nothing about the expensive task class the feature targets. A decisive run needs a task where a script replaces many tool calls, plus a check that it was invoked.
- **Item 5.8: PASS on its terms.** Seven trace files — the host plus six Stations — with `station start` at 63.6 ms over 6 spans among the top five (`dispatch request` 716 ms, `herdr call` 93.6 ms over 13 calls).
- **Item 5.9: MEASURED.** Per-Shot Station and tree peaks: tree resident memory **460–520 MiB**, 42–70 descriptors, 2–5 children. CPU is `not measured` on macOS by design. The default concurrency of **5** therefore costs roughly **2.3–2.6 GiB**, which is the number the item asked to choose it from.
- **Item 5.10: PASS.** `gate-s6` queued at event 8, dequeued at 12, started at 13, with five started before it and no failure events.
- **Suite acceptance:** three consecutive runs, 372 tests each, all green; 374 tests green twice more after the process-group fix.

**Defects found by running the gates rather than the tests**, all fixed before the tag: the pane-reclaim gap that stalled any dispatch above five Shots; a zombie leak worth 2248 processes and machine-wide fork failures, caused by the setuid `/bin/ps` whose wait is skipped; fourteen `__server` processes that never idle-exited; a process-group kill that could signal its own caller's group; and process-global test state that made two tests flaky.

**Still open after this release:** the suite lock's dead-holder reclamation, and — per the section below — removing Herdr.

## Roadmap: v0.6.0 — the Barista-to-Station subsystem moves to Go

**Decision, 2026-10-31.** The developer decided to move **orchestration** from Odin to Go: the foreground host loop, the request and activity sockets, dispatch acceptance, the queue and slot accounting, Station process spawning and watching, the per-Shot bounded log, the relay, spool, history and progress ledger. **Odin keeps the actual work**: the CLI, Recipe parsing, Git worktrees, Blend, `pr` and `cleanup`, and the Station's own labour — the agent, its RPC lines and dialogs, the turn deadline, cancel propagation, the Taste and the commit. The reason given is direct: the orchestration substrate has proven hard to get right in raw Odin. The v0.5 record is the evidence: a map key allocated on a temporary allocator crashed the host after its first turn; a cancel could not reach a turn blocked on a model reply; the reap of an agent could block forever; and a bounded log kept the wrong end of an oversized read.

**Decided with it:** `csd` is built from source and embedded in the Odin binary, then written to `<state>/host/bin/` and exec'd, so there is still one user-facing command; the dispatch queue stays in memory and a restart drops it, as v0.5 had it; Go is assumed on the build machine and no Go binary is committed.

**What this is not.** Not a rewrite of Coffee Shop. Recipe parsing, Git worktrees, station directories, Register/Receipt, Taste, Blend, the `pr`/`cleanup` commands, the machine-wide slot files and the one-shot `brew` path stay where they are. This release moves the *orchestration substrate*, because that is where the host-side defects were, and it keeps the wire contract byte-identical so both implementations can run against the same tests.

**Design:** [v0.6 Go subsystem design](docs/plans/2026-10-31-v0-6-go-subsystem-design.md).

**Carried in from v0.5, and part of this release:**

- **Delete the Herdr/pane paths** (v0.5 Wave 3 items 6–7): remove `pane_pool.odin`, `host_pane_pool.odin`'s pool half, `pane_clear.odin`, `pane_backend_herdr.odin`, `host_pool_persistence.odin`'s pane recovery half, the pane branches in `host.odin`, `pr.odin`'s pane discovery, `settle.odin`'s tab close; amend the guardrail that names Herdr as required. Retiring the pane-lifecycle document from that list is already done. The code deletions above remain open. This becomes moot for the moved code and must not be re-implemented in Go: the Go host has **no pane backend**.
- **The sustained-overlap gate** that v0.5 did not prove: five Shots genuinely holding five Slots, with a sixth waiting for a freed one.
- **The WSL2/macOS measurement** of the removal.

**Phases.**

1. **Freeze the wire contract as data.** Turn the host's stdout event shapes, request shapes, socket paths, exit codes, spool and history formats into a written contract plus a black-box conformance test that any implementation can be run against. No behaviour change. **Done (#147, #148).** `go/internal/proto` holds the types with the contract's field order and timestamp shape, `go/internal/conformance` holds the harness, `go/internal/conformance/testdata/recorded-v05-gate.ndjson` plus its golden stream are a real v0.5 gate run, and `CS_CONFORMANCE_CMD='odin run src -- host'` passes against the live Odin host.
2. **The Odin seam.** Add the subcommands Go needs — `prepare` and `release`, alongside the existing `station`, `pr` and `cleanup` — with a JSON failure shape and non-zero exit, so orchestration can drive the work without linking it. **Done (#149).** Both exist (`src/seam.odin`); they validate every path and branch before any Git call, print `{"type":"error","reason":"…"}` on stdout with exit 1, print nothing on success, and `prepare` then `release` is a tested round trip.
3. **The Go orchestrator.** `csd` runs the host: loop, listeners, dispatch, queue, slots, Station spawn and watch, log pump, relay, spool, history, ledger, cancel escalation, behind `coffee-shop host --impl=go`, headless only. The Odin Station keeps the turn deadline and the #143 cancel path; its regression tests must stay green, because that fix is now in the other language. **Partially done (#151, #152, #153, #154, #156, #157, #158, #160, #162; #150 superseded by #151).** `csd` exists and passes the conformance suite alongside the Odin host; it serves the activity socket — reports written to history, announced on stdout, spooled copy removed only after relay, and spool entries from a previous host replayed at start; it dispatches through the `prepare` seam, starts Stations with an argv, pumps output into a bounded log, queues Shots beyond five Slots, and releases a Slot on a terminal report; the machine-wide slot budget is shared with the Brew; `host --impl=go` selects it, with the host lock, the request socket (`reply`), cancel escalation SIGTERM→SIGKILL, state-directory preparation and `CS_CLI` at handover, and `csd` embedded in the Odin binary. Not in the merged list: the progress ledger, so the phase is not closed.
4. **Cut over, then delete.** Default to the Go host, remove the Odin host loop and Station supervisor, then do the v0.5 Wave 3 deletions in the same release. **Not started.** `--impl=go` is still opt-in and no pane path is deleted; the Pi extension is still written by the Odin binary at start, so `csd` cannot install it yet (see below).
5. **Measure.** The same five-Shot run on macOS and WSL2, wall-clock per Shot, host CPU and resident memory, before and after. **Not started.** It waits on the cutover (a before/after of the same host would not measure the move) and on the WSL2 machine.

**Gates.**

- **Conformance: Done (#148, #162).** One black-box suite passes against the Odin host and the Go host on identical request streams, byte-for-byte on every event field except timing, with #159's event-sequence pin and #162's golden dispatch stream as the byte-level proof.
- **Lifecycle: Done (#157).** A cancel stops a Station blocked on a model reply with SIGTERM→SIGKILL escalation in the Go host; the Odin path carries #143's fix forward. Orphan-agent sweep beyond the kill path is covered by the Odin station tests staying green.
- **Durability: Done (#152, #164).** Kill the host mid-run and every terminal report is still relayed or recoverable after restart without reading a log. #164 is the crash proof, not the unit-level replay: a host is SIGKILLed after relaying one report and leaving another spooled-but-unannounced, the spool is provably non-empty, and a fresh host on the same state root relays the surviving report and empties the spool.
- **Concurrency: Open.** Five Stations holding five Slots with a sixth waiting, sustained, is exactly the v0.5 unproven gate; both attempts failed and it is listed as still open above.
- **Parity: Open.** Suite-green-so-far holds (#155–#162 were landed with tests), but the gate is only closed when the cutover and deletions complete without weakening a test.

### Still open for the cutover

Nothing below is claimed done; each item is listed with why it is still open.

- **The Wave-3 code deletion is not done.** `pane_pool.odin`, `host_pane_pool.odin`'s pool half, `pane_clear.odin`, `pane_backend_herdr.odin`, the pane branches in `host.odin`, `pr.odin`'s pane discovery, `settle.odin`'s tab close, `docs/tab-lifecycle.md` and the six tests that fake Herdr all remain. It is the highest-integration-risk step — deleting the plane the Odin host still serves — so it waits for the Go host to be the default, and goes in its own commit naming the guarantee traded, as v0.5's Wave 3 prescribed. The coupling is concrete: the one-shot `brew` path — `run_brew_with`/`dispatch_workers` in `src/dispatch.odin` and `settle_brew`/`close_shot_tab` in `src/settle.odin` — still opens Herdr workspaces and tabs for its Workers, so the Wave-3 deletion is not just deleting pane files: it either ports `brew` to the headless backend first or deletes the `brew` path outright, which is a breaking change to the compatibility foundation the plan says must not regress. Who decides — the developer, separately — is open, because those two options are in tension and the plan does not currently say which.
- **The sustained five-Slot overlap gate is unproven.** v0.5's two attempts both failed (agents backgrounded their sleeps, then a rerun hung), and the cause is unconfirmed. It needs a run where five Shots genuinely hold their Slots for a measured duration with a sixth waiting on a real free, not a synthetic queue check.
- **The WSL2/macOS measurement is not done.** It needs the WSL2 machine, and it must run after the cutover to measure the same five-Shot run before and after the move. The tooling is written and ready: `docs/measurement-plan.md` describes what to record, `scripts/measure-host.sh` is a thin launcher for the Go tool (`go/cmd/measure`) that drives a five-Shot run and writes `report.md`, `per-shot.csv`, `machine.txt`, `host-peaks.csv` and the raw event stream into one output directory.
- **The Go host is not the default.** `host --impl=go` is opt-in today, and the Pi extension is still written by the Odin binary at start — `csd` cannot install it — so the default flip needs that installer/handover piece first.

**Deliberately out of scope for v0.6:** a second agent runtime, a multiplexer, a detached daemon, remote workers, and rewriting the Git, Recipe, Taste or Blend paths.

## Scope guardrails

The target is one machine, a main-agent/Barista session (Pi first), a foreground Coffee Shop host, and Herdr. Pi is required for the first usable path. The host and Station supervisor may be implemented in Go from v0.6, behind the same wire contract, and the v0.6 decision to delete Herdr and the pane paths stands: do not add a pane backend, tmux or zmx to the Go host without a separately approved requirement. Oreo may take the main or worker agent role after the Pi-based flow is usable and Oreo is stable; Rachel is an optional developer aid. Neither is a core dependency. Keep task decomposition with the Barista and integration decisions with the developer. The foreground host is in scope; a detached daemon is not. Do not add remote workers, unrelated agent harnesses, tmux or zmx backends, Relay, automatic merge, PR creation, publishing, or a general configuration system without a separately approved requirement.
