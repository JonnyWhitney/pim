local M = {}

-- Use a sentinel because a nil field means that an update does not change the field.
---@class PimStateNone
M.NONE = setmetatable({}, {
	__tostring = function()
		return "state.NONE"
	end,
})

---@return PimApplicationState
local function initial()
	return {
		connected = false,
		run_active = false,
		is_streaming = false,
		is_compacting = false,
		bash_running = false,
		model = nil,
		thinking_level = nil,
		session_id = nil,
		session_name = nil,
		session_file = nil,
		context_tokens = nil,
		context_window = nil,
		context_percent = nil,
		retrying = false,
		ext_status = {},
		ext_widgets = {},
		exit_code = nil,
		stopped = false,
		spawn_error = nil,
		config_dir = require("pim.config").pi_config_dir(),
	}
end

---@type PimApplicationState
local state = initial()
---@type fun(state: PimApplicationState)[]
local observers = {}

local function notify()
	for _, observer in ipairs(observers) do
		observer(state)
	end
end

---@return PimApplicationState
function M.get()
	return state
end

---@param value PimBusyState|nil
---@return boolean
function M.is_busy(value)
	value = value or state
	return value.run_active
		or value.is_streaming
		or value.is_compacting
		or value.bash_running
		or value.retrying
		or false
end

---@param observer fun(state: PimApplicationState)
function M.subscribe(observer)
	observers[#observers + 1] = observer
end

function M.update(partial)
	for key, value in pairs(partial) do
		if value == M.NONE then
			state[key] = nil
		else
			state[key] = value
		end
	end
	notify()
end

function M.reset()
	state = initial()
	notify()
end

function M.reset_observers()
	observers = {}
end

---@param rpc PimRpcState
function M.apply_rpc_state(rpc)
	M.update({
		connected = true,
		run_active = rpc.isStreaming or false,
		is_streaming = rpc.isStreaming or false,
		is_compacting = rpc.isCompacting or false,
		model = rpc.model or M.NONE,
		thinking_level = rpc.thinkingLevel or M.NONE,
		session_id = rpc.sessionId or M.NONE,
		session_name = rpc.sessionName or M.NONE,
		session_file = rpc.sessionFile or M.NONE,
	})
end

function M.set_ext_status(key, text)
	state.ext_status[key] = text
	notify()
end

function M.set_ext_widget(key, lines)
	state.ext_widgets[key] = lines
	notify()
end

---@param event PimEvent
function M.handle_event(event)
	local kind = event.type
	if kind == "agent_start" then
		M.update({ run_active = true, is_streaming = true })
	elseif kind == "agent_end" then
		M.update({ is_streaming = false, retrying = event.willRetry or false })
	elseif kind == "agent_settled" then
		M.update({ run_active = false, is_streaming = false, is_compacting = false, retrying = false })
	elseif kind == "compaction_start" then
		M.update({ is_compacting = true })
	elseif kind == "compaction_end" then
		M.update({ is_compacting = false })
	elseif kind == "session_info_changed" then
		M.update({ session_name = event.name })
	elseif kind == "thinking_level_changed" then
		M.update({ thinking_level = event.level })
	elseif kind == "auto_retry_start" then
		M.update({ retrying = true })
	elseif kind == "auto_retry_end" then
		M.update({ retrying = false })
	elseif kind == "summarization_retry_scheduled" or kind == "summarization_retry_attempt_start" then
		M.update({ retrying = true })
	elseif kind == "summarization_retry_finished" then
		M.update({ retrying = false })
	end
end

function M.poll_stats()
	local client = require("pim.rpc.client")
	if not client.is_running() then
		return
	end
	client.request("get_session_stats", nil, function(success, stats)
		if not success or type(stats) ~= "table" then
			return
		end
		---@cast stats PimRpcSessionStats
		local usage = stats.contextUsage
		local has_context = type(usage) == "table"
			and type(usage.tokens) == "number"
			and type(usage.contextWindow) == "number"
			and type(usage.percent) == "number"
		---@cast usage PimRpcContextUsage
		M.update({
			context_tokens = has_context and usage.tokens or M.NONE,
			context_window = has_context and usage.contextWindow or M.NONE,
			context_percent = has_context and usage.percent or M.NONE,
			session_file = stats.sessionFile or state.session_file,
		})
	end)
end

return M
