# Rachel Implementation Plan

Implement the smallest useful foreground watcher first. Keep generation and process execution behind narrow seams; do not build a daemon, editor extension, provider system, or configuration framework before the local feedback loop works.

## Current progress

- Rachel polls every 250 ms, debounces saves for 350 ms, and runs package-level `odin check -no-entry-point .`.
- Packages containing `*_test.odin` run `odin test .`; test failures and allocator-leak diagnostics become errors.
- Changed production files get a companion test file without overwriting an existing one. Rachel warns about new procedures without intent comments and production-looking content in `*_test.odin` files.
- A configured `RACHEL_TEST_GENERATOR` executable receives a versioned JSON request over stdin and returns proposed test source as JSON over stdout. Rachel validates the response, writes only the matching test file, and runs the package tests. No harness is bundled.
- `cd tools/rachel && just test` passes 12 tests without allocator-leak warnings; `just build` passes. Manual temporary-project smoke checks cover watcher feedback, warnings, companion creation, and a fake-generator round trip.
- Linux verification and a real user-configured generator wrapper remain outstanding.

## Phase 0 — Resolve implementation gates

- The generator protocol is fixed at v1 in [architecture.md](architecture.md); verify the user's wrapper against it before relying on an external harness.
- Confirm how the target project root maps to Odin package directories and how ignored/generated directories are configured.
- Verify the pinned Odin commands and leak-diagnostic output used by the selected compiler.

**Gate:** the configured wrapper can satisfy the protocol; watcher and fake-generator tests remain offline.

## Phase 1 — Watch and validate

- Add `rachel <directory>` CLI validation and foreground lifecycle.
- Watch `.odin` saves and coalesce events with a quiet-period debounce.
- Resolve changed files to package directories; run `odin check -no-entry-point .` through an argv-based process boundary.
- Capture exit status and output, retain compiler errors visibly, and recover after the next save.
- Serialize validations per package so process runs cannot race over one edit.

**Gate:** a real Odin syntax error appears promptly and clears after a successful edit; watcher shutdown leaves no child processes or allocator warnings.

## Phase 2 — Test-file routing and test health

- Reserve `*_test.odin` for test source and classify it before procedure analysis.
- When an affected package contains test source, syntax-check and run `odin test .`; do not generate a companion test file from a test-file change.
- Treat test failures and allocator-leak warnings as errors regardless of process exit code.
- Warn when a newly created `_test.odin` file appears to contain production code; recommend the corresponding non-test filename.

**Gate:** editing a test file never creates another test file, and a reproducible failing/leaking test produces persistent visible error output.

## Phase 3 — Procedure contracts and test generation

- Detect newly added procedures after a successful package check.
- Warn when a procedure lacks an adjacent intent/contract comment. Keep this advisory; do not block compilation or generation of other procedures.
- Ensure each observed production module has a matching `<source-stem>_test.odin`; create a minimal package test file directly if absent.
- For a documented procedure without a matching `test_<procedure>` or `test_<procedure>_*`, request test source through `RACHEL_TEST_GENERATOR` and write it directly into the companion file. Skip generation when no generator is configured or matching coverage already exists.
- Check and run tests after writing. Report generation conflicts and failed generated tests; do not auto-retry indefinitely.

**Gate:** a fixture procedure with a contract generates a test once, in the right file, and the result is validated; an undocumented procedure produces a warning only.

## Phase 4 — Hardening and usability

- Verify save coalescing, atomic-save rename behavior, deleted/moved files, rapid repeated edits, and clean shutdown.
- Test generator JSON rejection, nonzero exits, timeout termination, concurrent file edits, import merging, and duplicate detection with fake executables.
- Run on Linux and macOS. Add only the minimum configurable debounce/ignore options supported by observed needs.

**Gate:** focused and full tests pass without allocator leak warnings on both platforms; no test contacts a live AI service.

## Out of scope for the first release

- Editor/LSP integration, background daemon, automatic production-code rewrites, Git operations, remote test execution, or an owned model/authentication client.
