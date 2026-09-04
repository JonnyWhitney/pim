local M = {}

function M.split_lines(text)
	return vim.split(text or "", "\n", { plain = true })
end

function M.append(lines, text)
	vim.list_extend(lines, M.split_lines(text))
end

-- Use a fence longer than every backtick run in the output.
local function fence_for(text)
	local longest = 2
	for run in text:gmatch("`+") do
		longest = math.max(longest, #run)
	end
	return string.rep("`", longest + 1)
end

function M.append_fenced(lines, text, language)
	text = (text or ""):gsub("\n$", "")

	local fence = fence_for(text)
	local first = #lines
	lines[#lines + 1] = fence .. (language or "")
	M.append(lines, text)
	lines[#lines + 1] = fence
	return first, #lines - 1
end

function M.append_quoted(lines, text)
	for _, line in ipairs(M.split_lines(text)) do
		lines[#lines + 1] = line == "" and ">" or ("> " .. line)
	end
end

function M.format_json(value)
	local encoded = vim.json.encode(value)
	local output = {}
	local indent = 0
	local index = 1

	local function newline()
		output[#output + 1] = "\n" .. string.rep("  ", indent)
	end

	while index <= #encoded do
		local char = encoded:sub(index, index)
		if char == '"' then
			local last = index + 1
			while last <= #encoded do
				local candidate = encoded:sub(last, last)
				if candidate == "\\" then
					last = last + 2
				elseif candidate == '"' then
					break
				else
					last = last + 1
				end
			end
			output[#output + 1] = encoded:sub(index, last)
			index = last
		elseif char == "{" or char == "[" then
			local closing = char == "{" and "}" or "]"
			if encoded:sub(index + 1, index + 1) == closing then
				output[#output + 1] = char .. closing
				index = index + 1
			else
				output[#output + 1] = char
				indent = indent + 1
				newline()
			end
		elseif char == "}" or char == "]" then
			indent = indent - 1
			newline()
			output[#output + 1] = char
		elseif char == "," then
			output[#output + 1] = char
			newline()
		elseif char == ":" then
			output[#output + 1] = ": "
		elseif not char:match("%s") then
			output[#output + 1] = char
		end
		index = index + 1
	end

	return table.concat(output)
end

return M
