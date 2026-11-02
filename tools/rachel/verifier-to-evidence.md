# From verifier to evidence

Rachel today is a compiler wrapper that prints a verdict. This plan grows her into
a **verifier** (checks and tests, with a stage-tagged verdict) and then into an
**evidence producer** (artifacts an agent can act on). The end state is a
"human in the loop": she decides what is worth running, runs it, and reports what
she saw in the form the reader can use.

## What exists

- `rachel <dir>`: polls, runs `just check`, then `just test` if a check passed.
- `rachel check [--from-env] [--max-errors N] <dir> [paths...]`: one-shot, verdict
  lines on stdout, full compiler output on stderr.
- Station `--watch`: runs any command beside an agent and reports distinct stdout
  lines as `rachel_verdict`.
- e2e suite in Odin (`just e2e`), no shell scripts.

## Principles

1. **The verdict is the product.** One line answers "can I keep going"; more lines
   answer "what do I fix". Everything else is for humans in a terminal.
2. **Stages are ordered by cost, and stop at the first failure.** Compile errors
   make tests meaningless. A stage that cannot change the answer is not run.
3. **The project owns its commands.** Rachel runs justfile recipes; she does not
   learn Playwright, Go, or npm. New ecosystems arrive as recipes.
4. **Evidence is files, not prose.** Screenshots, logs and traces belong in a run
   directory with a manifest; the verdict points at them.
5. **POSIX only.** `core:sys/posix` is already used; Windows means WSL.
6. **No new runtime dependencies** beyond `odin`, `just`, and whatever a project
   recipe already needs.
7. **Every step is dogfooded** with `odin run src -- …` (never a prebuilt binary)
   against the real repository, before it is called done.

## Design

### Stages

| Stage | Command | Typical cost | Trigger |
|---|---|---|---|
| `check` | `just check` | < 1 s | every save |
| `test` | `just test` | 1–30 s | save, or verify |
| `e2e` | `just e2e` | seconds–minutes | verify / pre-commit |
| `browser` | project recipe (Playwright) | tens of seconds | pre-commit, CI |

Rachel never hardcodes a tool name for a stage. A stage is a recipe name, and the
project decides what it runs.

### `rachel verify`

```
rachel verify [--max-errors N] [--stages check,test] <project> [paths...]
```

- Runs stages in order; stops at the first failing stage unless `--all`.
- Emits one verdict per executed stage, tagged:

```
rachel: check ok (1 checked)
rachel: test fail (2 of 24): fmt_test.odin:12:test_expects_two() expected value() to be 2, got 1
rachel: error ... (1 more)
```

- Exit `0` only if every executed stage passed, `1` if any failed, `2` on usage.
- `--max-errors` applies per stage.

### Extraction

Each stage needs a rule that turns tool output into verdict lines:

- **check**: lines containing `Error:`, path relative to the project, capped.
  (Implemented.)
- **test**: Odin prints
  `[ERROR] --- [<timestamp>] [<file>:<line>:<test>()] <message>`; take the
  `file:line:test()` and the message, drop the timestamp. Fall back to the
  ` - <package>.<test>\t<message>` summary lines, then to the exit code.
- **e2e**: the project recipe's own output. Until a project needs more, reuse the
  test rule and the exit code.
- **browser**: same contract. A recipe printing `rachel:`-prefixed lines is taken
  as-is, so a project can own its verdict without Rachel understanding the tool.

Rules are capped (10 by default), deduped by message, and never include timestamps
or absolute paths.

### Evidence

A failing stage writes a run directory:

```
<project>/.rachel/evidence/<timestamp>-<stage>/
  manifest.json     stage, status, exit code, command, started/ended, duration,
                    changed paths, first failure, verdict lines, artifacts
  stdout.log        captured output
  artifacts/        screenshots, traces, diffs — whatever the recipe produced
```

- `rachel evidence last <project>` prints the most recent run directory, so an
  agent can read one line and then open specific files.
- Retention: keep the last 10 run directories; delete older ones on write.
- `.rachel/` is gitignored by the default justfile, or left untracked; the plan's
  tests assert it never becomes committed content.
- Evidence is written only on failure. A passing run writes nothing.

### Delivery

1. **stdout**: verdict lines, for a human or an agent's command output.
2. **evidence directory**: files, for an agent that needs to look.
3. **Station `--watch`**: already forwards distinct stdout lines as reports; a
   stage-tagged verdict needs no new protocol.
4. **Agent context** (later): an extension can deliver the verdict with
   `pi.sendMessage(..., {triggerTurn: false})`, so it rides the next turn instead
   of costing one. Not part of the slices below.

## Slices

Each slice is independently shippable, tested, and dogfooded.

**1. `verify` with `check` and `test`. — implemented**
Scope: the command, stage ordering, stage-tagged verdicts, the Odin test extractor.
Tests: extractor unit tests using real Odin output; e2e asserting a passing project
gives two `ok` stage lines and a failing test stops before later stages.
Done when `odin run src -- verify .` on this repository reports both stages.

Evidence: `odin run src -- verify .` reports `rachel: check ok (1 checked)` and
`rachel: test ok (24 tests)` in 1.9 s. A failing test in a temporary project reports
`rachel: test fail (1 of 1 tests)` and `rachel: error module.odin:12:test_wants_two()
expected value() to be 2, got 1`. `just test` (27) and `just e2e` (6) pass.

**2. `e2e` stage and `--stages`. — implemented**
Scope: third stage, `--stages` selection, `--all` to continue past failures.
Tests: stage selection; a failing `test` does not run `e2e` unless `--all`.

Evidence: `odin run src -- verify .` reports check and test; `--stages check`
reports only check; `--stages e2e` runs this repository's e2e recipe and reports
`ok (6 tests)`; a project whose test recipe declares `test: check` no longer runs
the check twice (`--no-deps`), taking verify from 1.85 s to 1.58 s; a stage with no
recipe prints `skip (no recipe)` and still exits 0.

**3. Evidence on failure.**
Scope: run directory, manifest, stdout capture, retention, `rachel evidence last`.
Tests: failing stage writes a manifest whose fields match the verdict; a passing
stage writes nothing; retention prunes to 10.

**4. Browser stage as a recipe.**
Scope: a stage name a project can wire to Playwright; `rachel:`-prefixed passthrough;
artifact collection from a directory the recipe names in its output
(`rachel: artifact <path>`).
Tests: a fake recipe proves the passthrough and artifact copy without a browser.
This is deliberately not a Playwright client: no node, no browser driver, no
screenshots taken by Rachel.

**5. Preconditions.**
Scope: cheap checks before stages — a dirty worktree, a stale generated justfile, a
port a recipe needs, a missing dependency directory. Each reports one line and never
blocks a stage Rachel cannot judge.
Tests: each precondition fires and stays quiet when satisfied.

**6. Delivery integration.**
Scope: document and test the Station `--watch` command that carries a verdict into
an agent without a tool call; add the extension snippet.
Done when an agent receives a `rachel_verdict` with no tool call, proven by a test.

## Non-goals

- No LLM inside Rachel. No summarising, no judgement beyond "stage passed".
- No browser driver, no node, no Playwright client.
- No daemon: every stage is a child process and Rachel exits.
- No Windows support outside WSL.
- No container dependency in the dev or test flow.
- No test framework abstraction: stages are recipes.

## Risks

- **Flaky browser stages teach readers to ignore the channel.** Mitigation: browser
  is never a save-triggered stage; a failure may be re-run once before it is
  reported, and evidence shows the trace.
- **Verdict volume.** Every extractor is capped and deduped; a stage that prints
  hundreds of lines must still produce one verdict line and a pointer to the log.
- **Evidence bloat.** Retention of 10 and failure-only writes bound it. Screenshots
  are the risk; the manifest should carry sizes so a future cap is possible.
- **Latency.** `odin run` rebuilds per iteration (~0.5 s). If verify becomes the
  default loop, build once per run rather than per stage.
- **Stale evidence.** A verdict must name the run directory it produced; an agent
  reading an old directory is the failure mode to design out.

## Findings from dogfooding

Recorded as they were found, because each one changed the design.

- **The check stage ran twice.** This repository's justfile declares `test: check`,
  so `verify` executed the check, then the test recipe ran it again. Stages now run
  with `just --no-deps`: verify has already run the earlier stage, and a recipe
  dependency would repeat it. Any project that relies on a dependency's side effects
  must do that work inside the stage itself.
- **Two lines per run is the right shape.** No summary line is needed: the exit code
  answers "did everything pass", and one line per stage answers "where". A third
  summary line was written and removed.
- **A missing recipe must be a skip, not a failure.** Most projects have no `e2e`
  recipe; treating that as a failure would make `--stages check,e2e` useless.
  A skipped stage does not change the exit code.
- **Stage names must be validated at parse time.** A typo silently skipping a stage
  is the worst failure mode for a verifier, because the run looks green.
- **`just --summary` is a reliable recipe probe.** It prints space-separated recipe
  names and exits 0, which is cheaper and more stable than matching an error string.

## Open questions

1. Should `verify` reuse the check verdict line, or emit a single summary line and
   put per-stage detail behind `--verbose`? Current plan: one line per stage.
2. Where should evidence live for a Station worktree — under the worktree (simple,
   cleaned with it) or under the state root (survives)? Current plan: worktree.
3. Does an agent need a machine-readable manifest, or is `rachel: <stage> <status>
   <detail>` plus a directory path enough? Current plan: both, manifest is cheap.

## Test strategy

- Unit tests for every extractor and for manifest construction, using captured
  real output as the fixture text.
- e2e tests in the existing Odin package: real binary, temporary projects, real
  `just` recipes; skips only where an external tool is genuinely absent.
- Dogfooding after each slice: run the new command on this repository with
  `odin run src --`, and record what it got wrong before moving on.
