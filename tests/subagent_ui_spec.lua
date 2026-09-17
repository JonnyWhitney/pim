local h = require("helpers")
local events = require("pim.events")
local inspector = require("pim.subagents.inspector")
local subagent_state = require("pim.subagents.state")
local tool = require("pim.render.tool")

local function details(directory, statuses)
	local agents = {}
	for index, status in ipairs(statuses) do
		agents[index] = {
			id = "child-" .. index,
			label = index == 1 and "parser review" or "test review",
			status = status,
			transcriptPath = vim.fs.joinpath(directory, "child-" .. index .. ".jsonl"),
			summary = nil,
			usage = nil,
			stoppedBy = nil,
		}
	end
	return {
		schemaVersion = 1,
		invocationId = "invocation-123",
		mode = #agents == 1 and "single" or "parallel",
		status = statuses[1],
		transcriptDir = directory,
		agents = agents,
	}
end

local function with_root(root, fn)
	local subagents = require("pim.subagents")
	local original = subagents.transcript_root
	---@diagnostic disable-next-line: duplicate-set-field
	subagents.transcript_root = function()
		return root
	end
	local ok, err = xpcall(fn, debug.traceback)
	subagents.transcript_root = original
	if not ok then
		error(err, 0)
	end
end

local function append(path, text)
	local file = assert(io.open(path, "ab"))
	file:write(text)
	file:close()
end

return {
	["discovery separates current-session and retained invocations"] = function()
		local root = vim.fn.tempname()
		for _, parent in ipairs({ "current-parent", "old-parent" }) do
			local id = parent == "current-parent" and "current-invocation" or "old-invocation"
			local directory = vim.fs.joinpath(root, parent, id)
			vim.fn.mkdir(directory, "p")
			local value = details(directory, { "completed" })
			value.invocationId = id
			value.parentSessionId = parent
			value.toolCallId = "call-" .. id
			value.agents[1].transcriptPath = vim.fs.joinpath(directory, "child-1.jsonl")
			vim.fn.writefile({ vim.json.encode(value) }, vim.fs.joinpath(directory, "invocation.json"), "b")
		end
		require("pim.state").update({ session_id = "current-parent" })
		with_root(root, function()
			local current = require("pim.subagents.discovery").list(false)
			h.eq(1, #current)
			h.eq("current-invocation", current[1].invocation_id)
			local retained = require("pim.subagents.discovery").list(true)
			h.eq(2, #retained)
		end)
		vim.fn.delete(root, "rf")
	end,

	["compact renderer summarizes valid calls and results"] = function()
		local call = tool.call({
			type = "toolCall",
			name = "subagent",
			arguments = { agents = { { label = "review", prompt = "Review." }, { label = "test", prompt = "Test." } } },
		})
		h.eq({ "▸ tool(subagent): 2 agents" }, call.lines)
		local result = tool.execution({
			toolName = "subagent",
			result = { details = details("/tmp/invocation-123", { "completed", "running" }) },
		})
		h.eq({ "▸ result(subagent): 1 completed, 1 running" }, result.lines)
	end,

	["malformed and unsupported details retain generic rendering"] = function()
		for _, invalid in ipairs({ { schemaVersion = 2 }, { schemaVersion = 1, invocationId = "../bad" } }) do
			local rendered = tool.execution({
				toolName = "subagent",
				result = { content = { { type = "text", text = "fallback" } }, details = invalid },
			})
			h.eq("▸ result(subagent)", rendered.lines[1])
			h.ok(table.concat(rendered.lines, "\n"):find("fallback", 1, true))
		end
	end,

	["live and historical results update the invocation index"] = function()
		local value = details("/tmp/invocation-123", { "running" })
		events.handle({
			type = "tool_execution_update",
			toolCallId = "call-1",
			toolName = "subagent",
			args = { agents = { { label = "review", prompt = "Review." } } },
			partialResult = { details = value },
		})
		h.eq("invocation-123", assert(subagent_state.get_by_tool_call("call-1")).invocation_id)
		value.status = "completed"
		value.agents[1].status = "completed"
		events.handle({
			type = "tool_execution_end",
			toolCallId = "call-1",
			toolName = "subagent",
			result = { details = value },
		})
		h.eq("completed", assert(subagent_state.get("invocation-123")).details.status)

		events.load_messages({
			{
				role = "toolResult",
				toolCallId = "call-old",
				toolName = "subagent",
				details = value,
				content = {},
			},
		})
		h.eq(true, assert(subagent_state.get("invocation-123")).historical)
	end,

	["inspector incrementally reads parallel transcripts and surfaces corrupt records"] = function()
		local root = vim.fn.tempname()
		local directory = vim.fs.joinpath(root, "parent", "invocation-123")
		vim.fn.mkdir(directory, "p")
		local value = details(directory, { "running", "completed" })
		for _, agent in ipairs(value.agents) do
			vim.fn.writefile({}, agent.transcriptPath, "b")
		end
		append(value.agents[1].transcriptPath, vim.json.encode({
			timestamp = "now",
			record = {
				type = "configuration",
				agent = {
					model = "provider/model",
					thinkingLevel = "high",
					tools = { "read" },
					prompt = "Review parser",
				},
			},
		}) .. "\nnot-json\n")
		append(
			value.agents[1].transcriptPath,
			vim.json.encode({
				timestamp = "now",
				record = {
					type = "message_end",
					message = { role = "assistant", content = { { type = "text", text = "partial answer" } } },
				},
			})
		)
		append(value.agents[2].transcriptPath, vim.json.encode({
			timestamp = "now",
			record = { type = "status", status = "completed" },
		}) .. "\n")

		with_root(root, function()
			local invocation = subagent_state.update("call-1", value, nil, false)
			local buf = inspector.open(invocation)
			local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
			h.ok(text:find("## parser review [running]", 1, true))
			h.ok(text:find("## test review [completed]", 1, true))
			h.ok(text:find("1 malformed JSONL record", 1, true))
			h.eq(nil, text:find("partial answer", 1, true), "an incomplete final line is retained")

			append(value.agents[1].transcriptPath, "\n")
			inspector.refresh("invocation-123")
			text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
			h.ok(text:find("partial answer", 1, true), "the completed line is read on refresh")
			h.eq(buf, inspector.open(invocation), "one buffer is reused per invocation")
		end)
		vim.fn.delete(root, "rf")
	end,
}
