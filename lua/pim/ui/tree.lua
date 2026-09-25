local layout = require("pim.ui.layout")
local session_tree = require("pim.session_tree")
local transcript = require("pim.ui.transcript")

local M = {}

---@class PimTreeView
---@field buf integer
---@field rows PimTreeRow[]
---@field display_rows PimTreeRow[]
---@field open_responses table<string, boolean>
---@field line_by_index table<integer, integer>
---@field index_by_line table<integer, integer>
---@field tree PimSessionTreeNode[]
---@field selected_index integer
---@field mode "tree"|"preview"

---@type PimTreeView|nil
local view = nil
local opening = false

local function set_markdown(buf, enabled)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if enabled then
		vim.bo[buf].filetype = "markdown"
		pcall(vim.treesitter.start, buf, "markdown")
	else
		pcall(vim.treesitter.stop, buf)
		vim.bo[buf].filetype = "text"
	end
end

local function focus_transcript()
	local win = layout.transcript_win()
	if win then
		vim.api.nvim_set_current_win(win)
	end
end

local function clear_keymaps()
	local current = view
	if not current or not vim.api.nvim_buf_is_valid(current.buf) then
		return
	end
	for _, lhs in ipairs({ "<CR>", "p", "r", "c", "q" }) do
		pcall(vim.keymap.del, "n", lhs, { buffer = current.buf })
	end
end

local function selected_index()
	local current = view
	if not current or #current.display_rows == 0 then
		return nil
	end
	if current.mode == "preview" then
		return current.selected_index
	end
	local win = layout.transcript_win()
	if not win then
		return current.selected_index
	end
	local line = vim.api.nvim_win_get_cursor(win)[1]
	return current.index_by_line[line]
end

local function select_index(index)
	local current = view
	if not current or #current.rows == 0 then
		return
	end
	index = math.min(math.max(index, 1), #current.display_rows)
	local win = layout.transcript_win()
	if win then
		index = vim.api.nvim_win_call(win, function()
			local step = index >= current.selected_index and 1 or -1
			while index >= 1 and index <= #current.display_rows do
				local line = current.line_by_index[index]
				local closed = vim.fn.foldclosed(line)
				if closed == -1 or closed == line then
					break
				end
				index = index + step
			end
			return index >= 1 and index <= #current.display_rows and index or current.selected_index
		end)
		vim.api.nvim_win_set_cursor(win, { current.line_by_index[index], 0 })
	end
	current.selected_index = index
end

---@param current PimTreeView
local function render_tree(current)
	local lines = {
		"# pi tree",
		"Navigate with normal buffer motions · za: expand/collapse · p: preview · r: fork · c: clone · <CR>/q: close",
		"Input is disabled while the tree is open.",
		"",
	}
	current.line_by_index = {}
	current.index_by_line = {}
	current.display_rows = {}
	local folds = {}

	local function add_row(row)
		lines[#lines + 1] = row.line
		local line = #lines
		local index = #current.display_rows + 1
		current.display_rows[index] = row
		current.line_by_index[index] = line
		current.index_by_line[line] = index
	end

	if #current.rows == 0 then
		lines[#lines + 1] = "No entries in this session."
	else
		for _, row in ipairs(current.rows) do
			add_row(row)
			if row.turn_entries then
				local first = #lines - 1
				for _, entry in ipairs(row.turn_entries) do
					for _, text in ipairs(session_tree.detail_lines(entry)) do
						add_row({ entry = entry, id = entry.id, line = "    " .. text })
					end
				end
				folds[#folds + 1] = { first = first, last = #lines - 1, kind = "tree_responses" }
			end
		end
	end

	transcript.reset()
	transcript.set("tree", "tree", { lines = lines, folds = folds }, { final = true })
end

local function render_preview(messages)
	transcript.reset()
	transcript.set("tree-preview", "tree", {
		lines = { "# pi tree preview", "q: return to tree", "Input is disabled while the tree is open." },
		folds = {},
	}, { final = true })
	local opts = { thinking = require("pim.config").get().transcript.folds.thinking }
	for index, message in ipairs(messages) do
		transcript.set(
			"tree-preview-" .. index,
			"message",
			require("pim.render.message").render(message, opts),
			{ final = true }
		)
	end
end

---@param current PimTreeView
local function set_tree_keymaps(current)
	local buf = current.buf
	vim.keymap.set("n", "p", M.preview, { buffer = buf, desc = "Preview pi tree entry" })
	vim.keymap.set("n", "r", M.fork_selected, { buffer = buf, desc = "Fork pi tree prompt" })
	vim.keymap.set("n", "c", M.clone, { buffer = buf, desc = "Clone pi branch" })
	vim.keymap.set("n", "<CR>", M.close, { buffer = buf, desc = "Close pi tree" })
	vim.keymap.set("n", "q", M.close, { buffer = buf, desc = "Close pi tree" })
end

---@param current PimTreeView
local function set_preview_keymaps(current)
	vim.keymap.set("n", "q", M.return_to_tree, { buffer = current.buf, desc = "Return to pi tree" })
end

function M.is_open()
	return view ~= nil
end

function M.is_tree_mode()
	return view ~= nil and view.mode == "tree"
end

function M.selected()
	local current = view
	local index = selected_index()
	if current and index then
		current.selected_index = index
		return current.display_rows[index]
	end
	return nil
end

function M.open()
	if view then
		focus_transcript()
		return
	end
	if opening or require("pim.state").is_busy() then
		if not opening then
			vim.notify("[pim] Cannot open the tree while pi is busy", vim.log.levels.WARN)
		end
		return
	end

	opening = true
	require("pim.rpc.client").get_tree(function(success, data)
		opening = false
		if not success then
			vim.notify("[pim] Cannot load pi tree: " .. tostring(data), vim.log.levels.ERROR)
			return
		end
		if type(data) ~= "table" or type(data.tree) ~= "table" then
			vim.notify("[pim] pi did not return tree data", vim.log.levels.WARN)
			return
		end
		---@cast data PimRpcTreeResponse
		if require("pim.state").is_busy() then
			vim.notify("[pim] Cannot open the tree while pi is busy", vim.log.levels.WARN)
			return
		end

		local buf = layout.transcript_buf()
		if not buf then
			vim.notify("[pim] pi transcript is not open", vim.log.levels.WARN)
			return
		end
		---@type PimTreeView
		local current = {
			buf = buf,
			rows = session_tree.flatten(data.tree, data.leafId),
			display_rows = {},
			open_responses = {},
			line_by_index = {},
			index_by_line = {},
			tree = data.tree,
			selected_index = 1,
			mode = "tree",
		}
		view = current
		set_markdown(buf, false)
		render_tree(current)
		require("pim.ui.input").set_locked(true)
		set_tree_keymaps(current)
		focus_transcript()
		select_index(1)
	end)
end

function M.preview()
	local current = view
	local row = M.selected()
	if not current or current.mode ~= "tree" then
		return
	end
	if not row or type(row.id) ~= "string" then
		vim.notify("[pim] Select a valid tree entry to preview", vim.log.levels.WARN)
		return
	end
	local messages = session_tree.preview_messages(current.tree, row.id)
	if not messages then
		vim.notify("[pim] Cannot preview the selected tree entry", vim.log.levels.WARN)
		return
	end

	local win = layout.transcript_win()
	if win then
		vim.api.nvim_win_call(win, function()
			current.open_responses = {}
			for index, item in ipairs(current.display_rows) do
				if
					item.turn_entries
					and type(item.id) == "string"
					and vim.fn.foldclosed(current.line_by_index[index]) == -1
				then
					current.open_responses[item.id] = true
				end
			end
		end)
	end
	clear_keymaps()
	current.mode = "preview"
	set_markdown(current.buf, true)
	render_preview(messages)
	set_preview_keymaps(current)
	focus_transcript()
end

function M.return_to_tree()
	local current = view
	if not current or current.mode ~= "preview" then
		return
	end

	clear_keymaps()
	current.mode = "tree"
	set_markdown(current.buf, false)
	render_tree(current)
	set_tree_keymaps(current)
	focus_transcript()
	local win = layout.transcript_win()
	if win then
		vim.api.nvim_win_call(win, function()
			for index, item in ipairs(current.display_rows) do
				if item.turn_entries and current.open_responses[item.id] then
					vim.cmd(("%dfoldopen"):format(current.line_by_index[index]))
				end
			end
		end)
	end
	select_index(current.selected_index)
end

local function dismiss(refresh)
	local current = view
	clear_keymaps()
	if current then
		set_markdown(current.buf, true)
	end
	view = nil
	require("pim.ui.input").set_locked(false)
	layout.focus_input()
	if refresh then
		require("pim.sessions").refresh()
	end
end

function M.fork_selected()
	local current = view
	local row = M.selected()
	if not current or current.mode ~= "tree" then
		return
	end
	if not row then
		vim.notify("[pim] Select a user prompt to fork", vim.log.levels.WARN)
		return
	end
	local message = row.entry.message
	if
		row.entry.type ~= "message"
		or type(message) ~= "table"
		or message.role ~= "user"
		or type(row.id) ~= "string"
	then
		vim.notify("[pim] Select a user prompt to fork", vim.log.levels.WARN)
		return
	end

	dismiss(false)
	require("pim.sessions").fork(row.id)
end

function M.clone()
	if not view then
		return
	end

	dismiss(false)
	require("pim.sessions").clone()
end

function M.close()
	if not view then
		return
	end
	dismiss(true)
end

function M.reset()
	opening = false
	local current = view
	clear_keymaps()
	if current then
		set_markdown(current.buf, true)
	end
	view = nil
	require("pim.ui.input").set_locked(false)
end

return M
