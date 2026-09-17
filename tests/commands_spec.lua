local h = require("helpers")

local function load_plugin()
	if vim.api.nvim_get_commands({})["PiStart"] then
		return
	end
	vim.g.loaded_pim = nil
	dofile(vim.fs.joinpath(vim.fn.getcwd(), "plugin", "pim.lua"))
end

return {
	["subagent commands pass their history scope to the picker"] = function()
		load_plugin()

		local pickers = require("pim.ui.pickers")
		local original_agents = pickers.agents
		local original_transcript = pickers.agent_transcript
		local calls = {}
		---@diagnostic disable-next-line: duplicate-set-field
		pickers.agents = function(historical)
			calls[#calls + 1] = { "agents", historical }
		end
		---@diagnostic disable-next-line: duplicate-set-field
		pickers.agent_transcript = function(historical)
			calls[#calls + 1] = { "transcript", historical }
		end
		vim.cmd("PiAgents")
		vim.cmd("PiAgents!")
		vim.cmd("PiAgentTranscript")
		pickers.agents = original_agents
		pickers.agent_transcript = original_transcript

		h.eq({ { "agents", false }, { "agents", true }, { "transcript", false } }, calls)
	end,

	["PiTrust opens the project trust picker"] = function()
		load_plugin()

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
