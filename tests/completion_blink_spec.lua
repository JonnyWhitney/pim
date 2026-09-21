local h = require("helpers")
local blink = require("pim.completion.blink")
local data = require("pim.completion.data")
local layout = require("pim.ui.layout")

local function with_input(fn)
	local virtualedit = vim.o.virtualedit
	vim.o.virtualedit = "onemore"
	layout.open()
	local original = data.command_candidates
	local ok, err = pcall(fn, layout.input_buf())
	data.command_candidates = original
	data.reset()
	layout.destroy()
	vim.o.virtualedit = virtualedit
	if not ok then
		error(err, 0)
	end
end

local function prompt(text, col, row)
	local lines = vim.split(text, "\n")
	row = row or 1
	col = col or #lines[row]
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	vim.api.nvim_win_set_cursor(0, { row, col })
	return { bufnr = vim.api.nvim_get_current_buf(), cursor = { row, col }, line = lines[row], mode = "default" }
end

local function candidates(source, ctx)
	local result
	source:get_completions(ctx, function(value)
		result = value
	end)
	return result
end

local function metadata()
	---@diagnostic disable-next-line: duplicate-set-field
	data.command_candidates = function()
		return { { name = "rpc-select", source = "extension", description = "Demo select dialog" } }
	end
end

return {
	["command context is enabled without helper or backend activation"] = function()
		with_input(function()
			local source = blink.new()
			h.eq(nil, blink.setup)
			h.eq({ "/" }, source:get_trigger_characters())
			for _, text in ipairs({ "/", "/rpc" }) do
				local ctx = prompt(text)
				h.ok(source:enabled())
				h.eq({}, candidates(source, ctx).items, "metadata is not yet available")
			end
			metadata()
			for _, text in ipairs({ "/", "/rpc" }) do
				h.eq("/rpc-select", candidates(source, prompt(text)).items[1].label)
			end
			for _, text in ipairs({
				"",
				" /rpc",
				"text /rpc",
				"/rpc argument",
				"/rpc\targ",
				"@",
				"@~/",
				"`@~/",
				"é /rpc",
			}) do
				local ctx = prompt(text)
				h.eq(false, source:enabled(), text)
				h.eq({}, candidates(source, ctx).items, text)
			end
			local ctx = prompt("text\n/rpc", nil, 2)
			h.eq(false, source:enabled())
			h.eq({}, candidates(source, ctx).items)
			ctx = prompt("/rpc")
			for _, mode in ipairs({ "cmdline", "term", "terminal" }) do
				ctx.mode = mode
				h.eq({}, candidates(source, ctx).items)
			end
		end)
	end,

	["Markdown transcript and unrelated buffers are rejected"] = function()
		with_input(function(buf)
			local source = blink.new()
			metadata()
			local ctx = prompt("/rpc")
			ctx.bufnr = buf + 1000
			h.eq({}, candidates(source, ctx).items)
			local ordinary = vim.api.nvim_create_buf(false, true)
			for _, other in ipairs({ ordinary, assert(layout.transcript_buf()) }) do
				vim.api.nvim_win_set_buf(0, other)
				vim.bo.modifiable = true
				vim.bo.filetype = "markdown"
				ctx = prompt("/rpc")
				h.eq(false, source:enabled())
				h.eq({}, candidates(source, ctx).items)
			end
			vim.api.nvim_win_set_buf(0, buf)
			vim.api.nvim_buf_delete(ordinary, { force = true })
		end)
	end,

	["construction leaves existing options and mappings untouched"] = function()
		with_input(function(buf)
			vim.bo[buf].completeopt = "menu,menuone"
			vim.bo[buf].omnifunc = "OriginalOmni"
			vim.keymap.set("i", "/", "original", { buffer = buf })
			vim.keymap.set("i", "@", "user", { buffer = buf })
			blink.new()
			h.eq("original", vim.fn.maparg("/", "i"))
			h.eq("user", vim.fn.maparg("@", "i"))
			h.eq("menu,menuone", vim.bo[buf].completeopt)
			h.eq("OriginalOmni", vim.bo[buf].omnifunc)
		end)
	end,

	["provider survives hide show and cleanup without helper activation"] = function()
		with_input(function(buf)
			local options = { vim.bo[buf].completeopt, vim.bo[buf].omnifunc }
			local source = blink.new()
			h.eq(options, { vim.bo[buf].completeopt, vim.bo[buf].omnifunc })
			prompt("/rpc")
			layout.hide()
			h.eq(false, source:enabled())
			layout.open()
			h.ok(source:enabled())
			require("pim.lifecycle").cleanup()
			layout.open()
			local ctx = prompt("/rpc")
			h.ok(source:enabled())
			h.eq({}, candidates(source, ctx).items)
			h.eq("", vim.fn.maparg("@", "i"))
		end)
	end,

	["metadata and full versus cursor byte ranges are preserved"] = function()
		with_input(function()
			metadata()
			local source = blink.new()
			local ctx = prompt("/rpc-select é argument", 4)
			ctx.pos = { row = 0, col = 4 }
			local result = candidates(source, ctx)
			local item = result.items[1]
			h.eq("/rpc-select", item.label)
			h.eq("extension", item.labelDetails.description)
			h.eq("extension", item.client_name)
			h.eq("Demo select dialog", item.documentation.value)
			h.eq(0, item.textEdit.insert.start.character)
			h.eq(4, item.textEdit.insert["end"].character)
			h.eq(11, item.textEdit.replace["end"].character)
			item.textEdit.newText = "mutated"
			h.eq("/rpc-select", candidates(source, ctx).items[1].textEdit.newText)
			h.ok(result.is_incomplete_backward)
			h.ok(result.is_incomplete_forward)
		end)
	end,
}
