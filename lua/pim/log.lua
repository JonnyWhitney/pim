local buffers = require("pim.buffers")

local M = {}

local MAX_ENTRIES = 1000
local BUFFER_NAME = "pim://pi log"

-- Keep a bounded log in memory. The indexes avoid moving entries on each append.
local entries = {}
local first, last = 1, 0

---@param tag string
---@param text string
function M.add(tag, text)
	last = last + 1
	entries[last] = ("%s %-2s %s"):format(os.date("%H:%M:%S"), tag, text)
	if last - first >= MAX_ENTRIES then
		entries[first] = nil
		first = first + 1
	end
end

function M.raw(tag, line)
	if require("pim.config").get().debug then
		M.add(tag, line)
	end
end

---@return string[]
function M.lines()
	local out = {}
	for i = first, last do
		out[#out + 1] = entries[i]
	end
	return out
end

function M.clear()
	entries, first, last = {}, 1, 0
end

function M.open()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines())
	buffers.claim(buf, BUFFER_NAME, "log")
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"

	vim.cmd("botright split")
	vim.api.nvim_win_set_buf(0, buf)
	vim.api.nvim_win_set_cursor(0, { math.max(1, vim.api.nvim_buf_line_count(buf)), 0 })
end

return M
