// The Pi-facing Barista bridge. It starts the foreground Go host on demand,
// sends explicit dispatch requests over stdin, and relays host events to Pi.

import { spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
import { dirname, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const MAX_LINE_BYTES = 1 << 20;
const HOST_READY_TIMEOUT_MS = 60_000;
const DISPATCH_TIMEOUT_MS = 30_000;
const TERMINAL_REPORTS = new Set(["pulled", "taste_failed", "incomplete", "session_failed"]);

interface HostEvent {
	type?: string;
	request_id?: string;
	shot_id?: string;
	kind?: string;
	description?: string;
	reason?: string;
}

interface PendingDispatch {
	resolve: () => void;
	reject: (error: Error) => void;
}

const ShotSchema = Type.Object({
	id: Type.String({ pattern: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$" }),
	prompt: Type.String({ minLength: 1 }),
	model: Type.Optional(Type.String({ maxLength: 80 })),
	kind: Type.Optional(Type.Union([Type.Literal("execute"), Type.Literal("research")])),
	taste: Type.Optional(Type.String()),
	message: Type.Optional(Type.String({ maxLength: 200 })),
	codemode: Type.Optional(Type.Boolean()),
}, { additionalProperties: false });

const DispatchSchema = Type.Object({
	repo: Type.String({ minLength: 1 }),
	shots: Type.Array(ShotSchema, { minItems: 1 }),
}, { additionalProperties: false });

export default function coffeeShopBarista(pi: ExtensionAPI): void {
	let context: ExtensionContext | undefined;
	let child: ChildProcess | undefined;
	let ready: Promise<void> | undefined;
	let readyResolve: (() => void) | undefined;
	let readyReject: ((error: Error) => void) | undefined;
	let hostReady = false;
	const pending = new Map<string, PendingDispatch>();

	function notify(message: string, type: "info" | "warning" | "error" = "info"): void {
		if (context?.hasUI) context.ui.notify(`[coffee-shop] ${message}`, type);
	}

	function writeLine(message: unknown): void {
		if (!child?.stdin?.writable) throw new Error("Coffee Shop host is not accepting requests");
		child.stdin.write(`${JSON.stringify(message)}\n`);
	}

	function handleLine(line: string): void {
		let event: HostEvent;
		try {
			event = JSON.parse(line) as HostEvent;
		} catch {
			if (hostReady) notify("ignored an invalid host event", "warning");
			return;
		}

		if (event.type === "ready") {
			hostReady = true;
			readyResolve?.();
			readyResolve = undefined;
			readyReject = undefined;
			return;
		}

		const requestId = event.request_id ?? "";
		if (event.type === "dispatch_accepted") {
			pending.get(requestId)?.resolve();
			return;
		}
		if (event.type === "error" && requestId) {
			pending.get(requestId)?.reject(new Error(event.reason ?? "host rejected the dispatch"));
			notify(`${requestId}: ${event.reason ?? "host error"}`, "error");
			return;
		}

		if (event.type === "session_started") {
			notify(`${requestId}/${event.shot_id}: Station started`);
		} else if (event.type === "session_failed") {
			notify(`${requestId}/${event.shot_id}: could not start — ${event.reason ?? "unknown reason"}`, "error");
		} else if (event.type === "station_report") {
			const terminal = TERMINAL_REPORTS.has(event.kind ?? "");
			const severity = event.kind === "taste_failed" || event.kind === "incomplete" || event.kind === "session_failed" ? "warning" : "info";
			notify(`${requestId}/${event.shot_id}: ${event.kind ?? "report"}${terminal ? " (finished)" : ""}${event.description ? ` — ${event.description}` : ""}`, severity);
		} else if (event.type === "warning" || event.type === "stale_warning") {
			notify(`${requestId}/${event.shot_id ?? ""}: ${event.reason ?? event.type}`, "warning");
		}
	}

	function ensureHost(): Promise<void> {
		if (child && ready) return ready;
		ready = new Promise<void>((resolve, reject) => {
			readyResolve = resolve;
			readyReject = reject;
		});
		void ready.catch(() => {});

		try {
			const running = spawn("just", ["host-go"], {
				cwd: ROOT,
				stdio: ["pipe", "pipe", "pipe"],
				detached: process.platform !== "win32",
			});
			child = running;
			const lines = createInterface({ input: running.stdout! });
			lines.on("line", handleLine);
			running.stderr?.on("data", (chunk: Buffer) => process.stderr.write(chunk));
			running.once("error", (error) => {
				readyReject?.(error);
				readyReject = undefined;
				readyResolve = undefined;
				notify(`could not start the host: ${error.message}`, "error");
			});
			running.once("exit", (code, signal) => {
				const error = new Error(`Coffee Shop host exited (${signal ?? code})`);
				readyReject?.(error);
				readyReject = undefined;
				readyResolve = undefined;
				for (const request of pending.values()) request.reject(error);
				pending.clear();
				if (child === running) {
					child = undefined;
					ready = undefined;
					hostReady = false;
				}
			});
		} catch (error) {
			readyReject?.(asError(error));
			readyReject = undefined;
			readyResolve = undefined;
		}

		return withTimeout(ready, HOST_READY_TIMEOUT_MS, "Coffee Shop host did not become ready").catch(async (error: unknown) => {
			await stopHost();
			throw error;
		});
	}

	async function stopHost(): Promise<void> {
		const running = child;
		if (!running) return;
		const closed = running.exitCode !== null || running.signalCode !== null
			? Promise.resolve()
			: new Promise<void>((resolve) => running.once("close", () => resolve()));
		try {
			writeLine({ type: "shutdown", request_id: "barista-shutdown" });
			await withTimeout(closed, 2_000, "host shutdown timed out");
		} catch {
			try {
				if (running.pid && process.platform !== "win32") process.kill(-running.pid, "SIGTERM");
				else running.kill("SIGTERM");
			} catch {
				// The child may have exited between the timeout and the signal.
			}
			try {
				await withTimeout(closed, 1_000, "host did not stop after SIGTERM");
			} catch {
				try {
					if (running.pid && process.platform !== "win32") process.kill(-running.pid, "SIGKILL");
					else running.kill("SIGKILL");
				} catch {
					// The child may have exited between the timeout and the signal.
				}
			}
		}
		if (child === running) child = undefined;
		ready = undefined;
		hostReady = false;
	}

	pi.on("session_start", (_event, ctx) => { context = ctx; });
	pi.on("session_shutdown", async () => { await stopHost(); });

	pi.registerTool({
		name: "coffee_shop_dispatch",
		label: "Dispatch Coffee Shop Shots",
		description: "Send an explicit, user-approved recipe to the Coffee Shop host. The Barista plans the Shots; Coffee Shop only runs them in isolated worktrees.",
		parameters: DispatchSchema,
		executionMode: "sequential",
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			if (!ctx.hasUI) return toolError("Dispatch requires an interactive Pi session so the user can approve the recipe.");
			if (!isAbsolute(params.repo)) return toolError("repo must be an absolute path");
			if (params.shots.some((shot) => shot.taste && ((shot.kind ?? "execute") !== "execute" || !shot.message?.trim()))) {
				return toolError("a Taste requires an execute Shot and a non-empty one-line message");
			}
			if (params.shots.some((shot) => shot.message && /[\r\n]/.test(shot.message))) {
				return toolError("Taste messages must be one line");
			}
			if (new Set(params.shots.map((shot) => shot.id)).size !== params.shots.length) {
				return toolError("Shot ids must be unique within a dispatch");
			}

			const summary = [
				`Repository: ${params.repo}`,
				...params.shots.map((shot) => {
					const preview = shot.prompt.replace(/\s+/g, " ").trim();
					const lines = [`${shot.id} (${shot.kind ?? "execute"})`, `  ${preview.slice(0, 300)}${preview.length > 300 ? "…" : ""}`];
					if (shot.taste) lines.push(`  Taste: ${shot.taste}`);
					return lines.join("\n");
				}),
				"No automatic merge or integration will occur.",
			].join("\n\n");
			if (!(await ctx.ui.confirm("Approve Coffee Shop dispatch?", summary))) {
				return { content: [{ type: "text", text: "Dispatch cancelled by the user." }], details: { cancelled: true } };
			}

			const requestId = `barista_${randomUUID().replaceAll("-", "")}`;
			const request = { type: "dispatch", request_id: requestId, repo: params.repo, recipe: { shots: params.shots } };
			const line = `${JSON.stringify(request)}\n`;
			if (Buffer.byteLength(line) > MAX_LINE_BYTES) return toolError("The dispatch exceeds the host's 1 MiB request limit.");
			if (signal?.aborted) return toolError("Dispatch cancelled before it was sent.");

			try {
				await ensureHost();
				if (signal?.aborted) return toolError("Dispatch cancelled before it was sent.");
				const accepted = new Promise<void>((resolve, reject) => pending.set(requestId, { resolve, reject }));
				const cancel = () => {
					try { writeLine({ type: "cancel", request_id: requestId }); } catch { /* host already exited */ }
					pending.get(requestId)?.reject(new Error("Dispatch cancelled."));
				};
				signal?.addEventListener("abort", cancel, { once: true });
				try {
					writeLine(request);
					await withTimeout(accepted, DISPATCH_TIMEOUT_MS, "host did not acknowledge the dispatch");
				} finally {
					signal?.removeEventListener("abort", cancel);
					pending.delete(requestId);
				}
				return {
					content: [{ type: "text", text: `Accepted ${params.shots.length} Shot(s) as ${requestId}. Use Coffee Shop status/log to inspect progress; host reports also appear as Pi notifications.` }],
					details: { request_id: requestId, shots: params.shots.map((shot) => shot.id) },
				};
			} catch (error) {
				return toolError(asError(error).message);
			}
		},
	});
}

function toolError(message: string) {
	return { content: [{ type: "text" as const, text: `Coffee Shop dispatch failed: ${message}` }], details: { error: message } };
}

function asError(error: unknown): Error {
	return error instanceof Error ? error : new Error(String(error));
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
	return new Promise<T>((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(message)), timeoutMs);
		promise.then(resolve, reject).finally(() => clearTimeout(timer));
	});
}
