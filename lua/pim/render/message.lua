local content = require("pim.content")
local markdown = require("pim.render.markdown")
local tool = require("pim.render.tool")

local M = {}

local function render_user(message)
	local lines = { "### You", "" }
	markdown.append(lines, content.to_text(message.content))
	return { lines = lines, folds = {} }
end

local function append_rendered(lines, folds, rendered)
	local offset = #lines
	vim.list_extend(lines, rendered.lines)
	for _, fold in ipairs(rendered.folds) do
		folds[#folds + 1] = {
			first = fold.first + offset,
			last = fold.last + offset,
			kind = fold.kind,
		}
	end
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
			markdown.append_quoted(lines, block.redacted and "(redacted)" or block.thinking)
			folds[#folds + 1] = { first = first, last = #lines - 1, kind = "thinking" }
		elseif block.type == "toolCall" then
			append_rendered(lines, folds, tool.call(block))
		elseif block.type == "text" then
			markdown.append(lines, block.text)
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

local function render_tool_result(message, opts)
	local arguments = opts.tool_arguments and opts.tool_arguments[message.toolCallId]
	return tool.execution({
		toolName = message.toolName,
		args = arguments,
		isError = message.isError,
		result = {
			content = message.content,
			details = message.details,
		},
	})
end

local function render_custom(message)
	if message.display == false then
		return { lines = {}, folds = {} }
	end
	local lines = { ("### %s"):format(message.customType or "extension"), "" }
	markdown.append(lines, content.to_text(message.content))
	return { lines = lines, folds = {} }
end

local function render_branch_summary(message)
	local lines = { "▸ branch summary" }
	markdown.append_quoted(lines, message.summary or "")
	return { lines = lines, folds = { { first = 0, last = #lines - 1, kind = "summary" } } }
end

local function render_compaction_summary(message)
	local header = "▸ compacted"
	if message.tokensBefore then
		header = ("▸ compacted (%d tokens before)"):format(message.tokensBefore)
	end
	local lines = { header }
	markdown.append_quoted(lines, message.summary or "")
	return { lines = lines, folds = { { first = 0, last = #lines - 1, kind = "summary" } } }
end

local renderers = {
	user = render_user,
	assistant = render_assistant,
	toolResult = render_tool_result,
	bashExecution = tool.bash_execution,
	custom = render_custom,
	branchSummary = render_branch_summary,
	compactionSummary = render_compaction_summary,
}

---@param message PimMessage|nil
---@param opts { thinking: "folded"|"open"|"hidden"|nil, tool_arguments: table<string, table>|nil }|nil
---@return PimRenderedBlock
function M.render(message, opts)
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
