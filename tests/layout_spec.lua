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
	scratch[#scratch + 1] = buf
	vim.api.nvim_buf_set_name(buf, name)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved work" })
	return buf
end

local function drop_pi_bufs()
	layout.destroy()
end

local function guarded(fn)
	return h.with_cleanup(function(defer)
		scratch = {}
		defer(function()
			h.with_cleanup(function(remove)
				for _, buf in ipairs(scratch) do
					remove(function()
						if vim.api.nvim_buf_is_valid(buf) then
							vim.api.nvim_buf_delete(buf, { force = true })
						end
					end)
				end
			end)
		end)
		vim.cmd("tabnew")
		local guard = vim.api.nvim_get_current_tabpage()
		scratch[#scratch + 1] = vim.api.nvim_get_current_buf()
		defer(function()
			if vim.api.nvim_tabpage_is_valid(guard) and #vim.api.nvim_list_tabpages() > 1 then
				vim.api.nvim_set_current_tabpage(guard)
				vim.cmd("tabclose!")
			end
		end)
		defer(drop_pi_bufs)
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "guard" })
		return fn(guard, defer)
	end)
end

local function owned_window(defer, own_buffer)
	local win = vim.api.nvim_get_current_win()
	if own_buffer then
		scratch[#scratch + 1] = vim.api.nvim_get_current_buf()
	end
	defer(function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end)
	return win
end

return {
	["hide closes windows but keeps buffers and the input draft"] = function()
		guarded(function()
			layout.open()
			local transcript = assert(layout.transcript_buf())
			local input = assert(layout.input_buf())
			vim.api.nvim_buf_set_lines(input, 0, -1, false, { "unfinished draft" })

			layout.hide()
			h.eq(false, layout.is_open())
			h.eq(0, windows_showing(transcript), "the transcript window closed")
			h.eq(0, windows_showing(input), "the input window closed")
			h.ok(vim.api.nvim_buf_is_valid(transcript), "the transcript buffer remains")
			h.ok(vim.api.nvim_buf_is_valid(input), "the input buffer remains")

			layout.hide()
			layout.open()
			h.eq(transcript, layout.transcript_buf(), "the same transcript buffer returns")
			h.eq(input, layout.input_buf(), "the same input buffer returns")
			h.eq({ "unfinished draft" }, vim.api.nvim_buf_get_lines(input, 0, -1, false))
		end)
	end,

	["destroy removes buffers and tolerates partial layouts"] = function()
		guarded(function()
			layout.open()
			local transcript = assert(layout.transcript_buf())
			local input = assert(layout.input_buf())
			vim.api.nvim_win_close(assert(layout.input_win()), true)

			layout.destroy()
			h.eq(false, layout.is_open())
			h.eq(nil, layout.transcript_buf())
			h.eq(nil, layout.input_buf())
			h.eq(false, vim.api.nvim_buf_is_valid(transcript))
			h.eq(false, vim.api.nvim_buf_is_valid(input))
			layout.destroy()
		end)
	end,

	["ownership detection distinguishes pim from other UI"] = function()
		guarded(function()
			layout.open()
			h.eq(false, layout.owns_only_ui(), "the guard tab is separate UI")
		end)

		-- The only-UI case is isolated so unrelated parent tabs are never closed.
		h.with_cleanup(function(defer)
			local child = vim.fn.jobstart({ vim.v.progpath, "--clean", "--headless", "--embed" }, { rpc = true })
			h.ok(child > 0)
			defer(function()
				vim.fn.jobstop(child)
				h.ok(vim.fn.jobwait({ child }, 3000)[1] ~= -1, "child exit was awaited")
			end)
			local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
			h.eq(
				true,
				vim.rpcrequest(
					child,
					"nvim_exec_lua",
					[[
				vim.opt.rtp:prepend(...)
				local layout = require('pim.ui.layout')
				local foldtext = vim.api.nvim_get_option_value('foldtext', {scope='global'})
				local fixed = vim.api.nvim_get_option_value('winfixheight', {scope='global'})
				layout.open()
				assert(layout.owns_only_ui())
				layout.destroy()
				assert(not layout.owns_only_ui())
				assert(#vim.api.nvim_list_wins() == 1)
				assert(vim.wo.foldtext == foldtext)
				assert(vim.wo.winfixheight == fixed)
				return true
			]],
					{ root }
				)
			)
		end)
	end,

	["a buffer whose name merely contains ours is left alone"] = function()
		guarded(function()
			drop_pi_bufs()
			local decoy = user_buf("my-pim://pi transcript-scratch")
			vim.bo[decoy].modified = true

			layout.open()

			h.ok(vim.api.nvim_buf_is_valid(decoy), "the user's buffer survived :PiStart")
			h.eq({ "unsaved work" }, vim.api.nvim_buf_get_lines(decoy, 0, -1, false), "with its content intact")

			h.eq(TRANSCRIPT, name_of(assert(layout.transcript_buf())))
			h.eq(INPUT, name_of(assert(layout.input_buf())))
		end)
	end,

	["a leftover pi buffer of the same name is reclaimed"] = function()
		guarded(function()
			drop_pi_bufs()
			local leftover = vim.api.nvim_create_buf(false, true)
			scratch[#scratch + 1] = leftover
			vim.b[leftover].pim_role = "transcript"
			vim.api.nvim_buf_set_name(leftover, TRANSCRIPT)

			layout.open()

			h.ok(not vim.api.nvim_buf_is_valid(leftover), "the stale pi buffer was reclaimed")
			h.eq(TRANSCRIPT, name_of(assert(layout.transcript_buf())), "so the canonical name is reused, not suffixed")
		end)
	end,

	["a name collision with a user buffer picks a free suffix"] = function()
		guarded(function()
			drop_pi_bufs()
			local held = user_buf(TRANSCRIPT)
			local held_2 = user_buf(TRANSCRIPT .. " (2)")

			layout.open()

			h.eq(TRANSCRIPT .. " (3)", name_of(assert(layout.transcript_buf())), "walked past both taken names")
			h.ok(vim.api.nvim_buf_is_valid(held), "the user's buffer was not taken")
			h.ok(vim.api.nvim_buf_is_valid(held_2), "nor the one holding the first suffix")

			drop_pi_bufs()
			local held_3 = user_buf(TRANSCRIPT .. " (3)")

			layout.open()

			h.eq(TRANSCRIPT .. " (4)", name_of(assert(layout.transcript_buf())), "and past the third")
			h.ok(vim.api.nvim_buf_is_valid(held_3), "the third user buffer was not taken either")
		end)
	end,

	["closing the transcript alone is repaired, not duplicated"] = function()
		guarded(function()
			layout.open()
			local pi_tab = vim.api.nvim_get_current_tabpage()
			local input_win = assert(layout.input_win())
			local tabs = #vim.api.nvim_list_tabpages()

			vim.api.nvim_win_close(assert(layout.transcript_win()), true)
			layout.open()

			h.eq(tabs, #vim.api.nvim_list_tabpages(), "no second pi tab was built")
			h.eq(input_win, assert(layout.input_win()), "the surviving input window was reused, not replaced")
			h.eq(
				pi_tab,
				vim.api.nvim_win_get_tabpage(assert(layout.transcript_win())),
				"the replacement went in beside it"
			)
			h.eq(1, windows_showing(assert(layout.input_buf())), "exactly one window shows the input buffer")
			h.eq(1, windows_showing(assert(layout.transcript_buf())), "and exactly one shows the transcript")
			h.ok(layout.is_open(), "the layout is whole again")
		end)
	end,

	["closing the input alone is repaired, not duplicated"] = function()
		guarded(function()
			layout.open()
			local pi_tab = vim.api.nvim_get_current_tabpage()
			local transcript_win = assert(layout.transcript_win())
			local tabs = #vim.api.nvim_list_tabpages()

			vim.api.nvim_win_close(assert(layout.input_win()), true)
			layout.open()

			h.eq(tabs, #vim.api.nvim_list_tabpages(), "no second pi tab was built")
			h.eq(transcript_win, assert(layout.transcript_win()), "the surviving transcript window was reused")
			h.eq(pi_tab, vim.api.nvim_win_get_tabpage(assert(layout.input_win())), "the replacement went in beside it")
			h.eq(1, windows_showing(assert(layout.transcript_buf())), "exactly one window shows the transcript")
			h.eq(1, windows_showing(assert(layout.input_buf())), "and exactly one shows the input buffer")
			h.eq(assert(layout.input_win()), vim.api.nvim_get_current_win(), "and open() lands in it")
		end)
	end,

	["new windows do not inherit pim window options"] = function()
		guarded(function(_, defer)
			local foldtext = vim.api.nvim_get_option_value("foldtext", { scope = "global" })
			local linebreak = vim.api.nvim_get_option_value("linebreak", { scope = "global" })
			local fillchars = vim.api.nvim_get_option_value("fillchars", { scope = "global" })
			local winfixheight = vim.api.nvim_get_option_value("winfixheight", { scope = "global" })
			layout.open()
			local transcript = assert(layout.transcript_win())
			local input = assert(layout.input_win())
			h.eq(foldtext, vim.api.nvim_get_option_value("foldtext", { scope = "global" }))
			h.eq(linebreak, vim.api.nvim_get_option_value("linebreak", { scope = "global" }))
			h.eq(fillchars, vim.api.nvim_get_option_value("fillchars", { scope = "global" }))
			h.eq(winfixheight, vim.api.nvim_get_option_value("winfixheight", { scope = "global" }))

			vim.api.nvim_set_current_win(transcript)
			vim.cmd("split")
			local ordinary = owned_window(defer)
			h.eq(foldtext, vim.api.nvim_get_option_value("foldtext", { win = ordinary }))
			h.eq(fillchars, vim.api.nvim_get_option_value("fillchars", { win = ordinary }))
			h.eq(linebreak, vim.api.nvim_get_option_value("linebreak", { win = ordinary }))
			h.eq(
				"v:lua.require'pim.ui.transcript'.foldtext()",
				vim.api.nvim_get_option_value("foldtext", { win = transcript })
			)
			vim.api.nvim_win_close(ordinary, true)

			vim.api.nvim_set_current_win(transcript)
			vim.cmd("wincmd n")
			ordinary = owned_window(defer, true)
			h.eq(foldtext, vim.api.nvim_get_option_value("foldtext", { win = ordinary }), "<C-w><C-n> is clean")
			vim.api.nvim_win_close(ordinary, true)

			vim.api.nvim_set_current_win(input)
			vim.cmd("new")
			ordinary = owned_window(defer, true)
			h.eq(winfixheight, vim.api.nvim_get_option_value("winfixheight", { win = ordinary }))
			h.eq(linebreak, vim.api.nvim_get_option_value("linebreak", { win = ordinary }))
			h.eq(true, vim.api.nvim_get_option_value("winfixheight", { win = input }))
			vim.api.nvim_win_close(ordinary, true)

			vim.api.nvim_set_current_win(transcript)
			vim.cmd("tabnew")
			ordinary = owned_window(defer, true)
			h.eq(foldtext, vim.api.nvim_get_option_value("foldtext", { win = ordinary }))
			h.eq(fillchars, vim.api.nvim_get_option_value("fillchars", { win = ordinary }))
			vim.cmd("tabclose")
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
		}
		local WRONG = {
			wrap = false,
			linebreak = false,
			foldenable = false,
			foldmethod = "indent",
			foldtext = "",
			fillchars = "",
		}

		guarded(function()
			layout.open()
			local pi_tab = vim.api.nvim_get_current_tabpage()
			local input_win = assert(layout.input_win())

			vim.api.nvim_win_close(assert(layout.transcript_win()), true)

			vim.api.nvim_buf_delete(assert(layout.transcript_buf()), { force = true })
			for name, value in pairs(WRONG) do
				vim.api.nvim_set_option_value(name, value, { win = input_win, scope = "local" })
			end

			layout.open()

			local win = assert(layout.transcript_win())
			h.eq(pi_tab, vim.api.nvim_win_get_tabpage(win), "repaired in place, so these are the repair's own options")

			for name, value in pairs(WANTED) do
				h.eq(value, vim.api.nvim_get_option_value(name, { win = win }), name)
			end

			local min_height = require("pim.config").get().input.min_height
			h.eq(
				min_height,
				vim.api.nvim_win_get_height(assert(layout.input_win())),
				"the input window is back to its height"
			)
		end)
	end,

	["repair works when focus is in an unrelated window"] = function()
		guarded(function(guard)
			layout.open()
			local pi_tab = vim.api.nvim_get_current_tabpage()

			for _, closed in ipairs({ "input", "transcript" }) do
				vim.api.nvim_win_close(
					closed == "input" and assert(layout.input_win()) or assert(layout.transcript_win()),
					true
				)

				vim.api.nvim_set_current_tabpage(guard)
				local bystander = vim.api.nvim_get_current_win()

				layout.open()

				local why = "after closing the " .. closed
				h.eq(1, #vim.api.nvim_tabpage_list_wins(guard), why .. ": the unrelated tab was not split")
				h.ok(vim.api.nvim_win_is_valid(bystander), why .. ": its window is untouched")
				h.eq(
					pi_tab,
					vim.api.nvim_win_get_tabpage(assert(layout.input_win())),
					why .. ": repaired into the pi tab"
				)
				h.eq(1, windows_showing(assert(layout.transcript_buf())), why .. ": one window shows the transcript")
				h.eq(1, windows_showing(assert(layout.input_buf())), why .. ": one window shows the input buffer")
			end
		end)
	end,
}
