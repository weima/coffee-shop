// Shared helpers for the spike.
// Each process gets a fresh temp HOME, agent dir and cwd, so no user config,
// no credential file (auth.json) and no project resources are read.
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export const SDK_ENTRY =
	process.env.PI_SDK_ENTRY ??
	"/Users/weima/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/dist/index.js";

export function isolate() {
	const root = mkdtempSync(join(tmpdir(), "oreo-spike-"));
	const home = join(root, "home");
	const agentDir = join(home, ".pi", "agent");
	const cwd = join(root, "work");
	mkdirSync(agentDir, { recursive: true });
	mkdirSync(cwd, { recursive: true });
	process.env.HOME = home; // set before the SDK is loaded and used
	return { root, agentDir, cwd, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

export async function loadSdk() {
	return import(pathToFileURL(SDK_ENTRY).href);
}

// Creates one idle session. No prompt() is ever called: no model request.
export async function createIdleSession(sdk, iso) {
	const { session, modelFallbackMessage } = await sdk.createAgentSession({
		cwd: iso.cwd,
		agentDir: iso.agentDir,
		sessionManager: sdk.SessionManager.inMemory(iso.cwd),
	});
	return { session, note: modelFallbackMessage };
}

export const toMb = (bytes) => Math.round((bytes / 1024 / 1024) * 10) / 10;
