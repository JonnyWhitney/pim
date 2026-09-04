local h = require("helpers")
local config = require("pim.config")
local layout = require("pim.ui.layout")
local transcript = require("pim.ui.transcript")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function fresh()
	layout.open()
end

local function buffer_lines()
	return vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false)
end

local function block(lines)
	return { lines = lines, folds = {} }
end

return {
	["blocks append in order with separators"] = function()
		fresh()
		transcript.set("a", "message", block({ "A1", "A2" }), { final = true })
		transcript.set("b", "message", block({ "B1" }), { final = true })
		h.eq({ "A1", "A2", "", "B1", "" }, buffer_lines())
	end,

	["growing a block keeps its neighbours intact"] = function()
		fresh()
		transcript.set("a", "message", block({ "A" }), { final = true })
		transcript.set("b", "message", block({ "B" }), { final = true })
		transcript.set("a", "message", block({ "A1", "A2", "A3" }), { final = true })
		h.eq({ "A1", "A2", "A3", "", "B", "" }, buffer_lines())
	end,

	["shrinking a block keeps its neighbours intact"] = function()
		fresh()
		transcript.set("a", "message", block({ "A1", "A2", "A3" }), { final = true })
		transcript.set("b", "message", block({ "B" }), { final = true })
		transcript.set("a", "message", block({ "A" }), { final = true })
		h.eq({ "A", "", "B", "" }, buffer_lines())
	end,

	["streaming updates coalesce through the flush timer"] = function()
		fresh()
		transcript.set("live", "message", block({ "one" }))
		h.eq({ "" }, buffer_lines())
		transcript.set("live", "message", block({ "one two" }))
		h.wait_until(function()
			return buffer_lines()[1] == "one two"
		end, "the timer flush to write the latest content", 1000)
		h.eq({ "one two", "" }, buffer_lines())
	end,

	["final set flushes immediately, skipping the timer"] = function()
		fresh()
		transcript.set("a", "message", block({ "done" }), { final = true })
		h.eq({ "done", "" }, buffer_lines())
	end,

	["divider appends a rule"] = function()
		fresh()
		transcript.set("a", "message", block({ "A" }), { final = true })
		transcript.divider()
		h.eq({ "A", "", "---", "" }, buffer_lines())
	end,

	["reset clears buffer and block state"] = function()
		fresh()
		transcript.set("a", "message", block({ "A" }), { final = true })
		transcript.reset()
		h.eq({ "" }, buffer_lines())
		transcript.set("b", "message", block({ "B" }), { final = true })
		h.eq({ "B", "" }, buffer_lines())
	end,

	["wiping the transcript buffer re-anchors the blocks instead of raising"] = function()
		fresh()
		transcript.set("a", "message", block({ "A1", "A2" }), { final = true })

		local wiped = assert(layout.transcript_buf())
		vim.api.nvim_buf_delete(wiped, { force = true })
		layout.hide()
		layout.open()
		h.ok(assert(layout.transcript_buf()) ~= wiped, "layout built a replacement buffer")

		local appended, append_error = pcall(transcript.set, "b", "message", block({ "B1" }), { final = true })
		h.ok(appended, "appending after a wipe did not raise: " .. tostring(append_error))
		h.eq({ "A1", "A2", "", "B1", "" }, buffer_lines(), "the earlier conversation is restored too")

		local updated, update_error =
			pcall(transcript.set, "a", "message", block({ "A1", "A2", "A3" }), { final = true })
		h.ok(updated, "updating after a wipe did not raise: " .. tostring(update_error))
		h.eq({ "A1", "A2", "A3", "", "B1", "" }, buffer_lines(), "the update landed in place")
	end,

	["shutdown stops the pending flush timer"] = function()
		fresh()
		transcript.set("a", "message", block({ "A" }), { final = true })
		transcript.set("a", "message", block({ "A", "streaming…" }))

		transcript.shutdown()
		h.settle(150)

		h.eq({ "A", "" }, buffer_lines(), "the queued flush never ran")

		transcript.shutdown()
	end,

	["buffer is not modifiable from outside the store"] = function()
		fresh()
		transcript.set("a", "message", block({ "A" }), { final = true })
		h.fails(function()
			vim.api.nvim_buf_set_lines(assert(layout.transcript_buf()), 0, -1, false, { "vandalism" })
		end, "not.*modifiable")
	end,

	["thinking folds materialise on finalised blocks"] = function()
		fresh()
		transcript.set("a", "message", {
			lines = { "### pi", "", "▸ thinking", "> a", "> b", "", "answer" },
			folds = { { first = 2, last = 4, kind = "thinking" } },
		}, { final = true })

		local win = assert(layout.transcript_win())
		local closed = vim.api.nvim_win_call(win, function()
			return vim.fn.foldclosed(3)
		end)
		h.eq(3, closed, "fold should start closed at the thinking header")
	end,

	["queue display renders as virtual lines and clears when empty"] = function()
		fresh()
		transcript.set("a", "message", block({ "A" }), { final = true })
		transcript.set_queue({ "fix the tests" }, { "then lint" })

		local buf = assert(layout.transcript_buf())
		local queue_ns = vim.api.nvim_get_namespaces()["pim-queue"]
		local marks = vim.api.nvim_buf_get_extmarks(buf, queue_ns, 0, -1, { details = true })
		h.eq(1, #marks)
		local virt = assert(marks[1][4].virt_lines, "queue extmark must have virtual lines")
		h.eq("⏳ steer: fix the tests", virt[1][1][1])
		h.eq("⏳ follow-up: then lint", virt[2][1][1])

		transcript.set_queue({}, {})
		h.eq({}, vim.api.nvim_buf_get_extmarks(buf, queue_ns, 0, -1, {}))
	end,

	["end-to-end: tool run starts call and result folds closed"] = function()
		config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua", "tool" } })
		require("pim").start()
		transcript.reset()
		require("pim.events").reset()

		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "run ls" })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR><CR>", true, false, true), "x", false)

		h.wait_until(function()
			local lines = buffer_lines()
			return lines[#lines - 1] == "---"
		end, "the closing divider; buffer:\n" .. table.concat(buffer_lines(), "\n"), 10000)
		local snapshot = buffer_lines()
		local call_fold, result_fold = vim.api.nvim_win_call(assert(layout.transcript_win()), function()
			return vim.fn.foldclosed(7), vim.fn.foldclosed(14)
		end)

		h.eq({
			"### You",
			"",
			"run ls",
			"",
			"### pi",
			"",
			"▸ tool(bash): ls",
			"```json",
			"{",
			'  "command": "ls"',
			"}",
			"```",
			"",
			"▸ result(bash): ls",
			"```bash",
			"ls",
			"```",
			"```",
			"file-a",
			"file-b",
			"```",
			"",
			"### pi",
			"",
			"Two files.",
			"",
			"---",
			"",
		}, snapshot)
		h.eq(7, call_fold, "tool call fold should be closed at its header")
		h.eq(14, result_fold, "tool result fold should be closed at its header")
	end,

	["end-to-end: fake pi run renders user echo, assistant text, divider"] = function()
		config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" } })
		require("pim").start()
		transcript.reset()
		require("pim.events").reset()

		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "hello fake pi" })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR><CR>", true, false, true), "x", false)

		h.wait_until(function()
			local lines = buffer_lines()
			return lines[#lines - 1] == "---"
		end, "the closing divider; buffer:\n" .. table.concat(buffer_lines(), "\n"), 10000)
		local snapshot = buffer_lines()

		h.eq({
			"### You",
			"",
			"hello fake pi",
			"",
			"### pi",
			"",
			"Hello from fake pi",
			"",
			"---",
			"",
		}, snapshot)
	end,

	["end-to-end: a retried run draws exactly one divider"] = function()
		config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua", "retry" } })
		require("pim").start()
		transcript.reset()
		require("pim.events").reset()

		vim.api.nvim_buf_set_lines(assert(layout.input_buf()), 0, -1, false, { "hello fake pi" })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR><CR>", true, false, true), "x", false)

		h.wait_until(function()
			local lines = buffer_lines()
			return lines[#lines - 1] == "---"
		end, "the closing divider; buffer:\n" .. table.concat(buffer_lines(), "\n"), 10000)
		h.eq({
			"### You",
			"",
			"hello fake pi",
			"",
			"### pi",
			"",
			"Hello on the second try",
			"",
			"---",
			"",
		}, buffer_lines())
	end,
}
