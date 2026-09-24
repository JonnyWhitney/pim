local M = {}

---@param value any
---@return string
function M.to_text(value)
	if type(value) == "string" then
		return value
	end
	if type(value) ~= "table" then
		return ""
	end

	local parts = {}
	for _, block in ipairs(value) do
		if type(block) == "table" and block.type == "text" then
			parts[#parts + 1] = type(block.text) == "string" and block.text or ""
		elseif type(block) == "table" and block.type == "image" then
			parts[#parts + 1] = ("[image: %s]"):format(block.mimeType or "unknown")
		else
			local block_type = type(block) == "table" and block.type or nil
			parts[#parts + 1] = ("[%s block]"):format(tostring(block_type))
		end
	end
	return table.concat(parts, "\n")
end

---@param value any
---@return string|nil
function M.first_text(value)
	if type(value) == "string" then
		return value
	end
	if type(value) ~= "table" then
		return nil
	end

	for _, block in ipairs(value) do
		if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
			return block.text
		end
	end
	return nil
end

---@param text any
---@param width integer|nil
---@return string
function M.one_line(text, width)
	text = type(text) == "string" and vim.trim(text:gsub("%s+", " ")) or ""
	if width and vim.fn.strchars(text) > width then
		return vim.fn.strcharpart(text, 0, width - 1) .. "…"
	end
	return text
end

return M
