# Spike: ACTIVE pi agents in one process, with a fake provider

Question: can one pi process carry many ACTIVE agents (streaming, tool calls, JSON
events), and what do they cost in memory, CPU and event-loop delay? The idle spike
(`spike/README.md`) showed about 0.2 MB per idle session. This spike adds work.

Nothing here touches the network or a real model. The only provider is a fake one,
registered on an isolated `ModelRuntime`. If it is missing, or a session does not use
it, the run fails. It never falls back.

## Files

| File | Purpose |
|---|---|
| `spike/active/fake-provider.mjs` | Fake `streamSimple` provider, isolated runtime, session factory, and the per-agent scenario (`runAgentUntil`, `warmUp`, `stopAgent`). |
| `spike/active/probe.mjs` | Memory guard (`vm_stat`, free + inactive pages), `footprint -f bytes -p`, CPU helpers. |
| `spike/active/active.mjs` | N agents in ONE process: `in-process <N>`. |
| `spike/active/per-process.mjs` | N agents, ONE child process each, guarded. Child mode is `--child`, started by the parent only. |

It reuses `spike/lib.mjs` (`isolate`, `loadSdk`, `SDK_ENTRY`). It does not change any other file.

## How to run

```sh
cd spike/active
node active.mjs in-process 10                 # 60 s window, event-loop histogram on
node active.mjs in-process 50
node active.mjs in-process 100
node per-process.mjs 10                       # 10 children, guarded
# options: --window-ms 60000 (default), --warmup, --no-eld (in-process only), --sample-every-ms 10000
```

Run them one at a time, not in parallel, so the runs do not compete for CPU. Each
run prints a `RESULT {...}` JSON line and a summary.

Requirements: Node 22.19 or newer (tested with v22.23.2), the pi SDK in the global
install (override with `PI_SDK_ENTRY`), and pi-ai next to it (override with `PI_AI_ENTRY`).

## The scenario

Every agent loops until the window ends:

- prompt, then 20 tokens of text, then one `read` tool call to a 3-line file in its temp
  cwd, then the tool result, then 180 tokens of final answer. That is about 200 streamed
  tokens per turn, one read, one final answer.
- One token every 10 ms, so about 100 tokens per second.
- A turn counts only if it ends with `stopReason: "stop"`, a non-empty answer, and a read
  result that is not an error. A turn cut off at the window end is not counted.
- Sessions are in-memory, with only the `read` tool enabled. `PI_OFFLINE`,
  `PI_SKIP_VERSION_CHECK` and `PI_TELEMETRY=0` are set, and API-key-like env vars are removed.

Isolation: each process uses a fresh temp HOME, agent dir and cwd. The real `~/.pi` is
never read, and no credential file is opened. The SDK creates an `auth.json` inside the
temp agent dir, which is removed on exit. I checked a run's temp root: it held only
`notes.txt` and that `auth.json`. No session file is written.

## Results

Machine: Apple M4, 16 GB, macOS 26.6.2, darwin/arm64 (the same spec as the idle spike).
Node v22.23.2. pi-coding-agent 1.1.0. Window 60 s, cold start (no warm-up turn). Source:
`/tmp/active-results/`.

### Table 1: one process, N active agents (`active.mjs in-process N`)

Event-loop histogram on (1 ms resolution). Idle p99 is 1.19–1.20 ms.

| N | footprint peak, MB (idle) | CPU, % of one core | event-loop p99, ms | event-loop max, ms | turns total (per agent) | errors |
|---|---|---|---|---|---|---|
| 1 | 78.2 (105.8) | 5.1 | 1.46 | 8.6 | 29 (29) | 0 |
| 10 | 137.3 (106.9) | 8.6 | 1.77 | 17.0 | 290 (29) | 0 |
| 50 | 152.6 (108.7) | 24.2 | 3.11 | 28.8 | 1400 (28) | 0 |
| 100 | 280.1 (110.0) | 38.9 | 4.47 | 31.6 | 2700 (27) | 0 |

The N = 1 footprint peak is below its idle baseline. The footprint reading depends on
when V8 collects garbage, so one sample can show a value below the baseline. Read the
footprint as a range, not a per-agent cost.

### Table 2: one process per agent, guarded (`per-process.mjs N`)

| N | footprint total peak, MB (per child) | CPU, % (sum over children) | parent event-loop p99, ms | turns total (per agent) | errors | status |
|---|---|---|---|---|---|---|
| 1 | 110.1 (110.1) | 4.5 | 1.19 | 29 (29) | 0 | **inflated**: child histogram on |
| 10 | 950.7 (95.1) | 44.6 | 1.40 | 290 (29) | 0 | **inflated**: child histogram on |
| 10 | 912.5 (91.3) | 25.7 | 1.24 | 270 (27) | 0 | **clean**, cold, `cold-per-process-10-final.txt` |

The two inflated rows come from runs where each child ran its own 1 ms event-loop
histogram. That histogram costs CPU in every child, so the CPU column is too high. The
clean N = 10 row is the headline for per-process. The N = 1 row has no clean cold
counterpart in this directory; the warm-up note below has a clean N = 1 figure.

Guard: it never tripped. The lowest available memory in these runs was 3.7 GB.

### Note: warm-up and instrument checks (not scenarios)

These runs check whether the cold-start cost or the histogram explains the CPU figures.
They are not part of the headline tables.

| case | CPU, % | footprint peak, MB | note |
|---|---|---|---|
| in-process N = 1, warm-up, histogram on | 5.0 | 110.7 | |
| in-process N = 10, warm-up, histogram on | 9.9 | 110.9 | |
| in-process N = 50, warm-up, histogram on | 25.7 | 141.9 | |
| in-process N = 100, warm-up, histogram on | 38.5 | 269.5 | |
| in-process N = 1, warm-up, histogram off | 2.9 | 110.2 | histogram adds about 2 points at N = 1 |
| in-process N = 10, warm-up, histogram off | 7.5 | 114.3 | |
| per-process N = 1, warm-up (children have no histogram) | 3.1 | 109.9 | clean |
| per-process N = 10, warm-up (children have no histogram) | 23.9 | 881.1 | clean |

Warm-up does not change the picture. The per-process cost of about 2.5% CPU per child
stays after warm-up, so it is not first-turn JIT.

## The answer

One process is enough for 100 active agents at this load. CPU was 38.9% of one core,
event-loop p99 was 4.5 ms (max 32 ms), 2,700 turns completed, and there were no errors.
CPU is where it strains first. The cost grows about 0.34% of a core per active agent
from N = 10 to N = 100, so one core would saturate at roughly 250–300 agents by
extrapolation, which I did not measure. Event-loop p99 also rises with N (1.8, 3.1, then
4.5 ms) but stays far from a stall. Memory is last: 280 MB peak at N = 100, about 1.7 MB
per agent above idle, but the footprint was still rising at the end of the 60 s window.
Per process, the same 10 agents cost about 6.7 times the memory (912 MB against 137 MB)
and about 3 times the CPU (25.7% against 8.6%), because each child pays a base of about
90 MB and about 2.5% CPU.

## What the numbers do not show

- **The fake provider is not a real provider.** Each token is one 10 ms timer, so CPU is
  partly timer-driven. There is no HTTP, no SSE or JSON parsing of a provider payload, no
  real token counting (input usage is 0), and no TUI rendering. A real provider adds
  network I/O, parsing and rendering, none of which is measured here.
- **Only the `read` tool.** No bash, edit or write, and no extensions or skills.
- **Sixty seconds only.** The footprint still rose at the end of the window at N = 100
  (221 → 280 MB over the window). Longer windows may show more growth.
- **Footprint is noisy.** V8 does not collect the heap on a fixed schedule. Across the
  runs I did (these tables from `/tmp/active-results`, plus reruns of the same scenario in
  `/tmp/active-final`), the N = 50 peak ranged from about 153 to 232 MB, and the N = 100 CPU
  ranged from 33% to 39%. The table values are single runs.
- **The histogram is not free.** At 1 ms resolution it adds about 2 CPU points per process
  (note table). The per-process children no longer run one, so Table 2's clean row is not
  inflated by it. The Table 1 runs include it, so their CPU is a few points high.
- **Summed child CPU can exceed 100%.** It is shown as a percentage of one core, the same
  unit as the in-process figure.
- **Machine-specific.** One macOS arm64 machine.

## Guard, cap and cleanup

- The guard reads `vm_stat` (free + inactive, 16384-byte pages) before each child starts,
  every 2 s during an in-process window, and every 10 s during a per-process window. The
  run stops below 2.0 GB. It never tripped. The stop path was checked on a scratch copy with
  the threshold raised to 5 GB: it stopped before any child started and exited 1.
- The child cap is 50. The per-process runs used 10. The parent is not counted.
  `footprint` and `vm_stat` run as short-lived child processes of the parent, one at a time.
- No `per-process.mjs`, `active.mjs` or `footprint` process from this spike is left running
  (checked with `pgrep`). Temp roots are removed on exit.
- One batch was interrupted from outside the scripts, and its children were killed before
  they could clean up. 11 `oreo-spike-*` temp dirs from that batch were removed. The runs
  from that batch were redone.

## Questions

- Q1: Should the next run be longer, for example 5 minutes per window, to see whether
  footprint plateaus as the transcript grows? At N = 100 the footprint was still rising at 60 s.
- Q2: Should I add a fake provider that replays SSE over a loopback HTTP server? That adds
  the parsing cost. A loopback socket may conflict with "no network", so I have not added
  one. Is loopback allowed?
- Q3: Should I profile one child with `--cpu-prof` to find the ~2.5% per-process fixed CPU?
  The cause is not established.
- Q4: Should each N run 3 times and report the median? Footprint varies by tens of MB between runs.
