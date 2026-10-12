// Tests for the Oreo bridge protocol module. These run offline with
// `node --test extensions/oreo/protocol_test.ts`; there is no model call, no
// pi runtime, and no host process involved.

import assert from "node:assert";
import { test } from "node:test";

import {
	type AssistantMessage,
	type ModelRequestMessage,
	frameLines,
	modelError,
	parseMessage,
	serializeMessage,
	toModelResponse,
	toPiContext,
	toThinkingLevel,
} from "./protocol.ts";

function decodeRequest(line: string): ModelRequestMessage {
	const message = parseMessage(line);
	assert.ok(message !== undefined, "the line should parse");
	assert.equal(message.type, "model_request");
	if (message.type !== "model_request") {
		throw new Error("unreachable");
	}
	return message;
}

test("a model_request decodes into pi-ai messages and tools", () => {
	const request = decodeRequest(
		serializeMessage({
			type: "model_request",
			request_id: "mr-7",
			provider: "opencode-go",
			model: "deepseek-v4.1-flash",
			thinking: "low",
			messages: [
				{ role: "system", text: "be brief" },
				{ role: "user", text: "read src/app.txt" },
			],
			tools: [
				{
					name: "read",
					description: "Read a file.",
					parameters_json: '{"type":"object","properties":{"path":{"type":"string"}}}',
				},
			],
		}),
	);

	const { messages, tools } = toPiContext(request);
	assert.deepEqual(
		messages.map((message) => message.role),
		["system", "user"],
	);
	assert.equal(messages[0].role === "system" && messages[0].content, "be brief");
	assert.equal(messages[1].role === "user" && messages[1].content, "read src/app.txt");
	assert.equal(tools.length, 1);
	assert.equal(tools[0].name, "read");
	assert.equal(tools[0].description, "Read a file.");
	assert.deepEqual(tools[0].parameters, { type: "object", properties: { path: { type: "string" } } });
});

test("an Oreo assistant message with tool calls maps to pi-ai content", () => {
	const request = decodeRequest(
		serializeMessage({
			type: "model_request",
			request_id: "mr-8",
			provider: "opencode-go",
			model: "deepseek-v4.1-flash",
			thinking: "high",
			messages: [
				{
					role: "assistant",
					text: "checking",
					tool_calls: [{ id: "c1", name: "read", arguments_json: '{"path":"src/app.txt"}' }],
				},
				{ role: "tool", text: "the file says hello", tool_call_id: "c1" },
			],
			tools: [],
		}),
	);

	const { messages } = toPiContext(request);
	const assistant = messages[0];
	assert.equal(assistant.role, "assistant");
	if (assistant.role !== "assistant") {
		throw new Error("unreachable");
	}
	assert.equal(assistant.provider, "opencode-go");
	assert.equal(assistant.model, "deepseek-v4.1-flash");
	assert.deepEqual(assistant.content, [
		{ type: "text", text: "checking" },
		{ type: "toolCall", id: "c1", name: "read", arguments: { path: "src/app.txt" } },
	]);

	const tool = messages[1];
	assert.equal(tool.role, "toolResult");
	if (tool.role !== "toolResult") {
		throw new Error("unreachable");
	}
	assert.equal(tool.toolCallId, "c1");
	assert.equal(tool.toolName, "read");
	assert.equal(tool.isError, false);
	assert.deepEqual(tool.content, [{ type: "text", text: "the file says hello" }]);
});

test("a pi-ai content list becomes text plus tool_calls with arguments_json", () => {
	const assistant = {
		role: "assistant",
		content: [
			{ type: "thinking", thinking: "considering" },
			{ type: "text", text: "the file says " },
			{ type: "text", text: "hello" },
			{ type: "toolCall", id: "c1", name: "read", arguments: { path: "src/app.txt" } },
		],
	} as unknown as AssistantMessage;

	assert.deepEqual(toModelResponse("mr-7", assistant), {
		type: "model_response",
		request_id: "mr-7",
		text: "the file says hello",
		tool_calls: [{ id: "c1", name: "read", arguments_json: '{"path":"src/app.txt"}' }],
	});
});

test("thinking but no text still answers with empty text and no tool calls", () => {
	const assistant = { role: "assistant", content: [{ type: "thinking", thinking: "hmm" }] } as unknown as AssistantMessage;
	assert.deepEqual(toModelResponse("mr-9", assistant), {
		type: "model_response",
		request_id: "mr-9",
		text: "",
		tool_calls: [],
	});
});

test("malformed lines return undefined rather than throwing", () => {
	assert.equal(parseMessage("{not json"), undefined);
	assert.equal(parseMessage(""), undefined);
	assert.equal(parseMessage("   "), undefined);
	assert.equal(parseMessage("[]"), undefined);
	assert.equal(parseMessage("null"), undefined);
	assert.equal(parseMessage("42"), undefined);
	assert.equal(parseMessage('{"type":42}'), undefined);
	assert.equal(parseMessage('{"no_type":true}'), undefined);
});

test("unknown message types are ignored", () => {
	assert.equal(parseMessage('{"type":"future_thing","x":1}'), undefined);
});

test("framing yields complete lines and keeps the partial tail", () => {
	const first = frameLines('{"type":"ready","protocol":1}\n{"type":"event"');
	assert.deepEqual(first.lines, ['{"type":"ready","protocol":1}']);
	assert.equal(first.rest, '{"type":"event"');

	const second = frameLines(`${first.rest},"kind":"progress"}\n`);
	assert.deepEqual(second.lines, ['{"type":"event","kind":"progress"}']);
	assert.equal(second.rest, "");

	assert.deepEqual(frameLines("no newline yet"), { lines: [], rest: "no newline yet" });
});

test("thinking levels are validated and model errors stay token-free", () => {
	assert.equal(toThinkingLevel("low"), "low");
	assert.equal(toThinkingLevel("max"), "max");
	assert.equal(toThinkingLevel("off"), undefined);
	assert.equal(toThinkingLevel("louder"), undefined);
	assert.deepEqual(modelError("mr-7", "unknown model p/m in pi"), {
		type: "model_error",
		request_id: "mr-7",
		reason: "unknown model p/m in pi",
	});
});
