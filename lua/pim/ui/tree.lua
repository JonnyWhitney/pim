local layout = require("pim.ui.layout")
local transcript = require("pim.ui.transcript")

local M = {}

---@class PimTreeRow
---@field entry table
---@field id string|nil
---@field line string

---@class PimTreeView
---@field buf integer
---@field rows PimTreeRow[]
---@field line_by_index table<integer, integer>
---@field index_by_line table<integer, integer>
---@field tree table[]
---@field selected_index integer
---@field mode "tree"|"preview"

---@type PimTreeView|nil
local view = nil
local opening = false

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
	for _, lhs in ipairs({ "j", "k", "<CR>", "p", "r", "c", "q" }) do
		pcall(vim.keymap.del, "n", lhs, { buffer = current.buf })
	end
end

local function selected_index()
	local current = view
	if not current or #current.rows == 0 then
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
	return current.index_by_line[line] or current.selected_index
end

local function select_index(index)
	local current = view
	if not current or #current.rows == 0 then
		return
	end
	index = math.min(math.max(index, 1), #current.rows)
	current.selected_index = index
	local win = layout.transcript_win()
	if win then
		vim.api.nvim_win_set_cursor(win, { current.line_by_index[index], 0 })
	end
end

local function move(amount)
	local index = selected_index()
	if index then
		select_index(index + amount)
	end
end

---@param current PimTreeView
local function render_tree(current)
	local lines = {
		"# pi tree",
		"j/k: move · p: preview · r: fork · c: clone · <CR>/q: close",
		"Input is disabled while the tree is open.",
		"",
	}
	current.line_by_index = {}
	current.index_by_line = {}

	if #current.rows == 0 then
		lines[#lines + 1] = "No entries in this session."
	else
		for index, row in ipairs(current.rows) do
			lines[#lines + 1] = row.line
			local line = #lines
			current.line_by_index[index] = line
			current.index_by_line[line] = index
		end
	end

	transcript.reset()
	transcript.set("tree", "tree", { lines = lines, folds = {} }, { final = true })
end

local function render_preview(messages)
	transcript.reset()
	transcript.set("tree-preview", "tree", {
		lines = { "# pi tree preview", "q: return to tree", "Input is disabled while the tree is open." },
		folds = {},
	}, { final = true })
	local opts = { thinking = require("pim.config").get().transcript.show_thinking }
	for index, message in ipairs(messages) do
		transcript.set(
			"tree-preview-" .. index,
			"message",
			require("pim.ui.render").message(message, opts),
			{ final = true }
		)
	end
end

---@param current PimTreeView
local function set_tree_keymaps(current)
	local buf = current.buf
	vim.keymap.set("n", "j", function()
		move(1)
	end, { buffer = buf, desc = "Next pi tree entry" })
	vim.keymap.set("n", "k", function()
		move(-1)
	end, { buffer = buf, desc = "Previous pi tree entry" })
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

function M.selected()
	local current = view
	local index = selected_index()
	if current and index then
		current.selected_index = index
		return current.rows[index]
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
			rows = require("pim.session_tree").flatten(data.tree, data.leafId),
			line_by_index = {},
			index_by_line = {},
			tree = data.tree,
			selected_index = 1,
			mode = "tree",
		}
		view = current
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
	if not current or current.mode ~= "tree" or not row or type(row.id) ~= "string" then
		return
	end
	local messages = require("pim.session_tree").preview_messages(current.tree, row.id)
	if not messages then
		vim.notify("[pim] Cannot preview the selected tree entry", vim.log.levels.WARN)
		return
	end

	clear_keymaps()
	current.mode = "preview"
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
	render_tree(current)
	set_tree_keymaps(current)
	focus_transcript()
	select_index(current.selected_index)
end

local function dismiss(refresh)
	clear_keymaps()
	view = nil
	require("pim.ui.input").set_locked(false)
	layout.focus_input()
	if refresh then
		require("pim").refresh()
	end
end

function M.fork_selected()
	local current = view
	local row = M.selected()
	if not current or current.mode ~= "tree" or not row then
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
	require("pim").fork(row.id)
end

function M.clone()
	if not view then
		return
	end

	dismiss(false)
	require("pim").clone()
end

function M.close()
	if not view then
		return
	end
	dismiss(true)
end

function M.reset()
	opening = false
	clear_keymaps()
	view = nil
	require("pim.ui.input").set_locked(false)
end

return M
