local h = require("helpers")

local function check_version(version, enabled)
	require("pim.config").setup({ pi_cmd = vim.v.progpath, subagents = { enabled = enabled } })
	local messages = {}
	local health, system = vim.health, vim.system
	local ok, err = pcall(function()
		vim.health = { start = function() end }
		for _, level in ipairs({ "ok", "error", "warn", "info" }) do
			vim.health[level] = function(message)
				messages[#messages + 1] = { level = level, message = message }
			end
		end
		---@diagnostic disable-next-line: duplicate-set-field
		vim.system = function()
			return {
				wait = function()
					return { code = 0, stdout = version }
				end,
			}
		end
		require("pim.health").check()
	end)
	vim.health, vim.system = health, system
	assert(ok, err)
	return messages
end

return {
	["Pi 0.99.0 is required with or without subagents"] = function()
		for _, enabled in ipairs({ true, false }) do
			for _, case in ipairs({
				{ version = "0.98.9", level = "error" },
				{ version = "0.99.0", level = "ok" },
				{ version = "0.99.1", level = "ok" },
			}) do
				local messages = check_version(case.version, enabled)
				local found
				for _, entry in ipairs(messages) do
					if entry.message:find(case.version, 1, true) and entry.message:find("0.99.0", 1, true) then
						found = entry.level
					end
				end
				h.eq(case.level, found)
			end
		end
	end,
}
