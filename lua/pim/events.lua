local log = require("pim.log")
local render = require("pim.ui.render")
local state = require("pim.state")
local transcript = require("pim.ui.transcript")

local M = {}

local TOOL_EVENTS = {
	tool_execution_start = true,
	tool_execution_update = true,
	tool_execution_end = true,
}

local message_counter = 0
local current_key = nil

local function render_opts()
	return { thinking = require("pim.config").get().transcript.show_thinking }
end

local function next_key()
	message_counter = message_counter + 1
	return ("msg-%d"):format(message_counter)
end

function M.reset()
	message_counter = 0
	current_key = nil
end

---@param event table
function M.handle(event)
	state.handle_event(event)

	local kind = event.type
	-- Tool updates share one transcript block by toolCallId. Ignore updates that cannot identify it.
	if TOOL_EVENTS[kind] and type(event.toolCallId) ~= "string" then
		log.add("!", ("%s without a toolCallId; skipped"):format(kind))
		return
	end

	if kind == "message_start" then
		if event.message and event.message.role == "toolResult" then
			current_key = nil
			return
		end
		current_key = next_key()
		transcript.set(current_key, "message", render.message(event.message, render_opts()))
	elseif kind == "message_update" then
		if current_key then
			transcript.set(current_key, "message", render.message(event.message, render_opts()))
		end
	elseif kind == "message_end" then
		if current_key then
			transcript.set(current_key, "message", render.message(event.message, render_opts()), { final = true })
			current_key = nil
		end
	elseif kind == "tool_execution_start" then
		transcript.set(
			"tool-" .. event.toolCallId,
			"tool",
			render.tool_execution({ toolName = event.toolName, running = true })
		)
	elseif kind == "tool_execution_update" then
		transcript.set(
			"tool-" .. event.toolCallId,
			"tool",
			render.tool_execution({ toolName = event.toolName, running = true, result = event.partialResult })
		)
	elseif kind == "tool_execution_end" then
		transcript.set(
			"tool-" .. event.toolCallId,
			"tool",
			render.tool_execution({ toolName = event.toolName, isError = event.isError, result = event.result }),
			{ final = true }
		)
	elseif kind == "queue_update" then
		transcript.set_queue(event.steering, event.followUp)
	elseif kind == "agent_settled" then
		transcript.divider()
		state.poll_stats()
	elseif kind == "compaction_end" then
		state.poll_stats()
	end
end

---@param messages table[]|nil
function M.load_messages(messages)
	M.reset()
	transcript.reset()
	for _, message in ipairs(messages or {}) do
		transcript.set(next_key(), "message", render.message(message, render_opts()), { final = true })
	end
end

return M
