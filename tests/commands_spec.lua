local h = require("helpers")

local function load_plugin()
	if vim.api.nvim_get_commands({})["PiStart"] then
		return
	end
	vim.g.loaded_pim = nil
	dofile(vim.fs.joinpath(vim.fn.getcwd(), "plugin", "pim.lua"))
end

return {
	["all remaining commands are registered"] = function()
		load_plugin()
		local commands = vim.api.nvim_get_commands({})
		for _, name in ipairs({
			"PiStart",
			"PiStop",
			"PiRestart",
			"PiToggle",
			"PiAbort",
			"PiSend",
			"PiResume",
			"PiTree",
			"PiTrust",
			"PiNewSession",
			"PiFork",
			"PiClone",
			"PiModel",
			"PiThinking",
			"PiLog",
		}) do
			h.ok(commands[name], name .. " must be registered")
		end
	end,
	["bundled subagent commands are not registered"] = function()
		load_plugin()
		local commands = vim.api.nvim_get_commands({})
		for _, name in ipairs({ "PiAgents", "PiAgentTranscript", "PiAgentStop", "PiAgentClean" }) do
			h.eq(nil, commands[name], name .. " must be absent")
		end
	end,
	["PiTrust opens the project trust picker"] = function()
		load_plugin()
		h.with_cleanup(function(defer)
			local pickers = require("pim.ui.pickers")
			local called = false
			h.patch(defer, pickers, "trust", function()
				called = true
			end)
			vim.cmd("PiTrust")
			h.eq(true, called)
			h.eq("Manage trust for the current project", vim.api.nvim_get_commands({})["PiTrust"].desc)
		end)
	end,
}
