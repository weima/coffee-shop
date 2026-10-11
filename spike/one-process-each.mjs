// Baseline: one child node process per pi session. The parent sums RSS with ps.
// Run: node spike/one-process-each.mjs
// The same file acts as the child when started with --child (add --bare for a
// plain node process with no SDK, as a reference floor).
import { execFileSync, spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { createIdleSession, isolate, loadSdk, toMb } from "./lib.mjs";

const SELF = fileURLToPath(import.meta.url);
const SETTLE_MS = 1000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function runChild(bare) {
	let iso = null;
	let session = null;
	try {
		if (!bare) {
			iso = isolate();
			const sdk = await loadSdk();
			({ session } = await createIdleSession(sdk, iso));
		}
		process.stdout.write("READY\n");
	} catch (err) {
		process.stdout.write(`ERROR ${String(err?.message ?? err).replace(/\s+/g, " ")}\n`);
		iso?.cleanup();
		process.exit(1);
	}
	// Idle until the parent closes our stdin, then dispose and exit.
	process.stdin.resume();
	await once(process.stdin, "end");
	session?.dispose();
	iso?.cleanup();
	process.exit(0);
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

function rssKb(pid) {
	return Number(execFileSync("ps", ["-o", "rss=", "-p", String(pid)]).toString().trim());
}

async function measureGroup(n, bare) {
	const children = [];
	try {
		for (let i = 0; i < n; i++) {
			const child = spawn(process.execPath, [SELF, "--child", ...(bare ? ["--bare"] : [])], {
				stdio: ["pipe", "pipe", "inherit"],
			});
			children.push(child);
			const line = await readyOrFail(child);
			if (line !== "READY") throw new Error(`child ${i + 1} of ${n}: ${line}`);
		}
		await sleep(SETTLE_MS);
		const kb = children.reduce((sum, c) => sum + rssKb(c.pid), 0);
		return { n, totalMb: toMb(kb * 1024), avgMb: Math.round((kb / n / 1024) * 100) / 100 };
	} finally {
		for (const c of children) {
			if (c.exitCode === null && c.signalCode === null) {
				c.stdin.end();
				await once(c, "exit");
			}
		}
	}
}

async function runParent() {
	const rows = [];
	let failure = null;
	try {
		for (const n of [1, 5, 10]) rows.push({ label: "pi session per process", ...(await measureGroup(n, false)) });
		rows.push({ label: "bare node (reference, no SDK)", ...(await measureGroup(5, true)) });
	} catch (err) {
		failure = String(err?.message ?? err);
	}
	console.log("| case | processes (N) | total RSS (MB) | avg RSS per process (MB) |");
	console.log("|---|---|---|---|");
	for (const r of rows) console.log(`| ${r.label} | ${r.n} | ${r.totalMb} | ${r.avgMb.toFixed(2)} |`);
	console.log(`\nNode ${process.version}, platform ${process.platform}/${process.arch}`);
	console.log(failure ? `FAILED: ${failure}` : "createAgentSession: no failures in any child");
	process.exit(failure ? 1 : 0);
}

if (process.argv.includes("--child")) {
	await runChild(process.argv.includes("--bare"));
} else {
	await runParent();
}
