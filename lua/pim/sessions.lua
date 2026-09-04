local M = {}

local function can_change()
	if require("pim.ui.tree").is_open() then
		vim.notify("[pim] Close the tree before changing the session", vim.log.levels.WARN)
		return false
	end
	if require("pim.state").is_busy() then
		vim.notify("[pim] Cannot change the session while pi is busy", vim.log.levels.WARN)
		return false
	end
	return true
end

local function valid_response(action, success, data)
	if not success then
		vim.notify(("[pim] %s failed: %s"):format(action, tostring(data)), vim.log.levels.ERROR)
		return false
	end
	if type(data) ~= "table" or type(data.cancelled) ~= "boolean" then
		vim.notify(("[pim] %s returned invalid data"):format(action), vim.log.levels.WARN)
		return false
	end
	if data.cancelled then
		vim.notify(("[pim] %s cancelled by an extension"):format(action), vim.log.levels.WARN)
		return false
	end
	return true
end

function M.list()
	return require("pim.session_files").list()
end

function M.refresh()
	local client = require("pim.rpc.client")
	local state = require("pim.state")

	client.get_state(function(success, data)
		if not success then
			vim.notify("[pim] get_state failed: " .. tostring(data), vim.log.levels.ERROR)
		elseif type(data) ~= "table" then
			vim.notify("[pim] pi did not return state data", vim.log.levels.WARN)
		else
			state.apply_rpc_state(data)
			state.poll_stats()
		end
	end)
	client.get_messages(function(success, data)
		if not success then
			vim.notify("[pim] failed to load history: " .. tostring(data), vim.log.levels.ERROR)
		elseif type(data) ~= "table" or type(data.messages) ~= "table" then
			vim.notify("[pim] pi did not return history data", vim.log.levels.WARN)
		else
			require("pim.events").load_messages(data.messages)
		end
	end)
	require("pim.completion").refresh_commands()
end

function M.new()
	if not can_change() then
		return
	end
	require("pim.rpc.client").new_session(function(success, data)
		if valid_response("new_session", success, data) then
			M.refresh()
		end
	end)
end

---@param path string
function M.switch(path)
	if not can_change() then
		return
	end
	require("pim.rpc.client").switch_session(path, function(success, data)
		if valid_response("switch_session", success, data) then
			M.refresh()
		end
	end)
end

---@param entry_id string
function M.fork(entry_id)
	if not can_change() then
		return
	end
	require("pim.rpc.client").fork(entry_id, function(success, data)
		if not valid_response("fork", success, data) then
			return
		end
		if type(data.text) ~= "string" then
			vim.notify("[pim] fork returned invalid data", vim.log.levels.WARN)
			return
		end
		require("pim.ui.input").replace(data.text)
		M.refresh()
	end)
end

function M.clone()
	if not can_change() then
		return
	end
	require("pim.rpc.client").clone(function(success, data)
		if not valid_response("clone", success, data) then
			return
		end
		require("pim.ui.input").replace("")
		M.refresh()
	end)
end

return M
