-- Real Blink is loaded only in a clean child. No dependency is downloaded.
local root = vim.fn.fnamemodify(arg[0], ":p:h:h")
package.path = root .. "/tests/?.lua;" .. package.path
local h = require("helpers")
local blink_path =
	assert(arg[1], "usage: nvim -l tests/blink_integration.lua BLINK_PATH [BLINK_LIB_PATH] [lua|rust] [blink-first]")
local child = vim.fn.jobstart({ vim.v.progpath, "--headless", "--clean", "--embed" }, { rpc = true })
---@return any
local function lua(code, ...)
	return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end
local function input(keys)
	vim.rpcrequest(child, "nvim_input", keys)
	h.settle(30)
end
local function items()
	return lua(
		[[return vim.tbl_map(function(item) return {label=item.label, source=item.source_id} end, require('blink.cmp').get_items())]]
	)
end
local function find(label)
	for i, item in ipairs(items()) do
		if item.label == label then
			return i
		end
	end
end
local function wait_item(label)
	h.wait_until(function()
		return find(label) ~= nil
	end, label, 8000)
	h.eq(0, lua("return vim.fn.pumvisible()"), "native popup is not opened")
end
local function no_pim()
	h.settle(200)
	for _, item in ipairs(items()) do
		h.ok(item.source ~= "pim", "no Pim item: " .. item.label)
	end
end
local function prompt(text, col, row)
	input("<Esc>")
	lua(
		[[
		local text = ...
		require('blink.cmp').hide()
		vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, '\n'))
		vim.api.nvim_win_set_cursor(0, {1, 0})
	]],
		text
	)
	input("i")
	lua(
		"local row, col = ...; vim.api.nvim_win_set_cursor(0, {row, col}); require('blink.cmp').show()",
		row or 1,
		col or #text
	)
end
local function accept(label, expected)
	lua("require('blink.cmp').accept({index=...})", assert(find(label)))
	h.wait_until(function()
		return lua("return vim.api.nvim_get_current_line()") == expected
	end, expected)
end

local ok, err = pcall(function()
	lua(
		[[
		local root, blink_path, lib_path, implementation, blink_first = ...
		vim.opt.rtp:prepend(root)
		vim.opt.rtp:prepend(blink_path)
		if lib_path ~= '' then vim.opt.rtp:prepend(lib_path) end
		require('pim.config').setup()
		local function open_input()
			require('pim.ui.layout').open()
		end
		if not blink_first then open_input() end
		package.preload['pim_test_source'] = function()
			return { new = function()
				return {
					get_trigger_characters = function() return {'/', '@'} end,
					get_completions = function(_, _, callback)
						callback({ items = { {label='/rpc-other'}, {label='/zzzz-no-match'}, {label='@~/' } },
							is_incomplete_forward=true, is_incomplete_backward=true })
					end,
				}
			end }
		end
		require('blink.cmp').setup({
			sources = {
				default = {'pim', 'other', 'buffer'},
				providers = {
					pim = {name='pim', module='pim.completion.blink'},
					other = {name='other', module='pim_test_source'},
				},
				per_filetype = { minifiles = {} },
			},
			fuzzy = {implementation=implementation, frecency={enabled=false}},
			completion = {
				keyword = {range='full'},
				list = {selection={preselect=false, auto_insert=false}},
				documentation = {auto_show=true, auto_show_delay_ms=10},
				ghost_text = {enabled=true},
			},
		})
		if blink_first then open_input() end
		_G.pim_test_root = root
	]],
		root,
		blink_path,
		arg[2] or "",
		arg[3] or "lua",
		arg[4] == "blink-first"
	)
	h.settle(100)
	prompt("/rpc")
	wait_item("/rpc-other")
	no_pim()
	lua([[
		require('pim.config').setup({pi_cmd={vim.v.progpath, '-l', pim_test_root .. '/tests/fake_pi.lua'}})
		require('pim.rpc.client').start({})
		require('pim.completion.data').refresh_commands()
	]])
	h.wait_until(function()
		return lua("return #require('pim.completion.data').command_candidates()") > 0
	end, "command metadata")
	prompt("")
	input("/rpc")
	wait_item("/rpc-select")
	wait_item("/rpc-other")
	h.eq(vim.NIL, lua("return require('blink.cmp').get_selected_item_idx()"))
	h.eq("/rpc", lua("return vim.api.nvim_get_current_line()"))
	h.eq(
		"Demo select dialog",
		lua([[
		for _, item in ipairs(require('blink.cmp').get_items()) do
			if item.label == '/rpc-select' then return item.documentation.value end
		end
	]])
	)
	accept("/rpc-select", "/rpc-select")
	prompt("/")
	wait_item("/rpc-select")
	wait_item("/rpc-other")
	prompt("/zzzz-no-match")
	wait_item("/zzzz-no-match")
	no_pim()
	prompt("/rpc-select é tail", 4)
	wait_item("/rpc-select")
	accept("/rpc-select", "/rpc-select é tail")
	lua("require('blink.cmp.config').completion.keyword.range = 'prefix'")
	prompt("/rpc-select é tail", 4)
	wait_item("/rpc-select")
	accept("/rpc-select", "/rpc-select-select é tail")
	lua("require('blink.cmp.config').completion.keyword.range = 'full'")
	prompt("/rpcx")
	input("<BS>")
	wait_item("/rpc-select")
	input(" argument")
	no_pim()
	for _, text in ipairs({ " /rpc", "text /rpc", "/rpc argument", "@", "@~/", "`@~/" }) do
		prompt(text)
		no_pim()
	end
	prompt("text\n/rpc", 4, 2)
	no_pim()
	input("<Esc>")
	lua("require('pim.ui.layout').hide(); require('pim.ui.layout').open()")
	prompt("/rpc")
	wait_item("/rpc-select")
	input("<Esc>")
	lua([[
		require('pim.lifecycle').cleanup()
		require('pim').start()
	]])
	h.wait_until(function()
		return lua("return #require('pim.completion.data').command_candidates()") > 0
	end, "restart metadata")
	prompt("/rpc")
	wait_item("/rpc-select")
	input("<Esc>")
	input(":/rpc")
	h.eq(false, lua("return require('pim.completion.blink').new():enabled()"))
	input("<Esc>")
	lua([[
		require('blink.cmp').hide()
		vim.api.nvim_win_set_buf(0, require('pim.ui.layout').transcript_buf())
		vim.bo.modifiable = true
	]])
	prompt("/rpc")
	no_pim()
	input("<Esc>")
	lua("vim.cmd.enew(); vim.bo.filetype = 'markdown'")
	prompt("/rpc")
	wait_item("/rpc-other")
	no_pim()
	lua("vim.bo.filetype = 'minifiles'")
	prompt("/rpc")
	h.settle(200)
	h.eq({}, items(), "empty filetype override is retained")
	io.write(
		"ok   real Blink: command contexts, coexistence, no matches, edits, metadata, lifecycle and native non-interference\n"
	)
end)
if not ok then
	local success, diagnostic = pcall(
		lua,
		[[return {mode=vim.api.nvim_get_mode().mode, line=vim.api.nvim_get_current_line(), messages=vim.api.nvim_exec2('messages', {output=true}).output, items=require('blink.cmp').get_items()}]]
	)
	if success then
		io.write(vim.inspect(diagnostic) .. "\n")
	end
end
pcall(lua, "require('pim.lifecycle').cleanup()")
pcall(vim.fn.jobstop, child)
if not ok then
	io.write(tostring(err) .. "\n")
	os.exit(1)
end
