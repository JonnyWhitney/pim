import fs from "node:fs";
let prompt = "";
for await (const chunk of process.stdin) prompt += chunk;
const args = process.argv.slice(2);
const send = (event) => process.stdout.write(JSON.stringify(event) + "\n");
if (/\bhang\b/.test(prompt)) {
	process.on("SIGTERM", () => {});
	send({ type: "ready", pid: process.pid });
	setInterval(() => {}, 1000);
} else if (prompt.includes("malformed")) {
	process.stdout.write("not json\n");
} else if (prompt.includes("interrupted")) {
	process.stdout.write('{"type":');
} else if (prompt.includes("unavailable")) {
	process.stderr.write("Unavailable child tools: missing\n");
	process.exitCode = 1;
} else {
	const systemIndex = args.findIndex((arg) =>
		["--system-prompt", "--append-system-prompt"].includes(arg),
	);
	const systemFile = systemIndex < 0 ? null : args[systemIndex + 1];
	send({
		type: "configuration_probe",
		args,
		prompt,
		cwd: process.cwd(),
		host: process.env.PIM_HOST ?? null,
		root: process.env.PIM_SUBAGENT_ROOT ?? null,
		policy: process.env.PIM_CHILD_POLICY,
		systemFile,
		system: systemFile && fs.readFileSync(systemFile, "utf8"),
		permissions: systemFile && fs.statSync(systemFile).mode & 0o777,
	});
	await new Promise((resolve) => setTimeout(resolve, prompt.includes("slow") ? 100 : 10));
	const text = prompt.includes("large") ? "🙂".repeat(30000) : "answer α\u2028β\u2029γ";
	const usage = {
		input: 2,
		output: 3,
		cacheRead: 4,
		cacheWrite: 5,
		totalTokens: 14,
		cost: { input: 0.1, output: 0.2, cacheRead: 0.3, cacheWrite: 0.4, total: 1 },
	};
	send({
		type: "message_update",
		message: { role: "assistant" },
		assistantMessageEvent: { type: "thinking_delta", delta: "reason" },
	});
	send({ type: "message_end", message: { role: "toolResult", usage, content: [] } });
	const serialized =
		JSON.stringify({
			type: "message_end",
			message: {
				role: "assistant",
				usage,
				stopReason: prompt.includes("failure") ? "error" : "stop",
				errorMessage: prompt.includes("failure") ? "Provider failed" : undefined,
				content: [{ type: "text", text }],
			},
		}) + "\n";
	const bytes = Buffer.from(serialized);
	const split = bytes.indexOf(Buffer.from("α")) + 1;
	process.stdout.write(bytes.subarray(0, split));
	setTimeout(() => process.stdout.write(bytes.subarray(split)), 5);
}
