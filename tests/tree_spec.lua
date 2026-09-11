local h = require("helpers")
local client = require("pim.rpc.client")
local config = require("pim.config")
local input = require("pim.ui.input")
local layout = require("pim.ui.layout")
local state = require("pim.state")
local tree = require("pim.ui.tree")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function start_pim()
	config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" } })
	require("pim").start()
	h.wait_until(function()
		return state.get().connected
	end, "pim to connect", 5000)
end

local function feed(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function transcript_text()
	return table.concat(vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false), "\n")
end

return {
	["hidden leaves and entirely hidden trees keep selection safe"] = function()
		layout.open()
		local real_get_tree = client.get_tree
		local ok, err = pcall(function()
			for _, visible in ipairs({ true, false }) do
				local hidden = { entry = { type = "compaction", id = "hidden" } }
				local nodes = visible
						and {
							{
								entry = {
									type = "message",
									id = "prompt",
									message = { role = "user", content = "Visible prompt" },
								},
								children = { hidden },
							},
						}
					or { hidden }
				---@diagnostic disable-next-line: duplicate-set-field
				client.get_tree = function(callback)
					callback(true, { tree = nodes, leafId = "hidden" })
				end
				tree.open()
				if visible then
					h.eq("prompt", tree.selected().id)
					tree.preview()
					h.ok(transcript_text():find("Visible prompt", 1, true))
					tree.return_to_tree()
					h.eq("prompt", tree.selected().id)
				else
					h.eq(nil, tree.selected())
					tree.preview()
					tree.fork_selected()
					h.ok(transcript_text():find("No entries in this session.", 1, true))
				end
				tree.reset()
			end
		end)
		client.get_tree = real_get_tree
		if not ok then
			error(err, 0)
		end
	end,

	["compaction blocks tree opening and session changes"] = function()
		local real_notify = vim.notify
		local notices = {}
		vim.notify = function(message)
			notices[#notices + 1] = message
		end
		local ok, err = pcall(function()
			state.handle_event({ type = "compaction_start" })
			h.eq(true, state.is_busy())
			tree.open()
			require("pim.sessions").clone()
			h.eq(false, tree.is_open())
			h.eq(2, #notices)
			state.handle_event({ type = "compaction_end" })
			h.eq(false, state.is_busy())
		end)
		vim.notify = real_notify
		if not ok then
			error(err, 0)
		end
	end,
	["tree renders session branches and locks the input"] = function()
		start_pim()
		tree.open()
		h.wait_until(tree.is_open, "the tree to open", 5000)

		local rendered = transcript_text()
		h.ok(rendered:find("# pi tree", 1, true), "tree heading renders")
		h.ok(rendered:find("Fix the parser error [parser work]", 1, true), "labels render")
		h.ok(rendered:find("●", 1, true), "active leaf is marked")
		h.eq(false, vim.bo[assert(layout.input_buf())].modifiable)
		h.eq(assert(layout.transcript_win()), vim.api.nvim_get_current_win(), "tree receives focus")

		local start_line = vim.api.nvim_win_get_cursor(assert(layout.transcript_win()))[1]
		feed("j")
		h.eq(
			start_line + 1,
			vim.api.nvim_win_get_cursor(assert(layout.transcript_win()))[1],
			"j moves to the next entry"
		)
		feed("k")
		h.eq(
			start_line,
			vim.api.nvim_win_get_cursor(assert(layout.transcript_win()))[1],
			"k moves to the previous entry"
		)
	end,

	["p previews the selected entry and q returns to the tree"] = function()
		start_pim()
		tree.open()
		h.wait_until(tree.is_open, "the tree to open", 5000)

		feed("jjp")
		h.wait_until(function()
			return transcript_text():find("# pi tree preview", 1, true) ~= nil
		end, "the preview to open", 5000)
		h.ok(transcript_text():find("Fix the parser error", 1, true), "preview shows the selected conversation")
		h.eq(true, tree.is_open(), "preview keeps tree mode active")
		h.eq(false, vim.bo[assert(layout.input_buf())].modifiable, "preview keeps the input locked")

		feed("q")
		h.wait_until(function()
			return transcript_text():find("# pi tree", 1, true) ~= nil
		end, "the tree to return", 5000)
		h.eq("tree-3", tree.selected().id, "the selected entry is preserved")
	end,

	["r forks the selected user prompt"] = function()
		start_pim()
		tree.open()
		h.wait_until(tree.is_open, "the tree to open", 5000)

		feed("jjr")
		h.wait_until(function()
			return not tree.is_open()
				and state.get().session_id == "forked-session"
				and table.concat(vim.api.nvim_buf_get_lines(assert(layout.input_buf()), 0, -1, false), "\n")
					== "Fix the parser error"
		end, "the selected prompt to fork", 5000)
	end,

	["c clones the active branch"] = function()
		start_pim()
		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "discard this draft" })
		tree.open()
		h.wait_until(tree.is_open, "the tree to open", 5000)

		feed("c")
		h.wait_until(function()
			return not tree.is_open()
				and state.get().session_id == "cloned-session"
				and table.concat(vim.api.nvim_buf_get_lines(assert(layout.input_buf()), 0, -1, false), "\n") == ""
		end, "the active branch to clone", 5000)
	end,

	["external session actions are blocked while the tree is open"] = function()
		start_pim()
		tree.open()
		h.wait_until(tree.is_open, "the tree to open", 5000)

		local calls = 0
		local real_clone = client.clone
		---@diagnostic disable-next-line: duplicate-set-field
		client.clone = function()
			calls = calls + 1
		end
		local notified
		local real_notify = vim.notify
		vim.notify = function(message)
			notified = message
		end

		local ok, err = pcall(require("pim.sessions").clone)
		client.clone = real_clone
		vim.notify = real_notify
		if not ok then
			error(err, 0)
		end

		h.eq(0, calls)
		h.eq(true, tree.is_open())
		h.ok(notified:find("Close the tree", 1, true), "blocked action explains how to continue")
	end,

	["tree blocks prompt submission and q restores the active transcript"] = function()
		start_pim()
		tree.open()
		h.wait_until(tree.is_open, "the tree to open", 5000)

		local calls = 0
		local real_prompt = client.prompt
		---@diagnostic disable-next-line: duplicate-set-field
		client.prompt = function()
			calls = calls + 1
		end
		local notified
		local real_notify = vim.notify
		vim.notify = function(message)
			notified = message
		end

		local ok, err = pcall(function()
			input.send("do not send")
		end)
		client.prompt = real_prompt
		vim.notify = real_notify
		if not ok then
			error(err, 0)
		end

		h.eq(0, calls)
		h.ok(notified:find("Close the tree", 1, true), "blocked send explains how to continue")

		feed("q")
		h.wait_until(function()
			return not tree.is_open() and vim.bo[assert(layout.input_buf())].modifiable
		end, "the tree to close", 5000)
	end,

	["enter closes the tree"] = function()
		start_pim()
		tree.open()
		h.wait_until(tree.is_open, "the tree to open", 5000)

		feed("<CR>")
		h.wait_until(function()
			return not tree.is_open() and vim.bo[assert(layout.input_buf())].modifiable
		end, "enter to close the tree", 5000)
	end,

	["tree does not open before an agent run settles"] = function()
		state.handle_event({ type = "agent_start" })
		state.handle_event({ type = "agent_end", willRetry = false })
		local calls = 0
		local real_get_tree = client.get_tree
		---@diagnostic disable-next-line: duplicate-set-field
		client.get_tree = function()
			calls = calls + 1
		end
		local notified
		local real_notify = vim.notify
		vim.notify = function(message)
			notified = message
		end

		local ok, err = pcall(tree.open)
		client.get_tree = real_get_tree
		vim.notify = real_notify
		if not ok then
			error(err, 0)
		end

		h.eq(0, calls)
		h.ok(notified:find("while pi is busy", 1, true), "busy state explains why tree is unavailable")
	end,
}
