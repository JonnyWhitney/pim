local h = require("helpers")
local config = require("pim.config")
local layout = require("pim.ui.layout")
local input = require("pim.ui.input")
local client = require("pim.rpc.client")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function fresh(opts)
	config.setup(opts)
	layout.open()
	vim.api.nvim_set_current_win(assert(layout.input_win()))
	vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, {})
	input.setup()
end

local function with_fake_pi()
	fresh({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" } })
	client.start({ on_event = require("pim.events").handle })
end

local function input_text()
	return table.concat(vim.api.nvim_buf_get_lines(assert(layout.input_buf()), 0, -1, false), "\n")
end

local function feed(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function wait_text(expected, what)
	h.wait_until(function()
		return input_text() == expected
	end, ("%s: the input buffer to hold %q, it holds %q"):format(what or "wait_text", expected, input_text()))
end

local function wait_height(win, expected, what)
	h.wait_until(function()
		return vim.api.nvim_win_get_height(win) == expected
	end, ("%s: window height %d, it is %d"):format(what, expected, vim.api.nvim_win_get_height(win)))
end

return {
	["input window grows and shrinks with content, clamped"] = function()
		fresh()
		local win = assert(layout.input_win())
		local lines = {}
		for i = 1, 6 do
			lines[i] = "line " .. i
		end
		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, lines)
		wait_height(win, 6, "grow to content")

		for i = 1, 40 do
			lines[i] = "line " .. i
		end
		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, lines)
		wait_height(win, config.get().input.max_height, "clamp to max_height")

		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, {})
		wait_height(win, config.get().input.min_height, "shrink to min_height")
	end,

	["submit without pi restores the text"] = function()
		fresh()
		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "precious draft" })
		input.submit()
		wait_text("precious draft", "restore on reject")
	end,

	["a rejected prompt does not overwrite text typed since"] = function()
		fresh()

		local reject
		local notified = {}
		local real_prompt, real_notify = client.prompt, vim.notify
		---@diagnostic disable-next-line: duplicate-set-field
		client.prompt = function(_, _, callback)
			reject = function()
				callback(false, "preflight refused it")
			end
		end
		vim.notify = function(message, level)
			notified[#notified + 1] = { message = message, level = level }
		end

		local ok, err = pcall(function()
			vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "original prompt" })
			input.submit()
			wait_text("", "cleared on submit")

			vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "a brand new thought" })
			reject()

			h.settle(100)
			h.eq("a brand new thought", input_text(), "the text typed since must win")
		end)
		client.prompt, vim.notify = real_prompt, real_notify
		if not ok then
			error(err, 0)
		end

		h.ok(
			vim.iter(notified):any(function(n)
				return n.message:find("<Up>", 1, true) ~= nil
			end),
			"the user is told how to recall the rejected prompt, got: " .. vim.inspect(notified)
		)

		feed("<Up>")
		wait_text("original prompt", "<Up> recalls the rejected prompt")
		feed("<Down>")
		wait_text("a brand new thought", "<Down> returns the draft")
	end,

	["cleared queued prompts stay distinct and the first returns to empty input"] = function()
		fresh()
		input.restore_queued({ "change direction", "also add tests", "write docs" })

		h.eq("change direction", input_text(), "the next prompt in delivery order is restored")
		feed("<Up>")
		wait_text("write docs", "the follow-up remains a separate history entry")
		feed("<Up>")
		wait_text("also add tests", "the second steering prompt remains separate")
		feed("<Up>")
		wait_text("change direction", "the first steering prompt remains in history")
	end,

	["cleared queued prompts do not overwrite a newer draft"] = function()
		fresh()
		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "newer draft" })
		local notified = {}
		local real_notify = vim.notify
		vim.notify = function(message, level)
			notified[#notified + 1] = { message = message, level = level }
		end

		local ok, err = pcall(input.restore_queued, { "queued steer", "queued follow-up" })
		vim.notify = real_notify
		if not ok then
			error(err, 0)
		end

		h.eq("newer draft", input_text(), "the newer draft wins")
		h.eq(1, #notified, "one short recovery notice is shown")
		h.ok(notified[1].message:find("<Up>", 1, true), "the notice explains how to recall queued text")
		feed("<Up>")
		wait_text("queued follow-up", "recovered prompts were added to history")
	end,

	["history recalls submitted prompts on <Up> and returns via <Down>"] = function()
		with_fake_pi()
		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "first prompt" })
		input.submit()
		wait_text("", "cleared after first submit")
		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "second prompt" })
		input.submit()
		wait_text("", "cleared after second submit")

		feed("<Up>")
		wait_text("second prompt", "first <Up>")
		feed("<Up>")
		wait_text("first prompt", "second <Up>")
		feed("<Down>")
		wait_text("second prompt", "<Down> back")
		feed("<Down>")
		wait_text("", "<Down> to empty draft")
	end,

	["history preserves the draft being typed"] = function()
		with_fake_pi()
		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "sent already" })
		input.submit()
		wait_text("", "cleared after submit")

		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "work in progress" })
		feed("<Up>")
		wait_text("sent already", "recalled entry")
		feed("<Down>")
		wait_text("work in progress", "draft restored")
	end,

	["<Up> on a lower line moves the cursor instead of recalling"] = function()
		with_fake_pi()
		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "sent" })
		input.submit()
		wait_text("", "cleared after submit")

		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "alpha", "beta" })
		vim.api.nvim_win_set_cursor(assert(layout.input_win()), { 2, 0 })
		feed("<Up>")

		h.settle(100)
		h.eq("alpha\nbeta", input_text())
		h.eq(1, vim.api.nvim_win_get_cursor(assert(layout.input_win()))[1])
	end,
}
