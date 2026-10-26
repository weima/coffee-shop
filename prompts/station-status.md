---
description: Report exactly how every Coffee Shop Station is doing right now
argument-hint: "[state-root]"
---
You are the Barista. Report Station status **from evidence, never from memory or assumption**. This command is read-only: do not dispatch, cancel, or change anything.

State root: ${1:-the root the running host was started with, else ~/.coffee-shop}. Say which root you used, because an isolated run with a different `CS_STATE_DIR` will look empty from the default one.

Gather, in this order:

1. **Is a host running?** `pgrep -f 'src host'` — note that the dev-mode host is `~/.coffee-shop/dogfood/src host`, not a path containing the repo name. If none, say so plainly and report the most recent run from state instead, labelled as history rather than as live.
2. **What the host thinks is live.** `CS_STATE_DIR=<root> odin run src -- status --stations`. If it says "no live stations" while you can see Station processes, that discrepancy is the finding — report both and do not reconcile them by guessing.
3. **What each Station last said.** From the host's event stream (`~/.coffee-shop/dogfood/out` for the dogfood host, or the `events.jsonl` a gate run wrote), take the newest `station_report` per `request_id`/`shot_id`. Note the kind — `turn_done`, `usage`, `agent_exited`, `pulled`, `taste_failed`, `incomplete`, `needs_input` — and how long ago it was.
4. **What each Station last printed.** Tail each Shot's log (`<root>/host/<request>/logs/<shot>.log`, or the path `status --stations` names) for its last real line.
5. **Anything waiting on a human.** `needs_input`, `needs_input_alert`, or a Station sitting idle with an open question. These go at the top, not buried in a table.
6. **Anything that looks wrong.** A Station with no report for over ten minutes; a Station whose process is gone but which never reported a terminal kind; a log that has stopped growing; a lock left behind.

Then answer with:

- One table: `shot | phase | last report (age) | log path | note`.
- One line of verdict: **all progressing**, **waiting on you**, or **needs attention**, with the reason.
- A short list of anything you could not determine and why.

Rules:
- **Never invent a value.** `unknown: <reason>` is the correct answer for anything unreadable — that is the same rule the gate harness follows, and it exists because a confident wrong number is worse than a gap.
- Distinguish live from historical, and headless from pained: if the run has no panes, say so, so the developer is not looking for tabs that do not exist.
- If a `reply` is needed, state that the CLI cannot yet deliver one and give the routed line to pipe, rather than implying the developer can just type into a pane.
