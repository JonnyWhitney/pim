local h = require("helpers")
local trust = require("pim.trust")

local function with_temp_dir(fn)
	local directory = vim.fn.tempname()
	vim.fn.mkdir(directory, "p")
	local original = vim.env.PI_CODING_AGENT_DIR
	vim.env.PI_CODING_AGENT_DIR = directory
	local ok, err = pcall(fn, directory)
	vim.env.PI_CODING_AGENT_DIR = original
	vim.fn.delete(directory, "rf")
	if not ok then
		error(err, 0)
	end
end

local function write(path, content)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local file = assert(io.open(path, "w"))
	assert(file:write(content))
	assert(file:close())
end

local function read(path)
	local file = assert(io.open(path, "r"))
	local content = file:read("*a")
	file:close()
	return content
end

return {
	["missing trust files have no decision"] = function()
		with_temp_dir(function(directory)
			h.eq(nil, trust.get(directory .. "/project"))
			h.eq(nil, vim.uv.fs_stat(directory .. "/trust.json"))
			h.eq(nil, vim.uv.fs_stat(directory .. "/trust.json.lock"))
		end)
	end,

	["direct and inherited decisions return their saved paths"] = function()
		with_temp_dir(function(directory)
			local parent = directory .. "/work"
			local project = parent .. "/project"
			vim.fn.mkdir(project, "p")
			trust.trust(parent)

			h.eq({ path = trust.canonical_path(parent), decision = true }, trust.get_entry(project))
			trust.reject(project)
			h.eq({ path = trust.canonical_path(project), decision = false }, trust.get_entry(project))
		end)
	end,

	["project paths are canonicalized through symlinks"] = function()
		with_temp_dir(function(directory)
			local target = directory .. "/target"
			local link = directory .. "/link"
			vim.fn.mkdir(target, "p")
			assert(vim.uv.fs_symlink(target, link))

			trust.trust(link)
			local entry = assert(trust.get_entry(target), "trusted entry must exist")
			h.eq(trust.canonical_path(target), entry.path)
			h.eq(true, entry.decision)
			h.ok(read(directory .. "/trust.json"):find(trust.canonical_path(target), 1, true))
			h.eq(nil, read(directory .. "/trust.json"):find(link, 1, true))
		end)
	end,

	["updates preserve unrelated entries and null values"] = function()
		with_temp_dir(function(directory)
			local store = directory .. "/trust.json"
			write(store, '{"/z":null,"/unrelated":false}\n')

			trust.trust("/project")
			h.eq('{\n  "/project": true,\n  "/unrelated": false,\n  "/z": null\n}\n', read(store))
		end)
	end,

	["trusting a parent removes the direct child override"] = function()
		with_temp_dir(function(directory)
			local parent = directory .. "/work"
			local project = parent .. "/project"
			vim.fn.mkdir(project, "p")
			trust.reject(project)
			trust.trust_parent(project)

			h.eq({ path = trust.canonical_path(parent), decision = true }, trust.get_entry(project))
			local saved = read(directory .. "/trust.json")
			h.eq(nil, saved:find(trust.canonical_path(project), 1, true))
		end)
	end,

	["malformed JSON is reported and is not overwritten"] = function()
		with_temp_dir(function(directory)
			local store = directory .. "/trust.json"
			local original = "{broken\n"
			write(store, original)

			h.fails(function()
				trust.trust("/project")
			end, "failed to read trust store")
			h.eq(original, read(store))
		end)
	end,

	["non-object trust data and invalid values are rejected"] = function()
		with_temp_dir(function(directory)
			local store = directory .. "/trust.json"
			write(store, "[]\n")
			h.fails(function()
				trust.get("/project")
			end, "expected an object")

			write(store, '{"/project":"yes"}\n')
			h.fails(function()
				trust.reject("/project")
			end, "must be true, false, or null")
			h.eq('{"/project":"yes"}\n', read(store))
		end)
	end,

	["an active pi-compatible lock prevents access"] = function()
		with_temp_dir(function(directory)
			vim.fn.mkdir(directory .. "/trust.json.lock", "p")
			h.fails(function()
				trust.trust("/project")
			end, "failed to acquire trust store lock")
			h.eq(nil, vim.uv.fs_stat(directory .. "/trust.json"))
		end)
	end,
}
