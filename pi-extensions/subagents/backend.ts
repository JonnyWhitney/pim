import { addUsage, emptyUsage, truncate, validate, type Details } from "./protocol.ts";
import { Limiter, runChild, type RunOptions } from "./runner.ts";
import { TranscriptStore } from "./transcript-store.ts";

export interface ExecuteOptions {
	root: string;
	parentSessionId: string;
	parentSessionFile: string | null;
	toolCallId: string;
	cwd: string;
	trusted: boolean;
	signal?: AbortSignal;
	onUpdate?: (details: Details) => void;
	invocation?: RunOptions["invocation"];
	stopTimeout?: number;
}
export class Backend {
	private limiter = new Limiter();
	async execute(input: unknown, opts: ExecuteOptions) {
		const { agents } = validate(input);
		const store = new TranscriptStore(
			opts.root,
			opts.parentSessionId,
			opts.parentSessionFile,
			opts.toolCallId,
			agents,
		);
		store.manifest.status = "running";
		const update = () => {
			store.save();
			opts.onUpdate?.(store.details());
		};
		update();
		const controller = new AbortController();
		const signal = opts.signal
			? AbortSignal.any([opts.signal, controller.signal])
			: controller.signal;
		const settled = await Promise.allSettled(
			agents.map((agent, index) =>
				this.limiter
					.run(async () => {
						const child = store.manifest.agents[index];
						child.status = signal.aborted ? "aborted" : "running";
						store.append(index, { type: "status", status: child.status });
						update();
						let lastUpdate = 0;
						const result = await runChild(agent, {
							...opts,
							signal,
							parallel: agents.length > 1,
							onRecord: (record) => {
								store.append(index, record);
								if (Date.now() - lastUpdate >= 250) {
									lastUpdate = Date.now();
									update();
								}
							},
						});
						child.status = result.status;
						child.stoppedBy = result.status === "aborted" ? "parent_abort" : null;
						child.usage = result.usage;
						child.summary = truncate(result.output, 1024);
						store.finish(index, result.output);
						update();
						return `### ${agent.label} (${child.status})\n${truncate(result.output, Math.floor((48 * 1024) / agents.length))}`;
					})
					.catch((error) => {
						controller.abort();
						throw error;
					}),
			),
		);
		const failed = settled.find((result) => result.status === "rejected");
		if (failed?.status === "rejected") throw failed.reason;
		const outputs = settled.map((result) => (result.status === "fulfilled" ? result.value : ""));
		const children = store.manifest.agents;
		store.manifest.status = children.some((child) => child.status === "aborted")
			? "aborted"
			: children.some((child) => child.status === "failed")
				? "failed"
				: "completed";
		update();
		const usage = emptyUsage();
		children.forEach((child) => addUsage(usage, child.usage));
		return {
			content: [{ type: "text" as const, text: truncate(outputs.join("\n\n")) }],
			details: store.details(),
			usage,
		};
	}
}
