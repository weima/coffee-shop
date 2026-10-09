# Coffee Shop Architecture

Coffee Shop is a local Odin dispatcher. The active Pi session decides how to divide an Order. Coffee Shop starts and tracks Pi workers; it does not act as another AI coordinator.

## Architecture diagram

```mermaid
flowchart TD
    Dev[Developer] -->|Order and review| Barista[Active Pi session<br/>Barista]
    Barista -->|Recipe: order plus Shots| CLI[Coffee Shop brew command and supervisor<br/>Odin]
    Beans[Target repository<br/>and task context] --> CLI
    CLI --> Register[Register<br/>current Brew and Shot status]
    CLI --> Receipt[Receipt<br/>append-only event history]
    CLI --> Scale[Scale<br/>concurrency limit]
    CLI --> HERDR[Herdr workspace<br/>one per Brew]
    HERDR --> Tab1[Shot A tab]
    HERDR --> TabN[Shot N tab]
    Tab1 --> Worker1[Worker A<br/>Pi event adapter]
    TabN --> WorkerN[Worker N<br/>Pi event adapter]
    Worker1 --> Station1[Station A<br/>isolated Git worktree]
    WorkerN --> StationN[Station N<br/>isolated Git worktree]
    Worker1 --> Pi1[Pi CLI<br/>JSON mode]
    WorkerN --> PiN[Pi CLI<br/>JSON mode]
    Pi1 -->|newline-delimited JSON events| Worker1
    PiN -->|newline-delimited JSON events| WorkerN
    Worker1 -->|bounded normalized events| Activity[Per-Brew Unix-domain stream socket]
    WorkerN -->|bounded normalized events| Activity
    Activity -->|validate Brew and running Shot| CLI
    CLI -->|atomically persist| ActivityState[Latest activity<br/>per running Shot]
    Status[Coffee Shop status command] -->|read snapshot| Register
    Status -->|read snapshot| ActivityState
    Worker1 --> Results[Worker reports and check evidence]
    WorkerN --> Results
    Results --> Filter[Filter<br/>review and existing tests]
    Register --> Collect[Collect completed results]
    Receipt --> Collect
    Filter --> Collect
    Collect --> Tray[Tray<br/>summary, evidence, decisions]
    Tray --> Barista
    Barista -->|explicit request| Blend[Proposed Blend command<br/>one commit]
    Station1 -->|Shot changes| Blend
    StationN -->|Shot changes| Blend
    Blend --> Delivery[Retained integration worktree]
    Delivery -->|commit hash and path| Barista
    Delivery -. commit succeeds .-> Cleanup[Close Herdr tabs<br/>remove per-Shot Stations]
    Blend -. conflict or commit failure .-> Preserve[Keep tabs and Stations]
    Preserve --> Barista
    Barista --> Dev
```

## Design views

The views below show the same design from different angles. The server views match the implementation (PLAN.md item 8); the Shot view lists today's states.

### Processes

Which processes exist, and what each one may talk to.

```mermaid
flowchart LR
    Dev[Developer or Barista shell] -->|brew| Sup[Brew supervisor process]
    Dev -->|status, cancel, collect| Cmd[Command process]
    Sup -->|requests over server.sock| Srv[Repository server]
    Cmd -->|requests over server.sock| Srv
    Sup -->|opens tabs and runs Workers| Herdr[Herdr workspace]
    Herdr --> W[Worker process, one per Shot]
    W -->|requests with Brew token| Srv
    W -->|runs| Pi[pi --mode json --print]
    Srv -->|only writer| State[(register.json and receipt.ndjson)]
```

### File ownership

Each file has one writer, so no file needs a lock shared between processes.

```mermaid
flowchart TD
    Brew[brew command, before any Worker exists] -->|creates| Reg[register.json]
    Brew -->|creates| Rec[receipt.ndjson]
    Srv[Repository server] -->|sole writer after launch| Reg
    Srv -->|sole writer after launch| Rec
    Srv -->|rewrites with heartbeat| Meta[servers/name-hash/server.json]
    Srv -->|holds| Lock[servers/name-hash/server.lock]
    W[Worker for one Shot] -->|writes its own| Started[workers/shot.started]
    W -->|writes its own| Result[results/shot.json]
    W -->|writes its own| Report[reports/shot.md]
    W -->|writes its own| Act[workers/shot.activity.json]
    Cancel[cancel command] -->|writes marker only| Marker[cancel marker file]
```

Commands read only a Brew's repository path and token from `register.json`, to find their server. Brew status always comes from the server.

### Transition through the server

A Worker's state change, including the retry-then-abort path. No client reads or writes `register.json` directly.

```mermaid
sequenceDiagram
    participant W as Worker
    participant C as Client code
    participant S as Repository server
    participant F as register.json and receipt.ndjson
    W->>C: transition Shot to running
    C->>S: connect to server.sock
    alt server reachable
        S->>F: check repository and token, then append Receipt event
        S->>F: rewrite Register
        S-->>C: ok
        C-->>W: ok
    else server not reachable
        C->>C: start a server if none is running
        loop a fixed number of attempts, pausing between them
            C->>S: connect to server.sock
        end
        C-->>W: abort with the cause, no state changed
    end
```

### Server lifecycle

The server is one process per repository. A restart keeps its id, so Workers launched earlier still reach it.

```mermaid
stateDiagram-v2
    [*] --> Electing
    Electing --> Standby: lock held by another server
    Standby --> [*]: this process exits
    Electing --> Serving: lock acquired, generation plus one written
    Serving --> Serving: serve request, heartbeat each second
    Serving --> Idle: no non-terminal Brew for this repository
    Idle --> Serving: a Brew becomes active
    Idle --> Exited: idle timeout passes
    Serving --> Crashed: process dies
    Crashed --> Electing: kernel releases lock, next client starts a server with the same id
    Exited --> [*]
```

### Shot states

The states a Shot moves through, as recorded in its Register.

```mermaid
stateDiagram-v2
    [*] --> queued
    queued --> running: Worker started
    queued --> failed: no tab or launch failed
    queued --> cancelled: cancelled before start
    running --> completed: CS-DONE, or exit 0 in a v0.1 Brew
    running --> incomplete: no marker, or CS-BLOCKED
    running --> failed: exit with an error
    running --> cancelled: exited after a cancel request
    running --> interrupted: exit not seen, or not confirmed after cancel
```

## Components

| Component | Responsibility |
| --- | --- |
| **Barista** | The active Pi session. It interprets an Order, writes a Recipe, and reviews results. |
| **Coffee Shop CLI** | The Odin program. It validates inputs, creates Stations, starts Workers in Herdr, records state, and collects results. |
| **Beans** | The target repository and task context supplied to workers. |
| **Recipe** | An Order and its explicit list of Shots. The Barista owns task decomposition. |
| **Shot** | One unit of work with one prompt and one Worker. |
| **Station** | A Git worktree isolated to one Shot. |
| **Worker** | One Pi CLI process in a Herdr tab, working in its Shot's Station. Pi's JSON event stream is reduced to bounded activity summaries. |
| **Activity channel** | A per-Brew Unix-domain stream socket. Workers send bounded newline-delimited summaries best-effort; the supervisor validates Brew/Shot identity and persists the latest one per running Shot. It does not establish liveness. |
| **Register** | Durable current status for each Brew and Shot. |
| **Receipt** | Append-only events that explain status changes. |
| **Server** | One per repository. It starts on demand, holds the Register in memory, and is the only writer of Brew state, so commands and Workers ask it instead of editing files. It is elected by an exclusive lock on `server.lock`, exits when the repository has no active Brew, and serves requests over one Unix socket. See the Server section below. |
| **Scale** | The maximum number of concurrent Workers. |
| **Filter** | Uses a separate one-shot Pi reviewer to check selected changes against the Beans repository's root `standards.md`, then discovers and runs unit/component and end-to-end test commands from existing manifests and test configuration. It reports evidence without fixing code or changing test setup. |
| **Tray** | The final review packet with the outcome, evidence, and any decision for the developer. |
| **Blend (proposed)** | An explicit post-review operation that gathers a Brew's Shot changes into one commit in a retained integration worktree, then removes the per-Shot worktrees after success. |

## Recipe contract

Recipes are strict JSON objects described by the root `recipe.schema.json`. They have exactly one of `order`/`order_file`, a non-empty `shots` array, optional `share`, optional model/thinking defaults, and optional `preamble`/`preamble_file`. A Shot has exactly one of `prompt`/`prompt_file`, a unique safe `id`, optional model/thinking overrides, and optional `expect_changes`. File inputs resolve relative to the Recipe, reject absolute/traversal paths, and are read before Stations are created. Text is snapshotted in Brew state. Scale defaults to two; `workers` opts into 1–5.

## Shared paths

A Station is a fresh checkout, so gitignored dependency directories (`node_modules`, `vendor/bundle`, `.venv`) are absent from it, and installing them per Station would waste space and time. The Recipe's `share` list names Beans paths to symlink into every Station instead. Each path must be relative, free of `..`, outside `.git`, present in the Beans, and gitignored there; otherwise `brew` fails before it creates any state. The check also guarantees a shared path never collides with a tracked file.

A `.gitignore` entry such as `node_modules/` matches only directories, so a symlink to one would appear as an untracked change. Coffee Shop therefore adds an anchored entry (`/node_modules`, no trailing slash) to the repository's shared `info/exclude` file once per path. The entry is redundant for the Beans' real directory and is not duplicated by later Brews. The shared list is recorded in the Register.

The link is read-through, so a Worker that installs packages modifies the Beans' real copy. Coffee Shop does not prevent this; the Barista should tell Workers not to install dependencies.

## Local state

Store each Brew under `$CS_STATE_DIR/<brew-id>/`; when `CS_STATE_DIR` is unset, the default is `~/.coffee-shop/<brew-id>/`. `CS_STATE_DIR` must be an absolute path. Coffee Shop does not use XDG or any other platform directory convention. A Brew ID is `brew-<UTC start time>-<pid>`, for example `brew-20261008T041500Z-1634886`, so sorting by name sorts by start time. IDs are never reused; a counter is appended if two Brews would collide. `register.json` contains its current state; `receipt.ndjson` is its append-only event history. This state remains outside the Beans repository.

Each Brew has a Brew token, `<brew-id>-<guid>`, recorded in `register.json` when the Brew is created. Workers receive it at launch and present it, and a Worker carrying another Brew's token is refused before it records a start. The GUID tells apart Workers that share a resource; it is not a security measure.

Each Brew keeps its state under one repository server. That server keeps its files under `$CS_STATE_DIR/servers/<name>-<hash>/`, with `server.json` (pid, generation, heartbeat, socket path, repository path), `server.lock` and `server.sock`. The server holds `server.lock` for its whole life, so liveness is a kernel fact. The heartbeat is for display only. A restarted server keeps its id, `<name>-<hash>`, so Workers launched under the old server still reach its socket. The server is the only reader and writer of Brew state after launch: commands, the supervisor and Workers ask it over `server.sock`. If it cannot be reached, a client waits and retries a few times, starting the server if needed, and then aborts with the cause. There is no fallback to reading files directly. Before a Brew's first Worker starts, its files are created directly by `brew`.

The Receipt event is appended before the Register is rewritten, so a crash between the two leaves the Receipt one or more events ahead. The server repairs that case: it replays the complete Receipt lines the Register does not yet record, checking each one against the state before it, and cuts off a final line that was never fully written. Any other disagreement, or a failed check, leaves both files untouched and reports the Brew's state as unknown, naming the failing line when it can. To recover from that, inspect `receipt.ndjson` and `register.json` by hand; the Receipt is the more detailed record. A file that cannot be read for another reason, such as permissions, is reported as an I/O error rather than as corruption.

## Server

The server for a repository is described under Local state. This section describes how it talks to clients and how it stays correct.

- **Transport.** A Unix stream socket, `server.sock`, inside the server's directory, which only the user can read. A connection carries one request and one response, each a single JSON line. The socket path must fit the kernel limit of about 107 bytes, so a long `CS_STATE_DIR` is refused with an explanation. Local clients need no network boundary, so TCP is not used.
- **Requests.** `snapshot` returns the Register. `transition` and `request_cancel` change one Shot and return the updated Register. Every request must name a Brew of this repository and carry that Brew's token; a Worker with another Brew's token is refused.
- **Concurrency.** One thread with a non-blocking event loop (`poll`) over the listener and every connected client. Each client gets its own buffers, so a client that stalls or reads slowly delays only itself. A change is always written and synced before its response is sent, so the loop waits for the disk while one change is applied.
- **Socket hygiene.** The listener and every accepted socket are non-blocking and close-on-exec, so a child process never inherits them.
- **Timeouts.** A client that does not finish its request or response within 15 seconds is dropped. A server with no active Brew on its repository exits after 30 seconds; the next command starts a new one.
- **Retries.** A client that cannot reach the server starts it if none is running, retries up to six times with half a second between attempts, then aborts with the cause.
- **Stale servers.** A lock belongs to the file it was taken on. A server that finds its lock file replaced, because the directory was removed and recreated, stops without touching the socket path, which now belongs to its successor.

## Shot lifecycle

| State | Meaning |
| --- | --- |
| `queued` | The Shot is validated and waiting to start. |
| `running` | Its Worker has started and no terminal outcome is confirmed. |
| `completed` | For v0.1 Brews, the Worker exited successfully. For v0.2 Brews, it exited successfully and ended its final response with `CS-DONE`. |
| `failed` | The Worker could not be launched or exited unsuccessfully. |
| `cancelled` | The Shot was cancelled before launch, or its Worker exited after a cancellation request. |
| `interrupted` | The Worker outcome cannot be proved, for example after an unexpected session loss. |
| `incomplete` | A v0.2 Worker exited successfully but did not finish with `CS-DONE`, declared `CS-BLOCKED`, or failed its `expect_changes` check. |

Allowed transitions are `queued` → `running`, `failed`, or `cancelled`, and `running` → `completed`, `failed`, `cancelled`, `interrupted`, or `incomplete`. A cancellation request is recorded separately; a running Shot stays `running` until the Worker exit is confirmed, then becomes `cancelled`. Cancelling a Brew marks queued Shots `cancelled` and interrupts active Workers. Brew status is derived from its Shots rather than maintained as a second state machine.

## Worker activity

A Worker runs Pi with `--mode json --print --no-session`. It parses newline-delimited Pi events and sends only short normalized summaries (for example, a tool name or “drafting response”) over the Brew's Unix-domain stream socket. Each newline-delimited event is bounded and includes a timestamp. The Worker does not send prompts, tool arguments, tool output, or response deltas; send and receive failures do not fail a successful Pi run. The Worker still extracts the final assistant text for the report.

The supervisor stamps received events and atomically saves the latest activity under `workers/<shot>.activity.json`. `workers/<shot>.started_at` records the Worker start time. A `status` snapshot shows running time and the age/description of the last activity on the same line as the Shot. Activity older than 12 minutes is marked quiet; this is not a timeout. A missing socket or activity record only removes progress detail. Worker process identity remains the authority for liveness and completion.

## Cancellation and recovery

`cancel <brew-id>` records a cancellation request and is safe to repeat. While the supervisor is alive it does the work: queued Shots become `cancelled`, and each running Worker has its Herdr tab closed, which ends Pi. A Shot becomes `cancelled` once its Worker process is confirmed gone, or `interrupted` if that cannot be confirmed within ten seconds.

The supervisor records its process identity (PID plus kernel start time, so a reused PID is not mistaken for it) in `supervisor.json`; each Worker does the same in `workers/<shot>.started`. If the supervisor has died, `status` says so, and `collect` or `cancel` take over its job using only evidence: a Worker's result file is recorded as completed or failed, and a Worker that vanished without a result becomes `interrupted`. A live Worker is left alone unless the Brew is being cancelled. A Shot is never marked `completed` without a recorded successful result.

Liveness has three answers, not two. A process is **gone** only on evidence: its `/proc/<pid>/stat` entry is missing, it is a zombie, or its start time differs. If that entry cannot be read, or does not parse, the answer is **unknown**, and unknown is never treated as gone: a Worker is not recorded as `interrupted`, `cancel` does not confirm an exit it cannot see (after its grace period the Shot ends `interrupted`, which says the exit was not confirmed), and `collect` and `cancel` do not take over from a supervisor whose state they cannot read. A process that cannot record its own identity says so and stops rather than writing a guessed start time.

## Filter and Tray

`collect` runs the Filter once for each `completed` Shot and saves its evidence in `<brew>/filter/<shot>.json`; later collections show the saved evidence without re-running Pi or the tests. Delete that file to run the Filter again for a Shot.

- **Review.** A one-shot `pi --print --no-session --no-extensions --no-mcp --tools read,grep,find,ls` reviews `git diff <base commit>` plus the untracked file list against the Station's `standards.md`. The tool allowlist is what keeps it read-only. The Brew records the Beans HEAD commit as the base when it starts. If `standards.md` is missing, the base commit is unknown, there are no changes, or Pi fails, the Tray says the review was not performed; it never shows a failed review as clean.
- **Checks.** Test commands are discovered, never invented, from the Station's own manifests: `package.json` scripts (`test`, `test:unit`, `test:e2e`, `e2e`, `test:playwright`, using the package manager its lockfile or `packageManager` field names), `justfile` (also `Justfile`, `.justfile`) and `Makefile` `test`/`e2e`/`test-e2e` targets, `go.mod`, and `Cargo.toml`. A recipe that needs arguments is skipped, since a bare run could not execute it. If more than one candidate exists for a kind, none is run and the Tray reports the ambiguity. A Playwright configuration without an e2e script, or no recognized test configuration, is reported rather than guessed at.
- **Limits.** Checks run inside the Station, a fresh checkout: dependencies the repository does not commit (for example `node_modules`) are absent, and a command may write build output there. Failures from either cause are reported as failures. Output is kept to its tail, and there is no timeout.
- **Decisions.** The Tray ends with "Decisions for the developer": any Shot that did not complete, a review that reported findings or could not run, a failing check, and every ambiguity or gap above.

## Data flow

1. The Barista supplies a JSON Recipe and the path to the Beans.
2. The CLI validates the repository and Recipe before it starts Workers.
3. The CLI creates one Station per Shot and one Herdr workspace per Brew. A per-Brew supervisor creates one tab per Shot, runs `pi --mode json --print --no-session` from each Station, and keeps at most the Recipe's Worker limit active (two by default, five maximum). It schedules queued Shots as slots open, receives best-effort activity messages, and exits when the Brew is terminal.
4. Workers write their result and check evidence to their own Station. The Barista may assign a normal Shot to add tests from `standards.md`; that Worker receives the Taste-Driven Development skill as task guidance, without installing it into the Beans repository.
5. The CLI updates the Register and Receipt as it observes Worker state. The repository's server makes these writes. The supervisor persists latest activity separately; activity recency never changes liveness. The Scale uses the Recipe's Worker limit (two by default, five maximum); the supervisor continues queued independent Shots after a Worker fails. There is no automatic timeout.
6. Filter runs a separate one-shot Pi code review against `standards.md`, then discovers and runs the repository's existing unit/component and end-to-end test commands without overriding them.
7. The Barista collects Worker reports and Filter evidence into the Tray for human review.
8. The proposed `blend <brew-id>` action integrates reviewed Shot changes after the Barista approves the Tray.

## Blend (proposed)

Blend creates one retained integration worktree from the Brew's recorded Beans base commit and combines its Shot changes into one local commit. Workers continue not to commit. On success, Blend closes that Brew's Herdr tabs and removes its per-Shot Station worktrees, but preserves Brew state, reports, and Filter evidence. It prints the commit hash and integration-worktree path; it never pushes or creates a PR. The Barista removes the retained integration worktree only after the owner is done with it.

If changes conflict or the commit fails, Blend leaves the original tabs, Stations, and state intact. The action is explicit and scoped to one Brew; it does not clean up historical or unrelated Brews.

## Safety boundaries

- A Worker never shares a Station with another Worker in the same Brew.
- Herdr launches Workers from command text. Its command contains only Coffee Shop's internal Worker subcommand, the state directory (so the Worker reads the same Brew state even when `CS_STATE_DIR` is set), and validated Brew/Shot IDs. That subcommand reads the prompt as data and starts Pi with a separate argument vector; Order and Shot text never enter shell syntax.
- Coffee Shop reports a missing or failed Worker as incomplete. It does not treat an unreadable state record as success.
- A test-authoring Worker reads the Beans repository's root `standards.md` and receives Taste-Driven Development as task guidance; Coffee Shop does not install the skill into the Beans repository.
- Filter reports review findings and test outcomes; it does not auto-fix, commit, merge, publish, or manage CI. It does not rewrite test scripts or configuration. If discovery is ambiguous or setup is unavailable, it reports that instead of guessing.
- Workers do not merge, commit, or publish their changes. A person reviews the Tray and explicitly decides when to integrate them.
- Coffee Shop preserves Stations and Brew state by default. The proposed Blend action removes only the target Brew's per-Shot worktrees after its single integration commit succeeds; Brew state, reports, and Filter evidence remain.
- The per-Brew supervisor exists only while `brew` is active. A repository's server runs only while that repository has an active Brew and exits after an idle timeout. There is no always-on watcher or automatic Worker timeout. The Barista asks for status or collection when needed.
- The Register and Receipt live under the Coffee Shop state directory, outside the Beans repository.

## Deliberate omissions

The first version targets one machine, Pi, and Herdr. It does not include second mates, remote execution, Relay, tmux or zmx backends, automatic task decomposition, or automatic merges. Add a feature only when a real workflow needs it.
