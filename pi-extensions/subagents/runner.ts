import { spawn } from "node:child_process";
import * as fs from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { StringDecoder } from "node:string_decoder";
import type { Usage } from "@earendil-works/pi-ai";
import { addUsage, emptyUsage, truncate, type Agent } from "./protocol.ts";

export interface RunOptions {
	cwd: string;
	trusted: boolean;
	parallel: boolean;
	signal?: AbortSignal;
	userSignal?: AbortSignal;
	stopTimeout?: number;
	invocation?: (args: string[]) => { command: string; args: string[] };
	onRecord: (record: unknown) => void;
}
export interface Outcome {
	status: "completed" | "failed" | "aborted" | "stopped";
	output: string;
	usage: Usage;
}
export function piInvocation(args: string[]): { command: string; args: string[] } {
	const script = process.argv[1];
	if (script && !script.startsWith("/$bunfs/") && fs.existsSync(script))
		return { command: process.execPath, args: [script, ...args] };
	if (!/^(node|bun)(\.exe)?$/i.test(basename(process.execPath)))
		return { command: process.execPath, args };
	return { command: "pi", args };
}

export function childArgs(
	agent: Agent,
	opts: Pick<RunOptions, "cwd" | "trusted" | "parallel">,
	systemFile?: string,
): string[] {
	const cwd = resolve(opts.cwd, agent.cwd ?? ".");
	// Trust is not transferred to a different directory, including sibling projects.
	const trusted = opts.trusted && fs.realpathSync(cwd) === fs.realpathSync(opts.cwd);
	const args = [
		"--mode",
		"json",
		"-p",
		"--no-session",
		"--model",
		agent.model,
		"--thinking",
		agent.thinkingLevel,
		"--exclude-tools",
		"subagent",
		trusted && agent.projectContext !== false ? "--approve" : "--no-approve",
	];
	args.push(...(agent.tools.length ? ["--tools", agent.tools.join(",")] : ["--no-tools"]));
	if (agent.projectContext === false)
		args.push("--no-context-files", "--no-extensions", "--no-skills", "--no-prompt-templates");
	else if (opts.parallel) args.push("--no-extensions");
	if (systemFile)
		args.push(
			agent.systemPromptMode === "replace" ? "--system-prompt" : "--append-system-prompt",
			systemFile,
		);
	args.push("--extension", fileURLToPath(new URL("./child-policy.ts", import.meta.url)));
	return args;
}
export function childEnvironment(agent: Agent): NodeJS.ProcessEnv {
	const env = { ...process.env };
	for (const key of Object.keys(env))
		if (
			key.startsWith("PIM_") ||
			[
				"PI_SESSION_ID",
				"PI_SESSION_FILE",
				"PI_PROVIDER",
				"PI_MODEL",
				"PI_REASONING_LEVEL",
			].includes(key)
		)
			delete env[key];
	env.PIM_CHILD_POLICY = JSON.stringify({ tools: agent.tools, model: agent.model });
	return env;
}
export function childPrompt(agent: Agent): string {
	return agent.context === undefined
		? `Task:\n${agent.prompt}`
		: `Caller context (JSON string):\n${JSON.stringify(agent.context)}\n\nTask:\n${agent.prompt}`;
}
export async function runChild(agent: Agent, opts: RunOptions): Promise<Outcome> {
	const usage = emptyUsage();
	if (opts.signal?.aborted) return { status: "aborted", output: "Aborted by parent.", usage };
	if (opts.userSignal?.aborted) return { status: "stopped", output: "Stopped by user.", usage };
	let temporary: string | undefined;
	try {
		let systemFile: string | undefined;
		if (agent.systemPrompt !== undefined) {
			temporary = fs.mkdtempSync(join(tmpdir(), "pim-prompt-"));
			fs.chmodSync(temporary, 0o700);
			systemFile = join(temporary, "system.md");
			fs.writeFileSync(systemFile, agent.systemPrompt, { mode: 0o600, flag: "wx" });
		}
		const args = childArgs(agent, opts, systemFile);
		const invocation = (opts.invocation ?? piInvocation)(args);
		return await new Promise<Outcome>((done) => {
			const child = spawn(invocation.command, invocation.args, {
				cwd: resolve(opts.cwd, agent.cwd ?? "."),
				env: childEnvironment(agent),
				shell: false,
				detached: process.platform !== "win32",
				stdio: ["pipe", "pipe", "pipe"],
			});
			let buffer = "",
				stderr = "",
				output = "",
				failure = "";
			let ended = false,
				assistantSeen = false;
			let killTimer: ReturnType<typeof setTimeout> | undefined;
			const decoder = new StringDecoder("utf8");
			const kill = (signal: NodeJS.Signals) => {
				try {
					if (process.platform !== "win32" && child.pid) process.kill(-child.pid, signal);
					else child.kill(signal);
				} catch {
					/* A process that has already exited needs no signal. */
				}
			};
			const stop = () => {
				if (ended || killTimer) return;
				kill("SIGTERM");
				killTimer = setTimeout(() => kill("SIGKILL"), opts.stopTimeout ?? 5000);
			};
			let userStopped = false;
			const userStop = () => {
				if (ended || child.exitCode !== null || child.signalCode !== null) return;
				userStopped = true;
				stop();
			};
			const record = (value: unknown) => {
				try {
					opts.onRecord(value);
				} catch (error) {
					failure = `Transcript write failed: ${String(error)}`;
					stop();
				}
			};
			const line = (text: string) => {
				if (!text.trim()) return;
				try {
					const event = JSON.parse(text);
					if (!event || typeof event.type !== "string") throw new Error("Missing event type");
					record(event);
					if (event.type === "message_end" && event.message) {
						const message = event.message;
						if (message.role === "assistant" || message.role === "toolResult")
							addUsage(usage, message.usage);
						if (message.role === "assistant") {
							assistantSeen = true;
							if (!Array.isArray(message.content)) throw new Error("Invalid assistant content");
							output = message.content
								.filter((part: { type: string }) => part.type === "text")
								.map((part: { text: string }) => part.text)
								.join("\n");
							if (["error", "aborted"].includes(message.stopReason))
								failure = message.errorMessage || `Child ${message.stopReason}`;
						}
					}
				} catch (error) {
					failure = `Malformed child JSON: ${String(error)}`;
					record({ type: "malformed", text });
					stop();
				}
			};
			child.stdout.on("data", (chunk: Buffer) => {
				buffer += decoder.write(chunk);
				let end: number;
				while ((end = buffer.indexOf("\n")) >= 0) {
					line(buffer.slice(0, end));
					buffer = buffer.slice(end + 1);
				}
				if (Buffer.byteLength(buffer) > 16 * 1024 * 1024) {
					failure = "Child JSON record exceeded 16 MiB.";
					buffer = "";
					stop();
				}
			});
			child.stderr.setEncoding("utf8");
			child.stderr.on("data", (text: string) => {
				stderr = truncate(stderr + text);
				record({ type: "stderr", text });
			});
			child.stdin.on("error", (error) => {
				if (!failure) failure = `Child input failed: ${error.message}`;
			});
			child.on("error", (error) => {
				failure = `Child could not be started: ${error.message}`;
			});
			child.once("close", (code) => {
				ended = true;
				if (killTimer) clearTimeout(killTimer);
				opts.signal?.removeEventListener("abort", stop);
				opts.userSignal?.removeEventListener("abort", userStop);
				buffer += decoder.end();
				if (buffer.trim()) {
					failure ||= "Interrupted child JSON record.";
					record({ type: "incomplete", text: buffer });
				}
				const aborted = opts.signal?.aborted;
				const status = aborted
					? "aborted"
					: userStopped
						? "stopped"
						: failure || code !== 0 || !assistantSeen
							? "failed"
							: "completed";
				done({
					status,
					output: aborted
						? "Aborted by parent."
						: userStopped
							? "Stopped by user."
							: failure ||
								(status === "failed"
									? stderr || `Child exited with code ${code} without a final response.`
									: output),
					usage,
				});
			});
			opts.signal?.addEventListener("abort", stop, { once: true });
			if (opts.signal?.aborted) stop();
			opts.userSignal?.addEventListener("abort", userStop, { once: true });
			if (opts.userSignal?.aborted) userStop();
			child.stdin.end(childPrompt(agent));
		});
	} catch (error) {
		return { status: opts.signal?.aborted ? "aborted" : "failed", output: String(error), usage };
	} finally {
		if (temporary) fs.rmSync(temporary, { recursive: true, force: true });
	}
}

// One limiter is shared by every invocation owned by the extension instance.
export class Limiter {
	private active = 0;
	private waiting: (() => void)[] = [];
	constructor(private readonly maximum = 4) {}
	async run<T>(work: () => Promise<T>, signal?: AbortSignal): Promise<T> {
		let admitted = true;
		if (this.active >= this.maximum) {
			admitted = await new Promise<boolean>((done) => {
				const grant = () => {
					signal?.removeEventListener("abort", cancel);
					done(true);
				};
				const cancel = () => {
					const index = this.waiting.indexOf(grant);
					if (index >= 0) this.waiting.splice(index, 1);
					signal?.removeEventListener("abort", cancel);
					done(false);
				};
				this.waiting.push(grant);
				signal?.addEventListener("abort", cancel, { once: true });
				if (signal?.aborted) cancel();
			});
		} else this.active++;
		// Cancelled waiters still finalize their controlled result without a process slot.
		if (!admitted) return work();
		try {
			return await work();
		} finally {
			const next = this.waiting.shift();
			if (next) next();
			else this.active--;
		}
	}
}
