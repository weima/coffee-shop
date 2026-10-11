# Spike: how many pi sessions fit in one Node process

Question: can many pi agent sessions share one Node process, and what does each
session cost in memory and CPU, compared with one pi process per session?

This spike makes **no model requests**. It creates sessions with
`createAgentSession()` and `SessionManager.inMemory()`, lets them sit idle, and
measures. `session.prompt()` is never called.

## Files

| File | Purpose |
|---|---|
| `spike/lib.mjs` | Shared helpers: isolated HOME/agent dir/cwd, SDK loader, idle session factory. |
| `spike/in-process.mjs` | N = 1, 10, 50, 100 sessions in ONE node process. |
| `spike/one-process-each.mjs` | Baseline: one child process per session, N = 1, 5, 10. Also a bare-node reference. |
| `spike/baseline-guarded.mjs` | Guarded baseline: one child per session, N = 25 then N = 50, with a free-memory guard. Reuses `one-process-each.mjs --child`. |
| `spike/footprint.mjs` | Physical footprint (macOS `footprint -f bytes -p`): `in-process` (N = 0, 10, 50, 100) and `guarded` (one child per session, N = 10, 25, 50). |

## How to run

```sh
cd spike
node --expose-gc in-process.mjs        # memory, heap, create time, idle CPU
node one-process-each.mjs              # per-process baseline (takes about 10 s)
```

Requirements:

- Node 22.19 or newer (the SDK's `engines` field). Tested with Node v22.23.2.
- The pi SDK is read from the global install by default:
  `/Users/weima/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/dist/index.js`.
  Override with `PI_SDK_ENTRY=/path/to/dist/index.js`.
- `--expose-gc` is optional. Without it the script warns, and heap numbers are noisier.

## Isolation (hard rules)

Each process sets `HOME` to a fresh temp directory under `$TMPDIR/oreo-spike-*`
before it creates a session, and passes that directory as `agentDir`, with a
fresh temp `cwd`. So:

- No file under the real `~/.pi` is read, including `auth.json`, `models.json`
  and `settings.json`. No credential file is opened.
- No user extensions, skills or project context files are loaded.
- `SessionManager.inMemory()` writes no session files.
- Each script calls `session.dispose()` on every session and removes its temp
  root before it exits. I checked afterwards: no `oreo-spike-*` directories and
  no stray processes were left.

## Results

Machine: Apple M4, macOS 26.6.2 (build 25G83), darwin/arm64.
Node v22.23.2. pi-coding-agent 1.1.0.

### 1. In one process (`node --expose-gc in-process.mjs`)

| N | RSS (MB) | heapUsed (MB) | create time, cumulative (ms) | avg RSS per session (MB) | idle CPU (%, 2 s window) |
|---|---|---|---|---|---|
| 0 | 136.3 | 30.4 | 0 | - | - |
| 1 | 137.7 | 31.1 | 12 | 1.44 | 0.2 |
| 10 | 140.5 | 33.3 | 81 | 0.42 | 0.2 |
| 50 | 147.0 | 40.0 | 197 | 0.22 | 0.3 |
| 100 | 156.7 | 47.7 | 341 | 0.20 | 0.3 |

- Average RSS per session = (RSS at N − RSS at 0) / N. At N = 100: (156.7 − 136.3) / 100 = **0.20 MB**.
- Create time is the cumulative time for N sessions. Idle windows are excluded.
- After all sessions were disposed: heapUsed fell to 32.2 MB, but RSS stayed at 156.7 MB.
  The heap was returned to the process; RSS was not returned to the OS.
- No failures at any N.

### 2. One process per session (`node one-process-each.mjs`)

| case | processes (N) | total RSS (MB) | avg RSS per process (MB) |
|---|---|---|---|
| pi session per process | 1 | 138.2 | 138.20 |
| pi session per process | 5 | 689.2 | 137.83 |
| pi session per process | 10 | 1380.2 | 138.02 |
| bare node, no SDK (reference) | 5 | 209.0 | 41.80 |

### Comparison

- Memory per session: **about 0.2 MB in-process** (marginal, at N = 100) against **about 138 MB per process**. That is roughly 690 times less.
- At N = 10, the totals are 140.5 MB in one process against 1380.2 MB in ten processes: about 10 times less.
- Derived, not measured: a bare node process costs about 42 MB. Loading the pi SDK adds about 94 MB on top, and in-process that cost is paid once, not per session.
- Extrapolation, not measured: 100 separate processes would be about 13.8 GB RSS.

## What the numbers show, and what they do not

**They show:**

- Sessions created with the SDK, held in one process, add little memory each: about 0.2 MB at N = 100 in this setup.
- Creation is cheap: 100 sessions in about 0.34 s of cumulative creation time.
- Idle CPU stays low (0.2–0.3% of one core over a 2 s window) at N = 100.
- Process-per-session costs about 138 MB each, mostly from the Node runtime plus the SDK load.
- No session failed to create, and no credential prompt appeared.

**They do not show:**

- **No model and no login.** The isolated HOME has no `auth.json`, so every session started with no model. The note printed was "No models available. Use /login…". Real sessions with a model configured will cost more: they may hold provider clients and auth state. This spike does not measure that.
- **No user config.** Extensions, skills and settings from a real `~/.pi/agent` are not loaded. A real setup could cost more per session.
- **Idle only.** No prompts, tool runs, or streaming. The CPU figure is idle CPU, not the cost of active agent work.
- **N=1 is inflated.** The first session pays one-time costs, so 1.44 MB at N = 1 is not the marginal cost.
- **Run-to-run variance.** Two runs of the in-process script gave RSS at N = 0 of 134.6 and 136.3 MB, so expect about ±2 MB.
- **RSS does not drop after dispose.** Use heapUsed to judge freed memory, not RSS.
- **Per-process numbers were for N = 1, 5, 10 only.** Larger N was extrapolated, not measured.
- **Machine-specific.** These are one macOS arm64 machine's numbers.

## Errors

None. `createAgentSession` succeeded at every N, in-process and in every child.

## Credentials

No credential file was opened, read or printed. The HOME override means the SDK could not reach the real `~/.pi`. The sessions did not share a login, because there was no login in the isolated HOME. No credential prompt appeared.

## Guarded baseline

Run: `node spike/baseline-guarded.mjs` (about 50 s). Children start one at a time,
with a 0.3 s pause between them. Before each child starts, the script reads
`vm_stat` and sums free and inactive pages (16384 bytes each). If that sum is
below 2.00 GB, it starts no more children and stops the ones it started. Each
step runs with fresh children: all children are stopped before the next step.
RSS is summed with `ps -o rss=`. Available memory is read before the step, at
peak (after the 1 s settle, children alive), and after cleanup.

| N requested | N reached | total RSS (MB) | avg RSS per process (MB) | available before (GB) | available at peak (GB) | available after cleanup (GB) | stopped early |
|---|---|---|---|---|---|---|---|
| 25 | 25 | 2474.6 | 98.98 | 4.69 | 3.75 | 5.38 | no |
| 50 | 50 | 4452.5 | 89.05 | 5.38 | 3.13 | 6.29 | no |

Machine: Apple M4, 16 GB, macOS, Node v22.23.2. No failures in any child. After
each step, no child and no `oreo-spike-*` temp directory was left.

**What it shows:**

- N = 50 was reached. The guard did not trigger. The lowest available memory at
  peak was 3.13 GB, so the 2 GB guard had about 1.1 GB of margin.
- The summed RSS for 50 processes is 4452.5 MB, about 89 MB each. The drop in
  average from 99 MB at N = 25 to 89 MB at N = 50 is consistent with more shared
  pages between processes. Summed RSS counts shared pages once per process, so
  it overstates physical use.
- A cross-check from `vm_stat`: available memory fell 0.94 GB for 25 processes
  (about 38 MB each) and 2.25 GB for 50 (about 45 MB each). These are rough. Other
  applications and the file cache move the figure too, and the "after cleanup"
  value rose above "before" in both steps.

**What it does not show:**

- The N = 25 and N = 50 steps are separate runs, not one run that grows from 25 to
  50. Each step starts from a freshly stopped state.
- Idle sessions only, with no model and no user config, as in the sections above.
- The earlier one-process-each run measured about 138 MB per process at N = 1, 5 and
  10. This guarded run measured 89 to 99 MB per process at N = 25 and 50. The
  cause is not established here. Possible causes: warmer shared pages, or a
  different machine state.
- One run only. Available memory varies by several hundred MB between runs.

**Questions:**

- Q1: The cap of 50 applies to the child processes. The parent `node` process
  adds one more, so there are 51 `node` processes at N = 50. Should the parent count
  toward the cap?
- Q2: Summed RSS overstates physical use when processes share pages. Should the
  baseline report physical footprint (for example `footprint` or `vmmap`) as well?

## Physical footprint

Run one mode per invocation, so each measurement is a fresh process:

```sh
node --expose-gc spike/footprint.mjs in-process   # N = 0, 10, 50, 100 in ONE process
node spike/footprint.mjs guarded                  # one child per session: 10, then 25, then 50
```

Method, the same for both cases: `footprint -f bytes -p <pid>`, total line
`Footprint: N B`. RSS is printed next to it (`ps -o rss=`) for comparison. Available
memory is free + inactive pages from `vm_stat` (16384-byte pages). The guard stops
starting children below 2.00 GB and kills every child it started. Children start one
at a time, with a 0.3 s pause. The cap is 50 children for the whole run. The guarded
steps grow one run: 10 children, then 15 more to 25, then 25 more to 50. Each step
measures all children alive at that point.

### Table 1: in one process (`node --expose-gc spike/footprint.mjs in-process`)

| N | physical footprint (MB) | per-session cost (MB) = (F_N − F_0) / N | RSS (MB) | available (GB) |
|---|---|---|---|---|
| 0 | 105.72 | - | 138.86 | 4.34 |
| 10 | 107.97 | 0.23 | 141.56 | 4.36 |
| 50 | 114.25 | 0.17 | 147.28 | 4.36 |
| 100 | 129.84 | **0.24** | 161.33 | 4.36 |
| after dispose | 129.89 | - | 161.38 | 4.32 |

Per-session cost at N = 100: (129.84 − 105.72) / 100 = 0.24 MB. No failures. The only
model note was the usual "No models available" message, since the isolated HOME has no login.

### Table 2: one child per session, guarded (`node spike/footprint.mjs guarded`)

| N requested | N reached | footprint total (MB) | footprint avg per child (MB) | RSS total (MB) | RSS avg per child (MB) | available before step (GB) | available after step, children alive (GB) | stopped early |
|---|---|---|---|---|---|---|---|---|
| 10 | 10 | 1044.36 | 104.44 | 1377.75 | 137.78 | 4.41 | 4.34 | no |
| 25 | 25 | 2399.57 | 95.98 | 2711.81 | 108.47 | 4.34 | 3.84 | no |
| 50 | 50 | 3842.86 | 76.86 | 5053.50 | 101.07 | 3.84 | 3.23 | no |

After all children stopped: available 6.19 GB, 0 children still alive, 50 children
started in total. The guard never triggered. The lowest available reading was 3.23 GB,
about 1.2 GB above the 2 GB limit.

### What this shows

Neither earlier figure is a physical footprint figure. Both are RSS. The 138 MB figure
matches RSS: this run gave 138.9 MB RSS at N = 0 and 137.8 MB at N = 10. Physical
footprint for the same process is 105.7 MB at N = 0 and 104.4 MB per child at N = 10,
so RSS was about 33 MB higher per process. The 89 to 99 MB figure was also RSS. This run
measured RSS of 108 MB at 25 children and 101 MB at 50, so that figure depends on machine
state. Physical footprint per child fell from 104 MB at N = 10 to 77 MB at N = 50 in this
run. I did not establish why. This is one run only, and the mix of shared and compressed
pages is unknown.

For the design, the measure that matters under memory pressure is about 100 MB of physical
footprint per pi process, not 138 MB. Ten processes cost about 1 GB and 50 cost about
3.8 GB by footprint. The in-process cost of one session is about 0.2 MB. What costs 100 MB
is the Node runtime plus the SDK load. A one-off spot check of a bare `node` process with
a timer gave 11 MB footprint (not part of the script), so the SDK adds roughly 95 MB on
top. One process that holds many sessions is therefore far cheaper than one process per
session. The vm_stat drop during the guarded run (4.41 GB to 3.23 GB) was smaller than the
summed footprint, so the free + inactive guard is a rough proxy, not an exact measure.

**Questions:**

- Q1: Each guarded step grew the same run (10, then 25, then 50 children), not fresh
  children per step as in `baseline-guarded.mjs`. Should the next run use fresh children per
  step?
- Q2: Footprint per child fell from 104 MB to 77 MB as N grew. Should I check the cause
  with `footprint --swapped` or `vmmap` on a child set at N = 10 and N = 50?
