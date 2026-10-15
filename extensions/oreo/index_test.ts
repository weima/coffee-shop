import assert from "node:assert/strict";
import { test } from "node:test";
import { runOreoSubmission, stationRpcResult, validateOreoRoute, type OreoSubmissionHost } from "./index.ts";

class FakeOreoHost implements OreoSubmissionHost {
	requests: Array<{ session_id: string; prompt: string; provider: string; model: string; thinking: string }> = [];
	closed: string[] = [];
	quitCount = 0;
	result: Promise<string> = Promise.resolve("Oreo final result");

	submit(request: (typeof this.requests)[number], signal: AbortSignal): Promise<string> {
		this.requests.push(request);
		return Promise.race([
			this.result,
			new Promise<never>((_, reject) => signal.addEventListener("abort", () => reject(new Error("cancelled")), { once: true })),
		]);
	}

	async closeSession(sessionId: string): Promise<void> { this.closed.push(sessionId); }
	async quit(): Promise<void> { this.quitCount++; }
}

 test("submits the exact assignment once with explicit route and thinking, then relays the result", async () => {
	const host = new FakeOreoHost();
	const task = "Do exactly this.\nKeep the newline and punctuation: 'x'.";
	const result = await runOreoSubmission(host, "shot-17", task, "openai-codex/gpt-6-luna", "high");
	assert.equal(result, "Oreo final result");
	assert.deepEqual(host.requests, [{
		session_id: "shot-17", prompt: task, provider: "openai-codex", model: "gpt-6-luna", thinking: "high",
	}]);
	assert.deepEqual(host.closed, ["shot-17"]);
	assert.equal(host.quitCount, 1);
});

test("failed work is relayed as failure and still closes the Oreo session", async () => {
	const host = new FakeOreoHost();
	host.result = Promise.reject(new Error("fake work failed"));
	await assert.rejects(runOreoSubmission(host, "shot-f", "task", "openai-codex/gpt-6-luna", "high"), /fake work failed/);
	assert.equal(host.requests.length, 1, "a failed Oreo submission must not fall back to Pi or retry");
	assert.deepEqual(host.closed, ["shot-f"]);
	assert.equal(host.quitCount, 1);
});

test("cancellation closes the session and process without falling back", async () => {
	const host = new FakeOreoHost();
	let started!: () => void;
	host.result = new Promise((resolve) => { started = () => resolve("late result"); });
	const controller = new AbortController();
	const submission = runOreoSubmission(host, "shot-c", "task", "openai-codex/gpt-6-luna", "high", controller.signal);
	controller.abort();
	await assert.rejects(submission, /cancelled/);
	started();
	assert.equal(host.requests.length, 1);
	assert.deepEqual(host.closed, ["shot-c"]);
	assert.equal(host.quitCount, 1);
});

test("Oreo's final text uses the Station Pi-RPC agent_end contract unchanged", () => {
	assert.deepEqual(stationRpcResult("exact Oreo result"), {
		type: "agent_end",
		messages: [{ role: "assistant", content: [{ type: "text", text: "exact Oreo result" }] }],
	});
});

test("an invalid route fails before any Oreo submission and cannot fall back", async () => {
	const host = new FakeOreoHost();
	await assert.rejects(runOreoSubmission(host, "shot-invalid", "task", "/", "high"), /provider\/model/);
	assert.equal(host.requests.length, 0);
	assert.equal(host.quitCount, 0);
});

test("provider/model must be a complete pair", () => {
	assert.deepEqual(validateOreoRoute("openai-codex/gpt-6-luna"), { provider: "openai-codex", model: "gpt-6-luna" });
	for (const route of ["", "openai-codex/", "/gpt-6-luna", "openai-codex", "bad route/model", "a/b/c"]) {
		assert.throws(() => validateOreoRoute(route), /provider\/model/);
	}
});
