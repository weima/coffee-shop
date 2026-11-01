# The v0.6 host measurement: macOS and WSL2 (Wave-3 item 7)

This measures the same five-Shot run twice, once on macOS and once on WSL2, so the Go
host's phase-5 gate is a number rather than a claim. The Odin host's numbers are already
in `PLAN.md`'s v0.4 record (tree RSS 460–520 MiB, 2–5 children, 2.3–2.6 GiB for the
default concurrency of five); what is missing is the Go host's numbers on both platforms,
and the wall-clock comparison against the Odin baseline.

## What to record per platform

Host: `csd` in a fresh state root, headless, no Herdr in `PATH`, extensions pre-installed
(`csd` does this itself since #168, so add nothing).

1. Wall-clock per Shot: `dispatch_accepted` → `taste_passed` / `agent_exited`, from the
   `at` field on the event stream. Use the same `sleep 30` Taste so the work is identical
   on both sides. **Not** `sleep 90`; five at 30 s is enough to observe scheduling noise,
   and the total runtime stays under 3 minutes.
2. Host-process peaks: resident memory, CPU seconds, open file descriptors, live children.
   One sample per second is enough; write to `<state>/host/<request>/workers/<shot>.resource`
   in the format the Odin host already uses, or to a separate file the comparison script
   reads.
3. Whole-run wall clock: the first `session_started`'s `at` to the last `station_report`'s
   `at`, so you have something to compare the Odin baseline against directly.
4. Machine facts, written next to the numbers so the comparison is honest: OS version,
   WSL2 kernel version if applicable, whether the project sits on the Linux filesystem or
   under `/mnt/c` (PLAN.md warns about 9P; the WSL2 run must be inside the Linux
   filesystem), CPU core count, RAM size.
5. Sustained-overlap evidence: the five-Slot gate (#169) must pass on the WSL2 box too, not
   just on macOS — otherwise the macOS numbers cannot be called representative. Run it the
   same way the gate's test does and record pass/fail alongside the numbers.

Negative results count. If a number is unmeasurable on WSL2, record the reason in
`PLAN.md`; do not invent it. `not measured: <reason>` is the v0.4 convention and still the
rule.

## Running it

The logic lives in Go (`go/cmd/measure`); `scripts/measure-host.sh` is a thin launcher
so the docs name one shell entry point. Everything runs through `go run` — no built
binary is depended on.

```sh
# macOS first (this machine)
sh scripts/measure-host.sh /path/to/scratch       # one number set
# then WSL2 (your Windows box, the project inside the Linux filesystem)
sh scripts/measure-host.sh ~/scratch              # the comparable run
# then copy both report.md + machine.txt + per-shot.csv into PLAN.md
```

## What "right" looks like

Each platform's run produces:

- `<run>/report.md` — the number set above, in the shape `PLAN.md` already uses,
- `<run>/events.jsonl` — the raw event stream, for re-derivation,
- `<run>/host.err` — anything the host printed on stderr,
- five `workers/*.resource` files.

Numbers go into a `## v0.6 measured (`<date>`)` section in `PLAN.md` that mirrors the
v0.4 record's style: two paragraphs of context, one table per platform, one cross-platform
comparison table, and one line saying which claim the measurement closes and which it does
not (for example: "host CPU is `not measured` on macOS by design (#125), the WSL2 side is
measured via `/proc`" is exactly the kind of asymmetry to state).

## What the numbers close

Phase 5 of the v0.6 roadmap is "Measure". Gate wording: *"The same five-Shot run on WSL2
and on macOS, wall-clock per Shot, host CPU and resident memory, before and after."* The
"before" half is the Odin host's already-recorded numbers; the "after" half is this run.
If the WSL2 numbers alone cannot close it (for example, no comparable Linux-side Odin
baseline exists for that specific machine), the record says so and Phase 5 stays open
until a paired run exists — honest, not convenient.

## Pre-flight checklist (before you start the WSL2 run)

- [ ] WSL2 box has Go and Odin and `pi` on `PATH`, and Pi is authenticated.
- [ ] Project is on the Linux filesystem (`~`, not `/mnt/c`).
- [ ] `herdr` is *not* on `PATH` in the shell you are about to use (the measurement means
      nothing if Herdr silently serves the run).
- [ ] `just check` and `just test` pass on that box: the measurement is against code that
      can be built there, not a copy of a number from somewhere else.
- [ ] You have the macOS run's numbers written down already, so the comparison is fresh.

## Where the numbers go

`PLAN.md`, in the `## v0.6 measured` section of the v0.6 roadmap. The comparison is also
the input to the final cutover decision: if WSL2 numbers are materially worse than macOS
in ways the code cannot explain (for example 9P filesystem overhead when the project
*sits* correctly on the Linux filesystem), that is a code or environment defect, not a
number to accept — record it and keep Phase 5 open until it is understood.
