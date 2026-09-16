local M = {}

local files = require("pim.completion.files")
local commands = nil

---Shared parsing is independent of buffer identity and menu backend.
---Columns and returned starts are zero-based byte offsets; rows are one-based.
---@param line string
---@param col integer
---@param row integer
---@return integer|nil
---@return string|nil
function M.parse_context(line, col, row)
	local before = line:sub(1, col)

	if row == 1 and before:match("^/[%w%-_:%.]*$") then
		return 0, "slash"
	end

	local at = before:find("@[^%s@]*$")
	if at then
		local prev = at > 1 and before:sub(at - 1, at - 1) or ""
		if at == 1 or prev:match("%s") then
			return at - 1, "file"
		end
	end

	return nil
end

function M.refresh_commands()
	local client = require("pim.rpc.client")
	if not client.is_running() then
		return
	end
	client.get_commands(function(success, data)
		if not success or type(data) ~= "table" then
			return
		end
		commands = {}
		for _, cmd in ipairs(data.commands or {}) do
			local source = cmd.source
			if type(source) ~= "string" and type(cmd.sourceInfo) == "table" then
				source = cmd.sourceInfo.source
			end
			commands[#commands + 1] = {
				name = cmd.name,
				description = cmd.description,
				source = type(source) == "string" and source or "",
			}
		end
	end)
end

---Unfiltered command metadata is returned without sigils or menu formatting.
---A fresh copy is owned by each caller; cached records must not be exposed.
---@return {name: string, description: string?, source: string}[]
function M.command_candidates()
	return vim.deepcopy(commands or {})
end

---Unfiltered eligible paths are returned in a fresh list, relative to cwd.
---Matching and sigil insertion are owned by the menu backend.
M.file_candidates = files.get
M.request_files = files.request

function M.reset()
	commands = nil
	files.reset()
end

return M
