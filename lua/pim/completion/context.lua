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
	if vim.api.nvim_get_mode().mode:match("^[ct]") or vim.fn.getcmdwintype() ~= "" then
		return nil
	end
	local cursor = ctx and ctx.cursor or vim.api.nvim_win_get_cursor(0)
	if ctx and ctx.pos then
		cursor = { ctx.pos.row + 1, ctx.pos.col }
	end
	local line = ctx and ctx.line or vim.api.nvim_get_current_line()
	if cursor[1] ~= 1 or not line:sub(1, cursor[2]):match("^/[%w%-_:%.]*$") then
		return nil
	end
	local suffix = line:sub(cursor[2] + 1):match("^[%w%-_:%.]*")
	return {
		bufnr = buf,
		row = cursor[1] - 1,
		col = cursor[2],
		line = line,
		start = 0,
		finish = cursor[2] + #suffix,
	}
end

return M
