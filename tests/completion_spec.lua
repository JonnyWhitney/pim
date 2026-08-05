local h = require("helpers")
local client = require("pim.rpc.client")
local completion = require("pim.completion")
local config = require("pim.config")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function refresh_from_fake_pi()
	config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" } })
	client.start({})
	completion.refresh_commands()
	h.wait_until(function()
		return #completion.omnifunc(0, "/") > 0
	end, "the slash-command cache to fill", 5000)
end

---@return string
local function fixture_repo()
	local repo = vim.fn.tempname()
	vim.fn.mkdir(repo .. "/lua/pim", "p")
	vim.system({ "git", "init", "-q", repo }):wait()
	vim.fn.writefile({ "*.log" }, repo .. "/.gitignore")
	vim.fn.writefile({ "-- source" }, repo .. "/lua/pim/completion.lua")
	vim.fn.writefile({ "-- source" }, repo .. "/lua/pim/config.lua")
	vim.fn.writefile({ "noise" }, repo .. "/ignored-scratch.log")
	return repo
end

return {
	["slash context: only at the very start of the prompt"] = function()
		h.eq(0, (completion.parse_context("/mo", 3, 1)))
		h.eq(0, (completion.parse_context("/", 1, 1)))
		h.eq(nil, (completion.parse_context("/cmd arg", 8, 1)), "args are not completed")
		h.eq(nil, (completion.parse_context("hello /x", 8, 1)), "not at start of line")
		h.eq(nil, (completion.parse_context("/mo", 3, 2)), "not on the first line")
	end,

	["file context: @ at BOL or after whitespace"] = function()
		local start, kind = completion.parse_context("see @lua/nv", 11, 2)
		h.eq(4, start)
		h.eq("file", kind)
		h.eq(0, (completion.parse_context("@src", 4, 1)))
		h.eq(nil, (completion.parse_context("mail me a@b.com", 15, 1)), "no email false positive")
		h.eq(nil, (completion.parse_context("see @a b", 8, 1)), "space ends the context")
	end,

	["slash matches filter by prefix and tolerate both source shapes"] = function()
		refresh_from_fake_pi()

		local all = completion.omnifunc(0, "/")
		h.eq(3, #all)

		local rpc = completion.omnifunc(0, "/rpc")
		h.eq(1, #rpc)
		h.eq("/rpc-select", rpc[1].word)
		h.eq("extension", rpc[1].menu)
		h.eq("Demo select dialog", rpc[1].info)

		local legacy = completion.omnifunc(0, "/legacy")
		h.eq("skill", legacy[1].menu, "source read from sourceInfo when the flat field is absent")
	end,

	["file candidates come from git and respect the prefix"] = function()
		local repo = fixture_repo()
		h.eq({ "lua/pim/completion.lua" }, completion.file_candidates("lua/pim/comp", repo))
		h.eq(
			{ "lua/pim/completion.lua", "lua/pim/config.lua" },
			completion.file_candidates("lua/pim/", repo),
			"both siblings offered for the shared prefix"
		)
		vim.fn.delete(repo, "rf")
	end,

	["gitignored files are not offered"] = function()
		local repo = fixture_repo()
		h.eq({ ".gitignore" }, completion.file_candidates(".git", repo), "the scan works")
		h.eq({}, completion.file_candidates("ignored-scratch", repo), "*.log is excluded")
		vim.fn.delete(repo, "rf")
	end,

	["@ completions carry the sigil through to the menu"] = function()
		local real = completion.file_candidates
		---@diagnostic disable-next-line: duplicate-set-field
		completion.file_candidates = function(prefix)
			return { prefix .. "one.lua", prefix .. "two.lua" }
		end
		local ok, items = pcall(completion.omnifunc, 0, "@src/")
		completion.file_candidates = real
		h.ok(ok, tostring(items))

		h.eq({
			{ word = "@src/one.lua", menu = "file" },
			{ word = "@src/two.lua", menu = "file" },
		}, items)
	end,
}
