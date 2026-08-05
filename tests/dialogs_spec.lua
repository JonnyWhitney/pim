local h = require("helpers")
local client = require("pim.rpc.client")
local config = require("pim.config")
local dialogs = require("pim.ui.dialogs")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local original_select = vim.ui.select
local original_input = vim.ui.input
local original_respond = client.respond_ui

local function with_stubs(stubs, fn)
	local responses = {}
	vim.ui.select = stubs.select or original_select
	vim.ui.input = stubs.input or original_input
	---@diagnostic disable-next-line: duplicate-set-field
	client.respond_ui = function(id, payload)
		responses[#responses + 1] = { id = id, payload = payload }
	end
	local ok, err = pcall(fn, responses)
	vim.ui.select = original_select
	vim.ui.input = original_input
	client.respond_ui = original_respond
	dialogs.reset()
	h.settle(50)
	if not ok then
		error(err, 0)
	end
end

local function wait_for_responses(responses, count)
	h.wait_until(function()
		return #responses >= count
	end, ("%d dialog response(s), have %d"):format(count, #responses))
end

return {
	["select answer maps to a value response"] = function()
		with_stubs({
			select = function(items, _, on_choice)
				on_choice(items[2])
			end,
		}, function(responses)
			dialogs.handle({
				type = "extension_ui_request",
				id = "d1",
				method = "select",
				title = "t",
				options = { "a", "b" },
			})
			h.eq({ { id = "d1", payload = { value = "b" } } }, responses)
		end)
	end,

	["select cancel maps to cancelled"] = function()
		with_stubs({
			select = function(_, _, on_choice)
				on_choice(nil)
			end,
		}, function(responses)
			dialogs.handle({
				type = "extension_ui_request",
				id = "d2",
				method = "select",
				title = "t",
				options = { "a" },
			})
			h.eq({ cancelled = true }, responses[1].payload)
		end)
	end,

	["confirm yes/no maps to confirmed booleans"] = function()
		local pick
		with_stubs({
			select = function(items, _, on_choice)
				on_choice(pick == "yes" and items[1] or items[2])
			end,
		}, function(responses)
			pick = "yes"
			dialogs.handle({ id = "c1", method = "confirm", title = "Sure?", message = "really" })
			wait_for_responses(responses, 1)
			pick = "no"
			dialogs.handle({ id = "c2", method = "confirm", title = "Sure?", message = "really" })
			wait_for_responses(responses, 2)
			h.eq({ confirmed = true }, responses[1].payload)
			h.eq({ confirmed = false }, responses[2].payload)
		end)
	end,

	["input text and cancel map correctly"] = function()
		local reply
		with_stubs({
			input = function(_, on_confirm)
				on_confirm(reply)
			end,
		}, function(responses)
			reply = "typed answer"
			dialogs.handle({ id = "i1", method = "input", title = "Name" })
			wait_for_responses(responses, 1)
			reply = nil
			dialogs.handle({ id = "i2", method = "input", title = "Name" })
			wait_for_responses(responses, 2)
			h.eq({ value = "typed answer" }, responses[1].payload)
			h.eq({ cancelled = true }, responses[2].payload)
		end)
	end,

	["concurrent requests are served one at a time in order"] = function()
		local pending_choices = {}
		with_stubs({
			select = function(items, _, on_choice)
				pending_choices[#pending_choices + 1] = function()
					on_choice(items[1])
				end
			end,
		}, function(responses)
			dialogs.handle({ id = "q1", method = "select", title = "one", options = { "a" } })
			dialogs.handle({ id = "q2", method = "select", title = "two", options = { "b" } })
			h.eq(1, #pending_choices, "second dialog must wait for the first")

			pending_choices[1]()
			h.wait_until(function()
				return #pending_choices == 2
			end, "the second dialog to be shown once the first was answered")
			pending_choices[2]()
			wait_for_responses(responses, 2)

			h.eq("q1", responses[1].id)
			h.eq("q2", responses[2].id)
		end)
	end,

	["timeout abandons the dialog and advances the queue"] = function()
		local shown = {}
		with_stubs({
			select = function(_, opts, on_choice)
				shown[#shown + 1] = { prompt = opts.prompt, answer = on_choice }
			end,
		}, function(responses)
			dialogs.handle({ id = "t1", method = "select", title = "slow", options = { "a" }, timeout = 60 })
			dialogs.handle({ id = "t2", method = "select", title = "next", options = { "b" } })
			h.eq(1, #shown)

			h.wait_until(function()
				return #shown == 2
			end, "the queue to advance past the timed-out dialog")
			h.eq(0, #responses, "no response sent for the timed-out dialog")

			shown[1].answer("a")
			h.eq(0, #responses, "stale answer must not be sent")

			shown[2].answer("b")
			wait_for_responses(responses, 1)
			h.eq(1, #responses)
			h.eq("t2", responses[1].id)
		end)
	end,

	["editor dialog submits its buffer text"] = function()
		with_stubs({}, function(responses)
			dialogs.handle({ id = "e1", method = "editor", title = "Edit me", prefill = "line one\nline two" })
			local buf = vim.api.nvim_get_current_buf()
			h.eq({ "line one", "line two" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR><CR>", true, false, true), "x", false)
			wait_for_responses(responses, 1)

			h.eq({ value = "edited" }, responses[1].payload)
			h.ok(not vim.api.nvim_buf_is_valid(buf), "editor buffer cleaned up")
		end)
	end,

	["editor dialog cancels on q"] = function()
		with_stubs({}, function(responses)
			dialogs.handle({ id = "e2", method = "editor", title = "Edit me", prefill = "" })
			vim.api.nvim_feedkeys("q", "x", false)
			wait_for_responses(responses, 1)
			h.eq({ cancelled = true }, responses[1].payload)
		end)
	end,

	["editor dialog opens inside the pi tabpage"] = function()
		local layout = require("pim.ui.layout")
		layout.open()
		local pi_tab = vim.api.nvim_get_current_tabpage()

		vim.cmd("tabnew")
		local other_tab = vim.api.nvim_get_current_tabpage()

		with_stubs({}, function(responses)
			dialogs.handle({ id = "e3", method = "editor", title = "Edit me", prefill = "" })
			h.eq(pi_tab, vim.api.nvim_get_current_tabpage(), "the editor split lands in the pi tab")
			h.ok(vim.api.nvim_get_current_tabpage() ~= other_tab, "not in the user's own tab")
			vim.api.nvim_feedkeys("q", "x", false)
			wait_for_responses(responses, 1)
		end)

		if vim.api.nvim_tabpage_is_valid(other_tab) then
			vim.api.nvim_set_current_tabpage(other_tab)
			vim.cmd("tabclose")
		end
	end,

	["set_editor_text replaces the input buffer"] = function()
		require("pim.ui.layout").open()
		dialogs.handle({ method = "set_editor_text", text = "from extension" })
		local buf = require("pim.ui.layout").input_buf()
		h.eq({ "from extension" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	end,

	["setWidget surfaces its first line in the winbar"] = function()
		local state = require("pim.state")
		dialogs.handle({ method = "setWidget", widgetKey = "w1", widgetLines = { "widget says hi", "more" } })
		local bar = require("pim.ui.statusline").build(state.get())
		h.ok(bar:find("widget says hi", 1, true), "widget line present in winbar")
		dialogs.handle({ method = "setWidget", widgetKey = "w1", widgetLines = nil })
		bar = require("pim.ui.statusline").build(state.get())
		h.ok(not bar:find("widget says hi", 1, true), "widget cleared")
	end,

	["an unknown method is answered as cancelled and logged"] = function()
		local log = require("pim.log")
		with_stubs({}, function(responses)
			dialogs.handle({ id = "u1", method = "multiSelect", title = "Pick some" })
			h.eq({ { id = "u1", payload = { cancelled = true } } }, responses)
		end)
		h.ok(table.concat(log.lines(), "\n"):find("multiSelect", 1, true), "the unhandled method is named in the log")
	end,

	["end-to-end: select dialog round-trips through fake pi"] = function()
		config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua", "dialog" } })

		---@diagnostic disable-next-line: duplicate-set-field
		vim.ui.select = function(items, _, on_choice)
			on_choice(items[2])
		end

		require("pim").start()

		local layout = require("pim.ui.layout")
		vim.api.nvim_buf_set_lines(layout.input_buf(), 0, -1, false, { "ask me" })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR><CR>", true, false, true), "x", false)

		local ok, err = pcall(h.wait_until, function()
			local lines = vim.api.nvim_buf_get_lines(layout.transcript_buf(), 0, -1, false)
			return table.concat(lines, "\n"):find("You picked: beta", 1, true) ~= nil
		end, "the dialog answer to come back through fake pi", 10000)

		vim.ui.select = original_select
		h.ok(ok, tostring(err))
	end,
}
