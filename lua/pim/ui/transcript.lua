local layout = require("pim.ui.layout")
local view = require("pim.ui.transcript_view")
local folds = require("pim.ui.transcript_folds")

local M = {}

local ns = vim.api.nvim_create_namespace("pim-transcript")
local queue_ns = vim.api.nvim_create_namespace("pim-queue")
local FLUSH_DELAY_MS = 50

---@type PimTranscriptBlock[]
local blocks = {}
---@type table<string, PimTranscriptBlock>
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
		local following = {}
		for i = index + 1, #blocks do
			if blocks[i].mark then
				following[#following + 1] = { mark = blocks[i].mark, row = mark_row(buf, blocks[i].mark) }
			end
		end
		vim.api.nvim_buf_set_lines(buf, srow, erow, false, text)
		-- Boundary marks are rebound because replacement can collapse them into the changed range.
		for _, mark in ipairs(following) do
			vim.api.nvim_buf_set_extmark(buf, ns, mark.row + #text - (erow - srow), 0, {
				id = mark.mark,
				right_gravity = false,
			})
		end
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

local function ranges(buf)
	local result = {}
	for index, block in ipairs(blocks) do
		if block.mark then
			local first, last = region(buf, index)
			result[#result + 1] = { key = block.key, first = first + 1, last = last }
		end
	end
	return result
end

function M.flush()
	stop_timer()
	local buf = layout.transcript_buf()
	if not buf then
		return
	end
	if marked_buf ~= buf then
		rebind(buf)
	end

	folds.attach(buf, M.flush)
	local saved = view.capture(buf, ranges(buf))
	folds.capture(buf, dirty)

	vim.bo[buf].modifiable = true
	for index, block in ipairs(blocks) do
		if dirty[block.key] then
			write_block(buf, index)
		end
	end
	vim.bo[buf].modifiable = false

	for _, block in ipairs(blocks) do
		block.srow = mark_row(buf, block.mark)
	end
	folds.apply(buf, blocks, dirty)
	dirty = {}

	view.restore(saved, ranges(buf))
end

---@param key string
---@param kind string
---@param rendered PimRenderedBlock
---@param opts { final: boolean|nil }|nil
function M.set(key, kind, rendered, opts)
	if #rendered.lines == 0 then
		return
	end
	local block = by_key[key]
	if not block then
		block = { key = key, kind = kind, lines = {}, folds = {}, mark = nil, final = false }
		blocks[#blocks + 1] = block
		by_key[key] = block
	end
	block.lines = rendered.lines
	block.folds = rendered.folds or {}
	block.final = (opts and opts.final) or block.final

	dirty[key] = true
	if opts and opts.final then
		-- Completed content is written without waiting for the streaming timer.
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
	view.shutdown()
	folds.shutdown()
end

function M.reset()
	stop_timer()
	view.reset()
	folds.reset()
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
