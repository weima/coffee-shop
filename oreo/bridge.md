# Oreo bridge

**Status:** decided 2026-10-11. Not implemented yet. This is the spec for the TypeScript extension and the Odin side it talks to.

The bridge is the one part of Oreo that cannot be tested offline: it is the seam between the Odin host and pi's model layer. This document fixes the contract so the two sides are written against a spec instead of being discovered twice.

## Why it can work at all

`PLAN.md` recorded the bridge as "proposed, pending the spike". The spike is answered from pi's own documentation and type declarations:

- An extension receives an `ExtensionContext` that "provides the working directory, mode, UI, session manager, **model runtime**, abort signal, context usage, and controls for compaction and shutdown" (`docs/extensions.md:211`).
- "Use `ctx.modelRegistry.streamSimple()` for provider-neutral nested model calls" (`docs/extensions.md:212`).
- `ModelRegistry` exposes `find(provider, modelId)`, `complete(model, context, options?)`, `streamSimple(model, context, options?)`, `hasConfiguredAuth(model)`, and `getProviderAuthStatus(provider)` (`dist/core/model-registry.d.ts:24-52`).

So an extension can call a model on Oreo's behalf. `streamSimple` and `complete` authenticate **at request time inside pi**, so no credential ever crosses the pipe: Oreo sends `{provider, model, thinking, messages, tools}` and receives text and tool calls. That satisfies F2 (Oreo does no auth work) and the third-round A2 constraint that the parent pi must support the chosen provider, model, and thinking level.

## Decision

1. **Transport.** Newline-delimited JSON over the host's stdin and stdout, exactly as the Odin `transport` slice already does. No sockets, no HTTP, no extra port.
2. **Process model.** The pi extension spawns the Odin host as a child process, once, on extension load. One long-lived host per pi process. The child is not detached; its lifetime is the extension's.
3. **Auth boundary.** Credentials stay in pi. The extension resolves the model and authenticates; the host only ever sees provider and model *names*.
4. **Request style.** The first version uses `ctx.modelRegistry.complete()`, not `streamSimple()`. Oreo's provider interface is request-then-response, so a non-streaming call is the smallest thing that works. Streaming and progress events are a later upgrade (see Open items).
5. **Model lookup.** The extension resolves the model through `ctx.modelRegistry.find(provider, model)` against pi's live catalog. Oreo therefore inherits pi's model metadata (context window, thinking levels, compat flags) without reading the store itself.

## Process model

| Event | What happens |
|---|---|
| Extension loads | Spawn the host; do not block pi startup on it. |
| Host writes `ready` | Mark the bridge live. Requests may now be sent. |
| Extension unloads, or the session ends | Send `quit`; wait up to 2 s for `stopped`; then kill the child. |
| Host exits unexpectedly | Report once through the pi UI; do not respawn automatically in v1. |
| Host stdout closes | Same as unexpected exit. Host stderr is forwarded to pi's log, never parsed as protocol. |

The host owns the durable session store (`~/.oreo/sessions.db`). Killing the host must leave that store consistent; the store's own restart rule already marks unfinished work `interrupted`.

## Wire protocol

One JSON object per line in both directions. Lines are never pretty-printed. A malformed line is reported and skipped, never fatal.

### pi → host (already implemented in `src/transport.odin`)

| Message | Fields | Reply |
|---|---|---|
| `submit` | `session_id, prompt, provider, model, thinking` | `accepted` |
| `resume` | `work_item_id, input` | `accepted` |
| `close_session` | `session_id` | `closed` |
| `quit` | — | `stopped`, then exit |

### host → pi (already implemented)

| Message | Fields |
|---|---|
| `ready` | `protocol: 1` |
| `accepted` | `work_item_id` |
| `closed` | `session_id` |
| `stopped` | — |
| `event` | `kind` (`needs_input` \| `progress` \| `final_result`), `session_id`, `work_item_id`, `message` |
| `error` | `reason` |

### The new half: model requests

This is what the bridge adds. The host writes a request and blocks until the matching response arrives; requests are matched by `request_id`.

**host → extension**

```json
{"type":"model_request","request_id":"mr-7","provider":"opencode-go","model":"deepseek-v4.1-flash","thinking":"low",
 "messages":[{"role":"user","text":"read src/app.txt"}],
 "tools":[{"name":"read","description":"Read a file.","parameters_json":"{\"type\":\"object\",...}"}]}
```

`messages` items are Oreo's `Agent_Message`:

| Field | Notes |
|---|---|
| `role` | `system` \| `user` \| `assistant` \| `tool` |
| `text` | always present, possibly empty |
| `tool_calls` | present on an `assistant` message; `[{id, name, arguments_json}]` |
| `tool_call_id` | present on a `tool` message |

**extension → host**

```json
{"type":"model_response","request_id":"mr-7","text":"the file says hello",
 "tool_calls":[{"id":"c1","name":"read","arguments_json":"{\"path\":\"src/app.txt\"}"}]}
```

```json
{"type":"model_error","request_id":"mr-7","reason":"not logged in to provider opencode-go in pi"}
```

Exactly one of `model_response` / `model_error` is sent per `model_request`, always. A request that attracts no reply would hang a worker thread forever, so the extension answers on every path, including an unexpected throw.

## The TypeScript extension

### Layout

```
extensions/oreo/
  index.ts       pi-facing glue: spawn, lifetime, event relay. Thin.
  protocol.ts    pure: line framing, message parse, pi-type mapping. No pi, no process.
  protocol_test.ts  node --test suite for protocol.ts
```

Keeping the parsing and type mapping in a module with no pi or process dependency is what makes any of this testable offline in a repository that has no JS test infrastructure yet. `index.ts` stays small enough to read in one sitting.

### pi APIs used

| Need | API |
|---|---|
| Resolve the model | `ctx.modelRegistry.find(provider, modelId)` |
| Check the user is logged in | `ctx.modelRegistry.hasConfiguredAuth(model)` |
| Make the call | `ctx.modelRegistry.complete(model, context, {reasoning, signal})` |
| Cancellation | `ctx.signal` (extension context) |
| Child process | `spawn` from `node:child_process` |
| Surface a problem to the user | the pi UI helpers on `ctx` |

### Type mapping

| Oreo | pi-ai |
|---|---|
| `system` message | `{role:"system", content: text}` |
| `user` message | `{role:"user", content: text, timestamp: Date.now()}` |
| `assistant` message | `{role:"assistant", content:[{type:"text",text}, ...toolCalls], ...}` |
| `tool` message | `ToolResultMessage` (shape to confirm at implementation) |
| `tools[].parameters_json` | `Type.Unsafe<TSchema>(JSON.parse(parameters_json))` |
| response `content` `TextContent` | `text` |
| response `ToolCall` | `{id, name, arguments_json: JSON.stringify(arguments)}` |

Two real wrinkles, both to be handled in `protocol.ts` where they are testable:

- `AssistantMessage` requires `api`, `provider`, `model`, `usage`, and `stopReason` even when it is only replayed as history. The extension must synthesize those fields for messages it echoes back into a later request.
- `parameters_json` is a JSON Schema, but pi's `Tool.parameters` is a TypeBox schema. `Type.Unsafe` is the bridge between them.

### Failure handling

| Case | Behaviour |
|---|---|
| `find()` returns undefined | `model_error`, reason names the provider and model |
| No configured auth | `model_error`, reason says which provider to log into in pi |
| `complete()` rejects | `model_error` with the message, token-free |
| `stopReason: "error"` | `model_error` using `errorMessage` |
| Provider returns thinking but no text | `model_response` with empty `text` and no tool calls |
| Host asks for a tool Oreo did not send | passed through; the host rejects it, not the extension |

Reasons are free-form text and must never include a credential. The extension never logs the request body, because the transcript may contain repository content.

## The Odin counterpart

One new piece, `oreo/src/provider_remote.odin`:

- `provider_remote(writer, reader) -> Provider` — a `Provider` whose `complete` serializes a `model_request`, flushes, then blocks reading lines until the matching `request_id` arrives as `model_response` or `model_error`.
- Unrelated lines that arrive while waiting (an `event`, another request's response) are dispatched, not dropped.
- A missing response is bounded by a timeout, so a dead extension fails the work item instead of hanging the pool.
- This is the piece that lets `runtime_work` run against pi instead of a fake.

`provider_remote` is testable offline against a fake peer over an `os.Pipe`, in the same style as the existing transport test.

## Verification

| What | How |
|---|---|
| Framing and type mapping | `protocol_test.ts` under `node --test`, no model calls |
| `provider_remote` | Odin test with a fake peer over a pipe |
| The two halves agree | A scripted fake host: real extension protocol module on one side, canned lines on the other |
| Real provider call | One approved `submit` on `opencode-go/deepseek-v4.1-flash` |
| End to end | The v0.4 gate rerun with Oreo as the runtime |

## Open items

1. **Streaming.** v1 answers with a complete message. `streamSimple` plus `progress` events is the upgrade, and it is what makes a long turn observable.
2. **Assistant history fields.** The synthesized `api`/`provider`/`model`/`usage`/`stopReason` for replayed messages need confirming against a real request.
3. **Tool result shape.** `ToolResultMessage` was not pinned down when this was written.
4. **Host binary location.** The extension must find the built Odin host; packaging and the "not built yet" error path are unresolved.
5. **Thinking level default.** The host's config default is `low`. Whether the extension should instead defer to the pi session's own thinking level is open.
