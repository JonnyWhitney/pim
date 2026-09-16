local M = {}
local data = require("pim.completion.data")
local context = require("pim.completion.context")
local backend = require("pim.completion.backend")

local function active()
	return backend.is_blink_enabled() and context.get() ~= nil
end

local function evaluate(value, ...)
	return type(value) == "function" and value(...) or vim.deepcopy(value)
end

-- Filetype overrides are composed into the documented dynamic default selector.
-- This avoids depending on support for function-valued per_filetype entries.
local function route(default, per_filetype)
	return function(...)
		if active() then
			return { "pim" }
		end
		local defaults = evaluate(default, ...)
		if vim.api.nvim_get_mode().mode:match("^[ct]") or vim.fn.getcmdwintype() ~= "" then
			return defaults
		end
		local selected, overridden = {}, false
		for _, ft in ipairs(vim.split(vim.bo.filetype, ".", { plain = true, trimempty = true })) do
			if per_filetype[ft] ~= nil then
				local specific = evaluate(per_filetype[ft], ...)
				vim.list_extend(selected, specific)
				if specific.inherit_defaults then
					vim.list_extend(selected, defaults)
				end
				overridden = true
			end
		end
		return overridden and selected or defaults
	end
end

-- Blink may coalesce several typed characters into one change event. Its
-- visible list is refreshed after reference boundaries, so an old provider
-- list cannot be reused for the same keyword in a new context.
-- Only already-visible menus are refreshed. Hidden or ghost-text-only menus
-- are not opened by this handler.
local function watch_boundaries(select_sources)
	local pending
	local group = vim.api.nvim_create_augroup("pim-blink-boundaries", { clear = true })
	vim.api.nvim_create_autocmd("InsertCharPre", {
		group = group,
		callback = function()
			local cmp = package.loaded["blink.cmp"]
			local layout = require("pim.ui.layout")
			if
				not backend.is_blink_enabled()
				or not cmp
				or not layout.is_open()
				or layout.input_buf() ~= vim.api.nvim_get_current_buf()
			then
				return
			end
			local char = vim.v.char
			local cursor = vim.api.nvim_win_get_cursor(0)
			local line = vim.api.nvim_get_current_line()
			local start = data.parse_context(line:sub(1, cursor[2]) .. char, cursor[2] + #char, cursor[1])
			local entering = (char == "@" or char == "/") and start == cursor[2]
			if entering or (char:match("%s") and context.get() ~= nil) then
				pending = { buf = vim.api.nvim_get_current_buf(), visible = cmp.is_menu_visible() }
			end
		end,
	})
	-- Windows cannot be closed during InsertCharPre's text lock. Refresh is
	-- scheduled after Blink's change handlers; edits made meanwhile invalidate it.
	vim.api.nvim_create_autocmd("TextChangedI", {
		group = group,
		callback = function(event)
			local previous = pending
			pending = nil
			local cmp = package.loaded["blink.cmp"]
			if previous and previous.visible and previous.buf == event.buf and backend.is_blink_enabled() and cmp then
				local tick = vim.api.nvim_buf_get_changedtick(event.buf)
				local cursor = vim.api.nvim_win_get_cursor(0)
				vim.schedule(function()
					if
						backend.is_blink_enabled()
						and vim.api.nvim_get_current_buf() == event.buf
						and vim.api.nvim_get_mode().mode == "i"
						and vim.api.nvim_buf_get_changedtick(event.buf) == tick
						and vim.deep_equal(vim.api.nvim_win_get_cursor(0), cursor)
					then
						cmp.hide()
						cmp.show({ providers = select_sources() })
					end
				end)
			end
		end,
	})
end

---Explicit integration contract: a sources configuration with a default list
---(or function) is supplied before blink.cmp.setup. A new configuration is
---returned; existing defaults, filetype overrides and provider options are kept.
---Only source selection is changed. Menu behavior and keymaps are not configured.
---@param sources table
---@return table
function M.setup(sources)
	assert(type(sources) == "table", "pim Blink setup requires a sources table")
	assert(
		type(sources.default) == "table" or type(sources.default) == "function",
		"pim Blink setup requires sources.default"
	)
	local result = vim.deepcopy(sources)
	result.default = route(result.default, result.per_filetype or {})
	result.per_filetype = {}
	result.providers = result.providers or {}
	assert(result.providers.pim == nil, "the Blink provider id 'pim' is reserved")
	result.providers.pim = {
		name = "pim",
		module = "pim.completion.blink",
		fallbacks = {},
		should_show_items = active,
	}
	backend.set_blink_enabled(true)
	watch_boundaries(result.default)
	return result
end

function M.new()
	return setmetatable({}, { __index = M })
end

function M:enabled()
	return active()
end

function M:get_trigger_characters()
	return { "@", "/" }
end

local function response(items)
	return {
		items = items,
		-- Ranges are refreshed on edits, including deletion and mid-token typing.
		is_incomplete_forward = true,
		is_incomplete_backward = true,
	}
end

local function item(text, ctx, kind, source, description)
	local function range(finish)
		return {
			start = { line = ctx.row, character = ctx.start },
			["end"] = { line = ctx.row, character = finish },
		}
	end
	return {
		label = text,
		filterText = text,
		kind = kind,
		labelDetails = { description = source },
		client_name = source,
		documentation = description and { kind = "plaintext", value = description } or nil,
		insertTextFormat = 1,
		-- Non-LSP Blink sources use UTF-8 byte offsets. InsertReplaceEdit lets
		-- Blink honor keyword.range without a runtime dependency on its config.
		textEdit = { newText = text, insert = range(ctx.col), replace = range(ctx.finish) },
	}
end

function M:get_completions(ctx, callback)
	local parsed = backend.is_blink_enabled() and context.get(ctx) or nil
	if not parsed then
		callback(response({}))
		return function() end
	end
	local tick = vim.api.nvim_buf_get_changedtick(parsed.bufnr)
	local function current()
		local now = context.get()
		return backend.is_blink_enabled()
			and now ~= nil
			and vim.deep_equal(now, parsed)
			and vim.api.nvim_buf_get_changedtick(parsed.bufnr) == tick
	end
	if parsed.kind == "slash" then
		local items = {}
		for _, command in ipairs(data.command_candidates()) do
			items[#items + 1] = item("/" .. command.name, parsed, 1, command.source, command.description)
		end
		callback(response(items))
		return function() end
	end
	return data.request_files(vim.uv.cwd(), function(paths)
		local items = {}
		for _, path in ipairs(paths) do
			items[#items + 1] = item("@" .. path, parsed, 17, "file")
		end
		callback(response(items))
	end, current)
end

return M
