local protocol = require("pim.subagents.protocol")

local M = {}

local STATUS_ORDER = { "completed", "running", "pending", "failed", "stopped", "aborted" }

---@param arguments any
---@return PimRenderedBlock|nil
function M.call(arguments)
	if not protocol.is_parameters(arguments) then
		return nil
	end
	local count = #arguments.agents
	return {
		lines = { ("▸ tool(subagent): %d %s"):format(count, count == 1 and "agent" or "agents") },
		folds = {},
	}
end

---@param result any
---@param is_error boolean|nil
---@return PimRenderedBlock|nil
function M.result(result, is_error)
	local details = type(result) == "table" and result.details or nil
	if not protocol.is_details(details) then
		return nil
	end
	---@cast details PimSubagentDetails
	local counts = {}
	for _, agent in ipairs(details.agents) do
		counts[agent.status] = (counts[agent.status] or 0) + 1
	end
	local summary = {}
	for _, status in ipairs(STATUS_ORDER) do
		if counts[status] then
			summary[#summary + 1] = ("%d %s"):format(counts[status], status)
		end
	end
	local suffix = is_error and " ✘ error" or ""
	return { lines = { "▸ result(subagent): " .. table.concat(summary, ", ") .. suffix }, folds = {} }
end

return M
