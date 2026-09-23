local M = {}

local STATUSES = {
	pending = true,
	running = true,
	completed = true,
	failed = true,
	stopped = true,
	aborted = true,
}

local function valid_agent(agent)
	return type(agent) == "table"
		and type(agent.id) == "string"
		and agent.id:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
		and type(agent.label) == "string"
		and STATUSES[agent.status] == true
		and type(agent.transcriptPath) == "string"
		and (agent.summary == nil or type(agent.summary) == "string")
		and (agent.usage == nil or type(agent.usage) == "table")
		and (agent.stoppedBy == nil or agent.stoppedBy == "user" or agent.stoppedBy == "parent_abort")
end

---@param value any
---@return boolean
function M.is_details(value)
	if
		type(value) ~= "table"
		or value.schemaVersion ~= 1
		or type(value.invocationId) ~= "string"
		or value.invocationId:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") == nil
		or (value.mode ~= "single" and value.mode ~= "parallel")
		or not STATUSES[value.status]
		or type(value.transcriptDir) ~= "string"
		or type(value.agents) ~= "table"
		or #value.agents < 1
		or #value.agents > 8
	then
		return false
	end
	for _, agent in ipairs(value.agents) do
		if not valid_agent(agent) then
			return false
		end
	end
	return true
end

---@param arguments any
---@return boolean
function M.is_parameters(arguments)
	if type(arguments) ~= "table" or type(arguments.agents) ~= "table" then
		return false
	end
	if #arguments.agents < 1 or #arguments.agents > 8 then
		return false
	end
	for _, agent in ipairs(arguments.agents) do
		if type(agent) ~= "table" or type(agent.label) ~= "string" or type(agent.prompt) ~= "string" then
			return false
		end
	end
	return true
end

return M
