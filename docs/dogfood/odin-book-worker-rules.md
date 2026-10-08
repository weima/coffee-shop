# Worker rules for extending "Odin in Practice"

Every Worker in this Brew reads this file first and follows it. It is written once, here, instead of being pasted into each Shot.

## Context

You work in your own Git worktree (a Station) of the repository for "Odin in Practice", a source-guided book that teaches Odin through systems programming. The Odin compiler is the official monthly release dev-2026-10: `odin version` must print `dev-2026-10-nightly:84bc3fc`. If `odin` is not found, run `source ~/.zshrc` first.

The book was the language reference while a real Odin CLI called Coffee Shop was built. Some lessons from that project are missing from the book. Each Worker adds ONE topic. Coffee Shop's source is at /home/wema/work/coffee-shop/src (read-only reference; never modify it).

## You are not interactive

No person is watching and nobody will answer a question. Never ask for permission, confirmation or clarification, and never stop to propose a plan and wait. Make the reasonable choice, state it in your report, and carry on. If something truly blocks you, report exactly what blocked you, and still finish everything that is not blocked.

## Rules

1. **Evidence first.** Every claim about compiler, library or OS behaviour must be reproduced by compiling or running it with dev-2026-10, in a scratch directory under /tmp/<your-shot-id>/. Quote real compiler errors verbatim. If real behaviour differs from your brief, the real behaviour wins; say so in your report. Never state a behaviour you did not observe.
2. **Library claims.** Confirm names and signatures in the bundled source (`$(odin root)/core/...`). The book links Odin source at the pinned commit 84bc3fc2100b0f7880a3af37f71bccdcda41c6f9; copy that link style (see how docs/chapters/cli-linux.md, chapter 15, links process.odin) and make sure every linked file exists in the bundled source.
3. **Style.** First read the neighbouring sections of your chapter and match them: second person, precise, aware of trade-offs, short code blocks that compile, Linux-specific parts labelled, ownership and failure called out. ADD text only; do not rewrite existing text.
4. **Book rules** (enforced by tools/check-book.py). Never add, remove or renumber a `## N.` chapter heading. New subsections are unnumbered `###` headings inside your chapter. If the file uses explicit anchors (`<a id="...">`), give each new subsection a unique id that starts with `dogfood-`. Do NOT edit html/, README.md, docs/index.md, docs/examples/README.md, mkdocs.yml, tools/, .github/, package files, or any chapter or section other than the one assigned to you.
5. **Companion code.** A new directory docs/examples/<name>/ holding a library package plus `_test.odin` tests (add a main.odin only if it helps teaching; CI compiles every main.odin). Tests use the standard core:testing runner, pass under `TZ=UTC odin test <dir>`, show NO memory-leak warnings, touch nothing outside a temporary directory, and need no network. Keep the code small and readable; it is for teaching. Code that is supposed to FAIL to compile must never be committed as a compiling package: show it only as a verified transcript in the chapter text.
6. **Verification.** All of these must pass before you report: `odin check <dir>`; `TZ=UTC odin test <dir>` (run it 3 times in a row when processes or timing are involved); and `. .venv/bin/activate && mkdocs build --strict -d /tmp/<your-shot-id>-site`. The .venv in your Station is a link to a shared environment: do not install anything, and NEVER run mkdocs without -d, because that would rewrite the tracked html/ folder. If a check fails, fix the cause and run it again until it passes; do not report while anything is failing or unverified. Finish with `git status --short`: only files you own may appear (an untracked `.pi/` folder is not yours and may be ignored).
7. **Do not** commit, push, create branches, install packages, run npm, or run the Mermaid diagram build.

## Your last message

Your final reply is the deliverable, not a progress note. It must be a report with these parts, and it must not end before every check has actually run:

- files created or changed;
- what the new text teaches;
- each verification command with its real result;
- every place where reality differed from your brief;
- open questions.

A reply such as "I fixed it and restarted verification" is not a report.
