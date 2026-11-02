# Rachel

![Rachel mascot](../../assets/characters/rachel.svg)

Rachel is a local terminal assistant in development for people editing Odin code. Run her against a project directory; she watches saved `.odin` files and gives fast, visible feedback without taking control of production source.

## Intended loop

```sh
cd tools/rachel
just run /path/to/odin-project
```

Rachel currently polls for Odin file updates every 250 ms, coalesces changes for a 350 ms quiet period, and runs the watched project's `just check` and `just test` recipes. If no root justfile exists, she creates a starter with those recipes and package arguments. Test failures and allocator-leak diagnostics become `[ERROR]` terminal feedback. On a changed production file, Rachel creates its missing companion test file without overwriting an existing file. She warns about newly added procedures without intent comments and production-looking code in newly created `*_test.odin` files. When `RACHEL_TEST_GENERATOR` is configured, she can generate and validate tests for documented procedures without a matching test.

```sh
RACHEL_TEST_GENERATOR=/path/to/local-generator just run /path/to/odin-project
```

The project justfile is left untouched when present. Rachel creates the starter only when none exists; see [justfile integration](architecture.md#justfile-integration).

The generator is a trusted local executable. It reads one versioned JSON request from stdin and returns test source as JSON on stdout; see [the protocol](architecture.md#local-generator-protocol).

## One-shot check

`rachel check <project-directory> [path ...]` runs the checks once and exits: `0`
when every check passes, `1` when one fails, `2` on a usage error. Every line it
prints starts with `rachel:`, so a line reader can filter on that prefix.

```
rachel: ok (2 checked)
```

On failure it prints a summary and then one line per distinct error, with paths
relative to the project and no source snippet:

```
rachel: fail (1 of 2, 3 errors)
rachel: error module.odin(4:2) Error: Expected 1 return values, got 0
rachel: error module.odin(10:2) Error: Expected 1 return values, got 0
rachel: error util.odin(9:1) Error: Other failure
```

`--max-errors N` sets the budget, because the two callers want opposite things.
The default is 10: enough for an agent to fix several problems from one read
without running the compiler again. A human at a terminal usually wants the first
problem and knows the rest are there, so they pass `--max-errors 1`:

```
rachel: fail (1 of 1, 3 errors)
rachel: error module.odin(4:2) Error: Expected 1 return values, got 0
rachel: error ... (2 more)
```

`--max-errors 0` lists every distinct error. Distinctness is by message, so a
repeated diagnostic does not repeat. The full compiler output, including
snippets, always goes to stderr; the budget only shapes the verdict lines.

A `path` narrows the check to the package of that `.odin` file. Any other path,
an empty list, or a path outside the project checks the whole project, so a check
is never skipped. A hand-written justfile takes no package argument, so it always
checks the project once.

This is the form a file watcher drives. `--from-env` reads the paths a watcher
reported for the current batch from `$WATCHEXEC_COMMON_PATH`,
`$WATCHEXEC_WRITTEN_PATH`, `$WATCHEXEC_CREATED_PATH`, `$WATCHEXEC_REMOVED_PATH`,
`$WATCHEXEC_RENAMED_PATH`, `$WATCHEXEC_META_CHANGED_PATH` and
`$WATCHEXEC_OTHERWISE_CHANGED_PATH`, and narrows the check to those packages:

```sh
watchexec -q --debounce 500ms --exit-on-eof -f '*.odin' \
  --emit-events-to=environment -- \
  rachel check --from-env /path/to/odin-project
```

`-q` matters for a machine reader: without it watchexec prints its own
`[Running: ...]` and `[Command was successful]` lines into the same stream, and
they are not verdicts.

watchexec is then the one owner of the quiet period. Without `--from-env`, or
when the watcher reports no paths, the whole project is checked. `just
watchexec-e2e` proves the pair against a real watchexec run and skips when
watchexec is not installed.

## Verify

`rachel verify <project-directory> [path ...]` runs the check stage and, only if it
passes, the test stage. Each stage prints its own verdict:

```
rachel: check ok (1 checked)
rachel: test fail (1 of 2 tests)
rachel: error module.odin:12:test_wants_two() expected value() to be 2, got 1
```

Exit `0` only when every stage passed, `1` when one failed, `2` on a usage error.
`--max-errors`, `--from-env` and path arguments behave as they do for `check`.

Stages default to `check,test`. `--stages check,e2e` selects explicitly, and
`--all` keeps going after a failing stage instead of stopping at it. A stage whose
recipe does not exist prints `skip (no recipe)` and does not change the exit code.
Stages after the first run with `--no-deps`, because verify already ran the earlier
one and a `test: check` dependency would repeat it.

The test stage runs the project's `test` recipe for every package that has a
`*_test.odin` file, or once for the whole project when the justfile is
hand-written. Odin's `[ERROR] --- [<timestamp>] [<location>] <message>` lines
become `<location> <message>`, with the timestamp dropped, the project root
stripped, duplicates removed and the list capped.

`odin run src -- verify .` on this repository reports `check ok (1 checked)` and
`test ok (24 tests)` in under two seconds.

## Test-file convention

- Production source uses names such as `memory_usage.odin`.
- Test source uses the reserved suffix `*_test.odin` and contains Odin tests.
- Rachel reserves `*_test.odin` for test source. Changes to these files are compile-checked and tested; automatic test generation will never create a companion such as `memory_usage_test_test.odin`.
- If a newly created `*_test.odin` file appears to contain production code rather than tests, Rachel gives a visible naming warning and suggests a production filename, for example `memory_usage.odin`.

Generated tests are written directly to the working tree. Rachel rechecks the source and test file before writing and leaves the file untouched if a concurrent edit is detected. Generated test code runs with the developer's normal permissions; the configured generator and generated code are not sandboxed. Rachel does not rewrite production source, run formatters over unrelated files, commit changes, or push branches.

## Status

The watcher, compile/test feedback loop, missing-intent warnings, test-filename conflict warnings, companion-test creation, and provider-neutral test-generation adapter are implemented. The adapter can use any trusted local command; Rachel does not own model credentials or depend on Pi. Further test-generation quality tuning and Linux verification remain open.

`cd tools/rachel && just test` passes 24 tests without allocator-leak warnings; `just build` succeeds. Linux verification remains outstanding.

`just e2e` runs the process-level tests in the `e2e` package (`odin test e2e`). They build the real binary and drive it against temporary projects, which the in-process tests cannot cover:

- the watch loop: startup check, a saved file, the missing-intent warning, companion test creation exactly once, and the package test;
- clean shutdown on SIGTERM;
- one-shot verdicts: every distinct error, relative paths, no snippets, and `--max-errors`;
- narrowing a check to the package of a changed file;
- a real `watchexec` run: `ok (2 checked)` at startup, a narrowed failure, recovery, and no banner lines in the verdict stream;
- human-speed typing: a fragment is written one byte at a time with pauses at line ends, and no check may fail while it is half-written.

`just typing-e2e` and `just watchexec-e2e` run those single tests by name. Everything is Odin: there are no shell scripts, and the only external dependencies are the `odin` and `watchexec` binaries. Tests pass on macOS; they have not been run on Linux.

The watcher overlaps with [watchexec](watchexec.md); that document compares them and records the integration options and the decision to keep the built-in watcher for now.

- [Watchexec comparison](watchexec.md)
- [Architecture and diagrams](architecture.md)
- [Implementation plan](PLAN.md)
- [Roadmap](ROADMAP.md)
- [Mascot](../../assets/characters/rachel.svg)
