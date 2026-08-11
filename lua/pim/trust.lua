local M = {}

local LOCK_ATTEMPTS = 10
local LOCK_DELAY_MS = 20
local LOCK_STALE_MS = 10000

local function trust_path()
	return vim.fs.joinpath(vim.fs.abspath(require("pim.config").pi_agent_dir()), "trust.json")
end

---@param path string|nil
---@return string
function M.canonical_path(path)
	local input = path or vim.uv.cwd()
	if not input then
		error("[pim] failed to resolve the current working directory", 0)
	end
	local absolute = vim.fs.abspath(input)
	return vim.uv.fs_realpath(absolute) or absolute
end

---@param path string|nil
---@return string|nil
function M.parent_path(path)
	local canonical = M.canonical_path(path)
	local parent = vim.fs.dirname(canonical)
	if parent == canonical then
		return nil
	end
	return parent
end

---@return string
function M.store_path()
	return trust_path()
end

local function fail(message)
	error("[pim] " .. message, 0)
end

local function ensure_directory(path)
	local ok, err = pcall(vim.fn.mkdir, path, "p")
	if not ok or vim.uv.fs_stat(path) == nil then
		fail(("failed to create trust store directory %s: %s"):format(path, tostring(err or "unknown error")))
	end
end

local function lock_is_stale(path)
	local stat = vim.uv.fs_stat(path)
	if not stat or not stat.mtime then
		return false
	end
	return (os.time() * 1000 - (stat.mtime.sec * 1000 + math.floor(stat.mtime.nsec / 1000000))) > LOCK_STALE_MS
end

local function acquire_lock(path)
	local lock_path = path .. ".lock"
	ensure_directory(vim.fs.dirname(path))
	local last_error

	for attempt = 1, LOCK_ATTEMPTS do
		local ok, err, code = vim.uv.fs_mkdir(lock_path, 448)
		if ok then
			return function()
				local removed, remove_err = vim.uv.fs_rmdir(lock_path)
				if not removed then
					fail(("failed to release trust store lock %s: %s"):format(lock_path, tostring(remove_err)))
				end
			end
		end

		last_error = err
		if code ~= "EEXIST" then
			fail(("failed to acquire trust store lock %s: %s"):format(lock_path, tostring(err)))
		end
		if lock_is_stale(lock_path) then
			vim.uv.fs_rmdir(lock_path)
		elseif attempt < LOCK_ATTEMPTS then
			vim.wait(LOCK_DELAY_MS)
		end
	end

	fail(("failed to acquire trust store lock %s: %s"):format(lock_path, tostring(last_error or "locked")))
end

local function with_lock(path, fn)
	local release = acquire_lock(path)
	local ok, result = pcall(fn)
	local released, release_error = pcall(release)
	if not ok then
		error(result, 0)
	end
	if not released then
		error(release_error, 0)
	end
	return result
end

local function read_file(path)
	local stat = vim.uv.fs_stat(path)
	if not stat then
		return {}
	end
	if stat.type ~= "file" then
		fail(("failed to read trust store %s: not a file"):format(path))
	end

	local file, open_error = io.open(path, "r")
	if not file then
		fail(("failed to read trust store %s: %s"):format(path, tostring(open_error)))
		return {}
	end
	local content = file:read("*a")
	file:close()

	local ok, data = pcall(vim.json.decode, content)
	if not ok then
		fail(("failed to read trust store %s: %s"):format(path, tostring(data)))
	end
	if type(data) ~= "table" or not content:match("^%s*{") then
		fail(("invalid trust store %s: expected an object"):format(path))
	end
	for key, value in pairs(data) do
		if type(key) ~= "string" or (value ~= true and value ~= false and value ~= vim.NIL) then
			fail(
				("invalid trust store %s: value for %s must be true, false, or null"):format(
					path,
					vim.json.encode(tostring(key))
				)
			)
		end
	end
	return data
end

local function encode_file(data)
	local keys = vim.tbl_keys(data)
	table.sort(keys)
	local lines = { "{" }
	for index, key in ipairs(keys) do
		local value = data[key]
		local encoded_value = value == vim.NIL and "null" or tostring(value)
		lines[#lines + 1] = ("  %s: %s%s"):format(vim.json.encode(key), encoded_value, index < #keys and "," or "")
	end
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n") .. "\n"
end

local function write_file(path, data)
	ensure_directory(vim.fs.dirname(path))
	local file, open_error = io.open(path, "w")
	if not file then
		fail(("failed to write trust store %s: %s"):format(path, tostring(open_error)))
		return
	end
	local ok, write_error = file:write(encode_file(data))
	local closed, close_error = file:close()
	if not ok or not closed then
		fail(("failed to write trust store %s: %s"):format(path, tostring(write_error or close_error)))
	end
end

local function nearest_entry(data, path)
	local current = M.canonical_path(path)
	while true do
		local decision = data[current]
		if decision == true or decision == false then
			return { path = current, decision = decision }
		end
		local parent = vim.fs.dirname(current)
		if parent == current then
			return nil
		end
		current = parent
	end
end

---@param path string|nil
---@return { path: string, decision: boolean }|nil
function M.get_entry(path)
	local store = trust_path()
	return with_lock(store, function()
		return nearest_entry(read_file(store), path)
	end)
end

---@param path string|nil
---@return boolean|nil
function M.get(path)
	local entry = M.get_entry(path)
	return entry and entry.decision or nil
end

---@param updates { path: string, decision: boolean|nil }[]
function M.set_many(updates)
	local store = trust_path()
	with_lock(store, function()
		local data = read_file(store)
		for _, update in ipairs(updates) do
			local key = M.canonical_path(update.path)
			if update.decision == nil then
				data[key] = nil
			elseif update.decision == true or update.decision == false then
				data[key] = update.decision
			else
				fail("trust decision must be true, false, or nil")
			end
		end
		write_file(store, data)
	end)
end

---@param path string|nil
function M.trust(path)
	M.set_many({ { path = M.canonical_path(path), decision = true } })
end

---@param path string|nil
function M.trust_parent(path)
	local project = M.canonical_path(path)
	local parent = M.parent_path(project)
	if not parent then
		fail(("cannot trust the parent of filesystem root %s"):format(project))
		return
	end
	M.set_many({
		{ path = parent, decision = true },
		{ path = project, decision = nil },
	})
end

---@param path string|nil
function M.reject(path)
	M.set_many({ { path = M.canonical_path(path), decision = false } })
end

return M
