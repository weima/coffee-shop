# Odin probe: read pi's login by path, then POST with libcurl

Replaces the Node probe (`spike/probe/`) for the Copilot path. Same design: the child reads
pi's `auth.json` BY PATH, read-only, and makes one request per call. The parent passes only the path.

Files:

- `probe.odin`: the program. `probe test` (step 1, local only) and `probe run <auth.json>` (step 2).
- `fake_server.py`: a loopback fake of the Messages route, for step 1. It binds `127.0.0.1` only.
- `fixtures/`: test auth files. Fake tokens only, never the user's file.
- `step2-run.jsonl`: the raw output of the step 2 run.

## Build

```sh
odin check spike/probe-odin
odin build spike/probe-odin -out:/tmp/probe-odin-bin   # links /usr/lib/libcurl.4.dylib
```

The binary goes to `/tmp`, so nothing is added to the repo.

## Step 1: tests, no model calls

```sh
python3 spike/probe-odin/fake_server.py 18777 > /tmp/probe-odin-fake.log 2>&1 &
PROBE_TEST_BASE_URL=http://127.0.0.1:18777 /tmp/probe-odin-bin test
kill %1
```

`PROBE_TEST_BASE_URL` is read only in `test` mode and must start with `http://127.0.0.1:`.
Without it, or with any other host, the test mode exits 1 before any request. `run` never reads it.

Results (first full run, exit 0):

| Test | Result |
|---|---|
| base URL from `proxy-ep` (pure) | PASS |
| base URL default without `proxy-ep` (pure) | PASS |
| read a fixture auth file by path, 1 read | PASS |
| half-written file stops after 4 reads, at least 600 ms | PASS |
| half-written file is retried, then read (writer completes after 300 ms) | PASS |
| POST 200, JSON usage parsed (12 in, 2 out) | PASS |
| 429 detected, run stops after 1 request | PASS |
| 401 detected, run stops after 1 request | PASS |
| 5xx detected, run stops after 1 request | PASS |
| expired token stops before any request | PASS |
| full loop: 3 sessions x 2 calls, exit 0 | PASS |

`failures: 0`. The fake server log has 10 requests (1 + 1 + 1 + 1 + 6). The 429, 401, and 5xx
runs made one request each, and the expired run made none. No 400 was logged, so the request
shape matched the checks in `fake_server.py`.

No real host was contacted in step 1. The only base URL in use is the loopback one from
`PROBE_TEST_BASE_URL`. The fixtures were checked with sha256 before and after the tests and are unchanged.

## Step 2: six real calls

```sh
/tmp/probe-odin-bin run "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/auth.json" \
  > spike/probe-odin/step2-run.jsonl
```

The shell passed the path only and never opened `auth.json`. The footprint was sampled once with
`footprint -p <pid>` at about 2.5 s.

Model `claude-haiku-5.5`, prompt `Reply with the single word OK.`, `max_tokens` 16.

| Session | Call | Latency ms | HTTP status | Input tokens | Output tokens |
|---|---|---|---|---|---|
| 1 | 1 | 772 | 200 | 18 | 4 |
| 1 | 2 | 775 | 200 | 18 | 4 |
| 2 | 3 | 938 | 200 | 18 | 4 |
| 2 | 4 | 746 | 200 | 18 | 4 |
| 3 | 5 | 829 | 200 | 18 | 4 |
| 3 | 6 | 838 | 200 | 18 | 4 |

- Total tokens: 132 (108 in, 24 out).
- Mean latency: 816 ms. Wall time: 10,927 ms (6 s of waits plus the calls).
- Odin process footprint at 2.5 s: 3952 KB (about 3.9 MB).
- Stop rules: no error occurred, so no stop. Stderr was empty.
- No `pi` or `node` process started during or after the run. The PID set of `node` and `pi`
  processes was the same before, during (2.5 s sample), and after. `probe.odin` never spawns a process.

## Wire format (from pi's source, not from the user's auth.json)

- Host: `proxy-ep=` from the token, with `proxy.` replaced by `api.`. Default
  `https://api.individual.githubcopilot.com`. Path `POST /v1/messages`.
- Headers: `Authorization: Bearer <access>`, `X-Initiator: user`, `Openai-Intent: conversation-edits`,
  `accept`, `anthropic-version: 2023-06-01`, `anthropic-dangerous-direct-browser-access: true`,
  `content-type: application/json`, and the Copilot set `User-Agent`, `Editor-Version`,
  `Editor-Plugin-Version`, `Copilot-Integration-Id` (pi-ai `COPILOT_HEADERS`).
- Model: `claude-haiku-5.5` is not in pi's static catalog, so the wire settings are the same as
  `claude-haiku-4.5`, as in the Node probe. The header values are the same.

## Limits built in

- 6 requests in total: 3 sessions x 2 calls. `auth.json` is read once at each session start.
- 1.0 s wait before every call, including the first.
- Any non-2xx status, or any transport error, stops the run with exit 2. No retries.
- A JSON parse error on the file retries 3 times after the first read, 200 ms apart (4 reads).
  The parse message is not printed.
- An expired token stops the run with exit 3. The program never refreshes or re-reads it.
- Error text is cut to 160 bytes after the access token is replaced with `[redacted]`.
- Odin prints JSON lines only. The access token is used only inside the `Authorization` header.

## What this shows

- The login can be read by path, read-only, from an Odin program. The shell never opens it.
- libcurl over the system `libcurl.4.dylib` makes the Copilot call with the pi wire format.
  The 6 real calls all returned 200 with usage.
- The stop rules (any non-2xx, expiry, parse retry) run in code. Step 1 showed each stop with
  the right request count.

## What this does not show

- TLS details: which CA, which cipher, and whether certificate pinning applies. This is the
  system libcurl, and we did not inspect its TLS setup.
- Connection reuse. The program makes a new curl handle for each call, so each latency includes DNS,
  TCP, and TLS. A reused connection would be faster.
- Token refresh. The program never refreshes. It stops at expiry, and it does not re-read a
  file that pi may have refreshed in the meantime.
- Streaming. pi sends `stream: true`. This probe reads a non-streaming reply, so time to first token
  is not measured.
- Real 403 and quota responses. Only the 200 path ran live. 429, 401, and 5xx are tested locally
  against the fake server.
- Footprint under load: one sample at 2.5 s, one run, no comparison with the Node probe.
- Latency and token cost over more runs. Six calls is one sample.

## Questions

Q1: Should step 3 use streaming (`stream: true`, as pi does) to measure time to first token?
Q2: On expiry, is "stop" right, or should the probe re-read `auth.json` once, as the Node probe did?
Q3: The repo rule is to run tests through `just`. Should I add a `just` recipe later? This task
forbade edits outside `spike/probe-odin/`, so none was added.
