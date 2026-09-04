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
	for _, line in ipairs(vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false)) do
		if line == "---" then
			count = count + 1
		end
	end
	return count
end

local function transcript_text()
	transcript.flush()
	return table.concat(vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false), "\n")
end

return {
	["text deltas build a live message and message_end replaces it"] = function()
		layout.open()
		events.reset()
		transcript.reset()

		events.handle({ type = "message_start", message = { role = "assistant", content = {} } })
		events.handle({
			type = "message_update",
			usage = { output = 1 },
			assistantMessageEvent = { type = "text_start", contentIndex = 0 },
		})
		events.handle({
			type = "message_update",
			usage = { output = 2 },
			assistantMessageEvent = { type = "text_delta", contentIndex = 0, delta = "Hello" },
		})
		events.handle({
			type = "message_update",
			usage = { output = 3 },
			assistantMessageEvent = { type = "text_delta", contentIndex = 0, delta = " world" },
		})
		h.ok(transcript_text():find("Hello world", 1, true), "the live deltas render")

		events.handle({
			type = "message_end",
			message = { role = "assistant", content = { { type = "text", text = "Authoritative text" } } },
		})
		local rendered = transcript_text()
		h.ok(rendered:find("Authoritative text", 1, true), "the final message replaces the accumulator")
		h.ok(not rendered:find("Hello world", 1, true), "the discarded partial text is gone")
	end,

	["thinking deltas build a thinking block"] = function()
		layout.open()
		local failure = handle_all({
			{ type = "message_start", message = { role = "assistant", content = {} } },
			{
				type = "message_update",
				assistantMessageEvent = { type = "thinking_start", contentIndex = 0 },
			},
			{
				type = "message_update",
				assistantMessageEvent = { type = "thinking_delta", contentIndex = 0, delta = "check " },
			},
			{
				type = "message_update",
				assistantMessageEvent = { type = "thinking_end", contentIndex = 0, content = "check types" },
			},
		})

		h.eq(nil, failure)
		h.ok(transcript_text():find("> check types", 1, true), "the completed thinking content renders")
	end,

	["tool-call deltas use start identity and the completed call"] = function()
		layout.open()
		local failure = handle_all({
			{ type = "message_start", message = { role = "assistant", content = {} } },
			{
				type = "message_update",
				assistantMessageEvent = {
					type = "toolcall_start",
					contentIndex = 0,
					id = "call-1",
					toolName = "read",
				},
			},
			{
				type = "message_update",
				assistantMessageEvent = { type = "toolcall_delta", contentIndex = 0, delta = '{"path":' },
			},
			{
				type = "message_update",
				assistantMessageEvent = { type = "toolcall_delta", contentIndex = 0, delta = '"draft.lua"}' },
			},
			{
				type = "message_update",
				assistantMessageEvent = {
					type = "toolcall_end",
					contentIndex = 0,
					toolCall = {
						type = "toolCall",
						id = "call-1",
						name = "read",
						arguments = { path = "final.lua" },
					},
				},
			},
		})

		h.eq(nil, failure)
		local rendered = transcript_text()
		h.ok(rendered:find("tool(read): final.lua", 1, true), "toolcall_end is authoritative")
		h.ok(rendered:find('"path": "final.lua"', 1, true), "the completed arguments render")
	end,

	["multiple streamed blocks keep contentIndex order"] = function()
		layout.open()
		local failure = handle_all({
			{ type = "message_start", message = { role = "assistant", content = {} } },
			{
				type = "message_update",
				assistantMessageEvent = { type = "text_delta", contentIndex = 0, delta = "Before" },
			},
			{
				type = "message_update",
				assistantMessageEvent = { type = "thinking_delta", contentIndex = 1, delta = "Consider" },
			},
			{
				type = "message_update",
				assistantMessageEvent = { type = "text_delta", contentIndex = 2, delta = "After" },
			},
		})

		h.eq(nil, failure)
		local rendered = transcript_text()
		local before = assert(rendered:find("Before", 1, true))
		local thinking = assert(rendered:find("> Consider", 1, true))
		local after = assert(rendered:find("After", 1, true))
		h.ok(before < thinking and thinking < after, "blocks render in contentIndex order")
	end,

	["malformed deltas are ignored and later deltas still render"] = function()
		layout.open()
		local failure = handle_all({
			{ type = "message_start", message = { role = "assistant", content = {} } },
			{ type = "message_update" },
			{ type = "message_update", assistantMessageEvent = "bad" },
			{ type = "message_update", assistantMessageEvent = { type = "text_delta", contentIndex = -1 } },
			{ type = "message_update", assistantMessageEvent = { type = "text_delta", contentIndex = 9 } },
			{
				type = "message_update",
				assistantMessageEvent = { type = "text_delta", contentIndex = 0, delta = "survived" },
			},
		})

		h.eq(nil, failure)
		h.ok(transcript_text():find("survived", 1, true), "a valid later delta renders")
	end,
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
			{
				type = "tool_execution_start",
				toolCallId = "call-1",
				toolName = "bash",
				args = { command = "mise test" },
			},
			{
				type = "tool_execution_end",
				toolCallId = "call-1",
				toolName = "bash",
				result = { content = { { type = "text", text = "the output" } } },
			},
		})
		transcript.flush()

		h.eq(nil, failure)
		local rendered = table.concat(vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false), "\n")
		h.ok(rendered:find("result(bash): mise test", 1, true), "the cached arguments rendered, got: " .. rendered)
		h.ok(rendered:find("the output", 1, true), "its result rendered")
	end,

	["tool events share context and only the end event is final"] = function()
		local original_set = transcript.set
		local calls = {}
		---@diagnostic disable-next-line: duplicate-set-field
		transcript.set = function(key, kind, rendered, opts)
			calls[#calls + 1] = { key = key, kind = kind, rendered = rendered, opts = opts }
		end

		local success, err = xpcall(function()
			events.handle({ type = "tool_execution_start", toolCallId = "call-1", toolName = "bash" })
			events.handle({
				type = "tool_execution_update",
				toolCallId = "call-1",
				toolName = "bash",
				args = { command = "mise test" },
				partialResult = "partial output",
			})
			events.handle({
				type = "tool_execution_end",
				toolCallId = "call-1",
				toolName = "bash",
				---@diagnostic disable-next-line: assign-type-mismatch
				args = "malformed",
				result = "final output",
			})
		end, debug.traceback)
		transcript.set = original_set
		if not success then
			error(err, 0)
		end

		h.eq(3, #calls)
		h.eq(nil, calls[1].opts)
		h.eq(nil, calls[2].opts)
		h.eq({ final = true }, calls[3].opts)
		h.ok(calls[2].rendered.lines[1]:find("mise test", 1, true), "the update adds argument context")
		h.ok(calls[3].rendered.lines[1]:find("mise test", 1, true), "the end reuses valid arguments")
		h.ok(table.concat(calls[3].rendered.lines, "\n"):find("final output", 1, true), "the final result renders")
	end,

	["loaded tool results recover context from earlier calls"] = function()
		layout.open()
		events.load_messages({
			{
				role = "assistant",
				content = {
					{
						type = "toolCall",
						id = "write-1",
						name = "write",
						arguments = { path = "notes.txt", content = "saved content" },
					},
				},
			},
			{
				role = "toolResult",
				toolCallId = "write-1",
				toolName = "write",
				content = { { type = "text", text = "written" } },
			},
		})
		transcript.flush()

		local rendered = table.concat(vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false), "\n")
		h.ok(rendered:find("tool(write): notes.txt", 1, true), "the loaded call has context")
		h.ok(rendered:find("result(write): notes.txt", 1, true), "the loaded result has context")
		h.ok(rendered:find("saved content", 1, true), "the loaded write content is inspectable")
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

		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "go" })
		require("pim.ui.input").submit()

		local function rendered()
			return table.concat(vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false), "\n")
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
		---@diagnostic disable-next-line: duplicate-set-field
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

	["message events with missing or malformed messages do not raise"] = function()
		h.eq(
			nil,
			handle_all({
				{ type = "message_start" },
				{ type = "message_update" },
				{ type = "message_end" },
				{ type = "message_start", message = 42 },
				{ type = "message_end", message = "bad" },
				{ type = "message_start", message = { role = "assistant", content = "bad" } },
				{ type = "message_end", message = { role = "assistant", content = "bad" } },
			})
		)
	end,
}
