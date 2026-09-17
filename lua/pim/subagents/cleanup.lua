local M = {}
local uv = vim.uv

local function safe_path(path)
	if type(path) ~= "string" or path:sub(1, 1) ~= "/" or vim.fs.normalize(path) ~= path then
		return false
	end
	local current = path
	while current do
		local stat, _, code = uv.fs_lstat(current)
		if stat and stat.type == "link" or not stat and code ~= "ENOENT" then
			return false
		end
		local parent = vim.fs.dirname(current)
		current = parent ~= current and parent or nil
	end
	return true
end

local function read_json(path)
	local stat = uv.fs_lstat(path)
	if not stat or stat.type ~= "file" then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil
	end
	local decoded, value =
		pcall(vim.json.decode, table.concat(lines, "\n"), { luanil = { object = true, array = true } })
	return decoded and value or nil
end

local function active(details)
	if details.status == "pending" or details.status == "running" then
		return true
	end
	for _, child in ipairs(details.agents) do
		if child.status == "pending" or child.status == "running" then
			return true
		end
	end
	local live = require("pim.subagents.state").get(details.invocationId)
	return live and (live.details.status == "pending" or live.details.status == "running")
end

local function eligible(directory, parent_id, force, grace, now)
	if not safe_path(directory) then
		return "skipped"
	end
	local manifest = read_json(vim.fs.joinpath(directory, "invocation.json"))
	if not require("pim.subagents.protocol").is_details(manifest) then
		return "skipped"
	end
	---@cast manifest PimSubagentDetails
	if
		manifest.parentSessionId ~= parent_id
		or manifest.invocationId ~= vim.fs.basename(directory)
		or manifest.transcriptDir ~= directory
		or not safe_path(manifest.parentSessionFile)
	then
		return "skipped"
	end
	local allowed = { ["invocation.json"] = true, ["orphaned.json"] = true }
	local ids = {}
	for _, child in ipairs(manifest.agents) do
		if ids[child.id] or child.transcriptPath ~= vim.fs.joinpath(directory, child.id .. ".jsonl") then
			return "skipped"
		end
		ids[child.id] = true
		allowed[child.id .. ".jsonl"] = true
		allowed[child.id .. ".summary.json"] = true
	end
	for name, kind in vim.fs.dir(directory) do
		if kind ~= "file" or not allowed[name] then
			return "skipped"
		end
	end
	if active(manifest) then
		return "retained"
	end
	local marker = vim.fs.joinpath(directory, "orphaned.json")
	local parent, _, code = uv.fs_lstat(manifest.parentSessionFile)
	if parent then
		if parent.type ~= "file" then
			return "skipped"
		end
		uv.fs_unlink(marker)
		return "retained"
	end
	if code ~= "ENOENT" then
		return "skipped"
	end
	local orphan = read_json(marker)
	if
		uv.fs_lstat(marker)
		and (type(orphan) ~= "table" or type(orphan.since) ~= "number" or orphan.since > now or orphan.since < 0)
	then
		return "skipped"
	end
	if not orphan then
		local fd = uv.fs_open(marker, "wx", 384)
		if not fd then
			return "skipped"
		end
		local written = uv.fs_write(fd, vim.json.encode({ since = now }) .. "\n", 0)
		uv.fs_close(fd)
		if not written then
			return "skipped"
		end
		orphan = { since = now }
	end
	if not force and now - orphan.since < grace * 86400 then
		return "retained"
	end
	-- Rechecked immediately before removal; ambiguous storage is never followed.
	local present, _, last_code = uv.fs_lstat(manifest.parentSessionFile)
	if not safe_path(directory) or present or last_code ~= "ENOENT" or active(manifest) then
		return "skipped"
	end
	return vim.fn.delete(directory, "rf") == 0 and "removed" or "skipped"
end

function M.run(force, now)
	local report = { removed = 0, retained = 0, skipped = 0 }
	local root = require("pim.subagents").transcript_root()
	if not safe_path(root) then
		report.skipped = 1
		return report
	end
	local root_stat = uv.fs_lstat(root)
	if not root_stat then
		return report
	end
	if root_stat.type ~= "directory" then
		report.skipped = 1
		return report
	end
	local grace = require("pim.config").get().subagents.orphan_grace_days
	for parent_id, kind in vim.fs.dir(root) do
		local parent = vim.fs.joinpath(root, parent_id)
		if kind ~= "directory" or not parent_id:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") then
			report.skipped = report.skipped + 1
		else
			for name, child_kind in vim.fs.dir(parent) do
				local result = "skipped"
				if child_kind == "directory" and name:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") then
					local ok, value =
						pcall(eligible, vim.fs.joinpath(parent, name), parent_id, force, grace, now or os.time())
					if ok then
						result = value
					end
				end
				report[result] = report[result] + 1
			end
		end
	end
	return report
end

function M.clean(force)
	if not require("pim.config").get().subagents.enabled then
		vim.notify("[pim] Subagents are disabled", vim.log.levels.WARN)
		return
	end
	local report = M.run(force)
	vim.notify(
		("[pim] Subagent cleanup: %d removed, %d retained, %d skipped (unsafe or ambiguous)"):format(
			report.removed,
			report.retained,
			report.skipped
		),
		report.skipped > 0 and vim.log.levels.WARN or vim.log.levels.INFO
	)
end

return M
