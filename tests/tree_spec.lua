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

	["pi responses are folded by default and can be inspected individually"] = function()
		layout.open()
		local real_get_tree = client.get_tree
		local ok, err = pcall(function()
			local function message(id, role, content, children)
				return {
					entry = {
						type = "message",
						id = id,
						message = { role = role, content = { { type = "text", text = content } } },
					},
					children = children,
				}
			end
			local nodes = {
				message("prompt", "user", "Start ``` fenced ``` text", {
					message("first", "assistant", "First answer", {
						message("result", "toolResult", "Output", {
							message("second", "assistant", "Second answer", {
								message("followup", "user", "Continue"),
							}),
						}),
					}),
				}),
			}
			nodes[1].children[1].entry.message.content = {
				{ type = "thinking", thinking = "Look at the file" },
				{ type = "toolCall", id = "call-1", name = "read", arguments = { path = "a.lua" } },
			}
			nodes[1].children[1].children[1].entry.message.toolName = "read"
			---@diagnostic disable-next-line: duplicate-set-field
			client.get_tree = function(callback)
				callback(true, { tree = nodes, leafId = "followup" })
			end
			tree.open()
			h.eq("text", vim.bo[assert(layout.transcript_buf())].filetype, "tree text is not parsed as Markdown")
			local win = assert(layout.transcript_win())
			local lines = vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false)
			local group_line
			for line, text in ipairs(lines) do
				if text == "  pi: [response] x 2" then
					group_line = line
				end
			end
			h.ok(group_line, "response group is rendered")
			h.ok(transcript_text():find("Start ``` fenced ``` text", 1, true), "backticks remain literal")
			h.eq("    pi: [thinking]", lines[group_line + 1])
			h.eq("    pi: [tool call - read]", lines[group_line + 2])
			h.eq("    pi: [result - read]", lines[group_line + 3])
			h.eq("    pi: Second answer", lines[group_line + 4])
			h.eq(
				group_line,
				vim.api.nvim_win_call(win, function()
					return vim.fn.foldclosed(group_line + 1)
				end),
				"responses are closed by default"
			)
			feed("j")
			h.eq("second", tree.selected().id, "the group selects the last response")
			feed("j")
			h.eq("followup", tree.selected().id, "closed responses are skipped")
			feed("k")
			feed("zo")
			feed("j")
			h.eq("first", tree.selected().id, "an expanded response can be selected")
			feed("j")
			h.eq("first", tree.selected().id, "both blocks belong to the same response")
			feed("j")
			h.eq("result", tree.selected().id, "the tool result can be selected")
			feed("k")
			tree.preview()
			h.eq("markdown", vim.bo[assert(layout.transcript_buf())].filetype, "previews use Markdown")
			h.ok(transcript_text():find("read", 1, true), "the selected tool call can be previewed")
			tree.return_to_tree()
			h.eq("text", vim.bo[assert(layout.transcript_buf())].filetype, "tree text is restored")
			h.eq("first", tree.selected().id, "the expanded selection survives preview")
			tree.reset()
			h.eq("markdown", vim.bo[assert(layout.transcript_buf())].filetype, "transcript syntax is restored")
		end)
		client.get_tree = real_get_tree
		if not ok then
			tree.reset()
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
	["tree renders flat entries and locks the input"] = function()
		start_pim()
		tree.open()
		h.wait_until(tree.is_open, "the tree to open", 5000)

		local rendered = transcript_text()
		h.ok(rendered:find("# pi tree", 1, true), "tree heading renders")
		h.ok(rendered:find("  You: Fix the parser error [parser work]", 1, true), "labels render without indentation")
		h.ok(not rendered:find("└─", 1, true) and not rendered:find("├─", 1, true), "branches are not drawn")
		h.ok(rendered:find("●", 1, true), "active leaf is marked")
		local lines = vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false)
		for line, text in ipairs(lines) do
			if text == "  pi: [response]" then
				h.eq(
					line,
					vim.api.nvim_win_call(assert(layout.transcript_win()), function()
						return vim.fn.foldclosed(line + 1)
					end),
					"a single pi response is folded"
				)
				break
			end
		end
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
		local marks = vim.api.nvim_buf_get_extmarks(
			assert(layout.transcript_buf()),
			vim.api.nvim_get_namespaces()["pim-transcript-decorations"],
			0,
			-1,
			{ details = true }
		)
		h.ok(#marks > 0, "preview messages are decorated through the shared transcript store")
		h.eq("markdown", vim.bo[assert(layout.transcript_buf())].filetype)
		h.eq(true, tree.is_open(), "preview keeps tree mode active")
		h.eq(false, vim.bo[assert(layout.input_buf())].modifiable, "preview keeps the input locked")

		feed("q")
		h.wait_until(function()
			return transcript_text():find("# pi tree", 1, true) ~= nil
		end, "the tree to return", 5000)
		h.eq("tree-3", tree.selected().id, "the selected entry is preserved")
		h.eq(
			{},
			vim.api.nvim_buf_get_extmarks(
				assert(layout.transcript_buf()),
				vim.api.nvim_get_namespaces()["pim-transcript-decorations"],
				0,
				-1,
				{}
			),
			"preview decorations are cleared on return to the tree"
		)
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
		h.eq("markdown", vim.bo[assert(layout.transcript_buf())].filetype, "closing restores Markdown")
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
