local h = require("helpers")
local bash = require("pim.bash")
local client = require("pim.rpc.client")
local config = require("pim.config")
local layout = require("pim.ui.layout")
local message_renderer = require("pim.render.message")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function start_fake()
	config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" } })
	require("pim").start()
end

local function transcript_text()
	return table.concat(vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false), "\n")
end

local function submit(text)
	vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, vim.split(text, "\n", { plain = true }))
	require("pim.ui.input").submit()
end

return {
	["a single ! runs the command in context"] = function()
		local command, exclude = bash.parse("!ls -la")
		h.eq("ls -la", command)
		h.eq(false, exclude)
	end,

	["a double !! keeps the output out of context"] = function()
		local command, exclude = bash.parse("!!git status")
		h.eq("git status", command)
		h.eq(true, exclude)
	end,

	["ordinary prompts are left alone"] = function()
		h.eq(nil, (bash.parse("fix the bug in foo.ts")))
		h.eq(nil, (bash.parse("what does ! mean in bash?")), "a ! mid-sentence is not a command")
	end,

	["a bare ! is not a command"] = function()
		h.eq(nil, (bash.parse("!")))
		h.eq(nil, (bash.parse("!!")))
		h.eq(nil, (bash.parse("!   ")), "whitespace only is nothing to run")
	end,

	["the prefix survives multi-line commands"] = function()
		local command = bash.parse("!for f in *.lua; do\n  echo $f\ndone")
		h.eq("for f in *.lua; do\n  echo $f\ndone", command)
	end,

	["bash_passthrough = false sends ! prompts verbatim"] = function()
		config.setup({ bash_passthrough = false })
		h.eq(nil, (bash.parse("!ls")), "the ! is just text now")
	end,

	["a running command renders before its result arrives"] = function()
		local block = message_renderer.render({
			role = "bashExecution",
			command = "sleep 5",
			running = true,
		})
		h.eq({ "▸ ! sleep 5 [running]" }, block.lines)
	end,

	["excluded output is marked as such"] = function()
		local block = message_renderer.render({
			role = "bashExecution",
			command = "cat secrets",
			output = "hunter2",
			exitCode = 0,
			excludeFromContext = true,
		})
		h.eq("▸ ! cat secrets [not in context]", block.lines[1])
	end,

	["a failing excluded command shows both markers"] = function()
		local block = message_renderer.render({
			role = "bashExecution",
			command = "make",
			output = "",
			exitCode = 2,
			excludeFromContext = true,
		})
		h.eq("▸ ! make [exit 2] [not in context]", block.lines[1])
	end,

	["a rejected bash command renders as an error"] = function()
		local block = message_renderer.render({
			role = "bashExecution",
			command = "ls",
			failed = true,
			output = "pi is not running",
		})
		h.eq("▸ ! ls ✘ error", block.lines[1])
		h.ok(table.concat(block.lines, "\n"):find("pi is not running", 1, true), "the reason is shown")
	end,

	["end-to-end: !cmd renders its output in the transcript"] = function()
		start_fake()

		submit("!echo hello")
		h.wait_until(function()
			return transcript_text():find("ran: echo hello", 1, true) ~= nil
		end, "the command output in the transcript, got:\n" .. transcript_text(), 5000)

		local rendered = transcript_text()
		h.ok(rendered:find("▸ ! echo hello", 1, true), "header rendered, got:\n" .. rendered)
		h.ok(not rendered:find("[running]", 1, true), "the running marker was replaced")
		h.ok(not rendered:find("### You", 1, true), "a !cmd is not sent to the agent as a prompt")
	end,

	["end-to-end: a non-zero exit is reported"] = function()
		start_fake()

		submit("!make fail")
		h.wait_until(function()
			return transcript_text():find("[exit 3]", 1, true) ~= nil
		end, "the non-zero exit to be reported, got:\n" .. transcript_text(), 5000)
	end,

	["end-to-end: !! marks the block as out of context"] = function()
		start_fake()

		submit("!!cat secrets")
		h.wait_until(function()
			return transcript_text():find("[not in context]", 1, true) ~= nil
		end, "the out-of-context marker, got:\n" .. transcript_text(), 5000)
	end,

	["abort routes to abort_bash while a command is running"] = function()
		local state = require("pim.state")
		local sent = {}
		local real_request = client.request
		---@diagnostic disable-next-line: duplicate-set-field
		client.request = function(command_type, params, callback)
			sent[#sent + 1] = command_type
			return real_request(command_type, params, callback)
		end

		state.update({ bash_running = true, run_active = true, is_streaming = true })
		require("pim").abort()
		state.update({ bash_running = false })
		require("pim").abort()

		client.request = real_request
		state.update({ run_active = false, is_streaming = false })

		h.eq({ "abort_bash", "clear_queue", "abort" }, sent, "bash stays direct; agent abort clears its queue first")
	end,

	["abort does nothing when nothing is running"] = function()
		local state = require("pim.state")
		local sent = {}
		local real_request = client.request
		---@diagnostic disable-next-line: duplicate-set-field
		client.request = function(command_type)
			sent[#sent + 1] = command_type
		end

		state.update({ bash_running = false, run_active = false, is_streaming = false })
		require("pim").abort()

		client.request = real_request
		h.eq({}, sent, "<C-c> stays harmless at rest")
	end,

	["the winbar spins while a command runs"] = function()
		local statusline = require("pim.ui.statusline")
		local bar = statusline.build({ connected = true, bash_running = true, ext_status = {} })
		h.ok(bar:find("!", 1, true), "a bash marker is shown, got: " .. bar)
	end,
}
