local M = {}

---Input-buffer identity is checked independently of its Markdown filetype.
---Blink's cursor uses one-based rows and zero-based byte columns. Newer Blink
---also supplies pos with zero-based rows. Replacement ranges include the sigil.
---@param ctx? table
---@return table|nil
function M.get(ctx)
	local layout = require("pim.ui.layout")
	local buf = vim.api.nvim_get_current_buf()
	if not layout.is_open() or layout.input_buf() ~= buf then
		return nil
	end
	if ctx and (ctx.bufnr ~= buf or (ctx.mode and ctx.mode ~= "default")) then
		return nil
	end
	if not ctx and vim.api.nvim_get_mode().mode:match("^[ct]") then
		return nil
	end
	local cursor = ctx and ctx.cursor or vim.api.nvim_win_get_cursor(0)
	if ctx and ctx.pos then
		cursor = { ctx.pos.row + 1, ctx.pos.col }
	end
	local line = ctx and ctx.line or vim.api.nvim_get_current_line()
	local start, kind = require("pim.completion.data").parse_context(line, cursor[2], cursor[1])
	if start == nil then
		return nil
	end
	local suffix = line:sub(cursor[2] + 1):match(kind == "file" and "^[^%s@]*" or "^[%w%-_:%.]*")
	return {
		bufnr = buf,
		row = cursor[1] - 1,
		col = cursor[2],
		line = line,
		start = start,
		finish = cursor[2] + #suffix,
		kind = kind,
	}
end

return M
