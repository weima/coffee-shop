// Coffee Shop's Pi extension. Loaded into every Station with `pi -e`, next to the
// user's installed extensions. It adds one tool that asks the user a question. The
// Station sees the dialog as needs_input and answers it from the main agent's reply.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "coffee_shop_ask",
		label: "Ask the user",
		description: "Ask the user a question with a fixed list of options and wait for the answer.",
		parameters: Type.Object({
			question: Type.String({ description: "The question to ask." }),
			options: Type.Array(Type.String(), { description: "The answers the user may choose from." }),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			if (!ctx.hasUI) {
				return { content: [{ type: "text", text: "No user is available to answer." }], details: {} };
			}
			const answer = await ctx.ui.select(params.question, params.options);
			return {
				content: [{ type: "text", text: answer ?? "The user cancelled the question." }],
				details: {},
			};
		},
	});
}
