local h = require("helpers")
local client = require("pim.rpc.client")
local config = require("pim.config")
local layout = require("pim.ui.layout")
local statusline = require("pim.ui.statusline")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function fake_pi_config()
	config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" } })
end

local function test_tab(defer, text)
	vim.cmd("tabnew")
	local tab = vim.api.nvim_get_current_tabpage()
	local buf = vim.api.nvim_get_current_buf()
	defer(function()
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end)
	defer(function()
		if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
			vim.api.nvim_set_current_tabpage(tab)
			vim.cmd("tabclose!")
		end
	end)
	if text then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
	end
	return tab
end

local function with_guard_tab(fn)
	return h.with_cleanup(function(defer)
		fake_pi_config()
		local guard = test_tab(defer, "guard")
		defer(require("pim.lifecycle").cleanup)
		require("pim").start()
		return fn(guard, vim.api.nvim_get_current_tabpage())
	end)
end

local function with_answer(answer, fn)
	return h.with_cleanup(function(defer)
		local prompts, completed = {}, false
		h.patch(defer, vim.ui, "select", function(_, opts, on_choice)
			prompts[#prompts + 1] = opts.prompt
			on_choice(answer)
		end)
		-- Failed waits can leave scheduled close prompts. The stub is kept through cleanup.
		defer(function()
			if not completed then
				h.settle(50)
			end
		end)
		defer(function()
			if not completed then
				require("pim.lifecycle").cleanup()
			end
		end)
		fn(prompts)
		completed = true
		return prompts
	end)
end

local function start_and_connect()
	fake_pi_config()
	require("pim").start()
	h.wait_until(function()
		return require("pim.state").get().connected
	end, "the initial connect to fake pi", 5000)
end

local function fake_argv()
	local argv
	client.get_state(function(success, data)
		if success then
			argv = data.fakeArgv
		end
	end)
	h.wait_until(function()
		return argv ~= nil
	end, "a get_state reply carrying fakeArgv", 5000)
	return argv
end

return {
	["startup and cleanup preserve old data in an isolated child"] = function()
		h.with_cleanup(function(defer)
			local directory = vim.fn.tempname()
			defer(function()
				h.eq(0, vim.fn.delete(directory, "rf"))
			end)
			vim.fn.mkdir(directory, "p")
			local child = vim.fn.jobstart({ vim.v.progpath, "--clean", "--headless", "--embed" }, {
				rpc = true,
				env = { XDG_DATA_HOME = directory .. "/data", PI_CODING_AGENT_DIR = directory .. "/agent" },
			})
			h.ok(child > 0, "child Neovim was started")
			defer(function()
				vim.fn.jobstop(child)
				h.ok(vim.fn.jobwait({ child }, 3000)[1] ~= -1, "child Neovim exit was awaited")
			end)
			defer(function()
				vim.rpcrequest(child, "nvim_exec_lua", "require('pim.lifecycle').cleanup()", {})
			end)
			local result = vim.rpcrequest(
				child,
				"nvim_exec_lua",
				[[
				local root, isolated = ...
				vim.opt.rtp:prepend(root)
				local data = vim.fn.stdpath('data')
				assert(vim.startswith(data, isolated .. '/data/'), 'data must be isolated')
				local old_root = data .. '/pim/subagents/old-parent/old-invocation'
				vim.fn.mkdir(old_root, 'p')
				local files = {
					['invocation.json'] = '{"schemaVersion":1,"invocationId":"old-invocation"}',
					['child-1.jsonl'] = '{"type":"message","text":"retained content"}',
					['orphan.json'] = '{"firstSeen":"old marker"}',
				}
				for name, text in pairs(files) do vim.fn.writefile({text}, old_root .. '/' .. name) end
				local function unchanged()
					for name, text in pairs(files) do
						assert(vim.deep_equal({text}, vim.fn.readfile(old_root .. '/' .. name)), name .. ' changed')
					end
				end
				require('pim.config').setup({pi_cmd={vim.v.progpath, '-l', root .. '/tests/fake_pi.lua'}})
				require('pim').start()
				unchanged()
				require('pim.lifecycle').cleanup()
				unchanged()
				return true
			]],
				{ vim.fn.fnamemodify(tests_dir, ":h"), directory }
			)
			h.eq(true, result)
		end)
	end,
	["a blank tab is reused instead of opening a new one"] = function()
		h.with_cleanup(function(defer)
			local blank_tab = test_tab(defer)
			defer(require("pim.lifecycle").cleanup)
			local tabs_before = #vim.api.nvim_list_tabpages()

			layout.open()

			h.eq(tabs_before, #vim.api.nvim_list_tabpages(), "no extra tab created")
			h.eq(blank_tab, vim.api.nvim_get_current_tabpage(), "pi lives in the reused tab")
			h.ok(layout.is_open())
		end)
	end,

	["a tab with real content is left alone"] = function()
		h.with_cleanup(function(defer)
			local work_tab = test_tab(defer, "precious work")
			defer(require("pim.lifecycle").cleanup)
			local tabs_before = #vim.api.nvim_list_tabpages()

			layout.open()

			h.eq(tabs_before + 1, #vim.api.nvim_list_tabpages(), "new tab created")
			h.ok(vim.api.nvim_get_current_tabpage() ~= work_tab, "pi opened away from the work tab")
		end)
	end,

	["a missing pi binary is reported, not raised"] = function()
		config.setup({ pi_cmd = "pim-definitely-not-a-real-binary" })

		local notified = {}
		local real_notify = vim.notify
		vim.notify = function(message, level)
			notified[#notified + 1] = { message = message, level = level }
		end
		local ok, err = pcall(require("pim").start)
		vim.notify = real_notify

		h.ok(ok, ":PiStart did not raise: " .. tostring(err))

		local state = require("pim.state").get()
		h.ok(state.spawn_error ~= nil, "the failure is recorded in state")
		h.eq(false, state.connected)

		h.eq(1, #notified, "exactly one notification")
		h.eq(vim.log.levels.ERROR, notified[1].level)
		h.ok(notified[1].message:find("Cannot start pi", 1, true), "notification explains the failure")
		h.ok(notified[1].message:find("pi_cmd", 1, true), "notification names the offending setting")

		h.ok(layout.is_open(), "the pi tab is still open")
		local rendered = table.concat(vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false), "\n")
		h.ok(rendered:find("Cannot start pi", 1, true), "the transcript explains itself, got: " .. rendered)
	end,

	["stop destroys the pi UI as well as the process"] = function()
		with_guard_tab(function(_, pi_tab)
			local tabs_before = #vim.api.nvim_list_tabpages()
			local transcript = assert(layout.transcript_buf())
			local input = assert(layout.input_buf())

			local prompts = with_answer("Yes", function()
				require("pim").stop()
			end)

			h.eq(1, #prompts, "asked before leaving")
			h.eq(false, client.is_running(), "pi was stopped")
			h.eq(tabs_before - 1, #vim.api.nvim_list_tabpages(), "the pi tab is gone")
			h.ok(not vim.api.nvim_tabpage_is_valid(pi_tab), "specifically the pi tab")
			h.eq(false, layout.is_open())
			h.eq(nil, layout.transcript_buf(), "the transcript reference was cleared")
			h.eq(nil, layout.input_buf(), "the input reference was cleared")
			h.eq(false, vim.api.nvim_buf_is_valid(transcript), "the transcript buffer was deleted")
			h.eq(false, vim.api.nvim_buf_is_valid(input), "the input buffer was deleted")
		end)
	end,

	["declining stop leaves everything running"] = function()
		with_guard_tab(function(_, pi_tab)
			local tabs_before = #vim.api.nvim_list_tabpages()

			with_answer("No", function()
				require("pim").stop()
			end)

			h.eq(true, client.is_running(), "pi kept running")
			h.eq(tabs_before, #vim.api.nvim_list_tabpages(), "no tab was closed")
			h.ok(vim.api.nvim_tabpage_is_valid(pi_tab), "the pi tab is intact")
			h.eq(true, layout.is_open())
		end)
	end,

	["stop with confirm disabled asks nothing (:PiStop!)"] = function()
		with_guard_tab(function()
			local prompts = with_answer("No", function()
				require("pim").stop({ confirm = false })
			end)

			h.eq(0, #prompts, "the bang form skips the prompt")
			h.eq(false, client.is_running(), "pi was stopped anyway")
			h.eq(false, layout.is_open())
		end)
	end,

	["stop does not offer to close a tab that is already hidden"] = function()
		with_guard_tab(function()
			require("pim").toggle()

			local prompts = with_answer("Yes", function()
				require("pim").stop()
			end)

			h.eq(1, #prompts)
			h.eq("Stop pi?", prompts[1], "no promise to close a tab that is not there")
			h.eq(false, client.is_running())
		end)
	end,

	["closing the input window asks before tearing anything down"] = function()
		with_guard_tab(function(_, pi_tab)
			local prompts = with_answer("No", function()
				vim.api.nvim_win_close(assert(layout.input_win()), true)
				h.wait_until(function()
					return layout.is_open()
				end, "the declined close to restore the input window", 1000)
			end)

			h.eq(1, #prompts, "asked exactly once")
			h.ok(prompts[1]:find("Stop pi", 1, true), "prompt names the consequence, got: " .. tostring(prompts[1]))

			h.ok(layout.is_open(), "the input window came back")
			h.eq(pi_tab, vim.api.nvim_get_current_tabpage(), "restored into the same tab")
			h.eq(true, client.is_running(), "pi kept running")
		end)
	end,

	["confirming the close stops pi and closes the tab"] = function()
		with_guard_tab(function(_, pi_tab)
			with_answer("Yes", function()
				vim.api.nvim_win_close(assert(layout.input_win()), true)
				h.wait_until(function()
					return not client.is_running()
				end, "pi to stop after confirming the close", 3000)
			end)

			h.eq(false, client.is_running(), "pi was stopped")
			h.ok(not vim.api.nvim_tabpage_is_valid(pi_tab), "the pi tab is gone")
		end)
	end,

	["declining twice keeps working"] = function()
		with_guard_tab(function()
			for attempt = 1, 2 do
				local prompts = with_answer("No", function()
					vim.api.nvim_win_close(assert(layout.input_win()), true)
					h.wait_until(function()
						return layout.is_open()
					end, "the input window to come back on attempt " .. attempt, 1000)
				end)
				h.eq(1, #prompts, "asked on attempt " .. attempt)
				h.ok(layout.is_open(), "restored on attempt " .. attempt)
			end
		end)
	end,

	["toggling the UI closed does not ask anything"] = function()
		with_guard_tab(function()
			local prompts = with_answer("Yes", function()
				require("pim").toggle()
				h.settle(200)
			end)

			h.eq(0, #prompts, "hiding the UI is not leaving")
			h.eq(true, client.is_running(), "pi keeps running while hidden")
			h.eq(false, layout.is_open())
		end)
	end,

	["leaving Neovim stops the UI timers before pi shuts down"] = function()
		local function active_timers()
			local count = 0
			vim.uv.walk(function(handle)
				if handle:get_type() == "timer" and handle:is_active() then
					count = count + 1
				end
			end)
			return count
		end

		with_guard_tab(function()
			h.wait_until(client.is_running, "fake pi start", 5000)
			local idle = active_timers()
			require("pim.state").update({ run_active = true, is_streaming = true })
			h.wait_until(function()
				return active_timers() > idle
			end, "the busy spinner timer", 2000)

			-- Keep pi alive so only the exit hook itself can close the UI timers.
			local real_stop = client.stop
			---@diagnostic disable-next-line: duplicate-set-field
			client.stop = function() end
			local ok, err = pcall(vim.api.nvim_exec_autocmds, "VimLeavePre", { group = "pim-shutdown" })
			client.stop = real_stop
			if not ok then
				error(err, 0)
			end
			local after_hook = active_timers()

			-- A second explicit shutdown closes nothing more when the hook already did the work.
			statusline.shutdown()
			require("pim.ui.transcript").shutdown()
			h.eq(after_hook, active_timers(), "the UI timers are closed by the exit hook")
			h.ok(after_hook <= idle, "no UI timer survives exit")

			require("pim").stop({ confirm = false })
		end)
	end,

	["repeated start/stop cycles accumulate nothing"] = function()
		local function census()
			local groups = {}
			for _, group in ipairs({ "pim-shutdown", "pim-exit" }) do
				local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = group })
				groups[group] = ok and #autocmds or 0
			end
			local buffers = 0
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				local name = vim.api.nvim_buf_get_name(buf)
				if name:find("pim://", 1, true) then
					buffers = buffers + 1
				end
			end
			return {
				shutdown = groups["pim-shutdown"],
				exit = groups["pim-exit"],
				pi_buffers = buffers,
				tabs = #vim.api.nvim_list_tabpages(),
			}
		end

		with_guard_tab(function()
			require("pim").stop({ confirm = false })
			local baseline = census()

			for cycle = 1, 3 do
				require("pim").start()
				require("pim").stop({ confirm = false })
				h.eq(baseline, census(), "state accumulated after cycle " .. cycle)
			end

			h.eq(0, baseline.shutdown, "stop removes the VimLeavePre autocmd")
			h.eq(0, baseline.pi_buffers, "stop leaves no pim buffers")
		end)
	end,

	["restart passes --session when the session file is known"] = function()
		h.with_cleanup(function(defer)
			local session_file = vim.fn.tempname() .. ".jsonl"
			defer(function()
				h.eq(0, vim.fn.delete(session_file))
			end)
			vim.fn.writefile({ '{"type":"session","version":3,"id":"x"}' }, session_file)

			start_and_connect()

			require("pim.state").update({ session_file = session_file })
			require("pim").restart()

			local argv = fake_argv()
			h.ok(vim.list_contains(argv, "--session"), "--session flag passed")
			h.ok(vim.list_contains(argv, session_file), "session path passed")
		end)
	end,

	["restart without a session file passes no --session"] = function()
		start_and_connect()

		local state = require("pim.state")
		state.update({ session_file = "/tmp/pim-should-be-cleared.jsonl" })
		state.update({ session_file = state.NONE })
		h.eq(nil, state.get().session_file, "the clear has to actually happen")

		require("pim").restart()

		h.ok(not vim.list_contains(fake_argv(), "--session"), "no --session flag")
	end,

	["restart passes no --session when the session file is gone"] = function()
		start_and_connect()

		local missing = vim.fn.tempname() .. ".jsonl"
		require("pim.state").update({ session_file = missing })
		require("pim").restart()

		local argv = fake_argv()
		h.ok(not vim.list_contains(argv, "--session"), "no --session flag for a path that no longer exists")
		h.ok(not vim.list_contains(argv, missing), "and not the stale path either")
	end,

	["agent abort clears queued prompts before aborting the run"] = function()
		config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua", "queue" } })
		require("pim").start()
		h.wait_until(function()
			return require("pim.state").get().connected
		end, "the queued fake pi connection", 5000)

		h.with_cleanup(function(defer)
			local sent = {}
			local real_request = client.request
			h.patch(defer, client, "request", function(command_type, params, callback)
				sent[#sent + 1] = command_type
				return real_request(command_type, params, callback)
			end)
			require("pim.state").handle_event({ type = "agent_start" })
			require("pim.state").handle_event({ type = "agent_end", willRetry = false })
			require("pim").abort()
			h.wait_until(function()
				return sent[#sent] == "abort"
			end, "clear_queue followed by abort", 5000)

			h.eq({ "clear_queue", "abort" }, sent)
			local input_text = table.concat(vim.api.nvim_buf_get_lines(assert(layout.input_buf()), 0, -1, false), "\n")
			h.eq("change direction", input_text, "the first queued message returns to input")
		end)
	end,

	["agent abort still runs after clear_queue fails"] = function()
		config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua", "clearfail" } })
		require("pim").start()
		h.wait_until(function()
			return require("pim.state").get().connected
		end, "the clear-failure fake pi connection", 5000)

		local sent, notified = {}, {}
		h.with_cleanup(function(defer)
			local real_request = client.request
			h.patch(defer, client, "request", function(command_type, params, callback)
				sent[#sent + 1] = command_type
				return real_request(command_type, params, callback)
			end)
			h.patch(defer, vim, "notify", function(message, level)
				notified[#notified + 1] = { message = message, level = level }
			end)
			require("pim.state").update({ run_active = true, is_streaming = true })
			require("pim").abort()
			h.wait_until(function()
				return sent[#sent] == "abort"
			end, "abort after clear_queue failure", 5000)
		end)

		h.eq({ "clear_queue", "abort" }, sent)
		h.ok(
			vim.iter(notified):any(function(item)
				return item.message:find("clear_queue failed", 1, true) ~= nil
			end),
			"the failed recovery is reported"
		)
	end,

	["runtime cleanup is idempotent and keeps configuration and the event log"] = function()
		start_and_connect()
		local log = require("pim.log")
		local input = require("pim.ui.input")
		local lifecycle = require("pim.lifecycle")
		local configured_command = vim.deepcopy(config.get().pi_cmd)

		log.add("*", "keep this process log")
		input.restore_queued({ "old queued prompt" })
		input.set_locked(true)
		require("pim.state").update({ is_streaming = true, bash_running = true, session_name = "old" })

		lifecycle.cleanup()
		lifecycle.cleanup()

		h.eq(false, client.is_running())
		h.eq(false, input.is_locked())
		h.eq(false, require("pim.ui.tree").is_open())
		h.eq(nil, layout.transcript_buf())
		h.eq(nil, layout.input_buf())
		h.eq(false, require("pim.state").get().is_streaming)
		h.eq(false, require("pim.state").get().bash_running)
		h.eq(nil, require("pim.state").get().session_name)
		h.eq(configured_command, config.get().pi_cmd, "cleanup keeps user configuration")
		h.ok(
			table.concat(log.lines(), "\n"):find("keep this process log", 1, true),
			"cleanup keeps the previous process log"
		)

		layout.open()
		input.setup()
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Up>", true, false, true), "x", false)
		h.settle(50)
		h.eq({ "" }, vim.api.nvim_buf_get_lines(assert(layout.input_buf()), 0, -1, false), "input history was reset")
		h.eq({ "" }, vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false), "transcript was reset")
		h.eq({}, require("pim.completion.data").command_candidates(), "slash-command completion was reset")
	end,

	["log clears for a new process but not session changes, toggles, or stop"] = function()
		with_guard_tab(function()
			start_and_connect()
			local log = require("pim.log")
			log.add("*", "marker before session actions")

			require("pim.sessions").new()
			h.wait_until(function()
				return require("pim.state").get().session_id == "fresh-session"
			end, "new session refresh", 5000)
			require("pim").toggle()
			require("pim").toggle()
			h.ok(
				table.concat(log.lines(), "\n"):find("marker before session actions", 1, true),
				"new session and toggle keep the process log"
			)

			require("pim").restart()
			h.wait_until(function()
				return require("pim.state").get().connected
			end, "restart connection", 5000)
			h.ok(
				not table.concat(log.lines(), "\n"):find("marker before session actions", 1, true),
				"restart clears the old process log"
			)

			log.add("*", "marker before stop")
			require("pim").stop({ confirm = false })
			h.ok(table.concat(log.lines(), "\n"):find("marker before stop", 1, true), "stop keeps the process log")
		end)
	end,

	["an intentional stop reports stopped with no exit code"] = function()
		start_and_connect()

		client.stop()
		h.wait_until(function()
			return require("pim.state").get().stopped
		end, "the requested exit to reach state", 5000)

		local current = require("pim.state").get()
		h.eq(nil, current.exit_code, "a requested stop is not a crash")
		h.eq(false, current.connected)

		local bar = statusline.build(current)
		h.ok(bar:find("stopped", 1, true), "winbar reports a clean stop, got: " .. bar)
	end,
}
