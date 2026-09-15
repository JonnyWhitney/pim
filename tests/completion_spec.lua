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

local function with_files(git, fn)
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")
	local paths = {
		"ignored.log",
		"build/out.js",
		"nested/build/out.js",
		"node_modules/pkg/x.js",
		"nested/node_modules/pkg/x.js",
		"node_modules_backup/x.js",
		"tracked.log",
		"plain.txt",
		"nested/other.log",
		"config/private.json",
		"UPPER.LOG",
	}
	for _, path in ipairs(paths) do
		vim.fn.mkdir(vim.fs.dirname(root .. "/" .. path), "p")
		vim.fn.writefile({ "fixture" }, root .. "/" .. path)
	end
	if git then
		vim.system({ "git", "init", "-q", root }):wait()
		vim.system({ "git", "-C", root, "config", "core.excludesFile", "/dev/null" }):wait()
		vim.fn.writefile({ "*.log", "build/", "node_modules/" }, root .. "/.gitignore")
		vim.system({ "git", "-C", root, "add", "-f", "tracked.log" }):wait()
	end
	local cwd = vim.fn.getcwd()
	vim.cmd.cd(root)
	local ok, err = pcall(fn, root)
	vim.cmd.cd(cwd)
	vim.fn.delete(root, "rf")
	if not ok then
		error(err, 0)
	end
end

return {
	["Git filters and cache setting changes work together"] = function()
		with_files(true, function(root)
			local function offered(path)
				return vim.tbl_contains(completion.file_candidates("", root), path)
			end
			for _, respect in ipairs({ true, false, true }) do
				config.setup({ completion = { respect_gitignore = respect } })
				h.eq(not respect, offered("ignored.log"))
				h.eq(not respect, offered("build/out.js"))
				h.ok(offered("tracked.log"))
				h.ok(offered("plain.txt"))
				h.ok(offered("node_modules_backup/x.js"))
				h.eq(false, offered("node_modules/pkg/x.js"))
				h.eq(false, offered("nested/node_modules/pkg/x.js"))
				for _, path in ipairs(completion.file_candidates(".git", root)) do
					h.eq(".gitignore", path)
				end
			end
			config.setup({ completion = { respect_gitignore = false, exclude = {} } })
			h.ok(offered("node_modules/pkg/x.js"))
			h.ok(offered("nested/node_modules/pkg/x.js"))
			config.setup({
				completion = { respect_gitignore = false, exclude = { "*.log", "**/build/**", "config/private.json" } },
			})
			h.eq(false, offered("tracked.log"))
			h.eq(false, offered("ignored.log"))
			h.ok(offered("nested/other.log"))
			h.ok(offered("UPPER.LOG"))
			h.eq(false, offered("build/out.js"))
			h.eq(false, offered("nested/build/out.js"))
			h.eq(false, offered("config/private.json"))
			config.setup({ completion = { respect_gitignore = false, exclude = { "**/*.log" } } })
			h.eq(false, offered("nested/other.log"))
			vim.fn.writefile({ "new" }, root .. "/new.txt")
			h.eq(false, offered("new.txt"))
			completion.reset()
			h.ok(offered("new.txt"))
			h.eq({ { word = "@plain.txt", menu = "file" } }, completion.omnifunc(0, "@plain"))
			config.setup({ completion = { respect_gitignore = false, exclude = { "nested/*.log" } } })
			vim.cmd.cd(root .. "/nested")
			h.eq(
				{ "other.log" },
				completion.file_candidates("other", root .. "/nested"),
				"patterns are relative to cwd"
			)
		end)
	end,

	["non-Git and failed Git candidates share directory filtering"] = function()
		for _, git in ipairs({ false, true }) do
			with_files(git, function(root)
				local real_system, real_completion = vim.system, vim.fn.getcompletion
				---@diagnostic disable-next-line: duplicate-set-field
				vim.system = function()
					return {
						wait = function()
							return { code = 1 }
						end,
					}
				end
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.getcompletion = function()
					return {
						"node_modules",
						"node_modules/",
						"nested/node_modules/",
						"./node_modules/",
						"plain.txt",
						"node_modules_backup/",
					}
				end
				local ok, err = pcall(function()
					h.eq({ "plain.txt", "node_modules_backup/" }, completion.file_candidates("", root))
					config.setup({ completion = { exclude = {} } })
					h.eq(6, #completion.file_candidates("", root))
				end)
				vim.system, vim.fn.getcompletion = real_system, real_completion
				if not ok then
					error(err, 0)
				end
				config.setup()
				completion.reset()
			end)
		end
	end,

	["real non-Git directory completion is filtered"] = function()
		with_files(false, function()
			h.eq({ "node_modules_backup/" }, completion.file_candidates("node_modules"))
			h.eq({ "node_modules_backup/" }, completion.file_candidates("node_modules_b"))
		end)
	end,
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
