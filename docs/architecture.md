# Coffee Shop Architecture

Coffee Shop is a local Odin dispatcher. The active Pi session decides how to divide an Order. Coffee Shop starts and tracks Pi workers; it does not act as another AI coordinator.

## Architecture diagram

```mermaid
flowchart TD
    Dev[Developer] -->|Order and review| Barista[Active Pi session<br/>Barista]
    Barista -->|Recipe: order plus Shots| CLI[Coffee Shop CLI<br/>Odin]
    Beans[Target repository<br/>and task context] --> CLI
    CLI --> Register[Register<br/>current Brew and Shot status]
    CLI --> Receipt[Receipt<br/>append-only event history]
    CLI --> Scale[Scale<br/>concurrency limit]
    CLI --> TMUX[tmux sessions]
    TMUX --> Worker1[Pi Worker<br/>Shot A]
    TMUX --> WorkerN[Pi Worker<br/>Shot N]
    Worker1 --> Station1[Station A<br/>isolated Git worktree]
    WorkerN --> StationN[Station N<br/>isolated Git worktree]
    Worker1 --> Results[Worker reports and check evidence]
    WorkerN --> Results
    Results --> Filter[Filter<br/>review and existing tests]
    Register --> Collect[Collect completed results]
    Receipt --> Collect
    Filter --> Collect
    Collect --> Oreo[Oreo<br/>summary, evidence, decisions]
    Oreo --> Barista
    Barista --> Dev
```

## Components

| Component | Responsibility |
| --- | --- |
| **Barista** | The active Pi session. It interprets an Order, writes a Recipe, and reviews results. |
| **Coffee Shop CLI** | The Odin program. It validates inputs, creates Stations, starts Workers, records state, and collects results. |
| **Beans** | The target repository and task context supplied to workers. |
| **Recipe** | An Order and its explicit list of Shots. The Barista owns task decomposition. |
| **Shot** | One unit of work with one prompt and one Worker. |
| **Station** | A Git worktree isolated to one Shot. |
| **Worker** | One Pi CLI process in a tmux session. |
| **Register** | Durable current status for each Brew and Shot. |
| **Receipt** | Append-only events that explain status changes. |
| **Scale** | The maximum number of concurrent Workers. |
| **Filter** | Reviews selected changes against the Beans repository's root `standards.md`, discovers and runs its existing unit/component and end-to-end tests, and reports evidence without changing test configuration. |
| **Oreo** | The final review packet with the outcome, evidence, and any decision for the developer. |

## Data flow

1. The Barista supplies a Recipe and the path to the Beans.
2. The CLI validates the repository and Recipe before it starts workers.
3. The CLI creates one Station per Shot and starts each Pi Worker in tmux.
4. Workers write their result and check evidence to their own Station. The Barista may assign a normal Shot to add tests from `standards.md`; that Worker receives the Taste-Driven Development skill as task guidance, without installing it into the Beans repository.
5. The CLI updates the Register and Receipt as it observes worker state.
6. Filter reviews the selected changes against `standards.md` and discovers and runs the repository's existing unit/component and end-to-end test commands without overriding them.
7. The Barista collects Worker reports and Filter evidence into the Oreo for human review.

## Safety boundaries

- A Worker never shares a Station with another Worker in the same Brew.
- The CLI passes the Pi executable and arguments as separate process arguments. It does not build shell commands from task text.
- Coffee Shop reports a missing or failed Worker as incomplete. It does not treat an unreadable state record as success.
- A test-authoring Worker reads the Beans repository's root `standards.md` and receives Taste-Driven Development as task guidance; Coffee Shop does not install the skill into the Beans repository.
- Filter does not rewrite test scripts or configuration. If test discovery is ambiguous or required setup is unavailable, it reports that instead of guessing.
- Workers do not merge or publish their changes. A person reviews the Oreo and decides what to integrate.
- There is no always-on watcher. The Barista starts an explicit Brew and asks for status or collection when needed.

## Deliberate omissions

The first version targets one machine, Pi, and tmux. It does not include second mates, remote execution, Relay, multiple backends, automatic task decomposition, or automatic merges. Add a feature only when a real workflow needs it.
