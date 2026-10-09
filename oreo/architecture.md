# Oreo Architecture

Oreo is a small, standalone Odin agent harness. It will begin in this repository as its own package and expose a library API that Coffee Shop can use. Its package boundary should allow the code to move into an independent repository later.

The OAuth and agent-loop reference is documented in [Oreo's README](README.md#reference-implementation). Oreo has no runtime or build dependency on that reference.

## System boundary

![Oreo system architecture, including Oreo the American Shorthair mascot](assets/architecture-diagram.svg)

[Open the self-contained HTML diagram](assets/architecture-diagram.html).

Each run call drives one session. Oreo imposes no limit on concurrent calls; the consumer supplies task context and owns scheduling and resource limits.

## Responsibilities

| Oreo owns | Its consumer owns |
|---|---|
| Provider login and token refresh | How many sessions to start and when |
| One model session and its tool-call loop | Task decomposition and scheduling |
| The minimal `read`, `write`, and `execute` tools | Repository/worktree setup and cleanup |
| Oreo's own credential storage | Machine-wide CPU and memory policy |

Oreo does not create a worker pool or impose a global session limit. A consumer that starts many sessions is responsible for knowing the resource limits of its machine.

## Session flow

1. The consumer creates a session with a provider/model, instructions, and the available tools.
2. Oreo sends the conversation and tool definitions to that provider.
3. Oreo returns text to the consumer, or executes a requested tool and sends the result back to the model.
4. The loop ends when the model returns a final answer, the consumer cancels, or the provider reports an error.

A session belongs to its caller. The caller chooses its lifetime, runs concurrent sessions, and supplies the working directory and task context. Oreo does not decompose tasks or coordinate other sessions.

## Providers and authentication

Oreo implements provider-specific flows directly in Odin:

- **OpenAI Codex:** browser OAuth with PKCE and a loopback callback, plus device-code login for headless use; refresh tokens when needed.
- **GitHub Copilot:** GitHub device-code login, exchange the GitHub credential for a Copilot access token, then refresh that token.

These flows are not one generic OAuth implementation. Keep each provider's endpoints, token fields, refresh rules, and error handling in its adapter. Verify provider behavior and authorization requirements before release; OAuth client identifiers or private endpoints may not be available to another application.

Oreo stores its own credentials under `~/.oreo/auth.json`, with owner-only permissions. It never reads or writes another agent's credential store. Tokens and authorization headers must not appear in logs, test output, or the repository. Reference source links are in [Oreo's README](README.md#reference-implementation).

## Tools

Oreo starts with three tools:

| Tool | Responsibility |
|---|---|
| `read` | Read a file from the caller's working context. |
| `write` | Create or replace a file in that context. |
| `execute` | Run a requested command and return its result to the model. |

`execute` is Oreo's name for the command tool; it does not imply a security sandbox. Unless the consumer supplies an operating-system boundary, tool actions have the permissions of the Oreo process. The detailed input/output contracts and output handling are implementation-plan decisions.

## Boundaries

- Oreo is an Odin package/library first, not a wrapper around provider command-line processes.
- Provider clients and OAuth flows are implemented in Oreo.
- Coffee Shop may call Oreo as a library but retains responsibility for Workers, worktrees, state, and concurrency.
- No global resource manager, session scheduler, automatic task decomposition, or machine-wide OOM policy belongs in Oreo.
- Additional tools or providers are added only when a consumer needs them.
