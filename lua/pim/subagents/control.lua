local M = {}
local pending = {}
local sequence = 0

local function take(token)
	local entry = pending[token]
	pending[token] = nil
	if entry and entry.timer and not entry.timer:is_closing() then
		entry.timer:stop()
		entry.timer:close()
	end
	return entry
end

function M.reset()
	for token in pairs(pending) do
		take(token)
	end
end

function M.acknowledge(request)
	if request.method ~= "setStatus" or request.statusKey ~= "pim-agent-stop" then
		return false
	end
	local ok, ack = pcall(vim.json.decode, request.statusText or "")
	if not ok or type(ack) ~= "table" or type(ack.token) ~= "string" then
		return true
	end
	local entry = take(ack.token)
	if not entry or entry.session ~= require("pim.state").get().session_id then
		return true
	end
	if type(ack.labels) ~= "table" or #ack.labels == 0 then
		vim.notify("[pim] No active children were stopped")
		return true
	end
	local labels = {}
	for _, label in ipairs(ack.labels) do
		if type(label) ~= "string" then
			return true
		end
		labels[#labels + 1] = vim.json.encode(label)
	end
	local text = "The user stopped "
		.. (#labels == 1 and "subagent " or "subagents ")
		.. table.concat(labels, ", ")
		.. ". Reassess the task and continue without relying on "
		.. (#labels == 1 and "its" or "their")
		.. " completion."
	require("pim.rpc.client").request("steer", { message = text }, function(success, err)
		if not success then
			vim.notify("[pim] Stop steering failed: " .. tostring(err), vim.log.levels.ERROR)
		end
	end)
	return true
end

function M.request(invocation, child_id)
	local client = require("pim.rpc.client")
	sequence = sequence + 1
	local token = ("%.0f-%d"):format(vim.uv.hrtime(), sequence)
	local entry = { session = require("pim.state").get().session_id }
	pending[token] = entry
	entry.timer = vim.defer_fn(function()
		if take(token) then
			vim.notify("[pim] Stop acknowledgement was not received", vim.log.levels.WARN)
		end
	end, 30000)
	client.prompt(
		"/pim-internal-agent-stop " .. token .. " " .. invocation.invocation_id .. " " .. child_id,
		nil,
		function(success, err)
			if not success and take(token) then
				vim.notify("[pim] Stop request failed: " .. tostring(err), vim.log.levels.ERROR)
			end
		end
	)
end

function M.stop(all)
	if not require("pim.config").get().subagents.enabled then
		vim.notify("[pim] Subagents are disabled", vim.log.levels.WARN)
		return
	end
	local choices = {}
	for _, invocation in ipairs(require("pim.subagents.state").list()) do
		if not invocation.historical then
			for _, child in ipairs(invocation.details.agents) do
				if child.status == "running" or child.status == "pending" then
					choices[#choices + 1] = {
						invocation = invocation,
						id = all and "*" or child.id,
						label = all and invocation.invocation_id or child.label,
					}
					if all then
						break
					end
				end
			end
		end
	end
	if #choices == 0 then
		vim.notify("[pim] No active subagents are available")
		return
	end
	vim.ui.select(choices, {
		prompt = "Stop subagents",
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if choice then
			M.request(choice.invocation, choice.id)
		end
	end)
end

return M
