local content = require("pim.content")

local M = {}

local PREVIEW_WIDTH = 72

function M.encode_cwd(cwd)
	return "--" .. cwd:gsub("^/", ""):gsub("/", "-") .. "--"
end

---@return string
function M.dir_for(cwd)
	return vim.fs.joinpath(require("pim.config").pi_sessions_dir(), M.encode_cwd(cwd))
end

local function decode(line)
	local ok, value = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
	if ok and type(value) == "table" then
		return value
	end
	return nil
end

---@param lines string[]
---@return { id: string, timestamp: string, cwd: string, name: string|nil, preview: string|nil, message_count: integer, path: string|nil, mtime: integer|nil }|nil
function M.parse_lines(lines)
	if #lines == 0 then
		return nil
	end
	local header = decode(lines[1])
	if not header or header.type ~= "session" then
		return nil
	end

	local info = {
		id = header.id,
		timestamp = header.timestamp,
		cwd = header.cwd,
		name = nil,
		preview = nil,
		message_count = 0,
	}

	for i = 2, #lines do
		local line = lines[i]
		-- Check the JSONL record type before decoding data that the picker does not need.
		if line:find('"type":"message"', 1, true) then
			info.message_count = info.message_count + 1
			if info.preview == nil and line:find('"role":"user"', 1, true) then
				local entry = decode(line)
				if entry and entry.message and entry.message.role == "user" then
					local text = content.first_text(entry.message.content)
					if text ~= nil then
						info.preview = content.one_line(text, PREVIEW_WIDTH)
					end
				end
			end
		elseif line:find('"type":"session_info"', 1, true) then
			local entry = decode(line)
			if entry and entry.type == "session_info" then
				info.name = entry.name
			end
		end
	end

	return info
end

---@return table[]
function M.list_dir(dir)
	local sessions = {}
	if not vim.uv.fs_stat(dir) then
		return sessions
	end
	for name, kind in vim.fs.dir(dir) do
		if kind == "file" and name:match("%.jsonl$") then
			local path = vim.fs.joinpath(dir, name)
			local file = io.open(path, "r")
			if file then
				local content = file:read("*a")
				file:close()
				local info = M.parse_lines(vim.split(content, "\n", { plain = true, trimempty = true }))
				if info then
					local stat = vim.uv.fs_stat(path)
					info.path = path
					info.mtime = stat and stat.mtime.sec or 0
					sessions[#sessions + 1] = info
				end
			end
		end
	end
	table.sort(sessions, function(a, b)
		return a.mtime > b.mtime
	end)
	return sessions
end

function M.list(cwd)
	return M.list_dir(M.dir_for(cwd or vim.uv.cwd()))
end

return M
