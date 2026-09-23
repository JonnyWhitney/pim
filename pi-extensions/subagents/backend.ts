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
	private active = new Map<
		string,
		{
			id: string;
			controller: AbortController;
			done: Promise<void>;
			finish: () => void;
			child: Details["agents"][number];
			parent?: AbortSignal;
			persisted: boolean;
		}[]
	>();

	async stop(invocationId: string, childId: string): Promise<string[]> {
		const selected = (this.active.get(invocationId) ?? []).filter(
			(entry) =>
				(childId === "*" || entry.id === childId) &&
				["pending", "running"].includes(entry.child.status) &&
				!entry.controller.signal.aborted &&
				!entry.parent?.aborted,
		);
		for (const entry of selected) entry.controller.abort();
		await Promise.all(selected.map((entry) => entry.done));
		return selected
			.filter(
				(entry) => entry.persisted && entry.child.status === "stopped" && !entry.parent?.aborted,
			)
			.map((entry) => entry.child.label);
	}
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
		const entries = store.manifest.agents.map((child) => {
			let finish!: () => void;
			const done = new Promise<void>((resolve) => {
				finish = resolve;
			});
			return {
				id: child.id,
				child,
				controller: new AbortController(),
				done,
				finish,
				parent: opts.signal,
				persisted: false,
			};
		});
		update();
		this.active.set(store.manifest.invocationId, entries);
		const controller = new AbortController();
		const signal = opts.signal
			? AbortSignal.any([opts.signal, controller.signal])
			: controller.signal;
		const settled = await Promise.allSettled(
			agents.map((agent, index) =>
				this.limiter
					.run(
						async () => {
							const child = store.manifest.agents[index];
							child.status = signal.aborted
								? "aborted"
								: entries[index].controller.signal.aborted
									? "stopped"
									: "running";
							store.append(index, { type: "status", status: child.status });
							update();
							let lastUpdate = 0;
							const result = await runChild(agent, {
								...opts,
								signal,
								userSignal: entries[index].controller.signal,
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
							child.stoppedBy =
								result.status === "aborted"
									? "parent_abort"
									: result.status === "stopped"
										? "user"
										: null;
							child.usage = result.usage;
							child.summary = truncate(result.output, 1024);
							store.finish(index, result.output);
							update();
							entries[index].persisted = true;
							return `### ${agent.label} (${child.status})\n${truncate(result.output, Math.floor((48 * 1024) / agents.length))}`;
						},
						AbortSignal.any([signal, entries[index].controller.signal]),
					)
					.finally(() => entries[index].finish())
					.catch((error) => {
						controller.abort();
						throw error;
					}),
			),
		);
		this.active.delete(store.manifest.invocationId);
		const failed = settled.find((result) => result.status === "rejected");
		if (failed?.status === "rejected") throw failed.reason;
		const outputs = settled.map((result) => (result.status === "fulfilled" ? result.value : ""));
		const children = store.manifest.agents;
		store.manifest.status = children.some((child) => child.status === "aborted")
			? "aborted"
			: children.some((child) => child.status === "failed")
				? "failed"
				: children.some((child) => child.status === "stopped")
					? "stopped"
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
