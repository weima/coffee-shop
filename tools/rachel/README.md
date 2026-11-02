# Rachel

![Rachel mascot](../../assets/characters/rachel.svg)

Rachel is a local verifier for a project directory: it runs the project's checks and
tests, prints a verdict a human or an agent can act on, and keeps evidence when
something fails. It is not tied to Odin; see [Languages](#languages) and
[Project commands](#project-commands).

## Intended loop

`watchexec` decides when to run:

```sh
watchexec -q -d 500ms -f '*.odin' --emit-events-to=environment -- \
  rachel verify --from-env /path/to/project
```

or, when the project has a `.rachel.json`:

```sh
rachel watch /path/to/project
```

Rachel does not watch anything itself: a file watcher is the one thing every
language needs and none should write again. With no `.rachel.json`, the stages are
the project's `just check` / `just test` recipes (a starter justfile is created
when none exists); with one, the project names its own commands.

The project justfile is left untouched when present. Rachel creates the starter
only when none exists; see [justfile integration](architecture.md#justfile-integration).

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

## Project commands

Rachel does not need to know a project's language. A project can name its own
stages in `.rachel.json` at its root; Rachel runs them, normalizes the output into
the same verdict, and writes the same evidence:

```json
{
  "version": 1,
  "stages": {
    "check": {
      "command": ["sh", "-c", "odin check src && (cd go && go vet ./...) && ./node_modules/.bin/tsc --noEmit -p tsconfig.json"],
      "filters": ["*.odin", "*.go", "*.ts", "*.json", "justfile"]
    },
    "test":  { "command": ["sh", "-c", "odin test src && bun run guard/selftest.ts"], "filters": ["*.odin", "*.ts"] },
    "e2e":   { "command": ["sh", "-c", "odin test e2e && (cd go && go test ./...)"], "filters": ["*.odin", "*.go"] }
  }
}
```

- `command` is an argv array, so no shell is implied; use `["sh","-c","..."]` when
  a stage needs a pipeline.
- `filters` are watchexec patterns used by `rachel watch`.
- `working_dir` is optional, relative to the project.
- A stage with a command replaces the justfile path entirely: no package
  narrowing, and no starter justfile is written.

`rachel watch <dir>` is a thin watchexec launcher: it builds

```
watchexec -q -d 500ms -w <dir> -f <filter>... -- <rachel> verify --from-env <dir>
```

and runs it. The trigger is watchexec; Rachel stays the checker, verdict and
evidence. A project with no `.rachel.json` still gets a watcher: no filters are passed, so
watchexec watches the tree (honouring `.gitignore`) and `verify` falls back to the
project's justfile recipes. `watch` therefore works for any project, configured or
not.

Run `watch` from an **installed** Rachel, not from `odin run`: `odin run` rebuilds a
temporary binary in the project directory, and a watcher that captured that path
fails on its next batch when the binary is replaced.

The configuration at this repository's root is the worked example: Odin, Go and
TypeScript in one project, with the fast stages in the loop and the slow Go suite
in `e2e`.

## Languages

Rachel runs the project's `check` and `test` recipes, so any toolchain works when
the project writes them. Two languages are first-class:

| | Odin | TypeScript |
| --- | --- | --- |
| Detection | any `.odin` at the project root | `tsconfig.json` or `package.json`, when the root has no `.odin` |
| Starter recipe | `odin check -no-entry-point <package>` per package | `tsc --noEmit` |
| Diagnostics | `file(line:col) Error: ...` | `file(line,col): error TSxxxx: ...` |
| Precondition | the Odin toolchain, implied | `tsc` on PATH, checked only when Rachel generated the recipe |

A generated TypeScript recipe takes and ignores the package argument, so the
per-package call path is unchanged, and a project with no Odin packages still gets
one whole-project call instead of "0 checked". There is no default `test` recipe
for TypeScript: add one for your runner and `verify` will use it.

`rachel <dir>` is a one-shot `verify`; watching is `rachel watch`, which is
language-agnostic.

## Concurrency

A verdict measured while another suite is running is not a verdict: two Odin suites
at once were enough to make `git init` fail inside test fixtures. `verify` therefore
takes a machine-wide lock before running stages.

- default: wait for the lock, and say so on stderr;
- `--no-wait`: fail at once with `rachel: fail (precondition): another verify is running`;
- `--no-lock`: skip locking;
- `--lock-path <path>`: use another lock file (CI shards, tests).

It is an advisory `fcntl` record lock, released by the kernel when the process
exits, so a crashed run cannot wedge it. `RACHEL_LOCK_PATH` overrides the default
`$HOME/.rachel/machine.lock`. The e2e suite gives each verify its own lock and has
one contention test that starts two against a single lock.

## Evidence

A failing stage writes a run directory and prints where it went:

```
rachel: evidence .rachel/evidence/01793595995993020000-test
```

```
.rachel/evidence/<id>/
  manifest.json   stage, status, recipe, exit code, started_ns, duration_ms,
                  tests, failure_count, verdict lines, and the paths checked
  verdict.txt     the same verdict lines, one per line
```

Only failures write evidence; a passing stage leaves nothing. The newest 10 run
directories are kept and older ones are deleted on write. `rachel evidence last
<project>` prints the newest run directory. `.rachel/` is gitignored.

## Status

The verdict and evidence layer is the product: a stage ladder with stage-tagged verdicts, capped and de-duplicated diagnostics, failure evidence, a `.rachel/last.json` signal, and project-owned commands. The Odin-only polling watcher and its scaffolding (companion test files, intent-comment warnings, test generation) are retired: a file watcher is watchexec's job, and those rules only served one language. Linux verification remains open.

`cd tools/rachel && just test` passes 34 tests without allocator-leak warnings; `just e2e` runs 9 process-level tests. `just build` succeeds. Linux verification remains outstanding.

`just e2e` runs the process-level tests in the `e2e` package (`odin test e2e`). They build the real binary and drive it against temporary projects, which the in-process tests cannot cover:

- the check and test stages on real projects, including TypeScript;
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
