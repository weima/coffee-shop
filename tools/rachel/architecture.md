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
4. Rachel runs `odin check` for the affected package. Compile or syntax errors are shown as red, persistent errors with the file and compiler output. Test generation waits until the package parses successfully.
5. For production files, Rachel ensures the companion `<source-stem>_test.odin` exists, creating a minimal package test file if necessary. It compares procedure declarations with its last observed snapshot. A new procedure without an adjacent intent/contract comment gets a visible advisory warning. A documented new procedure without a matching test gets a test-generation request.
6. The generator adds a non-duplicate test directly to the matching test file. The write is limited to that file. Rachel then runs package tests and reports test failures or allocator-leak warnings as red errors.
7. Changes to test files run syntax checking and package tests, including Odin's memory tracking. They never trigger more test-file generation.

The feedback-loop diagram gives the ordered view. The file-routing diagram gives the file-classification decisions.

## Test generation and write safety

Automatic writes in v1 are limited to creating a missing companion `*_test.odin` file and adding generated tests to it. Test generation must not overwrite existing content or duplicate an existing test. Before writing, Rachel re-reads the destination so an edit made during generation is preserved. If a safe merge cannot be made, it reports a conflict and leaves the file unchanged. Generated code is checked and tested immediately; failed output remains visible for the developer to repair. Rachel does not retry indefinitely.

### Generator boundary recommendation

Rachel should depend on a small `Test_Generator` contract, not on Oreo, Pi, or any one agent harness. The recommended first transport is a user-configured local executable that exchanges a versioned JSON request/response over stdin/stdout. The request contains only the relevant procedure contract, source context, existing test contents, and package/check diagnostics; the response contains proposed test source, not tool calls or arbitrary file edits. Rachel owns writing that source into the matching test file and then validating it. Launch the configured command with an argument vector, apply a timeout, and treat it as a trusted local program running with the developer's permissions; this protocol is not a security sandbox.

This gives Rachel an open adapter seam without a plugin framework. A fake command can cover protocol and failure cases offline; adapters for different AI harnesses can be added independently. An Oreo adapter is a later option once Oreo has a stable host, agent loop, and provider-neutral call boundary. Oreo is not ready to serve this today: its current mainline provides the SQLite store, while the host/worker pool and agent loop remain planned and live provider work is gated on contract verification. Rachel should not wait for Oreo or become coupled to Pi.

The exact JSON fields and first real command remain implementation gates. Keep generation behind this one narrow adapter, and make all watcher, parser, compiler, and test-runner tests work with the fake command without credentials or network access.

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
