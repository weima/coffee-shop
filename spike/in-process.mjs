// Measures N idle pi sessions inside ONE node process.
// Run: node --expose-gc spike/in-process.mjs
import { createIdleSession, isolate, loadSdk, toMb } from "./lib.mjs";

const CHECKPOINTS = [1, 10, 50, 100];
const IDLE_WINDOW_MS = 2000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

if (typeof global.gc !== "function") {
	console.warn("warning: run with --expose-gc for stable heapUsed numbers");
}

const iso = isolate();
const sdk = await loadSdk();
const sessions = [];
const rows = [];
let failure = null;
const notes = new Set();

function sample() {
	global.gc?.();
	const m = process.memoryUsage();
	const cpu = process.cpuUsage();
	return { rss: m.rss, heap: m.heapUsed, cpuMs: (cpu.user + cpu.system) / 1000 };
}

async function idleCpuPct() {
	const c0 = process.cpuUsage();
	const w0 = performance.now();
	await sleep(IDLE_WINDOW_MS);
	const used = process.cpuUsage(c0);
	return (((used.user + used.system) / 1000) / (performance.now() - w0)) * 100;
}

const base = sample();
rows.push({ n: 0, rssMb: toMb(base.rss), heapMb: toMb(base.heap), createMs: 0, avgRssMb: 0, idleCpuPct: null });

let createMs = 0; // creation time only; idle windows are excluded
try {
	for (const target of CHECKPOINTS) {
		const t0 = performance.now();
		while (sessions.length < target) {
			const { session, note } = await createIdleSession(sdk, iso);
			sessions.push(session);
			if (note) notes.add(note);
		}
		createMs += performance.now() - t0;
		const s = sample();
		const n = sessions.length;
		rows.push({
			n,
			rssMb: toMb(s.rss),
			heapMb: toMb(s.heap),
			createMs: Math.round(createMs),
			avgRssMb: Math.round(((s.rss - base.rss) / n / 1024 / 1024) * 100) / 100,
			idleCpuPct: Math.round((await idleCpuPct()) * 10) / 10,
		});
	}
} catch (err) {
	failure = { atN: sessions.length + 1, message: String(err?.message ?? err).replace(/\s+/g, " ") };
} finally {
	for (const session of sessions) {
		try {
			session.dispose();
		} catch (err) {
			console.error("dispose failed:", err?.message ?? err);
		}
	}
	sessions.length = 0;
}

const after = sample();
iso.cleanup();

console.log("| N | RSS (MB) | heapUsed (MB) | create time, cumulative (ms) | avg RSS per session (MB) | idle CPU (%, 2 s) |");
console.log("|---|---|---|---|---|---|");
for (const r of rows) {
	const avg = r.n === 0 ? "-" : r.avgRssMb.toFixed(2);
	const idle = r.idleCpuPct === null ? "-" : r.idleCpuPct.toFixed(1);
	console.log(`| ${r.n} | ${r.rssMb} | ${r.heapMb} | ${r.createMs} | ${avg} | ${idle} |`);
}
console.log(`\nAfter dispose of all sessions: RSS ${toMb(after.rss)} MB, heapUsed ${toMb(after.heap)} MB`);
console.log(`Node ${process.version}, platform ${process.platform}/${process.arch}`);
console.log(`Model fallback notes (no credentials read): ${[...notes].join(" | ") || "none"}`);
console.log(failure ? `FAILED at N=${failure.atN}: ${failure.message}` : "createAgentSession: no failures");

process.exit(failure ? 1 : 0);
