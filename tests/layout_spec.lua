local h = require("helpers")
local layout = require("pim.ui.layout")

local TRANSCRIPT = "pim://pi transcript"
local INPUT = "pim://pi input"

local scratch = {}

local function name_of(buf)
	return buf and vim.api.nvim_buf_get_name(buf) or nil
end

local function windows_showing(buf)
	local count = 0
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == buf then
			count = count + 1
		end
	end
	return count
end

local function user_buf(name)
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(buf, name)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved work" })
	scratch[#scratch + 1] = buf
	return buf
end

local function drop_pi_bufs()
	for _, buf in ipairs({ layout.transcript_buf(), layout.input_buf() }) do
		if buf then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end
end

local function guarded(fn)
	scratch = {}
	vim.cmd("tabnew")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "guard" })
	local guard = vim.api.nvim_get_current_tabpage()

	local ok, err = pcall(fn, guard)

	layout.close()
	drop_pi_bufs()
	for _, buf in ipairs(scratch) do
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	if vim.api.nvim_tabpage_is_valid(guard) then
		vim.api.nvim_set_current_tabpage(guard)
		vim.bo.modified = false
		if #vim.api.nvim_list_tabpages() > 1 then
			vim.cmd("tabclose")
		end
	end

	if not ok then
		error(err, 0)
	end
end

return {
	["a buffer whose name merely contains ours is left alone"] = function()
		guarded(function()
			drop_pi_bufs()
			local decoy = user_buf("my-pim://pi transcript-scratch")
			vim.bo[decoy].modified = true

			layout.open()

			h.ok(vim.api.nvim_buf_is_valid(decoy), "the user's buffer survived :PiStart")
			h.eq({ "unsaved work" }, vim.api.nvim_buf_get_lines(decoy, 0, -1, false), "with its content intact")

			h.eq(TRANSCRIPT, name_of(layout.transcript_buf()))
			h.eq(INPUT, name_of(layout.input_buf()))
		end)
	end,

	["a leftover pi buffer of the same name is reclaimed"] = function()
		guarded(function()
			drop_pi_bufs()
			local leftover = vim.api.nvim_create_buf(false, true)
			vim.b[leftover].pim_role = "transcript"
			vim.api.nvim_buf_set_name(leftover, TRANSCRIPT)
			scratch[#scratch + 1] = leftover

			layout.open()

			h.ok(not vim.api.nvim_buf_is_valid(leftover), "the stale pi buffer was reclaimed")
			h.eq(TRANSCRIPT, name_of(layout.transcript_buf()), "so the canonical name is reused, not suffixed")
		end)
	end,

	["a name collision with a user buffer picks a free suffix"] = function()
		guarded(function()
			drop_pi_bufs()
			local held = user_buf(TRANSCRIPT)
			local held_2 = user_buf(TRANSCRIPT .. " (2)")

			layout.open()

			h.eq(TRANSCRIPT .. " (3)", name_of(layout.transcript_buf()), "walked past both taken names")
			h.ok(vim.api.nvim_buf_is_valid(held), "the user's buffer was not taken")
			h.ok(vim.api.nvim_buf_is_valid(held_2), "nor the one holding the first suffix")

			layout.close()
			drop_pi_bufs()
			local held_3 = user_buf(TRANSCRIPT .. " (3)")

			layout.open()

			h.eq(TRANSCRIPT .. " (4)", name_of(layout.transcript_buf()), "and past the third")
			h.ok(vim.api.nvim_buf_is_valid(held_3), "the third user buffer was not taken either")
		end)
	end,

	["closing the transcript alone is repaired, not duplicated"] = function()
		guarded(function()
			layout.open()
			local pi_tab = vim.api.nvim_get_current_tabpage()
			local input_win = layout.input_win()
			local tabs = #vim.api.nvim_list_tabpages()

			vim.api.nvim_win_close(layout.transcript_win(), true)
			layout.open()

			h.eq(tabs, #vim.api.nvim_list_tabpages(), "no second pi tab was built")
			h.eq(input_win, layout.input_win(), "the surviving input window was reused, not replaced")
			h.eq(pi_tab, vim.api.nvim_win_get_tabpage(layout.transcript_win()), "the replacement went in beside it")
			h.eq(1, windows_showing(layout.input_buf()), "exactly one window shows the input buffer")
			h.eq(1, windows_showing(layout.transcript_buf()), "and exactly one shows the transcript")
			h.ok(layout.is_open(), "the layout is whole again")
		end)
	end,

	["closing the input alone is repaired, not duplicated"] = function()
		guarded(function()
			layout.open()
			local pi_tab = vim.api.nvim_get_current_tabpage()
			local transcript_win = layout.transcript_win()
			local tabs = #vim.api.nvim_list_tabpages()

			vim.api.nvim_win_close(layout.input_win(), true)
			layout.open()

			h.eq(tabs, #vim.api.nvim_list_tabpages(), "no second pi tab was built")
			h.eq(transcript_win, layout.transcript_win(), "the surviving transcript window was reused")
			h.eq(pi_tab, vim.api.nvim_win_get_tabpage(layout.input_win()), "the replacement went in beside it")
			h.eq(1, windows_showing(layout.transcript_buf()), "exactly one window shows the transcript")
			h.eq(1, windows_showing(layout.input_buf()), "and exactly one shows the input buffer")
			h.eq(layout.input_win(), vim.api.nvim_get_current_win(), "and open() lands in it")
		end)
	end,

	["a repaired transcript window keeps its window options"] = function()
		local WANTED = {
			wrap = true,
			linebreak = true,
			foldenable = true,
			foldmethod = "manual",
			foldtext = "v:lua.require'pim.ui.transcript'.foldtext()",
			fillchars = "fold: ",
			number = false,
			signcolumn = "no",
		}
		local WRONG = {
			wrap = false,
			linebreak = false,
			foldenable = false,
			foldmethod = "indent",
			foldtext = "",
			fillchars = "",
			number = true,
			signcolumn = "yes",
		}

		guarded(function()
			layout.open()
			local pi_tab = vim.api.nvim_get_current_tabpage()
			local input_win = layout.input_win()

			vim.api.nvim_win_close(layout.transcript_win(), true)

			vim.api.nvim_buf_delete(layout.transcript_buf(), { force = true })
			for name, value in pairs(WRONG) do
				vim.api.nvim_set_option_value(name, value, { win = input_win })
			end

			layout.open()

			local win = layout.transcript_win()
			h.eq(pi_tab, vim.api.nvim_win_get_tabpage(win), "repaired in place, so these are the repair's own options")

			for name, value in pairs(WANTED) do
				h.eq(value, vim.api.nvim_get_option_value(name, { win = win }), name)
			end

			local min_height = require("pim.config").get().input.min_height
			h.eq(min_height, vim.api.nvim_win_get_height(layout.input_win()), "the input window is back to its height")
		end)
	end,

	["repair works when focus is in an unrelated window"] = function()
		guarded(function(guard)
			layout.open()
			local pi_tab = vim.api.nvim_get_current_tabpage()

			for _, closed in ipairs({ "input", "transcript" }) do
				vim.api.nvim_win_close(closed == "input" and layout.input_win() or layout.transcript_win(), true)

				vim.api.nvim_set_current_tabpage(guard)
				local bystander = vim.api.nvim_get_current_win()

				layout.open()

				local why = "after closing the " .. closed
				h.eq(1, #vim.api.nvim_tabpage_list_wins(guard), why .. ": the unrelated tab was not split")
				h.ok(vim.api.nvim_win_is_valid(bystander), why .. ": its window is untouched")
				h.eq(pi_tab, vim.api.nvim_win_get_tabpage(layout.input_win()), why .. ": repaired into the pi tab")
				h.eq(1, windows_showing(layout.transcript_buf()), why .. ": one window shows the transcript")
				h.eq(1, windows_showing(layout.input_buf()), why .. ": one window shows the input buffer")
			end
		end)
	end,
}
