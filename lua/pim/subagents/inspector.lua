local content = require("pim.content")
local markdown = require("pim.render.markdown")
local message_renderer = require("pim.render.message")

local M = {}

---@class PimSubagentReader
---@field offset integer
---@field records table[]
---@field errors integer
---@field missing boolean

---@class PimSubagentInspector
---@field invocation PimSubagentInvocation
---@field buf integer
---@field readers table<string, PimSubagentReader>
---@field ranges table<string, { first: integer, last: integer }>

---@type table<string, PimSubagentInspector>
local inspectors = {}

local function inside(path, parent)
	path = vim.fs.normalize(path)
	parent = vim.fs.normalize(parent)
	return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

local function safe_transcript_path(invocation, path)
	local root = vim.fs.normalize(require("pim.subagents").transcript_root())
	local directory = vim.fs.normalize(invocation.details.transcriptDir)
	if not inside(directory, root) or not inside(path, directory) then
		return false
	end
	local real = vim.uv.fs_realpath(path)
	local real_root = vim.uv.fs_realpath(root) or root
	return real == nil or inside(real, real_root)
end

local function read_new(reader, path)
	local file = io.open(path, "rb")
	if not file then
		reader.missing = true
		return
	end
	reader.missing = false
	local size = assert(file:seek("end"))
	if size < reader.offset then
		reader.offset = 0
		reader.records = {}
		reader.errors = 0
	end
	assert(file:seek("set", reader.offset))
	local bytes = file:read("*a") or ""
	file:close()
	local boundary = bytes:match("^.*()\n")
	if not boundary then
		return
	end
	local complete = bytes:sub(1, boundary)
	reader.offset = reader.offset + #complete
	for line in complete:gmatch("(.-)\n") do
		if line ~= "" then
			local ok, envelope = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
			if ok and type(envelope) == "table" and type(envelope.record) == "table" then
				reader.records[#reader.records + 1] = envelope.record
			else
				reader.errors = reader.errors + 1
			end
		end
	end
end

local function append_message(lines, record)
	if record.type ~= "message_end" or type(record.message) ~= "table" then
		return false
	end
	local message = record.message
	if message.role ~= "assistant" and message.role ~= "toolResult" then
		return true
	end
	local rendered = message_renderer.render(message, { thinking = "open", tool_arguments = {} })
	if #rendered.lines > 0 then
		if #lines > 0 and lines[#lines] ~= "" then
			lines[#lines + 1] = ""
		end
		vim.list_extend(lines, rendered.lines)
	end
	return true
end

local function append_record(lines, record)
	if append_message(lines, record) then
		return
	end
	if record.type == "configuration" and type(record.agent) == "table" then
		local agent = record.agent
		lines[#lines + 1] = ("Model: `%s` · thinking: `%s`"):format(
			tostring(agent.model or "unknown"),
			tostring(agent.thinkingLevel or "unknown")
		)
		lines[#lines + 1] = "Tools: " .. (type(agent.tools) == "table" and table.concat(agent.tools, ", ") or "unknown")
		lines[#lines + 1] = "Prompt: " .. content.one_line(agent.prompt or "", 160)
		if agent.cwd then
			lines[#lines + 1] = "Working directory: `" .. tostring(agent.cwd) .. "`"
		end
	elseif record.type == "stderr" and type(record.text) == "string" then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "**stderr:**"
		markdown.append_fenced(lines, record.text)
	elseif record.type == "malformed" or record.type == "incomplete" then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "**Transcript error:** " .. tostring(record.type)
	elseif record.type == "status" then
		lines[#lines + 1] = "Status: **" .. tostring(record.status) .. "**"
	end
end

local function usage_text(usage)
	if type(usage) ~= "table" then
		return nil
	end
	local tokens = tonumber(usage.totalTokens)
	local cost = type(usage.cost) == "table" and tonumber(usage.cost.total) or nil
	if tokens and cost then
		return ("Usage: %d tokens · $%.4f"):format(tokens, cost)
	end
	return tokens and ("Usage: %d tokens"):format(tokens) or nil
end

local function render(inspector)
	local lines = { "# Subagents", "", "Invocation: `" .. inspector.invocation.invocation_id .. "`", "" }
	local ranges = {}
	local total_tokens, total_cost = 0, 0
	for _, agent in ipairs(inspector.invocation.details.agents) do
		local first = #lines + 1
		lines[#lines + 1] = ("## %s [%s]"):format(agent.label, agent.status)
		local reader = inspector.readers[agent.id]
		if reader.missing then
			lines[#lines + 1] = "**Transcript unavailable:** `" .. agent.transcriptPath .. "`"
		else
			for _, record in ipairs(reader.records) do
				append_record(lines, record)
			end
			if reader.errors > 0 then
				lines[#lines + 1] = ("**Transcript warning:** %d malformed JSONL %s skipped."):format(
					reader.errors,
					reader.errors == 1 and "record was" or "records were"
				)
			end
		end
		local usage = usage_text(agent.usage)
		if usage then
			lines[#lines + 1] = ""
			lines[#lines + 1] = usage
			total_tokens = total_tokens + (tonumber(agent.usage.totalTokens) or 0)
			total_cost = total_cost + (type(agent.usage.cost) == "table" and tonumber(agent.usage.cost.total) or 0)
		end
		lines[#lines + 1] = ""
		ranges[agent.id] = { first = first, last = #lines - 1 }
	end
	if total_tokens > 0 or total_cost > 0 then
		lines[#lines + 1] = ("Aggregate usage: %d tokens · $%.4f"):format(total_tokens, total_cost)
	end
	return lines, ranges
end

local function write(inspector)
	local lines, ranges = render(inspector)
	vim.bo[inspector.buf].modifiable = true
	vim.api.nvim_buf_set_lines(inspector.buf, 0, -1, false, lines)
	vim.bo[inspector.buf].modifiable = false
	inspector.ranges = ranges
	for _, win in ipairs(vim.fn.win_findbuf(inspector.buf)) do
		vim.api.nvim_win_call(win, function()
			vim.cmd("silent! normal! zE")
			for _, range in pairs(ranges) do
				if range.last > range.first then
					vim.cmd(("silent! %d,%dfold"):format(range.first, range.last))
					vim.cmd(("silent! %dfoldopen"):format(range.first))
				end
			end
		end)
	end
end

local function ensure(invocation)
	local inspector = inspectors[invocation.invocation_id]
	if inspector and vim.api.nvim_buf_is_valid(inspector.buf) then
		inspector.invocation = invocation
		return inspector
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, "pim://subagents/" .. invocation.invocation_id)
	vim.b[buf].pim_role = "subagent-transcript"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = false
	inspector = { invocation = invocation, buf = buf, readers = {}, ranges = {} }
	inspectors[invocation.invocation_id] = inspector
	return inspector
end

local function update(inspector)
	for _, agent in ipairs(inspector.invocation.details.agents) do
		local reader = inspector.readers[agent.id]
		if not reader then
			reader = { offset = 0, records = {}, errors = 0, missing = false }
			inspector.readers[agent.id] = reader
		end
		if safe_transcript_path(inspector.invocation, agent.transcriptPath) then
			read_new(reader, agent.transcriptPath)
		else
			reader.missing = true
		end
	end
	write(inspector)
end

---@param invocation PimSubagentInvocation
function M.open(invocation)
	local inspector = ensure(invocation)
	update(inspector)
	local windows = vim.fn.win_findbuf(inspector.buf)
	if #windows > 0 then
		vim.api.nvim_set_current_win(windows[1])
	else
		vim.cmd("tabnew")
		vim.api.nvim_win_set_buf(0, inspector.buf)
		vim.wo.foldmethod = "manual"
		vim.wo.foldenable = true
		write(inspector)
	end
	return inspector.buf
end

---@param invocation_id string
function M.refresh(invocation_id)
	local inspector = inspectors[invocation_id]
	local invocation = require("pim.subagents.state").get(invocation_id)
	if not inspector or not invocation or not vim.api.nvim_buf_is_valid(inspector.buf) then
		return
	end
	inspector.invocation = invocation
	update(inspector)
end

function M.reset()
	inspectors = {}
end

return M
