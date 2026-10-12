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
				// needs_input asks the user for something; the rest is progress.
				report(message.message, message.kind === "needs_input" ? "warning" : "info");
				return;
			case "error":
				report(tokenFree(message.reason), "error");
				return;
			case "ready":
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
		const hostPath = process.env.OREO_HOST ?? "oreo/bin/oreo-host";
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
			report(`could not start the Oreo host at ${hostPath}: ${tokenFree(errorReason(error))}`, "error");
		});
		running.on("exit", (code, signal) => {
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
		await new Promise<void>((resolve) => {
			if (running.exitCode !== null || running.signalCode !== null) {
				resolve();
				return;
			}
			const timer = setTimeout(() => {
				running.kill();
				resolve();
			}, 2000);
			running.once("close", () => {
				clearTimeout(timer);
				resolve();
			});
		});
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

	pi.on("session_shutdown", async () => {
		await stopHost();
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
