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

1. The developer starts `rachel <project-directory>`. Rachel resolves the root and identifies Odin package directories beneath it, excluding `.git`, generated outputs, and configured ignored directories.
2. The watcher coalesces save events for a package during a short quiet period. It does not launch a new compiler or test process for every keystroke. At most one validation run per package is active; newer saves schedule one follow-up run.
3. Rachel classifies the changed file by filename. A file ending in `_test.odin` is test source, never a production source needing a companion test.
4. Rachel runs the project's `just check` recipe for syntax/compile validation. If the watched project has no root `justfile`, `Justfile`, or `.justfile`, Rachel creates a starter root `justfile` with `check package="."` and `test package="."` recipes that run Odin for the selected package. Compile or syntax errors are shown as persistent `[ERROR]` output; test generation waits until checks pass.
5. For a changed production file, Rachel ensures the companion `<source-stem>_test.odin` exists, creating a minimal package test file if necessary. It compares procedure declarations with its previous snapshot. A new procedure without an adjacent intent/contract comment gets a visible advisory warning. A documented procedure without a matching `@(test)` procedure triggers generation when a local generator is configured.
6. Rachel validates the generator's versioned JSON response, merges its imports, and atomically updates only the matching test file after checking that source and test contents did not change during generation. It then runs package tests and reports failures or allocator-leak warnings as red errors.
7. Changes to test files run `just test`, including Odin's memory tracking. They never trigger more test-file generation.

The feedback-loop diagram gives the ordered view. The file-routing diagram gives the file-classification decisions.

## Current implementation status

The first implementation uses portable directory polling every 250 ms and a 350 ms quiet-period debounce. It scans recursively and currently skips `.git`, `build`, `dist`, `node_modules`, symlinks, and special files. It caches procedure declarations for unchanged files, checks changed packages, and runs package tests when a `*_test.odin` file is present. New undocumented procedures and production-looking code in newly added test files produce advisory warnings. A changed production file gets a minimal companion test file using exclusive create. If `RACHEL_TEST_GENERATOR` names a local generator and a documented procedure has no matching test, Rachel requests and validates a generated test.

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

## Test generation and write safety

Automatic writes create a missing companion `*_test.odin` file with exclusive creation, then may add generated tests to that file. Rachel never rewrites production source. Before writing a generated test, Rachel re-reads the source and test file; if either changed during generation, it leaves the test file untouched and reports a conflict. It writes a replacement to a temporary directory beside the test file and renames it into place, preserving existing content and file permissions. It checks for a matching test first to avoid duplicates. Generated code is compiled and tested immediately; failures remain visible. Rachel does not retry indefinitely.

### Local generator protocol

Set `RACHEL_TEST_GENERATOR` to one executable path before starting Rachel. Rachel invokes that executable directly (argv, no shell), passes one UTF-8 JSON request on stdin, and reads one JSON response from stdout. Use a wrapper script if a particular harness needs extra flags or configuration. Rachel waits at most two minutes, kills a timed-out child, captures stderr for diagnostics, and has no built-in provider or credential flow. If the variable is unset, Rachel creates the companion test file and warns that it cannot generate test cases.

Request v1 fields are `protocol_version` (1), `kind` (`generate_odin_test`), `package_dir`, `source_path`, `procedure_name`, `procedure_line`, `source_text`, `test_path`, and `existing_test_source`. The response v1 fields are `protocol_version` (1), `imports` (package paths), and `test_source` (one or more `@(test)` procedures). Test names must start with `test_<procedure-name>`; Rachel treats an existing `test_<procedure-name>` or `test_<procedure-name>_*` as coverage. Generated source cannot add a package declaration, import statement, `#run`, or foreign import. Put additional packages in the response `imports` array.

This is a small adapter protocol, not a plugin framework. A fake executable covers the protocol offline; wrappers for different AI harnesses can be written independently. An Oreo adapter is a later option once Oreo has a stable host, agent loop, and provider-neutral call boundary. Rachel should not wait for Oreo or become coupled to Pi.

**Trust boundary:** the configured executable runs with the developer's normal permissions and may access the network. Generated test code also runs as the developer when Odin tests execute; neither process is sandboxed. Configure only a generator you trust and inspect generated code when appropriate. Rachel limits its writes to the matching test file but cannot make arbitrary executable code safe.

## Candidate AI-assisted development flow (experimental)

This is an opt-in alternative to having an AI make a broad change and run the full unit and end-to-end suites at the end. The approach is not yet the project's default; dogfood it on an Oreo vertical slice and compare the developer experience and quality before choosing a default.

1. Before editing anything under `oreo/`, run Rachel's `cd tools/rachel && just test && just build` checks. Start Rachel watching the Oreo project directory with `RACHEL_TEST_GENERATOR` unset so the coding agent authors the TDD tests and Rachel does not compete by generating them.
2. Use the current development worktree's Herdr workspace. Keep a human Git-operations tab and a separate Rachel tab rooted at the worktree; launch Rachel on `<worktree>/oreo` in its tab.
3. Write one failing Odin test for the next behavior under `oreo/`, save it, and wait for Rachel's check/test output before changing implementation code. The agent reads the Rachel pane with Herdr's `pane read --source recent-unwrapped` (or `pane wait-output`) so its decisions are based on Rachel's actual diagnostics, not assumptions.
4. Implement the smallest change that makes the test pass. After each save, wait for Rachel's result. A valid Oreo compile/test/leak error means Rachel is working: keep her running and fix Oreo. If Rachel itself crashes, stops observing edits, or emits demonstrably incorrect feedback, stop the watcher and make no further Oreo edits; fix Rachel, run its own tests/build, restart it, and verify the loop before resuming Oreo.
5. Keep Rachel and the development tabs available during the task and review. After all vertical slices are green, run the complete unit and end-to-end suites once as the integration gate; do not run the full E2E suite after every keystroke. Close the tabs and remove the worktree only after human confirmation that the PR is merged into the local root checkout and both checkouts are clean.
6. At the end of the trial, record what worked, where Rachel's feedback was late/noisy/incorrect, any regressions, and whether this loop should replace or complement the current batch-oriented AI workflow.

The `RACHEL_TEST_GENERATOR` adapter is deliberately disabled in this experiment: the TDD coding agent writes tests first, while Rachel independently validates each saved change. This avoids two generators competing to edit the same test file. Adoption as the default AI workflow requires a separate human decision.

## Odin file convention and recursion prevention

`*_test.odin` is reserved for test source. A test source file may contain procedures whose names include `_test`; filenames, not procedure names, determine routing. Rachel must never infer that `memory_usage_test.odin` needs `memory_usage_test_test.odin`.

When a newly created `_test.odin` file contains production-looking procedures but no Odin test declarations, Rachel warns that the name is reserved and suggests renaming the file (for example, `memory_usage_test.odin` → `memory_usage.odin`). This is advisory: it does not rename the user's file. The tool still checks and tests the package while the developer resolves the warning.

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
