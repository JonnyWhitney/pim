local content = require("pim.content")

local M = {}

local PREVIEW_WIDTH = 72

-- Older pi versions do not provide this RPC method. These levels keep the picker usable.
local FALLBACK_THINKING_LEVELS = { "off", "minimal", "low", "medium", "high", "xhigh" }

local function mark(is_current)
	return is_current and "● " or "  "
end

local function format_trust_decision(project, entry)
	if not entry then
		return "none"
	end
	local decision = entry.decision and "trusted" or "untrusted"
	if entry.path ~= project then
		return ("%s (inherited from %s)"):format(decision, entry.path)
	end
	return ("%s (%s)"):format(decision, entry.path)
end

local function trust_options(project)
	local trust = require("pim.trust")
	local options = {
		{
			label = "Trust",
			decision = true,
			saved_path = project,
			apply = function()
				trust.trust(project)
			end,
		},
	}
	local parent = trust.parent_path(project)
	if parent then
		options[#options + 1] = {
			label = ("Trust parent folder (%s)"):format(parent),
			decision = true,
			saved_path = parent,
			apply = function()
				trust.trust_parent(project)
			end,
		}
	end
	options[#options + 1] = {
		label = "Do not trust",
		decision = false,
		saved_path = project,
		apply = function()
			trust.reject(project)
		end,
	}
	return options
end

local function format_model(model, is_current)
	local ctx = ""
	if model.contextWindow then
		ctx = (" — %dk ctx"):format(math.floor(model.contextWindow / 1000))
	end
	return ("%s%s (%s)%s"):format(mark(is_current), model.name or model.id, model.provider, ctx)
end

function M.trust()
	local trust = require("pim.trust")
	local ok, project, entry = pcall(function()
		local path = trust.canonical_path()
		return path, trust.get_entry(path)
	end)
	if not ok then
		vim.notify("[pim] Cannot read project trust: " .. tostring(project), vim.log.levels.ERROR)
		return
	end

	local options = trust_options(project)
	vim.ui.select(options, {
		prompt = ("pi trust — %s — saved: %s"):format(project, format_trust_decision(project, entry)),
		format_item = function(option)
			local is_saved = entry ~= nil and entry.path == option.saved_path and entry.decision == option.decision
			return mark(is_saved) .. option.label
		end,
	}, function(choice)
		if not choice then
			return
		end
		local applied, apply_error = pcall(choice.apply)
		if not applied then
			vim.notify("[pim] Cannot update project trust: " .. tostring(apply_error), vim.log.levels.ERROR)
			return
		end
		if require("pim.rpc.client").is_running() then
			vim.notify("[pim] Project trust saved. Run :PiRestart to load it.")
		else
			vim.notify("[pim] Project trust saved.")
		end
	end)
end

function M.model()
	local client = require("pim.rpc.client")
	client.get_available_models(function(success, data)
		if not success then
			vim.notify("[pim] Cannot list models: " .. tostring(data), vim.log.levels.ERROR)
			return
		end
		if type(data) ~= "table" or type(data.models) ~= "table" then
			vim.notify("[pim] pi did not return a model list", vim.log.levels.WARN)
			return
		end
		local models = data.models
		if #models == 0 then
			vim.notify("[pim] pi has no available models", vim.log.levels.WARN)
			return
		end

		local current = require("pim.state").get().model
		vim.ui.select(models, {
			prompt = "pi model",
			format_item = function(model)
				local is_current = current ~= nil and current.id == model.id and current.provider == model.provider
				return format_model(model, is_current)
			end,
		}, function(choice)
			if not choice then
				return
			end
			client.set_model(choice.provider, choice.id, function(ok, payload)
				if ok then
					require("pim.state").update({ model = payload or choice })
				else
					vim.notify("[pim] set_model failed: " .. tostring(payload), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

function M.fork()
	local client = require("pim.rpc.client")

	client.get_fork_messages(function(success, data)
		if not success then
			vim.notify("[pim] Cannot list fork prompts: " .. tostring(data), vim.log.levels.ERROR)
			return
		end
		if type(data) ~= "table" or type(data.messages) ~= "table" then
			vim.notify("[pim] pi did not return fork prompts", vim.log.levels.WARN)
			return
		end
		if #data.messages == 0 then
			vim.notify("[pim] No prompts are available for forking", vim.log.levels.WARN)
			return
		end
		---@cast data PimRpcForkMessagesResponse

		vim.ui.select(data.messages, {
			prompt = "pi fork from prompt",
			format_item = function(message)
				return content.one_line(message.text, PREVIEW_WIDTH)
			end,
		}, function(choice)
			if choice then
				require("pim.sessions").fork(choice.entryId)
			end
		end)
	end)
end

function M.session()
	local sessions = require("pim.sessions").list()
	if #sessions == 0 then
		vim.notify("[pim] No sessions exist for this directory", vim.log.levels.WARN)
		return
	end

	local current_id = require("pim.state").get().session_id
	vim.ui.select(sessions, {
		prompt = "pi sessions",
		format_item = function(session)
			local label = session.name or session.preview or session.id:sub(1, 8)
			local when = os.date("%Y-%m-%d %H:%M", session.mtime)
			return ("%s%s  (%s · %d msgs)"):format(mark(session.id == current_id), label, when, session.message_count)
		end,
	}, function(choice)
		if choice then
			require("pim.sessions").switch(choice.path)
		end
	end)
end

local function subagent_label(invocation)
	local details = invocation.details
	local counts = {}
	for _, agent in ipairs(details.agents) do
		counts[agent.status] = (counts[agent.status] or 0) + 1
	end
	local statuses = {}
	for _, status in ipairs({ "running", "completed", "failed", "stopped", "aborted", "pending" }) do
		if counts[status] then
			statuses[#statuses + 1] = ("%d %s"):format(counts[status], status)
		end
	end
	local labels = {}
	for _, agent in ipairs(details.agents) do
		labels[#labels + 1] = agent.label
	end
	return ("%s — %s — %s"):format(
		table.concat(labels, ", "),
		table.concat(statuses, ", "),
		invocation.invocation_id
	)
end

---@param include_historical boolean|nil
function M.agents(include_historical)
	if not require("pim.config").get().subagents.enabled then
		vim.notify("[pim] Subagents are disabled", vim.log.levels.WARN)
		return
	end
	local invocations, invalid = require("pim.subagents.discovery").list(include_historical == true)
	if invalid > 0 then
		vim.notify(("[pim] Skipped %d invalid subagent manifest(s)"):format(invalid), vim.log.levels.WARN)
	end
	if #invocations == 0 then
		vim.notify("[pim] No subagent invocations are available", vim.log.levels.WARN)
		return
	end
	vim.ui.select(invocations, {
		prompt = include_historical and "subagent invocations (including history)" or "subagent invocations",
		format_item = subagent_label,
	}, function(choice)
		if choice then
			require("pim.subagents.inspector").open(choice)
		end
	end)
end

---@param include_historical boolean|nil
function M.agent_transcript(include_historical)
	M.agents(include_historical)
end

function M.thinking()
	local client = require("pim.rpc.client")
	client.get_available_thinking_levels(function(success, data)
		local levels = FALLBACK_THINKING_LEVELS
		if success and type(data) == "table" and type(data.levels) == "table" and #data.levels > 0 then
			levels = data.levels
		end

		local current = require("pim.state").get().thinking_level
		vim.ui.select(levels, {
			prompt = "thinking level",
			format_item = function(level)
				return mark(level == current) .. level
			end,
		}, function(choice)
			if not choice then
				return
			end
			client.set_thinking_level(choice, function(ok, err)
				if ok then
					require("pim.state").update({ thinking_level = choice })
				else
					vim.notify("[pim] set_thinking_level failed: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

return M
