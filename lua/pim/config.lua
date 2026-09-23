local M = {}

M.defaults = {
	pi_cmd = "pi",
	subagents = { enabled = true, orphan_grace_days = 30 },
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
		dividers = true,
		header_highlights = {
			user = "PimUserHeader",
			assistant = "PimAssistantHeader",
			custom = "PimCustomHeader",
		},
		folds = {
			tool_calls = "folded",
			tool_results = "open",
			thinking = "folded",
			bash_output = "open",
		},
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

	if type(opts.subagents.enabled) ~= "boolean" then
		fail("subagents.enabled must be a boolean")
	end

	local grace = opts.subagents.orphan_grace_days
	if type(grace) ~= "number" or grace < 0 or grace == math.huge or grace % 1 ~= 0 then
		fail("subagents.orphan_grace_days must be a nonnegative integer")
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
	if type(opts.transcript.dividers) ~= "boolean" then
		fail("transcript.dividers must be a boolean")
	end
	local headers = opts.transcript.header_highlights
	if headers ~= false then
		if type(headers) ~= "table" then
			fail("transcript.header_highlights must be a table or false")
		end
		for _, role in ipairs({ "user", "assistant", "custom" }) do
			local name = headers[role]
			if type(name) ~= "string" or #name > 200 or not name:match("^[A-Za-z0-9_.@%-]+$") then
				fail("transcript.header_highlights." .. role .. " must be a Neovim highlight-group name")
			end
		end
	end
	if type(opts.transcript.folds) ~= "table" then
		fail("transcript.folds must be a table")
	end
	for name in pairs(M.defaults.transcript.folds) do
		local value = opts.transcript.folds[name]
		if value ~= "folded" and value ~= "open" and not (name == "thinking" and value == "hidden") then
			fail(
				"transcript.folds."
					.. name
					.. ' must be "folded" or "open"'
					.. (name == "thinking" and ', or "hidden"' or "")
			)
		end
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

local function collect_unknown(opts, known, prefix, found)
	for key, value in pairs(opts) do
		local path = prefix .. tostring(key)
		local default = known[key]
		if default == nil then
			found[#found + 1] = path
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

	table.sort(found)
	local lines = { "[pim] ignoring unknown config " .. (#found == 1 and "key:" or "keys:") }
	for _, path in ipairs(found) do
		lines[#lines + 1] = "  " .. path
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
