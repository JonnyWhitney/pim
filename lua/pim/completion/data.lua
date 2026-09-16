local M = {}

-- Git file lists change less often than completion requests. Keep the cache short for new files.
local GIT_CACHE_TTL_S = 10

local commands = nil

local git_cache = {}

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

---@param cwd string
---@param respect_gitignore boolean
local function git_files(cwd, respect_gitignore)
	if
		git_cache.cwd == cwd
		and git_cache.respect_gitignore == respect_gitignore
		and git_cache.files ~= nil
		and os.time() - git_cache.at <= GIT_CACHE_TTL_S
	then
		return git_cache.files
	end

	---@type string[]|false
	local files = false
	if vim.fs.root(cwd, ".git") then
		-- omnifunc must return its candidates now, so wait for the short Git query.
		local args = { "git", "ls-files", "--cached", "--others" }
		if respect_gitignore then
			args[#args + 1] = "--exclude-standard"
		end
		local result = vim.system(args, { cwd = cwd, text = true }):wait(2000)
		if result.code == 0 and result.stdout then
			files = vim.split(result.stdout, "\n", { trimempty = true })
		end
	end

	git_cache = { cwd = cwd, respect_gitignore = respect_gitignore, files = files, at = os.time() }
	return files
end

local function excluded(path, patterns, cwd)
	local normalized = vim.fs.normalize(path)
	if vim.startswith(normalized, cwd .. "/") then
		normalized = normalized:sub(#cwd + 2)
	end
	normalized = normalized:gsub("^%./", ""):gsub("/+$", "")
	local directory = path:sub(-1) == "/" or vim.fn.isdirectory(vim.fs.joinpath(cwd, normalized)) == 1
	for _, pattern in ipairs(patterns) do
		if pattern:match(normalized) or (directory and pattern:match(normalized .. "/")) then
			return true
		end
	end
	return false
end

---Eligible paths are returned in a fresh list, without sigils or prefix filtering.
---Git paths are relative to cwd. Until recursive discovery is available, the
---native fallback is scoped by fallback_prefix and the current Neovim directory.
---The fallback prefix is a discovery hint, not a shared matching policy.
---@param cwd string|nil
---@param fallback_prefix string|nil
---@return string[]
---@return boolean native_matched Whether matching was already applied by Neovim.
function M.file_candidates(cwd, fallback_prefix)
	cwd = vim.fs.normalize(cwd or vim.uv.cwd() or ".")
	local opts = require("pim.config").get().completion
	local patterns = {}
	for _, pattern in ipairs(opts.exclude) do
		patterns[#patterns + 1] = vim.glob.to_lpeg(pattern)
	end
	local files = git_files(cwd, opts.respect_gitignore)
	local matches = {}
	for _, path in ipairs(files or vim.fn.getcompletion(fallback_prefix or "", "file")) do
		if not excluded(path, patterns, cwd) then
			matches[#matches + 1] = path
		end
	end
	return matches, files == false
end

function M.reset()
	commands = nil
	git_cache = {}
end

return M
