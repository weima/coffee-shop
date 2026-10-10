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
