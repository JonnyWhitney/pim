local h = require("helpers")
local client = require("pim.rpc.client")
local config = require("pim.config")
local input = require("pim.ui.input")
local layout = require("pim.ui.layout")
local state = require("pim.state")
local tree = require("pim.ui.tree")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function start_pim()
	config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" } })
	require("pim").start()
	h.wait_until(function()
		return state.get().connected
	end, "pim to connect", 5000)
end

local function feed(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function transcript_text()
	return table.concat(vim.api.nvim_buf_get_lines(layout.transcript_buf(), 0, -1, false), "\n")
end

return {
	["tree renders session branches and locks the input"] = function()
		start_pim()
		tree.open()
		h.wait_until(tree.is_open, "the tree to open", 5000)

		local rendered = transcript_text()
		h.ok(rendered:find("# pi tree", 1, true), "tree heading renders")
		h.ok(rendered:find("Fix the parser error [parser work]", 1, true), "labels render")
		h.ok(rendered:find("●", 1, true), "active leaf is marked")
		h.eq(false, vim.bo[layout.input_buf()].modifiable)
		h.eq(layout.transcript_win(), vim.api.nvim_get_current_win(), "tree receives focus")

		local start_line = vim.api.nvim_win_get_cursor(layout.transcript_win())[1]
		feed("j")
		h.eq(start_line + 1, vim.api.nvim_win_get_cursor(layout.transcript_win())[1], "j moves to the next entry")
		feed("k")
		h.eq(start_line, vim.api.nvim_win_get_cursor(layout.transcript_win())[1], "k moves to the previous entry")
	end,

	["tree blocks prompt submission and q restores the active transcript"] = function()
		start_pim()
		tree.open()
		h.wait_until(tree.is_open, "the tree to open", 5000)

		local calls = 0
		local real_prompt = client.prompt
		client.prompt = function()
			calls = calls + 1
		end
		local notified
		local real_notify = vim.notify
		vim.notify = function(message)
			notified = message
		end

		local ok, err = pcall(function()
			input.send("do not send")
		end)
		client.prompt = real_prompt
		vim.notify = real_notify
		if not ok then
			error(err, 0)
		end

		h.eq(0, calls)
		h.ok(notified:find("Close the tree", 1, true), "blocked send explains how to continue")

		feed("q")
		h.wait_until(function()
			return not tree.is_open() and vim.bo[layout.input_buf()].modifiable
		end, "the tree to close", 5000)
	end,

	["enter closes the tree"] = function()
		start_pim()
		tree.open()
		h.wait_until(tree.is_open, "the tree to open", 5000)

		feed("<CR>")
		h.wait_until(function()
			return not tree.is_open() and vim.bo[layout.input_buf()].modifiable
		end, "enter to close the tree", 5000)
	end,

	["tree does not open while pi is busy"] = function()
		state.update({ is_streaming = true })
		local calls = 0
		local real_get_tree = client.get_tree
		client.get_tree = function()
			calls = calls + 1
		end
		local notified
		local real_notify = vim.notify
		vim.notify = function(message)
			notified = message
		end

		local ok, err = pcall(tree.open)
		client.get_tree = real_get_tree
		vim.notify = real_notify
		if not ok then
			error(err, 0)
		end

		h.eq(0, calls)
		h.ok(notified:find("while pi is busy", 1, true), "busy state explains why tree is unavailable")
	end,
}
