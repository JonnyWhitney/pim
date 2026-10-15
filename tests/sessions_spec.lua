local h = require("helpers")
local session_files = require("pim.session_files")
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
	["workflow listing delegates to session files"] = function()
		local expected = { { id = "session-1" } }
		h.with_cleanup(function(defer)
			local calls = 0
			h.patch(defer, session_files, "list", function()
				calls = calls + 1
				return expected
			end)
			h.eq(expected, sessions.list())
			h.eq(1, calls)
		end)
	end,

	["old application session APIs are removed"] = function()
		local pim = require("pim")
		h.eq(nil, pim.refresh)
		h.eq(nil, pim.new_session)
		h.eq(nil, pim.fork)
		h.eq(nil, pim.clone)
	end,

	["cwd encoding matches pi's real directory naming"] = function()
		h.eq(
			"--Users-jonathanloughlin-proj-PiExtentions-pim--",
			session_files.encode_cwd("/Users/jonathanloughlin/proj/PiExtentions/pim")
		)
	end,

	["session directory uses PI_CODING_AGENT_DIR"] = function()
		with_agent_dir("/tmp/pim-agent", function()
			h.eq("/tmp/pim-agent/sessions/--tmp-proj--", session_files.dir_for("/tmp/proj"))
		end)
	end,

	["named session parses header, name, count, and preview"] = function()
		local info =
			assert(session_files.parse_lines(read_lines(fixtures .. "/session_named.jsonl")), "fixture must parse")
		h.eq("aaaa-1111", info.id)
		h.eq("/tmp/proj", info.cwd)
		h.eq("parser work", info.name)
		h.eq(3, info.message_count)
		h.eq("fix the parser bug", info.preview)
	end,

	["unnamed session falls back to a truncated one-line preview"] = function()
		local info =
			assert(session_files.parse_lines(read_lines(fixtures .. "/session_unnamed.jsonl")), "fixture must parse")
		h.eq(nil, info.name)
		h.eq(1, info.message_count)
		local preview = assert(info.preview, "fixture must have a preview")
		h.ok(preview:find("hello there second line", 1, true) == 1, "newlines collapsed")
		h.ok(preview:find("…", 1, true), "long preview truncated")
	end,

	["session preview skips user messages without text"] = function()
		local info = assert(session_files.parse_lines({
			'{"type":"session","id":"one","timestamp":"now","cwd":"/tmp"}',
			'{"type":"message","message":{"role":"user","content":[{"type":"image","mimeType":"image/png"}]}}',
			'{"type":"message","message":{"role":"user","content":[{"type":"text","text":"later prompt"}]}}',
		}))
		h.eq("later prompt", info.preview)
	end,

	["non-session files are rejected"] = function()
		h.eq(nil, session_files.parse_lines(read_lines(fixtures .. "/not_a_session.jsonl")))
		h.eq(nil, session_files.parse_lines({}))
		h.eq(nil, session_files.parse_lines({ "garbage not json" }))
	end,

	["list_dir returns parseable sessions only"] = function()
		local found = session_files.list_dir(fixtures)
		h.eq(2, #found)
		local ids = { found[1].id, found[2].id }
		table.sort(ids)
		h.eq({ "aaaa-1111", "bbbb-2222" }, ids)
		h.ok(found[1].path:find("%.jsonl$"), "entries carry their path")
	end,

	["list_dir of a missing directory is empty"] = function()
		h.eq({}, session_files.list_dir(fixtures .. "/does-not-exist"))
	end,

	["end-to-end: picker switch cold-renders the target session"] = function()
		local config = require("pim.config")
		local layout = require("pim.ui.layout")
		config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" } })
		require("pim").start()

		h.with_cleanup(function(defer)
			h.patch(defer, sessions, "list", function()
				return {
					{
						id = "switched-session",
						path = "/tmp/fake.jsonl",
						mtime = 0,
						message_count = 2,
						name = "old work",
					},
				}
			end)
			h.patch(defer, vim.ui, "select", function(items, _, on_choice)
				on_choice(items[1])
			end)

			require("pim.ui.pickers").session()

			h.wait_until(function()
				local lines = vim.api.nvim_buf_get_lines(assert(layout.transcript_buf()), 0, -1, false)
				return table.concat(lines, "\n"):find("old answer", 1, true) ~= nil
			end, "the switched session history to cold-render into the transcript", 10000)
		end)
	end,
}
