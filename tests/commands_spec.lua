local h = require("helpers")

local function load_plugin()
	if vim.api.nvim_get_commands({})["PiStart"] then
		return
	end
	vim.g.loaded_pim = nil
	dofile(vim.fs.joinpath(vim.fn.getcwd(), "plugin", "pim.lua"))
end

return {
	["subagent stop and cleanup commands pass their bang flags"] = function()
		load_plugin()
		local control = require("pim.subagents.control")
		local cleanup = require("pim.subagents.cleanup")
		local stop, clean = control.stop, cleanup.clean
		local calls = {}
		---@diagnostic disable-next-line: duplicate-set-field
		control.stop = function(all)
			calls[#calls + 1] = { "stop", all }
		end
		---@diagnostic disable-next-line: duplicate-set-field
		cleanup.clean = function(force)
			calls[#calls + 1] = { "clean", force }
		end
		vim.cmd("PiAgentStop")
		vim.cmd("PiAgentStop!")
		vim.cmd("PiAgentClean")
		vim.cmd("PiAgentClean!")
		control.stop, cleanup.clean = stop, clean
		h.eq({ { "stop", false }, { "stop", true }, { "clean", false }, { "clean", true } }, calls)
	end,
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
