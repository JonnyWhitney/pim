local h = require("helpers")
local client = require("pim.rpc.client")
local config = require("pim.config")
local layout = require("pim.ui.layout")
local sessions = require("pim.sessions")
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

	["session switch is rechecked after the picker returns"] = function()
		local choice = { id = "session-1", path = "/tmp/session-1.jsonl", mtime = 0, message_count = 0 }
		local choose
		local switched = 0
		local real_list = sessions.list
		local real_switch = client.switch_session
		local real_select = vim.ui.select
		local real_notify = vim.notify
		---@diagnostic disable-next-line: duplicate-set-field
		sessions.list = function()
			return { choice }
		end
		---@diagnostic disable-next-line: duplicate-set-field
		client.switch_session = function()
			switched = switched + 1
		end
		vim.ui.select = function(_, _, callback)
			choose = callback
		end
		vim.notify = function() end

		local ok, err = pcall(function()
			require("pim.ui.pickers").session()
			state.handle_event({ type = "agent_start" })
			state.handle_event({ type = "agent_end", willRetry = false })
			assert(choose)(choice)
		end)
		sessions.list = real_list
		client.switch_session = real_switch
		vim.ui.select = real_select
		vim.notify = real_notify
		if not ok then
			error(err, 0)
		end

		h.eq(0, switched, "a run started while the picker was open")
	end,

	["session actions stay blocked after agent_end until agent_settled"] = function()
		state.handle_event({ type = "agent_start" })
		state.handle_event({ type = "agent_end", willRetry = false })

		local calls = { new_session = 0, session_list = 0, fork_messages = 0, fork = 0, clone = 0 }
		local real_new = client.new_session
		local real_list = sessions.list
		local real_messages = client.get_fork_messages
		local real_fork = client.fork
		local real_clone = client.clone
		---@diagnostic disable-next-line: duplicate-set-field
		client.new_session = function()
			calls.new_session = calls.new_session + 1
		end
		---@diagnostic disable-next-line: duplicate-set-field
		sessions.list = function()
			calls.session_list = calls.session_list + 1
			return {}
		end
		---@diagnostic disable-next-line: duplicate-set-field
		client.get_fork_messages = function()
			calls.fork_messages = calls.fork_messages + 1
		end
		---@diagnostic disable-next-line: duplicate-set-field
		client.fork = function()
			calls.fork = calls.fork + 1
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
			require("pim").new_session()
			require("pim.ui.pickers").session()
			require("pim.ui.pickers").fork()
			require("pim").fork("entry-1")
			require("pim").clone()
		end)

		client.new_session = real_new
		sessions.list = real_list
		client.get_fork_messages = real_messages
		client.fork = real_fork
		client.clone = real_clone
		vim.notify = real_notify
		if not ok then
			error(err, 0)
		end

		h.eq({ new_session = 0, session_list = 0, fork_messages = 0, fork = 0, clone = 0 }, calls)
		h.eq(5, #notifications)
		for _, notification in ipairs(notifications) do
			h.ok(notification:find("while pi is busy", 1, true), "blocked action explains why it is unavailable")
		end
	end,
}
