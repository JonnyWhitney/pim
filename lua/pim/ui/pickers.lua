local M = {}

-- Older pi versions do not provide this RPC method. These levels keep the picker usable.
local FALLBACK_THINKING_LEVELS = { "off", "minimal", "low", "medium", "high", "xhigh" }

local function mark(is_current)
	return is_current and "● " or "  "
end

local function format_model(model, is_current)
	local ctx = ""
	if model.contextWindow then
		ctx = (" — %dk ctx"):format(math.floor(model.contextWindow / 1000))
	end
	return ("%s%s (%s)%s"):format(mark(is_current), model.name or model.id, model.provider, ctx)
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
		if not choice then
			return
		end
		require("pim.rpc.client").switch_session(choice.path, function(ok, data)
			if not ok then
				vim.notify("[pim] switch_session failed: " .. tostring(data), vim.log.levels.ERROR)
			elseif type(data) == "table" and data.cancelled then
				vim.notify("[pim] An extension cancelled the session switch", vim.log.levels.WARN)
			else
				require("pim").refresh()
			end
		end)
	end)
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
