// Read-only child: reads pi's auth.json BY PATH and makes up to 6 non-streaming
// Copilot calls (3 sessions x 2), one at a time. Never writes auth.json, takes no
// lock, never refreshes a token, never prints a secret. Usage: node child.mjs <auth.json>
import { readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

const [, , authPath] = process.argv;
const MODEL = "claude-haiku-5.5";
// pi's own github-copilot catalog (the source of truth for model ids and wire API).
const CATALOG = "/Users/weima/.bun/install/global/node_modules/@earendil-works/pi-ai/dist/providers/data/github-copilot.json";
const PROMPT = "Reply with the single word OK.";
const SESSIONS = 3;
const CALLS_PER_SESSION = 2;
const WAIT_MS = 1000;
const PARSE_RETRIES = 3;
const PARSE_RETRY_MS = 200;
const PROVIDER = "github-copilot";

// Exit codes: 0 done, 2 API stop, 3 auth stop, 4 model not in pi's catalog.
const out = (obj) => process.stdout.write(JSON.stringify(obj) + "\n");
let secrets = [];

function redact(text) {
  let t = String(text).slice(0, 160);
  for (const s of secrets) if (s) t = t.split(s).join("[redacted]");
  return t
    .replace(/Bearer\s+\S+/gi, "Bearer [redacted]")
    .replace(/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/g, "[redacted]")
    .replace(/tid=[^;\s"]+/g, "[redacted]")
    .replace(/sk-[A-Za-z0-9_-]+/g, "[redacted]");
}

function stop(code, reason, extra = {}) {
  out({ stop: reason, ...extra });
  process.exit(code);
}

// Read the github-copilot credential by path. Retry only on JSON parse errors
// (a half-written file). Never echo the parse message: V8 can quote file content.
async function readCredential() {
  for (let attempt = 0; ; attempt++) {
    let raw;
    try {
      raw = readFileSync(authPath, "utf8");
    } catch (e) {
      stop(3, `auth file unreadable (${e.code ?? "error"})`);
    }
    let data;
    try {
      data = JSON.parse(raw.replace(/^\uFEFF/, ""));
    } catch {
      if (attempt < PARSE_RETRIES) {
        await sleep(PARSE_RETRY_MS);
        continue;
      }
      stop(3, "auth file is not valid JSON after retries");
    }
    const cred = data?.[PROVIDER];
    if (!cred || cred.type !== "oauth" || typeof cred.access !== "string" || typeof cred.expires !== "number") {
      stop(3, `no usable ${PROVIDER} oauth credential in auth file`);
    }
    secrets = [cred.access, cred.refresh];
    return cred;
  }
}

// Same rule as pi-ai: the API host is the token's proxy-ep with proxy. -> api.
function baseUrlFromToken(token) {
  const m = token.match(/proxy-ep=([^;]+)/);
  return m ? `https://${m[1].replace(/^proxy\./, "api.")}` : "https://api.individual.githubcopilot.com";
}

// Decision (Q1): MODEL is live in `pi --list-models` but absent from the static catalog,
// so its wire format comes from the catalog sibling SIBLING. The note line says so.
const SIBLING = "claude-haiku-4.5";
function loadModel() {
  const catalog = JSON.parse(readFileSync(CATALOG, "utf8"));
  const entries = Object.values(catalog).flatMap((byId) => Object.values(byId));
  const sibling = entries.find((m) => m.id === SIBLING && m.provider === PROVIDER);
  if (!sibling || sibling.api !== "anthropic-messages") stop(4, `sibling ${SIBLING} missing or not anthropic-messages`);
  const listed = entries.find((m) => m.id === MODEL && m.provider === PROVIDER);
  if (!listed) out({ note: `${MODEL} not in static catalog; wire format from ${SIBLING}` });
  return listed ?? { ...sibling, id: MODEL };
}

async function main() {
  const t0 = performance.now();
  const entry = loadModel();
  let n = 0;
  for (let session = 1; session <= SESSIONS; session++) {
    let cred = null; // fresh read at each session start
    for (let call = 1; call <= CALLS_PER_SESSION; call++) {
      n++;
      await sleep(WAIT_MS);
      if (!cred || Date.now() >= cred.expires) {
        cred = await readCredential();
        if (Date.now() >= cred.expires) stop(3, "token expired; re-login with pi (child does not refresh)", { call: n });
      }
      const body = JSON.stringify({ model: entry.id, max_tokens: 16, messages: [{ role: "user", content: PROMPT }] });
      const headers = {
        "content-type": "application/json",
        accept: "application/json",
        authorization: `Bearer ${cred.access}`,
        "anthropic-version": "2023-06-01",
        "X-Initiator": "user",
        "Openai-Intent": "conversation-edits",
        ...entry.headers,
      };
      const start = performance.now();
      let res;
      let text;
      try {
        res = await fetch(`${baseUrlFromToken(cred.access)}/v1/messages`, {
          method: "POST",
          headers,
          body,
          signal: AbortSignal.timeout(60_000),
        });
        text = await res.text();
      } catch (e) {
        stop(2, `network error: ${redact(e.name)}`, { call: n, session });
      }
      const latency_ms = Math.round(performance.now() - start);
      if (!res.ok) {
        stop(2, `HTTP ${res.status}: ${redact(text)}`, { call: n, session, status: res.status, latency_ms });
      }
      let usage = {};
      try {
        usage = JSON.parse(text).usage ?? {};
      } catch {
        stop(2, "2xx response was not JSON", { call: n, session, status: res.status, latency_ms });
      }
      out({
        call: n,
        session,
        latency_ms,
        status: res.status,
        input_tokens: usage.input_tokens ?? null,
        output_tokens: usage.output_tokens ?? null,
      });
    }
  }
  out({ done: true, calls: n, total_ms: Math.round(performance.now() - t0) });
  process.exit(0);
}

if (!authPath) stop(3, "usage: node child.mjs <path-to-auth.json>");
main();
