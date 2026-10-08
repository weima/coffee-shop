# Coffee Shop

![Coffee Shop mascot: Coffee and Oreo](assets/coffee-shop.svg)

Coffee Shop is being built as a small Odin command-line tool for dispatching parallel Pi workers. The active Pi session acts as the **Barista**: it turns a developer's **Order** into a **Recipe**, then asks Coffee Shop to run the work.

> **Status:** implementation in progress. The Odin CLI validates arguments, JSON Recipes, and Beans Git repositories, dispatches Workers, persists Brew state, and collects results.

## How it is intended to work

1. The Barista prepares a Recipe with one or more independent Shots.
2. Coffee Shop creates an isolated Git worktree, or **Station**, for each Shot.
3. Coffee Shop starts each Pi **Worker** in its own tab in a Herdr workspace.
4. Coffee Shop records progress in the **Register** and events in the **Receipt**.
5. The Barista reviews the completed work and serves an **Oreo**: a summary, evidence, and any decision needed.
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

A Recipe is strict JSON with a non-empty `order` and a non-empty `shots` array. Each Shot has a non-empty `prompt` and a unique `id`: 1–64 ASCII letters, digits, `_` or `-`, starting with a letter or digit.

```json
{
  "order": "Improve the command-line help",
  "shots": [
    { "id": "help-copy", "prompt": "Review and improve the help text." }
  ]
}
```

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

```sh
coffee-shop brew --repo <path> --recipe <recipe.json>
coffee-shop status <brew-id>
coffee-shop cancel <brew-id>
coffee-shop collect <brew-id>
```

- `brew` creates and runs the Brew, blocks until every Shot is terminal, then prints the Brew ID (`brew-<UTC start time>-<pid>`).
- At most two Workers run at once.
- `status` prints the Brew and each Shot's status.
- `cancel` requests cancellation; repeating it is safe.
- `collect` prints each Shot's outcome, Worker report and Station changes, then runs the Filter once per completed Shot: a read-only Pi review against the repository's `standards.md` and the repository's own test commands. The saved evidence is reused on later collections. It ends with the decisions that need a human, and exits non-zero unless every Shot completed. See [the architecture](docs/architecture.md#filter-and-oreo).
- Brew state is stored under `$CS_STATE_DIR/<brew-id>` when `CS_STATE_DIR` is set, or `~/.coffee-shop/<brew-id>` otherwise. `CS_STATE_DIR` must be an absolute path.
- Stations and Brew state are never deleted automatically; `collect` preserves them.

## Development

Coffee Shop currently supports Linux, including WSL. Cancel and recovery identify processes through `/proc`, so macOS is not supported yet. Keep `CS_STATE_DIR` on the Linux filesystem, not under `/mnt/c`.

The initial implementation uses Odin `dev-2026-09-nightly:a2fb372`, Pi `1.1.0`, and Herdr `0.9.3`. Run the CLI checks with:

```sh
odin test src
odin check src
odin run src -- --help
```

## Odin reference

The implementation plan uses [Odin in Practice](https://github.com/weima/odin-in-practice) as its language reference. Key topics include CLI contracts, process arguments, child-process ownership, memory lifetimes, and parallel work. The plan links to the relevant chapters.

## Current files

- [`specs/UBIQUITOUS_LANGUAGE_LATEST.md`](specs/UBIQUITOUS_LANGUAGE_LATEST.md) — canonical Coffee Shop terms and proposed software mappings.
- [`docs/architecture.md`](docs/architecture.md) — architecture diagram, data flow, and boundaries.
- [`PLAN.md`](PLAN.md) — implementation roadmap and verification gates.
- [`src/`](src/) — Odin CLI source and package tests.
