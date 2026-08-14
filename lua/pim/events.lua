local log = require("pim.log")
local render = require("pim.ui.render")
local tool_preview = require("pim.tool_preview")
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
local tool_arguments = {}
local tool_previews = {}

local function render_opts()
	return {
		thinking = require("pim.config").get().transcript.show_thinking,
		tool_arguments = tool_arguments,
	}
end

local function remember_tool_calls(message)
	if not message or message.role ~= "assistant" then
		return
	end
	for _, block in ipairs(message.content or {}) do
		if block.type == "toolCall" and type(block.id) == "string" and type(block.arguments) == "table" then
			tool_arguments[block.id] = block.arguments
		end
	end
end

local function event_arguments(event)
	if type(event.args) == "table" then
		tool_arguments[event.toolCallId] = event.args
	end
	return event.args or tool_arguments[event.toolCallId]
end

local function event_preview(event, arguments)
	if tool_previews[event.toolCallId] == nil then
		tool_previews[event.toolCallId] = tool_preview.generate(event.toolName, arguments)
	end
	return tool_previews[event.toolCallId]
end

local function next_key()
	message_counter = message_counter + 1
	return ("msg-%d"):format(message_counter)
end

function M.reset()
	message_counter = 0
	current_key = nil
	tool_arguments = {}
	tool_previews = {}
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
		remember_tool_calls(event.message)
		current_key = next_key()
		transcript.set(current_key, "message", render.message(event.message, render_opts()))
	elseif kind == "message_update" then
		remember_tool_calls(event.message)
		if current_key then
			transcript.set(current_key, "message", render.message(event.message, render_opts()))
		end
	elseif kind == "message_end" then
		remember_tool_calls(event.message)
		if current_key then
			transcript.set(current_key, "message", render.message(event.message, render_opts()), { final = true })
			current_key = nil
		end
		if event.message and event.message.role == "assistant" then
			state.poll_stats()
		end
	elseif kind == "tool_execution_start" then
		local arguments = event_arguments(event)
		transcript.set(
			"tool-" .. event.toolCallId,
			"tool",
			render.tool_execution({
				toolName = event.toolName,
				args = arguments,
				preview = event_preview(event, arguments),
				running = true,
			})
		)
	elseif kind == "tool_execution_update" then
		local arguments = event_arguments(event)
		transcript.set(
			"tool-" .. event.toolCallId,
			"tool",
			render.tool_execution({
				toolName = event.toolName,
				args = arguments,
				preview = event_preview(event, arguments),
				running = true,
				result = event.partialResult,
			})
		)
	elseif kind == "tool_execution_end" then
		local arguments = event_arguments(event)
		transcript.set(
			"tool-" .. event.toolCallId,
			"tool",
			render.tool_execution({
				toolName = event.toolName,
				args = arguments,
				preview = event_preview(event, arguments),
				isError = event.isError,
				result = event.result,
			}),
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
		remember_tool_calls(message)
		transcript.set(next_key(), "message", render.message(message, render_opts()), { final = true })
	end
end

return M
