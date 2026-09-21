local M = {}
local data = require("pim.completion.data")
local context = require("pim.completion.context")

function M.new()
	return setmetatable({}, { __index = M })
end

function M:enabled()
	return context.get() ~= nil
end

function M:get_trigger_characters()
	return { "/" }
end

local function response(items)
	return {
		items = items,
		is_incomplete_forward = true,
		is_incomplete_backward = true,
	}
end

local function item(command, ctx)
	local text = "/" .. command.name
	local function range(finish)
		return {
			start = { line = ctx.row, character = ctx.start },
			["end"] = { line = ctx.row, character = finish },
		}
	end
	return {
		label = text,
		filterText = text,
		kind = 1,
		labelDetails = { description = command.source },
		client_name = command.source,
		documentation = command.description and { kind = "plaintext", value = command.description } or nil,
		insertTextFormat = 1,
		-- UTF-8 byte ranges are used by non-LSP Blink sources. Both keyword
		-- replacement settings are supported through InsertReplaceEdit.
		textEdit = { newText = text, insert = range(ctx.col), replace = range(ctx.finish) },
	}
end

function M:get_completions(ctx, callback)
	local parsed = context.get(ctx)
	local items = {}
	if parsed then
		for _, command in ipairs(data.command_candidates()) do
			items[#items + 1] = item(command, parsed)
		end
	end
	callback(response(items))
	return function() end
end

return M
