import * as fs from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import type { Agent, Details, Manifest } from "./protocol.ts";

export function safeId(id: string): string {
	if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(id))
		throw new Error("Unsafe transcript identifier.");
	return id;
}
function directory(path: string): void {
	if (dirname(path) !== path) directory(dirname(path));
	if (!fs.existsSync(path)) {
		fs.mkdirSync(path, { mode: 0o700 });
	}
	const stat = fs.lstatSync(path);
	if (!stat.isDirectory() || stat.isSymbolicLink())
		throw new Error(`Unsafe transcript directory: ${path}`);
}
export function privateRoot(root: string): string {
	if (!isAbsolute(root)) throw new Error("An absolute transcript root is required.");
	root = resolve(root);
	directory(root);
	fs.chmodSync(root, 0o700);
	return fs.realpathSync(root);
}
export function readRecords(text: string): { records: unknown[]; errors: number; pending: string } {
	const lines = text.split("\n");
	const pending = lines.pop()!;
	const records: unknown[] = [];
	let errors = 0;
	for (const line of lines) {
		if (!line) continue;
		try {
			records.push(JSON.parse(line));
		} catch {
			errors++;
		}
	}
	return { records, errors, pending };
}
export class TranscriptStore {
	readonly manifest: Manifest;
	constructor(
		root: string,
		parentSessionId: string,
		parentSessionFile: string | null,
		toolCallId: string,
		agents: Agent[],
	) {
		safeId(parentSessionId);
		const parent = join(privateRoot(root), parentSessionId);
		directory(parent);
		fs.chmodSync(parent, 0o700);
		const invocationId = randomUUID();
		const transcriptDir = join(parent, invocationId);
		fs.mkdirSync(transcriptDir, { mode: 0o700 });
		const now = new Date().toISOString();
		this.manifest = {
			schemaVersion: 1,
			invocationId,
			transcriptDir,
			parentSessionId,
			parentSessionFile,
			toolCallId,
			createdAt: now,
			updatedAt: now,
			mode: agents.length === 1 ? "single" : "parallel",
			status: "pending",
			agents: agents.map((agent) => {
				const id = randomUUID();
				const transcriptPath = join(transcriptDir, `${id}.jsonl`);
				fs.writeFileSync(transcriptPath, "", { mode: 0o600, flag: "wx" });
				return {
					id,
					label: agent.label,
					status: "pending",
					transcriptPath,
					summary: null,
					usage: null,
					stoppedBy: null,
				};
			}),
		};
		agents.forEach((agent, index) => this.append(index, { type: "configuration", agent }));
		this.save();
	}
	details(): Details {
		const { schemaVersion, invocationId, transcriptDir, mode, status, agents } = this.manifest;
		return structuredClone({ schemaVersion, invocationId, transcriptDir, mode, status, agents });
	}
	private atomic(name: string, value: unknown): void {
		const target = join(this.manifest.transcriptDir, name);
		const temporary = `${target}.${randomUUID()}.tmp`;
		try {
			fs.writeFileSync(temporary, JSON.stringify(value) + "\n", { mode: 0o600, flag: "wx" });
			fs.renameSync(temporary, target);
		} finally {
			fs.rmSync(temporary, { force: true });
		}
	}
	save(): void {
		this.manifest.updatedAt = new Date().toISOString();
		this.atomic("invocation.json", this.manifest);
	}
	append(index: number, record: unknown): void {
		const child = this.manifest.agents[index];
		const fd = fs.openSync(
			child.transcriptPath,
			fs.constants.O_APPEND | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW,
		);
		try {
			fs.writeFileSync(fd, JSON.stringify({ timestamp: new Date().toISOString(), record }) + "\n");
		} finally {
			fs.closeSync(fd);
		}
	}
	finish(index: number, output: string): void {
		this.append(index, { type: "final", child: this.manifest.agents[index], output });
		this.atomic(`${safeId(this.manifest.agents[index].id)}.summary.json`, {
			...this.manifest.agents[index],
			output,
		});
		this.save();
	}
}
