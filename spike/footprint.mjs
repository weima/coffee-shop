// Physical footprint (macOS `footprint`) of idle pi sessions, measured two ways.
// Run one mode per invocation, so each measurement is a fresh process:
//   node --expose-gc spike/footprint.mjs in-process   # N = 0, 10, 50, 100 in ONE process
//   node spike/footprint.mjs guarded                  # one child per session: 10, then 25, then 50
// Same method both ways: `footprint -f bytes -p <pid>`, total "Footprint: N B" line.
// No model request, no session file. Children are the --child mode of one-process-each.mjs.
import { execFileSync, spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { once } from "node:events";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createIdleSession, isolate, loadSdk } from "./lib.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const CHILD_SCRIPT = join(HERE, "one-process-each.mjs");
const FOOTPRINT = "/usr/bin/footprint";
const PAGE_SIZE = 16384;
const GUARD_BYTES = 2 * 1024 ** 3;
const MAX_PROCESSES = 50;
const PAUSE_MS = 300;
const SETTLE_MS = 1000;
const KILL_WAIT_MS = 5000;
const IN_PROCESS_CHECKPOINTS = [10, 50, 100];
const GUARDED_STEPS = [10, 25, 50];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mb = (bytes) => Math.round((bytes / 1024 / 1024) * 100) / 100;
const gb = (bytes) => Math.round((bytes / 1024 ** 3) * 100) / 100;

// Total physical footprint of one process, in bytes.
function footprintBytes(pid) {
	const out = execFileSync(FOOTPRINT, ["-f", "bytes", "-p", String(pid)]).toString();
	const m = out.match(/Footprint:\s+(\d+) B\b/);
	if (!m) throw new Error(`footprint for pid ${pid} has no total line`);
	return Number(m[1]);
}

// Summed RSS in KB for a list of pids (for comparison only).
function totalRssKb(pids) {
	if (pids.length === 0) return 0;
	const rows = execFileSync("ps", ["-o", "rss=", "-p", pids.join(",")])
		.toString()
		.split("\n")
		.map((s) => s.trim())
		.filter(Boolean);
	if (rows.length !== pids.length) throw new Error(`ps returned ${rows.length} rows for ${pids.length} pids`);
	return rows.reduce((sum, r) => sum + Number(r), 0);
}

// Free + inactive pages, in bytes. Inactive pages count as available.
function availableBytes() {
	const out = execFileSync("vm_stat").toString();
	const header = out.match(/page size of (\d+) bytes/);
	if (!header || Number(header[1]) !== PAGE_SIZE) throw new Error(`vm_stat page size is ${header?.[1]}, expected ${PAGE_SIZE}`);
	const pages = (label) => {
		const m = out.match(new RegExp(`^${label}:\\s+(\\d+)\\.`, "m"));
		if (!m) throw new Error(`vm_stat has no "${label}" line`);
		return Number(m[1]);
	};
	return (pages("Pages free") + pages("Pages inactive")) * PAGE_SIZE;
}

const isAlive = (pid) => {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
};

async function inProcess() {
	if (typeof global.gc !== "function") console.warn("warning: run with --expose-gc so GC runs before each sample");
	const iso = isolate();
	const sdk = await loadSdk();
	const sessions = [];
	const notes = new Set();
	const rows = [];
	let failure = null;

	// Settle, collect garbage, then read footprint of this process.
	async function sample() {
		await sleep(SETTLE_MS);
		global.gc?.();
		return { foot: footprintBytes(process.pid), rssKb: totalRssKb([process.pid]), availGb: gb(availableBytes()) };
	}

	const base = await sample();
	rows.push({ label: "0", n: 0, ...base, perSession: null });
	try {
		for (const target of IN_PROCESS_CHECKPOINTS) {
			while (sessions.length < target) {
				const { session, note } = await createIdleSession(sdk, iso);
				sessions.push(session);
				if (note) notes.add(note);
			}
			const s = await sample();
			rows.push({ label: String(sessions.length), n: sessions.length, ...s, perSession: (s.foot - base.foot) / sessions.length });
		}
	} catch (err) {
		failure = `at N=${sessions.length + 1}: ${String(err?.message ?? err).replace(/\s+/g, " ")}`;
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
	rows.push({ label: "after dispose", n: 0, ...(await sample()), perSession: null });
	iso.cleanup();

	console.log("| N | physical footprint (MB) | per-session cost (MB) = (F_N - F_0) / N | RSS (MB) | available (GB) |");
	console.log("|---|---|---|---|---|");
	for (const r of rows) {
		const per = r.perSession === null ? "-" : mb(r.perSession).toFixed(2);
		console.log(`| ${r.label} | ${mb(r.foot).toFixed(2)} | ${per} | ${mb(r.rssKb * 1024).toFixed(2)} | ${r.availGb} |`);
	}
	console.log(`\nNode ${process.version}, platform ${process.platform}/${process.arch}`);
	console.log(`Model fallback notes (no credentials read): ${[...notes].join(" | ") || "none"}`);
	console.log(failure ? `FAILED ${failure}` : "createAgentSession: no failures");
	process.exit(failure ? 1 : 0);
}

function startChild() {
	return spawn(process.execPath, [CHILD_SCRIPT, "--child"], { stdio: ["pipe", "pipe", "inherit"] });
}

function readyOrFail(child) {
	return new Promise((resolve) => {
		const rl = createInterface({ input: child.stdout });
		rl.once("line", (line) => {
			rl.close();
			resolve(line);
		});
		child.once("exit", (code) => resolve(`EXIT ${code}`));
	});
}

// Ends stdin so each child disposes its session and exits. SIGKILL only after KILL_WAIT_MS.
async function stopAll(children) {
	await Promise.all(
		children.map(async (c) => {
			if (c.exitCode !== null || c.signalCode !== null) return;
			c.stdin.on("error", () => {});
			c.stdin.end();
			const timer = setTimeout(() => c.kill("SIGKILL"), KILL_WAIT_MS);
			await once(c, "exit");
			clearTimeout(timer);
		}),
	);
}

async function guarded() {
	const children = [];
	const rows = [];
	let failure = null;
	const onSignal = async () => {
		await stopAll(children);
		process.exit(130);
	};
	process.once("SIGINT", onSignal);
	process.once("SIGTERM", onSignal);

	try {
		for (const target of GUARDED_STEPS) {
			const row = { requested: target, availBeforeGb: gb(availableBytes()), stoppedEarly: false, stopReason: "" };
			try {
				while (children.length < target) {
					if (children.length >= MAX_PROCESSES) throw new Error(`child cap ${MAX_PROCESSES} reached`);
					const avail = availableBytes();
					if (avail < GUARD_BYTES) {
						row.stoppedEarly = true;
						row.stopReason = `available ${gb(avail)} GB before child ${children.length + 1}, below 2.00 GB`;
						break;
					}
					const child = startChild();
					children.push(child);
					const line = await readyOrFail(child);
					if (line !== "READY") throw new Error(`child ${children.length}: ${line}`);
					await sleep(PAUSE_MS);
				}
				await sleep(SETTLE_MS);
				const pids = children.map((c) => c.pid);
				const footBytes = pids.map(footprintBytes);
				const footTotal = footBytes.reduce((a, b) => a + b, 0);
				const rssKb = totalRssKb(pids);
				Object.assign(row, {
					reached: children.length,
					footTotalMb: mb(footTotal),
					footAvgMb: children.length ? mb(footTotal / children.length) : null,
					rssTotalMb: mb(rssKb * 1024),
					rssAvgMb: children.length ? mb((rssKb * 1024) / children.length) : null,
					availAfterGb: gb(availableBytes()),
				});
			} catch (err) {
				failure = String(err?.message ?? err).replace(/\s+/g, " ");
			}
			rows.push(row);
			if (row.stoppedEarly || failure) break;
		}
	} finally {
		await stopAll(children);
	}

	const leftover = children.filter((c) => isAlive(c.pid)).length;
	const availCleanupGb = gb(availableBytes());

	console.log("| N requested | N reached | footprint total (MB) | footprint avg per child (MB) | RSS total (MB) | RSS avg per child (MB) | available before step (GB) | available after step, children alive (GB) | stopped early |");
	console.log("|---|---|---|---|---|---|---|---|---|");
	for (const r of rows) {
		const stop = r.stoppedEarly ? `yes: ${r.stopReason}` : "no";
		console.log(
			`| ${r.requested} | ${r.reached ?? "-"} | ${r.footTotalMb ?? "-"} | ${r.footAvgMb?.toFixed(2) ?? "-"} | ${r.rssTotalMb ?? "-"} | ${r.rssAvgMb?.toFixed(2) ?? "-"} | ${r.availBeforeGb} | ${r.availAfterGb ?? "-"} | ${stop} |`,
		);
	}
	console.log(`\nAvailable after all children stopped: ${availCleanupGb} GB. Children still alive after stop: ${leftover}. Total started: ${children.length}.`);
	console.log(`Node ${process.version}, platform ${process.platform}/${process.arch}, guard ${gb(GUARD_BYTES)} GB, cap ${MAX_PROCESSES}`);
	console.log(failure ? `FAILED: ${failure}` : "no failures in any child");
	process.exit(failure || leftover ? 1 : 0);
}

const mode = process.argv[2];
if (mode === "in-process") await inProcess();
else if (mode === "guarded") await guarded();
else {
	console.error("usage: node spike/footprint.mjs in-process | guarded");
	process.exit(2);
}
