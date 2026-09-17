local h = require("helpers")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

return {
	["automatic native popups remain available without Blink"] = function()
		local child = vim.fn.jobstart({ vim.v.progpath, "--headless", "--clean", "--embed" }, { rpc = true })
		---@return any
		local function lua(code, ...)
			return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
		end
		local function input(keys)
			vim.rpcrequest(child, "nvim_input", keys)
		end
		local ok, err = pcall(function()
			lua(
				[[
				local root = ...
				vim.opt.rtp:prepend(root)
				vim.cmd.cd(root)
				require('pim.config').setup({ pi_cmd = { vim.v.progpath, '-l', root .. '/tests/fake_pi.lua' } })
				require('pim.ui.layout').open()
				require('pim.completion').attach()
				require('pim.rpc.client').start({})
				require('pim.completion').refresh_commands()
			]],
				root
			)
			h.wait_until(function()
				return lua("return #require('pim.completion.data').command_candidates()") > 0
			end, "command metadata")
			for _, key in ipairs({ "/", "@" }) do
				input("i" .. key)
				h.wait_until(function()
					return lua("return vim.fn.pumvisible()") == 1
				end, "automatic " .. key .. " popup")
				h.ok(lua("return #vim.fn.complete_info().items") > 0)
				input("<C-e><Esc>")
				lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, {''}); vim.api.nvim_win_set_cursor(0, {1, 0})")
			end
			h.eq(false, lua("return package.loaded['blink.cmp'] ~= nil"))
		end)
		pcall(lua, "require('pim.lifecycle').cleanup()")
		pcall(vim.fn.jobstop, child)
		if not ok then
			error(err, 0)
		end
	end,
}
