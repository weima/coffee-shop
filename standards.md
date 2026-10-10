# Coffee Shop Standards

This file defines the coding and test standards for the Coffee Shop repository. Apply it with the [architecture](docs/architecture.md) and [implementation plan](PLAN.md); the architecture and plan define project behavior, while this file defines implementation quality.

## Project boundaries

- Keep Coffee Shop a local Odin CLI that dispatches explicit work to Pi Workers in isolated Git worktrees and Herdr tabs.
- Keep task decomposition with the Barista and integration decisions with the developer.
- Do not add automatic task decomposition, merges, publishing, PR creation, remote workers, alternate harnesses, or a daemon without explicit approval.
- Use one Herdr workspace per Brew and one tab per Shot. Do not add tmux or zmx backends without explicit approval.
- Preserve the boundary between Worker-authored changes and Filter verification. Filter reports review and test evidence; it does not rewrite repository test commands or configuration.

## Odin implementation

- Use the official Odin monthly release `dev-2026-10` (compiler version `dev-2026-10-nightly:84bc3fc`) as the supported compiler. Odin has no semver-stable release, so pin one official `dev-YYYY-MM` release and verify its archive checksum. Check version-sensitive behavior against it and the official Odin documentation; update this pin deliberately, and re-run the whole suite when you do.
- Treat each source directory as an Odin package. Keep files in one package when they share declarations; create a subpackage only for a clear responsibility or API boundary.
- Prefer Odin's `core:` libraries and existing project code. Add third-party source only for a concrete need, and record its upstream, exact version or commit, and license.
- Make ownership and lifetime explicit. Match each allocation to its allocator and owner; release owned memory and operating-system resources on every exit path.
- Handle errors at the layer with enough context to recover or report them. Do not use a result after failure, or report success when state is uncertain.
- Return an error when an allocation holds user-supplied data or the caller can reasonably recover. For a small internal value built from known parts, such as a file path, an `assert` with a clear message is acceptable: Odin's allocators give no useful way to continue after exhaustion, and threading an error through every caller adds noise without adding recovery.
- Keep CLI output predictable: write normal results to stdout, diagnostics to stderr, and return a non-zero status on failure.
- Pass executable arguments as an argument vector. Never build shell commands from an Order, Shot, or other task text.

## Tests and verification

- Test observable behavior through public interfaces. Do not test implementation text or private details.
- Use Odin's test runner for package behavior. Cover input validation, state transitions, process failures, recovery, and result collection as those features are implemented.
- Treat allocator leak warnings as test failures, even if Odin exits with code 0. A suite is clean only when it passes without leak warnings; investigate and fix leaks, especially in long-running code.
- Test Git and process boundaries with temporary repositories and fake Pi executables. Tests must not contact GitHub or an AI service.
- Run the repository's existing test and build commands without replacing or silently narrowing them. If a required command or test setup is unclear, report the gap instead of inventing project configuration.
- For behavior changes, use Taste-Driven Development: write a focused failing test first, make the smallest change that passes, then refactor while tests stay green.

## Review

- Check changes against this file, `docs/architecture.md`, and `PLAN.md`.
- Keep changes within the approved scope. Report unresolved requirements, failed checks, and unavailable test setup; never hide them to claim completion.

## References

- [Odin language overview](https://odin-lang.org/docs/overview/)
- The [Odin in Practice references](PLAN.md#verification-and-implementation-references) cover CLI contracts, process arguments, memory ownership, errors, and bounded concurrency.
