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

## What moves, and what does not

| Moves to Go | Stays Odin |
|---|---|
| foreground host loop | CLI parsing, `--help`, exit codes |
| request socket, activity socket | Recipe parsing and validation |
| Station supervisor: spawn, RPC pipe, log pump, deadline, cancel | Git worktrees, station directories |
| queue, slot accounting, dispatch retry | Register, Receipt, state files |
| report relay, spool, history | Taste, Blend, `pr`, `cleanup`, Filter |
| progress ledger, `needs_input`/stale alerts | machine-limit slot files (shared format) |
| per-Shot bounded log | one-shot `brew` Workers |

The Odin binary remains the user-facing `coffee-shop`. In v0.6 it launches the Go host;
it does not grow a second implementation of anything.

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

One module at `go/` in this repository, one binary `csd`, no third-party dependencies in
the first pass:

```
go/
  cmd/csd/main.go          flag parsing, host run, station run
  internal/proto/          event, message and request types + JSON marshalling
  internal/host/           loop, stdin reader, sockets, queue, slots, ledger
  internal/station/        agent spawn, RPC lines, log pump, deadline, cancel
  internal/session/        session table, process identity, liveness
  internal/state/          history, spool, reports, locks, paths
```

Rules the port adopts deliberately, because each one is a bug we already paid for:

- Ownership is the allocator's problem: no borrowed slices outlive the function that
  produced them, and nothing is stored in a map that was not explicitly copied.
- The request/activity loop is `select` over channels plus a `net.Listener`; no poll
  choreography, no hand-rolled wake-ups.
- An agent is `exec.Cmd` with its own process group; cancel is `Signal(SIGTERM)` then a
  bounded wait then `Kill`, and the reaper always runs.
- A Station turn has a deadline; a cancelled turn ends in seconds and reports why.
- A report is written to the spool and the history **before** it is announced on stdout.
- Logs are capped by a `io.Writer` wrapper that keeps the newest bytes and rotates once.

## Phases

1. **Contract + conformance harness.** Write the contract above as tests: feed a fixed
   request stream to a host, compare events field by field (timing excluded). Record the
   Odin host's current output as the golden baseline.
2. **Go host against a real repository**, headless only, behind `coffee-shop host
   --impl=go` (Odin keeps the CLI). No pane backend exists in it at all.
3. **Go Station supervision.** Port the supervisor with the v0.5 regression tests as
   acceptance: cancel reaches a blocked turn; no orphan agent; the bounded log keeps the
   tail; a turn deadline reports `incomplete`.
4. **Cutover and deletion.** Make the Go host the default, delete the Odin host loop and
   supervisor, then do the v0.5 Wave 3 deletions: `pane_pool.odin`,
   `pane_backend_herdr.odin`, `pane_clear.odin`, the pool half of `host_pane_pool.odin`,
   `host_pool_persistence.odin`'s pane recovery, `pr.odin`'s pane discovery,
   `settle.odin`'s tab close, `docs/tab-lifecycle.md`, the guardrail line, and the six
   tests that fake Herdr.
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

- **Two implementations drift.** Mitigated only by the conformance suite being the
  merge gate; if it is skipped, the port is worse than the original.
- **The Odin CLI still owns Recipe, Git and Taste.** A Go host that shells out to the
  Odin binary for those steps adds a process hop; the alternative is duplicating them,
  which this design rejects.
- **Go dependency creep.** Standard library only in the first pass; a third-party
  dependency needs a stated reason in the PR.
- **Windows/WSL2 differences** are the reason for the removal in the first place
  (PLAN.md). The measurement phase is not optional.

## Open questions

1. Does the Go host speak to the Odin CLI for worktree creation and Taste, or is worktree
   creation small enough to port too? This design says shell out; confirm.
2. Should `csd` ship as a separate binary, or as an embedded subcommand the Odin binary
   extracts on first run (as the Pi extension already is)?
3. Does the queue survive a host restart (persisted, like history) or stay in memory? v0.5
   kept it in memory and lost queued Shots on a crash.
4. Does the Go module live at `go/` in this repository, or in a submodule?
5. Is Go tooling assumed on the developer's machine at build time, or is `csd` committed
   as a built artifact per platform? The repository has an "never launch a stale binary"
   rule that argues for building from source.
