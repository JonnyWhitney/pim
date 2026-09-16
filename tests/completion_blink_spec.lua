local h = require("helpers")
local blink = require("pim.completion.blink")
local backend = require("pim.completion.backend")
local completion = require("pim.completion")
local data = require("pim.completion.data")
local layout = require("pim.ui.layout")

local function with_input(fn)
	local virtualedit = vim.o.virtualedit
	vim.o.virtualedit = "onemore"
	backend.set_blink_enabled(false)
	layout.open()
	local ok, err = pcall(fn, layout.input_buf())
	completion.reset()
	backend.set_blink_enabled(false)
	layout.destroy()
	vim.o.virtualedit = virtualedit
	if not ok then
		error(err, 0)
	end
end

local function prompt(text, col)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
	vim.api.nvim_win_set_cursor(0, { 1, col or #text })
	return { bufnr = vim.api.nvim_get_current_buf(), cursor = { 1, col or #text }, line = text, mode = "default" }
end

local function configure()
	return blink.setup({ default = { "lsp", "omni", "buffer" } })
end

return {
	["explicit setup owns only valid input contexts including empty results"] = function()
		with_input(function(buf)
			local source = blink.new()
			prompt("@comp")
			h.eq(false, source:enabled(), "module loading is not activation")
			local calls = 0
			local original = {
				default = function()
					calls = calls + 1
					return { "omni", "buffer" }
				end,
				per_filetype = {
					markdown = { "path", inherit_defaults = true },
					minifiles = { inherit_defaults = false },
					lua = function()
						return { "lsp" }
					end,
				},
				providers = { omni = {
					enabled = function()
						return true
					end,
				} },
			}
			local opts = blink.setup(original)
			h.eq({ "pim" }, opts.default())
			h.eq({}, opts.per_filetype, "filetype routing is composed into the default selector")
			h.eq(0, calls)
			h.ok(source:enabled())
			h.eq({ "@", "/" }, source:get_trigger_characters())
			h.eq({}, opts.providers.pim.fallbacks)
			h.eq(nil, original.providers.pim, "the supplied configuration is not mutated")
			prompt("@zzzz-no-match")
			h.eq({ "pim" }, opts.default())
			for _, text in ipairs({ "ordinary text", "mail a@b.com", "/command argument", "hello /cmd" }) do
				prompt(text)
				h.eq(false, source:enabled())
				h.eq({ "path", "omni", "buffer" }, opts.default())
				vim.bo[buf].filetype = "minifiles"
				h.eq({}, opts.default())
				vim.bo[buf].filetype = "lua"
				h.eq({ "lsp" }, opts.default())
				vim.bo[buf].filetype = "markdown"
			end
			local ordinary = vim.api.nvim_create_buf(false, true)
			vim.bo[ordinary].filetype = "markdown"
			vim.api.nvim_win_set_buf(0, ordinary)
			prompt("@comp")
			h.eq(false, source:enabled())
			h.eq({ "path", "omni", "buffer" }, opts.default())
			local transcript = assert(layout.transcript_buf())
			vim.bo[transcript].modifiable = true
			vim.api.nvim_buf_set_lines(transcript, 0, -1, false, { "@comp" })
			vim.bo[transcript].modifiable = false
			vim.api.nvim_win_set_buf(0, transcript)
			vim.api.nvim_win_set_cursor(0, { 1, 5 })
			h.eq(false, source:enabled(), "the pim transcript is not an input context")
			h.eq({ "path", "omni", "buffer" }, opts.default())
			vim.api.nvim_win_set_buf(0, buf)
			vim.api.nvim_buf_delete(ordinary, { force = true })
		end)
	end,

	["native ownership is restored safely when Blink is loaded later"] = function()
		with_input(function(buf)
			vim.bo[buf].completeopt = "menu,menuone"
			vim.bo[buf].omnifunc = "OriginalOmni"
			vim.keymap.set("i", "/", "original", { buffer = buf })
			completion.attach()
			completion.attach()
			prompt("")
			h.eq("/<C-x><C-o>", vim.fn.maparg("/", "i", false, true).callback())
			h.eq("@<C-x><C-o>", vim.fn.maparg("@", "i", false, true).callback())
			configure()
			h.eq("original", vim.fn.maparg("/", "i", false, true).rhs)
			h.eq("", vim.fn.maparg("@", "i"))
			h.eq("menu,menuone", vim.bo[buf].completeopt)
			h.eq("OriginalOmni", vim.bo[buf].omnifunc)
			completion.attach()
			h.eq("OriginalOmni", vim.bo[buf].omnifunc)
		end)
	end,

	["user changes after native attachment are not overwritten"] = function()
		with_input(function(buf)
			completion.attach()
			vim.keymap.set("i", "@", "user", { buffer = buf })
			vim.bo[buf].completeopt = "menu"
			vim.bo[buf].omnifunc = "UserOmni"
			configure()
			h.eq("user", vim.fn.maparg("@", "i"))
			h.eq("menu", vim.bo[buf].completeopt)
			h.eq("UserOmni", vim.bo[buf].omnifunc)
		end)
	end,

	["Blink-first attachment survives hide show and process resets"] = function()
		with_input(function(buf)
			configure()
			local options = { vim.bo[buf].completeopt, vim.bo[buf].omnifunc }
			completion.attach()
			completion.attach()
			h.eq(options, { vim.bo[buf].completeopt, vim.bo[buf].omnifunc })
			h.eq("", vim.fn.maparg("@", "i"))
			prompt("@comp")
			layout.hide()
			h.eq(false, blink.new():enabled())
			layout.open()
			completion.attach()
			h.ok(blink.new():enabled())
			require("pim.lifecycle").cleanup()
			layout.open()
			completion.attach()
			prompt("@comp")
			h.ok(blink.new():enabled())
			h.eq("", vim.fn.maparg("@", "i"))
		end)
	end,

	["source items preserve metadata and use fresh byte ranges"] = function()
		with_input(function()
			configure()
			local original = data.command_candidates
			---@diagnostic disable-next-line: duplicate-set-field
			data.command_candidates = function()
				return { { name = "rpc-select", source = "extension", description = "Demo select dialog" } }
			end
			local ok, err = pcall(function()
				local source = blink.new()
				local ctx = prompt("/rpc-select", 4)
				local result
				source:get_completions(ctx, function(value)
					result = value
				end)
				local item = result.items[1]
				h.eq("/rpc-select", item.label)
				h.eq("extension", item.labelDetails.description)
				h.eq("extension", item.client_name)
				h.eq("Demo select dialog", item.documentation.value)
				h.eq(0, item.textEdit.insert.start.character)
				h.eq(4, item.textEdit.insert["end"].character)
				h.eq(11, item.textEdit.replace["end"].character)
				item.textEdit.newText = "mutated"
				source:get_completions(ctx, function(value)
					result = value
				end)
				h.eq("/rpc-select", result.items[1].textEdit.newText)
				h.ok(result.is_incomplete_backward)
				h.ok(result.is_incomplete_forward)
			end)
			data.command_candidates = original
			if not ok then
				error(err, 0)
			end
		end)
	end,

	["file requests reject stale contexts and propagate cancellation"] = function()
		with_input(function()
			configure()
			local original = data.request_files
			local respond, current, cancelled
			---@diagnostic disable-next-line: duplicate-set-field
			data.request_files = function(_, callback, is_current)
				respond, current = callback, is_current
				return function()
					cancelled = true
				end
			end
			local ok, err = pcall(function()
				local source = blink.new()
				local ctx = prompt("é @comp.lua tail", #"é @comp")
				local result
				local cancel = source:get_completions(ctx, function(value)
					result = value
				end)
				h.ok(current())
				respond({ "lua/pim/completion.lua", "nested/é-file.lua" })
				h.eq(2, #result.items, "the source does not prefix filter")
				local edit = result.items[1].textEdit
				h.eq(#"é ", edit.insert.start.character)
				h.eq(#"é @comp.lua", edit.replace["end"].character)
				h.eq("@lua/pim/completion.lua", edit.newText)
				prompt("é @com")
				h.eq(false, current())
				cancel()
				h.ok(cancelled)
				local invalid = prompt("email@address")
				source:get_completions(invalid, function(value)
					result = value
				end)
				h.eq({}, result.items)
			end)
			data.request_files = original
			if not ok then
				error(err, 0)
			end
		end)
	end,
}
