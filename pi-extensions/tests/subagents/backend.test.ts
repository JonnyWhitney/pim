import { test } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import extension from "../../subagents/index.ts";
import { Backend } from "../../subagents/backend.ts";
import {
	validate,
	truncate,
	isDetails,
	type Agent,
	type Details,
} from "../../subagents/protocol.ts";
import {
	childArgs,
	childEnvironment,
	childPrompt,
	Limiter,
	runChild,
} from "../../subagents/runner.ts";
import {
	privateRoot,
	readRecords,
	safeId,
	TranscriptStore,
} from "../../subagents/transcript-store.ts";

const fixture = JSON.parse(
	fs.readFileSync(
		new URL("../../../tests/fixtures/subagents/parameters.json", import.meta.url),
		"utf8",
	),
);
const agent: Agent = { ...fixture.agents[0], projectContext: false };
const invocation = (args: string[]) => ({
	command: process.execPath,
	args: [fileURLToPath(new URL("./fake-child.mjs", import.meta.url)), ...args],
});
const cwd = fs.realpathSync(process.cwd());
function temporary(t: { after: (fn: () => void) => void }) {
	const root = fs.mkdtempSync(join(fs.realpathSync(tmpdir()), "pim-test-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	return root;
}
function options(root: string) {
	return {
		root,
		parentSessionId: "parent-123",
		parentSessionFile: "/sessions/parent.jsonl",
		toolCallId: "call-123",
		cwd,
		trusted: false,
		invocation,
	};
}

test("shared parameter fixture and strict schema are validated", () => {
	assert.equal(validate(fixture).agents.length, 1);
	const details = JSON.parse(
		fs.readFileSync(
			new URL("../../../tests/fixtures/subagents/details.json", import.meta.url),
			"utf8",
		),
	);
	assert.ok(isDetails(details));
	assert.ok(!isDetails({ ...details, schemaVersion: 2 }));
	assert.ok(!isDetails({ ...details, agents: [{}] }));
	for (const field of ["label", "prompt", "tools", "model", "thinkingLevel"]) {
		const invalid = { ...agent } as Record<string, unknown>;
		delete invalid[field];
		assert.throws(() => validate({ agents: [invalid] }));
	}
	for (const invalid of [
		{ ...agent, model: "sonnet" },
		{ ...agent, thinkingLevel: "auto" },
		{ ...agent, tools: ["subagent"] },
		{ ...agent, tools: ["read,bash"] },
		{ ...agent, label: " " },
		{ ...agent, systemPromptMode: "replace", systemPrompt: " " },
		{ ...agent, unknown: true },
	]) {
		assert.throws(() => validate({ agents: [invalid] }));
	}
	assert.throws(() => validate({ agents: [] }));
	assert.throws(() => validate({ agents: Array.from({ length: 9 }, () => ({ ...agent })) }));
	assert.equal(validate({ agents: [{ ...agent, tools: [] }] }).agents[0].tools.length, 0);
});

test("parallel preflight rejects every mutating or unknown tool before storage", async (t) => {
	const root = temporary(t);
	for (const tool of ["bash", "edit", "write", "extension_tool", "subagent"]) {
		await assert.rejects(
			new Backend().execute({ agents: [agent, { ...agent, tools: [tool] }] }, options(root)),
		);
	}
	assert.deepEqual(fs.readdirSync(root), []);
});

test("identifiers, symlinks, permissions, framing, and atomic replacement are protected", (t) => {
	const root = temporary(t);
	for (const id of ["..", "a/b", "/absolute", "x\\y", "", ".hidden"])
		assert.throws(() => safeId(id));
	const outside = join(root, "outside");
	fs.mkdirSync(outside);
	const linked = join(root, "linked");
	fs.symlinkSync(outside, linked);
	assert.throws(() => privateRoot(linked));
	assert.throws(() => new TranscriptStore(root, "linked", null, "call", [agent]));
	const store = new TranscriptStore(root, "parent", null, "call", [agent]);
	assert.equal(fs.statSync(store.manifest.transcriptDir).mode & 0o777, 0o700);
	const path = store.manifest.agents[0].transcriptPath;
	assert.equal(fs.statSync(path).mode & 0o777, 0o600);
	store.append(0, { text: "one\ntwo\u2028three" });
	const records = readRecords(fs.readFileSync(path, "utf8") + 'bad\n{"partial":');
	assert.equal(records.records.length, 2);
	assert.equal(records.errors, 1);
	assert.equal(records.pending, '{"partial":');
	store.manifest.status = "completed";
	store.save();
	assert.equal(
		JSON.parse(fs.readFileSync(join(store.manifest.transcriptDir, "invocation.json"), "utf8"))
			.status,
		"completed",
	);
	assert.equal(
		fs.statSync(join(store.manifest.transcriptDir, "invocation.json")).mode & 0o777,
		0o600,
	);
	assert.equal(
		fs.readdirSync(store.manifest.transcriptDir).some((name) => name.endsWith(".tmp")),
		false,
	);
	fs.unlinkSync(path);
	fs.symlinkSync(join(outside, "victim"), path);
	assert.throws(() => store.append(0, {}));
	assert.equal(fs.existsSync(join(outside, "victim")), false);
});

test("output truncation includes its notice within byte and line limits", () => {
	assert.equal(truncate("hello"), "hello");
	for (const text of ["🙂".repeat(30000), "line\n".repeat(3000)]) {
		const result = truncate(text);
		assert.ok(Buffer.byteLength(result) <= 50 * 1024);
		assert.ok(result.split("\n").length <= 2000);
		assert.ok(result.includes("truncated"));
		assert.ok(!result.includes("�"));
	}
});

test("argument construction enforces trust, isolation, explicit tools and prompts", (t) => {
	const opts = { cwd, trusted: true, parallel: false };
	const args = childArgs({ ...agent, projectContext: true }, opts, "/private/prompt.md");
	assert.ok(args.includes("--approve"));
	assert.ok(args.includes("--append-system-prompt"));
	assert.ok(args.includes("--no-session"));
	assert.equal(args[args.indexOf("--exclude-tools") + 1], "subagent");
	assert.ok(!args.includes(agent.prompt));
	const isolated = childArgs(
		{ ...agent, tools: [], systemPromptMode: "replace" },
		opts,
		"/private/prompt.md",
	);
	for (const flag of [
		"--no-tools",
		"--no-context-files",
		"--no-extensions",
		"--no-skills",
		"--no-prompt-templates",
		"--no-approve",
		"--system-prompt",
	])
		assert.ok(isolated.includes(flag));
	const other = temporary(t);
	assert.ok(
		childArgs({ ...agent, projectContext: true, cwd: other }, opts).includes("--no-approve"),
	);
	assert.ok(
		childArgs({ ...agent, projectContext: true }, { ...opts, trusted: false }).includes(
			"--no-approve",
		),
	);
	assert.ok(
		childArgs({ ...agent, projectContext: true }, { ...opts, parallel: true }).includes(
			"--no-extensions",
		),
	);
	assert.ok(childPrompt(agent).includes("Caller context (JSON string):"));
	assert.equal(childEnvironment(agent).PIM_HOST, undefined);
});

test("single completion stores events, removes prompt files and returns nested usage", async (t) => {
	const root = temporary(t);
	const updates: Details[] = [];
	const result = await new Backend().execute(
		{ agents: [agent] },
		{ ...options(root), onUpdate: (details) => updates.push(details) },
	);
	assert.equal(result.details.status, "completed");
	assert.ok(isDetails(result.details));
	assert.equal(result.usage.totalTokens, 28);
	assert.equal(result.usage.cost.total, 2);
	assert.ok(result.content[0].text.includes("answer α\u2028β\u2029γ"));
	const records = readRecords(fs.readFileSync(result.details.agents[0].transcriptPath, "utf8"))
		.records as { record: Record<string, unknown> }[];
	const probe = records.find((item) => item.record.type === "configuration_probe")!.record;
	assert.equal(probe.system, agent.systemPrompt);
	assert.equal(probe.permissions, 0o600);
	assert.equal(typeof probe.systemFile, "string");
	assert.equal(fs.existsSync(probe.systemFile as string), false);
	assert.equal(probe.host, null);
	assert.equal(probe.root, null);
	assert.ok(records.some((item) => item.record.type === "message_update"));
	assert.ok(records.some((item) => item.record.type === "final"));
	assert.ok(updates.some((update) => update.agents[0].status === "running"));
	assert.equal(updates[0].agents[0].status, "pending");
	assert.ok(JSON.stringify(updates).length < 15000);
});

test("provider failures, malformed output, interrupted output and unavailable tools are diagnosed", async () => {
	for (const [prompt, expected] of [
		["failure", "Provider failed"],
		["malformed", "Malformed"],
		["interrupted", "Interrupted"],
		["unavailable", "Unavailable"],
	]) {
		const result = await runChild(
			{ ...agent, prompt },
			{ cwd, trusted: false, parallel: false, invocation, onRecord() {} },
		);
		assert.equal(result.status, "failed");
		assert.ok(result.output.includes(expected), result.output);
	}
	const result = await runChild(agent, {
		cwd,
		trusted: false,
		parallel: false,
		invocation: (args) => ({ command: "/missing/pim-child", args }),
		onRecord() {},
	});
	assert.equal(result.status, "failed");
	assert.ok(result.output.includes("could not be started"));
});

test("parallel results preserve input ordering and independent failure with aggregate caps", async (t) => {
	const root = temporary(t);
	const agents = [
		"slow large",
		"failure",
		"large",
		"large",
		"large",
		"large",
		"large",
		"large",
	].map((prompt, i) => ({ ...agent, label: `child-${i}`, prompt }));
	const updates: Details[] = [];
	const result = await new Backend().execute(
		{ agents },
		{ ...options(root), onUpdate: (details) => updates.push(details) },
	);
	assert.deepEqual(
		result.details.agents.map((child) => child.label),
		agents.map((child) => child.label),
	);
	assert.equal(result.details.agents[0].status, "completed");
	assert.equal(result.details.agents[1].status, "failed");
	assert.equal(result.details.agents[7].status, "completed");
	assert.equal(result.usage.totalTokens, 224);
	assert.ok(Buffer.byteLength(result.content[0].text) <= 50 * 1024);
	assert.ok(result.content[0].text.includes("truncated"));
	assert.ok(
		updates.every(
			(update) => update.agents.filter((child) => child.status === "running").length <= 4,
		),
	);
	assert.ok(updates.every((update) => JSON.stringify(update).length < 15000));
});

test("limiter is shared across overlapping work", async () => {
	const limiter = new Limiter();
	let active = 0,
		maximum = 0;
	const results = await Promise.all(
		Array.from({ length: 12 }, (_, index) =>
			limiter.run(async () => {
				active++;
				maximum = Math.max(maximum, active);
				await new Promise((done) => setTimeout(done, 5));
				active--;
				return index;
			}),
		),
	);
	assert.equal(maximum, 4);
	assert.deepEqual(
		results,
		Array.from({ length: 12 }, (_, index) => index),
	);
});

test("parent abort escalates despite SIGTERM being ignored and prevents queued children", async (t) => {
	const root = temporary(t);
	const controller = new AbortController();
	let running = 0;
	const timer = setTimeout(() => controller.abort(), 300);
	t.after(() => clearTimeout(timer));
	const result = await new Backend().execute(
		{ agents: Array.from({ length: 8 }, () => ({ ...agent, prompt: "hang" })) },
		{
			...options(root),
			signal: controller.signal,
			stopTimeout: 30,
			onUpdate: (details) => {
				running = Math.max(
					running,
					details.agents.filter((child) => child.status === "running").length,
				);
			},
		},
	);
	assert.equal(running, 4);
	assert.ok(
		result.details.agents.every(
			(child) => child.status === "aborted" && child.stoppedBy === "parent_abort",
		),
	);
	for (const child of result.details.agents) {
		const records = readRecords(fs.readFileSync(child.transcriptPath, "utf8")).records as {
			record: { type: string; pid?: number };
		}[];
		const ready = records.find((item) => item.record.type === "ready");
		if (ready) assert.throws(() => process.kill(ready.record.pid!, 0));
	}
	const preAborted = await runChild(agent, {
		cwd,
		trusted: false,
		parallel: false,
		signal: controller.signal,
		invocation: () => {
			throw new Error("must not spawn");
		},
		onRecord() {},
	});
	assert.equal(preAborted.status, "aborted");
});

test("extension activation fails closed outside the PIM RPC host", (t) => {
	const host = process.env.PIM_HOST,
		root = process.env.PIM_SUBAGENT_ROOT;
	t.after(() => {
		if (host === undefined) delete process.env.PIM_HOST;
		else process.env.PIM_HOST = host;
		if (root === undefined) delete process.env.PIM_SUBAGENT_ROOT;
		else process.env.PIM_SUBAGENT_ROOT = root;
	});
	const handlers = new Map<string, Function>();
	let registrations = 0;
	const pi = {
		on: (name: string, handler: Function) => handlers.set(name, handler),
		registerTool: () => registrations++,
	} as unknown as ExtensionAPI;
	delete process.env.PIM_HOST;
	extension(pi);
	assert.equal(handlers.size, 0);
	process.env.PIM_HOST = "1";
	delete process.env.PIM_SUBAGENT_ROOT;
	extension(pi);
	assert.equal(handlers.size, 0);
	process.env.PIM_SUBAGENT_ROOT = resolve("/tmp/pim");
	extension(pi);
	for (const mode of ["tui", "json", "print"]) handlers.get("session_start")!({}, { mode });
	assert.equal(registrations, 0);
	handlers.get("session_start")!({}, { mode: "rpc" });
	assert.equal(registrations, 1);
});
