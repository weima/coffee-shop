# Coffee Shop

![Coffee Shop mascot: Coffee and Oreo](assets/coffee-shop.svg)

Coffee Shop is a local Odin orchestrator for work initiated from a long-lived main-agent session. Pi is the first user-facing **Barista**: it receives a natural-language **Order**, prepares an explicit **Recipe**, and asks a foreground Coffee Shop host to manage isolated Git worktrees and worker sessions. The first usable workflow uses Pi for both main and worker sessions. Oreo may take either agent role once stable; Oreo and Rachel are optional improvements, not prerequisites.

> **Current status:** The interactive workflow is implemented — a foreground host dispatches interactive Pi **Stations** as headless child processes, one isolated Git worktree each, and relays their reports. The retired one-shot `brew`/Worker workflow is no longer part of the CLI; `status` lists live host Stations, with `log` and `reply` for host requests. The automated vertical-slice suite passes on Linux, WSL and macOS, and a real Pi/Herdr smoke Brew passed on macOS with Pi `1.1.0` and Herdr `0.9.3`. The long-lived host, interactive worker sessions, and live completion/needs-input relay are **implemented**; `PLAN.md` records what shipped and what is still live.


## The story behind the names

Coffee Shop is named for two of our family members, Coffee and Oreo.

- **Coffee** is a black German Shepherd and Golden Retriever mix with relaxed floppy ears and a long charcoal muzzle. He is still with us. He is the Barista in the project's characters: the one who turns an Order into a Recipe and leads the Brew.
- **Oreo** was an American Shorthair with a black-and-white coat. He passed away in 2025, at the age of 12, and we miss him. He is drawn as the cat who reviews a finished Brew. The final review packet is now called the **Tray**.

Rachel is another family member and the inspiration for the optional human-facing Odin feedback companion in [`tools/rachel/`](tools/rachel/). Her mascot joins Coffee and Oreo in the same round-badge illustration style: Coffee leads the work, Oreo is remembered as the reviewer, and Rachel can help the developer while they code. Rachel is not part of the Coffee Shop runtime.

The drawings are in [`assets/characters/`](assets/characters/): `coffee.svg`, `oreo.svg`, and `rachel.svg`, alongside the other roles. We want them with us in this project, and this section is how we keep them here.

## Requirements

To **use** Coffee Shop you need:

- Linux (including WSL) or macOS. Linux process identity uses `/proc`; macOS uses Darwin's process-usage API. Native Windows is not supported.
- [Git](https://git-scm.com/).
- [Herdr](https://herdr.dev) `0.9.3` and [Pi](https://pi.dev) `1.1.0` on your `PATH`, with Pi already authenticated. A Herdr server must be running, but you do not need to run Coffee Shop inside a Herdr pane: from a plain terminal the Herdr CLI uses its default socket. The Herdr server must be reachable when dispatching Stations.
- Whatever the Beans repository's own tests need (for example `npm` or `make`) when running its Taste/checks.

To **develop** Coffee Shop you also need:

- The Odin compiler, official monthly release `dev-2026-10`. Odin has no semver-stable release; it publishes one `dev-YYYY-MM` release a month, and Coffee Shop pins one. The compiler reports it as `dev-2026-10-nightly:84bc3fc`, because Odin's version string always says "nightly". Download the archive for your platform from the [`dev-2026-10` release](https://github.com/odin-lang/Odin/releases/tag/dev-2026-10) and verify it against that archive's published SHA-256.
- [`just`](https://github.com/casey/just), the command runner for the project's checks. Install it with `cargo install just --locked` or your package manager. `just test`, `just check` and `just build` are the supported entry points.

## Sessions run with codemode

Every Pi session Coffee Shop drives — the Barista and every Station — runs with Pi's `codemode` tool enabled. A Station can then run one script instead of one tool call per turn. That matters here because cost is driven by turn count, not prompt size: across the v0.4 dogfood runs `cacheRead` was 95% of 18.0M tokens, because every turn re-sends the conversation.

Enable it once in your Pi user settings (`~/.pi/agent/settings.json`):

```json
{
  "defaultTools": ["+codemode"]
}
```

`+codemode` **adds** the tool to Pi's defaults (`read`, `bash`, `edit`, `write`); it does not replace them. Run `/reload` in an open session, or start a new one.

Two things to know:

- **Read-only means read-only to the source, not to scratch.** Research (Cupping) and review Shots get `--tools read,grep,find,ls,write,codemode`. They may write scratch files under `.scratch/` and run codemode scripts, but must not change any other file. The research Station and the review each check the source afterwards and report the Shot as incomplete if it changed.
- **Coffee Shop passes `+codemode` explicitly for every execute Shot**, Station or brew worker, so they do not depend on your settings file. There is no switch to turn it off.

## Intended interaction flow

1. For the first usable path, start Pi from `~/work/coffee-shop` and keep its main session open. Pi is the user-facing Barista; Oreo may take this role later once stable.
2. The active main-agent harness starts Coffee Shop from the `coffee-shop` executable or `odin run src`. The foreground host stays ready for structured dispatch and control requests; it is not a detached daemon or a second natural-language agent.
3. The user gives the main agent a repository task. The Barista interprets the Order, prepares an explicit Recipe, and sends Coffee Shop a dispatch request.
4. Coffee Shop creates isolated Git worktrees, then starts an interactive Pi worker session. Oreo may be evaluated as an alternative only after the Pi-based Coffee Shop flow is usable.
5. The user sends follow-up instructions to a running worker session through a routed reply; all project edits stay in the isolated worktree.
6. The worker sends `needs_input`, progress, or completion to Coffee Shop. Coffee Shop notifies the main agent; the Barista brings the question or result to the user and routes replies back to the same session.
7. The Barista reports completion. A person reviews and decides whether to integrate; Coffee Shop does not merge or publish automatically.

**Input boundary:** “Coffee Shop waits for input” means the foreground host waits for structured requests from the active main-agent harness. Raw user text goes to that harness; Coffee Shop does not interpret it.

**Current implementation:** the foreground host dispatches interactive Pi Stations as headless child processes (`CS_PANE_BACKEND=headless` selects the supported path), described in [the architecture](docs/architecture.md). The former one-shot `brew` and Worker execution path has been retired; Station output goes to bounded per-Shot logs, and the Herdr pane pool and tab lifecycle no longer exist.


### Go host (v0.6, in progress)

`csd` is a second, in-progress implementation of the foreground host, written in Go. It speaks the same wire contract as the Odin host — the same request stream, stdout event shapes, socket paths, and spool and history files — so the same conformance suite runs against both. Today it serves the request stream, receives Station reports over the activity socket with a durable spool and per-request history, and dispatches Shots by driving the Odin CLI's `prepare` and `station` commands. It runs five Slots per host and queues the sixth.

It takes the same host lock as the Odin host, serves the request socket, and escalates a cancel from SIGTERM to SIGKILL, so `coffee-shop status --stations` and `coffee-shop reply` work against it unchanged; the machine-wide Slot files are shared, so a Go host and an Odin Brew cannot together exceed the budget. The Go host installs its Pi extension itself and has no pane backend. `coffee-shop host` now defaults to Go; `--impl=odin` keeps the prior Odin backend available as a rollback. A normal build embeds and installs its matching `csd`; an explicit `CS_CSD` takes precedence, then the embedded host, then `csd` on `PATH`. A bare `odin run src -- host` has no embedded copy, so it requires a `CS_CSD` or matching `csd` on `PATH` and fails clearly otherwise. During Go handover, Coffee Shop sets `CS_CLI` to the current running executable so Go can drive `prepare` and `station` without buffering the host protocol.

Oreo and Rachel are improvement tracks, not core dependencies: the Coffee Shop workflow must be usable with Pi alone. See [the architecture](docs/architecture.md) for target and current diagrams and boundaries. See [the plan](PLAN.md) for the next implementation phases. See the [vocabulary](specs/UBIQUITOUS_LANGUAGE_LATEST.md) for the coffee-shop terms.

## Target scope

| Included | Not included |
| --- | --- |
| One local main-agent session (Pi first) with a foreground Coffee Shop controller | A detached background daemon or remote workers |
| Explicit task breakdown by the Barista | Natural-language task decomposition inside Coffee Shop |
| Herdr workspaces, isolated Git worktrees, and interactive Pi worker sessions | Oreo/Rachel integration in the core path; unrelated harnesses or workspace backends |
| Session history plus completion and needs-input handoff to the main agent | Automatic merge, PR creation, publishing, or cleanup |
| Human review before integration | Persistent second coordinators |

## Recipe format

A Recipe is strict JSON described by [`recipe.schema.json`](recipe.schema.json). It has `order` or `order_file`, a non-empty `shots` array, and each Shot has `prompt` or `prompt_file` plus a unique safe ID. Optional Recipe defaults `model` and `thinking` can be overridden per Shot; `review_model` and `review_thinking` configure the Filter review. `workers` opts into 1–5 concurrent Workers (default 2).

```json
{
  "order": "Improve the command-line help",
  "model": "provider/model-id",
  "thinking": "medium",
  "workers": 2,
  "shots": [
    { "id": "help-copy", "prompt": "Review and improve the help text.", "expect_changes": true }
  ]
}
```

Use `order_file`, `prompt_file`, and `preamble_file` for long Markdown text. Paths are relative to the Recipe file and cannot escape its directory. Coffee Shop validates and snapshots text before creating Stations. A preamble is delivered to every Worker as appended system guidance; `status` and the Tray show its filename and size, not its contents. Each Worker is instructed to read root `workers.md` and `standards.md` when present. Finish Worker reports with `CS-DONE` when complete and verified, or `CS-BLOCKED: <reason>` when blocked; Coffee Shop sends no automatic follow-up.

### Sharing installed dependencies

Each Station is a fresh checkout, so gitignored directories such as `node_modules` are missing from it. Rather than reinstalling them in every Station, list them in an optional `share` array. Coffee Shop links each listed path from the Beans repository into every Station.

```json
{ "order": "...", "share": ["node_modules", "packages/web/node_modules"], "shots": [ ... ] }
```

- Paths are relative to the Beans repository, must exist there, and must be gitignored. `brew` stops before creating anything if one is not.
- The link is read-through: a Worker that installs or upgrades packages changes the Beans' real copy, so tell Workers not to install dependencies.
- It works for any repository-local directory, for example `node_modules`, `vendor/bundle`, `.bundle` or `.venv`. Ecosystems that keep packages in a global cache outside the repository, such as NuGet's `~/.nuget/packages`, need nothing shared.
- When a Station lacks one of those common directories that the Beans has, the Filter adds a note suggesting `share` instead of leaving you with a confusing test failure.

## Limitations

These are the behaviours observed while building and dogfooding Coffee Shop, not future plans.

- **Linux, WSL and macOS.** On WSL, keep `CS_STATE_DIR` on the Linux filesystem, not under `/mnt/c`. Native Windows is not supported.
- **Stations start from the Beans' `HEAD` commit.** Uncommitted changes in the Beans repository are invisible to Workers, so commit first.
- **Two Workers by default, five maximum, no timeout.** A Worker that never finishes stays `running` until you `cancel` the Brew.
- **Explicit completion.** v0.2 Recipes complete only when the final response ends with `CS-DONE`; missing markers and `CS-BLOCKED` become `incomplete`.
- **Nothing is deleted automatically.** Stations, branches and state accumulate until you remove them.
- **Shared paths are read-through.** A Worker that installs packages changes the Beans' real copy.
- **The Filter's checks run inside the Station**, a fresh checkout. Dependencies the repository does not commit are missing unless shared, a command may write build output there, and output is buffered in memory with no timeout.
- **The Filter's review is advisory.** It is a second pair of eyes and has missed real problems; read the diff yourself.
- **State conflicts are never repaired.** If the Register and Receipt disagree, Coffee Shop reports the Brew's state as unknown and leaves both files for you to inspect.
- **A Brew ID is not reused**, but the older `brew-<pid>-<n>` format from early development sorts before the current `brew-<UTC time>-<pid>` format.

## Development

Run the checks with:

```sh
just test      # TZ=UTC odin test src, including the end-to-end tests
just check     # odin check src
just build     # builds ./coffee-shop
odin run src -- --help
```

The `justfile` only wraps the documented Odin commands, so `odin test src` and `odin check src` also work without `just`. Its `test` recipe is what the Filter discovers when it verifies a Station of this repository.

The end-to-end tests in `src/e2e_test.odin` build the real binary and run it as separate processes against fake `herdr` and `pi` scripts in a temporary repository. They cover a multi-Shot Brew with a failure, `status` and `collect` from fresh processes, Station isolation, repeated collection, cancellation (running Workers stopped, queued Shots cancelled, repeatable), and recovery after the supervisor is killed. They need Git, a POSIX shell and the Odin compiler, but no network, AI service or Herdr.

## Odin reference

The implementation plan uses [Odin in Practice](https://github.com/weima/odin-in-practice) as its language reference. Key topics include CLI contracts, process arguments, child-process ownership, memory lifetimes, and parallel work. The plan links to the relevant chapters.

## Current files

- [`specs/UBIQUITOUS_LANGUAGE_LATEST.md`](specs/UBIQUITOUS_LANGUAGE_LATEST.md) — canonical Coffee Shop terms and proposed software mappings.
- [`docs/architecture.md`](docs/architecture.md) — architecture diagram, data flow, and boundaries.
- [`PLAN.md`](PLAN.md) — implementation roadmap and verification gates.
- [`oreo/README.md`](oreo/README.md) — the independent Oreo Odin harness and its design documents.
- [`src/`](src/) — Odin CLI source and package tests.
