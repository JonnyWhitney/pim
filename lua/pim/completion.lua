local M = {}

-- Git file lists change less often than completion requests. Keep the cache short for new files.
local GIT_CACHE_TTL_S = 10

local commands = nil

local git_cache = { cwd = nil, files = nil, at = 0 }

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

local function slash_matches(base)
	local prefix = base:sub(2)
	local items = {}
	for _, cmd in ipairs(commands or {}) do
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

---@param cwd string|nil
local function git_files(cwd)
	cwd = cwd or vim.uv.cwd() or "."
	if git_cache.cwd == cwd and git_cache.files ~= nil and os.time() - git_cache.at <= GIT_CACHE_TTL_S then
		return git_cache.files
	end

	---@type string[]|false
	local files = false
	if vim.fs.root(cwd, ".git") then
		-- omnifunc must return its candidates now, so wait for the short Git query.
		local result = vim.system(
			{ "git", "ls-files", "--cached", "--others", "--exclude-standard" },
			{ cwd = cwd, text = true }
		)
			:wait(2000)
		if result.code == 0 and result.stdout then
			files = vim.split(result.stdout, "\n", { trimempty = true })
		end
	end

	git_cache = { cwd = cwd, files = files, at = os.time() }
	return files
end

---@param prefix string
---@param cwd string|nil
---@return string[]
function M.file_candidates(prefix, cwd)
	local files = git_files(cwd)
	if files then
		local matches = {}
		for _, path in ipairs(files) do
			if path:find(prefix, 1, true) == 1 then
				matches[#matches + 1] = path
			end
		end
		return matches
	end
	return vim.fn.getcompletion(prefix, "file")
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

function M.reset()
	commands = nil
	git_cache = { cwd = nil, files = nil, at = 0 }
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
