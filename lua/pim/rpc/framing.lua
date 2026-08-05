local M = {}

local DEFAULT_MAX_LINE_BYTES = 8 * 1024 * 1024
---@class PimFramingReader
---@field remainder string
---@field discarding boolean
---@field max_bytes integer

---@param max_bytes integer|nil
---@return PimFramingReader
function M.new(max_bytes)
	return { remainder = "", discarding = false, max_bytes = max_bytes or DEFAULT_MAX_LINE_BYTES }
end

---@param reader PimFramingReader
---@param chunk string
---@return string[]
---@return integer
function M.feed(reader, chunk)
	-- Discard through the next LF. This prevents an oversized line tail from becoming a message.
	if reader.discarding then
		local resync = chunk:find("\n", 1, true)
		if not resync then
			return {}, 0
		end
		reader.discarding = false
		chunk = chunk:sub(resync + 1)
	end

	local buf = reader.remainder .. chunk
	local lines = {}
	local start = 1

	while true do
		local nl = buf:find("\n", start, true)
		if not nl then
			break
		end
		local line = buf:sub(start, nl - 1)
		if line:sub(-1) == "\r" then
			line = line:sub(1, -2)
		end
		if line ~= "" then
			lines[#lines + 1] = line
		end
		start = nl + 1
	end

	local remainder = buf:sub(start)
	if #remainder > reader.max_bytes then
		reader.remainder = ""
		reader.discarding = true
		return lines, #remainder
	end

	reader.remainder = remainder
	return lines, 0
end

return M
