local h = require("helpers")
local client = require("pim.rpc.client")
local data = require("pim.completion.data")
local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function with_requests(fn)
	local running, get_commands = client.is_running, client.get_commands
	local requests = {}
	---@diagnostic disable-next-line: duplicate-set-field
	client.is_running = function()
		return true
	end
	---@diagnostic disable-next-line: duplicate-set-field
	client.get_commands = function(callback)
		requests[#requests + 1] = callback
	end
	local ok, err = pcall(fn, requests)
	client.is_running, client.get_commands = running, get_commands
	if not ok then
		error(err, 0)
	end
end

return {
	["RPC metadata is refreshed without a completion frontend"] = function()
		h.eq({}, data.command_candidates())
		data.refresh_commands()
		h.eq({}, data.command_candidates())
		require("pim.config").setup({ pi_cmd = { vim.v.progpath, "-l", tests_dir .. "/fake_pi.lua" } })
		require("pim").start()
		h.wait_until(function()
			return #data.command_candidates() == 3
		end, "command metadata")
		local commands = data.command_candidates()
		local by_name = {}
		for _, command in ipairs(commands) do
			by_name[command.name] = command
		end
		h.eq("extension", by_name["rpc-select"].source)
		h.eq("Demo select dialog", by_name["rpc-select"].description)
		h.eq("skill", by_name["legacy-cmd"].source)
		commands[1].name = "mutated"
		h.ok(data.command_candidates()[1].name ~= "mutated")
		client.stop()
		h.eq({}, data.command_candidates(), "process exit clears metadata")
		require("pim.lifecycle").cleanup()
		h.eq({}, data.command_candidates())
		require("pim").start()
		h.wait_until(function()
			return #data.command_candidates() == 3
		end, "restarted metadata")
	end,

	["late responses cannot restore reset or superseded commands"] = function()
		with_requests(function(requests)
			data.refresh_commands()
			data.reset()
			requests[1](true, { commands = { { name = "stale" } } })
			h.eq({}, data.command_candidates())
			data.refresh_commands()
			data.refresh_commands()
			requests[3](true, { commands = { { name = "current" } } })
			requests[2](true, { commands = { { name = "old-session" } } })
			h.eq({ { name = "current", source = "" } }, data.command_candidates())
		end)
	end,

	["empty failed and malformed metadata are safe"] = function()
		with_requests(function(requests)
			data.refresh_commands()
			requests[#requests](true, {
				commands = {
					{ name = "extension", source = "extension", description = "Description" },
					{ name = "template", source = "prompt" },
					{ name = "skill:test", sourceInfo = { source = "skill" } },
					false,
					{},
					{ name = 3 },
					{ name = "" },
				},
			})
			h.eq(3, #data.command_candidates())
			for _, response in ipairs({ {}, { commands = false }, { commands = {} }, { commands = "invalid" } }) do
				data.refresh_commands()
				h.eq({}, data.command_candidates(), "old session metadata is cleared before refresh")
				requests[#requests](true, response)
				h.eq({}, data.command_candidates())
			end
			data.refresh_commands()
			requests[#requests](false, "unavailable")
			h.eq({}, data.command_candidates())
		end)
	end,
}
