# Odin footprint floor

The floor for the Oreo spike. It measures an Odin program under the same N values
as the pi baseline in `spike/README.md`, with the same method: macOS
`footprint -f bytes -p <pid>`, total `Footprint: N B` line, converted to MB (2^20 B).

**Caveat:** this is a floor. The Odin program has no HTTP client, JSON or SQLite. The
real Oreo will cost more.

## Files

| File | Purpose |
|---|---|
| `session.odin` | `Session` struct: id, a 64 KB work buffer that is touched, a small history. `make_session`, `free_session`. |
| `sessions.odin` | Entry point with three modes: `idle`, `in-process N`, `child [SECONDS]`. |
| `measure.sh` | POSIX sh. Builds the program, runs every measurement, guards memory, kills everything. |

## How to run

```sh
cd spike/odin
sh measure.sh          # about 35 s on an M4 with 16 GB
```

Requirements: `odin` on `PATH` (tested with `dev-2026-10-nightly:84bc3fc`), `/usr/bin/footprint`,
`vm_stat`, `pgrep`. The build goes to a temp directory, so nothing is written to the repo.

The modes:

- `idle`: bare process, sleep 15 s (the floor).
- `in-process N`: N sessions in one process, touched, sleep 15 s, then freed.
- `child [SECONDS]`: one session, touched, sleep SECONDS (default 15).

Each mode prints `pid <pid> ready ...` once its sessions exist. `measure.sh` checks that
the pid in that line equals `$!`, then runs `footprint` on it.

## Method

- **Memory guard:** before each child starts, read `vm_stat`. Available = (free + inactive)
  pages x 16384. If it is below 2.0 GiB, start no more children, record the count, and kill the
  children started. The guard never triggered in the run below.
- **Pacing:** children start one at a time, with a 0.3 s pause after each start.
- **Cap:** at most 50 children. Children are counted separately from the single-program runs
  (see Q1).
- **Cleanup:** every process started is killed and waited for. On exit, `measure.sh` checks
  that `pgrep` finds no `sessions` process.
- **Settle:** 1 s after the last start, then `footprint`.

### Deviation: child hold of 60 s in Table B

The spec says the child sleeps 15 s. Table B grows one run (10, then 25, then 50 alive), so
the first children would exit before the 50-child step is measured. `measure.sh` starts
the Table B children with `child 60`. The idle and in-process runs keep the 15 s hold.

## Results

Machine: Apple M4, 16 GB, macOS, arm64. Single run (see the run log below).

### Table A: one process, in-process sessions

Odin per session = (F_N − F_0) / N. The pi column is the in-process run in `spike/README.md`,
Table 1 (`footprint.mjs in-process`).

| N | Odin footprint (MB) | Odin per session (MB) | pi footprint (MB) | pi per session (MB) |
|---|---|---|---|---|
| 0 (floor) | 0.89 | - | 105.72 | - |
| 10 | 1.69 | 0.080 | 107.97 | 0.23 |
| 50 | 4.86 | 0.079 | 114.25 | 0.17 |
| 100 | 8.78 | 0.079 | 129.84 | 0.24 |

The Odin per-session cost is stable at about 0.079 MB. The pi per-session figure varies
between 0.17 and 0.24 MB across N.

### Table B: one process per session, guarded growing run

Same method as the pi guarded run (Table 2 in `spike/README.md`): one run, 10 then 25 then 50
children alive. The pi column is that table's footprint columns.

| N | Odin total (MB) | Odin avg per child (MB) | pi total (MB) | pi avg per child (MB) |
|---|---|---|---|---|
| 10 | 9.85 | 0.98 | 1044.36 | 104.44 |
| 25 | 24.62 | 0.98 | 2399.57 | 95.98 |
| 50 | 49.23 | 0.98 | 3842.86 | 76.86 |

Lowest available memory in the run: 4.97 GB (2.97 GB above the guard). No child was refused.

### Side by side: per session, MB

| | N = 10 | N = 50 |
|---|---|---|
| pi, in-process | 0.23 | 0.17 |
| Odin, in-process | 0.080 | 0.079 |
| pi, one process each | 104.44 | 76.86 |
| Odin, one process each | 0.98 | 0.98 |

The Odin in-process figure is mostly the 64 KB work buffer (0.0625 MB), which I chose. It is not
the same session state as a pi session, so this is not a like-for-like comparison of sessions.

### Run log (last run, `sh measure.sh`)

```
building sessions
A floor idle pid=71441 footprint_MB=0.89 avail_before_GB=5.11 avail_after_GB=5.04
A in-process N=10 pid=71545 footprint_MB=1.69 per_session_MB=0.080 avail_before_GB=5.04 avail_after_GB=5.03
A in-process N=50 pid=71589 footprint_MB=4.86 per_session_MB=0.079 avail_before_GB=5.04 avail_after_GB=5.03
A in-process N=100 pid=71700 footprint_MB=8.78 per_session_MB=0.079 avail_before_GB=5.04 avail_after_GB=5.04
B target=10 reached=10 footprint_total_MB=9.85 footprint_avg_MB=0.98 avail_before_GB=5.04 avail_after_GB=5.02 stopped_early=no
B target=25 reached=25 footprint_total_MB=24.62 footprint_avg_MB=0.98 avail_before_GB=5.02 avail_after_GB=5.01 stopped_early=no
B target=50 reached=50 footprint_total_MB=49.23 footprint_avg_MB=0.98 avail_before_GB=5.01 avail_after_GB=4.97 stopped_early=no
summary children_started=50 cap=50 single_programs_started=4 avail_after_cleanup_GB=5.02
check: no sessions process left (pgrep empty)
```

## Caveats

- **Floor, not Oreo.** No HTTP client, JSON or SQLite. The real Oreo will cost more.
- **Session content is my choice.** A session here is 64 KB plus a small history. A pi session holds
  whatever the SDK allocates. Compare the two as cost per session under this load, not as equal state.
- **One run.** Expect about ±0.05 MB per session and about ±1 MB on the floor. The pi in-process
  per-session figure moved between 0.17 and 0.24 MB across N.
- **Idle only.** No prompts, no I/O, no network.
- **Machine-specific.** One macOS arm64 machine.

## Questions

- Q1: The 50-child cap counts only the one-process-per-session children. The four single-program
  runs (the idle floor and three in-process runs) are not counted, as the pi run did not count its
  in-process process. Literal total started: 54 (50 children + 4 single programs), never more than
  50 alive at once. Should the four count? If so, Table B would stop at 46 children.
- Q2: Table B is one growing run, not fresh children per step. Fresh steps would need 85 children,
  over the cap. Is the 60 s child hold acceptable in place of 15 s?
