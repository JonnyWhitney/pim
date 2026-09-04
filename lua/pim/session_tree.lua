local content = require("pim.content")

local M = {}

local PREVIEW_WIDTH = 72

local function preview(text)
	return content.one_line(text, PREVIEW_WIDTH)
end

---@param entry PimSessionEntry
---@return string
function M.summary(entry)
	if entry.type == "message" then
		local message = entry.message or {}
		local role = message.role
		local text = preview(content.first_text(message.content))
		if role == "user" then
			return "You: " .. (text ~= "" and text or "[empty prompt]")
		elseif role == "assistant" then
			return "pi: " .. (text ~= "" and text or "[response]")
		elseif role == "toolResult" then
			return "result: " .. (message.toolName or "tool")
		elseif role == "bashExecution" then
			return "! " .. preview(message.command or "")
		elseif role == "custom" then
			return (message.customType or "extension") .. ": " .. text
		end
		return tostring(role or "message")
	elseif entry.type == "model_change" then
		return ("model: %s/%s"):format(entry.provider or "-", entry.modelId or "-")
	elseif entry.type == "thinking_level_change" then
		return "thinking: " .. (entry.thinkingLevel or "-")
	elseif entry.type == "compaction" then
		return "compacted conversation"
	elseif entry.type == "branch_summary" then
		return "branch summary"
	elseif entry.type == "custom" then
		return "extension state: " .. (entry.customType or "unknown")
	elseif entry.type == "custom_message" then
		return "extension message: " .. (entry.customType or "unknown")
	elseif entry.type == "label" then
		return "label: " .. (entry.label or "cleared")
	elseif entry.type == "session_info" then
		return "session: " .. (entry.name or "unnamed")
	end
	return entry.type or "unknown entry"
end

---@param tree PimSessionTreeNode[]
---@param leaf_id string|nil
---@return PimTreeRow[]
function M.flatten(tree, leaf_id)
	local rows = {}

	local function visit(nodes, prefix, nested)
		for index, node in ipairs(nodes or {}) do
			local entry = node.entry
			if type(entry) == "table" then
				local last = index == #nodes
				local branch = nested and (last and "└─ " or "├─ ") or ""
				local label = type(node.label) == "string" and node.label ~= "" and (" [" .. node.label .. "]") or ""
				local marker = entry.id == leaf_id and "● " or "  "
				rows[#rows + 1] = {
					entry = entry,
					id = entry.id,
					line = marker .. prefix .. branch .. M.summary(entry) .. label,
				}
				local child_prefix = prefix
				if nested then
					child_prefix = child_prefix .. (last and "   " or "│  ")
				end
				visit(node.children, child_prefix, true)
			end
		end
	end

	visit(tree, "", false)
	return rows
end

---@param tree PimSessionTreeNode[]
---@param entry_id string
---@return PimSessionEntry[]|nil
function M.path(tree, entry_id)
	local entries = {}

	local function visit(nodes)
		for _, node in ipairs(nodes or {}) do
			local entry = node.entry
			if type(entry) == "table" then
				entries[#entries + 1] = entry
				if entry.id == entry_id or visit(node.children) then
					return true
				end
				entries[#entries] = nil
			end
		end
		return false
	end

	return visit(tree) and entries or nil
end

---@param tree PimSessionTreeNode[]
---@param entry_id string
---@return PimMessage[]|nil
function M.preview_messages(tree, entry_id)
	local entries = M.path(tree, entry_id)
	if not entries then
		return nil
	end

	local messages = {}
	for _, entry in ipairs(entries) do
		if entry.type == "message" and type(entry.message) == "table" then
			messages[#messages + 1] = entry.message
		elseif entry.type == "compaction" then
			messages[#messages + 1] = {
				role = "compactionSummary",
				summary = entry.summary,
				tokensBefore = entry.tokensBefore,
			}
		elseif entry.type == "branch_summary" then
			messages[#messages + 1] = {
				role = "branchSummary",
				summary = entry.summary,
			}
		elseif entry.type == "custom_message" then
			messages[#messages + 1] = {
				role = "custom",
				customType = entry.customType,
				content = entry.content,
				display = entry.display,
			}
		end
	end
	return messages
end

return M
