local h = require("helpers")
local layout = require("pim.ui.layout")
local transcript = require("pim.ui.transcript")
local view = require("pim.ui.transcript_view")

local function put(key, lines, folds)
	transcript.set(key, "message", { lines = lines, folds = folds or {} }, { final = true })
end

local function fresh()
	layout.open()
	put("a", { "one", "two", "three", "four" })
	return assert(layout.transcript_win()), assert(layout.transcript_buf())
end

local function cursor(win)
	return vim.api.nvim_win_get_cursor(win)[1]
end

local function observe()
	vim.api.nvim_exec_autocmds("CursorMoved", {})
end

local function submission(busy, behavior)
	local win = fresh()
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	observe()
	require("pim.state").update({ run_active = busy, is_streaming = busy })
	local client = require("pim.rpc.client")
	local original = client.prompt
	---@diagnostic disable-next-line: duplicate-set-field
	client.prompt = function(_, _, callback)
		callback(true)
	end
	vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "prompt" })
	local ok, err = pcall(require("pim.ui.input").submit, behavior)
	client.prompt = original
	assert(ok, err)
	put("b", { "new" })
	return cursor(win)
end

return {
	["cursor visibility adjustments after wrapped growth do not resume follow"] = function()
		local win = fresh()
		vim.api.nvim_set_current_win(win)
		vim.wo[win].scrolloff = 8
		local lines = {}
		for i = 1, 50 do
			lines[i] = "line " .. i
		end
		lines[51] = string.rep("wrapped output ", 40)
		put("a", lines)
		vim.cmd("redraw")
		observe()
		vim.cmd("normal! gk")
		observe()
		local reading = vim.api.nvim_win_get_cursor(win)
		for _ = 1, 5 do
			lines[51] = lines[51] .. " more text"
			put("a", lines)
			-- Redraw resolves cursor visibility before deferred movement events are delivered.
			vim.cmd("redraw")
			vim.fn.winline()
			observe()
			vim.api.nvim_exec_autocmds("WinScrolled", {})
			h.eq(reading, vim.api.nvim_win_get_cursor(win))
		end
	end,

	["one gk pauses on the final wrapped line and gj reattaches at its final row"] = function()
		local win = fresh()
		local text = string.rep("wrapped output ", 40)
		put("a", { "header", text })
		vim.api.nvim_win_call(win, function()
			vim.cmd("normal! gk")
		end)
		local reading = vim.api.nvim_win_get_cursor(win)
		h.eq(2, reading[1])
		h.ok(reading[2] < #text - 1)
		transcript.set("a", "message", { lines = { "header", text .. "more" }, folds = {} })
		transcript.flush()
		h.eq(reading, vim.api.nvim_win_get_cursor(win))
		vim.api.nvim_exec_autocmds("WinScrolled", {})
		put("a", { "header", text .. "more output" })
		h.eq(reading, vim.api.nvim_win_get_cursor(win))
		vim.api.nvim_win_call(win, function()
			vim.cmd("normal! 2gj")
		end)
		observe()
		put("b", { "latest" })
		h.eq(4, cursor(win))
	end,

	["one k pauses when a downward viewport adjustment is observed together"] = function()
		local win = fresh()
		vim.api.nvim_win_call(win, function()
			vim.cmd("normal! k")
			vim.fn.winrestview({ topline = 2 })
		end)
		h.eq(3, cursor(win))
		h.eq(2, vim.api.nvim_win_call(win, vim.fn.winsaveview).topline)
		put("b", { "new" })
		h.eq(3, cursor(win))
		vim.api.nvim_exec_autocmds("WinScrolled", {})
		put("c", { "latest" })
		h.eq(3, cursor(win))
	end,

	["one k immediately before a streaming flush pauses following"] = function()
		local win = fresh()
		transcript.set("a", "message", { lines = { "one", "two", "three", "four", "five" }, folds = {} })
		vim.api.nvim_win_call(win, function()
			vim.cmd("normal! k")
		end)
		transcript.flush()
		h.eq(3, cursor(win))
	end,

	["idle submission resumes following"] = function()
		h.eq(6, submission(false))
	end,

	["steering does not resume following"] = function()
		h.eq(1, submission(true, "steer"))
	end,

	["queued follow-up does not resume following"] = function()
		h.eq(1, submission(true, "followUp"))
	end,

	["focus changes do not resume following"] = function()
		local win = fresh()
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		observe()
		vim.api.nvim_set_current_win(win)
		vim.api.nvim_set_current_win(assert(layout.input_win()))
		put("b", { "new" })
		h.eq(1, cursor(win))
	end,
	["navigation just before a flush pauses even with bottom visible"] = function()
		local win = fresh()
		vim.api.nvim_win_set_cursor(win, { 2, 1 })
		put("b", { "new" })
		h.eq({ 2, 1 }, vim.api.nvim_win_get_cursor(win))
	end,

	["content end reattaches without visiting the separator"] = function()
		local win = fresh()
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		observe()
		vim.api.nvim_win_set_cursor(win, { 4, 0 })
		put("b", { "new" })
		h.eq(6, cursor(win))
	end,

	["deferred movement events do not detach plugin positioning"] = function()
		local win = fresh()
		observe()
		vim.api.nvim_exec_autocmds("WinScrolled", {})
		put("b", { "new" })
		observe()
		put("c", { "latest" })
		h.eq(8, cursor(win))
	end,

	["reading anchors move with earlier blocks and clamp on shrink"] = function()
		local win = fresh()
		put("b", { "alpha", "beta", "gamma" })
		vim.api.nvim_win_set_cursor(win, { 7, 3 })
		put("a", { "one" })
		h.eq({ 4, 3 }, vim.api.nvim_win_get_cursor(win))
		put("a", { "one", "two", "three", "four", "five" })
		h.eq({ 8, 3 }, vim.api.nvim_win_get_cursor(win))
		put("b", { "x" })
		h.eq({ 8, 0 }, vim.api.nvim_win_get_cursor(win))
	end,

	["windows follow independently and recreated windows start following"] = function()
		local win, buf = fresh()
		vim.api.nvim_set_current_win(win)
		vim.cmd("vsplit")
		local second = vim.api.nvim_get_current_win()
		observe()
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		put("b", { "new" })
		h.eq(1, cursor(win))
		h.eq(6, cursor(second))
		vim.api.nvim_win_close(second, true)
		vim.api.nvim_set_current_win(win)
		vim.cmd("vsplit")
		second = vim.api.nvim_get_current_win()
		h.eq(buf, vim.api.nvim_win_get_buf(second))
		put("c", { "latest" })
		h.eq(8, cursor(second))
		h.eq(1, cursor(win))
	end,

	["reset starts following again"] = function()
		local win = fresh()
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		observe()
		transcript.reset()
		put("new", { "a", "b", "c" })
		h.eq(3, cursor(win))
	end,

	["fold application preserves reading and falls back to header"] = function()
		local win = fresh()
		vim.api.nvim_win_set_cursor(win, { 3, 0 })
		put("a", { "header", "inside", "inside", "end" }, { { first = 0, last = 2, kind = "thinking" } })
		h.eq(1, cursor(win))
		put("b", { "new" })
		h.eq(1, cursor(win))
		h.eq(
			1,
			vim.api.nvim_win_call(win, function()
				return vim.fn.foldclosed(3)
			end)
		)
	end,

	["upward viewport scroll pauses and downward bottom scroll resumes"] = function()
		local win = fresh()
		local lines = {}
		for i = 1, 100 do
			lines[i] = "line " .. i
		end
		put("a", lines)
		vim.api.nvim_win_call(win, function()
			vim.cmd("normal! 3\25")
		end)
		observe()
		local before = cursor(win)
		put("b", { "new" })
		h.eq(before, cursor(win))
		vim.api.nvim_win_call(win, function()
			vim.cmd("normal! 100\5")
		end)
		observe()
		put("c", { "latest" })
		h.eq(104, cursor(win))
	end,

	["wrapped viewport and cursor column survive earlier block growth"] = function()
		local win = fresh()
		vim.wo[win].smoothscroll = true
		vim.api.nvim_win_call(win, function()
			vim.cmd("vertical resize 30")
		end)
		local lines = {}
		for i = 1, 40 do
			lines[i] = string.rep("wrapped text ", 20)
		end
		put("b", lines)
		vim.api.nvim_win_call(win, function()
			vim.api.nvim_win_set_cursor(win, { 20, 80 })
			vim.fn.winrestview({ lnum = 20, col = 80, topline = 20, skipcol = vim.api.nvim_win_get_width(win) })
		end)
		local before = vim.api.nvim_win_call(win, function()
			vim.fn.winline()
			return vim.fn.winsaveview()
		end)
		put("a", { "short" })
		local after = vim.api.nvim_win_call(win, vim.fn.winsaveview)
		h.eq(before.lnum - 3, after.lnum)
		h.eq(before.topline - 3, after.topline)
		h.ok(before.skipcol > 0, "a partially scrolled wrapped line was captured")
		h.eq(before.skipcol, after.skipcol)
		h.eq(before.col, after.col)
	end,

	["explicit resume affects only the primary window"] = function()
		local win, buf = fresh()
		vim.api.nvim_set_current_win(win)
		vim.cmd("vsplit")
		local second = vim.api.nvim_get_current_win()
		observe()
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		vim.api.nvim_win_set_cursor(second, { 1, 0 })
		observe()
		view.resume(win, buf)
		put("b", { "new" })
		h.eq(6, cursor(win))
		h.eq(1, cursor(second))
	end,
}
