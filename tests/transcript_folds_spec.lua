local h = require("helpers")
local config = require("pim.config")
local layout = require("pim.ui.layout")
local transcript = require("pim.ui.transcript")
local renderer = require("pim.render.message")

local function put(key, kind, count, final)
	local lines = { key }
	for i = 2, count do
		lines[i] = "line " .. i
	end
	transcript.set(
		key,
		"message",
		{ lines = lines, folds = { { first = 0, last = count - 1, kind = kind } } },
		{ final = final }
	)
	transcript.flush()
end

local function call(fn)
	return vim.api.nvim_win_call(assert(layout.transcript_win()), fn)
end

return {
	["disabled folding retains latent closed choices during updates"] = function()
		layout.open()
		put("call", "tool_calls", 4, false)
		local win = assert(layout.transcript_win())
		vim.wo[win].foldenable = false
		put("call", "tool_calls", 8, true)
		h.eq(false, vim.wo[win].foldenable)
		vim.wo[win].foldenable = true
		h.eq(
			1,
			call(function()
				return vim.fn.foldclosed(1)
			end)
		)
	end,
	["thinking identity survives an earlier empty block becoming visible"] = function()
		layout.open()
		local message = {
			role = "assistant",
			content = { { type = "thinking", thinking = "" }, { type = "thinking", thinking = "second" } },
		}
		transcript.set("assistant", "message", renderer.render(message))
		transcript.flush()
		call(function()
			vim.cmd("3foldopen")
		end)
		message.content[1].thinking = "first"
		transcript.set("assistant", "message", renderer.render(message), { final = true })
		call(function()
			h.eq(3, vim.fn.foldclosed(3))
			h.eq(-1, vim.fn.foldclosed(6))
		end)
	end,
	["independent defaults are applied during streaming and completion"] = function()
		layout.open()
		for _, reversed in ipairs({ false, true }) do
			config.setup({
				transcript = {
					folds = reversed and {
						tool_calls = "open",
						tool_results = "folded",
						thinking = "open",
						bash_output = "folded",
					} or {},
				},
			})
			transcript.reset()
			for index, kind in ipairs({ "tool_calls", "tool_results", "thinking", "bash_output" }) do
				put(kind, kind, 4, false)
				local first = (index - 1) * 5 + 1
				local closed = config.get().transcript.folds[kind] == "folded"
				h.eq(
					closed and first or -1,
					call(function()
						return vim.fn.foldclosed(first)
					end)
				)
				put(kind, kind, 4, true)
				h.eq(
					closed and first or -1,
					call(function()
						return vim.fn.foldclosed(first)
					end)
				)
			end
		end
	end,

	["native choices survive growth completion and preceding replacements without nesting"] = function()
		layout.open()
		put("prefix", "thinking", 4, true)
		put("call", "tool_calls", 4, false)
		put("result", "tool_results", 4, false)
		call(function()
			vim.cmd("6foldopen")
			vim.cmd("11foldclose")
		end)
		for count = 5, 12 do
			put("prefix", "thinking", count, true)
			put("call", "tool_calls", count, false)
			put("result", "tool_results", count, count == 12)
			call(function()
				h.eq(-1, vim.fn.foldclosed(count + 2))
				h.eq(2 * count + 3, vim.fn.foldclosed(2 * count + 3))
				h.eq(3 * count + 2, vim.fn.foldclosedend(2 * count + 3))
				for line = 1, 3 * (count + 1) do
					h.ok(vim.fn.foldlevel(line) <= 1, "no nested replacement folds")
				end
			end)
		end
		put("call", "tool_calls", 4, true)
		call(function()
			h.eq(-1, vim.fn.foldclosed(14))
			h.eq(19, vim.fn.foldclosed(19))
		end)
	end,

	["fold choices remain window local and new windows receive defaults"] = function()
		layout.open()
		put("call", "tool_calls", 4, false)
		local primary = assert(layout.transcript_win())
		vim.api.nvim_set_current_win(primary)
		vim.cmd("vsplit")
		local other = vim.api.nvim_get_current_win()
		transcript.flush()
		call(function()
			vim.cmd("1foldopen")
		end)
		put("call", "tool_calls", 8, true)
		h.eq(
			-1,
			call(function()
				return vim.fn.foldclosed(1)
			end)
		)
		h.eq(
			1,
			vim.api.nvim_win_call(other, function()
				return vim.fn.foldclosed(1)
			end)
		)
		vim.api.nvim_win_close(other, true)
		layout.hide()
		layout.open()
		transcript.flush()
		h.eq(
			1,
			call(function()
				return vim.fn.foldclosed(1)
			end)
		)
	end,

	["short ranges reset and buffer recreation use fresh defaults"] = function()
		layout.open()
		put("call", "tool_calls", 1, false)
		h.eq(
			0,
			call(function()
				return vim.fn.foldlevel(1)
			end)
		)
		put("call", "tool_calls", 4, false)
		call(function()
			vim.cmd("1foldopen")
		end)
		transcript.reset()
		put("call", "tool_calls", 4, true)
		h.eq(
			1,
			call(function()
				return vim.fn.foldclosed(1)
			end)
		)
		call(function()
			vim.cmd("1foldopen")
		end)
		vim.api.nvim_buf_delete(assert(layout.transcript_buf()), { force = true })
		layout.hide()
		layout.open()
		transcript.flush()
		h.eq(
			1,
			call(function()
				return vim.fn.foldclosed(1)
			end)
		)
	end,

	["loaded history and preview rendering share thinking and result defaults"] = function()
		layout.open()
		local messages = {
			{
				role = "assistant",
				content = { { type = "thinking", thinking = "reasoning" }, { type = "text", text = "answer" } },
			},
			{ role = "toolResult", toolName = "edit", content = "changed", details = { diff = "-old\n+new" } },
			{ role = "bashExecution", command = "echo hello", output = "hello" },
		}
		for _, thinking in ipairs({ "folded", "open", "hidden" }) do
			config.setup({ transcript = { folds = { thinking = thinking } } })
			require("pim.events").load_messages(messages)
			local buf = assert(layout.transcript_buf())
			local expected = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			transcript.reset()
			for index, message in ipairs(messages) do
				transcript.set(
					"preview-" .. index,
					"message",
					renderer.render(message, { thinking = thinking }),
					{ final = true }
				)
			end
			h.eq(expected, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
			call(function()
				for line, text in ipairs(expected) do
					if text == "▸ thinking" then
						h.eq(thinking == "folded" and line or -1, vim.fn.foldclosed(line))
					end
					if text == "```diff" or text == "hello" then
						h.eq(-1, vim.fn.foldclosed(line))
					end
				end
			end)
			h.eq(thinking ~= "hidden", table.concat(expected, "\n"):find("reasoning", 1, true) ~= nil)
		end
	end,
}
