local M = {}

function M.extension_path()
	return vim.api.nvim_get_runtime_file("pi-extensions/subagents/index.ts", false)[1]
end

function M.transcript_root()
	return vim.fs.joinpath(vim.fn.stdpath("data"), "pim", "subagents")
end

---@return table|nil, string|nil
function M.activation()
	if not require("pim.config").get().subagents.enabled then
		return { args = {} }
	end
	local path = M.extension_path()
	if not path or vim.fn.filereadable(path) ~= 1 then
		return nil, "Bundled subagent extension is missing. Reinstall PIM or disable subagents.enabled."
	end
	return {
		args = { "--extension", path },
		env = { PIM_HOST = "1", PIM_SUBAGENT_ROOT = M.transcript_root() },
	}
end

function M.check(health)
	if not require("pim.config").get().subagents.enabled then
		health.info("Subagents are disabled")
		return
	end
	local activation, err = M.activation()
	if not activation then
		health.error(err)
		return
	end
	health.ok("Bundled subagent extension is available")
	local root = M.transcript_root()
	---@type string|nil
	local ancestor = root
	while ancestor do
		local stat = vim.uv.fs_lstat(ancestor)
		if stat and stat.type == "link" then
			health.error("Subagent storage paths must not contain symlinks: " .. ancestor)
			return
		end
		local parent = vim.fs.dirname(ancestor)
		ancestor = parent ~= ancestor and parent or nil
	end
	local path = root
	while not vim.uv.fs_lstat(path) and vim.fs.dirname(path) ~= path do
		path = vim.fs.dirname(path)
	end
	local stat = vim.uv.fs_stat(path)
	if not stat or stat.type ~= "directory" or vim.fn.filewritable(path) ~= 2 then
		health.error("Subagent transcript root is not writable: " .. root)
	else
		health.ok("Subagent transcript root: " .. root)
	end
end

return M
