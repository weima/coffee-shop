# Rachel and watchexec

## What watchexec is

[watchexec](https://github.com/watchexec/watchexec) is a standalone file watcher that
runs a command when files change. It is language-agnostic and ships for Linux,
macOS, Windows, and BSD.

## Overlap with Rachel

Rachel contains a watcher. watchexec is a more mature watcher. The overlap is the
change-detection layer only.

| Concern | Rachel | watchexec |
|---|---|---|
| Change detection | Polls every 250 ms, rescans the whole tree, re-scans after a 350 ms quiet period | Native OS events with coalescing |
| Change identity | Same path with different size or mtime | Typed written/created/removed/renamed events |
| Ignore rules | Hardcoded `.git`, `build`, `dist`, `node_modules` | `.gitignore`, `.ignore`, glob filters |
| Extension filter | `.odin` only | `-e odin` |
| Command args | Per-package `just check` / `just test` | Whatever is passed; changed paths in `$WATCHEXEC_*` or JSON on stdin |
| Process control | Runs and waits | Process groups, restart, clearscreen, desktop notify |
| Platforms | Portable Odin; Linux untested | Verified cross-platform |
| Odin rules | Intent comments, test-file naming, companion tests, generator hook | None |

The Odin rule layer is Rachel's actual product. No generic watcher can supply it.

## Integration shapes

### Shipped: standalone watcher

`rachel <project-dir>` polls and validates on its own, with no external
dependency. This is the current implementation and the default experience.

### Cheap alternative: watchexec drives a one-shot Rachel

```sh
watchexec -e odin --emit-events-to=environment -- rachel <project-dir>
```

Rachel reads `$WATCHEXEC_COMMON_PATH`, `$WATCHEXEC_WRITTEN_PATH`,
`$WATCHEXEC_CREATED_PATH`, and `$WATCHEXEC_REMOVED_PATH`, maps changed paths to
packages, and runs one pass.

`rachel check <project> [path ...]` provides the one-shot half, and
`--from-env` reads the batch's paths from `$WATCHEXEC_*`, so the quiet rule is
owned by `--debounce` alone:

```sh
watchexec --debounce 500ms --exit-on-eof -f '*.odin' --emit-events-to=environment -- \
  rachel check --from-env <project>
```

Verified against watchexec 2.8.0 on macOS:

- The path variables are set for the command, joined by the platform path-list
  separator, and **relative to `$WATCHEXEC_COMMON_PATH`**, so a consumer must join
  them. `--from-env` does.
- The command runs once at startup before any event, with no `WATCHEXEC_*`
  variables set; `rachel check` then checks the whole project.
- With `--emit-events-to=json-stdio` the child's stdin closes at the end of a
  batch, so a one-shot reader is safe. The environment mode was chosen because it
  needs no JSON parser.
- A command that writes into the watched tree triggers itself. `rachel check`
  creates a starter justfile, which is not a `.odin` file, so the `-f '*.odin'`
  filter stops the loop; the e2e asserts the run count stays bounded.

This deletes roughly 250 lines: the project scan, the snapshot diff, and the
poll/debounce loop. It adds roughly 50 lines of environment parsing.

It also gains `.gitignore` support, real event delivery, configurable debounce,
and verified cross-platform behavior.

One rule does not survive unchanged. `new_procedure_contract_warnings` compares
the previous and current snapshot so it only warns about newly added procedures.
A stateless pass has no previous snapshot. The replacement rule warns about any
undocumented procedure in a file that just changed: louder, simpler, and closer
to the intent of the rule.

Every other behavior is already stateless and works in one pass: the
`*_test.odin` production-code warning, companion test creation, the generator
hook, and justfile creation.

### Expensive alternative: Rachel keeps its loop and parses watchexec events

Run watchexec with `--emit-events-to=json-stdio` and parse events from stdin.
This preserves exact semantics but adds a JSON protocol and a long-lived process
for no behavioral gain, because watchexec already delivers one event batch per
command invocation.

## Decision

The polling watcher stays while Rachel is standalone. If cross-platform support
or large source trees become a priority, take the cheap alternative above: it
removes more code than it adds and keeps the Odin rules.

watchexec is not installed on the development machine as of this writing.
`brew install watchexec` provides it. The environment-variable behavior above has
not been verified against a live watchexec run yet, so verify it before
committing to that integration.

## Verification

The watcher loop is covered end to end by `e2e/watcher_e2e.sh`, which runs the
real binary against a real Odin project:

```sh
just e2e
```
