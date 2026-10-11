// Guarded baseline: one child process per pi session, N = 25 then N = 50.
// Run: node spike/baseline-guarded.mjs
// Before each child starts, free + inactive memory is read with vm_stat. If it
// is below 2.0 GiB, no more children start and the children already started are
// stopped. Children are the --child mode of one-process-each.mjs, so they use the
// same isolated HOME, in-memory sessions and no credential files.
import { execFileSync, spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { once } from "node:events";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { toMb } from "./lib.mjs";

const CHILD_SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "one-process-each.mjs");
const STEPS = [25, 50];
const MAX_PROCESSES = 50;
const GUARD_BYTES = 2 * 1024 ** 3;
const PAGE_SIZE = 16384;
const PAUSE_MS = 300;
const SETTLE_MS = 1000;
const AFTER_STOP_MS = 500;
const KILL_WAIT_MS = 5000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const toGb = (bytes) => Math.round((bytes / 1024 ** 3) * 100) / 100;

const live = new Set();

// Free + inactive pages, in bytes. Inactive pages are counted as available.
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

function startChild() {
	const child = spawn(process.execPath, [CHILD_SCRIPT, "--child"], { stdio: ["pipe", "pipe", "inherit"] });
	live.add(child);
	child.once("exit", () => live.delete(child));
	return child;
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

// Ends stdin so each child disposes its session and removes its temp HOME.
// Sends SIGKILL only if a child is still alive after KILL_WAIT_MS.
async function stopAll(children) {
	await Promise.all(
		children.map(async (c) => {
			if (c.exitCode !== null || c.signalCode !== null) return;
			c.stdin.end();
			const timer = setTimeout(() => c.kill("SIGKILL"), KILL_WAIT_MS);
			await once(c, "exit");
			clearTimeout(timer);
		}),
	);
}

for (const sig of ["SIGINT", "SIGTERM"]) {
	process.on(sig, async () => {
		await stopAll([...live]);
		process.exit(130);
	});
}

async function runStep(n) {
	if (n > MAX_PROCESSES) throw new Error(`N=${n} exceeds the cap of ${MAX_PROCESSES}`);
	const row = { requested: n, reached: 0, stoppedEarly: false, stopReason: "", error: null };
	row.availBeforeGb = toGb(availableBytes());
	const children = [];
	try {
		for (let i = 0; i < n; i++) {
			const avail = availableBytes();
			if (avail < GUARD_BYTES) {
				row.stoppedEarly = true;
				row.stopReason = `available ${toGb(avail)} GB before child ${i + 1}, below 2.00 GB`;
				break;
			}
			const child = startChild();
			children.push(child);
			const line = await readyOrFail(child);
			if (line !== "READY") throw new Error(`child ${i + 1} of ${n}: ${line}`);
			row.reached = children.length;
			await sleep(PAUSE_MS);
		}
		await sleep(SETTLE_MS);
		const kb = totalRssKb(children.map((c) => c.pid));
		row.totalMb = toMb(kb * 1024);
		row.avgMb = row.reached ? Math.round((kb / row.reached / 1024) * 100) / 100 : null;
		row.availPeakGb = toGb(availableBytes());
	} catch (err) {
		row.error = String(err?.message ?? err);
	} finally {
		await stopAll(children);
	}
	await sleep(AFTER_STOP_MS);
	row.availAfterGb = toGb(availableBytes());
	return row;
}

const rows = [];
let failure = null;
try {
	for (const n of STEPS) {
		const row = await runStep(n);
		rows.push(row);
		if (row.error) {
			failure = row.error;
			break;
		}
	}
} finally {
	await stopAll([...live]);
}

console.log("| N requested | N reached | total RSS (MB) | avg RSS per process (MB) | available before (GB) | available at peak (GB) | available after cleanup (GB) | stopped early |");
console.log("|---|---|---|---|---|---|---|---|");
for (const r of rows) {
	const stop = r.stoppedEarly ? `yes: ${r.stopReason}` : "no";
	console.log(
		`| ${r.requested} | ${r.reached} | ${r.totalMb ?? "-"} | ${r.avgMb?.toFixed(2) ?? "-"} | ${r.availBeforeGb} | ${r.availPeakGb ?? "-"} | ${r.availAfterGb} | ${stop} |`,
	);
}
console.log(`\nNode ${process.version}, platform ${process.platform}/${process.arch}, guard ${toGb(GUARD_BYTES)} GB`);
console.log(failure ? `FAILED: ${failure}` : "no failures in any child");
process.exit(failure ? 1 : 0);
