local M = {}
local TTL = 10
local BATCH = 128
local cache = {}
local requests = {}

local function settings(cwd)
	local opts = vim.deepcopy(require("pim.config").get().completion)
	cwd = vim.fs.normalize(vim.fn.fnamemodify(cwd or vim.uv.cwd() or ".", ":p"))
	local key = vim.json.encode({ cwd, opts.respect_gitignore, opts.exclude })
	local patterns = {}
	for _, glob in ipairs(opts.exclude) do
		patterns[#patterns + 1] = vim.glob.to_lpeg(glob)
	end
	return cwd, opts, key, patterns
end

local function eligible(path, patterns)
	for _, pattern in ipairs(patterns) do
		if pattern:match(path) then
			return false
		end
	end
	return true
end

local function cached(key)
	local entry = cache[key]
	if entry and os.time() - entry.at <= TTL then
		return vim.deepcopy(entry.files)
	end
end

local function store(key, files)
	table.sort(files)
	cache[key] = { at = os.time(), files = vim.deepcopy(files) }
	return files
end

local function args(opts)
	local result = { "git", "ls-files", "-z", "--cached", "--others" }
	if opts.respect_gitignore then
		result[#result + 1] = "--exclude-standard"
	end
	return result
end

local function git_result(result, patterns)
	if result.code ~= 0 or not result.stdout then
		return nil
	end
	local files, seen = {}, {}
	for path in result.stdout:gmatch("([^%z]+)") do
		if not seen[path] and eligible(path, patterns) then
			seen[path] = true
			files[#files + 1] = path
		end
	end
	return files
end

-- No directories are pruned: a directory glob need not exclude its descendants.
-- Each step reads at most BATCH entries. Only one directory handle is held open.
local function walker(cwd, patterns)
	local pending, files = { "" }, {}
	local handle, parent
	local function close()
		if handle then
			vim.uv.fs_closedir(handle)
			handle = nil
		end
	end
	local function step()
		if not handle then
			parent = table.remove(pending)
			if parent == nil then
				return files
			end
			local absolute = vim.fs.joinpath(cwd, parent)
			local stat = vim.uv.fs_lstat(absolute)
			if not stat or stat.type ~= "directory" then
				return nil
			end
			handle = vim.uv.fs_opendir(absolute, nil, BATCH)
			if not handle then
				return nil
			end
		end
		local entries = vim.uv.fs_readdir(handle)
		if not entries then
			close()
			return nil
		end
		for _, entry in ipairs(entries) do
			local path = parent == "" and entry.name or parent .. "/" .. entry.name
			local absolute = vim.fs.joinpath(cwd, path)
			local stat = vim.uv.fs_lstat(absolute)
			if stat then
				if stat.type == "directory" then
					pending[#pending + 1] = path
				elseif stat.type == "file" or stat.type == "link" then
					local target = stat.type == "link" and vim.uv.fs_stat(absolute) or stat
					if target and target.type == "file" and eligible(path, patterns) then
						files[#files + 1] = path
					end
				end
			end
		end
	end
	return step, close
end

---Synchronous compatibility API for omni. Files are relative to cwd and caller-owned.
---Git gets a two-second timeout; fallback traversal has no candidate limit.
function M.get(cwd)
	local opts, key, patterns
	cwd, opts, key, patterns = settings(cwd)
	local hit = cached(key)
	if hit then
		return hit
	end
	if vim.fs.root(cwd, ".git") then
		local ok, result = pcall(function()
			return vim.system(args(opts), { cwd = cwd }):wait(2000)
		end)
		local files = ok and git_result(result, patterns) or nil
		if files then
			return store(key, files)
		end
	end
	local step = walker(cwd, patterns)
	while true do
		local files = step()
		if files then
			return store(key, files)
		end
	end
end

---Scheduled discovery. callback is called once with a fresh, complete list.
---The returned cancel function suppresses delivery and closes owned resources.
---is_current must check buffer/context identity; cwd/settings changes and reset
---are checked here. No partial or stale result is cached. Callbacks are scheduled,
---including cache hits. Batches yield between at most 128 filesystem entries.
---@param cwd string|nil
---@param callback fun(files: string[])
---@param is_current? fun(): boolean
---@return fun()
function M.request(cwd, callback, is_current)
	local opts, key, patterns
	cwd, opts, key, patterns = settings(cwd)
	local initial_cwd = vim.uv.cwd()
	local cancelled, process, close = false, nil, nil
	local cancel
	cancel = function()
		cancelled = true
		requests[cancel] = nil
		if process then
			process:kill(15)
			process = nil
		end
		if close then
			close()
			close = nil
		end
	end
	requests[cancel] = true
	local function current()
		if cancelled then
			return false
		end
		local _, _, now = settings(cwd)
		if vim.uv.cwd() ~= initial_cwd or now ~= key or (is_current and not is_current()) then
			cancel()
			return false
		end
		return true
	end
	local function deliver(files)
		if current() then
			store(key, files)
			cancel()
			callback(files)
		end
	end
	local function fallback()
		local step
		step, close = walker(cwd, patterns)
		local function tick()
			if not current() then
				return
			end
			local files = step()
			if files then
				deliver(files)
			else
				vim.defer_fn(tick, 1)
			end
		end
		vim.schedule(tick)
	end
	vim.schedule(function()
		if not current() then
			return
		end
		local hit = cached(key)
		if hit then
			cancel()
			callback(hit)
			return
		end
		if not vim.fs.root(cwd, ".git") then
			fallback()
			return
		end
		local ok, job = pcall(vim.system, args(opts), { cwd = cwd, timeout = 2000 }, function(result)
			vim.schedule(function()
				process = nil
				if not current() then
					return
				end
				local files = git_result(result, patterns)
				if files then
					deliver(files)
				else
					fallback()
				end
			end)
		end)
		if ok then
			process = job
		else
			fallback()
		end
	end)
	return cancel
end

function M.reset()
	for cancel in pairs(requests) do
		cancel()
	end
	cache = {}
end

return M
