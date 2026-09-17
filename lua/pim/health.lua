local M = {}

local function parse_version(text)
	local major, minor, patch = text:match("(%d+)%.(%d+)%.(%d+)")
	if not major then
		return nil
	end
	return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function version_at_least(version, minimum)
	for index = 1, 3 do
		if version[index] ~= minimum[index] then
			return version[index] > minimum[index]
		end
	end
	return true
end

function M.check()
	local health = vim.health

	health.start("pim")

	if vim.fn.has("nvim-0.12") == 1 then
		health.ok("Neovim >= 0.12")
	else
		health.error("pim requires Neovim 0.12 or newer")
	end

	local config = require("pim.config").get()
	local MINIMUM_PI_VERSION = { 0, 85, 1 }
	local MINIMUM_PI_VERSION_TEXT = table.concat(MINIMUM_PI_VERSION, ".")
	local command = type(config.pi_cmd) == "table" and vim.deepcopy(config.pi_cmd) or { config.pi_cmd }
	local executable = command[1]
	if vim.fn.executable(executable) == 1 then
		health.ok(("pi binary found: %s"):format(vim.fn.exepath(executable)))
		command[#command + 1] = "--version"
		local probe = vim.system(command, { text = true }):wait(5000)
		if probe.code == 0 then
			local output = vim.trim((probe.stdout and probe.stdout ~= "") and probe.stdout or probe.stderr or "?")
			local version = parse_version(output)
			if not version then
				health.warn(
					("Cannot parse pi version %q. pim requires pi %s or newer."):format(output, MINIMUM_PI_VERSION_TEXT)
				)
			elseif version_at_least(version, MINIMUM_PI_VERSION) then
				health.ok(("pi version: %s (required: %s or newer)"):format(output, MINIMUM_PI_VERSION_TEXT))
			else
				health.error(("pi %s is too old. pim requires pi %s or newer."):format(output, MINIMUM_PI_VERSION_TEXT))
			end
		else
			health.warn(("Cannot get the pi version. pim requires pi %s or newer."):format(MINIMUM_PI_VERSION_TEXT))
		end
	else
		health.error(
			("Cannot find or run pi: %s"):format(executable),
			"Install pi. Or set `pi_cmd` in require('pim').setup()."
		)
	end

	require("pim.subagents").check(health)

	local session_root = require("pim.config").pi_sessions_dir()
	if vim.uv.fs_stat(session_root) then
		health.ok("pi session directory exists: " .. session_root)
	else
		health.info("pi has not created the session directory: " .. session_root)
	end
end

return M
