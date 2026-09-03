local h = require("helpers")
local client = require("pim.rpc.client")
local config = require("pim.config")
local layout = require("pim.ui.layout")
local state = require("pim.state")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function start_pim()
	config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" } })
	require("pim").start()
	h.wait_until(function()
		return state.get().connected
	end, "pim to connect", 5000)
end

local function input_text()
	return table.concat(vim.api.nvim_buf_get_lines(assert(layout.input_buf()), 0, -1, false), "\n")
end

local function with_select(stub, fn)
	local original = vim.ui.select
	vim.ui.select = stub
	local ok, err = pcall(fn)
	vim.ui.select = original
	if not ok then
		error(err, 0)
	end
end

return {
	["fork picker creates a session and replaces the input draft"] = function()
		start_pim()
		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "discard this draft" })

		local seen
		with_select(function(items, opts, on_choice)
			seen = { items = items, prompt = opts.prompt }
			on_choice(items[2])
		end, function()
			require("pim.ui.pickers").fork()
			h.wait_until(function()
				return state.get().session_id == "forked-session" and input_text() == "Fix the parser error"
			end, "the forked session and prompt", 5000)
		end)

		h.eq("pi fork from prompt", seen.prompt)
		h.eq("Start the parser", seen.items[1].text)
		h.eq("Fix the parser error", seen.items[2].text)
	end,

	["clone creates a session and clears the input draft"] = function()
		start_pim()
		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "discard this draft" })

		require("pim").clone()
		h.wait_until(function()
			return state.get().session_id == "cloned-session" and input_text() == ""
		end, "the cloned session and empty input", 5000)
	end,

	["fork and clone reject busy sessions before sending requests"] = function()
		state.update({ is_streaming = true })

		local calls = { fork_messages = 0, clone = 0 }
		local real_messages, real_clone = client.get_fork_messages, client.clone
		---@diagnostic disable-next-line: duplicate-set-field
		client.get_fork_messages = function()
			calls.fork_messages = calls.fork_messages + 1
		end
		---@diagnostic disable-next-line: duplicate-set-field
		client.clone = function()
			calls.clone = calls.clone + 1
		end

		local notifications = {}
		local real_notify = vim.notify
		vim.notify = function(message)
			notifications[#notifications + 1] = message
		end

		local ok, err = pcall(function()
			require("pim.ui.pickers").fork()
			require("pim").clone()
		end)

		client.get_fork_messages, client.clone = real_messages, real_clone
		vim.notify = real_notify
		if not ok then
			error(err, 0)
		end

		h.eq({ fork_messages = 0, clone = 0 }, calls)
		h.eq(2, #notifications)
		h.ok(notifications[1]:find("while pi is busy", 1, true), "fork explains why it is unavailable")
		h.ok(notifications[2]:find("while pi is busy", 1, true), "clone explains why it is unavailable")
	end,
}
