# Coffee Time

Coffee Time is planned as a small Odin command-line tool for dispatching parallel Pi workers. The active Pi session acts as the **Barista**: it turns a developer's **Order** into a **Recipe**, then asks Coffee Time to run the work.

> **Status:** planning only. This repository has no executable yet. The current files define product vocabulary, architecture, and an implementation plan.

## How it is intended to work

1. The Barista prepares a Recipe with one or more independent Shots.
2. Coffee Time creates an isolated Git worktree, or **Station**, for each Shot.
3. Coffee Time starts each Pi **Worker** in a visible tmux session.
4. Coffee Time records progress in the **Register** and events in the **Receipt**.
5. The Barista reviews the completed work and serves an **Oreo**: a summary, evidence, and any decision needed.
6. A person decides whether to integrate the changes. Coffee Time does not merge or publish them.

See [the architecture](docs/architecture.md) for the diagram and boundaries. See [the plan](PLAN.md) for the proposed implementation steps. See the [vocabulary](specs/UBIQUITOUS_LANGUAGE_LATEST.md) for the coffee-shop terms.

## Initial scope

| Included | Not included |
| --- | --- |
| One local machine, Pi workers, and tmux sessions | Other agent harnesses or session backends |
| Explicit task breakdown by the active Pi session | A separate AI coordinator or automatic task decomposition |
| One isolated Git worktree per Shot | Persistent second mates or remote workers |
| Durable run status and collected worker results | An always-on watcher, Relay, or automatic merge |
| Human review before integration | Automatic PR creation or publishing |

## Odin reference

The implementation plan uses [Odin in Practice](https://github.com/weima/odin-in-practice) as its language reference. Key topics include CLI contracts, process arguments, child-process ownership, memory lifetimes, and parallel work. The plan links to the relevant chapters.

## Current files

- [`specs/UBIQUITOUS_LANGUAGE_LATEST.md`](specs/UBIQUITOUS_LANGUAGE_LATEST.md) — canonical Coffee Time terms and proposed software mappings.
- [`docs/architecture.md`](docs/architecture.md) — architecture diagram, data flow, and boundaries.
- [`PLAN.md`](PLAN.md) — implementation plan. No code changes are authorized by that plan alone.
