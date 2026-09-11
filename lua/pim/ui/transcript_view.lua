local M = {}
local states = {}
local active_buf
local group
local changing = false

local function snapshot(win)
	return vim.api.nvim_win_call(win, function()
		-- Cursor visibility is resolved before the navigation baseline is captured.
		vim.fn.winline()
		local bottom = vim.fn.line("w$")
		---@type table
		local view = vim.fn.winsaveview()
		view.bottom = bottom
		local last = math.max(1, vim.api.nvim_buf_line_count(active_buf) - 1)
		view.at_end = view.lnum >= last
		if view.lnum == last then
			local remaining = vim.api.nvim_win_text_height(win, {
				start_row = last - 1,
				end_row = last - 1,
				start_vcol = vim.fn.virtcol(".") - 1,
			})
			view.at_end = remaining.all <= 1
		end
		return view
	end)
end

local function content_end(buf)
	return math.max(1, vim.api.nvim_buf_line_count(buf) - 1)
end

local function observe(win)
	local now = snapshot(win)
	local state = states[win]
	if not state then
		state = { following = true }
		states[win] = state
	end
	local old = state.baseline
	if old then
		local up = now.topline < old.topline or (now.topline == old.topline and now.skipcol < old.skipcol)
		local down = now.topline > old.topline or (now.topline == old.topline and now.skipcol > old.skipcol)
		local moved = now.lnum ~= old.lnum or now.col ~= old.col
		local folded = vim.api.nvim_win_call(win, function()
			return vim.fn.foldclosed(old.lnum)
		end)
		if moved and folded == now.lnum and old.lnum ~= now.lnum then
			-- A closed fold is treated as a position adjustment, not navigation.
		elseif up or (not now.at_end and (now.lnum < old.lnum or (now.lnum == old.lnum and now.col < old.col))) then
			state.following = false
		elseif down and now.bottom >= content_end(active_buf) then
			state.following = true
		elseif moved then
			state.following = now.at_end
		end
	end
	state.baseline = now
	return state, now
end

function M.attach(buf)
	if active_buf ~= buf then
		states = {}
		active_buf = buf
	end
	if group then
		return
	end
	group = vim.api.nvim_create_augroup("PimTranscriptView", { clear = true })
	vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled", "BufWinEnter" }, {
		group = group,
		callback = function()
			if changing or not active_buf or not vim.api.nvim_buf_is_valid(active_buf) then
				return
			end
			for _, win in ipairs(vim.fn.win_findbuf(active_buf)) do
				observe(win)
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(event)
			states[tonumber(event.match)] = nil
		end,
	})
end

local function anchor(line, ranges)
	for i = #ranges, 1, -1 do
		if line >= ranges[i].first then
			return { key = ranges[i].key, offset = line - ranges[i].first }
		end
	end
	return { offset = line - 1 }
end

local function resolve(position, ranges)
	for _, range in ipairs(ranges) do
		if range.key == position.key then
			return math.min(range.last, range.first + position.offset)
		end
	end
	return math.min(vim.api.nvim_buf_line_count(active_buf), position.offset + 1)
end

function M.capture(buf, ranges)
	M.attach(buf)
	local saved = {}
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local state, view = observe(win)
		saved[win] = {
			following = state.following,
			view = view,
			cursor = anchor(view.lnum, ranges),
			top = anchor(view.topline, ranges),
		}
	end
	changing = true
	return saved
end

local function position_end(win)
	vim.api.nvim_win_call(win, function()
		local line = content_end(active_buf)
		local folded = vim.fn.foldclosed(line)
		local col = math.max(0, #vim.fn.getline(line) - 1)
		vim.api.nvim_win_set_cursor(win, { folded == -1 and line or folded, folded == -1 and col or 0 })
		vim.cmd("normal! zb")
	end)
end

function M.restore(saved, ranges)
	for win, position in pairs(saved) do
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == active_buf then
			if position.following then
				position_end(win)
			else
				vim.api.nvim_win_call(win, function()
					local view = position.view
					view.lnum = resolve(position.cursor, ranges)
					view.topline = resolve(position.top, ranges)
					for _, key in ipairs({ "lnum", "topline" }) do
						local folded = vim.fn.foldclosed(view[key])
						if folded ~= -1 then
							view[key] = folded
						end
					end
					view.col = math.min(view.col, math.max(0, #vim.fn.getline(view.lnum) - 1))
					vim.fn.winrestview(view)
				end)
			end
			states[win].baseline = snapshot(win)
		end
	end
	changing = false
end

function M.resume(win, buf)
	if not win or not buf or not vim.api.nvim_win_is_valid(win) then
		return
	end
	M.attach(buf)
	changing = true
	position_end(win)
	states[win] = { following = true, baseline = snapshot(win) }
	changing = false
end

function M.reset()
	states = {}
end

function M.shutdown()
	if group then
		vim.api.nvim_del_augroup_by_id(group)
	end
	group, active_buf = nil, nil
	states = {}
	changing = false
end

return M
