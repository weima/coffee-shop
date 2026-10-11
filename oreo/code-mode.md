# Oreo code mode

**Status:** planned for v0.5. Priority item. Not implemented.

Oreo's cost problem, and the design that answers it. This document records the measurements, the rejected alternative, and the containment rules, so the work does not restart from a guess.

## The problem this solves

Cost is driven by turn count, not prompt size. Measured on the Oreo v0.1 dogfood runs (2026-10-11):

- Across four Stations, **95% of 18.0M tokens were `cacheRead`**: the whole conversation re-sent on every turn.
- The `pool` Station spent **96 requests and $0.127** on roughly 700 lines of code, because it kept re-running one failing assertion.

That shape — run the tests, read the failure, edit, re-run — is the dominant cost in agentic work, and it is paid one model round trip at a time.

## What code mode changes

Pi's `codemode` tool lets the model write one script that calls the other tools. Its own documentation states the mechanism: *"Only the script's output reaches the model, so a script can run calls in parallel and filter large results before the model sees them."*

| | Normal turns | Inside one script |
|---|---|---|
| Tool results entering model context | every result, appended | **none** — only the script's output |
| Output bound | 2000 lines / 50 KB per tool | bounded by the script's own output |
| `bash` output available to the caller | 50 KB | up to 1 MiB, with the full text in a file |
| Round trips for N tool calls | N turns, each re-sending the conversation | **1 turn** |

So code mode attacks **both** terms of the cost product: it collapses turns, and it stops tool results from accumulating in context. It does not reduce the reasoning tokens per decision, and a wrong script still costs a turn.

## Decision: the script language is Odin, not an embedded JS engine

### Why not embed QuickJS

1. **It is a standing cost, and the budget is per session.** Oreo's whole point is many cheap sessions. The spike measured **~0.22 MB per idle session**. An embedded engine taxes that permanently, on every session, whether or not it ever writes a script. (A QuickJS VM's exact footprint is unmeasured here — QuickJS is not installed. It must be measured before it is used as an argument either way.)
2. **A shared engine does not fix it.** One VM in the host is a fixed host cost and removes isolation between sessions.
3. **The sandbox is mostly nominal.** QuickJS scripts have no file system, network, or timers — but they can call `execute`, so a script can already do anything a shell command can. What the sandbox actually buys is resource limits and determinism, not security.
4. **It adds a C dependency and a foreign-function boundary** for a language the project does not otherwise use.

### Why Odin

1. **No standing engine at all.** A script is compiled and run as a short-lived process. Nothing is embedded, so the per-session footprint is unchanged while idle.
2. **Compile cost is negligible.** Measured on this machine: a minimal build **0.137 s**, a realistic script with `os`/`strings`/`json` imports **0.149 s**, and a *type error* rejected in **0.030 s**. Against a 10–60 s model turn, that is noise.
3. **Tool calls are type-checked.** Pi resolves `tools.<name>(args)` at runtime, so a malformed call fails inside the script. An Odin script API makes a wrong call a **compile error before anything runs** — fewer wasted attempts, which is the currency that matters.
4. **No parallel tool surface.** The script calls Oreo's own `read`, `write`, and `execute` directly.
5. **`core/odin` gives a static gate.** Odin ships a lexer, parser, AST, and printer in core, documented as *"a lexer and parser for the `Odin` language for the purposes of writing tooling."* That allows a capability check before execution — see below.

### The honest risk

**Model competence, not compile speed.** Models write JavaScript far better than Odin, which is strict: explicit types, no implicit conversion, `_ = x` discards, no unused imports. Every mistake is cheap to *detect* (30 ms) but costs a *model turn* to fix, and turn count is what this feature exists to reduce. Mitigating factor: Odin's compiler errors are precise and point at the exact token, which models fix well in one shot. **This is the assumption to test first.**

## Process model

- **One short-lived process per script.** Compile, run, capture bounded output, exit.
- **No service.** The compile is 0.15 s and the process is transient, so there is no standing engine to amortize. A service would add a hop, a queue, and a single point of failure for no measured gain. A pool of *reusable processes* is a later optimization, and only if measurement asks for it.
- **The containment unit is a process, not a thread.** A threadpool gives scheduling, not containment: threads share an address space, cannot be killed, and a runaway script takes the host down with them. This is why a "code generator service with a threadpool" was rejected.
- **`core/odin` validation stays in-process.** Parsing one script to check its imports costs an AST (kilobytes, microseconds). Cheap static check in the host; expensive execution out of process.

## Containment and limits

| Limit | Mechanism |
|---|---|
| Memory | **Platform-dependent, and this is the sharp edge.** macOS does **not** enforce `RLIMIT_AS` — measured: with `ulimit -v 200000` set, a process allocated 400 MB anyway, and `zsh` does not even accept `-v`. Linux enforces it. On macOS the portable options are a supervisor that samples RSS and kills, or an engine-level heap cap, which only exists if the runtime is a VM-based engine. |
| Wall clock | A hard deadline per script, enforced by the parent. Portable. |
| Output | A cap on what a script may return to the model, with the full text written to a file, mirroring Pi's `max_output_tokens` behaviour. Portable. |
| Filesystem | The script runs in the worktree it was given. It is not sandboxed from it; `execute` already grants that reach. |

The macOS gap is the reason containment cannot be assumed to work the same way on both target platforms, and why it must be tested on each rather than written once.

## The static gate

Before compiling anything, parse the generated source with `core:odin/parser` and refuse a script that:

- imports anything outside an allowlist (`core:fmt`, `core:os`, `core:strings`, `core:encoding/json`, `core:slice`, `oreo:script`, and the standard library subset needed to be useful);
- contains a `foreign` block or `#load`, which reach outside the language;
- fails to parse at all.

A rejected script returns the parser's diagnostic to the model without a process spawn, which is both faster and a better message than a compiler invocation. This is the closest thing to a real capability boundary, and it is a *static* check on a language we control rather than a runtime sandbox.

## Script API

A package the generated script imports, so tool calls are typed:

```odin
package script

execute :: proc(command: string) -> (output: string, exit_code: int)
read :: proc(path: string, offset, limit: int) -> string
write :: proc(path, content: string) -> bool
text :: proc(value: any)      // adds a bounded item to the model-visible output
```

Tool calls go back to the host over the existing JSON-lines transport, so the script is a client of the same protocol the extension already speaks. Reusing that transport is deliberate: one protocol, one place to change.

## Non-goals

- Not a general-purpose plugin system.
- Not a way to run untrusted third-party code safely; the model is the author.
- Not in v0.4. v0.4's gate is the same end-to-end run with Oreo as the runtime, and this work is not required for it.

## Verification and gate

1. **Measure Pi's `codemode` first.** It already exists and is enabled with `pi --tools +codemode`. A/B the *same* task on real Stations, comparing tokens through the per-Station usage report added for v0.3. This gives the upper bound any Odin implementation could deliver, for the price of two runs. **If the delta is small, this feature is not worth building in any language.**
2. **Then prototype**: `core:odin` gate, one generated script, one process, bounded output, measured RSS while running.
3. **Gate:** on a repeated task, the Odin script path reduces total tokens materially against the same task without it, with a hard output cap and a working wall-clock deadline on both Linux and macOS.

## Open questions

- The exact `oreo:script` surface, and whether `text()` should accept images as Pi's does.
- Whether the script API should be prebuilt as an object file, given compile is already 0.15 s.
- How a script's tool calls are authorized against the session that wrote it.
- Whether the model needs the script API's declarations inline (Pi budgets 3000 estimated tokens for this).
- What replaces `RLIMIT_AS` on macOS, and whether a sampling watchdog is fast enough to be worth having.
