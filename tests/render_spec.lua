local h = require("helpers")
local render = require("pim.ui.render")

local function assistant(content, extra)
	local msg = { role = "assistant", content = content }
	for key, value in pairs(extra or {}) do
		msg[key] = value
	end
	return msg
end

return {
	["user message with plain string content"] = function()
		local block = render.message({ role = "user", content = "fix the bug\nin foo.ts" })
		h.eq({ "### You", "", "fix the bug", "in foo.ts" }, block.lines)
		h.eq({}, block.folds)
	end,

	["user message with content blocks and an image"] = function()
		local block = render.message({
			role = "user",
			content = {
				{ type = "text", text = "look at this" },
				{ type = "image", mimeType = "image/png", data = "..." },
			},
		})
		h.eq({ "### You", "", "look at this", "[image: image/png]" }, block.lines)
	end,

	["assistant text renders as markdown body"] = function()
		local block = render.message(assistant({ { type = "text", text = "Here is `code`.\n\nDone." } }))
		h.eq({ "### pi", "", "Here is `code`.", "", "Done." }, block.lines)
		h.eq({}, block.folds)
	end,

	["assistant thinking gets a quoted fold"] = function()
		local block = render.message(assistant({
			{ type = "thinking", thinking = "step one\nstep two" },
			{ type = "text", text = "answer" },
		}))
		h.eq({ "### pi", "", "▸ thinking", "> step one", "> step two", "", "answer" }, block.lines)
		h.eq({ { first = 2, last = 4, kind = "thinking" } }, block.folds)
	end,

	["redacted thinking hides the payload"] = function()
		local block = render.message(assistant({
			{ type = "thinking", thinking = "secret", redacted = true },
		}))
		h.eq({ "### pi", "", "▸ thinking", "> (redacted)" }, block.lines)
	end,

	["assistant toolCall renders a header line with compact args"] = function()
		local block = render.message(assistant({
			{ type = "toolCall", id = "t1", name = "bash", arguments = { command = "ls -la" } },
		}))
		h.eq({ "### pi", "", '▸ tool: bash {"command":"ls -la"}' }, block.lines)
	end,

	["aborted assistant message is marked"] = function()
		local block = render.message(assistant({ { type = "text", text = "partial" } }, { stopReason = "aborted" }))
		h.eq({ "### pi", "", "partial", "", "*(aborted)*" }, block.lines)
	end,

	["errored assistant message shows the error"] = function()
		local block = render.message(assistant({}, { stopReason = "error", errorMessage = "rate limited" }))
		h.eq({ "### pi", "", "**error:** rate limited" }, block.lines)
	end,

	["tool result renders fenced output under a fold"] = function()
		local block = render.message({
			role = "toolResult",
			toolCallId = "t1",
			toolName = "bash",
			isError = false,
			content = { { type = "text", text = "file-a\nfile-b" } },
		})
		h.eq({ "▸ result: bash", "```", "file-a", "file-b", "```" }, block.lines)
		h.eq({ { first = 0, last = 4, kind = "tool" } }, block.folds)
	end,

	["tool result error is marked in the header"] = function()
		local block = render.message({
			role = "toolResult",
			toolName = "read",
			isError = true,
			content = { { type = "text", text = "no such file" } },
		})
		h.eq("▸ result: read ✘ error", block.lines[1])
	end,

	["empty tool result has no fence and no fold"] = function()
		local block = render.message({ role = "toolResult", toolName = "noop", isError = false, content = {} })
		h.eq({ "▸ result: noop" }, block.lines)
		h.eq({}, block.folds)
	end,

	["tool output containing a fence gets a longer fence"] = function()
		local block = render.message({
			role = "toolResult",
			toolName = "read",
			isError = false,
			content = { { type = "text", text = "```lua\nprint(1)\n```" } },
		})
		h.eq("````", block.lines[2])
		h.eq("````", block.lines[#block.lines])
	end,

	["bash execution shows exit code and truncation"] = function()
		local block = render.message({
			role = "bashExecution",
			command = "make build",
			output = "boom",
			exitCode = 2,
			cancelled = false,
			truncated = true,
		})
		h.eq("▸ ! make build [exit 2]", block.lines[1])
		h.eq("[output truncated]", block.lines[#block.lines - 1])
		h.eq({ { first = 0, last = #block.lines - 1, kind = "tool" } }, block.folds)
	end,

	["newline-terminated output does not gain a blank line in the fence"] = function()
		local block = render.message({
			role = "bashExecution",
			command = "echo hi",
			output = "hi\n",
			exitCode = 0,
		})
		h.eq({ "▸ ! echo hi", "```", "hi", "```" }, block.lines)
	end,

	["deliberate blank lines inside output are kept"] = function()
		local block = render.message({
			role = "bashExecution",
			command = "printf",
			output = "one\n\ntwo\n",
			exitCode = 0,
		})
		h.eq({ "▸ ! printf", "```", "one", "", "two", "```" }, block.lines)
	end,

	["cancelled bash execution is marked"] = function()
		local block = render.message({
			role = "bashExecution",
			command = "sleep 100",
			output = "",
			cancelled = true,
		})
		h.eq({ "▸ ! sleep 100 [cancelled]" }, block.lines)
	end,

	["custom message with display=false renders nothing"] = function()
		local block = render.message({ role = "custom", customType = "hook", content = "hidden", display = false })
		h.eq({}, block.lines)
	end,

	["custom message with display=true renders under its type"] = function()
		local block =
			render.message({ role = "custom", customType = "notes", content = "remember this", display = true })
		h.eq({ "### notes", "", "remember this" }, block.lines)
	end,

	["branch summary folds its quote"] = function()
		local block = render.message({ role = "branchSummary", summary = "tried X\nit failed", fromId = "abc" })
		h.eq({ "▸ branch summary", "> tried X", "> it failed" }, block.lines)
		h.eq({ { first = 0, last = 2, kind = "summary" } }, block.folds)
	end,

	["compaction summary shows token count"] = function()
		local block = render.message({ role = "compactionSummary", summary = "history", tokensBefore = 52000 })
		h.eq({ "▸ compacted (52000 tokens before)", "> history" }, block.lines)
		h.eq({ { first = 0, last = 1, kind = "summary" } }, block.folds)
	end,

	["unknown role renders a visible stub"] = function()
		local block = render.message({ role = "notification" })
		h.eq({ "▸ notification message" }, block.lines)
	end,

	["an unknown assistant content block renders a stub, not a blank"] = function()
		local block = render.message(assistant({
			{ type = "text", text = "before" },
			{ type = "redactedThinking", data = "opaque" },
			{ type = "text", text = "after" },
		}))
		h.eq({ "### pi", "", "before", "", "▸ redactedThinking block", "", "after" }, block.lines)
	end,

	["an unknown assistant block on its own still renders"] = function()
		local block = render.message(assistant({ { type = "serverToolUse", name = "web_search" } }))
		h.eq({ "### pi", "", "▸ serverToolUse block" }, block.lines)
	end,

	["an unknown block in content_to_text renders a stub"] = function()
		local block = render.message({
			role = "user",
			content = {
				{ type = "text", text = "hi" },
				{ type = "document", name = "spec.pdf" },
			},
		})
		h.eq({ "### You", "", "hi", "[document block]" }, block.lines)
	end,

	["args summary truncates long arguments"] = function()
		local summary = render.args_summary({ command = string.rep("x", 200) })
		h.ok(vim.fn.strchars(summary) <= 72, "summary should be truncated to 72 chars")
		h.ok(summary:find("…", 1, true), "truncation marker present")
	end,

	["args summary is empty for empty arguments"] = function()
		h.eq("", render.args_summary({}))
		h.eq("", render.args_summary(nil))
	end,

	["empty thinking blocks are not rendered"] = function()
		local block = render.message(assistant({
			{ type = "thinking", thinking = "  " },
			{ type = "text", text = "answer" },
		}))
		h.eq({ "### pi", "", "answer" }, block.lines)
		h.eq({}, block.folds)
	end,

	["hidden thinking is omitted entirely"] = function()
		local block = render.message(
			assistant({ { type = "thinking", thinking = "hmm" }, { type = "text", text = "answer" } }),
			{ thinking = "hidden" }
		)
		h.eq({ "### pi", "", "answer" }, block.lines)
		h.eq({}, block.folds)
	end,

	["running tool execution shows status and streamed output"] = function()
		local block = render.tool_execution({
			toolName = "bash",
			running = true,
			result = { content = { { type = "text", text = "file-a" } } },
		})
		h.eq({ "▸ result: bash [running]", "```", "file-a", "```" }, block.lines)
		h.eq({ { first = 0, last = 3, kind = "tool" } }, block.folds)
	end,

	["finished tool execution drops the running marker"] = function()
		local block = render.tool_execution({ toolName = "bash", result = "done" })
		h.eq("▸ result: bash", block.lines[1])
	end,

	["failed tool execution is marked"] = function()
		local block = render.tool_execution({ toolName = "bash", isError = true, result = "boom" })
		h.eq("▸ result: bash ✘ error", block.lines[1])
	end,

	["tool execution with no output has no fence"] = function()
		local block = render.tool_execution({ toolName = "noop", running = true })
		h.eq({ "▸ result: noop [running]" }, block.lines)
		h.eq({}, block.folds)
	end,

	["tool execution tolerates ad-hoc result shapes"] = function()
		h.eq({ "▸ result: t", "```", "raw", "```" }, render.tool_execution({ toolName = "t", result = "raw" }).lines)
		h.eq(
			{ "▸ result: t", "```", "out", "```" },
			render.tool_execution({ toolName = "t", result = { output = "out" } }).lines
		)
	end,
}
