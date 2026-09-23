local protocol = require("pim.subagents.protocol")

local M = {}

---@type table<string, PimSubagentInvocation>
local by_id = {}
---@type table<string, string>
local by_tool_call = {}
local revision = 0

local function changed()
	revision = revision + 1
end

---@param tool_call_id string
---@param details PimSubagentDetails
---@param arguments table|nil
---@param historical boolean|nil
---@return PimSubagentInvocation
function M.update(tool_call_id, details, arguments, historical)
	local invocation = by_id[details.invocationId]
	if not invocation then
		invocation = {
			invocation_id = details.invocationId,
			tool_call_id = tool_call_id,
			details = details,
			arguments = arguments,
			historical = historical == true,
		}
		by_id[details.invocationId] = invocation
	end
	invocation.tool_call_id = tool_call_id
	invocation.details = vim.deepcopy(details)
	invocation.arguments = arguments or invocation.arguments
	invocation.historical = historical == true and true or invocation.historical
	by_tool_call[tool_call_id] = details.invocationId
	changed()
	return invocation
end

---@param tool_call_id string
---@param result any
---@param arguments table|nil
---@param historical boolean|nil
---@return PimSubagentInvocation|nil
function M.observe(tool_call_id, result, arguments, historical)
	local details = type(result) == "table" and result.details or nil
	if not protocol.is_details(details) then
		return nil
	end
	---@cast details PimSubagentDetails
	return M.update(tool_call_id, details, arguments, historical)
end

---@param id string
---@return PimSubagentInvocation|nil
function M.get(id)
	return by_id[id]
end

---@param tool_call_id string
---@return PimSubagentInvocation|nil
function M.get_by_tool_call(tool_call_id)
	local id = by_tool_call[tool_call_id]
	return id and by_id[id] or nil
end

---@return PimSubagentInvocation[]
function M.list()
	local result = {}
	for _, invocation in pairs(by_id) do
		result[#result + 1] = invocation
	end
	table.sort(result, function(a, b)
		return a.invocation_id < b.invocation_id
	end)
	return result
end

function M.revision()
	return revision
end

function M.reset()
	by_id = {}
	by_tool_call = {}
	changed()
end

return M
