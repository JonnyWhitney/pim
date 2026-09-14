local M = {}
local ns = vim.api.nvim_create_namespace("pim-transcript-decorations")
local group
local active_buf

local function define_highlights()
	for name, link in pairs({
		PimUserHeader = "Identifier",
		PimAssistantHeader = "Statement",
		PimCustomHeader = "Special",
		PimDivider = "Comment",
	}) do
		vim.api.nvim_set_hl(0, name, { default = true, link = link })
	end
end

local function divider_width(buf)
	local width = 1
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local info = vim.fn.getwininfo(win)[1]
		width = math.max(width, vim.api.nvim_win_get_width(win) - info.textoff)
	end
	return width
end

function M.attach(buf, refresh)
	active_buf = buf
	if group then
		return
	end
	define_highlights()
	group = vim.api.nvim_create_augroup("PimTranscriptDecorations", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = define_highlights,
	})
	vim.api.nvim_create_autocmd("WinResized", {
		group = group,
		callback = function()
			if active_buf and vim.api.nvim_buf_is_valid(active_buf) then
				refresh()
			end
		end,
	})
end

---@param buf integer
---@param blocks PimTranscriptBlock[]
function M.apply(buf, blocks)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	local config = require("pim.config").get().transcript
	local divider = config.dividers and string.rep("─", divider_width(buf)) or nil
	for _, block in ipairs(blocks) do
		local header = block.header
		if header and block.srow then
			local row = block.srow + header.row
			local highlight = config.header_highlights and config.header_highlights[header.role]
			if highlight then
				vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
					end_row = row,
					end_col = #block.lines[header.row + 1],
					hl_group = highlight,
					-- Markdown and Tree-sitter colors are overridden only within the role header.
					priority = 200,
				})
			end
			if divider and header.row == 0 and row > 0 then
				-- The store's blank separator is decorated without adding text or screen rows.
				-- Overlay text is clipped by Neovim in narrower windows.
				vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
					virt_text = { { divider, "PimDivider" } },
					virt_text_pos = "overlay",
					priority = 200,
				})
			end
		end
	end
end

function M.reset()
	if active_buf and vim.api.nvim_buf_is_valid(active_buf) then
		vim.api.nvim_buf_clear_namespace(active_buf, ns, 0, -1)
	end
end

function M.shutdown()
	M.reset()
	if group then
		vim.api.nvim_del_augroup_by_id(group)
	end
	group, active_buf = nil, nil
end

return M
