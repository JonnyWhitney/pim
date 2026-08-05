local M = {}

M.defaults = {
	pi_cmd = "pi",
	args = {},
	keymaps = {
		submit = "<CR><CR>",
		submit_followup = "<localleader><CR>",
		abort = "<C-c>",
		toggle_fold = "<Tab>",
	},
	input = {
		min_height = 3,
		max_height = 15,
	},
	streaming_submit = "steer",
	bash_passthrough = true,
	transcript = {
		tools_collapsed = true,
		show_thinking = "folded",
	},
	set_title = false,
	debug = false,
}

local options = nil

---@return string
function M.pi_agent_dir()
	local directory = vim.env.PI_CODING_AGENT_DIR
	if type(directory) ~= "string" or directory == "" then
		directory = vim.fs.joinpath(vim.fn.expand("~"), ".pi", "agent")
	end
	return vim.fn.expand(directory)
end

---@return string
function M.pi_config_dir()
	return vim.fn.fnamemodify(M.pi_agent_dir(), ":~")
end

---@return string
function M.pi_sessions_dir()
	return vim.fs.joinpath(M.pi_agent_dir(), "sessions")
end

local function fail(message)
	error("[pim] invalid config: " .. message, 0)
end

local function option_groups()
	local groups = {}
	for key, default in pairs(M.defaults) do
		if type(default) == "table" and not vim.islist(default) then
			groups[#groups + 1] = key
		end
	end
	table.sort(groups)
	return groups
end

local function validate(opts)
	for _, group in ipairs(option_groups()) do
		if type(opts[group]) ~= "table" then
			fail(("%s must be a table"):format(group))
		end
	end

	if type(opts.pi_cmd) ~= "string" and type(opts.pi_cmd) ~= "table" then
		fail("pi_cmd must be a string or a list of strings")
	end
	if type(opts.pi_cmd) == "table" and #opts.pi_cmd == 0 then
		fail("pi_cmd list must not be empty")
	end
	if type(opts.args) ~= "table" or not vim.islist(opts.args) then
		fail("args must be a list of strings")
	end
	if opts.streaming_submit ~= "steer" and opts.streaming_submit ~= "followUp" then
		fail('streaming_submit must be "steer" or "followUp"')
	end
	local thinking = opts.transcript.show_thinking
	if thinking ~= "folded" and thinking ~= "open" and thinking ~= "hidden" then
		fail('transcript.show_thinking must be "folded", "open", or "hidden"')
	end
	local input = opts.input
	if type(input.min_height) ~= "number" or input.min_height < 1 then
		fail("input.min_height must be a number >= 1")
	end
	if type(input.max_height) ~= "number" or input.max_height < input.min_height then
		fail("input.max_height must be a number >= input.min_height")
	end
	for name, lhs in pairs(opts.keymaps) do
		if type(lhs) ~= "string" then
			fail(("keymaps.%s must be a string"):format(name))
		end
	end
end

-- Compute edit distance so warnings can suggest a close option name.
local function distance(a, b)
	local previous = {}
	for j = 0, #b do
		previous[j] = j
	end
	for i = 1, #a do
		local current = { [0] = i }
		for j = 1, #b do
			local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
			current[j] = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
		end
		previous = current
	end
	return previous[#b]
end

local function nearest(key, known)
	local best, best_distance = nil, math.huge
	for candidate in pairs(known) do
		local candidate_distance = distance(key, candidate)
		if candidate_distance < best_distance then
			best, best_distance = candidate, candidate_distance
		end
	end
	if best_distance <= math.max(2, math.floor(#key / 3)) then
		return best
	end
	return nil
end

local function collect_unknown(opts, known, prefix, found)
	for key, value in pairs(opts) do
		local path = prefix .. tostring(key)
		local default = known[key]
		if default == nil then
			found[#found + 1] = { path = path, suggestion = nearest(tostring(key), known) }
		elseif type(default) == "table" and type(value) == "table" and not vim.islist(default) then
			collect_unknown(value, default, path .. ".", found)
		end
	end
end

local function warn_unknown(opts)
	local found = {}
	collect_unknown(opts, M.defaults, "", found)
	if #found == 0 then
		return
	end

	table.sort(found, function(a, b)
		return a.path < b.path
	end)
	local lines = { "[pim] ignoring unknown config " .. (#found == 1 and "key:" or "keys:") }
	for _, entry in ipairs(found) do
		lines[#lines + 1] = ("  %s%s"):format(
			entry.path,
			entry.suggestion and (" — did you mean %q?"):format(entry.suggestion) or ""
		)
	end
	vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN)
end

---@param opts table|nil
---@return table
function M.setup(opts)
	local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	validate(merged)
	warn_unknown(opts or {})
	options = merged
	return options
end

---@return table
function M.get()
	if options == nil then
		options = M.setup()
	end
	return options
end

return M
