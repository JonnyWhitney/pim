local buffers = require("pim.buffers")

local M = {}

local TRANSCRIPT_NAME = "pim://pi transcript"
local INPUT_NAME = "pim://pi input"

local bufs = { transcript = nil, input = nil }

---@type { tab: integer, transcript: integer, input: integer }|nil
local wins = nil

local closing = false

local function open_wins()
	if wins ~= nil and vim.api.nvim_win_is_valid(wins.transcript) and vim.api.nvim_win_is_valid(wins.input) then
		return wins
	end
	return nil
end

local function buf_valid(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param name string
---@param role string
local function make_buf(name, role)
	local buf = vim.api.nvim_create_buf(false, true)
	buffers.claim(buf, name, role)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = "markdown"
	return buf
end

local function ensure_bufs()
	if not buf_valid(bufs.transcript) then
		bufs.transcript = make_buf(TRANSCRIPT_NAME, "transcript")
		vim.bo[bufs.transcript].undolevels = -1
		vim.bo[bufs.transcript].modifiable = false
		pcall(vim.treesitter.start, bufs.transcript, "markdown")
	end
	if not buf_valid(bufs.input) then
		bufs.input = make_buf(INPUT_NAME, "input")
	end
end

local TRANSCRIPT_WIN_OPTS = {
	wrap = true,
	linebreak = true,
	number = false,
	relativenumber = false,
	signcolumn = "no",
	foldcolumn = "0",
	foldmethod = "manual",
	foldenable = true,
	foldtext = "v:lua.require'pim.ui.transcript'.foldtext()",
	fillchars = "fold: ",
}

local INPUT_WIN_OPTS = {
	wrap = true,
	linebreak = true,
	number = false,
	relativenumber = false,
	signcolumn = "no",
	foldcolumn = "0",
	winfixheight = true,
}

local function set_win_opts(win, opts)
	for name, value in pairs(opts) do
		vim.api.nvim_set_option_value(name, value, { win = win })
	end
end

local function input_min_height()
	return require("pim.config").get().input.min_height
end

local function open_input_split()
	vim.cmd("belowright " .. input_min_height() .. "split")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, bufs.input)
	set_win_opts(win, INPUT_WIN_OPTS)
	return win
end

---@return boolean
-- Rebuild only the pi window that a user closed. Keep the other pi window and tab.
local function repair()
	if wins == nil then
		return false
	end
	local has_transcript = vim.api.nvim_win_is_valid(wins.transcript)
	local has_input = vim.api.nvim_win_is_valid(wins.input)
	if has_transcript and has_input then
		return true
	end

	ensure_bufs()
	if has_transcript then
		vim.api.nvim_set_current_win(wins.transcript)
		wins.input = open_input_split()
		return true
	end
	if has_input then
		vim.api.nvim_set_current_win(wins.input)
		vim.cmd("aboveleft split")
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, bufs.transcript)
		set_win_opts(win, TRANSCRIPT_WIN_OPTS)
		wins.transcript = win
		vim.api.nvim_win_set_config(wins.input, { height = input_min_height() })
		return true
	end

	wins = nil
	return false
end

function M.is_open()
	return open_wins() ~= nil
end

local function current_tab_is_blank()
	if #vim.api.nvim_tabpage_list_wins(0) ~= 1 then
		return false
	end
	local buf = vim.api.nvim_get_current_buf()
	return vim.api.nvim_buf_get_name(buf) == ""
		and vim.bo[buf].buftype == ""
		and not vim.bo[buf].modified
		and vim.api.nvim_buf_line_count(buf) == 1
		and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

function M.open()
	if repair() then
		M.focus_input()
		return
	end

	ensure_bufs()

	local placeholder = nil
	if current_tab_is_blank() then
		placeholder = vim.api.nvim_get_current_buf()
	else
		vim.cmd("tabnew")
		placeholder = vim.api.nvim_get_current_buf()
	end
	local transcript_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(transcript_win, bufs.transcript)
	if
		placeholder ~= bufs.transcript
		and vim.api.nvim_buf_is_valid(placeholder)
		and vim.api.nvim_buf_get_name(placeholder) == ""
		and not vim.bo[placeholder].modified
	then
		-- Remove only the empty placeholder that Neovim created for this layout.
		pcall(vim.api.nvim_buf_delete, placeholder, {})
	end
	set_win_opts(transcript_win, TRANSCRIPT_WIN_OPTS)

	local input_win = open_input_split()

	wins = {
		tab = vim.api.nvim_get_current_tabpage(),
		transcript = transcript_win,
		input = input_win,
	}

	M.focus_input()
end

function M.is_closing()
	return closing
end

local function close_window(win)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	local closed = pcall(vim.api.nvim_win_close, win, true)
	if closed or not vim.api.nvim_win_is_valid(win) then
		return
	end

	-- Neovim must keep one window. Remove pim from that window instead.
	local placeholder = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_win_set_buf(win, placeholder)
end

function M.hide()
	local targets = wins
	if targets == nil then
		return
	end

	closing = true
	for _, win in ipairs({ targets.input, targets.transcript }) do
		pcall(close_window, win)
	end
	wins = nil
	closing = false
end

function M.destroy()
	local targets = { transcript = bufs.transcript, input = bufs.input }
	M.hide()
	for role, buf in pairs(targets) do
		if buf_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
		bufs[role] = nil
	end
end

function M.owns_only_ui()
	if wins == nil then
		return false
	end
	local owned = {}
	for _, win in ipairs({ wins.transcript, wins.input }) do
		if vim.api.nvim_win_is_valid(win) then
			owned[win] = true
		end
	end
	if not next(owned) then
		return false
	end
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if not owned[win] then
			return false
		end
	end
	return true
end

function M.focus_input()
	local current = open_wins()
	if current then
		vim.api.nvim_set_current_win(current.input)
	end
end

---@return integer|nil
function M.transcript_buf()
	return buf_valid(bufs.transcript) and bufs.transcript or nil
end

---@return integer|nil
function M.input_buf()
	return buf_valid(bufs.input) and bufs.input or nil
end

---@return integer|nil
function M.transcript_win()
	local current = open_wins()
	return current and current.transcript or nil
end

---@return integer|nil
function M.input_win()
	local current = open_wins()
	return current and current.input or nil
end

function M.scroll_transcript_to_bottom()
	local buf = M.transcript_buf()
	if not buf then
		return
	end
	local line_count = vim.api.nvim_buf_line_count(buf)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		vim.api.nvim_win_set_cursor(win, { line_count, 0 })
	end
end

return M
