# Rachel Architecture

## Purpose

Rachel is a local terminal process that watches one Odin project directory and gives a developer a short feedback loop while they edit. It is an assistant, not an autonomous maintainer: it may create or update matching test files, but it does not edit production procedures, run Git operations, or contact remote services unless a later implementation explicitly configures a test-generation backend.

## Runtime boundary

```text
Human developer
      │ edits and saves
      ▼
Watched Odin project ── file changes ──▶ Rachel
                                         ├─ classify file/package
                                         ├─ inspect proc docs/tests
                                         ├─ run Odin check/test
                                         ├─ optionally generate test source
                                         └─ report persistent terminal status
```

The runtime sequence is shown in [the feedback-loop diagram](diagrams/feedback-loop.png); [the file-routing diagram](diagrams/file-routing.png) documents the test-file recursion guard and naming warning.

## Processing flow

1. `watchexec` watches the project and runs `rachel verify --from-env <dir>` per
   batch, with the filters the project configured. Rachel itself never watches.
2. `verify` runs the selected stages in order — `check`, `test`, `e2e` — and stops
   at the first failure unless `--all`. A stage is either a command from
   `.rachel.json` or the project's justfile recipe.
3. Each stage's output is normalized into verdict lines: a stage summary, then up
   to `--max-errors` distinct diagnostics with the project root stripped.
4. A failing stage writes `.rachel/evidence/<run>/` (manifest plus verdict text) and
   prints one `rachel: evidence <path>` line.
5. Every run writes `.rachel/last.json` with the stage list, `ok`, and the verdict
   lines, so a reader — or the guard — has one small current signal.
6. `rachel watch <dir>` is a thin launcher for watchexec; the built-in poller and
   its Odin-only scaffolding are retired.

## Current implementation status

The verdict and evidence layer is the product. Stages come from the project, so
Rachel is language-agnostic: this repository runs Odin, Go and TypeScript in one
`.rachel.json`, and Odin and TypeScript have first-class defaults (starter recipe,
diagnostic extraction). The polling watcher, companion test creation, intent
warnings and test generation are retired.

## Justfile integration

A root `justfile`, `Justfile`, or `.justfile` is the project's test/build contract. Rachel runs its `check` and `test` recipes instead of guessing direct Odin commands; custom recipes may compile bundled C code, pass collection flags, or run other required setup. If none exists, Rachel creates a starter root `justfile` without overwriting a concurrent user file:

```just
set shell := ["sh", "-cu"]

check package=".":
    odin check -no-entry-point {{quote(package)}}

test package=".":
    TZ=UTC odin test {{quote(package)}}
```

For the generated file, Rachel passes each affected package as a recipe argument. For an existing justfile, Rachel runs its root-level `check` and `test` recipes. If a required recipe is missing or fails, the diagnostic is visible; Rachel does not replace or silently bypass the project's commands.

## Retired: Odin-only scaffolding

The built-in polling watcher, companion `*_test.odin` creation, missing-intent
warnings, test-filename warnings and the local test-generation adapter are gone.
They were reachable only from that watcher, and they served one language. Watching
is `watchexec`; the Odin rules became a language profile that the project's own
`check` recipe can run. The generator protocol section is kept in history, not in
the product.

## Candidate AI-assisted development flow (experimental)

This is an opt-in alternative to having an AI make a broad change and run the full unit and end-to-end suites at the end. The approach is not yet the project's default; dogfood it on an Oreo vertical slice and compare the developer experience and quality before choosing a default.

1. Before editing anything under `oreo/`, run Rachel's `cd tools/rachel && just test && just build` checks. Start Rachel watching the Oreo project directory with `RACHEL_TEST_GENERATOR` unset so the coding agent authors the TDD tests and Rachel does not compete by generating them.
2. Use the current development worktree. Keep one terminal pane for human Git operations and a separate pane running Rachel, rooted at the worktree; launch Rachel on `<worktree>/oreo` in that pane.
3. Write one failing Odin test for the next behavior under `oreo/`, save it, and wait for Rachel's check/test output before changing implementation code. The agent reads Rachel's pane output directly, so its decisions are based on Rachel's actual diagnostics, not assumptions.
4. Implement the smallest change that makes the test pass. After each save, wait for Rachel's result. A valid Oreo compile/test/leak error means Rachel is working: keep her running and fix Oreo. If Rachel itself crashes, stops observing edits, or emits demonstrably incorrect feedback, stop the watcher and make no further Oreo edits; fix Rachel, run its own tests/build, restart it, and verify the loop before resuming Oreo.
5. Keep Rachel and the development panes available during the task and review. After all vertical slices are green, run the complete unit and end-to-end suites once as the integration gate; do not run the full E2E suite after every keystroke. Close the panes and remove the worktree only after human confirmation that the PR is merged into the local root checkout and both checkouts are clean.
6. At the end of the trial, record what worked, where Rachel's feedback was late/noisy/incorrect, any regressions, and whether this loop should replace or complement the current batch-oriented AI workflow.

In this experiment the TDD coding agent writes tests first, while Rachel independently validates each saved change. Test generation is not part of Rachel; adoption of the flow requires a separate human decision.

## Terminal feedback

- Errors (compile failures, test failures, or allocator leak reports) use a stable `[ERROR]` marker, red styling when supported, and retained output until a later successful run. Color is not the only signal; respect `NO_COLOR`.
- Advisory contract and naming findings use `[WARN]` with the file and procedure/line where available.
- Successful checks show the package, check/test status, and elapsed time without flooding the terminal.
- The watcher remains interactive in the foreground. It does not take over the developer's editor or package command.

## Process and platform constraints

Invoke Odin using an argument vector, not a shell command built from project paths. Capture stdout and stderr separately, preserve exit codes, and classify allocator-leak diagnostics as failures even if `odin test` exits successfully. The intended targets are macOS and Linux. Watcher implementation should prefer Odin/OS facilities already available in the project; do not add a third-party watcher dependency until the standard-library option has been tested on both targets.

## Design diagrams

- [Feedback loop source](diagrams/feedback-loop.html) · [PNG](diagrams/feedback-loop.png)
- [File routing source](diagrams/file-routing.html) · [PNG](diagrams/file-routing.png)
