# Coffee Shop

![Coffee Shop mascot: Coffee and Oreo](assets/coffee-shop.svg)

Coffee Shop is being built as a small Odin command-line tool for dispatching parallel Pi workers. The active Pi session acts as the **Barista**: it turns a developer's **Order** into a **Recipe**, then asks Coffee Shop to run the work.

> **Status:** the vertical slice builds and its automated tests pass on Linux, WSL and macOS. A real one-Shot Pi/Herdr smoke Brew also passed on macOS with Pi `1.1.0` and Herdr `0.9.3`; it produced a completed report and `status`/`collect` succeeded. The smoke task was read-only and made no Station changes.

## The story behind the names

Coffee Shop is named for two of our family members, Coffee and Oreo.

- **Coffee** is a black mix of German Shepherd and Golden Retriever. He is still with us. He is the Barista in the project's characters: the one who turns an Order into a Recipe and leads the Brew.
- **Oreo** was an American Shorthair with a black-and-white coat. He passed away in 2025, at the age of 12, and we miss him. He is drawn as the cat who reviews a finished Brew. The final review packet is now called the **Tray**.

Rachel is another family member and the inspiration for the human-facing Odin feedback companion in [`tools/rachel/`](tools/rachel/). Her mascot joins Coffee and Oreo in the same round-badge illustration style: Coffee leads the work, Oreo is remembered as the reviewer, and Rachel helps the developer while they code. Her glasses and laptop are part of the design; the paw pin is a small remembrance of Oreo.

The drawings are in [`assets/characters/`](assets/characters/): `coffee.svg`, `oreo.svg`, and `rachel.svg`, alongside the other roles. We want them with us in this project, and this section is how we keep them here.

## Requirements

To **use** Coffee Shop you need:

- Linux (including WSL) or macOS. Linux process identity uses `/proc`; macOS uses Darwin's process-usage API. Native Windows is not supported.
- [Git](https://git-scm.com/).
- [Herdr](https://herdr.dev) `0.9.3` and [Pi](https://pi.dev) `1.1.0` on your `PATH`, with Pi already authenticated. A Herdr server must be running, but you do not need to run Coffee Shop inside a Herdr pane: from a plain terminal the Herdr CLI uses its default socket. If no server is reachable, `brew` records the Brew, exits 1, and reports Herdr's message (for example `no herdr server is running ...; run herdr to start or attach it`). Start Herdr, then run a new Brew.
- Whatever the Beans repository's own tests need (for example `npm` or `make`), because the Filter runs them.

To **develop** Coffee Shop you also need:

- The Odin compiler, official monthly release `dev-2026-10`. Odin has no semver-stable release; it publishes one `dev-YYYY-MM` release a month, and Coffee Shop pins one. The compiler reports it as `dev-2026-10-nightly:84bc3fc`, because Odin's version string always says "nightly". Download the archive for your platform from the [`dev-2026-10` release](https://github.com/odin-lang/Odin/releases/tag/dev-2026-10) and verify it against that archive's published SHA-256.
- [`just`](https://github.com/casey/just), the command runner for the project's checks. Install it with `cargo install just --locked` or your package manager. `just test`, `just check` and `just build` are the supported entry points.

## How it works

1. The Barista prepares a Recipe with one or more independent Shots.
2. Coffee Shop creates an isolated Git worktree, or **Station**, for each Shot.
3. Coffee Shop starts each Pi **Worker** in its own tab in a Herdr workspace.
4. Coffee Shop records progress in the **Register** and events in the **Receipt**.
5. The Barista reviews the completed work and serves a **Tray**: a summary, evidence, and any decision needed.
6. A person decides whether to integrate the changes. Coffee Shop does not merge or publish them.

See [the architecture](docs/architecture.md) for the diagram and boundaries. See [the plan](PLAN.md) for the proposed implementation steps. See the [vocabulary](specs/UBIQUITOUS_LANGUAGE_LATEST.md) for the coffee-shop terms.

## Initial scope

| Included | Not included |
| --- | --- |
| One local machine, Pi workers, and Herdr workspaces | Other agent harnesses or session backends |
| Explicit task breakdown by the active Pi session | A separate AI coordinator or automatic task decomposition |
| One isolated Git worktree per Shot | Persistent second mates or remote workers |
| Durable run status and collected worker results | An always-on watcher, Relay, or automatic merge |
| Human review before integration | Automatic PR creation or publishing |

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

## Usage

A typical session:

1. The Barista writes a Recipe and runs `brew`. It blocks until every Shot is finished, so run it in the background (for example with Pi's `bg_run`) rather than in the foreground.
2. While it runs, `status <brew-id>` shows each Shot, and `cancel <brew-id>` stops the Brew.
3. `collect <brew-id>` produces the Tray. Review each Station by hand, integrate the changes you want, and delete Stations and state yourself when you are done.

```sh
coffee-shop brew --repo <path> --recipe <recipe.json>
coffee-shop status <brew-id>
coffee-shop cancel <brew-id>
coffee-shop collect <brew-id>
```

- `brew` creates and runs the Brew, blocks until every Shot is terminal, then prints the Brew ID (`brew-<UTC start time>-<pid>`). It exits 0 even if some Workers failed, because those outcomes belong to `status` and `collect`. It exits 1, still printing the ID, only when no Worker could be started at all (for example, no Herdr server is running).
- At most two Workers run at once by default; `workers` can opt into a limit up to five.
- `status` prints the Brew and each Shot's status. Running Shots also show elapsed time and the latest Pi activity; activity older than 12 minutes is marked quiet. Activity is only a progress hint: process identity remains the liveness authority, and quiet Workers are never killed automatically.
- `cancel` requests cancellation; repeating it is safe.
- `collect` prints each Shot's outcome, Worker report and Station changes, then runs the Filter once per completed Shot: a read-only Pi review against the repository's `standards.md` and the repository's own test commands. The saved evidence is reused on later collections. It ends with the decisions that need a human, and exits non-zero unless every Shot completed. See [the architecture](docs/architecture.md#filter-and-tray).
- Brew state is stored under `$CS_STATE_DIR/<brew-id>` when `CS_STATE_DIR` is set, or `~/.coffee-shop/<brew-id>` otherwise. `CS_STATE_DIR` must be an absolute path.
- Stations and Brew state are never deleted automatically; `collect` preserves them.

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
