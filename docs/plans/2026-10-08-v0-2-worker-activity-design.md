# v0.2.0 slice 1: Worker activity

**Status:** Approved design  
**Scope:** Show what Pi is doing while a Shot runs, without changing Herdr's session role.

## Problem

A Worker currently runs `pi --print --no-session`; Coffee Shop captures stdout only after Pi exits. While it runs, `status` can say only `running`. A Barista cannot distinguish active work from a quiet or stuck Worker, or see which kind of Pi activity happened most recently.

## Design

Use a two-stage adapter:

1. The Worker launches Pi with `--mode json --print --no-session` and reads its newline-delimited event stream while Pi is running. It translates only the activity needed by Coffee Shop into a small, bounded Coffee Shop event: Shot identity, event kind, timestamp, and a short safe description (for example, a tool name, not its arguments or output).
2. The Worker sends those normalized events to the existing Brew supervisor over a local Unix-domain stream socket. The supervisor owns the listener, validates the Brew/Shot identity and message bounds, and persists the latest activity for each running Shot. The Barista and `status` consume Coffee Shop's event/state format, not Pi's JSON schema.

The socket is local IPC, not a new daemon or a replacement session backend. Herdr still owns one workspace per Brew and one tab per Shot. The existing process identity remains authoritative for whether a Worker is alive. Activity is evidence of what Pi last reported, not proof that the process is alive or that work is complete.

The Worker continues to persist the final report and result using the existing state files. The Pi adapter must recover the final assistant answer from the JSON stream so `collect` retains its current report contract. Unknown Pi event types are ignored; a malformed activity event or an unavailable socket must not turn a successful Pi run into a failed one. If the supervisor is unavailable, final report/result persistence and process-based liveness still work; intermediate activity may be stale until another event is persisted.

## `status` behavior

- Keep the default output bounded: one line per Shot and one Brew summary line.
- For a running Shot, show elapsed runtime, time since last activity, and a short description when known.
- Mark a Shot quiet after 12 minutes without activity. Never kill it automatically.
- Keep existing states and process-liveness semantics; this slice adds activity, not a new completion state or automatic timeout.
- Do not add `--watch` in this slice. A normal `status` invocation is a snapshot of the latest persisted activity.

## Boundaries and failure behavior

- Pin and verify the JSON event format against the supported Pi 1.1.0 CLI. Pi-specific parsing stays in the Worker adapter; the supervisor accepts only Coffee Shop's normalized event protocol.
- Use a Unix-domain socket rather than a TCP listener. Socket setup/cleanup belongs to the Brew supervisor. Worker sends are bounded and best-effort; they must not block Pi or corrupt completion reporting.
- Persist accepted latest-activity state before displaying it. Process identity—not socket connectivity, event recency, or a heartbeat—is the liveness authority.
- Do not persist prompt text, tool arguments, full tool output, or other unbounded/private event payloads as activity descriptions.
- On unknown/malformed Pi events, ignore the activity update and continue collecting output. On socket failure, retain the last activity and continue the Worker. Final report/result errors remain errors under the existing contract.

## Verification

- Unit-test Pi event parsing with captured, non-secret fixtures: tool activity, assistant text, turn completion, unknown types, malformed JSON and fragmented newline-delimited input.
- Use a fake Pi executable to prove that events reach a normalized activity record while the process is still running, that the final assistant answer is still the collected report, and that non-zero Pi exits preserve existing behavior.
- Test the Unix socket protocol, invalid Shot identity, bounded/truncated messages, listener startup/cleanup, client disconnect, and supervisor recovery without classifying a live Worker as dead.
- Test observable `status` output for recent activity, unknown activity, quiet activity, a dead Worker, and queued/completed Shots; assert output remains one line per Shot plus one summary.
- Run the existing Coffee Shop test suite and Filter checks without changing the Beans test commands.
- Dogfood with a real Brew: observe Pi tool activity before it exits, then collect and verify the final report and result. The Barista reviews and integrates Worker output; Workers do not commit.

## Explicitly out of scope

- Replacing Herdr, adding a daemon, TCP networking, remote Workers, `status --watch`, automatic timeouts/cancellation, automatic task decomposition or merges.
- Exposing full Pi event payloads or using activity as a completion/liveness signal.
- Model/thinking configuration, Recipe/schema changes, repository-name labels, higher concurrency, prompt files, completion markers, or per-repository rules (other v0.2 roadmap slices).
