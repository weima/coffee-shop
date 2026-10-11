// Parent: starts ONE read-only child with the auth.json PATH only (never the token),
// relays its JSON lines, samples the child's footprint while it runs, and reports.
// It never opens auth.json. Usage: node parent.mjs [path-to-auth.json]
import { spawn, execFile } from "node:child_process";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";

const here = dirname(fileURLToPath(import.meta.url));
const authPath = process.argv[2] ?? join(process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent"), "auth.json");
const FOOTPRINT_AT_MS = 2500; // child is alive for at least 6 s of waits

const rows = [];
let footprint = null;
const t0 = performance.now();
const child = spawn(process.execPath, [join(here, "child.mjs"), authPath], { stdio: ["ignore", "pipe", "pipe"] });

const sampler = setTimeout(() => {
  execFile("footprint", ["-p", String(child.pid)], (err, stdout) => {
    const m = !err && stdout.match(/Footprint:\s*([\d.]+)\s*(KB|MB|GB)/);
    if (m) footprint = `${m[1]} ${m[2]}`;
  });
}, FOOTPRINT_AT_MS);

const rl = createInterface({ input: child.stdout });
rl.on("line", (line) => {
  let obj;
  try {
    obj = JSON.parse(line);
  } catch {
    return;
  }
  if (obj.call) rows.push(obj);
  console.log(JSON.stringify(obj));
});

let stderr = "";
child.stderr.on("data", (d) => (stderr += d));

child.on("close", (code) => {
  clearTimeout(sampler);
  const wall_ms = Math.round(performance.now() - t0);
  const tokens = rows.reduce((s, r) => s + (r.input_tokens ?? 0) + (r.output_tokens ?? 0), 0);
  console.log(JSON.stringify({ summary: true, exit_code: code, calls_ok: rows.length, wall_ms, total_tokens: tokens, child_footprint: footprint }));
  if (stderr) console.log(JSON.stringify({ stderr: stderr.slice(0, 200).replace(/\S*auth\.json\S*/g, "[path]") }));
  process.exit(code === 0 ? 0 : 1);
});
