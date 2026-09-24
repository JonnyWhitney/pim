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

	-- Hidden entries are bypassed only for display; the source tree is retained.
	local function visible_nodes(nodes)
		local visible = {}
		for _, node in ipairs(nodes or {}) do
			local entry = node.entry
			if type(entry) == "table" then
				if
					entry.type == "branch_summary"
					or entry.type == "compaction"
					or (
						entry.type == "message"
						and type(entry.message) == "table"
						and entry.message.role == "toolResult"
					)
				then
					vim.list_extend(visible, visible_nodes(node.children))
				else
					visible[#visible + 1] = node
				end
			end
		end
		return visible
	end

	local function is_assistant(node)
		local entry = node.entry
		return entry.type == "message" and type(entry.message) == "table" and entry.message.role == "assistant"
	end

	local function visit(nodes, prefix, nested)
		nodes = visible_nodes(nodes)
		for index, node in ipairs(nodes) do
			local entry = node.entry
			local last = index == #nodes
			local branch = nested and (last and "└─ " or "├─ ") or ""
			local label = type(node.label) == "string" and node.label ~= "" and (" [" .. node.label .. "]") or ""
			local marker = entry.id == leaf_id and "● " or "  "
			local tail = node
			local count = 1
			if is_assistant(node) and label == "" then
				while true do
					local children = visible_nodes(tail.children)
					local child = children[1]
					if
						#children ~= 1
						or not child
						or not is_assistant(child)
						or (child.label and child.label ~= "")
					then
						break
					end
					tail = child
					count = count + 1
					if child.entry.id == leaf_id then
						marker = "● "
					end
				end
			end
			local summary = M.summary(entry) .. (count > 1 and (" x %d"):format(count) or "")
			rows[#rows + 1] = {
				entry = tail.entry,
				id = tail.entry.id,
				line = marker .. prefix .. branch .. summary .. label,
			}
			local child_prefix = prefix
			if nested then
				child_prefix = child_prefix .. (last and "   " or "│  ")
			end
			visit(tail.children, child_prefix, true)
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
