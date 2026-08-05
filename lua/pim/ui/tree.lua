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

---@type PimTreeView|nil
local view = nil
local opening = false

local function is_busy()
	local state = require("pim.state").get()
	return state.is_streaming or state.is_compacting or state.bash_running or state.retrying
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
	for _, lhs in ipairs({ "j", "k", "<CR>", "q" }) do
		pcall(vim.keymap.del, "n", lhs, { buffer = current.buf })
	end
end

local function selected_index()
	local current = view
	if not current or #current.rows == 0 then
		return nil
	end
	local win = layout.transcript_win()
	if not win then
		return 1
	end
	local line = vim.api.nvim_win_get_cursor(win)[1]
	return current.index_by_line[line] or 1
end

local function select_index(index)
	local current = view
	if not current or #current.rows == 0 then
		return
	end
	index = math.min(math.max(index, 1), #current.rows)
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
local function render(current)
	local lines = {
		"# pi tree",
		"j/k: move · <CR>/q: close",
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

---@param current PimTreeView
local function set_keymaps(current)
	local buf = current.buf
	vim.keymap.set("n", "j", function()
		move(1)
	end, { buffer = buf, desc = "Next pi tree entry" })
	vim.keymap.set("n", "k", function()
		move(-1)
	end, { buffer = buf, desc = "Previous pi tree entry" })
	vim.keymap.set("n", "<CR>", M.close, { buffer = buf, desc = "Close pi tree" })
	vim.keymap.set("n", "q", M.close, { buffer = buf, desc = "Close pi tree" })
end

function M.is_open()
	return view ~= nil
end

function M.selected()
	local current = view
	local index = selected_index()
	return current and index and current.rows[index] or nil
end

function M.open()
	if view then
		focus_transcript()
		return
	end
	if opening or is_busy() then
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
		if is_busy() then
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
		}
		view = current
		render(current)
		require("pim.ui.input").set_locked(true)
		set_keymaps(current)
		focus_transcript()
		select_index(1)
	end)
end

function M.close()
	if not view then
		return
	end
	clear_keymaps()
	view = nil
	require("pim.ui.input").set_locked(false)
	layout.focus_input()
	require("pim").refresh()
end

function M.reset()
	opening = false
	clear_keymaps()
	view = nil
	require("pim.ui.input").set_locked(false)
end

return M
