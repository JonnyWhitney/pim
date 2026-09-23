import { readFileSync } from "node:fs";

const { engines } = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const minimum = engines.node.slice(1).split(".").map(Number);
const actual = process.versions.node.split(".").map(Number);
const supported =
	actual[0] === minimum[0] &&
	(actual[1] > minimum[1] || (actual[1] === minimum[1] && actual[2] >= minimum[2]));

if (!supported) {
	console.error(
		`Node.js ${engines.node} is required for development; ${process.versions.node} was found. Run commands through mise.`,
	);
	process.exit(1);
}
