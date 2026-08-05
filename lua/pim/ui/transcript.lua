local layout = require("pim.ui.layout")

local M = {}

local ns = vim.api.nvim_create_namespace("pim-transcript")
local queue_ns = vim.api.nvim_create_namespace("pim-queue")
local FLUSH_DELAY_MS = 50

local blocks = {}
local by_key = {}
local dirty = {}
local divider_count = 0
local marked_buf = nil

local timer = nil

local function stop_timer()
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end
end

local function schedule_flush()
	if timer then
		return
	end
	timer = vim.uv.new_timer()
	if not timer then
		vim.schedule(M.flush)
		return
	end
	timer:start(FLUSH_DELAY_MS, 0, function()
		vim.schedule(M.flush)
	end)
end

local function mark_row(buf, mark_id)
	return vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark_id, {})[1]
end

-- Extmarks move when text changes. They keep each streamed block anchored to its buffer range.
local function region(buf, index)
	local srow = mark_row(buf, blocks[index].mark)
	local next_block = blocks[index + 1]
	local erow = next_block and next_block.mark and mark_row(buf, next_block.mark) or vim.api.nvim_buf_line_count(buf)
	return srow, erow
end

local function content_lines(block)
	local out = vim.deepcopy(block.lines)
	out[#out + 1] = ""
	return out
end

local function write_block(buf, index)
	local block = blocks[index]
	local text = content_lines(block)

	if block.mark then
		local srow, erow = region(buf, index)
		vim.api.nvim_buf_set_lines(buf, srow, erow, false, text)
		block.srow = srow
		return
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local fresh = index == 1 and line_count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
	local srow = fresh and 0 or line_count
	vim.api.nvim_buf_set_lines(buf, fresh and 0 or -1, -1, false, text)
	block.mark = vim.api.nvim_buf_set_extmark(buf, ns, srow, 0, { right_gravity = false })
	block.srow = srow
end

local function rebind(buf)
	for _, block in ipairs(blocks) do
		block.mark = nil
		block.srow = nil
		dirty[block.key] = true
	end
	marked_buf = buf
end

local function fold_starts_closed(kind)
	local cfg = require("pim.config").get().transcript
	if kind == "thinking" then
		return cfg.show_thinking ~= "open"
	elseif kind == "tool" then
		return cfg.tools_collapsed
	end
	return true
end

local function apply_folds(buf, block)
	if not block.final or #block.folds == 0 then
		return
	end
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		vim.api.nvim_win_call(win, function()
			for _, fold in ipairs(block.folds) do
				local first = block.srow + fold.first + 1
				local last = block.srow + fold.last + 1
				pcall(vim.api.nvim_command, ("%d,%dfold"):format(first, last))
				if not fold_starts_closed(fold.kind) then
					pcall(vim.api.nvim_command, ("%dfoldopen"):format(first))
				end
			end
		end)
	end
end

local function following_windows(buf)
	local wins = {}
	local last = vim.api.nvim_buf_line_count(buf)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local bottom_visible = vim.api.nvim_win_call(win, function()
			return vim.fn.line("w$")
		end)
		if bottom_visible >= last - 1 then
			wins[#wins + 1] = win
		end
	end
	return wins
end

function M.flush()
	stop_timer()
	if not next(dirty) then
		return
	end
	local buf = layout.transcript_buf()
	if not buf then
		return
	end
	if marked_buf ~= buf then
		rebind(buf)
	end

	-- Find viewers at the end before writing. Keep only those viewers following the stream.
	local follow = following_windows(buf)

	vim.bo[buf].modifiable = true
	local written = {}
	for index, block in ipairs(blocks) do
		if dirty[block.key] then
			write_block(buf, index)
			dirty[block.key] = nil
			written[#written + 1] = block
		end
	end
	vim.bo[buf].modifiable = false

	for _, block in ipairs(written) do
		apply_folds(buf, block)
	end

	local last = vim.api.nvim_buf_line_count(buf)
	for _, win in ipairs(follow) do
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_cursor(win, { last, 0 })
		end
	end
end

---@param key string
---@param kind string
---@param rendered { lines: string[], folds: table[] }
---@param opts { final: boolean|nil }|nil
function M.set(key, kind, rendered, opts)
	if #rendered.lines == 0 then
		return
	end
	local block = by_key[key]
	if not block then
		block = { key = key, kind = kind, mark = nil, final = false }
		blocks[#blocks + 1] = block
		by_key[key] = block
	end
	block.lines = rendered.lines
	block.folds = rendered.folds or {}
	block.final = (opts and opts.final) or block.final

	dirty[key] = true
	if opts and opts.final then
		-- Folds need final text. Write it now before Neovim creates those folds.
		M.flush()
	else
		schedule_flush()
	end
end

---@param steering string[]|nil
---@param follow_up string[]|nil
function M.set_queue(steering, follow_up)
	local buf = layout.transcript_buf()
	if not buf then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, queue_ns, 0, -1)

	local virt_lines = {}
	for _, text in ipairs(steering or {}) do
		virt_lines[#virt_lines + 1] = { { "⏳ steer: " .. text:gsub("\n", " "), "Comment" } }
	end
	for _, text in ipairs(follow_up or {}) do
		virt_lines[#virt_lines + 1] = { { "⏳ follow-up: " .. text:gsub("\n", " "), "Comment" } }
	end
	if #virt_lines == 0 then
		return
	end

	local last_row = vim.api.nvim_buf_line_count(buf) - 1
	vim.api.nvim_buf_set_extmark(buf, queue_ns, last_row, 0, { virt_lines = virt_lines })
end

function M.foldtext()
	local header = vim.fn.getline(vim.v.foldstart)
	local count = vim.v.foldend - vim.v.foldstart + 1
	return ("%s  (%d lines)"):format(header, count)
end

function M.divider(text)
	divider_count = divider_count + 1
	M.set("divider-" .. divider_count, "divider", { lines = { text or "---" }, folds = {} }, { final = true })
end

function M.shutdown()
	stop_timer()
end

function M.reset()
	stop_timer()
	blocks, by_key, dirty = {}, {}, {}
	divider_count = 0
	local buf = layout.transcript_buf()
	marked_buf = buf
	if buf then
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		vim.api.nvim_buf_clear_namespace(buf, queue_ns, 0, -1)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
		vim.bo[buf].modifiable = false
	end
end

return M
