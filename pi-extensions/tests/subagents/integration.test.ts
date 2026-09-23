import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { runChild } from "../../subagents/runner.ts";

const cli = fileURLToPath(
	new URL("../../node_modules/@earendil-works/pi-coding-agent/dist/cli.js", import.meta.url),
);
const backend = fileURLToPath(new URL("../../subagents/index.ts", import.meta.url));
const probe = fileURLToPath(new URL("./probe-extension.ts", import.meta.url));

test(
	"real child policy rejects unavailable tools before a provider request",
	{ timeout: 15000 },
	async (t) => {
		const root = fs.mkdtempSync(join(fs.realpathSync(tmpdir()), "pim-child-policy-"));
		const previous = process.env.PI_CODING_AGENT_DIR;
		process.env.PI_CODING_AGENT_DIR = root;
		t.after(() => {
			if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previous;
			fs.rmSync(root, { recursive: true, force: true });
		});
		const result = await runChild(
			{
				label: "policy",
				prompt: "No provider request should be made.",
				tools: ["missing_pim_tool"],
				model: "anthropic/claude-sonnet-4-6",
				thinkingLevel: "off",
				projectContext: false,
			},
			{
				cwd: root,
				trusted: false,
				parallel: false,
				signal: AbortSignal.timeout(10000),
				invocation: (args) => ({ command: process.execPath, args: [cli, "--offline", ...args] }),
				onRecord() {},
			},
		);
		assert.equal(result.status, "failed");
		assert.ok(result.output.includes("Unavailable child tools: missing_pim_tool"), result.output);
	},
);

test(
	"real Pi loads the bundle and activates its tool only for the PIM RPC host",
	{ timeout: 20000 },
	async (t) => {
		const root = fs.mkdtempSync(join(fs.realpathSync(tmpdir()), "pim-integration-"));
		t.after(() => fs.rmSync(root, { recursive: true, force: true }));
		for (const enabled of [true, false]) {
			const env = {
				...process.env,
				PI_CODING_AGENT_DIR: root,
				PI_OFFLINE: "1",
				PIM_SUBAGENT_ROOT: join(root, "transcripts"),
				PIM_HOST: enabled ? "1" : "0",
			};
			const child = spawn(
				process.execPath,
				[
					cli,
					"--mode",
					"rpc",
					"--offline",
					"--no-session",
					"--no-approve",
					"--no-extensions",
					"--no-skills",
					"--no-context-files",
					"--extension",
					backend,
					"--extension",
					probe,
				],
				{ env, cwd: root, stdio: ["pipe", "pipe", "pipe"] },
			);
			t.after(() => child.kill("SIGKILL"));
			let stderr = "",
				buffer = "";
			child.stderr.setEncoding("utf8");
			child.stderr.on("data", (data) => {
				stderr += data;
			});
			const tools = await new Promise<string[]>((done, reject) => {
				const timer = setTimeout(() => {
					child.kill("SIGKILL");
					reject(new Error(`Pi startup timed out: ${stderr}`));
				}, 8000);
				child.once("error", (error) => {
					clearTimeout(timer);
					reject(error);
				});
				child.once("close", (code) => {
					clearTimeout(timer);
					reject(new Error(`Pi exited ${code}: ${stderr}`));
				});
				child.stdout.setEncoding("utf8");
				const receive = (data: string) => {
					buffer += data;
					let end: number;
					while ((end = buffer.indexOf("\n")) >= 0) {
						const line = buffer.slice(0, end);
						buffer = buffer.slice(end + 1);
						try {
							const event = JSON.parse(line);
							if (event.type === "pim_test_probe") {
								clearTimeout(timer);
								done(event.tools);
							}
						} catch {
							/* Non-protocol startup diagnostics are checked through stderr. */
						}
					}
				};
				child.stdout.on("data", receive);
				// Pi redirects extension stdout to stderr during startup.
				child.stderr.on("data", receive);
			});
			assert.equal(tools.includes("subagent"), enabled, stderr);
			assert.ok(!stderr.includes("Failed to load extension"), stderr);
			if (enabled) {
				await new Promise<void>((done, reject) => {
					let pending = "",
						acknowledged = false,
						responded = false;
					const timer = setTimeout(() => reject(new Error("Stop acknowledgement timed out")), 3000);
					const receive = (data: string) => {
						pending += data;
						let end: number;
						while ((end = pending.indexOf("\n")) >= 0) {
							const event = JSON.parse(pending.slice(0, end));
							pending = pending.slice(end + 1);
							if (event.type === "extension_ui_request" && event.statusKey === "pim-agent-stop") {
								assert.deepEqual(JSON.parse(event.statusText), { token: "test-token", labels: [] });
								acknowledged = true;
							}
							if (event.type === "response" && event.id === "stop-test") {
								assert.equal(event.success, true);
								responded = true;
							}
						}
						if (acknowledged && responded) {
							clearTimeout(timer);
							child.stdout.off("data", receive);
							done();
						}
					};
					child.stdout.on("data", receive);
					child.stdin.write(
						JSON.stringify({
							id: "stop-test",
							type: "prompt",
							message: "/pim-internal-agent-stop test-token missing *",
						}) + "\n",
					);
				});
			}
			child.kill("SIGTERM");
			await new Promise<void>((done) => child.once("close", () => done()));
		}
	},
);
