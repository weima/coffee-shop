// Fake provider and the per-agent scenario, shared by active.mjs and per-process.mjs.
// No network, no real model, no credential file. The provider is registered on an
// isolated ModelRuntime, and the session is created with that model. If the fake
// model is missing or the session does not use it, createFakeSession() throws, so
// nothing falls back to a real provider.
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { isolate, loadSdk, SDK_ENTRY } from "../lib.mjs";

// pi-ai is a sibling package of the SDK: .../@earendil-works/pi-ai/dist/index.js
export const PI_AI_ENTRY = process.env.PI_AI_ENTRY ?? join(dirname(SDK_ENTRY), "../../pi-ai/dist/index.js");

export const FAKE_PROVIDER = "fake";
export const FAKE_API = "fake-stream";
export const FAKE_MODEL_ID = "fake-stream-1";
export const PREAMBLE_TOKENS = 20; // text before the read call
export const ANSWER_TOKENS = 180; // final answer; 20 + 180 = about 200 streamed tokens per turn
export const TOKEN_MS = 10; // one token every 10 ms, about 100 tokens/s
export const READ_FILE = "notes.txt";

// Keep the environment free of API keys, so no real provider can be authenticated.
// Also turn off every network-touching pi feature.
export function scrubEnv() {
	for (const key of Object.keys(process.env)) {
		if (/API_KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL/i.test(key)) delete process.env[key];
	}
	process.env.PI_OFFLINE = "1";
	process.env.PI_SKIP_VERSION_CHECK = "1";
	process.env.PI_TELEMETRY = "0";
}

// The isolated temp root for one process, with the read file in its cwd.
export function isolateWithFile() {
	const iso = isolate();
	writeFileSync(
		join(iso.cwd, READ_FILE),
		"Spike notes. The fake provider reads this file once per turn.\nLine two.\nLine three.\n",
	);
	return iso;
}

const zeroUsage = () => ({
	input: 0,
	output: 0,
	cacheRead: 0,
	cacheWrite: 0,
	totalTokens: 0,
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
});

const delay = (ms, signal) =>
	new Promise((resolve) => {
		const t = setTimeout(() => {
			signal?.removeEventListener("abort", onAbort);
			resolve();
		}, ms);
		const onAbort = () => {
			clearTimeout(t);
			resolve();
		};
		signal?.addEventListener("abort", onAbort, { once: true });
	});

// Streams one canned assistant message. Turn shape:
//   no tool result yet  -> preamble text, one read tool call, stop reason toolUse
//   tool result present -> final answer text, stop reason stop
function fakeStreamSimple(ai, model, context, options) {
	const stream = ai.createAssistantMessageEventStream();
	const afterTool = context.messages.at(-1)?.role === "toolResult";
	const signal = options?.signal;
	const message = {
		role: "assistant",
		content: [],
		api: model.api,
		provider: model.provider,
		model: model.id,
		usage: zeroUsage(),
		stopReason: "pending",
		timestamp: Date.now(),
	};

	const fail = (reason) => {
		message.stopReason = reason;
		message.errorMessage = reason === "aborted" ? "aborted by the spike" : "fake provider failure";
		stream.push({ type: "error", reason, error: message });
	};

	(async () => {
		stream.push({ type: "start", partial: message });
		const textTokens = afterTool ? ANSWER_TOKENS : PREAMBLE_TOKENS;
		message.content.push({ type: "text", text: "" });
		stream.push({ type: "text_start", contentIndex: 0, partial: message });
		for (let i = 0; i < textTokens; i++) {
			if (signal?.aborted) return fail("aborted");
			await delay(TOKEN_MS, signal);
			if (signal?.aborted) return fail("aborted");
			const delta = `tok${i} `;
			message.content[0].text += delta;
			stream.push({ type: "text_delta", contentIndex: 0, delta, partial: message });
		}
		stream.push({ type: "text_end", contentIndex: 0, content: message.content[0].text, partial: message });
		message.usage.output = textTokens;
		message.usage.totalTokens = textTokens;

		if (!afterTool) {
			const call = { type: "toolCall", id: `call_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`, name: "read", arguments: { path: READ_FILE } };
			message.content.push(call);
			const idx = message.content.length - 1;
			stream.push({ type: "toolcall_start", contentIndex: idx, partial: message });
			stream.push({ type: "toolcall_delta", contentIndex: idx, delta: JSON.stringify(call.arguments), partial: message });
			stream.push({ type: "toolcall_end", contentIndex: idx, toolCall: call, partial: message });
			message.stopReason = "toolUse";
			stream.push({ type: "done", reason: "toolUse", message });
		} else {
			message.stopReason = "stop";
			stream.push({ type: "done", reason: "stop", message });
		}
	})().catch((err) => {
		message.errorMessage = String(err?.message ?? err);
		stream.push({ type: "error", reason: "error", error: { ...message, stopReason: "error" } });
	});

	return stream;
}

// Loads the SDK and pi-ai, registers the fake provider, and returns what sessions need.
export async function loadFakeRuntime(iso) {
	const sdk = await loadSdk();
	const ai = await import(pathToFileURL(PI_AI_ENTRY).href);
	const modelRuntime = await sdk.ModelRuntime.create({
		authPath: join(iso.agentDir, "auth.json"), // does not exist in the isolated HOME
		modelsPath: null, // no models.json
		allowModelNetwork: false,
		refreshOnCreate: false,
	});
	modelRuntime.registerProvider(FAKE_PROVIDER, {
		api: FAKE_API,
		apiKey: "fake-not-a-credential", // literal dummy value; the fake stream never sends it anywhere
		streamSimple: (model, context, options) => fakeStreamSimple(ai, model, context, options),
		models: [
			{
				id: FAKE_MODEL_ID,
				name: "Fake streaming model",
				api: FAKE_API,
				baseUrl: "http://fake.invalid",
				reasoning: false,
				input: ["text"],
				contextWindow: 200000,
				maxTokens: 4096,
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			},
		],
	});
	const model = modelRuntime.getModel(FAKE_PROVIDER, FAKE_MODEL_ID);
	if (!model) throw new Error("fake provider is not registered: refusing to run");
	return { sdk, modelRuntime, model };
}

// One session on the fake model, in memory, with only the read tool.
export async function createFakeSession(rt, iso) {
	const { session, modelFallbackMessage } = await rt.sdk.createAgentSession({
		cwd: iso.cwd,
		agentDir: iso.agentDir,
		modelRuntime: rt.modelRuntime,
		model: rt.model,
		sessionManager: rt.sdk.SessionManager.inMemory(iso.cwd),
		tools: ["read"],
	});
	if (modelFallbackMessage) throw new Error(`model fallback, refusing to run: ${modelFallbackMessage}`);
	if (session.model?.provider !== FAKE_PROVIDER) {
		throw new Error(`session uses ${session.model?.provider}/${session.model?.id}, not the fake provider`);
	}
	const stats = { turns: 0, badTurns: 0, deltas: 0, toolCalls: 0, errors: [], stopped: false };
	session.subscribe((event) => {
		if (event.type === "message_update" && event.assistantMessageEvent.type === "text_delta") stats.deltas++;
		else if (event.type === "tool_execution_end") stats.toolCalls++;
	});
	return { session, stats };
}

// A turn counts only if it ended cleanly: the last message is an assistant "stop"
// with text, and the read tool result before it is not an error.
function turnWasClean(session) {
	const msgs = session.messages;
	const last = msgs.at(-1);
	const tool = msgs.at(-2);
	return (
		last?.role === "assistant" &&
		last.stopReason === "stop" &&
		last.content.some((c) => c.type === "text" && c.text.length > 0) &&
		tool?.role === "toolResult" &&
		tool.isError !== true
	);
}

// One untimed turn, so the window measures steady state. Counters are reset afterwards.
export async function warmUp(session, stats) {
	await session.prompt(`warm-up: summarise ${READ_FILE}`);
	Object.assign(stats, { turns: 0, badTurns: 0, deltas: 0, toolCalls: 0, errors: [] });
}

// Stops an agent at the end of its window. The stop flag is set before the abort, so a
// turn cut off by the abort is never counted, whatever the timer rounding.
export function stopAgent(session, stats) {
	stats.stopped = true;
	return session.abort().catch(() => {});
}

// Runs prompt -> stream -> read tool -> final answer, again and again, until windowEnd
// (a performance.now() value) or stopAgent(). A turn that ends after the stop is not counted.
export async function runAgentUntil(session, stats, windowEnd) {
	let n = 0;
	const over = () => stats.stopped || performance.now() >= windowEnd;
	while (!over()) {
		n++;
		try {
			await session.prompt(`turn ${n}: summarise ${READ_FILE}`);
		} catch (err) {
			if (!over() && stats.errors.length < 3) stats.errors.push(String(err?.message ?? err).slice(0, 200));
			return;
		}
		if (over()) return;
		if (turnWasClean(session)) stats.turns++;
		else {
			stats.badTurns++;
			if (stats.errors.length < 3) stats.errors.push(`unclean turn ${n}: stop=${session.messages.at(-1)?.stopReason}`);
		}
	}
}
