local h = require("helpers")
local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

return {
	["setup body and cleanup failures are reported with safe final cleanup"] = function()
		for _, case in ipairs({
			{
				mode = "success",
				code = 0,
				summary = "2 passed, 0 failed",
				steps = { "reset", "a", "reset", "reset", "b", "reset" },
			},
			{
				mode = "setup",
				code = 1,
				summary = "1 passed, 1 failed",
				steps = { "reset", "reset", "reset", "b", "reset" },
			},
			{
				mode = "body",
				code = 1,
				summary = "1 passed, 1 failed",
				steps = { "reset", "a", "reset", "reset", "b", "reset" },
			},
			{ mode = "cleanup", code = 1, summary = "0 passed, 1 failed", steps = { "reset", "a", "reset" } },
			{ mode = "marked", code = 1, summary = "0 passed, 1 failed", steps = { "reset", "a", "reset" } },
		}) do
			h.with_cleanup(function(defer)
				local directory = vim.fn.tempname()
				defer(function()
					h.eq(0, vim.fn.delete(directory, "rf"))
				end)
				vim.fn.mkdir(directory, "p")
				vim.fn.writefile(vim.fn.readfile(tests_dir .. "/run.lua"), directory .. "/run.lua")
				local preamble = ("local mode, path = %s, %s\n"):format(
					vim.inspect(case.mode),
					vim.inspect(directory .. "/steps")
				)
				vim.fn.writefile(
					vim.split(preamble .. [[
local calls = 0
return { reset_all = function()
	calls = calls + 1
	vim.fn.writefile({'reset'}, path, 'a')
	if mode == 'setup' and calls == 1 then error('setup failure') end
	if mode == 'cleanup' and calls == 2 then error('final cleanup failure') end
end }
]], "\n"),
					directory .. "/helpers.lua"
				)
				vim.fn.writefile(
					vim.split(preamble .. [[
return { test = function()
	vim.fn.writefile({'a'}, path, 'a')
	if mode == 'body' then error('body failure') end
	if mode == 'marked' then error(setmetatable({cleanup_failed=true}, {__tostring=function() return 'cleanup failure' end})) end
end }
]], "\n"),
					directory .. "/a_spec.lua"
				)
				vim.fn.writefile(
					vim.split(preamble .. [[
return { test = function() vim.fn.writefile({'b'}, path, 'a') end }
]], "\n"),
					directory .. "/b_spec.lua"
				)
				local child = vim.system({ vim.v.progpath, "--clean", "-l", directory .. "/run.lua" }, { text = true })
				defer(function()
					child:wait(3000)
				end)
				defer(function()
					child:kill(9)
				end)
				local result = child:wait(10000)
				h.eq(case.code, result.code, case.mode .. ": " .. (result.stderr or ""))
				h.ok(result.stdout:find(case.summary, 1, true), result.stdout)
				h.eq(case.steps, vim.fn.readfile(directory .. "/steps"), case.mode)
				if case.mode == "cleanup" or case.mode == "marked" then
					h.ok(result.stdout:find("testing stopped because cleanup failed", 1, true))
				end
			end)
		end
	end,
}
