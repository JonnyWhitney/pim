-- Optional real-Blink checks. No plugin is downloaded or configured outside the child.
local root = vim.fn.fnamemodify(arg[0], ":p:h:h")
local blink_first = arg[4] == "blink-first"
package.path = root .. "/tests/?.lua;" .. package.path
local h = require("helpers")
local blink_path = assert(arg[1], "usage: nvim -l tests/blink_integration.lua BLINK_PATH [BLINK_LIB_PATH] [lua|rust]")
local child = vim.fn.jobstart({ vim.v.progpath, "--headless", "--clean", "--embed" }, { rpc = true })
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. "/lua/pim", "p")
vim.fn.mkdir(fixture .. "/nested", "p")
for _, path in ipairs({ "lua/pim/completion.lua", "nested/é-file.lua", "nested/punc.file-name.lua" }) do
	vim.fn.writefile({ "fixture" }, fixture .. "/" .. path)
end
---@return any
local function lua(code, ...)
	return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end
local function input(keys)
	vim.rpcrequest(child, "nvim_input", keys)
	-- nvim_input queues keys. Subsequent RPC edits must wait for their events.
	h.settle(20)
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
	h.wait_until(function()
		return lua("return require('blink.cmp').is_menu_visible()")
	end, "visible Blink menu")
	for _, item in ipairs(items()) do
		h.eq("pim", item.source, "only pim is shown in its contexts")
	end
	h.eq(0, lua("return vim.fn.pumvisible()"), "native completion is not opened")
	h.eq(vim.NIL, lua("return require('blink.cmp').get_selected_item_idx()"), "no preselection")
end
local function prompt(text, col)
	input("<Esc>")
	lua(
		[[
		require('blink.cmp').hide()
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { ... })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
	]],
		text
	)
	input("i")
	h.wait_until(function()
		return lua("return vim.api.nvim_get_mode().mode") == "i"
	end, "insert mode")
	lua("vim.api.nvim_win_set_cursor(0, {1, ...}); require('blink.cmp').show()", col or #text)
end
local function accept(label, expected)
	local index = assert(find(label), "missing " .. label)
	lua("require('blink.cmp').accept({index=...})", index)
	h.wait_until(function()
		return lua("return vim.api.nvim_get_current_line()") == expected
	end, "accepted text " .. expected)
end

local ok, err = pcall(function()
	lua(
		[[
		local root, blink_path, lib_path, fixture, implementation, blink_first = ...
		vim.opt.rtp:prepend(root)
		vim.opt.rtp:prepend(blink_path)
		if lib_path and lib_path ~= '' then vim.opt.rtp:prepend(lib_path) end
		vim.cmd.cd(fixture)
		require('pim.config').setup()
		_G.PimTestOmni = function(findstart)
			return findstart == 1 and 0 or { { word = '@competing' } }
		end
		local function open_input()
			require('pim.ui.layout').open()
			vim.bo.omnifunc = 'v:lua.PimTestOmni'
			require('pim.completion').attach()
		end
		if not blink_first then open_input() end
		local sources = require('pim.completion.blink').setup({
			default = { 'omni', 'buffer' },
			per_filetype = { markdown = { inherit_defaults = true }, minifiles = {} },
			providers = { buffer = { opts = { get_bufnrs = function() return { vim.api.nvim_get_current_buf() } end } } },
		})
		require('blink.cmp').setup({
			sources = sources,
			fuzzy = { implementation = implementation, frecency = { enabled = false } },
			completion = {
				keyword = { range = 'full' },
				list = { selection = { preselect = false, auto_insert = false } },
				documentation = { auto_show = true, auto_show_delay_ms = 10 },
				ghost_text = { enabled = true },
			},
		})
		if blink_first then open_input() end
		require('pim.config').setup({ pi_cmd = { vim.v.progpath, '-l', root .. '/tests/fake_pi.lua' } })
		require('pim.rpc.client').start({})
		require('pim.completion').refresh_commands()
	]],
		root,
		blink_path,
		arg[2] or "",
		fixture,
		arg[3] or "lua",
		blink_first
	)

	-- Stable Blink schedules initialization after fuzzy setup.
	h.settle(100)
	-- Automatic trigger, without calling Blink's show API.
	input("i@comp")
	wait_item("@lua/pim/completion.lua")
	h.eq("@comp", lua("return vim.api.nvim_get_current_line()"), "no auto insert")
	accept("@lua/pim/completion.lua", "@lua/pim/completion.lua")

	for _, query in ipairs({ "@lpcomp", "@lua/pim/comp", "@punc.file-n", "@é" }) do
		prompt(query)
		local label = query == "@é" and "@nested/é-file.lua"
			or query == "@punc.file-n" and "@nested/punc.file-name.lua"
			or "@lua/pim/completion.lua"
		wait_item(label)
		accept(label, label)
	end

	prompt("é @comp.lua tail", #"é @comp")
	wait_item("@lua/pim/completion.lua")
	accept("@lua/pim/completion.lua", "é @lua/pim/completion.lua tail")

	prompt("@compx")
	input("<BS>")
	wait_item("@lua/pim/completion.lua")
	accept("@lua/pim/completion.lua", "@lua/pim/completion.lua")

	prompt("comparison @comp")
	wait_item("@lua/pim/completion.lua")
	input(" comp")
	h.wait_until(function()
		local normal = false
		for _, candidate in ipairs(items()) do
			if candidate.source == "pim" then
				return false
			end
			normal = normal or candidate.source == "buffer"
		end
		return normal
	end, "automatic routing after leaving a file reference")

	input("<Esc>")
	lua(
		"require('blink.cmp').hide(); vim.api.nvim_buf_set_lines(0, 0, -1, false, {''}); vim.api.nvim_win_set_cursor(0, {1, 0})"
	)
	input("i/rpc")
	wait_item("/rpc-select")
	input("<C-n>")
	h.wait_until(function()
		return lua("return require('blink.cmp').is_documentation_visible()")
	end, "automatic documentation")
	h.eq("/rpc", lua("return vim.api.nvim_get_current_line()"), "selection does not insert")
	h.ok(lua("return require('blink.cmp').is_ghost_text_visible()"), "configured ghost text is retained")
	h.eq(
		"Demo select dialog",
		lua([[
		for _, item in ipairs(require('blink.cmp').get_items()) do
			if item.label == '/rpc-select' then return item.documentation.value end
		end
	]])
	)
	accept("/rpc-select", "/rpc-select")

	prompt("zzzzzzzzzzzzzzzzzz-other @zzzzzzzzzzzzzzzzzz")
	h.settle(200)
	h.eq({}, items(), "zero matches do not expose other sources")
	h.eq(0, lua("return vim.fn.pumvisible()"))

	-- Ordinary prompt text, Markdown buffers and filetype overrides are retained.
	prompt("ordinary ordinaryword ord")
	h.wait_until(function()
		for _, item in ipairs(items()) do
			if item.source == "buffer" then
				return true
			end
		end
		return false
	end, "normal prompt sources")
	input("<Esc>")
	lua([[
		require('blink.cmp').hide()
		vim.cmd.enew()
		vim.bo.filetype = 'markdown'
	]])
	prompt("comparison @comp")
	h.wait_until(function()
		for _, item in ipairs(items()) do
			if item.source == "buffer" then
				return true
			end
		end
		return false
	end, "ordinary Markdown sources")
	lua("vim.bo.filetype = 'minifiles'")
	prompt("ordinaryword ord")
	h.settle(100)
	h.eq({}, items(), "the empty filetype override is retained")
	io.write("ok   real Blink: triggers, fuzzy matching, ranges, UTF-8, deletion, metadata, routing and selection\n")
end)
if not ok then
	local diagnostic_ok, diagnostic = pcall(
		lua,
		[[return { mode = vim.api.nvim_get_mode().mode, line = vim.api.nvim_get_current_line(), messages = vim.api.nvim_exec2('messages', {output=true}).output, sources = require('blink.cmp.config').sources.default(), items = require('blink.cmp').get_items(), active = require('blink.cmp').is_active(), available = require('pim.completion.blink').new():enabled() }]]
	)
	if diagnostic_ok then
		io.write(vim.inspect(diagnostic) .. "\n")
	end
end
pcall(lua, "require('pim.lifecycle').cleanup()")
pcall(vim.fn.jobstop, child)
vim.fn.delete(fixture, "rf")
if not ok then
	io.write(tostring(err) .. "\n")
	os.exit(1)
end
