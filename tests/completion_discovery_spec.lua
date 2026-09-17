local h = require("helpers")
local files = require("pim.completion.files")
local config = require("pim.config")

local function fixture(fn)
	local root = vim.fn.tempname()
	vim.fn.mkdir(root .. "/nested/deep", "p")
	vim.fn.writefile({ "test" }, root .. "/nested/deep/é-file.lua")
	local ok, err = pcall(fn, root)
	files.reset()
	vim.fn.delete(root, "rf")
	if not ok then
		error(err, 0)
	end
end

local function collect(root)
	local result
	files.request(root, function(paths)
		result = paths
	end)
	h.eq(nil, result, "delivery is scheduled")
	h.wait_until(function()
		return result ~= nil
	end, "complete discovery", 10000)
	return result
end

return {
	["async recursion and Git return identical owned lists"] = function()
		fixture(function(root)
			for _, git in ipairs({ false, true }) do
				if git then
					vim.system({ "git", "init", "-q", root }):wait()
				end
				files.reset()
				local paths = collect(root)
				h.eq({ "nested/deep/é-file.lua" }, paths)
				paths[1] = "mutated"
				h.eq({ "nested/deep/é-file.lua" }, collect(root))
				h.eq({ "nested/deep/é-file.lua" }, files.get(root))
			end
		end)
	end,

	["directory links and broken links are skipped"] = function()
		fixture(function(root)
			assert(vim.uv.fs_symlink(root, root .. "/nested/cycle", { dir = true }))
			assert(vim.uv.fs_symlink(root .. "/missing", root .. "/broken"))
			assert(vim.uv.fs_symlink(root .. "/nested/deep/é-file.lua", root .. "/alias.lua"))
			h.eq({ "alias.lua", "nested/deep/é-file.lua" }, collect(root))
		end)
	end,

	["cancel reset and stale contexts suppress callbacks and cache writes"] = function()
		fixture(function(root)
			for _, action in ipairs({ "cancel", "reset", "context", "settings", "cwd" }) do
				files.reset()
				local active, called = true, false
				local cancel = files.request(root, function()
					called = true
				end, function()
					return active
				end)
				local cwd = vim.fn.getcwd()
				if action == "cancel" then
					cancel()
				elseif action == "reset" then
					files.reset()
				elseif action == "context" then
					active = false
				elseif action == "settings" then
					config.setup({ completion = { exclude = { "**/*.lua" } } })
				else
					vim.cmd.cd(root)
				end
				h.settle(30)
				vim.cmd.cd(cwd)
				config.setup()
				h.eq(false, called, action)
				vim.fn.writefile({ "new" }, root .. "/new.txt")
				h.ok(vim.tbl_contains(collect(root), "new.txt"))
				vim.fn.delete(root .. "/new.txt")
			end
		end)
	end,

	["failed async Git and missing executable use recursive fallback"] = function()
		fixture(function(root)
			vim.system({ "git", "init", "-q", root }):wait()
			local original = vim.system
			local ok, err = pcall(function()
				for _, mode in ipairs({ "failure", "spawn" }) do
					files.reset()
					---@diagnostic disable-next-line: duplicate-set-field
					vim.system = function(_, _, callback)
						if mode == "spawn" then
							error("missing executable")
						end
						vim.schedule(function()
							callback({ code = 1 })
						end)
						return { kill = function() end }
					end
					h.ok(vim.tbl_contains(collect(root), "nested/deep/é-file.lua"))
				end
			end)
			vim.system = original
			if not ok then
				error(err, 0)
			end
		end)
	end,

	["in-flight Git is killed and late results are discarded"] = function()
		fixture(function(root)
			vim.system({ "git", "init", "-q", root }):wait()
			local original = vim.system
			local respond, killed, called
			---@diagnostic disable-next-line: duplicate-set-field
			vim.system = function(_, _, callback)
				respond = callback
				return {
					kill = function()
						killed = true
					end,
				}
			end
			local ok, err = pcall(function()
				local cancel = files.request(root, function()
					called = true
				end)
				h.wait_until(function()
					return respond ~= nil
				end, "Git process start")
				cancel()
				h.ok(killed)
				respond({ code = 0, stdout = "stale.txt\0" })
				h.settle(20)
				h.eq(nil, called)
			end)
			vim.system = original
			if not ok then
				error(err, 0)
			end
			h.eq({ "nested/deep/é-file.lua" }, collect(root))
		end)
	end,

	["unreadable and disappearing entries are skipped safely"] = function()
		fixture(function(root)
			local original_open, original_stat = vim.uv.fs_opendir, vim.uv.fs_lstat
			local ok, err = pcall(function()
				---@diagnostic disable-next-line: duplicate-set-field
				vim.uv.fs_opendir = function(path, ...)
					if path == root .. "/nested/deep" then
						return nil, "EACCES"
					end
					return original_open(path, ...)
				end
				h.eq({}, collect(root))
				vim.uv.fs_opendir = original_open
				files.reset()
				---@diagnostic disable-next-line: duplicate-set-field
				vim.uv.fs_lstat = function(path, ...)
					if path:match("é%-file.lua$") then
						return nil, "ENOENT"
					end
					return original_stat(path, ...)
				end
				h.eq({}, collect(root))
			end)
			vim.uv.fs_opendir, vim.uv.fs_lstat = original_open, original_stat
			if not ok then
				error(err, 0)
			end
		end)
	end,

	["large trees yield and are not truncated or partially cached"] = function()
		fixture(function(root)
			for i = 1, 2048 do
				vim.fn.writefile({}, root .. "/file-" .. i)
			end
			local ticks, done = 0, false
			local function heartbeat()
				ticks = ticks + 1
				if not done then
					vim.defer_fn(heartbeat, 1)
				end
			end
			vim.schedule(heartbeat)
			local paths = collect(root)
			done = true
			h.eq(2049, #paths)
			h.ok(ticks > 5, "the event loop ran between discovery batches")
			files.reset()
			local current_checks, called = 0, false
			files.request(root, function()
				called = true
			end, function()
				current_checks = current_checks + 1
				return current_checks < 5
			end)
			h.wait_until(function()
				return current_checks == 5
			end, "mid-scan cancellation")
			h.eq(false, called)
			vim.fn.writefile({}, root .. "/after-cancel")
			h.eq(2050, #collect(root), "partial results were not cached")
		end)
	end,
}
