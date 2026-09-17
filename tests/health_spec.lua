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
	["Pi 0.85.1 is required even with subagents disabled"] = function()
		for _, enabled in ipairs({ true, false }) do
			for _, version in ipairs({ "0.84.4", "0.85.0", "0.85.1", "0.86.0" }) do
				local messages = check_version(version, enabled)
				local found
				for _, entry in ipairs(messages) do
					if entry.message:find(version, 1, true) and entry.message:find("0.85.1", 1, true) then
						found = entry.level
					end
				end
				h.eq((version == "0.84.4" or version == "0.85.0") and "error" or "ok", found)
			end
		end
	end,
}
