# Oreo probe: read the login by path, then make 6 real calls

Status: **run once, 6/6 calls OK.** `claude-haiku-5.5` is live in `pi --list-models` but
absent from pi's static github-copilot catalog (`pi-ai/dist/providers/data/github-copilot.json`).
The probe uses its wire format from the catalog sibling `claude-haiku-4.5` and prints a note line.

## Files

- `child.mjs`: one read-only child. Takes one argument, the path to `auth.json`.
  It checks the model against pi's catalog, reads the `github-copilot` oauth
  credential by path, and makes 3 sessions x 2 non-streaming calls, one at a time.
- `parent.mjs`: starts the child with the path only. It never opens `auth.json`.
  It relays the child's JSON lines, samples the child's footprint while it runs,
  and prints a summary.

## Run

```sh
node spike/probe/parent.mjs                 # default: $PI_CODING_AGENT_DIR or ~/.pi/agent, + /auth.json
node spike/probe/parent.mjs /path/to/auth.json
```

To change the model, edit `MODEL` in `child.mjs`. It must be an `id` in pi's catalog.

## Limits built in

- 6 calls total: 3 sessions x 2. Each session re-reads the file once at its start.
- 1.0 s wait before every call, including the first.
- Stops at the first non-2xx response or network error, exit 2. No retries.
- A JSON parse error on the file (half-written) retries up to 3 times, 200 ms apart.
  The parse message is not printed, because V8 can quote file content.
- Expired token: re-read once. If still expired, stop, exit 3. The child never refreshes.
- Missing model in pi's catalog: stop before any read or call, exit 4.
- Error text is truncated to 160 characters and redacted (Bearer values, `gh*_` tokens,
  `tid=` fields, `sk-` keys, and the literal token strings).

## Wire format (taken from pi's source)

- Host: the `proxy-ep=` value in the access token, with `proxy.` replaced by `api.`.
  The fallback is `https://api.individual.githubcopilot.com`.
- The entry's API is `anthropic-messages`, so the request is
  `POST {host}/v1/messages` with `authorization: Bearer <access>`, the catalog headers,
  `X-Initiator: user`, `Openai-Intent: conversation-edits`, and `anthropic-version`.
- `max_tokens: 16`, prompt `Reply with the single word OK.`

## Output

One JSON line per call: `call`, `session`, `latency_ms`, `status`, `input_tokens`,
`output_tokens`. Then `summary` from the parent with exit code, calls, wall ms, total
tokens, and child footprint. A stop prints `{"stop": ...}` with the call number.

## What this shows

- The login can be read by path, read-only, with no token value passed between processes.
- The stop rules (first error, expiry, missing model) are enforced in code.
- Taking the model id from pi's catalog means a rename shows up as a stop, not a silent failure.

## What this does not show

- Latency, cost, and token numbers for a real call. These need a live run.
- Behavior of a real 429, 401, or 5xx. The stop path is written but untested against the API.
- Whether Copilot accepts the access token without a fresh exchange. The child uses
  the stored access token and does not refresh.
- Footprint under real load. The parent samples once, about 2.5 s in.
