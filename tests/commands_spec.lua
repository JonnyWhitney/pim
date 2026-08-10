local h = require("helpers")

return {
	["PiTrust opens the project trust picker"] = function()
		vim.g.loaded_pim = nil
		dofile(vim.fs.joinpath(vim.fn.getcwd(), "plugin", "pim.lua"))

		local pickers = require("pim.ui.pickers")
		local original_trust = pickers.trust
		local called = false
		---@diagnostic disable-next-line: duplicate-set-field
		pickers.trust = function()
			called = true
		end
		vim.cmd("PiTrust")
		pickers.trust = original_trust

		h.eq(true, called)
		local command = vim.api.nvim_get_commands({})["PiTrust"]
		h.eq("Manage trust for the current project", command.desc)
	end,
}
