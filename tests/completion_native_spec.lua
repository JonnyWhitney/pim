local h = require("helpers")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

return {
	["input lifecycle leaves completion untouched without Blink"] = function()
		local child = vim.fn.jobstart({ vim.v.progpath, "--headless", "--clean", "--embed" }, { rpc = true })
		---@return any
		local function lua(code, ...)
			return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
		end
		local function input(keys)
			vim.rpcrequest(child, "nvim_input", keys)
			h.settle(50)
		end
		local ok, err = pcall(function()
			lua(
				[[
				local root = ...
				vim.opt.rtp:prepend(root)
				require('pim.config').setup({pi_cmd={vim.v.progpath, '-l', root .. '/tests/fake_pi.lua'}})
				vim.api.nvim_create_autocmd('BufWinEnter', {callback=function(event)
					if vim.b[event.buf].pim_role == 'input' then
						vim.bo[event.buf].omnifunc = 'UserOmni'
						vim.bo[event.buf].completeopt = 'menu,longest'
						vim.keymap.set('i', '/', '/', {buffer=event.buf})
						vim.keymap.set('i', '@', '@', {buffer=event.buf})
					end
				end})
				require('pim').start()
			]],
				root
			)
			for _, action in ipairs({ "initial", "hide-show", "restart", "stop-start" }) do
				input("<Esc>")
				if action == "hide-show" then
					lua("require('pim.ui.layout').hide(); require('pim').start()")
				elseif action == "restart" then
					lua("require('pim').restart()")
				elseif action == "stop-start" then
					lua("require('pim.lifecycle').cleanup(); require('pim').start()")
				end
				h.wait_until(function()
					return lua("return #require('pim.completion.data').command_candidates()") > 0
				end, "metadata " .. action)
				h.eq(
					{ "UserOmni", "menu,longest", "/", "@" },
					lua([[
					return {vim.bo.omnifunc, vim.bo.completeopt, vim.fn.maparg('/', 'i'), vim.fn.maparg('@', 'i')}
				]]),
					action
				)
				lua([[
					vim.api.nvim_buf_set_lines(0, 0, -1, false, {''})
					vim.api.nvim_win_set_cursor(0, {1, 0})
					_G.pim_test_calls = {}
					_G.pim_test_system = vim.system
					_G.pim_test_opendir = vim.uv.fs_opendir
					vim.system = function(...) table.insert(pim_test_calls, 'process'); return pim_test_system(...) end
					vim.uv.fs_opendir = function(...) table.insert(pim_test_calls, 'scan'); return pim_test_opendir(...) end
				]])
				input("i/rpc @~/ @./ @../ @config")
				h.eq(0, lua("return vim.fn.pumvisible()"))
				h.eq("/rpc @~/ @./ @../ @config", lua("return vim.api.nvim_get_current_line()"))
				h.eq({}, lua("return pim_test_calls"), "typing does not discover files")
				lua("vim.system = pim_test_system; vim.uv.fs_opendir = pim_test_opendir")
			end
			h.eq(false, lua("return package.loaded['blink.cmp'] ~= nil"))
			h.eq(false, lua("return package.loaded['pim.completion.blink'] ~= nil"))
		end)
		pcall(lua, "require('pim.lifecycle').cleanup()")
		pcall(vim.fn.jobstop, child)
		if not ok then
			error(err, 0)
		end
	end,
}
