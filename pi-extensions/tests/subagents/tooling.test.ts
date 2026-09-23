import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

const guard = new URL("../../scripts/check-node.mjs", import.meta.url).href;

test("the pinned LTS development line is enforced", () => {
	for (const [version, supported] of [
		["22.0.0", false],
		["24.20.0", false],
		["24.21.0", true],
		["24.22.0", true],
		["26.9.0", false],
	] as const) {
		const result = spawnSync(
			process.execPath,
			[
				"--input-type=module",
				"--eval",
				`Object.defineProperty(process.versions, "node", { value: ${JSON.stringify(version)} }); await import(${JSON.stringify(guard)});`,
			],
			{ encoding: "utf8" },
		);
		assert.equal(result.status, supported ? 0 : 1, result.stderr);
		if (!supported) assert.match(result.stderr, /Node.js \^24\.21\.0 is required/);
	}
});
