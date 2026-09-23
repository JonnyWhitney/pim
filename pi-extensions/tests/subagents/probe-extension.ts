import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
	pi.on("session_start", (_event, ctx) => {
		process.stdout.write(
			JSON.stringify({ type: "pim_test_probe", mode: ctx.mode, tools: pi.getActiveTools() }) + "\n",
		);
	});
}
