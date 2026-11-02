# Coffee Shop

![Coffee Shop mascot: Coffee and Oreo](assets/coffee-shop.svg)

Coffee Shop is a local orchestrator for work initiated from a long-lived main-agent session. Pi is the first user-facing **Barista**: it receives a natural-language **Order**, decides the work, and asks a foreground host to run each piece in an isolated Git worktree as an interactive agent **Station**. The first usable workflow uses Pi for both main and worker sessions. Oreo may take either agent role once stable; Oreo and Rachel are optional improvements, not prerequisites.

> **Current status:** The v0.6 cutover is complete. The foreground host is `csd`, written in Go; it dispatches interactive Pi **Stations** as headless child processes, one isolated Git worktree each, relays their reports and alerts, and answers them through `coffee-shop reply`. Odin keeps the Station itself, the CLI, the worktree and `pr`/`cleanup`/`blend` commands. The retired one-shot `brew`/Worker path and the Herdr pane layer are gone. `status`, `log` and `reply` are the live controls. What remains is measurement, which `PLAN.md` lists.


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
- [Pi](https://pi.dev) `1.1.0` on your `PATH`, with Pi already authenticated. Coffee Shop needs no terminal multiplexer: a Station is a plain child process.
- Whatever the Beans repository's own tests need (for example `npm` or `make`) when running its Taste/checks.

To **develop** Coffee Shop you also need:

- The Odin compiler, official monthly release `dev-2026-10`. Odin has no semver-stable release; it publishes one `dev-YYYY-MM` release a month, and Coffee Shop pins one. The compiler reports it as `dev-2026-10-nightly:84bc3fc`, because Odin's version string always says "nightly". Download the archive for your platform from the [`dev-2026-10` release](https://github.com/odin-lang/Odin/releases/tag/dev-2026-10) and verify it against that archive's published SHA-256.
- [Go](https://go.dev) `1.27` or newer, because the host is written in Go and a build embeds it.
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
- **Coffee Shop passes `+codemode` explicitly for every execute Shot** unless the request sets `"codemode": false`, so an execute Station does not depend on your settings file.

## Intended interaction flow

1. For the first usable path, start Pi from `~/work/coffee-shop` and keep its main session open. Pi is the user-facing Barista; Oreo may take this role later once stable.
2. The active main-agent harness starts Coffee Shop from the `coffee-shop` executable or `odin run src`. The foreground host stays ready for structured dispatch and control requests; it is not a detached daemon or a second natural-language agent.
3. The user gives the main agent a repository task. The Barista interprets the Order, decides the Shots, and sends Coffee Shop a dispatch request.
4. Coffee Shop creates an isolated Git worktree per Shot and starts an interactive Pi **Station**. Oreo may be evaluated as an alternative only after the Pi-based flow is usable.
5. The user follows a Station with `status --stations` and `log`, and sends follow-up instructions with `coffee-shop reply`; all project edits stay in the isolated worktree. A Station that asks a question raises `needs_input_alert`.
6. Coffee Shop relays a Station's reports and questions to the main agent; the Barista brings the question or result to the user and routes the reply back to the same Station.
7. The Barista reports completion. A person reviews and decides whether to integrate; Coffee Shop does not merge or publish automatically.

**Input boundary:** “Coffee Shop waits for input” means the foreground host waits for structured requests from the active main-agent harness. Raw user text goes to that harness; Coffee Shop does not interpret it.

**Current implementation:** the Go host dispatches interactive Pi Stations as headless child processes, described in [the architecture](docs/architecture.md). Station output goes to bounded per-Shot logs, and no pane, tab or workspace layer exists.


### The host

`csd` is the foreground host, written in Go. It serves the request stream, receives Station reports over the activity socket with a durable spool and per-request history, supervises progress (`needs_input_alert`, `stale_warning`), and dispatches Shots by driving the Odin CLI's seams: `prepare`, `station`, and `blend`. It runs five Slots per host and queues the rest, within a machine-wide budget of the same size. Odin keeps the CLI, the Station, Git worktrees, `pr` and `cleanup`.

It holds the host lock, serves the request socket, and escalates a cancel from SIGTERM to SIGKILL, so `coffee-shop status --stations` and `coffee-shop reply` work against it. The machine-wide Slot files bound every host on the machine. The host installs its Pi extension itself and has no pane backend. `coffee-shop host` runs it; there is no second implementation to switch to. A normal build embeds and installs its matching `csd`; an explicit `CS_CSD` takes precedence, then the embedded host, then `csd` on `PATH`. A bare `odin run src -- host` has no embedded copy, so it requires a `CS_CSD` or matching `csd` on `PATH` and fails clearly otherwise. During Go handover, Coffee Shop sets `CS_CLI` to the current running executable so Go can drive `prepare` and `station` without buffering the host protocol.

Oreo and Rachel are improvement tracks, not core dependencies: the Coffee Shop workflow must be usable with Pi alone. See [the architecture](docs/architecture.md) for target and current diagrams and boundaries. See [the plan](PLAN.md) for the next implementation phases. See the [vocabulary](specs/UBIQUITOUS_LANGUAGE_LATEST.md) for the coffee-shop terms.

## Target scope

| Included | Not included |
| --- | --- |
| One local main-agent session (Pi first) with a foreground Coffee Shop controller | A detached background daemon or remote workers |
| Explicit task breakdown by the Barista | Natural-language task decomposition inside Coffee Shop |
| Isolated Git worktrees, interactive Pi Stations, and one foreground host | Oreo/Rachel integration in the core path; unrelated harnesses or workspace backends |
| Session history plus completion and needs-input handoff to the main agent | Automatic merge, publishing, or a detached daemon |
| `pr` and `cleanup` as explicit, human-run commands | Automatic cleanup of branches or worktrees |
| Human review before integration | Persistent second coordinators |

## Dispatch requests

The host reads one JSON request per line. A dispatch names the Beans repository and its Shots;
each Shot carries its own `prompt` (or a `prompt_file`), and may set `model`, `thinking`, `kind`
(`execute` or `research`), a `taste` with its `message`, and `codemode`. Without a model a
Station uses the Station default, which an explicit `model` overrides.

```json
{"type":"dispatch","request_id":"req-1","repo":"/abs/path/to/beans",
 "recipe":{"shots":[{"id":"help-copy","prompt":"Review and improve the help text."}]}}
```

Each Shot's prompt is written to `<state>/host/<request>/prompts/<shot>.md` and its output to
`<state>/host/<request>/logs/<shot>.log`. A Station that changes nothing still reports; a Pull
runs its Taste and commits only if the Taste passes.

## Limitations

These are behaviours observed while building and dogfooding Coffee Shop, not future plans.

- **Linux, WSL and macOS.** On WSL, keep `CS_STATE_DIR` on the Linux filesystem, not under `/mnt/c`. Native Windows is not supported.
- **Five Slots per host, and a machine-wide budget of the same size.** Shots beyond that queue and start as Slots free; there is no timeout.
- **A Station is silent until it reports.** `status --stations` reads the host's history, not the process table, so a Station that has said nothing looks idle until `stale_warning` fires at ten minutes.
- **Stations start from the Beans' `HEAD` commit.** Uncommitted changes are invisible to a Station, so commit first.
- **Nothing is deleted automatically.** Station worktrees, branches and state accumulate until you remove them: `pr` and `cleanup` are the supported path.
- **Station output is capped.** A Shot's log is bounded and rotated once, so a Station that prints without end keeps only its newest output.
- **A Pull commits only after its Taste passes.** A Taste that cannot run, or that exits non-zero, reports `taste_failed` and leaves the worktree unchanged.
- **Blend needs 2 to 20 commits.** A single Pull is fast-forwarded instead; `pr --blend` refuses one commit.
- **Measurement is partial.** The macOS five-Shot run is recorded in `PLAN.md`; WSL2 and per-Station resource sampling are still open.

## Development

Coffee Shop is two halves: an Odin CLI and Station, and a Go host. A build embeds the host, so
one command carries both.

```sh
just check     # odin check src, then go vet
just test      # go test -race ./..., then the Odin suite under the suite lock
just build     # builds ./coffee-shop with the Go host embedded
odin run src -- --help
```

Use `just` for build, check and test. `just test` holds the repository's suite lock, so two runs
cannot overlap and produce the flakes this repository has already measured.

The Odin tests drive the real binary as separate processes in temporary repositories: the
`__server` election and idle exit, `pr` and `cleanup` against real Git, the seams, and the
Station with fake agents. They need Git, a POSIX shell, and the Odin and Go toolchains, but no
network or AI service. The Go tests cover the host: contract conformance, dispatch, the queue and
Slots, cancellation, durability, progress supervision and Blend routing.

## Odin reference

The implementation plan uses [Odin in Practice](https://github.com/weima/odin-in-practice) as its language reference. Key topics include CLI contracts, process arguments, child-process ownership, memory lifetimes, and parallel work. The plan links to the relevant chapters.

## Current files

- [`specs/UBIQUITOUS_LANGUAGE_LATEST.md`](specs/UBIQUITOUS_LANGUAGE_LATEST.md) — canonical Coffee Shop terms and proposed software mappings.
- [`docs/architecture.md`](docs/architecture.md) — architecture diagram, data flow, and boundaries.
- [`PLAN.md`](PLAN.md) — implementation roadmap and verification gates.
- [`oreo/README.md`](oreo/README.md) — the independent Oreo Odin harness and its design documents.
- [`src/`](src/) — Odin CLI source and package tests.
