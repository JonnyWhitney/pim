local state_store = require("pim.state")

local M = {}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_INTERVAL_MS = 120

local spinner_index = 1
local timer = nil
local attached = false

-- A winbar uses % for statusline items. Escape it in data from pi and extensions.
local function esc(text)
	return (text:gsub("%%", "%%%%"))
end

---@param tokens number
---@return string
local function format_tokens(tokens)
	local divisor = 1
	local suffix = ""
	if tokens >= 1000000 then
		divisor = 1000000
		suffix = "m"
	elseif tokens >= 1000 then
		divisor = 1000
		suffix = "k"
	end

	local scaled = tokens / divisor
	if scaled == math.floor(scaled) then
		return ("%d%s"):format(scaled, suffix)
	end
	return ("%.1f%s"):format(scaled, suffix)
end

---@param state PimApplicationState
---@return string
function M.build(state)
	local model = state.model or {}
	local provider = model.provider or "-"
	local model_name = model.name or model.id or "-"
	local thinking = state.thinking_level or "-"
	local config_dir = state.config_dir or "-"
	local parts = {
		"pi",
		"Provider: " .. provider,
		"Model: " .. model_name,
		"Thinking: " .. thinking,
		"Config: " .. config_dir,
	}

	if state.spawn_error then
		parts[#parts + 1] = "failed to start"
	elseif state.exit_code then
		parts[#parts + 1] = ("exited(%d)"):format(state.exit_code)
	elseif state.stopped then
		parts[#parts + 1] = "stopped"
	elseif not state.connected then
		parts[#parts + 1] = "connecting…"
	end

	if state.context_tokens and state.context_window and state.context_percent then
		parts[#parts + 1] = ("ctx:%s/%s (%d%%)"):format(
			format_tokens(state.context_tokens),
			format_tokens(state.context_window),
			state.context_percent
		)
	end

	if state.is_compacting then
		parts[#parts + 1] = SPINNER[spinner_index] .. " compacting"
	elseif state.retrying then
		parts[#parts + 1] = SPINNER[spinner_index] .. " retrying"
	elseif state.bash_running then
		parts[#parts + 1] = SPINNER[spinner_index] .. " !"
	elseif state_store.is_busy(state) then
		parts[#parts + 1] = SPINNER[spinner_index]
	end

	if state.session_name then
		parts[#parts + 1] = state.session_name
	end

	for _, text in pairs(state.ext_status) do
		if text and text ~= "" then
			parts[#parts + 1] = text
		end
	end
	for _, lines in pairs(state.ext_widgets or {}) do
		if lines[1] and lines[1] ~= "" then
			parts[#parts + 1] = lines[1]
		end
	end

	return " " .. esc(table.concat(parts, " │ "))
end

local function refresh()
	local layout = require("pim.ui.layout")
	local win = layout.transcript_win()
	if not win then
		return
	end
	local state = state_store.get()
	vim.api.nvim_set_option_value("winbar", M.build(state), { win = win })
end

local function stop_spinner()
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end
end

local function start_spinner()
	if timer then
		return
	end
	timer = vim.uv.new_timer()
	if not timer then
		return
	end
	timer:start(SPINNER_INTERVAL_MS, SPINNER_INTERVAL_MS, function()
		spinner_index = spinner_index % #SPINNER + 1
		vim.schedule(refresh)
	end)
end

---@param state PimApplicationState
local function on_state_changed(state)
	if state_store.is_busy(state) then
		start_spinner()
	else
		stop_spinner()
	end
	refresh()
end

function M.shutdown()
	stop_spinner()
end

function M.reset()
	stop_spinner()
	spinner_index = 1
	attached = false
end

function M.attach()
	if not attached then
		attached = true
		state_store.subscribe(on_state_changed)
	end
	on_state_changed(state_store.get())
end

return M
