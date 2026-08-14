local M = {}

local function normalize(text)
	return text:gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function render_replacement(edit, index)
	local lines = { ("@@ replacement %d @@"):format(index) }
	for _, line in ipairs(vim.split(normalize(edit.oldText), "\n", { plain = true })) do
		lines[#lines + 1] = "-" .. line
	end
	for _, line in ipairs(vim.split(normalize(edit.newText), "\n", { plain = true })) do
		lines[#lines + 1] = "+" .. line
	end
	return table.concat(lines, "\n")
end

local function replacement_preview(edits)
	local blocks = {}
	for index, edit in ipairs(edits or {}) do
		if type(edit) == "table" and type(edit.oldText) == "string" and type(edit.newText) == "string" then
			blocks[#blocks + 1] = render_replacement(edit, index)
		end
	end
	return #blocks > 0 and table.concat(blocks, "\n") or nil
end

local function edit_list(arguments)
	if type(arguments.edits) == "table" and #arguments.edits > 0 then
		return arguments.edits
	end
	if type(arguments.oldText) == "string" and type(arguments.newText) == "string" then
		return { { oldText = arguments.oldText, newText = arguments.newText } }
	end
	return nil
end

local function find_unique(content, text)
	if text == "" then
		return nil
	end
	local first, last = content:find(text, 1, true)
	if not first or content:find(text, last + 1, true) then
		return nil
	end
	return first, last
end

local function apply_edits(content, edits)
	local replacements = {}
	for _, edit in ipairs(edits) do
		if type(edit) ~= "table" or type(edit.oldText) ~= "string" or type(edit.newText) ~= "string" then
			return nil
		end
		local old_text = normalize(edit.oldText)
		local first, last = find_unique(content, old_text)
		if not first then
			return nil
		end
		replacements[#replacements + 1] = { first = first, last = last, text = normalize(edit.newText) }
	end
	table.sort(replacements, function(left, right)
		return left.first < right.first
	end)
	for index = 2, #replacements do
		if replacements[index].first <= replacements[index - 1].last then
			return nil
		end
	end

	local output = {}
	local cursor = 1
	for _, replacement in ipairs(replacements) do
		output[#output + 1] = content:sub(cursor, replacement.first - 1)
		output[#output + 1] = replacement.text
		cursor = replacement.last + 1
	end
	output[#output + 1] = content:sub(cursor)
	return table.concat(output)
end

local function read_file(path)
	local file = io.open(vim.fs.abspath(path), "rb")
	if not file then
		return nil
	end
	local content = file:read("*a")
	file:close()
	return content
end

local function edit_preview(arguments)
	local edits = edit_list(arguments)
	if not edits then
		return nil
	end
	local fallback = replacement_preview(edits)
	local path = arguments.path or arguments.file_path
	if type(path) ~= "string" or path == "" then
		return fallback
	end
	local original = read_file(path)
	if not original then
		return fallback
	end
	original = normalize(original)
	local updated = apply_edits(original, edits)
	if not updated then
		return fallback
	end
	local diff = vim.text.diff(original, updated, { result_type = "unified", ctxlen = 3 })
	return type(diff) == "string" and diff ~= "" and diff or fallback
end

---@param tool_name string|nil
---@param arguments table|nil
---@return string|nil
function M.generate(tool_name, arguments)
	if type(arguments) ~= "table" then
		return nil
	end
	if tool_name == "write" then
		return type(arguments.content) == "string" and arguments.content or nil
	end
	if tool_name == "bash" then
		return type(arguments.command) == "string" and arguments.command or nil
	end
	if tool_name == "edit" then
		return edit_preview(arguments)
	end
	return nil
end

return M
