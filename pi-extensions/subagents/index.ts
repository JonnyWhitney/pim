import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Backend } from "./backend.ts";
import { Parameters } from "./protocol.ts";

export default function (pi: ExtensionAPI) {
	if (process.env.PIM_HOST !== "1" || !process.env.PIM_SUBAGENT_ROOT) return;
	const root = process.env.PIM_SUBAGENT_ROOT;
	const backend = new Backend();
	const active = new Set<AbortController>();
	const work = new Set<Promise<unknown>>();
	pi.on("session_shutdown", async () => {
		for (const controller of active) controller.abort();
		await Promise.allSettled(work);
	});
	pi.on("session_start", (_event, ctx) => {
		if (ctx.mode !== "rpc") return;
		pi.registerCommand("pim-internal-agent-stop", {
			description: "Reserved for PIM child cancellation",
			handler: async (args, context) => {
				if (context.mode !== "rpc") return;
				const [token, invocationId, childId, ...extra] = args.trim().split(/\s+/);
				if (
					extra.length ||
					![token, invocationId].every((value) => /^[A-Za-z0-9_-]+$/.test(value ?? "")) ||
					!/^(\*|[A-Za-z0-9_-]+)$/.test(childId ?? "")
				)
					throw new Error("Invalid PIM stop request.");
				const labels = await backend.stop(invocationId, childId);
				context.ui.setStatus("pim-agent-stop", JSON.stringify({ token, labels }));
			},
		});
		pi.registerTool({
			name: "subagent",
			label: "Subagent",
			description:
				"Run 1–8 dynamically defined children without parent history. Explicit tools, provider/model and thinkingLevel are required. Parallel children are restricted to built-in read, grep, find, ls; at most four processes run at once. Output is capped at 50 KiB and 2000 lines in aggregate; full events are stored in private transcript files. Project context defaults to true. Labels have no behavioral meaning.",
			parameters: Parameters,
			async execute(toolCallId, params, signal, onUpdate, context) {
				if (context.mode !== "rpc" || process.env.PIM_HOST !== "1")
					throw new Error("Subagents require PIM RPC mode.");
				const controller = new AbortController();
				const abort = () => controller.abort();
				signal?.addEventListener("abort", abort, { once: true });
				if (signal?.aborted) abort();
				active.add(controller);
				let task: ReturnType<Backend["execute"]> | undefined;
				try {
					task = backend.execute(params, {
						root,
						toolCallId,
						cwd: context.cwd,
						trusted: context.isProjectTrusted(),
						parentSessionId: context.sessionManager.getSessionId(),
						parentSessionFile: context.sessionManager.getSessionFile() ?? null,
						signal: controller.signal,
						onUpdate: (details) =>
							onUpdate?.({
								content: [
									{ type: "text", text: `${details.agents.length} subagent(s): ${details.status}` },
								],
								details,
							}),
					});
					work.add(task);
					return await task;
				} finally {
					if (task) work.delete(task);
					active.delete(controller);
					signal?.removeEventListener("abort", abort);
				}
			},
		});
	});
}
