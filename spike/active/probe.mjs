// Probes shared by active.mjs and per-process.mjs: vm_stat available memory (guard),
// macOS footprint, and process CPU. Async where a sample may run during the window,
// so the probe itself does not block the event loop being measured.
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);
export const PAGE_SIZE = 16384;
export const GUARD_BYTES = 2 * 1024 ** 3;
export const MAX_CHILDREN = 50;
export const gb = (bytes) => Math.round((bytes / 1024 ** 3) * 100) / 100;
export const mb = (bytes) => Math.round((bytes / 1024 / 1024) * 100) / 100;

// Free + inactive pages, in bytes. Inactive pages count as available.
export function parseAvailable(out) {
	const header = out.match(/page size of (\d+) bytes/);
	if (!header || Number(header[1]) !== PAGE_SIZE) throw new Error(`vm_stat page size is ${header?.[1]}, expected ${PAGE_SIZE}`);
	const pages = (label) => {
		const m = out.match(new RegExp(`^${label}:\\s+(\\d+)\\.`, "m"));
		if (!m) throw new Error(`vm_stat has no "${label}" line`);
		return Number(m[1]);
	};
	return (pages("Pages free") + pages("Pages inactive")) * PAGE_SIZE;
}

export function availableBytesSync() {
	return parseAvailable(execFileSync("vm_stat").toString());
}

export async function availableBytes() {
	return parseAvailable((await run("vm_stat")).stdout);
}

// Physical footprint of one process, in bytes (macOS footprint, total line).
export async function footprintBytes(pid) {
	const { stdout } = await run("/usr/bin/footprint", ["-f", "bytes", "-p", String(pid)]);
	const m = stdout.match(/Footprint:\s+(\d+) B\b/);
	if (!m) throw new Error(`footprint for pid ${pid} has no total line`);
	return Number(m[1]);
}

export const cpuMs = (usage) => (usage.user + usage.system) / 1000;
