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
---@type PimMessage|nil
local current_message = nil
local tool_argument_json = {}
local tool_arguments = {}
local tool_previews = {}

local function render_opts()
	return {
		thinking = require("pim.config").get().transcript.show_thinking,
		tool_arguments = tool_arguments,
	}
end

---@param message PimMessage|nil
local function remember_tool_calls(message)
	if type(message) ~= "table" then
		return
	end
	local blocks = message.content
	if message.role ~= "assistant" or type(blocks) ~= "table" then
		return
	end
	for _, block in ipairs(blocks) do
		if
			type(block) == "table"
			and block.type == "toolCall"
			and type(block.id) == "string"
			and type(block.arguments) == "table"
		then
			tool_arguments[block.id] = block.arguments
		end
	end
end

---@param event PimEvent
local function event_arguments(event)
	if type(event.args) == "table" then
		tool_arguments[event.toolCallId] = event.args
	end
	return event.args or tool_arguments[event.toolCallId]
end

---@param event PimEvent
---@param arguments table|nil
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

---@param key string
---@param message PimMessage
---@param opts { final: boolean|nil }|nil
local function set_message(key, message, opts)
	local ok, rendered = pcall(render.message, message, render_opts())
	if not ok then
		log.add("!", "Cannot render message event: " .. tostring(rendered))
		return
	end
	transcript.set(key, "message", rendered, opts)
end

---@return PimContentBlock|nil, integer|nil
local function content_block(update, block_type, field)
	if type(current_message) ~= "table" or current_message.role ~= "assistant" then
		return nil
	end
	if type(current_message.content) ~= "table" then
		current_message.content = {}
	end
	if type(update.contentIndex) ~= "number" or update.contentIndex < 0 or update.contentIndex % 1 ~= 0 then
		return nil
	end

	local index = update.contentIndex + 1
	if index > #current_message.content + 1 then
		return nil
	end
	local block = current_message.content[index]
	if type(block) ~= "table" or block.type ~= block_type then
		block = { type = block_type, [field] = "" }
		current_message.content[index] = block
	end
	return block, index
end

local function apply_text_delta(update, block_type, field)
	local block = content_block(update, block_type, field)
	if not block then
		return
	end
	if update.type == block_type .. "_start" then
		block[field] = ""
	elseif update.type == block_type .. "_delta" and type(update.delta) == "string" then
		block[field] = (type(block[field]) == "string" and block[field] or "") .. update.delta
	elseif update.type == block_type .. "_end" and type(update.content) == "string" then
		block[field] = update.content
	end
end

local function apply_toolcall_delta(update)
	local block, index = content_block(update, "toolCall", "arguments")
	local message = current_message
	if not block or not index or type(message) ~= "table" or type(message.content) ~= "table" then
		return
	end
	if update.type == "toolcall_start" then
		block.id = type(update.id) == "string" and update.id or nil
		block.name = type(update.toolName) == "string" and update.toolName or nil
		block.arguments = {}
		tool_argument_json[index] = ""
	elseif update.type == "toolcall_delta" and type(update.delta) == "string" then
		local json = (tool_argument_json[index] or "") .. update.delta
		tool_argument_json[index] = json
		local ok, arguments = pcall(vim.json.decode, json)
		if ok and type(arguments) == "table" then
			block.arguments = arguments
		end
	elseif update.type == "toolcall_end" and type(update.toolCall) == "table" then
		message.content[index] = vim.deepcopy(update.toolCall)
		tool_argument_json[index] = nil
	end
end

local function apply_message_update(event)
	local update = event.assistantMessageEvent
	if type(update) ~= "table" or type(update.type) ~= "string" then
		return false
	end

	if update.type == "text_start" or update.type == "text_delta" or update.type == "text_end" then
		apply_text_delta(update, "text", "text")
	elseif update.type == "thinking_start" or update.type == "thinking_delta" or update.type == "thinking_end" then
		apply_text_delta(update, "thinking", "thinking")
	elseif update.type == "toolcall_start" or update.type == "toolcall_delta" or update.type == "toolcall_end" then
		apply_toolcall_delta(update)
	else
		return false
	end

	if type(current_message) == "table" and type(event.usage) == "table" then
		current_message.usage = vim.deepcopy(event.usage)
	end
	return current_message ~= nil
end

function M.reset()
	message_counter = 0
	current_key = nil
	current_message = nil
	tool_argument_json = {}
	tool_arguments = {}
	tool_previews = {}
end

---@param event PimEvent
function M.handle(event)
	state.handle_event(event)

	local kind = event.type
	-- Tool updates share one transcript block by toolCallId. Ignore updates that cannot identify it.
	if TOOL_EVENTS[kind] and type(event.toolCallId) ~= "string" then
		log.add("!", ("%s without a toolCallId; skipped"):format(kind))
		return
	end

	if kind == "message_start" then
		current_message = type(event.message) == "table" and vim.deepcopy(event.message) or nil
		tool_argument_json = {}
		if type(event.message) == "table" and event.message.role == "toolResult" then
			current_key = nil
			return
		end
		remember_tool_calls(current_message)
		if current_message then
			current_key = next_key()
			set_message(current_key, current_message)
		else
			current_key = nil
		end
	elseif kind == "message_update" then
		if current_key and apply_message_update(event) then
			local message = current_message
			if message then
				remember_tool_calls(message)
				set_message(current_key, message)
			end
		end
	elseif kind == "message_end" then
		remember_tool_calls(event.message)
		if current_key and type(event.message) == "table" then
			set_message(current_key, event.message, { final = true })
		end
		current_key = nil
		current_message = nil
		tool_argument_json = {}
		if type(event.message) == "table" and event.message.role == "assistant" then
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

---@param messages PimMessage[]|nil
function M.load_messages(messages)
	M.reset()
	transcript.reset()
	for _, message in ipairs(messages or {}) do
		remember_tool_calls(message)
		transcript.set(next_key(), "message", render.message(message, render_opts()), { final = true })
	end
end

return M
