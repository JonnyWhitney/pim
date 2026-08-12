local h = require("helpers")
local config = require("pim.config")
local events = require("pim.events")
local layout = require("pim.ui.layout")
local log = require("pim.log")
local transcript = require("pim.ui.transcript")

local function handle_all(list)
	events.reset()
	transcript.reset()
	for index, event in ipairs(list) do
		local ok, err = pcall(events.handle, event)
		if not ok then
			return ("event %d (%s) raised: %s"):format(index, tostring(event.type), tostring(err))
		end
	end
	return nil
end

local function count_dividers()
	local count = 0
	for _, line in ipairs(vim.api.nvim_buf_get_lines(layout.transcript_buf(), 0, -1, false)) do
		if line == "---" then
			count = count + 1
		end
	end
	return count
end

return {
	["tool events without a toolCallId are dropped, not fatal"] = function()
		local failure = handle_all({
			{ type = "tool_execution_start", toolName = "bash" },
			{ type = "tool_execution_update", toolName = "bash", partialResult = "x" },
			{ type = "tool_execution_end", toolName = "bash", result = "x" },
		})

		h.eq(nil, failure)
		local logged = table.concat(log.lines(), "\n")
		h.ok(logged:find("without a toolCallId", 1, true), "the drop is recorded for :PiLog")
	end,

	["a valid tool event still renders after a malformed one"] = function()
		layout.open()

		local failure = handle_all({
			{ type = "tool_execution_start", toolName = "bash" },
			{ type = "tool_execution_start", toolCallId = "call-1", toolName = "bash" },
			{
				type = "tool_execution_end",
				toolCallId = "call-1",
				toolName = "bash",
				result = { content = { { type = "text", text = "the output" } } },
			},
		})
		transcript.flush()

		h.eq(nil, failure)
		local rendered = table.concat(vim.api.nvim_buf_get_lines(layout.transcript_buf(), 0, -1, false), "\n")
		h.ok(rendered:find("result: bash", 1, true), "the good block rendered, got: " .. rendered)
		h.ok(rendered:find("the output", 1, true), "its result rendered")
	end,

	["events with no type at all are ignored"] = function()
		h.eq(nil, handle_all({ {}, { type = "totally_unknown_event" }, { type = 42 } }))
	end,

	["a retried run draws one divider, not one per attempt"] = function()
		layout.open()

		local failure = handle_all({
			{ type = "agent_start" },
			{ type = "agent_end", willRetry = true },
			{ type = "auto_retry_start", attempt = 1 },
			{ type = "auto_retry_end", success = true },
			{ type = "agent_start" },
			{ type = "agent_end", willRetry = false },
		})
		transcript.flush()

		h.eq(nil, failure)
		h.eq(0, count_dividers(), "no boundary is drawn until the run has settled")

		events.handle({ type = "agent_settled" })
		transcript.flush()
		h.eq(1, count_dividers(), "exactly one boundary for the whole retried turn")
	end,

	["a hostile stream leaves the connection usable"] = function()
		local client = require("pim.rpc.client")
		local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

		config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua", "hostile" } })
		require("pim").start()
		transcript.reset()
		events.reset()

		vim.api.nvim_buf_set_lines(layout.input_buf(), 0, -1, false, { "go" })
		require("pim.ui.input").submit()

		local function rendered()
			return table.concat(vim.api.nvim_buf_get_lines(layout.transcript_buf(), 0, -1, false), "\n")
		end
		h.wait_until(function()
			return rendered():find("survived", 1, true) ~= nil
		end, "the valid message after the barrage to render:\n" .. rendered():sub(1, 500), 15000)

		h.eq(true, client.is_running(), "pi is still connected")
		local answer
		client.get_state(function(success, data)
			answer = { success = success, data = data }
		end)
		h.wait_until(function()
			return answer ~= nil
		end, "a get_state response after the barrage", 5000)

		h.eq(true, answer.success)
		h.eq("fake-session-id", answer.data.sessionId, "responses still correlate by id")
	end,

	["only completed assistant messages refresh context usage"] = function()
		local state = require("pim.state")
		local original_poll_stats = state.poll_stats
		local polls = 0
		state.poll_stats = function()
			polls = polls + 1
		end

		local success, err = xpcall(function()
			events.handle({ type = "message_end", message = { role = "user", content = "prompt" } })
			events.handle({ type = "message_end", message = { role = "toolResult", content = {} } })
			events.handle({ type = "message_end", message = { role = "assistant", content = {} } })
		end, debug.traceback)
		state.poll_stats = original_poll_stats
		if not success then
			error(err, 0)
		end

		h.eq(1, polls)
	end,

	["message events with no message do not raise"] = function()
		h.eq(
			nil,
			handle_all({
				{ type = "message_start" },
				{ type = "message_update" },
				{ type = "message_end" },
			})
		)
	end,
}
