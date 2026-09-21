local M = {}
local commands = {}
local generation = 0

function M.refresh_commands()
	generation = generation + 1
	local request = generation
	commands = {}
	local client = require("pim.rpc.client")
	if not client.is_running() then
		return
	end
	client.get_commands(function(success, data)
		if request ~= generation or not success or type(data) ~= "table" or type(data.commands) ~= "table" then
			return
		end
		for _, cmd in ipairs(data.commands) do
			if type(cmd) == "table" and type(cmd.name) == "string" and cmd.name ~= "" then
				local source = cmd.source
				if type(source) ~= "string" and type(cmd.sourceInfo) == "table" then
					source = cmd.sourceInfo.source
				end
				commands[#commands + 1] = {
					name = cmd.name,
					description = type(cmd.description) == "string" and cmd.description or nil,
					source = type(source) == "string" and source or "",
				}
			end
		end
	end)
end

---A fresh copy of command metadata is returned without menu formatting.
---@return {name: string, description: string?, source: string}[]
function M.command_candidates()
	return vim.deepcopy(commands)
end

function M.reset()
	generation = generation + 1
	commands = {}
end

return M
