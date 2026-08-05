if vim.fn.has("nvim-0.12") ~= 1 then
	io.write(("pim requires Neovim 0.12 or newer; this is %s\n"):format(tostring(vim.version())))
	os.exit(1)
end

local tests_dir = vim.fn.fnamemodify(arg[0], ":p:h")
local root = vim.fn.fnamemodify(tests_dir, ":h")

vim.opt.runtimepath:prepend(root)
package.path = tests_dir .. "/?.lua;" .. package.path

local helpers = require("helpers")

local filter = arg[1]

local spec_files = {}
for name, kind in vim.fs.dir(tests_dir) do
	if kind == "file" and name:match("_spec%.lua$") then
		spec_files[#spec_files + 1] = name
	end
end
-- Use a fixed order so test output and failures are reproducible.
table.sort(spec_files)

local passed, failed = 0, 0
local groups = {}

for _, file in ipairs(spec_files) do
	local group = file:gsub("_spec%.lua$", "")
	groups[#groups + 1] = group
	local spec = dofile(tests_dir .. "/" .. file)

	local names = vim.tbl_keys(spec)
	table.sort(names)

	for _, name in ipairs(names) do
		local label = group .. ": " .. name
		if not filter or label:find(filter, 1, true) then
			helpers.reset_all()
			local success, err = pcall(spec[name])
			helpers.reset_all()
			if success then
				passed = passed + 1
				io.write(("ok   %s\n"):format(label))
			else
				failed = failed + 1
				io.write(("FAIL %s\n     %s\n"):format(label, tostring(err)))
			end
		end
	end
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))

if filter and passed + failed == 0 then
	io.write(("no tests matched %q\navailable groups: %s\n"):format(filter, table.concat(groups, ", ")))
	os.exit(1)
end
if failed > 0 then
	os.exit(1)
end
