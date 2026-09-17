import { Type, type Static } from "typebox";
import { Check } from "typebox/value";
import type { Usage } from "@earendil-works/pi-ai";

const enumString = <T extends string>(values: T[]) =>
	Type.Unsafe<T>({ type: "string", enum: values });
export const AgentSchema = Type.Object(
	{
		label: Type.String({ minLength: 1, maxLength: 200 }),
		prompt: Type.String({ minLength: 1 }),
		tools: Type.Array(Type.String({ pattern: "^[A-Za-z0-9_.-]+$" }), { uniqueItems: true }),
		model: Type.String({ pattern: "^[^/\\s*?]+/[^\\s*?]+$" }),
		thinkingLevel: enumString(["off", "minimal", "low", "medium", "high", "xhigh", "max"]),
		systemPrompt: Type.Optional(Type.String()),
		systemPromptMode: Type.Optional(enumString(["append", "replace"])),
		context: Type.Optional(Type.String()),
		projectContext: Type.Optional(Type.Boolean()),
		cwd: Type.Optional(Type.String({ minLength: 1 })),
	},
	{ additionalProperties: false },
);
export const Parameters = Type.Object(
	{
		agents: Type.Array(AgentSchema, { minItems: 1, maxItems: 8 }),
	},
	{ additionalProperties: false },
);
export type Agent = Static<typeof AgentSchema>;
export type Params = Static<typeof Parameters>;
export type Status = "pending" | "running" | "completed" | "failed" | "stopped" | "aborted";
export interface Child {
	id: string;
	label: string;
	status: Status;
	transcriptPath: string;
	summary: string | null;
	usage: Usage | null;
	stoppedBy: "user" | "parent_abort" | null;
}
export interface Details {
	schemaVersion: 1;
	invocationId: string;
	mode: "single" | "parallel";
	status: Status;
	transcriptDir: string;
	agents: Child[];
}
const StatusSchema = enumString([
	"pending",
	"running",
	"completed",
	"failed",
	"stopped",
	"aborted",
]);
const UsageSchema = Type.Object({
	input: Type.Number(),
	output: Type.Number(),
	cacheRead: Type.Number(),
	cacheWrite: Type.Number(),
	totalTokens: Type.Number(),
	cost: Type.Object({
		input: Type.Number(),
		output: Type.Number(),
		cacheRead: Type.Number(),
		cacheWrite: Type.Number(),
		total: Type.Number(),
	}),
});
export const DetailsSchema = Type.Object({
	schemaVersion: Type.Literal(1),
	invocationId: Type.String(),
	mode: enumString(["single", "parallel"]),
	status: StatusSchema,
	transcriptDir: Type.String(),
	agents: Type.Array(
		Type.Object({
			id: Type.String(),
			label: Type.String(),
			status: StatusSchema,
			transcriptPath: Type.String(),
			summary: Type.Union([Type.String(), Type.Null()]),
			usage: Type.Union([UsageSchema, Type.Null()]),
			stoppedBy: Type.Union([enumString(["user", "parent_abort"]), Type.Null()]),
		}),
		{ minItems: 1, maxItems: 8 },
	),
});
export function isDetails(value: unknown): value is Details {
	return Check(DetailsSchema, value);
}
export interface Manifest extends Details {
	parentSessionId: string;
	parentSessionFile: string | null;
	toolCallId: string;
	createdAt: string;
	updatedAt: string;
}
export function validate(value: unknown): Params {
	if (!Check(Parameters, value))
		throw new Error(
			"Invalid subagent parameters; explicit label, prompt, tools, provider/model and thinkingLevel are required.",
		);
	for (const agent of value.agents) {
		if (!agent.label.trim() || !agent.prompt.trim())
			throw new Error("Label and prompt must not be empty.");
		if (agent.systemPromptMode === "replace" && !agent.systemPrompt?.trim())
			throw new Error("A nonempty replacement system prompt is required.");
		if (agent.tools.includes("subagent")) throw new Error("Nested subagents are not permitted.");
		if (
			value.agents.length > 1 &&
			agent.tools.some((tool) => !["read", "grep", "find", "ls"].includes(tool))
		) {
			throw new Error("Parallel tools are restricted to read, grep, find, ls.");
		}
	}
	return value;
}
export function truncate(text: string, cap = 50 * 1024): string {
	const suffix = "\n[Output truncated; full output is stored in the child transcript.]";
	if (Buffer.byteLength(text) <= cap && text.split("\n").length <= 2000) return text;
	let result = text.split("\n").slice(0, 1998).join("\n");
	const bytes = Buffer.from(result);
	let end = Math.min(bytes.length, cap - Buffer.byteLength(suffix));
	while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--;
	result = bytes.subarray(0, end).toString("utf8");
	return result + suffix;
}
export function emptyUsage(): Usage {
	return {
		input: 0,
		output: 0,
		cacheRead: 0,
		cacheWrite: 0,
		totalTokens: 0,
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
	};
}
export function addUsage(total: Usage, value: Usage | null | undefined): void {
	if (!value) return;
	for (const key of ["input", "output", "cacheRead", "cacheWrite", "totalTokens"] as const) {
		if (Number.isFinite(value[key])) total[key] += value[key];
	}
	for (const key of ["input", "output", "cacheRead", "cacheWrite", "total"] as const) {
		if (Number.isFinite(value.cost?.[key])) total.cost[key] += value.cost[key];
	}
}
