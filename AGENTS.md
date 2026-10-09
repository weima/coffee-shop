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
