# Coffee Shop Repository Instructions

## Clarifying questions

- When a task needs decisions or information from the user, ask concise, answerable questions in a numbered `Q1`…`Qn` list instead of open-ended prose. Preserve the numbering so the user can reply point by point.

## Git push policy

- For this repository, `git push` is permitted when the user explicitly asks to push.
- Before pushing, confirm the current branch, remote, and push target; review the commits that will be sent.
- Do not force-push or push to a different remote/branch unless the user explicitly requests it.
- A request to make changes, commit, or open a PR does not by itself authorize a push.
- Follow any higher-priority instructions that prescribe a different Git workflow; this file does not override them.
- When a Shot authors or changes tests in a Beans repository, load [Taste-Driven Development](skills/taste-driven-development/SKILL.md). It uses the repository's root `standards.md` and existing test conventions; Filter separately discovers and runs the suites.
- For diagram requests in any domain, use [Diagram Export](skills/diagram-export/SKILL.md) as the sole diagram authoring and rendering workflow; work from the user's description or named source material, then run `odin run skills/diagram-export -- <source.html>`. Keep the source and preview together.

## Git worktrees

- Use `wt` (Worktrunk) for worktree creation, listing, switching, merging, and removal. Do not use raw `git worktree` commands when `wt` supports the operation.
- Configure Worktrunk's user `worktree-path` as `~/.wt/{{ remote_repo | sanitize }}/{{ branch | sanitize }}` and use it. Never create worktrees as siblings under the repository's work directory.
- Keep branch names slash-free (for example, `feat-oreo-sqlite-binding`); use hyphens for hierarchy so each worktree occupies one branch-named directory.

## Sessions run with codemode

- Every Pi session — the Barista and every Station — runs with Pi's `codemode` tool enabled. Cost here is driven by turn count, not prompt size: `cacheRead` was 95% of 18.0M tokens across the v0.4 dogfood runs, so collapsing N tool-call turns into one script is the point.
- It is enabled by `"defaultTools": ["+codemode"]` in the user settings (`~/.pi/agent/settings.json`), so it holds for every project. Do not remove it to "simplify" a run; if a run should not use it, say why in the report.
- **"Read-only" means read-only to the source, not to scratch.** Research (Cupping) and review Shots get `--tools read,grep,find,ls,write,codemode`, so they can write scratch files and run codemode scripts. Scratch files go under `.scratch/`. They must never change any other file: the research Station and the review each check the source afterwards and report the Shot as incomplete if it changed.
- The host also passes `+codemode` explicitly for execute Shots, so Stations do not depend on a user settings file being present.

## Development commands

- Use `just` recipes for build, check, and test workflows. Do not add bespoke shell test-runner scripts when `just` can express the workflow.
- **Never launch a previously-built binary.** Do not run `./coffee-shop`, `~/.coffee-shop/dogfood/coffee-shop`, or any other copied build artifact. Launch through `odin run <package> -- <args>`, or a `just` recipe that compiles first, so the code being exercised is always the current source. A copied binary goes stale silently: the dogfood host once ran a build from hours earlier and kept rendering behaviour the source had already changed, so a whole change was invisible and time went into diagnosing a bug that no longer existed. `just test` and `odin test` already compile, so they are unaffected.
