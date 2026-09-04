local content = require("pim.content")
local markdown = require("pim.render.markdown")

local M = {}

local function bash_context(command)
	if type(command) ~= "string" then
		return nil
	end

	local first
	local additional = 0
	for _, line in ipairs(markdown.split_lines(command)) do
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

local function context(tool_name, arguments)
	if type(arguments) ~= "table" then
		return nil
	end
	if tool_name == "read" or tool_name == "edit" or tool_name == "write" then
		local path = arguments.path or arguments.file_path
		return type(path) == "string" and path ~= "" and path or nil
	end
	if tool_name == "bash" then
		return bash_context(arguments.command)
	end
	return nil
end

local function header(kind, tool_name, arguments, status)
	tool_name = tool_name or "tool"
	local text = ("▸ %s(%s)"):format(kind, tool_name)
	local detail = context(tool_name, arguments)
	if detail then
		text = text .. ": " .. detail
	end
	return text .. (status or "")
end

---@param block PimContentBlock
---@return PimRenderedBlock
function M.call(block)
	local lines = { header("tool", block.name, block.arguments) }
	local folds = {}
	if type(block.arguments) == "table" and not vim.tbl_isempty(block.arguments) then
		local _, last = markdown.append_fenced(lines, markdown.format_json(block.arguments), "json")
		folds[1] = { first = 0, last = last, kind = "tool" }
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

local function append_output(lines, exec, output)
	local last
	if exec.toolName == "bash" then
		local command = exec.preview
		if not command and type(exec.args) == "table" and type(exec.args.command) == "string" then
			command = exec.args.command
		end
		if command and vim.trim(command) ~= "" then
			local _, fence_last = markdown.append_fenced(lines, command, "bash")
			last = fence_last
		end
		if vim.trim(output) ~= "" then
			local _, fence_last = markdown.append_fenced(lines, output)
			last = fence_last
		end
		return last
	end

	local inspection = inspection_text(exec.toolName, exec.args, exec.result, exec.preview)
	local text = combine_inspection(output, inspection, exec.isError)
	if vim.trim(text) == "" then
		return nil
	end
	local language = exec.toolName == "edit" and "diff" or exec.toolName == "write" and write_language(exec.args) or nil
	local _, fence_last = markdown.append_fenced(lines, text, language)
	return fence_last
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

---@param exec PimToolExecution
---@return PimRenderedBlock
function M.execution(exec)
	local status = ""
	if exec.running then
		status = " [running]"
	elseif exec.isError then
		status = " ✘ error"
	end

	local lines = { header("result", exec.toolName, exec.args, status) }
	local folds = {}
	local last = append_output(lines, exec, result_text(exec.result))
	if last then
		folds[1] = { first = 0, last = last, kind = "tool" }
	end
	return { lines = lines, folds = folds }
end

---@param message PimMessage
---@return PimRenderedBlock
function M.bash_execution(message)
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
		local _, last = markdown.append_fenced(lines, output)
		folds[1] = { first = 0, last = last, kind = "tool" }
	end
	return { lines = lines, folds = folds }
end

return M
