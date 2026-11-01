# Five-Station gates (5.8, 5.9, 5.10)

The Odin tool `tools/gates` (run as `odin run tools/gates -- <args>`, never a built binary) writes the request and reads the results. It never starts a host or touches Herdr; the orchestrator dispatches.

## Run once

```sh
W=/tmp/gates && mkdir -p $W
just gates-request /abs/path/to/repo $W/request.jsonl        # six Shots gate-s1..gate-s6; fresh request id gate-five-<UTC timestamp> each run
# For an overlap gate the recipe is not enough (it takes no extra flags):
#   odin run tools/gates -- request --repo /abs/path/to/repo --out $W/request.jsonl --kind execute --taste true
# Orchestrator: start the foreground host with these, feed it request.jsonl on stdin,
# keep stdin open until all six Shots finish, and capture stdout:
#   CS_SPALL_FILE=$W/trace  CS_STATE_DIR=$W/state  <host command> < $W/request.jsonl > $W/events.jsonl
just gates-report $W/request.jsonl $W/events.jsonl $W/state $W/trace $W/report.md
```

Trace files are `$W/trace.host` and `$W/trace.<station>` (src/profiling.odin:44-52); the report reads `$W/trace*`.
Shots are `research` kind with a `sleep 90` prompt so Stations overlap; use `--prompt`/`--prompt-file` (call `odin run tools/gates -- request ...` directly; flags `--shots`, `--request-id`, `--kind`, `--taste` too) for another load.

**A research Shot cannot sleep.** Its tool list is `read,grep,find,ls,write,codemode`, so a prompt that runs a shell command is declined and the Shot finishes at once: the six Shots then never overlap, and the 5.10 check reads a run that never queued. For an overlap gate use `--kind execute --taste true`: an execute Shot has a shell, and the taste ends the turn instead of leaving the session open (a Shot with no Taste stays interactive by design). The same `--tools` allowlist also hides the extension's `coffee_shop_ask` from a research Shot, so a `needs_input` check needs an execute Shot too.

Each run mints a new request id (`gate-five-YYYYMMDD-HHMMSS-mmm`, printed by `gates-request`), so repeat runs need no cleanup or id juggling. Branches are `cs-host-<request id>-<shot id>`. `--request-id ID` pins one deliberately; a pinned id must not collide with existing branches from an earlier run (Git refuses with `a branch named ... already exists`), so delete the old branches/worktrees first. The report pairs events by Shot id read from the request file, so it is unaffected by the request id.

## Report

Each host event now has `at`, RFC 3339 UTC with millisecond precision. The report uses `session_started` through each terminal `station_report` to print per-Shot elapsed seconds, plus the span from the first Station start to the last terminal report. Older event files without `at`, or Shots without a terminal report, say `not measured`.

- **5.10**: whether the sixth Shot got `dispatch_queued` → `dispatch_dequeued` → `session_started` (src/host.odin:891, :327, :938), Stations started before it queued, and any failure events.
- **5.9**: per-Shot Station and Pi-tree peaks (cpu, rss, fds, children) from `<state>/workers/<shot>.resource` (src/resource_profile.odin:26, :126).
- **5.8**: top spans by inclusive total time across all trace files.

Anything unreadable prints `not measured` with the reason. On macOS CPU is always unknown (src/resource_profile_darwin.odin:6).

## Known gap

`record_resource_use` is called only from the Brew settle path (src/settle.odin:147), not the foreground host. Until the host calls it, 5.9 reads `not measured: no .resource file`. The tool does not fake it.

## Test without Herdr

`just gates-selftest` (needs no Herdr server or host) builds a fixture (Spall trace, events, resource files) and checks the report, for the waited and not-waited cases.
