local h = require("helpers")
local preview = require("pim.tool_preview")

local function with_file(content, callback)
	local directory = vim.fn.tempname()
	vim.fn.mkdir(directory, "p")
	local path = directory .. "/sample.txt"
	vim.fn.writefile(vim.split(content, "\n", { plain = true }), path, "b")
	local ok, err = xpcall(function()
		callback(path)
	end, debug.traceback)
	vim.fn.delete(directory, "rf")
	if not ok then
		error(err, 0)
	end
end

return {
	["edit preview renders a unified diff without changing the file"] = function()
		with_file("before\nkeep\n", function(path)
			local diff = assert(
				preview.generate("edit", {
					path = path,
					edits = { { oldText = "before", newText = "after" } },
				}),
				"edit preview must generate a diff"
			)
			h.ok(diff:find("-before", 1, true))
			h.ok(diff:find("+after", 1, true))
			h.eq({ "before", "keep" }, vim.fn.readfile(path))
		end)
	end,

	["edit preview applies disjoint replacements against the original file"] = function()
		with_file("one\nmiddle\ntwo\n", function(path)
			local diff = assert(
				preview.generate("edit", {
					path = path,
					edits = {
						{ oldText = "one", newText = "first" },
						{ oldText = "two", newText = "second" },
					},
				}),
				"edit preview must generate a diff"
			)
			h.ok(diff:find("-one", 1, true))
			h.ok(diff:find("+first", 1, true))
			h.ok(diff:find("-two", 1, true))
			h.ok(diff:find("+second", 1, true))
		end)
	end,

	["edit preview falls back to replacement blocks"] = function()
		local diff = preview.generate("edit", {
			path = "/missing/file",
			edits = { { oldText = "old\nline", newText = "new\nline" } },
		})
		h.eq("@@ replacement 1 @@\n-old\n-line\n+new\n+line", diff)
	end,

	["write preview is the proposed content"] = function()
		h.eq("first\nsecond", preview.generate("write", { path = "new.txt", content = "first\nsecond" }))
	end,

	["bash preview is the complete command"] = function()
		h.eq("mise test\necho done", preview.generate("bash", { command = "mise test\necho done" }))
	end,
}
