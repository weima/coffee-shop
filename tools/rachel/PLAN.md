# Rachel Implementation Plan

Implement the smallest useful foreground watcher first. Keep generation and process execution behind narrow seams; do not build a daemon, editor extension, provider system, or configuration framework before the local feedback loop works.

## Phase 0 — Resolve implementation gates

- Confirm the recommended boundary: a versioned JSON request/response to a user-configured local generator command, with Rachel applying the returned test source. Keep the exact request fields and first real adapter as explicit decisions.
- Confirm how the target project root maps to Odin package directories and how ignored/generated directories are configured.
- Verify the pinned Odin commands and leak-diagnostic output used by the selected compiler.

**Gate:** the adapter contract is recorded, a fake generator can exercise it offline, and no network-dependent setup is required.

## Phase 1 — Watch and validate

- Add `rachel <directory>` CLI validation and foreground lifecycle.
- Watch `.odin` saves and coalesce events with a quiet-period debounce.
- Resolve changed files to package directories; run `odin check` through an argv-based process boundary.
- Capture exit status and output, retain compiler errors visibly, and recover after the next save.
- Serialize validations per package so process runs cannot race over one edit.

**Gate:** a real Odin syntax error appears promptly and clears after a successful edit; watcher shutdown leaves no child processes or allocator warnings.

## Phase 2 — Test-file routing and test health

- Reserve `*_test.odin` for test source and classify it before procedure analysis.
- When test source changes, syntax-check and run the owning package tests; do not generate a companion test file.
- Treat test failures and allocator-leak warnings as errors regardless of process exit code.
- Warn when a newly created `_test.odin` file appears to contain production code; recommend the corresponding non-test filename.

**Gate:** editing a test file never creates another test file, and a reproducible failing/leaking test produces persistent visible error output.

## Phase 3 — Procedure contracts and test generation

- Detect newly added procedures after a successful package check.
- Warn when a procedure lacks an adjacent intent/contract comment. Keep this advisory; do not block compilation or generation of other procedures.
- Ensure each observed production module has a matching `<source-stem>_test.odin`; create a minimal package test file directly if absent.
- For a documented procedure with no corresponding test, request test source through the selected adapter and write it directly into that file; otherwise add a non-duplicate test without replacing human changes.
- Check and run tests after writing. Report generation conflicts and failed generated tests; do not auto-retry indefinitely.

**Gate:** a fixture procedure with a contract generates a test once, in the right file, and the result is validated; an undocumented procedure produces a warning only.

## Phase 4 — Hardening and usability

- Verify save coalescing, atomic-save rename behavior, deleted/moved files, rapid repeated edits, and clean shutdown.
- Test process output, nonzero exits, leak-diagnostic parsing, and terminal output with fake Odin/generator executables.
- Run on Linux and macOS. Add only the minimum configurable debounce/ignore options supported by observed needs.

**Gate:** focused and full tests pass without allocator leak warnings on both platforms; no test contacts a live AI service.

## Out of scope for the first release

- Editor/LSP integration, background daemon, automatic production-code rewrites, Git operations, remote test execution, or an owned model/authentication client.
