local content = require("pim.content")

local M = {}

local function tool_call_label(name)
	name = content.one_line(name)
	return "pi: [tool call - " .. (name ~= "" and name or "tool") .. "]"
end

local function assistant_fallback(blocks)
	if type(blocks) ~= "table" then
		return "[response]"
	end
	local tools = {}
	local has_thinking = false
	for _, block in ipairs(blocks) do
		if type(block) == "table" then
			if block.type == "toolCall" then
				local name = content.one_line(block.name)
				tools[#tools + 1] = name ~= "" and name or "tool"
			elseif block.type == "thinking" then
				has_thinking = true
			end
		end
	end
	if #tools > 0 then
		return "[tool call - " .. table.concat(tools, ", ") .. "]"
	end
	return has_thinking and "[thinking]" or "[response]"
end

---@param entry PimSessionEntry
---@return string
function M.summary(entry)
	if entry.type == "message" then
		local message = entry.message or {}
		local role = message.role
		local text = content.one_line(content.first_text(message.content))
		if role == "user" then
			return "You: " .. (text ~= "" and text or "[empty prompt]")
		elseif role == "assistant" then
			return "pi: " .. (text ~= "" and text or assistant_fallback(message.content))
		elseif role == "toolResult" then
			local name = content.one_line(message.toolName)
			return name ~= "" and ("pi: [result - %s]"):format(name) or "pi: [result]"
		elseif role == "bashExecution" then
			return "! " .. content.one_line(message.command or "")
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

---@param entry PimSessionEntry
---@return string[]
function M.detail_lines(entry)
	local message = entry.message
	if
		entry.type ~= "message"
		or type(message) ~= "table"
		or message.role ~= "assistant"
		or type(message.content) ~= "table"
	then
		return { M.summary(entry) }
	end
	local lines = {}
	for _, block in ipairs(message.content) do
		if type(block) == "table" then
			if block.type == "text" then
				local text = content.one_line(block.text)
				if text ~= "" then
					lines[#lines + 1] = "pi: " .. text
				end
			elseif block.type == "toolCall" then
				lines[#lines + 1] = tool_call_label(block.name)
			elseif block.type == "thinking" then
				lines[#lines + 1] = "pi: [thinking]"
			end
		end
	end
	return #lines > 0 and lines or { M.summary(entry) }
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
				if entry.type == "branch_summary" or entry.type == "compaction" then
					vim.list_extend(visible, visible_nodes(node.children))
				else
					visible[#visible + 1] = node
				end
			end
		end
		return visible
	end

	local function has_role(node, role)
		local entry = node.entry
		return entry.type == "message" and type(entry.message) == "table" and entry.message.role == role
	end

	local function visit(nodes)
		nodes = visible_nodes(nodes)
		for _, node in ipairs(nodes) do
			local entry = node.entry
			local label = type(node.label) == "string" and node.label ~= "" and (" [" .. node.label .. "]") or ""
			local marker = entry.id == leaf_id and "● " or "  "
			local tail = node
			local turn_entries = has_role(node, "assistant") and { node.entry } or nil
			local count = 1
			if turn_entries and label == "" then
				while true do
					local children = visible_nodes(tail.children)
					local child = children[1]
					if
						#children ~= 1
						or not child
						or (not has_role(child, "assistant") and not has_role(child, "toolResult"))
						or (child.label and child.label ~= "")
					then
						break
					end
					tail = child
					turn_entries[#turn_entries + 1] = child.entry
					if has_role(child, "assistant") then
						count = count + 1
					end
					if child.entry.id == leaf_id then
						marker = "● "
					end
				end
			end
			local summary = turn_entries and "pi: [response]" or M.summary(entry)
			if count > 1 then
				summary = summary .. (" x %d"):format(count)
			end
			rows[#rows + 1] = {
				entry = tail.entry,
				id = tail.entry.id,
				line = marker .. summary .. label,
				turn_entries = turn_entries,
			}
			visit(tail.children)
		end
	end

	visit(tree)
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
