local M = {}
local data = require("pim.completion.data")

-- Shared data is kept independent of omni matching and menu presentation.
M.parse_context = data.parse_context
M.refresh_commands = data.refresh_commands
M.reset = data.reset

local function slash_matches(base)
	local prefix = base:sub(2)
	local items = {}
	for _, cmd in ipairs(data.command_candidates()) do
		if vim.startswith(cmd.name, prefix) then
			items[#items + 1] = {
				word = "/" .. cmd.name,
				menu = cmd.source,
				info = cmd.description or "",
			}
		end
	end
	return items
end

---The existing prefix-matched API is retained for omni callers.
---@param prefix string
---@param cwd string|nil
---@return string[]
function M.file_candidates(prefix, cwd)
	local matches = {}
	local paths = data.file_candidates(cwd)
	for _, path in ipairs(paths) do
		if vim.startswith(path, prefix) then
			matches[#matches + 1] = path
		end
	end
	return matches
end

local function file_matches(base)
	local items = {}
	for _, path in ipairs(M.file_candidates(base:sub(2))) do
		items[#items + 1] = { word = "@" .. path, menu = "file" }
	end
	return items
end

function M.omnifunc(findstart, base)
	if findstart == 1 then
		local cursor = vim.api.nvim_win_get_cursor(0)
		local start = M.parse_context(vim.api.nvim_get_current_line(), cursor[2], cursor[1])
		return start or -1
	end

	local sigil = base:sub(1, 1)
	if sigil == "/" then
		return slash_matches(base)
	elseif sigil == "@" then
		return file_matches(base)
	end
	return {}
end

function M.attach()
	local buf = require("pim.ui.layout").input_buf()
	if not buf then
		return
	end

	vim.bo[buf].omnifunc = "v:lua.require'pim.completion'.omnifunc"
	pcall(vim.api.nvim_set_option_value, "completeopt", "menu,menuone,noselect", { buf = buf })

	vim.keymap.set("i", "/", function()
		local cursor = vim.api.nvim_win_get_cursor(0)
		if cursor[1] == 1 and cursor[2] == 0 then
			return "/<C-x><C-o>"
		end
		return "/"
	end, { buffer = buf, expr = true, desc = "Slash-command completion" })

	vim.keymap.set("i", "@", function()
		local col = vim.api.nvim_win_get_cursor(0)[2]
		local prev = col > 0 and vim.api.nvim_get_current_line():sub(col, col) or ""
		if col == 0 or prev:match("%s") then
			return "@<C-x><C-o>"
		end
		return "@"
	end, { buffer = buf, expr = true, desc = "File-path completion" })
end

return M
