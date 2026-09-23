local protocol = require("pim.subagents.protocol")

local M = {}

local function read_json(path)
	local ok, lines = pcall(vim.fn.readfile, path, "b")
	if not ok then
		return nil
	end
	local decoded, value = pcall(vim.json.decode, table.concat(lines, "\n"), {
		luanil = { object = true, array = true },
	})
	return decoded and value or nil
end

local function directories(path)
	local result = {}
	local iterator = vim.fs.dir(path)
	if not iterator then
		return result
	end
	for name, kind in iterator do
		local child = vim.fs.joinpath(path, name)
		local stat = vim.uv.fs_lstat(child)
		if kind == "directory" and stat and stat.type == "directory" then
			result[#result + 1] = child
		end
	end
	return result
end

---@param include_historical boolean
---@return PimSubagentInvocation[], integer
function M.list(include_historical)
	local state = require("pim.subagents.state")
	local found, invalid = {}, 0
	for _, invocation in ipairs(state.list()) do
		found[invocation.invocation_id] = invocation
	end
	local session_id = require("pim.state").get().session_id
	local root = require("pim.subagents").transcript_root()
	for _, parent in ipairs(directories(root)) do
		local parent_id = vim.fs.basename(parent)
		if include_historical or (session_id and parent_id == session_id) then
			for _, directory in ipairs(directories(parent)) do
				local manifest = read_json(vim.fs.joinpath(directory, "invocation.json"))
				if protocol.is_details(manifest) then
					---@cast manifest PimSubagentDetails
					if
						manifest.parentSessionId == parent_id
						and vim.fs.normalize(manifest.transcriptDir) == vim.fs.normalize(directory)
					then
						if not found[manifest.invocationId] then
							found[manifest.invocationId] = {
								invocation_id = manifest.invocationId,
								tool_call_id = type(manifest.toolCallId) == "string" and manifest.toolCallId or "",
								details = manifest,
								historical = true,
								parent_session_id = parent_id,
							}
						end
					else
						invalid = invalid + 1
					end
				else
					invalid = invalid + 1
				end
			end
		end
	end
	local result = vim.tbl_values(found)
	table.sort(result, function(a, b)
		local ad = a.details.updatedAt or a.details.createdAt or ""
		local bd = b.details.updatedAt or b.details.createdAt or ""
		if ad == bd then
			return a.invocation_id < b.invocation_id
		end
		return ad > bd
	end)
	return result, invalid
end

return M
