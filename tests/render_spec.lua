local h = require("helpers")
local message_renderer = require("pim.render.message")
local tool_renderer = require("pim.render.tool")

local function assistant(content, extra)
	local msg = { role = "assistant", content = content }
	for key, value in pairs(extra or {}) do
		msg[key] = value
	end
	return msg
end

return {
	["user message with plain string content"] = function()
		local block = message_renderer.render({ role = "user", content = "fix the bug\nin foo.ts" })
		h.eq({ "### You", "", "fix the bug", "in foo.ts" }, block.lines)
		h.eq({}, block.folds)
	end,

	["user message with content blocks and an image"] = function()
		local block = message_renderer.render({
			role = "user",
			content = {
				{ type = "text", text = "look at this" },
				{ type = "image", mimeType = "image/png", data = "..." },
			},
		})
		h.eq({ "### You", "", "look at this", "[image: image/png]" }, block.lines)
	end,

	["assistant text renders as markdown body"] = function()
		local block = message_renderer.render(assistant({ { type = "text", text = "Here is `code`.\n\nDone." } }))
		h.eq({ "### pi", "", "Here is `code`.", "", "Done." }, block.lines)
		h.eq({}, block.folds)
	end,

	["assistant thinking gets a quoted fold"] = function()
		local block = message_renderer.render(assistant({
			{ type = "thinking", thinking = "step one\nstep two" },
			{ type = "text", text = "answer" },
		}))
		h.eq({ "### pi", "", "▸ thinking", "> step one", "> step two", "", "answer" }, block.lines)
		h.eq({ { first = 2, last = 4, kind = "thinking" } }, block.folds)
	end,

	["redacted thinking hides the payload"] = function()
		local block = message_renderer.render(assistant({
			{ type = "thinking", thinking = "secret", redacted = true },
		}))
		h.eq({ "### pi", "", "▸ thinking", "> (redacted)" }, block.lines)
	end,

	["assistant toolCall renders complete long arguments in a fold"] = function()
		local command = string.rep("x", 200)
		local block = message_renderer.render(assistant({
			{ type = "toolCall", id = "t1", name = "bash", arguments = { command = command } },
		}))
		h.eq({
			"### pi",
			"",
			("▸ tool(bash): %s"):format(command),
			"```json",
			"{",
			('  "command": "%s"'):format(command),
			"}",
			"```",
		}, block.lines)
		h.eq({ { first = 2, last = 7, kind = "tool" } }, block.folds)
	end,

	["assistant toolCall formats nested arguments as readable JSON"] = function()
		local arguments = { options = { paths = { "a", "b" } } }
		local block = message_renderer.render(assistant({
			{ type = "toolCall", id = "t1", name = "read", arguments = arguments },
		}))
		local encoded = table.concat(vim.list_slice(block.lines, 5, #block.lines - 1), "\n")
		h.eq(arguments, vim.json.decode(encoded), "rendered arguments should be valid JSON")
		h.eq('  "options": {', block.lines[6])
		h.eq('    "paths": [', block.lines[7])
	end,

	["built-in file tool calls show their supplied paths"] = function()
		for _, case in ipairs({
			{ name = "read", path = "src/read.lua" },
			{ name = "edit", path = "/tmp/edit.lua" },
			{ name = "write", path = "doc/write.txt" },
		}) do
			local block = message_renderer.render(assistant({
				{ type = "toolCall", id = case.name, name = case.name, arguments = { path = case.path } },
			}))
			h.eq(("▸ tool(%s): %s"):format(case.name, case.path), block.lines[3])
		end
	end,

	["legacy file_path is shown when path is absent"] = function()
		local block = message_renderer.render(assistant({
			{ type = "toolCall", id = "t1", name = "read", arguments = { file_path = "legacy.lua" } },
		}))
		h.eq("▸ tool(read): legacy.lua", block.lines[3])
	end,

	["multiline bash context uses the first non-empty line"] = function()
		local block = message_renderer.render(assistant({
			{ type = "toolCall", id = "t1", name = "bash", arguments = { command = "\n  mise test  \n\necho done" } },
		}))
		h.eq("▸ tool(bash): mise test … (+1 lines)", block.lines[3])
	end,

	["assistant toolCall without arguments stays header-only"] = function()
		local block = message_renderer.render(assistant({
			{ type = "toolCall", id = "t1", name = "noop", arguments = {} },
		}))
		h.eq({ "### pi", "", "▸ tool(noop)" }, block.lines)
		h.eq({}, block.folds)
	end,

	["aborted assistant message is marked"] = function()
		local block =
			message_renderer.render(assistant({ { type = "text", text = "partial" } }, { stopReason = "aborted" }))
		h.eq({ "### pi", "", "partial", "", "*(aborted)*" }, block.lines)
	end,

	["errored assistant message shows the error"] = function()
		local block = message_renderer.render(assistant({}, { stopReason = "error", errorMessage = "rate limited" }))
		h.eq({ "### pi", "", "**error:** rate limited" }, block.lines)
	end,

	["tool result renders fenced output under a fold"] = function()
		local block = message_renderer.render({
			role = "toolResult",
			toolCallId = "t1",
			toolName = "bash",
			isError = false,
			content = { { type = "text", text = "file-a\nfile-b" } },
		})
		h.eq({ "▸ result(bash)", "```", "file-a", "file-b", "```" }, block.lines)
		h.eq({ { first = 0, last = 4, kind = "tool" } }, block.folds)
	end,

	["tool result error is marked in the header"] = function()
		local block = message_renderer.render({
			role = "toolResult",
			toolName = "read",
			isError = true,
			content = { { type = "text", text = "no such file" } },
		})
		h.eq("▸ result(read) ✘ error", block.lines[1])
	end,

	["empty tool result has no fence and no fold"] = function()
		local block = message_renderer.render({ role = "toolResult", toolName = "noop", isError = false, content = {} })
		h.eq({ "▸ result(noop)" }, block.lines)
		h.eq({}, block.folds)
	end,

	["tool results reuse call context"] = function()
		local cases = {
			{ name = "read", arguments = { path = "src/read.lua" }, context = "src/read.lua" },
			{ name = "edit", arguments = { path = "/tmp/edit.lua" }, context = "/tmp/edit.lua" },
			{ name = "write", arguments = { path = "doc/write.txt" }, context = "doc/write.txt" },
			{ name = "bash", arguments = { command = "mise test\necho done" }, context = "mise test … (+1 lines)" },
		}
		for _, case in ipairs(cases) do
			local block = message_renderer.render({
				role = "toolResult",
				toolCallId = case.name,
				toolName = case.name,
				content = {},
			}, { tool_arguments = { [case.name] = case.arguments } })
			h.eq(("▸ result(%s): %s"):format(case.name, case.context), block.lines[1])
		end
	end,

	["historical and live tool results share one rendering shape"] = function()
		local arguments = { path = "src/read.lua" }
		local result = { content = { { type = "text", text = "file contents" } } }
		local historical = message_renderer.render({
			role = "toolResult",
			toolCallId = "t1",
			toolName = "read",
			content = result.content,
		}, { tool_arguments = { t1 = arguments } })
		local live = tool_renderer.execution({
			toolName = "read",
			args = arguments,
			result = result,
		})

		h.eq(live, historical)
	end,

	["tool output containing a fence gets a longer fence"] = function()
		local block = message_renderer.render({
			role = "toolResult",
			toolName = "read",
			isError = false,
			content = { { type = "text", text = "```lua\nprint(1)\n```" } },
		})
		h.eq("````", block.lines[2])
		h.eq("````", block.lines[#block.lines])
	end,

	["bash execution shows exit code and truncation"] = function()
		local block = message_renderer.render({
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
		local block = message_renderer.render({
			role = "bashExecution",
			command = "echo hi",
			output = "hi\n",
			exitCode = 0,
		})
		h.eq({ "▸ ! echo hi", "```", "hi", "```" }, block.lines)
	end,

	["deliberate blank lines inside output are kept"] = function()
		local block = message_renderer.render({
			role = "bashExecution",
			command = "printf",
			output = "one\n\ntwo\n",
			exitCode = 0,
		})
		h.eq({ "▸ ! printf", "```", "one", "", "two", "```" }, block.lines)
	end,

	["cancelled bash execution is marked"] = function()
		local block = message_renderer.render({
			role = "bashExecution",
			command = "sleep 100",
			output = "",
			cancelled = true,
		})
		h.eq({ "▸ ! sleep 100 [cancelled]" }, block.lines)
	end,

	["custom message with display=false renders nothing"] = function()
		local block =
			message_renderer.render({ role = "custom", customType = "hook", content = "hidden", display = false })
		h.eq({}, block.lines)
	end,

	["custom message with display=true renders under its type"] = function()
		local block = message_renderer.render({
			role = "custom",
			customType = "notes",
			content = "remember this",
			display = true,
		})
		h.eq({ "### notes", "", "remember this" }, block.lines)
	end,

	["branch summary folds its quote"] = function()
		local block =
			message_renderer.render({ role = "branchSummary", summary = "tried X\nit failed", fromId = "abc" })
		h.eq({ "▸ branch summary", "> tried X", "> it failed" }, block.lines)
		h.eq({ { first = 0, last = 2, kind = "summary" } }, block.folds)
	end,

	["compaction summary shows token count"] = function()
		local block = message_renderer.render({ role = "compactionSummary", summary = "history", tokensBefore = 52000 })
		h.eq({ "▸ compacted (52000 tokens before)", "> history" }, block.lines)
		h.eq({ { first = 0, last = 1, kind = "summary" } }, block.folds)
	end,

	["unknown role renders a visible stub"] = function()
		local block = message_renderer.render({ role = "notification" })
		h.eq({ "▸ notification message" }, block.lines)
	end,

	["an unknown assistant content block renders a stub, not a blank"] = function()
		local block = message_renderer.render(assistant({
			{ type = "text", text = "before" },
			{ type = "redactedThinking", data = "opaque" },
			{ type = "text", text = "after" },
		}))
		h.eq({ "### pi", "", "before", "", "▸ redactedThinking block", "", "after" }, block.lines)
	end,

	["an unknown assistant block on its own still renders"] = function()
		local block = message_renderer.render(assistant({ { type = "serverToolUse", name = "web_search" } }))
		h.eq({ "### pi", "", "▸ serverToolUse block" }, block.lines)
	end,

	["an unknown block in content_to_text renders a stub"] = function()
		local block = message_renderer.render({
			role = "user",
			content = {
				{ type = "text", text = "hi" },
				{ type = "document", name = "spec.pdf" },
			},
		})
		h.eq({ "### You", "", "hi", "[document block]" }, block.lines)
	end,

	["empty thinking blocks are not rendered"] = function()
		local block = message_renderer.render(assistant({
			{ type = "thinking", thinking = "  " },
			{ type = "text", text = "answer" },
		}))
		h.eq({ "### pi", "", "answer" }, block.lines)
		h.eq({}, block.folds)
	end,

	["hidden thinking is omitted entirely"] = function()
		local block = message_renderer.render(
			assistant({ { type = "thinking", thinking = "hmm" }, { type = "text", text = "answer" } }),
			{ thinking = "hidden" }
		)
		h.eq({ "### pi", "", "answer" }, block.lines)
		h.eq({}, block.folds)
	end,

	["running tool execution shows status and streamed output"] = function()
		local block = tool_renderer.execution({
			toolName = "bash",
			running = true,
			result = { content = { { type = "text", text = "file-a" } } },
		})
		h.eq({ "▸ result(bash) [running]", "```", "file-a", "```" }, block.lines)
		h.eq({ { first = 0, last = 3, kind = "tool" } }, block.folds)
	end,

	["pending edit execution shows its preview"] = function()
		local block = tool_renderer.execution({
			toolName = "edit",
			args = { path = "src/config.lua" },
			preview = "@@ -1 +1 @@\n-old\n+new",
			running = true,
		})
		h.eq("▸ result(edit): src/config.lua [running]", block.lines[1])
		h.eq("```diff", block.lines[2])
		h.eq("-old", block.lines[4])
		h.eq("+new", block.lines[5])
	end,

	["finished edit execution uses the authoritative result diff"] = function()
		local block = tool_renderer.execution({
			toolName = "edit",
			args = { path = "src/config.lua" },
			preview = "preview",
			result = { content = { { type = "text", text = "done" } }, details = { diff = "-before\n+after" } },
		})
		h.eq({ "▸ result(edit): src/config.lua", "```diff", "-before", "+after", "```" }, block.lines)
	end,

	["write execution uses the target filetype for proposed content"] = function()
		local block = tool_renderer.execution({
			toolName = "write",
			args = { path = "new.lua", content = "local first = true\nreturn first" },
			result = { content = { { type = "text", text = "written" } } },
		})
		h.eq({
			"▸ result(write): new.lua",
			"```lua",
			"local first = true",
			"return first",
			"```",
		}, block.lines)
	end,

	["pending bash execution shows the complete command"] = function()
		local block = tool_renderer.execution({
			toolName = "bash",
			args = { command = "mise test\necho done" },
			preview = "mise test\necho done",
			running = true,
		})
		h.eq({
			"▸ result(bash): mise test … (+1 lines) [running]",
			"```bash",
			"mise test",
			"echo done",
			"```",
		}, block.lines)
	end,

	["finished bash execution keeps the command and output separate"] = function()
		local block = tool_renderer.execution({
			toolName = "bash",
			args = { command = "echo done" },
			preview = "echo done",
			result = { content = { { type = "text", text = "done" } } },
		})
		h.eq({ "▸ result(bash): echo done", "```bash", "echo done", "```", "```", "done", "```" }, block.lines)
	end,

	["finished tool execution drops the running marker"] = function()
		local block = tool_renderer.execution({ toolName = "bash", result = "done" })
		h.eq("▸ result(bash)", block.lines[1])
	end,

	["failed tool execution is marked"] = function()
		local block = tool_renderer.execution({ toolName = "bash", isError = true, result = "boom" })
		h.eq("▸ result(bash) ✘ error", block.lines[1])
	end,

	["tool execution with no output has no fence"] = function()
		local block = tool_renderer.execution({ toolName = "noop", running = true })
		h.eq({ "▸ result(noop) [running]" }, block.lines)
		h.eq({}, block.folds)
	end,

	["tool execution tolerates ad-hoc result shapes"] = function()
		h.eq(
			{ "▸ result(t)", "```", "raw", "```" },
			tool_renderer.execution({ toolName = "t", result = "raw" }).lines
		)
		h.eq(
			{ "▸ result(t)", "```", "out", "```" },
			tool_renderer.execution({ toolName = "t", result = { output = "out" } }).lines
		)
	end,
}
