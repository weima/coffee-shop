# v0.6 design — the Barista-to-Station subsystem in Go

**Status:** approved direction, not implemented. Written 2026-10-31.

## Why

The developer decided to move the substrate between the Barista and its Stations from
Odin to Go, because getting it right in raw Odin has proven unreliable. The v0.5 record
is the evidence:

- A ledger map key allocated on `context.temp_allocator` was freed at the end of a turn
  and then dereferenced, crashing the host after its first report (#144).
- A routed cancel could not reach a Station blocked on a model reply, because only the
  typed-input reader looked at the flag while the main flow waited in a blocking read
  (#143).
- That same fix exposed a reap that could block forever on an agent that would not exit.
- The bounded per-Shot log rotated and kept the **first** bytes of an oversized read,
  losing the tail a person actually reads (#142).

Every one of those is manual memory ownership, blocking I/O, or process lifecycle —
the three things Go's runtime makes cheap. The workflow itself is not the problem.

## Decisions taken (2026-10-31)

1. **Go orchestrates, Odin works.** Go owns the host: the request and activity sockets, the dispatch queue and slot accounting, spawning and watching Station *processes*, the per-Shot log, the relay, the spool, history and the progress ledger. Odin keeps the actual work of a Station: the agent, its RPC lines and dialogs, the Taste, the commit, and the turn deadline and cancel propagation inside the Station. Odin also keeps the repository work: worktree create/remove, Blend, `pr`, `cleanup`, Filter.
2. **`csd` is extracted from the Odin binary**, the way the Pi extension is embedded today: the Go binary is `#load`ed at build time and written under `<state>/host/bin/` at host start, then executed. One user-facing binary, one build step.
3. **The queue stays in memory**, as v0.5 had it: a host restart drops queued Shots and says so. Durability applies to *reports*, not to *intent*.
4. **Go best practice, not transliterated Odin.** The rules that follow are the ones this codebase earned.
5. **Go is assumed on the build machine.** `csd` is built from source on every `just build`; no Go binary is committed.

## What moves, and what does not

Two levels of supervision, and the boundary between them is the point:

| | Go (`csd`) | Odin (`coffee-shop`) |
|---|---|---|
| Owns | host loop, both sockets, dispatch acceptance, queue, slots, session table | CLI, Recipe parsing, Git worktrees |
| Supervises | the **Station process**: spawn, process group, bounded log pump, liveness, SIGTERM→SIGKILL | the **agent**: RPC lines, dialogs, turn deadline, cancel propagation, Taste, commit |
| Durability | spool, history, reports, ledger, alerts | Register, Receipt, Brew state |
| Repository work | calls Odin | worktree create/remove, Blend, `pr`, `cleanup`, Filter |
| One-shot path | none | `brew`, Workers |

The two levels mean a cancel has two steps, and both must stay: Go signals the Station, and the Station's existing cancel path stops the agent even when it is blocked on a model reply (#143). Go must never assume that killing the Station is enough — that leaves an orphan agent, which is the defect v0.4 paid for.

**The seam is a CLI contract.** Go does not link Odin code; it runs the Odin binary. Worktree creation and Station launch become explicit subcommands instead of host-internal calls:

- `coffee-shop prepare --repo R --branch B --dir D` — create the Shot's worktree, print nothing on success.
- `coffee-shop station …` — the existing command, unchanged.
- `coffee-shop pr …` / `coffee-shop cleanup …` — already explicit.
- `coffee-shop release --dir D --repo R` — remove a worktree after a terminal report, if `pr`/`cleanup` is not what does it.

Each seam command prints one JSON object on failure and exits non-zero; the host reports that reason verbatim. No seam command reads the host's sockets.

## The contract to freeze first

The port is only safe if the wire format is data, not prose. Phase 1 writes this down and
builds a conformance test around it.

**Sockets.** Both under `<state root>/host/`, both one JSON value per line.

- `activity.sock` — Stations report to the host. `Activity_Message`:
  `brew_id`, `shot_id`, `kind`, `description`, `timestamp_ns`, `spool`.
- `requests.sock` — a separate process delivers one request and reads one ack.
  Only `reply` is accepted, with exactly `type`, `request_id`, `shot_id`, `message`.
  Ack is `{"ok":true}` or `{"ok":false,"reason":"…"}`. The directory is 0700, the socket
  0600, and a `reply` is one line of at most `HOST_REPLY_MAX` bytes.

**Host stdout.** One JSON object per line. Fields: `type`, `request_id`, `at`, and
optionally `bytes`, `shot_id`, `pane_id`, `kind`, `description`, `reason`, `branch`,
`commit`. `at` is RFC 3339 UTC with exactly three millisecond digits and is the **last**
field. Event types in use today: `ready`, `received`, `dispatch_accepted`,
`dispatch_queued`, `dispatch_dequeued`, `session_started`, `session_failed`,
`session_report`/`station_report`, `reply_sent`, `cancelled`, `sessions`, `blended`,
`blend_failed`, `warning`, `error`, `stopped`.

**Exit codes.** `reply`: 0 delivered, 1 no host running, 4 socket unreachable,
5 refused. Host: 0 on `shutdown` or end of input, 1 on a startup failure.

**Durable state.** `<state>/host/<request>/history.ndjson` (one event per line),
`<state>/host/spool/<name>.json` (written before relay, removed after),
`<state>/host/<request>/logs/<shot>.log` (bounded, rotated to `.1`),
`<state>/host/reports/` (long report bodies, referenced as `file:`).

**Station command.** Unchanged argument surface:
`coffee-shop station --kind … --report … --station … --brew … --prompt-file … [--taste … --message …] [--interactive] [--codemode …] -- <agent argv>`.

## Go structure

One module at `go/` in this repository, one binary `csd`, standard library only in the
first pass:

```
go/
  cmd/csd/main.go          flag parsing, host run
  internal/proto/          event, message, request and ack types; JSON marshalling
  internal/host/           loop, stdin reader, listeners, dispatch, queue, slots
  internal/station/        Station process: spawn, process group, log pump, watch, cancel
  internal/session/        session table, process identity, liveness
  internal/state/          history, spool, reports, locks, paths
  internal/odincli/        the seam: prepare, station, pr, cleanup, release
```

The binary is built by `just build-go` and embedded by the Odin binary (`#load`), then
written to `<state>/host/bin/csd` at host start. Extraction is atomic: write a temporary
file, `chmod 0700`, rename over the old one, so a running host never execs a half-written
file. This mirrors `HOST_EXTENSION_SOURCE` and keeps one user-facing command.

Rules the port adopts deliberately, because each one is a bug we already paid for:

- Nothing is shared by pointer across a boundary without a copy; Go's GC removes the class
  of defect that killed the v0.5 host, but channels and maps still need one owner.
- Everything cancellable takes a `context.Context`; every child process is started with
  `exec.CommandContext` and `Setpgid`, and its exit is always waited for.
- A report is written to the spool and the history **before** it is announced on stdout.
- Logs are capped by an `io.Writer` that keeps the newest bytes and rotates once; a chunk
  larger than the cap is truncated from the **front**, not the back (#142).

## Go practice

These are the rules the first Go PR should follow, and the ones I would hold a review to.

1. **Standard library first.** No third-party dependency in phase 1–4. The port needs
   `net`, `os/exec`, `encoding/json`, `context`, `sync`, `os/signal`, `os`, `path/filepath`,
   `log/slog`. A dependency needs a stated reason in the PR, not a preference.
2. **One goroutine, one owner.** Every goroutine is started by a function that also owns
   its exit: a done channel, a `sync.WaitGroup`, or a context. No fire-and-forget. The
   host has exactly four long-lived goroutines: stdin reader, activity accept loop,
   request accept loop, and the session watchdog. The port should not add a fifth without
   saying why.
3. **`context` is the cancel path.** Deadlines and cancels travel in contexts, not in
   package globals. The v0.5 cancel bug was a flag that only one thread read; a context
   is read by everything that blocks.
4. **Never signal an unverified process.** Kill the process group only after matching the
   pid *and* its start time, as `child_launch.odin` does today. Use `cmd.Wait` exactly
   once, and never `Kill` after `Wait` returned.
5. **JSON is the contract.** Types live in `internal/proto` with explicit tags and `at`
   declared **last** so field order matches. `omitempty` cannot distinguish `0` from
   absent, so counts that can legitimately be zero use `*int`. Every wire change needs a
   conformance-test update in the same commit.
6. **Unix sockets the boring way.** `net.Listen("unix", path)`; `os.Chmod` the socket
   `0600` and its directory `0700`; unlink a stale socket only while holding the host
   lock; never accept a path longer than the `sun_path` limit.
7. **Errors are values with a reason string.** The wire format has no error codes, only
   `reason`, so wrap with `%w`, log the chain with `slog`, and send the sentence a person
   needs. Do not send a Go error's `Error()` containing internal paths.
8. **`go test -race` is mandatory**, and it is the point of the port: concurrency bugs are
   the reason for this release. Conformance tests are black-box (exec the binary, feed
   stdin, compare events), so they test the contract rather than the package layout.
9. **Table tests with `t.TempDir()` and `t.Cleanup`.** No shared machine state in tests: the
   v0.5 flake was process-global state under a 10-thread runner. Give every test its own
   state root and its own slots, as `standards.md` already requires.
10. **Platform edges stay behind build tags.** Group kill is `syscall.Kill(-pgid, …)` on
    Unix; WSL2 is Linux, so the tag set is `//go:build unix` and, if ever needed,
    `windows`. Nothing else in the host is platform-specific.
11. **`just` recipes, not shell scripts.** `just build`, `just check`, `just test` gain a
    Go half (`go vet ./...`, `go test -race ./...`), so the documented commands stay the
    only way to build and test, as `AGENTS.md` requires.
12. **Log, then leave.** `slog` for developer diagnostics, the JSON event stream for
    anything a consumer parses. Never write a diagnostic to stdout; stdout is the wire.

## Phases

1. **Contract + conformance harness.** Write the contract above as tests: feed a fixed
   request stream to a host, compare events field by field (timing excluded). Record the
   Odin host's current output as the golden baseline.
2. **The Odin seam.** Add the subcommands Go needs — `prepare`, `release`, and the existing
   `station`/`pr`/`cleanup` — with a JSON failure shape and non-zero exit. No behaviour
   change to the host; the Odin host keeps working.
3. **The Go orchestrator.** `csd` runs the host: loop, listeners, dispatch, queue, slots,
   Station spawn and watch, log pump, relay, spool, history, ledger, cancel escalation.
   Behind `coffee-shop host --impl=go`, headless only, no pane backend compiled in. The
   Odin Station keeps the turn deadline and the #143 cancel path, and its regression tests
   stay green.
4. **Cutover and deletion.** Make the Go host the default, delete the Odin host loop, then
   do the v0.5 Wave 3 deletions: `pane_pool.odin`, `pane_backend_herdr.odin`,
   `pane_clear.odin`, the pool half of `host_pane_pool.odin`, `host_pool_persistence.odin`'s
   pane recovery, `pr.odin`'s pane discovery, `settle.odin`'s tab close,
   `docs/tab-lifecycle.md`, the guardrail line, and the six tests that fake Herdr.
5. **Measure.** The same five-Shot run on macOS and WSL2: wall-clock per Shot, host CPU
   and resident memory, before and after. The WSL2 half needs that machine.

## Gates

- **Conformance:** the same request stream produces the same events, field for field,
  from both implementations.
- **Lifecycle:** a cancel stops a Station blocked on a model reply within seconds, and
  leaves no orphan agent behind.
- **Durability:** kill the host mid-run; every terminal report is relayed or recoverable
  after restart, with no log reading.
- **Concurrency:** five Stations hold five Slots and a sixth waits, sustained, with a
  timed report — the gate v0.5 did not prove.
- **Parity:** the existing suite stays green at every phase; no test is weakened.
- **No Herdr:** the Go host runs with no `herdr` on `PATH` and no pane code compiled in.

## Risks

- **Two implementations drift.** Mitigated only by the conformance suite being the merge
  gate; if it is skipped, the port is worse than the original.
- **The seam is a process boundary.** Every dispatch now costs one Odin process for
  `prepare` and one for `station`. Measured, not assumed: phase 5 records it.
- **Two cancel paths must both work.** Go's escalate-to-Station and the Station's
  stop-the-agent are separate code in separate languages; a test must cover the blocked
  turn end to end, or the v0.5 fix can regress silently.
- **Go dependency creep.** Standard library only through phase 4; a third-party dependency
  needs a stated reason in the PR.
- **Windows/WSL2 differences** are the reason for the removal in the first place
  (PLAN.md). The measurement phase is not optional.

## Open questions

1. The seam command names: `prepare` / `release` above, or something else the CLI should
   grow? The Station command keeps its current shape either way.
2. Who owns the machine-wide slot files — Go reimplements the small on-disk protocol so
   Odin `brew` and the Go host share one budget, or Go shells out to Odin for a slot? The
   design says reimplement, because the format is a contract and a process hop per
   acquire is worse.
3. Does the Odin binary keep a `host` subcommand at all after cutover (a shim that execs
   `csd`), or is `csd` invoked directly by the Barista with `coffee-shop host` removed?
   Keeping the shim preserves one documented entry point.
