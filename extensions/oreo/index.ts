// The pi-facing half of the Oreo bridge. It owns one long-lived Odin host
// process per session, answers the host's model requests through pi's model
// layer, and relays host events to the pi UI. The protocol and type mapping
// live in ./protocol.ts so they stay testable without pi.
//
// The host never sees credentials: it sends provider and model names, and pi
// authenticates at request time inside this process. Request bodies are never
// logged, and error reasons are stripped of obvious tokens.

import { type ChildProcess, spawn } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	type ModelErrorMessage,
	type ModelRequestMessage,
	type ModelResponseMessage,
	frameLines,
	modelError,
	parseMessage,
	serializeMessage,
	toModelResponse,
	toPiContext,
	toThinkingLevel,
} from "./protocol.ts";

export default function oreoBridge(pi: ExtensionAPI): void {
	let context: ExtensionContext | undefined;
	let child: ChildProcess | undefined;
	let pending = "";
	let stopping = false;
	let readyResolve: (() => void) | undefined;
	let readyReject: ((error: Error) => void) | undefined;
	let readyPromise: Promise<void> | undefined;
	let workResolve: ((result: string) => void) | undefined;
	let workReject: ((error: Error) => void) | undefined;
	let activeSession = "";

	function writeLine(message: unknown): void {
		try {
			child?.stdin?.write(serializeMessage(message));
		} catch (error) {
			report(`could not write to the Oreo host: ${tokenFree(errorReason(error))}`, "error");
		}
	}

	function report(message: string, type: "info" | "warning" | "error" = "info"): void {
		context?.ui.notify(`[oreo] ${message}`, type);
	}

	async function answerModelRequest(request: ModelRequestMessage): Promise<void> {
		const requestId = request.request_id;
		let replied = false;
		// Every path below, including an unexpected throw, replies exactly once.
		// A missing reply would hang one of the host's worker threads forever.
		const reply = (message: ModelResponseMessage | ModelErrorMessage): void => {
			if (replied) {
				return;
			}
			replied = true;
			writeLine(message);
		};

		try {
			if (!context) {
				reply(modelError(requestId, "the oreo bridge has no pi session context"));
				return;
			}
			const model = context.modelRegistry.find(request.provider, request.model);
			if (!model) {
				reply(modelError(requestId, `unknown model ${request.provider}/${request.model} in pi`));
				return;
			}
			if (!context.modelRegistry.hasConfiguredAuth(model)) {
				reply(modelError(requestId, `not logged in to provider ${request.provider} in pi`));
				return;
			}

			const { messages, tools } = toPiContext(request);
			const assistant = await context.modelRegistry.complete(
				model,
				{ messages, tools },
				{ reasoning: toThinkingLevel(request.thinking), signal: context.signal },
			);
			if (assistant.stopReason === "error") {
				reply(modelError(requestId, tokenFree(assistant.errorMessage ?? "the provider returned an error")));
				return;
			}
			reply(toModelResponse(requestId, assistant));
		} catch (error) {
			reply(modelError(requestId, tokenFree(errorReason(error))));
		}
	}

	async function handleLine(line: string): Promise<void> {
		const message = parseMessage(line);
		if (!message) {
			return;
		}
		switch (message.type) {
			case "model_request":
				await answerModelRequest(message);
				return;
			case "event":
				if (message.kind === "final_result" && message.session_id === activeSession) {
					workResolve?.(message.message);
					workResolve = undefined;
					workReject = undefined;
					return;
				}
				if (message.session_id === activeSession && message.kind === "needs_input") {
					workReject?.(new Error("Oreo requested human input; one-shot execution cannot continue"));
					workResolve = undefined;
					workReject = undefined;
					return;
				}
				if (message.kind !== "progress") {
					report(message.message, message.kind === "needs_input" ? "warning" : "info");
				}
				return;
			case "error":
				if (workReject) {
					workReject(new Error(tokenFree(message.reason)));
					workResolve = undefined;
					workReject = undefined;
				} else {
					readyReject?.(new Error(tokenFree(message.reason)));
				}
				report(tokenFree(message.reason), "error");
				return;
			case "ready":
				readyResolve?.();
				readyResolve = undefined;
				readyReject = undefined;
				return;
			case "accepted":
			case "closed":
			case "stopped":
				return;
		}
	}

	function handleChunk(chunk: string): void {
		pending += chunk;
		const { lines, rest } = frameLines(pending);
		pending = rest;
		for (const line of lines) {
			void handleLine(line);
		}
	}

	function startHost(ctx: ExtensionContext): void {
		const hostPath = process.env.OREO_HOST ?? "oreo/bin/oreo-host.bin";
		readyPromise = new Promise<void>((resolve, reject) => {
			readyResolve = resolve;
			readyReject = reject;
		});
		void readyPromise.catch(() => {});
		let running: ChildProcess;
		try {
			running = spawn(hostPath, [], { cwd: ctx.cwd, stdio: ["pipe", "pipe", "pipe"] });
		} catch (error) {
			report(`could not start the Oreo host at ${hostPath}: ${tokenFree(errorReason(error))}`, "error");
			return;
		}
		child = running;
		stopping = false;

		running.stdout?.setEncoding("utf8");
		running.stdout?.on("data", (chunk: string) => handleChunk(chunk));
		// Host stderr is pi's log, never protocol.
		running.stderr?.setEncoding("utf8");
		running.stderr?.on("data", (chunk: string) => process.stderr.write(chunk));
		running.on("error", (error) => {
			readyReject?.(error);
			workReject?.(error);
			workResolve = undefined;
			workReject = undefined;
			readyResolve = undefined;
			readyReject = undefined;
			report(`could not start the Oreo host at ${hostPath}: ${tokenFree(errorReason(error))}`, "error");
		});
		running.on("exit", (code, signal) => {
			const exitError = new Error(`Oreo host exited (${signal ?? code})`);
			readyReject?.(exitError);
			workReject?.(exitError);
			workResolve = undefined;
			workReject = undefined;
			readyResolve = undefined;
			readyReject = undefined;
			if (child === running) {
				child = undefined;
			}
			if (!stopping) {
				report(`the Oreo host exited unexpectedly (${signal ?? code}).`, "error");
			}
		});
	}

	// Send quit, wait up to 2 s for the host to stop, then kill it.
	async function stopHost(): Promise<void> {
		const running = child;
		if (!running) {
			return;
		}
		stopping = true;
		writeLine({ type: "quit" });
		const closed = running.exitCode !== null || running.signalCode !== null
			? Promise.resolve()
			: new Promise<void>((resolve) => running.once("close", () => resolve()));
		try {
			await withTimeout(closed, STOP_TIMEOUT_MS);
		} catch {
			running.kill("SIGKILL");
			try {
				await withTimeout(closed, 1_000);
			} catch {
				report("could not confirm the Oreo host exited", "error");
			}
		}
		if (child === running) {
			child = undefined;
		}
	}

	pi.on("session_start", (_event, ctx) => {
		context = ctx;
		if (!child) {
			startHost(ctx);
		}
	});

	let submitted = false;
	pi.on("input", async (event, ctx) => {
		const provider = process.env.OREO_PROVIDER ?? "";
		if (submitted) {
			return { action: "handled" };
		}
		submitted = true;
		const model = process.env.OREO_MODEL ?? "";
		const thinking = process.env.OREO_THINKING ?? "";
		try {
			const result = await runOreoSubmission({
				submit: async (request, signal) => {
					await withTimeout(readyPromise ?? Promise.reject(new Error("Oreo host did not start")), READY_TIMEOUT_MS);
					activeSession = request.session_id;
					return new Promise<string>((resolve, reject) => {
						workResolve = resolve;
						workReject = reject;
						signal.addEventListener("abort", () => reject(new Error("Oreo work cancelled")), { once: true });
						writeLine({ type: "submit", ...request });
					});
				},
				closeSession: async (sessionId) => {
					if (child) writeLine({ type: "close_session", session_id: sessionId });
				},
				quit: stopHost,
			}, process.env.OREO_SESSION_ID ?? "shot", event.text, `${provider}/${model}`, thinking, ctx.signal);
			emitRpcResult(result);
		} catch (error) {
			const cancelled = ctx.signal?.aborted ?? false;
			process.exitCode = cancelled ? 130 : 1;
			emitRpcResult(cancelled ? "Oreo work cancelled" : `Oreo work failed: ${tokenFree(errorReason(error))}`);
		} finally {
			ctx.shutdown();
		}
		return { action: "handled" };
	});

	pi.on("session_shutdown", async () => {
		await stopHost();
	});
}

export interface OreoSubmissionRequest {
	session_id: string;
	prompt: string;
	provider: string;
	model: string;
	thinking: string;
}

export interface OreoSubmissionHost {
	submit(request: OreoSubmissionRequest, signal: AbortSignal): Promise<string>;
	closeSession(sessionId: string): Promise<void>;
	quit(): Promise<void>;
}

const READY_TIMEOUT_MS = 5_000;
const WORK_TIMEOUT_MS = 30 * 60 * 1_000;
const STOP_TIMEOUT_MS = 2_000;

export function validateOreoRoute(route: string): { provider: string; model: string } {
	const parts = route.split("/");
	if (parts.length !== 2 || !/^[A-Za-z0-9._:-]{1,80}$/.test(parts[0]) || !/^[A-Za-z0-9._:-]{1,80}$/.test(parts[1])) {
		throw new Error("Oreo model route must be a provider/model pair");
	}
	return { provider: parts[0], model: parts[1] };
}

export async function runOreoSubmission(
	host: OreoSubmissionHost,
	sessionId: string,
	prompt: string,
	route: string,
	thinking: string,
	externalSignal?: AbortSignal,
): Promise<string> {
	const { provider, model } = validateOreoRoute(route);
	if (!sessionId || !prompt || !["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(thinking)) {
		throw new Error("Oreo submission needs a session, task, and valid explicit thinking level");
	}
	const controller = new AbortController();
	let rejectAbort!: (error: Error) => void;
	const aborted = new Promise<never>((_, reject) => { rejectAbort = reject; });
	const cancel = () => {
		controller.abort();
		rejectAbort(new Error(externalSignal?.aborted ? "Oreo work cancelled" : "Oreo work timed out"));
	};
	const timer = setTimeout(cancel, WORK_TIMEOUT_MS);
	externalSignal?.addEventListener("abort", cancel, { once: true });
	if (externalSignal?.aborted) cancel();
	let succeeded = false;
	try {
		if (controller.signal.aborted) throw new Error(externalSignal?.aborted ? "Oreo work cancelled" : "Oreo work timed out");
		const result = await Promise.race([
			host.submit({ session_id: sessionId, prompt, provider, model, thinking }, controller.signal),
			aborted,
		]);
		succeeded = true;
		return result;
	} finally {
		clearTimeout(timer);
		externalSignal?.removeEventListener("abort", cancel);
		try {
			await withTimeout(host.closeSession(sessionId), STOP_TIMEOUT_MS);
		} catch {
			// quit still gets a chance to cancel the host's active work.
		}
		try {
			await withTimeout(host.quit(), STOP_TIMEOUT_MS);
		} catch {
			// The extension's process owner kills the host if graceful quit times out.
		}
		if (!succeeded) controller.abort();
	}
}

export function stationRpcResult(text: string) {
	return { type: "agent_end", messages: [{ role: "assistant", content: [{ type: "text", text }] }] };
}

function emitRpcResult(text: string): void {
	process.stdout.write(`${JSON.stringify(stationRpcResult(text))}\n`);
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
	return new Promise<T>((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error("Oreo operation timed out")), timeoutMs);
		promise.then(resolve, reject).finally(() => clearTimeout(timer));
	});
}

function errorReason(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

// Reasons travel back over the pipe, so strip obvious credentials before they do.
function tokenFree(reason: string): string {
	return reason
		.replace(/Bearer\s+[A-Za-z0-9._~+/-]+=*/gi, "Bearer [redacted]")
		.replace(/\b(?:sk|pk|ghp|gho|ghu|ghs|xox[baprs])-[A-Za-z0-9_-]{8,}/g, "[redacted]");
}
