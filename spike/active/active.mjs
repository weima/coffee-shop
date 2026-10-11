// N ACTIVE pi sessions in ONE node process, each running prompt -> stream -> read -> answer
// in a loop for a fixed window. Prints one RESULT line of JSON and a summary.
// Run: node spike/active/active.mjs in-process <N> [--window-ms 60000]
// The fake provider is the only model. The memory guard stops the run below 2.0 GB.
import { monitorEventLoopDelay, performance } from "node:perf_hooks";
import { availableBytes, cpuMs, footprintBytes, GUARD_BYTES, gb, mb } from "./probe.mjs";
import { createFakeSession, isolateWithFile, loadFakeRuntime, runAgentUntil, scrubEnv, stopAgent, warmUp } from "./fake-provider.mjs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const args = process.argv.slice(2);
const mode = args[0];
const N = Number(args[1]);
const flagValue = (name, dflt) => {
	const i = args.indexOf(name);
	return i === -1 ? dflt : Number(args[i + 1]);
};
const WINDOW_MS = flagValue("--window-ms", 60000);
const WARMUP = args.includes("--warmup"); // one untimed turn per agent before the window
const NO_ELD = args.includes("--no-eld"); // skip the event-loop histogram in the window (cost check)
const SAMPLE_EVERY_MS = flagValue("--sample-every-ms", 10000);
const GUARD_EVERY_MS = 2000;

if (mode !== "in-process" || !Number.isInteger(N) || N < 1) {
	console.error("usage: node spike/active/active.mjs in-process <N> [--window-ms 60000]");
	process.exit(2);
}

scrubEnv();
const iso = isolateWithFile();
const rt = await loadFakeRuntime(iso);
const sessions = [];
let stopReason = null; // set by the memory guard
let failure = null;

const guardOrThrow = async (where) => {
	const avail = await availableBytes();
	if (avail < GUARD_BYTES) throw new Error(`memory guard: ${gb(avail)} GB available at ${where}, below 2.00 GB`);
	return avail;
};

try {
	// Idle event-loop baseline: SDK loaded, no session yet.
	const hIdle = monitorEventLoopDelay({ resolution: 1 });
	hIdle.enable();
	await sleep(2000);
	hIdle.disable();
	const idleP99 = hIdle.percentile(99) / 1e6;

	// Create N sessions. Memory is checked before each one.
	const createStart = performance.now();
	let minAvail = Infinity;
	for (let i = 0; i < N; i++) {
		minAvail = Math.min(minAvail, await guardOrThrow(`before session ${i + 1}`));
		sessions.push(await createFakeSession(rt, iso));
	}
	const createMs = Math.round(performance.now() - createStart);
	await sleep(1000);
	const footIdle = await footprintBytes(process.pid);

	if (WARMUP) await Promise.all(sessions.map((s) => warmUp(s.session, s.stats)));

	// Active window. All agents start together.
	const h = monitorEventLoopDelay({ resolution: 1 });
	const windowEnd = performance.now() + WINDOW_MS;
	const cpu0 = process.cpuUsage();
	const w0 = performance.now();
	if (!NO_ELD) h.enable();

	const guardTimer = setInterval(async () => {
		try {
			minAvail = Math.min(minAvail, await guardOrThrow("window"));
		} catch (err) {
			stopReason = String(err.message);
			for (const s of sessions) stopAgent(s.session, s.stats);
		}
	}, GUARD_EVERY_MS);

	const loops = sessions.map((s) => runAgentUntil(s.session, s.stats, windowEnd).catch((e) => s.stats.errors.push(String(e?.message ?? e))));

	// Footprint every SAMPLE_EVERY_MS during the window. The series shows the peak.
	const foot = [];
	while (performance.now() + SAMPLE_EVERY_MS < windowEnd) {
		await sleep(SAMPLE_EVERY_MS);
		foot.push(await footprintBytes(process.pid));
	}
	await sleep(Math.max(0, windowEnd - performance.now()));
	const cpu1 = process.cpuUsage(cpu0);
	const w1 = performance.now();
	h.disable();
	const p99 = h.percentile(99) / 1e6;
	const p50 = h.percentile(50) / 1e6;
	const max = h.max / 1e6;
	clearInterval(guardTimer);

	// Stop: abort in-flight turns (they are not counted) and wait for the loops.
	await Promise.all(sessions.map((s) => stopAgent(s.session, s.stats)));
	await Promise.all(loops);

	const turns = sessions.map((s) => s.stats.turns);
	const sorted = [...turns].sort((a, b) => a - b);
	const errors = sessions.flatMap((s) => s.stats.errors);
	const result = {
		mode: "in-process",
		warmup: WARMUP,
		eld: !NO_ELD,
		n: N,
		windowS: Math.round((w1 - w0) / 100) / 10,
		footprintIdleMb: mb(footIdle),
		footprintPeakMb: foot.length ? mb(Math.max(...foot)) : null,
		footprintSeriesMb: foot.map(mb),
		cpuPct: Math.round((cpuMs(cpu1) / (w1 - w0)) * 1000) / 10,
		evLoopIdleP99Ms: Math.round(idleP99 * 100) / 100,
		evLoopP50Ms: NO_ELD ? null : Math.round(p50 * 100) / 100,
		evLoopP99Ms: NO_ELD ? null : Math.round(p99 * 100) / 100,
		evLoopMaxMs: NO_ELD ? null : Math.round(max * 10) / 10,
		turnsTotal: turns.reduce((a, b) => a + b, 0),
		turnsPerAgent: { min: sorted[0], median: sorted[Math.floor(sorted.length / 2)], max: sorted.at(-1) },
		deltasTotal: sessions.reduce((a, s) => a + s.stats.deltas, 0),
		badTurns: sessions.reduce((a, s) => a + s.stats.badTurns, 0),
		createMs,
		minAvailableGb: gb(minAvail),
		errorsCount: errors.length,
		errorsSample: errors.slice(0, 3),
		stoppedByGuard: stopReason,
	};
	console.log(`RESULT ${JSON.stringify(result)}`);
	console.log(`N=${N}: footprint peak ${result.footprintPeakMb} MB (series ${result.footprintSeriesMb.join(", ")}), CPU ${result.cpuPct}%, ev-loop p99 ${NO_ELD ? "not measured" : result.evLoopP99Ms + " ms"} (idle ${result.evLoopIdleP99Ms} ms), turns ${result.turnsTotal} (per agent ${result.turnsPerAgent.min}-${result.turnsPerAgent.max}), errors ${result.errorsCount}`);
	if (stopReason) failure = stopReason;
	if (result.errorsCount > 0 || result.badTurns > 0) failure ??= `${result.errorsCount} errors, ${result.badTurns} unclean turns`;
} catch (err) {
	failure = String(err?.message ?? err);
} finally {
	for (const s of sessions) {
		try {
			s.session.dispose();
		} catch (err) {
			console.error("dispose failed:", err?.message ?? err);
		}
	}
	sessions.length = 0;
	iso.cleanup();
}

if (failure) console.log(`FAILED: ${failure}`);
process.exit(failure ? 1 : 0);
