import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// This guard is loaded only in children. No subagent tool is registered here.
export default function (pi: ExtensionAPI) {
	const raw = process.env.PIM_CHILD_POLICY;
	delete process.env.PIM_CHILD_POLICY;
	if (!raw) return;
	const policy = JSON.parse(raw) as { tools: string[]; model: string };
	pi.on("session_start", (_event, ctx) => {
		if (ctx.mode !== "json") return;
		const available = new Set(pi.getAllTools().map((tool) => tool.name));
		const missing = policy.tools.filter((tool) => !available.has(tool));
		const actualModel = ctx.model && `${ctx.model.provider}/${ctx.model.id}`;
		if (missing.length || actualModel !== policy.model) {
			process.stderr.write(
				missing.length
					? `Unavailable child tools: ${missing.join(", ")}\n`
					: `Requested child model ${policy.model} was not resolved exactly (${actualModel}).\n`,
			);
			process.exit(1);
		}
		pi.setActiveTools(policy.tools.filter((tool) => tool !== "subagent"));
	});
	pi.on("tool_call", (event) => {
		if (!policy.tools.includes(event.toolName) || event.toolName === "subagent") {
			return { block: true, reason: "The tool is excluded by the child policy." };
		}
	});
}
