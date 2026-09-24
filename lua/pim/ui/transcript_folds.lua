local M = {}
local windows = {}
local active_buf
local group
local rendered = {}

local function in_window(win, callback)
	return vim.api.nvim_win_call(win, function()
		-- Latent fold choices are read even when folding has been disabled with zi.
		local enabled = vim.wo[win].foldenable
		vim.wo[win].foldenable = true
		local ok, err = pcall(callback)
		vim.wo[win].foldenable = enabled
		if not ok then
			error(err, 0)
		end
	end)
end

local function remove(fold)
	if vim.fn.foldlevel(fold.first) > 0 then
		vim.api.nvim_win_set_cursor(0, { fold.first, 0 })
		vim.cmd("normal! zd")
	end
end

local function collect(blocks)
	local result = {}
	for _, block in ipairs(blocks) do
		local counts = {}
		for _, fold in ipairs(block.folds) do
			counts[fold.kind] = (counts[fold.kind] or 0) + 1
			if block.srow and fold.first >= 0 and fold.last > fold.first and fold.last < #block.lines then
				result[#result + 1] = {
					key = block.key,
					id = fold.kind .. ":" .. tostring(fold.id or counts[fold.kind]),
					kind = fold.kind,
					first = block.srow + fold.first + 1,
					last = block.srow + fold.last + 1,
				}
			end
		end
	end
	return result
end

function M.attach(buf, refresh)
	if active_buf ~= buf then
		windows, rendered = {}, {}
		active_buf = buf
	end
	if group then
		return
	end
	group = vim.api.nvim_create_augroup("PimTranscriptFolds", { clear = true })
	vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
		group = group,
		callback = function()
			vim.schedule(function()
				if active_buf and vim.api.nvim_buf_is_valid(active_buf) then
					refresh()
				end
			end)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(event)
			windows[tonumber(event.match)] = nil
		end,
	})
end

-- Native fold state is captured before any affected text is replaced.
function M.capture(buf, dirty)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		in_window(win, function()
			local state = windows[win]
			if not state then
				state = { folds = {}, choices = {} }
				windows[win] = state
				-- Inherited folds are removed before defaults are applied in a new window.
				for _, fold in ipairs(rendered) do
					remove(fold)
				end
			end
			for _, fold in ipairs(state.folds) do
				state.choices[fold.key] = state.choices[fold.key] or {}
				state.choices[fold.key][fold.id] = vim.fn.foldclosed(fold.first) ~= -1
				if dirty[fold.key] then
					remove(fold)
				end
			end
		end)
	end
end

function M.apply(buf, blocks, dirty)
	local next_folds = collect(blocks)
	local defaults = require("pim.config").get().transcript.folds
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		in_window(win, function()
			local state = windows[win]
			local existing = {}
			for _, fold in ipairs(state.folds) do
				existing[fold.key] = existing[fold.key] or {}
				existing[fold.key][fold.id] = true
			end
			for _, fold in ipairs(next_folds) do
				if dirty[fold.key] or not (existing[fold.key] and existing[fold.key][fold.id]) then
					vim.cmd(("%d,%dfold"):format(fold.first, fold.last))
					local closed = state.choices[fold.key] and state.choices[fold.key][fold.id]
					if closed == nil then
						closed = fold.kind == "tree_responses" or defaults[fold.kind] ~= "open"
					end
					if not closed then
						vim.cmd(("%dfoldopen"):format(fold.first))
					end
				end
			end
			state.folds = next_folds
		end)
	end
	rendered = next_folds
end

function M.reset()
	windows, rendered = {}, {}
end

function M.shutdown()
	if group then
		vim.api.nvim_del_augroup_by_id(group)
	end
	group, active_buf = nil, nil
	M.reset()
end

return M
