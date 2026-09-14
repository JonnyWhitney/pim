local h = require("helpers")
local config = require("pim.config")
local layout = require("pim.ui.layout")
local transcript = require("pim.ui.transcript")
local renderer = require("pim.render.message")

local function put(key, role, text, final)
	local content = role == "assistant" and { { type = "text", text = text } } or text
	transcript.set(key, "message", renderer.render({ role = role, content = content }), { final = final ~= false })
end

local function buf()
	return assert(layout.transcript_buf())
end

local function lines()
	return vim.api.nvim_buf_get_lines(buf(), 0, -1, false)
end

local function marks(namespace)
	return vim.api.nvim_buf_get_extmarks(
		buf(),
		vim.api.nvim_get_namespaces()[namespace or "pim-transcript-decorations"],
		0,
		-1,
		{ details = true }
	)
end

local function headers()
	return vim.tbl_filter(function(mark)
		return mark[4].hl_group ~= nil
	end, marks())
end

local function dividers()
	return vim.tbl_filter(function(mark)
		return mark[4].virt_text ~= nil
	end, marks())
end

local function with_highlights(names, callback)
	local original = {}
	for _, name in ipairs(names) do
		original[name] = vim.api.nvim_get_hl(0, { name = name, create = false })
	end
	local ok, err = pcall(callback)
	for name, highlight in pairs(original) do
		vim.api.nvim_set_hl(0, name, highlight)
	end
	if not ok then
		error(err, 0)
	end
end

return {
	["only structural chat boundaries are decorated"] = function()
		layout.open()
		put("user", "user", "### pi\n```lua\nlocal value = 1\n```")
		put("assistant", "assistant", "### You\n```markdown\n### You\n```")
		put("result", "toolResult", "### You")
		put("custom", "custom", "notes")
		put("unknown", "notification", "### You")
		local colored = headers()
		h.eq(3, #colored)
		h.eq(
			{ "PimUserHeader", "PimAssistantHeader", "PimCustomHeader" },
			vim.tbl_map(function(mark)
				return mark[4].hl_group
			end, colored)
		)
		for _, mark in ipairs(colored) do
			h.eq(mark[2], mark[4].end_row)
			h.eq(#lines()[mark[2] + 1], mark[4].end_col)
			h.eq(200, mark[4].priority)
			h.eq(nil, mark[4].line_hl_group)
		end
		h.eq(2, #dividers(), "no divider is added around internal tools or unknown messages")
		for _, mark in ipairs(dividers()) do
			h.eq("", lines()[mark[2] + 1])
		end
		h.eq("markdown", vim.bo[buf()].filetype)
	end,

	["decorations do not change copied text or screen height"] = function()
		layout.open()
		put("user", "user", "question")
		put("assistant", "assistant", "answer\n```lua\nreturn true\n```")
		local expected = lines()
		local win = assert(layout.transcript_win())
		local height = vim.api.nvim_win_text_height(win, {}).all
		for _, dividers_enabled in ipairs({ false, true }) do
			for _, colors_enabled in ipairs({ false, true }) do
				config.setup({
					transcript = {
						dividers = dividers_enabled,
						header_highlights = colors_enabled and { user = "Special", assistant = "String" } or false,
					},
				})
				transcript.flush()
				h.eq(expected, lines())
				h.eq(height, vim.api.nvim_win_text_height(win, {}).all)
				h.eq(dividers_enabled and 1 or 0, #dividers())
				h.eq(colors_enabled and 2 or 0, #headers())
				if colors_enabled then
					h.eq("Special", headers()[1][4].hl_group)
					h.eq("String", headers()[2][4].hl_group)
				end
				vim.api.nvim_win_call(win, function()
					vim.cmd('silent normal! gg"zyG')
				end)
				h.eq(expected, vim.fn.getreg("z", 1, true))
			end
		end
	end,

	["streamed replacements rebind decorations without touching other namespaces"] = function()
		layout.open()
		put("user", "user", "question")
		put("assistant", "assistant", "answer")
		transcript.set_queue({ "later" }, {})
		local queue_id = marks("pim-queue")[1][1]
		local boundaries = marks("pim-transcript")
		for count = 1, 6 do
			put("user", "user", string.rep("question\n", count), false)
			put("assistant", "assistant", string.rep("answer\n", count), false)
			transcript.flush()
			h.eq(3, #marks())
			local colored = headers()
			h.eq(0, colored[1][2])
			h.eq("### pi", lines()[colored[2][2] + 1])
			h.eq(colored[2][2] - 1, dividers()[1][2])
			h.eq(queue_id, marks("pim-queue")[1][1])
			h.eq(boundaries[1][1], marks("pim-transcript")[1][1])
			h.eq(boundaries[2][1], marks("pim-transcript")[2][1])
		end
		put("user", "user", "short")
		put("assistant", "assistant", "done")
		h.eq(4, headers()[2][2])
		h.eq(3, #marks())
		transcript.set("assistant", "message", { lines = { "not a chat header" }, folds = {} }, { final = true })
		h.eq(1, #marks(), "obsolete header metadata is cleared")
	end,

	["reset shutdown and buffer recreation leave no stale decorations"] = function()
		layout.open()
		put("user", "user", "question")
		put("assistant", "assistant", "answer")
		transcript.reset()
		h.eq({}, marks())
		put("custom", "custom", "notes")
		h.eq(1, #marks())
		vim.api.nvim_buf_delete(buf(), { force = true })
		layout.hide()
		layout.open()
		transcript.flush()
		h.eq(1, #marks())
		h.eq("PimCustomHeader", headers()[1][4].hl_group)
		transcript.shutdown()
		h.eq({}, marks())
	end,

	["dividers are clipped to narrow windows and refreshed on resize"] = function()
		layout.open()
		put("user", "user", "question")
		put("assistant", "assistant", "answer")
		local primary = assert(layout.transcript_win())
		vim.api.nvim_set_current_win(primary)
		vim.cmd("vsplit")
		local narrow = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_config(narrow, { width = 8 })
		vim.api.nvim_exec_autocmds("WinResized", {})
		vim.cmd("redraw")
		local width = math.max(vim.api.nvim_win_get_width(primary), vim.api.nvim_win_get_width(narrow))
		h.eq(width, vim.fn.strdisplaywidth(dividers()[1][4].virt_text[1][1]))
		for _, win in ipairs({ primary, narrow }) do
			local position = vim.fn.screenpos(win, 4, 1)
			h.eq("─", vim.fn.screenstring(position.row, position.col))
			h.eq("─", vim.fn.screenstring(position.row, position.col + vim.api.nvim_win_get_width(win) - 1))
			h.eq(position.row + 1, vim.fn.screenpos(win, 5, 1).row, "the divider does not wrap")
		end
		vim.api.nvim_win_close(narrow, true)
		vim.api.nvim_exec_autocmds("WinResized", {})
		h.eq(vim.api.nvim_win_get_width(primary), vim.fn.strdisplaywidth(dividers()[1][4].virt_text[1][1]))
	end,

	["default links respect user definitions and colorscheme refreshes"] = function()
		with_highlights({ "PimUserHeader", "PimAssistantHeader", "PimCustomHeader", "PimDivider" }, function()
			vim.api.nvim_set_hl(0, "PimUserHeader", { fg = "#123456" })
			vim.cmd("highlight clear PimAssistantHeader")
			layout.open()
			put("user", "user", "question")
			h.eq(0x123456, vim.api.nvim_get_hl(0, { name = "PimUserHeader" }).fg)
			h.eq("Statement", vim.api.nvim_get_hl(0, { name = "PimAssistantHeader" }).link)
			vim.cmd("highlight clear PimAssistantHeader")
			vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "default" })
			h.eq("Statement", vim.api.nvim_get_hl(0, { name = "PimAssistantHeader" }).link)
			h.eq(0x123456, vim.api.nvim_get_hl(0, { name = "PimUserHeader" }).fg)
			vim.api.nvim_create_autocmd("ColorScheme", {
				once = true,
				callback = function()
					vim.api.nvim_set_hl(0, "PimUserHeader", { fg = "#123456" })
				end,
			})
			vim.cmd("colorscheme default")
			h.eq("Statement", vim.api.nvim_get_hl(0, { name = "PimAssistantHeader" }).link)
			h.eq(0x123456, vim.api.nvim_get_hl(0, { name = "PimUserHeader" }).fg)
		end)
	end,

	["role colors override Markdown only inside the known header range"] = function()
		with_highlights({ "PimTestRole", "PimTestMarkdown" }, function()
			vim.api.nvim_set_hl(0, "PimTestRole", { fg = "#ff0000", ctermfg = 1 })
			vim.api.nvim_set_hl(0, "PimTestMarkdown", { fg = "#00ff00", ctermfg = 2 })
			config.setup({ transcript = { header_highlights = { user = "PimTestRole" } } })
			layout.open()
			put("user", "user", "### You")
			local win = assert(layout.transcript_win())
			vim.api.nvim_win_call(win, function()
				vim.cmd("syntax match PimTestMarkdown /^### You$/")
			end)
			local lower = vim.api.nvim_create_namespace("pim-test-markdown")
			for _, row in ipairs({ 0, 2 }) do
				vim.api.nvim_buf_set_extmark(
					buf(),
					lower,
					row,
					0,
					{ end_col = 7, hl_group = "PimTestMarkdown", priority = 100 }
				)
			end
			local function attributes()
				vim.cmd("redraw")
				local first = vim.fn.screenpos(win, 1, 5)
				local body = vim.fn.screenpos(win, 3, 5)
				return vim.fn.screenattr(first.row, first.col), vim.fn.screenattr(body.row, body.col)
			end
			local header, body = attributes()
			h.ok(header ~= body, "the role color takes precedence over syntax and Tree-sitter priority")
			config.setup({ transcript = { header_highlights = false } })
			transcript.flush()
			local uncolored, unchanged_body = attributes()
			h.eq(body, unchanged_body)
			h.eq(body, uncolored, "disabling role coloring restores Markdown highlighting")
		end)
	end,
}
