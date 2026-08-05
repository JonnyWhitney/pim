local h = require("helpers")
local sessions = require("pim.sessions")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local fixtures = tests_dir .. "/fixtures"

local function read_lines(path)
	local file = assert(io.open(path, "r"))
	local content = file:read("*a")
	file:close()
	return vim.split(content, "\n", { plain = true, trimempty = true })
end

local function with_agent_dir(directory, fn)
	local original = vim.env.PI_CODING_AGENT_DIR
	vim.env.PI_CODING_AGENT_DIR = directory
	local ok, err = pcall(fn)
	vim.env.PI_CODING_AGENT_DIR = original
	if not ok then
		error(err, 0)
	end
end

return {
	["cwd encoding matches pi's real directory naming"] = function()
		h.eq(
			"--Users-jonathanloughlin-proj-PiExtentions-pim--",
			sessions.encode_cwd("/Users/jonathanloughlin/proj/PiExtentions/pim")
		)
	end,

	["session directory uses PI_CODING_AGENT_DIR"] = function()
		with_agent_dir("/tmp/pim-agent", function()
			h.eq("/tmp/pim-agent/sessions/--tmp-proj--", sessions.dir_for("/tmp/proj"))
		end)
	end,

	["named session parses header, name, count, and preview"] = function()
		local info = sessions.parse_lines(read_lines(fixtures .. "/session_named.jsonl"))
		h.ok(info, "fixture must parse")
		---@cast info
		h.eq("aaaa-1111", info.id)
		h.eq("/tmp/proj", info.cwd)
		h.eq("parser work", info.name)
		h.eq(3, info.message_count)
		h.eq("fix the parser bug", info.preview)
	end,

	["unnamed session falls back to a truncated one-line preview"] = function()
		local info = sessions.parse_lines(read_lines(fixtures .. "/session_unnamed.jsonl"))
		h.ok(info, "fixture must parse")
		---@cast info
		h.eq(nil, info.name)
		h.eq(1, info.message_count)
		h.ok(info.preview:find("hello there second line", 1, true) == 1, "newlines collapsed")
		h.ok(info.preview:find("…", 1, true), "long preview truncated")
	end,

	["non-session files are rejected"] = function()
		h.eq(nil, sessions.parse_lines(read_lines(fixtures .. "/not_a_session.jsonl")))
		h.eq(nil, sessions.parse_lines({}))
		h.eq(nil, sessions.parse_lines({ "garbage not json" }))
	end,

	["list_dir returns parseable sessions only"] = function()
		local found = sessions.list_dir(fixtures)
		h.eq(2, #found)
		local ids = { found[1].id, found[2].id }
		table.sort(ids)
		h.eq({ "aaaa-1111", "bbbb-2222" }, ids)
		h.ok(found[1].path:find("%.jsonl$"), "entries carry their path")
	end,

	["list_dir of a missing directory is empty"] = function()
		h.eq({}, sessions.list_dir(fixtures .. "/does-not-exist"))
	end,

	["end-to-end: picker switch cold-renders the target session"] = function()
		local client = require("pim.rpc.client")
		local config = require("pim.config")
		local layout = require("pim.ui.layout")
		config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" } })
		require("pim").start()

		local original_list = sessions.list
		local original_select = vim.ui.select
		---@diagnostic disable-next-line: duplicate-set-field
		sessions.list = function()
			return {
				{ id = "switched-session", path = "/tmp/fake.jsonl", mtime = 0, message_count = 2, name = "old work" },
			}
		end
		---@diagnostic disable-next-line: duplicate-set-field
		vim.ui.select = function(items, _, on_choice)
			on_choice(items[1])
		end

		require("pim.ui.pickers").session()

		local ok, err = pcall(h.wait_until, function()
			local lines = vim.api.nvim_buf_get_lines(layout.transcript_buf(), 0, -1, false)
			return table.concat(lines, "\n"):find("old answer", 1, true) ~= nil
		end, "the switched session history to cold-render into the transcript", 10000)

		sessions.list = original_list
		vim.ui.select = original_select

		h.ok(ok, tostring(err))
	end,
}
