// Oreo bridge protocol: line framing, wire-message parsing, and the mapping
// between Oreo's `Agent_Message` and pi-ai's message and tool types.
//
// This module is deliberately pure. It has no runtime imports (type-only
// imports are erased), no pi API, and no process or node dependency, so
// `node --test extensions/oreo/protocol_test.ts` can exercise it offline.

import type { Api, AssistantMessage, JsonObject, Message, ProviderId, TextContent, Tool, ToolCall, Usage } from "@earendil-works/pi-ai";
import type { TSchema } from "typebox";

// --- wire types -----------------------------------------------------------------

export type OreoRole = "system" | "user" | "assistant" | "tool";

export interface OreoToolCall {
	id: string;
	name: string;
	arguments_json: string;
}

/** One entry of the request's `messages`, matching Oreo's `Agent_Message`. */
export interface OreoMessage {
	role: OreoRole;
	text: string;
	tool_calls?: OreoToolCall[];
	tool_call_id?: string;
}

export interface OreoTool {
	name: string;
	description: string;
	parameters_json: string;
}

export interface ModelRequestMessage {
	type: "model_request";
	request_id: string;
	provider: string;
	model: string;
	thinking: string;
	messages: OreoMessage[];
	tools: OreoTool[];
}

export interface EventMessage {
	type: "event";
	kind: string;
	session_id: string;
	work_item_id: string;
	message: string;
}

export interface ReadyMessage {
	type: "ready";
	protocol: number;
}

export interface AcceptedMessage {
	type: "accepted";
	work_item_id: string;
}

export interface ClosedMessage {
	type: "closed";
	session_id: string;
}

export interface StoppedMessage {
	type: "stopped";
}

export interface ErrorMessage {
	type: "error";
	reason: string;
}

export type HostMessage =
	| ModelRequestMessage
	| EventMessage
	| ReadyMessage
	| AcceptedMessage
	| ClosedMessage
	| StoppedMessage
	| ErrorMessage;

export interface ModelResponseMessage {
	type: "model_response";
	request_id: string;
	text: string;
	tool_calls: OreoToolCall[];
}

export interface ModelErrorMessage {
	type: "model_error";
	request_id: string;
	reason: string;
}

const HOST_MESSAGE_TYPES = new Set(["model_request", "event", "ready", "accepted", "closed", "stopped", "error"]);

// --- framing --------------------------------------------------------------------

/**
 * Split one stdout chunk into complete lines plus the trailing partial line.
 * The caller keeps `rest` and appends the next chunk to it.
 */
export function frameLines(buffer: string): { lines: string[]; rest: string } {
	const lastBreak = buffer.lastIndexOf("\n");
	if (lastBreak < 0) {
		return { lines: [], rest: buffer };
	}
	const lines: string[] = [];
	for (const raw of buffer.slice(0, lastBreak).split("\n")) {
		const line = raw.replace(/\r$/, "");
		if (line.length > 0) {
			lines.push(line);
		}
	}
	return { lines, rest: buffer.slice(lastBreak + 1) };
}

/** Encode one message as a single protocol line. */
export function serializeMessage(message: unknown): string {
	return `${JSON.stringify(message)}\n`;
}

// --- parsing --------------------------------------------------------------------

/**
 * Parse one protocol line. A malformed line, a non-object, or an unknown type
 * returns undefined instead of throwing, so a bad line is skipped, never fatal.
 */
export function parseMessage(line: string): HostMessage | undefined {
	const trimmed = line.trim();
	if (trimmed.length === 0) {
		return undefined;
	}
	let value: unknown;
	try {
		value = JSON.parse(trimmed);
	} catch {
		return undefined;
	}
	if (typeof value !== "object" || value === null || Array.isArray(value)) {
		return undefined;
	}
	const type = (value as { type?: unknown }).type;
	if (typeof type !== "string" || !HOST_MESSAGE_TYPES.has(type)) {
		return undefined;
	}
	return value as HostMessage;
}

// --- mapping --------------------------------------------------------------------

/**
 * Map Oreo's messages and tools to a pi-ai `Context`.
 *
 * `parameters_json` is a JSON Schema while pi's `Tool.parameters` is a TypeBox
 * schema. `Type.Unsafe` is the documented bridge, but it is a runtime import, so
 * this module keeps the erased equivalent: the decoded schema is used as-is.
 *
 * `AssistantMessage` requires `api`, `provider`, `model`, `usage`, and
 * `stopReason` even when it is only replayed as history. pi reads `api`/`provider`
 * on assistant history only for its managed-thinking path, so the request's
 * provider and model are used and the rest is synthesized.
 */
export function toPiContext(request: ModelRequestMessage): { messages: Message[]; tools: Tool[] } {
	const toolNames = new Map<string, string>();
	const messages: Message[] = [];
	for (const message of request.messages ?? []) {
		switch (message.role) {
			case "system":
				messages.push({ role: "system", content: message.text, timestamp: Date.now() });
				break;
			case "user":
				messages.push({ role: "user", content: message.text, timestamp: Date.now() });
				break;
			case "assistant": {
				const content: (TextContent | ToolCall)[] = [];
				if (message.text.length > 0) {
					content.push({ type: "text", text: message.text });
				}
				for (const call of message.tool_calls ?? []) {
					toolNames.set(call.id, call.name);
					content.push({ type: "toolCall", id: call.id, name: call.name, arguments: parseArguments(call.arguments_json) });
				}
				messages.push({
					role: "assistant",
					content,
					api: "" as Api,
					provider: request.provider as ProviderId,
					model: request.model,
					usage: zeroUsage(),
					stopReason: "stop",
					timestamp: Date.now(),
				});
				break;
			}
			case "tool": {
				const toolCallId = message.tool_call_id ?? "";
				messages.push({
					role: "toolResult",
					toolCallId,
					toolName: toolNames.get(toolCallId) ?? "",
					content: [{ type: "text", text: message.text }],
					isError: false,
					timestamp: Date.now(),
				});
				break;
			}
		}
	}

	const tools: Tool[] = (request.tools ?? []).map((tool) => ({
		name: tool.name,
		description: tool.description,
		parameters: parseSchema(tool.parameters_json),
	}));
	return { messages, tools };
}

/** Map a pi-ai assistant message to Oreo's response: text plus tool calls. */
export function toModelResponse(requestId: string, message: AssistantMessage): ModelResponseMessage {
	let text = "";
	const toolCalls: OreoToolCall[] = [];
	for (const block of message.content) {
		if (block.type === "text") {
			text += block.text;
		} else if (block.type === "toolCall") {
			toolCalls.push({ id: block.id, name: block.name, arguments_json: JSON.stringify(block.arguments ?? {}) });
		}
	}
	return { type: "model_response", request_id: requestId, text, tool_calls: toolCalls };
}

export function modelError(requestId: string, reason: string): ModelErrorMessage {
	return { type: "model_error", request_id: requestId, reason };
}

export type OreoThinkingLevel = "minimal" | "low" | "medium" | "high" | "xhigh" | "max";

/** Map Oreo's thinking level onto pi's, dropping `off` and unknown values. */
export function toThinkingLevel(thinking: string): OreoThinkingLevel | undefined {
	switch (thinking) {
		case "minimal":
		case "low":
		case "medium":
		case "high":
		case "xhigh":
		case "max":
			return thinking;
	}
	return undefined;
}

// --- helpers --------------------------------------------------------------------

function zeroUsage(): Usage {
	return {
		input: 0,
		output: 0,
		cacheRead: 0,
		cacheWrite: 0,
		totalTokens: 0,
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
	};
}

function parseArguments(json: string): JsonObject {
	try {
		const value: unknown = JSON.parse(json);
		if (typeof value === "object" && value !== null && !Array.isArray(value)) {
			return value as JsonObject;
		}
	} catch {
		// Malformed arguments become an empty object; the host rejects the tool call.
	}
	return {};
}

function parseSchema(json: string): TSchema {
	const fallback = { type: "object", properties: {} };
	if (json.length === 0) {
		return fallback as TSchema;
	}
	try {
		const value: unknown = JSON.parse(json);
		if (typeof value === "object" && value !== null) {
			return value as TSchema;
		}
	} catch {
		// A malformed schema still gives the model a usable empty object schema.
	}
	return fallback as TSchema;
}
