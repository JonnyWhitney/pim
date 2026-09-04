local content = require("pim.content")

local M = {}

local function split_lines(text)
	return vim.split(text or "", "\n", { plain = true })
end

local function append(lines, text)
	vim.list_extend(lines, split_lines(text))
end

-- Use a fence longer than every backtick run in the output.
local function fence_for(text)
	local longest = 2
	for run in text:gmatch("`+") do
		longest = math.max(longest, #run)
	end
	return string.rep("`", longest + 1)
end

local function append_fenced(lines, text, language)
	text = (text or ""):gsub("\n$", "")

	local fence = fence_for(text)
	local first = #lines
	lines[#lines + 1] = fence .. (language or "")
	append(lines, text)
	lines[#lines + 1] = fence
	return first, #lines - 1
end

local function append_quoted(lines, text)
	for _, line in ipairs(split_lines(text)) do
		lines[#lines + 1] = line == "" and ">" or ("> " .. line)
	end
end

local function format_json(value)
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

local function bash_context(command)
	if type(command) ~= "string" then
		return nil
	end

	local first
	local additional = 0
	for _, line in ipairs(split_lines(command)) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			if not first then
				first = trimmed
			else
				additional = additional + 1
			end
		end
	end
	if not first then
		return nil
	end
	if additional > 0 then
		return ("%s … (+%d lines)"):format(first, additional)
	end
	return first
end

local function tool_context(name, arguments)
	if type(arguments) ~= "table" then
		return nil
	end
	if name == "read" or name == "edit" or name == "write" then
		local path = arguments.path or arguments.file_path
		return type(path) == "string" and path ~= "" and path or nil
	end
	if name == "bash" then
		return bash_context(arguments.command)
	end
	return nil
end

local function tool_header(kind, name, arguments, status)
	name = name or "tool"
	local header = ("▸ %s(%s)"):format(kind, name)
	local context = tool_context(name, arguments)
	if context then
		header = header .. ": " .. context
	end
	return header .. (status or "")
end

local function render_user(message)
	local lines = { "### You", "" }
	append(lines, content.to_text(message.content))
	return { lines = lines, folds = {} }
end

local function render_assistant(message, opts)
	local lines = { "### pi", "" }
	local folds = {}

	for _, block in ipairs(message.content or {}) do
		local empty_thinking = block.type == "thinking" and not block.redacted and vim.trim(block.thinking or "") == ""
		if block.type == "thinking" and (opts.thinking == "hidden" or empty_thinking) then
			goto continue
		end
		if #lines > 2 then
			lines[#lines + 1] = ""
		end
		if block.type == "thinking" then
			local first = #lines
			lines[#lines + 1] = "▸ thinking"
			append_quoted(lines, block.redacted and "(redacted)" or block.thinking)
			folds[#folds + 1] = { first = first, last = #lines - 1, kind = "thinking" }
		elseif block.type == "toolCall" then
			local first = #lines
			lines[#lines + 1] = tool_header("tool", block.name, block.arguments)
			if type(block.arguments) == "table" and not vim.tbl_isempty(block.arguments) then
				local _, last = append_fenced(lines, format_json(block.arguments), "json")
				folds[#folds + 1] = { first = first, last = last, kind = "tool" }
			end
		elseif block.type == "text" then
			append(lines, block.text)
		else
			lines[#lines + 1] = ("▸ %s block"):format(tostring(block.type))
		end
		::continue::
	end

	if message.stopReason == "aborted" or message.stopReason == "error" then
		if lines[#lines] ~= "" then
			lines[#lines + 1] = ""
		end
		if message.stopReason == "aborted" then
			lines[#lines + 1] = "*(aborted)*"
		else
			lines[#lines + 1] = "**error:** " .. (message.errorMessage or "unknown error")
		end
	end

	return { lines = lines, folds = folds }
end

local function inspection_text(tool_name, arguments, result, preview)
	if tool_name == "edit" and type(result) == "table" and type(result.details) == "table" then
		local diff = result.details.diff
		if type(diff) == "string" and diff ~= "" then
			return diff
		end
	end
	if tool_name == "write" and type(arguments) == "table" and type(arguments.content) == "string" then
		return arguments.content
	end
	if tool_name == "edit" then
		return preview
	end
	return nil
end

local function combine_inspection(output, inspection, is_error)
	if not inspection then
		return output
	end
	if is_error and vim.trim(output) ~= "" then
		return output .. "\n\n" .. inspection
	end
	return inspection
end

local function write_language(arguments)
	if type(arguments) ~= "table" then
		return nil
	end
	local path = arguments.path or arguments.file_path
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local language = vim.filetype.match({ filename = path })
	return type(language) == "string" and language or nil
end

local function append_tool_output(lines, tool_name, arguments, result, preview, is_error, output)
	local last
	if tool_name == "bash" then
		local command = preview
		if not command and type(arguments) == "table" and type(arguments.command) == "string" then
			command = arguments.command
		end
		if command and vim.trim(command) ~= "" then
			local _, fence_last = append_fenced(lines, command, "bash")
			last = fence_last
		end
		if vim.trim(output) ~= "" then
			local _, fence_last = append_fenced(lines, output)
			last = fence_last
		end
		return last
	end

	local text = combine_inspection(output, inspection_text(tool_name, arguments, result, preview), is_error)
	if vim.trim(text) == "" then
		return nil
	end
	local language = tool_name == "edit" and "diff" or tool_name == "write" and write_language(arguments) or nil
	local _, fence_last = append_fenced(lines, text, language)
	return fence_last
end

local function render_tool_result(message, opts)
	local lines = {}
	local status = message.isError and " ✘ error" or ""
	local arguments = opts.tool_arguments and opts.tool_arguments[message.toolCallId]
	lines[#lines + 1] = tool_header("result", message.toolName, arguments, status)
	local folds = {}
	local last = append_tool_output(
		lines,
		message.toolName,
		arguments,
		message,
		nil,
		message.isError,
		content.to_text(message.content)
	)
	if last then
		folds[#folds + 1] = { first = 0, last = last, kind = "tool" }
	end
	return { lines = lines, folds = folds }
end

local function render_bash_execution(message)
	local marks = {}
	if message.running then
		marks[#marks + 1] = "[running]"
	elseif message.cancelled then
		marks[#marks + 1] = "[cancelled]"
	elseif message.failed then
		marks[#marks + 1] = "✘ error"
	elseif message.exitCode ~= nil and message.exitCode ~= 0 then
		marks[#marks + 1] = ("[exit %d]"):format(message.exitCode)
	end
	if message.excludeFromContext then
		marks[#marks + 1] = "[not in context]"
	end
	local status = #marks > 0 and (" " .. table.concat(marks, " ")) or ""

	local lines = { ("▸ ! %s%s"):format(message.command or "", status) }
	local folds = {}
	local output = message.output or ""
	if message.truncated then
		output = output .. "\n[output truncated]"
	end
	if vim.trim(output) ~= "" then
		local _, last = append_fenced(lines, output)
		folds[#folds + 1] = { first = 0, last = last, kind = "tool" }
	end
	return { lines = lines, folds = folds }
end

local function render_custom(message)
	if message.display == false then
		return { lines = {}, folds = {} }
	end
	local lines = { ("### %s"):format(message.customType or "extension"), "" }
	append(lines, content.to_text(message.content))
	return { lines = lines, folds = {} }
end

local function render_branch_summary(message)
	local lines = { "▸ branch summary" }
	append_quoted(lines, message.summary or "")
	return { lines = lines, folds = { { first = 0, last = #lines - 1, kind = "summary" } } }
end

local function render_compaction_summary(message)
	local header = "▸ compacted"
	if message.tokensBefore then
		header = ("▸ compacted (%d tokens before)"):format(message.tokensBefore)
	end
	local lines = { header }
	append_quoted(lines, message.summary or "")
	return { lines = lines, folds = { { first = 0, last = #lines - 1, kind = "summary" } } }
end

local function result_text(result)
	if result == nil then
		return ""
	end
	if type(result) == "string" then
		return result
	end
	if type(result) == "table" then
		if result.content then
			return content.to_text(result.content)
		end
		if type(result.output) == "string" then
			return result.output
		end
		if type(result.text) == "string" then
			return result.text
		end
	end
	return vim.inspect(result)
end

---@param exec { toolName: string, args: table|nil, preview: string|nil, running: boolean|nil, isError: boolean|nil, result: any }
---@return { lines: string[], folds: table[] }
function M.tool_execution(exec)
	local status = ""
	if exec.running then
		status = " [running]"
	elseif exec.isError then
		status = " ✘ error"
	end

	local lines = { tool_header("result", exec.toolName, exec.args, status) }
	local folds = {}
	local last = append_tool_output(
		lines,
		exec.toolName,
		exec.args,
		exec.result,
		exec.preview,
		exec.isError,
		result_text(exec.result)
	)
	if last then
		folds[#folds + 1] = { first = 0, last = last, kind = "tool" }
	end
	return { lines = lines, folds = folds }
end

local renderers = {
	user = render_user,
	assistant = render_assistant,
	toolResult = render_tool_result,
	bashExecution = render_bash_execution,
	custom = render_custom,
	branchSummary = render_branch_summary,
	compactionSummary = render_compaction_summary,
}

---@param message table
---@param opts { thinking: "folded"|"open"|"hidden"|nil, tool_arguments: table<string, table>|nil }|nil
---@return { lines: string[], folds: { first: integer, last: integer, kind: string }[] }
function M.message(message, opts)
	local renderer = message and renderers[message.role]
	if not renderer then
		return {
			lines = { ("▸ %s message"):format(message and tostring(message.role) or "unknown") },
			folds = {},
		}
	end
	return renderer(message, opts or {})
end

return M
