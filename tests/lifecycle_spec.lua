local h = require("helpers")
local client = require("pim.rpc.client")
local config = require("pim.config")
local layout = require("pim.ui.layout")
local statusline = require("pim.ui.statusline")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function fake_pi_config()
	config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" } })
end

local function start_with_guard_tab()
	fake_pi_config()

	vim.cmd("tabnew")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "guard" })
	local guard = vim.api.nvim_get_current_tabpage()

	require("pim").start()
	return guard, vim.api.nvim_get_current_tabpage()
end

local function cleanup_guard(guard)
	if vim.api.nvim_tabpage_is_valid(guard) then
		vim.api.nvim_set_current_tabpage(guard)
		vim.bo.modified = false
		if #vim.api.nvim_list_tabpages() > 1 then
			vim.cmd("tabclose")
		end
	end
end

local function with_answer(answer, fn)
	local prompts = {}
	local real_select = vim.ui.select
	---@diagnostic disable-next-line: duplicate-set-field
	vim.ui.select = function(_, opts, on_choice)
		prompts[#prompts + 1] = opts.prompt
		on_choice(answer)
	end
	local ok, err = pcall(fn, prompts)
	vim.ui.select = real_select
	if not ok then
		error(err, 0)
	end
	return prompts
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
	["a blank tab is reused instead of opening a new one"] = function()
		vim.cmd("tabnew")
		local tabs_before = #vim.api.nvim_list_tabpages()
		local blank_tab = vim.api.nvim_get_current_tabpage()

		layout.open()

		h.eq(tabs_before, #vim.api.nvim_list_tabpages(), "no extra tab created")
		h.eq(blank_tab, vim.api.nvim_get_current_tabpage(), "pi lives in the reused tab")
		h.ok(layout.is_open())
	end,

	["a tab with real content is left alone"] = function()
		vim.cmd("tabnew")
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "precious work" })
		local tabs_before = #vim.api.nvim_list_tabpages()
		local work_tab = vim.api.nvim_get_current_tabpage()

		layout.open()

		h.eq(tabs_before + 1, #vim.api.nvim_list_tabpages(), "new tab created")
		h.ok(vim.api.nvim_get_current_tabpage() ~= work_tab, "pi opened away from the work tab")

		vim.api.nvim_set_current_tabpage(work_tab)
		vim.bo.modified = false
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
		local rendered = table.concat(vim.api.nvim_buf_get_lines(layout.transcript_buf(), 0, -1, false), "\n")
		h.ok(rendered:find("Cannot start pi", 1, true), "the transcript explains itself, got: " .. rendered)
	end,

	["stop closes the pi tab as well as the process"] = function()
		local guard, pi_tab = start_with_guard_tab()
		local tabs_before = #vim.api.nvim_list_tabpages()

		local prompts = with_answer("Yes", function()
			require("pim").stop()
		end)

		h.eq(1, #prompts, "asked before leaving")
		h.eq(false, client.is_running(), "pi was stopped")
		h.eq(tabs_before - 1, #vim.api.nvim_list_tabpages(), "the pi tab is gone")
		h.ok(not vim.api.nvim_tabpage_is_valid(pi_tab), "specifically the pi tab")
		h.eq(false, layout.is_open())

		cleanup_guard(guard)
	end,

	["declining stop leaves everything running"] = function()
		local guard, pi_tab = start_with_guard_tab()
		local tabs_before = #vim.api.nvim_list_tabpages()

		with_answer("No", function()
			require("pim").stop()
		end)

		h.eq(true, client.is_running(), "pi kept running")
		h.eq(tabs_before, #vim.api.nvim_list_tabpages(), "no tab was closed")
		h.ok(vim.api.nvim_tabpage_is_valid(pi_tab), "the pi tab is intact")
		h.eq(true, layout.is_open())

		cleanup_guard(guard)
	end,

	["stop with confirm disabled asks nothing (:PiStop!)"] = function()
		local guard = start_with_guard_tab()

		local prompts = with_answer("No", function()
			require("pim").stop({ confirm = false })
		end)

		h.eq(0, #prompts, "the bang form skips the prompt")
		h.eq(false, client.is_running(), "pi was stopped anyway")
		h.eq(false, layout.is_open())

		cleanup_guard(guard)
	end,

	["stop does not offer to close a tab that is already hidden"] = function()
		local guard = start_with_guard_tab()
		require("pim").toggle()

		local prompts = with_answer("Yes", function()
			require("pim").stop()
		end)

		h.eq(1, #prompts)
		h.eq("Stop pi?", prompts[1], "no promise to close a tab that is not there")
		h.eq(false, client.is_running())

		cleanup_guard(guard)
	end,

	["closing the input window asks before tearing anything down"] = function()
		local guard, pi_tab = start_with_guard_tab()

		local prompts = with_answer("No", function()
			vim.api.nvim_win_close(layout.input_win(), true)
			h.wait_until(function()
				return layout.is_open()
			end, "the declined close to restore the input window", 1000)
		end)

		h.eq(1, #prompts, "asked exactly once")
		h.ok(prompts[1]:find("Stop pi", 1, true), "prompt names the consequence, got: " .. tostring(prompts[1]))

		h.ok(layout.is_open(), "the input window came back")
		h.eq(pi_tab, vim.api.nvim_get_current_tabpage(), "restored into the same tab")
		h.eq(true, client.is_running(), "pi kept running")

		cleanup_guard(guard)
	end,

	["confirming the close stops pi and closes the tab"] = function()
		local guard, pi_tab = start_with_guard_tab()

		with_answer("Yes", function()
			vim.api.nvim_win_close(layout.input_win(), true)
			h.wait_until(function()
				return not client.is_running()
			end, "pi to stop after confirming the close", 3000)
		end)

		h.eq(false, client.is_running(), "pi was stopped")
		h.ok(not vim.api.nvim_tabpage_is_valid(pi_tab), "the pi tab is gone")

		cleanup_guard(guard)
	end,

	["declining twice keeps working"] = function()
		local guard = start_with_guard_tab()

		for attempt = 1, 2 do
			local prompts = with_answer("No", function()
				vim.api.nvim_win_close(layout.input_win(), true)
				h.wait_until(function()
					return layout.is_open()
				end, "the input window to come back on attempt " .. attempt, 1000)
			end)
			h.eq(1, #prompts, "asked on attempt " .. attempt)
			h.ok(layout.is_open(), "restored on attempt " .. attempt)
		end

		cleanup_guard(guard)
	end,

	["toggling the UI closed does not ask anything"] = function()
		local guard = start_with_guard_tab()

		local prompts = with_answer("Yes", function()
			require("pim").toggle()
			h.settle(200)
		end)

		h.eq(0, #prompts, "hiding the UI is not leaving")
		h.eq(true, client.is_running(), "pi keeps running while hidden")
		h.eq(false, layout.is_open())

		cleanup_guard(guard)
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

		local guard = start_with_guard_tab()
		require("pim").stop({ confirm = false })
		local baseline = census()

		for cycle = 1, 3 do
			require("pim").start()
			require("pim").stop({ confirm = false })
			h.eq(baseline, census(), "state accumulated after cycle " .. cycle)
		end

		h.eq(1, baseline.shutdown, "one VimLeavePre autocmd, not one per connect")
		h.eq(2, baseline.pi_buffers, "exactly the transcript and input buffers")

		cleanup_guard(guard)
	end,

	["restart passes --session when the session file is known"] = function()
		local session_file = vim.fn.tempname() .. ".jsonl"
		local file = assert(io.open(session_file, "w"))
		file:write('{"type":"session","version":3,"id":"x"}\n')
		file:close()

		start_and_connect()

		require("pim.state").update({ session_file = session_file })
		require("pim").restart()

		local argv = fake_argv()
		h.ok(vim.list_contains(argv, "--session"), "--session flag passed")
		h.ok(vim.list_contains(argv, session_file), "session path passed")

		os.remove(session_file)
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
