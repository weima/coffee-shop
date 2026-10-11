// N ACTIVE pi sessions, ONE child node process per session, each running the same
// prompt -> stream -> read -> answer loop for the same window. The parent is guarded:
// vm_stat is read before each child starts, and the run stops below 2.0 GB.
// Run: node spike/active/per-process.mjs <N> [--window-ms 60000]
// Child mode (started by the parent only): node spike/active/per-process.mjs --child --window-ms <ms>
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { monitorEventLoopDelay, performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import { availableBytes, cpuMs, footprintBytes, GUARD_BYTES, gb, MAX_CHILDREN, mb } from "./probe.mjs";
import { createFakeSession, isolateWithFile, loadFakeRuntime, runAgentUntil, scrubEnv, stopAgent, warmUp } from "./fake-provider.mjs";

const SELF = fileURLToPath(import.meta.url);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const args = process.argv.slice(2);
const flagValue = (name, dflt) => {
	const i = args.indexOf(name);
	return i === -1 ? dflt : Number(args[i + 1]);
};
const WINDOW_MS = flagValue("--window-ms", 60000);
const SAMPLE_EVERY_MS = flagValue("--sample-every-ms", 10000);
const PAUSE_MS = 300;
const WARMUP = args.includes("--warmup"); // one untimed turn before READY, as in active.mjs

// ---------- child: one agent in this process ----------
async function runChild() {
	scrubEnv();
	const iso = isolateWithFile();
	let rt;
	let session;
	let stats;
	try {
		rt = await loadFakeRuntime(iso);
		({ session, stats } = await createFakeSession(rt, iso));
	} catch (err) {
		process.stdout.write(`ERROR ${String(err?.message ?? err).replace(/\s+/g, " ")}\n`);
		iso.cleanup();
		process.exit(1);
	}
	if (WARMUP) await warmUp(session, stats);
	// Idle event-loop baseline, then ready.
	const hIdle = monitorEventLoopDelay({ resolution: 1 });
	hIdle.enable();
	await sleep(1000);
	hIdle.disable();
	process.stdout.write(`READY idleP99=${hIdle.percentile(99) / 1e6}\n`);

	const rl = createInterface({ input: process.stdin });
	for await (const line of rl) {
		if (line.trim() !== "GO") continue;
		rl.close();
		// No event-loop histogram here: its 1 ms timer costs CPU in every child. The parent measures its own loop.
		const w0 = performance.now();
		const windowEnd = w0 + WINDOW_MS;
		const cpu0 = process.cpuUsage();
		const loop = runAgentUntil(session, stats, windowEnd).catch((e) => stats.errors.push(String(e?.message ?? e)));
		// Stop the clock at the window end, then abort the in-flight turn (not counted), as active.mjs does.
		await sleep(Math.max(0, windowEnd - performance.now()));
		const cpu1 = process.cpuUsage(cpu0);
		const w1 = performance.now();
		await stopAgent(session, stats);
		await loop;
		const result = {
			turns: stats.turns,
			badTurns: stats.badTurns,
			deltas: stats.deltas,
			errors: stats.errors,
			cpuMs: cpuMs(cpu1),
			wallMs: w1 - w0,
		};
		process.stdout.write(`RESULT ${JSON.stringify(result)}\n`);
		session.dispose();
		iso.cleanup();
		process.exit(0);
	}
	// Parent closed stdin without GO: nothing to do.
	session.dispose();
	iso.cleanup();
	process.exit(0);
}

// ---------- parent ----------
function startChild() {
	const child = spawn(process.execPath, [SELF, "--child", "--window-ms", String(WINDOW_MS), ...(WARMUP ? ["--warmup"] : [])], {
		stdio: ["pipe", "pipe", "inherit"],
	});
	child.lines = [];
	child.waiters = [];
	const rl = createInterface({ input: child.stdout });
	rl.on("line", (line) => {
		child.lines.push(line);
		for (const w of child.waiters.splice(0)) w(line);
	});
	child.exited = new Promise((resolve) => child.once("exit", (code) => resolve(code)));
	// Resolves with the first line that starts with the given prefix.
	child.next = (prefix) =>
		new Promise((resolve) => {
			const found = child.lines.find((l) => l.startsWith(prefix));
			if (found) return resolve(found);
			const check = (line) => {
				if (line.startsWith(prefix)) resolve(line);
				else child.waiters.push(check);
			};
			child.waiters.push(check);
		});
	return child;
}

async function stopChildren(children) {
	await Promise.all(
		children.map(async (c) => {
			if (c.exitCode !== null || c.signalCode !== null) return;
			c.stdin.on("error", () => {});
			c.stdin.end();
			const timer = setTimeout(() => c.kill("SIGKILL"), 5000);
			await c.exited;
			clearTimeout(timer);
		}),
	);
}

const runParent = async () => {
	const N = Number(args[0]);
	if (!Number.isInteger(N) || N < 1 || N > MAX_CHILDREN) {
		console.error(`usage: node spike/active/per-process.mjs <N, 1..${MAX_CHILDREN}> [--window-ms 60000]`);
		process.exit(2);
	}
	const children = [];
	let failure = null;
	let guardStop = null;
	let minAvail = Infinity;
	const parentEl = monitorEventLoopDelay({ resolution: 1 });
	const foot = []; // per sample: total footprint of all children (bytes)
	const onSignal = async () => {
		await stopChildren(children);
		process.exit(130);
	};
	process.once("SIGINT", onSignal);
	process.once("SIGTERM", onSignal);

	try {
		// Start children one at a time. The guard is read before each one.
		for (let i = 0; i < N; i++) {
			const avail = await availableBytes();
			minAvail = Math.min(minAvail, avail);
			if (avail < GUARD_BYTES) {
				guardStop = `available ${gb(avail)} GB before child ${i + 1}, below 2.00 GB`;
				break;
			}
			const child = startChild();
			children.push(child);
			const ready = await Promise.race([child.next("READY"), child.next("ERROR"), child.exited.then(() => "EXIT")]);
			if (!ready.startsWith("READY")) throw new Error(`child ${i + 1} of ${N}: ${ready}`);
			await sleep(PAUSE_MS);
		}
		if (guardStop) throw new Error(`memory guard: ${guardStop}`);
		await sleep(1000); // settle

		// Active window: GO to every child, then sample footprint until the window ends.
		const cpuP0 = process.cpuUsage();
		const pw0 = performance.now();
		parentEl.enable();
		for (const c of children) c.stdin.write("GO\n");
		// Sample only inside the window: children exit at GO + WINDOW_MS, so a sample after that finds no pid.
		const sampleEnd = pw0 + WINDOW_MS - 2000;
		const pids = children.map((c) => c.pid);
		let guardTripped = false;
		while (performance.now() + SAMPLE_EVERY_MS < sampleEnd) {
			await sleep(SAMPLE_EVERY_MS);
			const avail = await availableBytes();
			minAvail = Math.min(minAvail, avail);
			if (avail < GUARD_BYTES) {
				guardStop = `available ${gb(avail)} GB during the window, below 2.00 GB`;
				guardTripped = true;
				break;
			}
			let total = 0;
			for (const pid of pids) total += await footprintBytes(pid);
			foot.push(total);
		}
		if (guardTripped) {
			for (const c of children) c.kill("SIGKILL");
		}
		parentEl.disable();
		const parentCpu = process.cpuUsage(cpuP0);
		const parentWallMs = performance.now() - pw0;

		// Collect each child's RESULT.
		const results = [];
		for (const c of children) {
			const line = await Promise.race([c.next("RESULT"), c.next("ERROR"), c.exited.then(() => "EXIT")]);
			if (line.startsWith("RESULT ")) results.push(JSON.parse(line.slice(7)));
			else if (!guardTripped) throw new Error(`child ${children.indexOf(c) + 1}: ${line}`);
		}
		const turns = results.map((r) => r.turns);
		const sorted = [...turns].sort((a, b) => a - b);
		const childCpuMs = results.reduce((a, r) => a + r.cpuMs, 0);
		const avgWallMs = results.reduce((a, r) => a + r.wallMs, 0) / Math.max(results.length, 1);
		const errors = results.flatMap((r) => r.errors);
		const badTurns = results.reduce((a, r) => a + r.badTurns, 0);
		const idleP99s = children.map((c) => Number(c.lines.find((l) => l.startsWith("READY")).split("=")[1])).sort((a, b) => a - b);
		const peak = foot.length ? Math.max(...foot) : null;
		const summary = {
			mode: "per-process",
			warmup: WARMUP,
			n: N,
			childrenStarted: children.length,
			windowS: Math.round((avgWallMs / 1000) * 10) / 10,
			footprintTotalPeakMb: peak === null ? null : mb(peak),
			footprintTotalSeriesMb: foot.map(mb),
			footprintPerChildPeakMb: peak === null ? null : mb(peak / children.length),
			childCpuPct: Math.round((childCpuMs / avgWallMs) * 1000) / 10, // sum over children, % of one core
			parentCpuPct: Math.round((cpuMs(parentCpu) / parentWallMs) * 1000) / 10,
			parentEvLoopP99Ms: Math.round((parentEl.percentile(99) / 1e6) * 100) / 100,
			parentEvLoopMaxMs: Math.round((parentEl.max / 1e6) * 10) / 10,
			childIdleP99MsMedian: idleP99s.length ? Math.round(idleP99s[Math.floor(idleP99s.length / 2)] * 100) / 100 : null,
			turnsTotal: turns.reduce((a, b) => a + b, 0),
			turnsPerAgent: { min: sorted[0] ?? null, median: sorted[Math.floor(sorted.length / 2)] ?? null, max: sorted.at(-1) ?? null },
			badTurns,
			errorsCount: errors.length,
			errorsSample: errors.slice(0, 3),
			minAvailableGb: minAvail === Infinity ? null : gb(minAvail),
			stoppedByGuard: guardStop,
		};
		console.log(`RESULT ${JSON.stringify(summary)}`);
		console.log(
			`N=${N} children: footprint total peak ${summary.footprintTotalPeakMb} MB, child CPU ${summary.childCpuPct}%, parent ev-loop p99 ${summary.parentEvLoopP99Ms} ms, turns ${summary.turnsTotal} (per agent ${summary.turnsPerAgent.min}-${summary.turnsPerAgent.max}), errors ${summary.errorsCount}`,
		);
		if (guardStop) failure = guardStop;
		if (summary.errorsCount > 0 || badTurns > 0) failure ??= `${summary.errorsCount} errors, ${badTurns} unclean turns`;
	} catch (err) {
		failure = String(err?.message ?? err);
	} finally {
		await stopChildren(children);
	}

	const alive = children.filter((c) => c.exitCode === null && c.signalCode === null).length;
	console.log(`Children still alive after stop: ${alive}. Started in total: ${children.length}.`);
	if (failure) console.log(`FAILED: ${failure}`);
	process.exit(failure || alive ? 1 : 0);
};

if (args.includes("--child")) await runChild();
else await runParent();
