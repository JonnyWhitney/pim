local h = require("helpers")

local function check_version(version)
	require("pim.config").setup({ pi_cmd = vim.v.progpath })
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
	["Pi 1.5.2 is required"] = function()
		for _, case in ipairs({
			{ version = "0.99.0", level = "error" },
			{ version = "1.5.1", level = "error" },
			{ version = "1.5.2", level = "ok" },
			{ version = "1.5.3", level = "ok" },
		}) do
			local found
			for _, entry in ipairs(check_version(case.version)) do
				if entry.message:find(case.version, 1, true) and entry.message:find("1.5.2", 1, true) then
					found = entry.level
				end
			end
			h.eq(case.level, found)
		end
	end,
	["health retains editor Pi and session checks without feature checks"] = function()
		local messages = check_version("1.5.2")
		local text = table.concat(
			vim.tbl_map(function(entry)
				return entry.message
			end, messages),
			"\n"
		)
		h.ok(text:find("Neovim >= 0.12", 1, true))
		h.ok(text:find("pi binary found:", 1, true))
		h.ok(text:find("pi version: 1.5.2", 1, true))
		h.ok(text:find("session directory", 1, true))
		h.ok(not text:lower():find("subagent", 1, true))
		h.ok(not text:lower():find("bundl", 1, true))
		h.ok(not text:lower():find("transcript", 1, true))
	end,
}
