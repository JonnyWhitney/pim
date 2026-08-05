local M = {}

function M.check()
	local health = vim.health

	health.start("pim")

	if vim.fn.has("nvim-0.12") == 1 then
		health.ok("Neovim >= 0.12")
	else
		health.error("pim requires Neovim 0.12 or newer")
	end

	local config = require("pim.config").get()
	local cmd = type(config.pi_cmd) == "table" and config.pi_cmd[1] or config.pi_cmd
	if vim.fn.executable(cmd) == 1 then
		health.ok(("pi binary found: %s"):format(vim.fn.exepath(cmd)))
		local probe = vim.system({ cmd, "--version" }, { text = true }):wait(5000)
		if probe.code == 0 then
			health.ok("pi version: " .. vim.trim(probe.stdout ~= "" and probe.stdout or probe.stderr or "?"))
		else
			health.warn("Cannot get the pi version. `pi --version` failed.")
		end
	else
		health.error(
			("Cannot find or run pi: %s"):format(cmd),
			"Install pi. Or set `pi_cmd` in require('pim').setup()."
		)
	end

	local session_root = require("pim.config").pi_sessions_dir()
	if vim.uv.fs_stat(session_root) then
		health.ok("pi session directory exists: " .. session_root)
	else
		health.info("pi has not created the session directory: " .. session_root)
	end
end

return M
