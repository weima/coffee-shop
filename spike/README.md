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
