local h = require("helpers")
local config = require("pim.config")

local function setup_capturing_warning(opts)
	local captured = nil
	local real_notify = vim.notify
	vim.notify = function(message, level)
		if level == vim.log.levels.WARN then
			captured = message
		end
	end
	local ok, err = pcall(config.setup, opts)
	vim.notify = real_notify
	h.ok(ok, "setup() raised: " .. tostring(err))
	return captured
end

local function with_agent_dir(directory, fn)
	local original = vim.env.PI_CODING_AGENT_DIR
	vim.env.PI_CODING_AGENT_DIR = directory
	local ok, err = pcall(fn)
	vim.env.PI_CODING_AGENT_DIR = original
	if not ok then
		error(err, 0)
	end
end

return {
	["removed completion settings are reported as unknown"] = function()
		h.eq(nil, config.setup().completion)
		local warning = assert(setup_capturing_warning({ completion = { respect_gitignore = false, exclude = {} } }))
		h.ok(warning:find("completion", 1, true))
	end,
	["message decorations can be independently configured or disabled"] = function()
		local opts =
			config.setup({ transcript = { dividers = false, header_highlights = { user = "@markup.heading.3" } } })
		h.eq(false, opts.transcript.dividers)
		h.eq("@markup.heading.3", opts.transcript.header_highlights.user)
		h.eq("PimAssistantHeader", opts.transcript.header_highlights.assistant)
		h.eq("PimCustomHeader", opts.transcript.header_highlights.custom)
		h.eq(nil, setup_capturing_warning({ transcript = { header_highlights = false } }))
		h.eq(false, config.get().transcript.header_highlights)
		h.eq(true, config.get().transcript.dividers)
	end,

	["invalid divider and header settings are rejected"] = function()
		for _, value in ipairs({ "yes", 1, {} }) do
			h.fails(function()
				config.setup({ transcript = { dividers = value } })
			end, "transcript.dividers must be a boolean")
		end
		for _, value in ipairs({ true, "Comment", 1 }) do
			h.fails(function()
				config.setup({ transcript = { header_highlights = value } })
			end, "transcript.header_highlights must be a table or false")
		end
		for _, role in ipairs({ "user", "assistant", "custom" }) do
			for _, name in ipairs({ "", "two words", "bad\nname", "bad/name", string.rep("x", 201), false, 1 }) do
				h.fails(function()
					config.setup({ transcript = { header_highlights = { [role] = name } } })
				end, "transcript.header_highlights." .. role)
			end
		end
		h.eq(
			"custom-header",
			config.setup({ transcript = { header_highlights = { custom = "custom-header" } } }).transcript.header_highlights.custom
		)
	end,
	["pi config directory uses PI_CODING_AGENT_DIR and shortens home"] = function()
		with_agent_dir(vim.fs.joinpath(vim.fn.expand("~"), ".pi-personal", "agent"), function()
			h.eq("~/.pi-personal/agent", config.pi_config_dir())
		end)
	end,

	["pi config directory falls back to pi default"] = function()
		with_agent_dir(nil, function()
			h.eq("~/.pi/agent", config.pi_config_dir())
		end)
	end,

	["get() without setup() returns the defaults"] = function()
		h.eq(config.defaults, config.get())
	end,

	["a non-table option group fails with our own message"] = function()
		for _, group in ipairs({ "keymaps", "input", "transcript" }) do
			h.fails(function()
				config.setup({ [group] = "oops" })
			end, "invalid config: " .. group .. " must be a table")
		end
	end,

	["setup() merges nested options over defaults"] = function()
		local opts = config.setup({ input = { min_height = 5 } })
		h.eq(5, opts.input.min_height)
		h.eq(config.defaults.input.max_height, opts.input.max_height)
		h.eq(config.defaults.streaming_submit, opts.streaming_submit)
	end,

	["setup() does not mutate the defaults table"] = function()
		config.setup({ keymaps = { submit = "<C-s>" } })
		h.eq("<CR><CR>", config.defaults.keymaps.submit)
	end,

	["setup() result is what get() returns"] = function()
		local opts = config.setup({ debug = true })
		h.ok(config.get() == opts)
		h.eq(true, config.get().debug)
	end,

	["rejects invalid streaming_submit"] = function()
		h.fails(function()
			config.setup({ streaming_submit = "queue" })
		end, "streaming_submit")
	end,

	["fold settings are independently validated"] = function()
		for _, name in ipairs({ "tool_calls", "tool_results", "thinking", "bash_output" }) do
			for _, value in ipairs({ "folded", "open" }) do
				h.eq(value, config.setup({ transcript = { folds = { [name] = value } } }).transcript.folds[name])
			end
			for _, value in ipairs({ false, "sometimes", "hidden" }) do
				if name ~= "thinking" or value ~= "hidden" then
					h.fails(function()
						config.setup({ transcript = { folds = { [name] = value } } })
					end, "transcript.folds." .. name)
				end
			end
		end
		h.eq("hidden", config.setup({ transcript = { folds = { thinking = "hidden" } } }).transcript.folds.thinking)
		h.fails(function()
			config.setup({ transcript = { folds = false } })
		end, "transcript.folds")
	end,

	["rejects max_height below min_height"] = function()
		h.fails(function()
			config.setup({ input = { min_height = 10, max_height = 2 } })
		end, "max_height")
	end,

	["rejects empty pi_cmd list"] = function()
		h.fails(function()
			config.setup({ pi_cmd = {} })
		end, "pi_cmd")
	end,

	["an unknown top-level key warns without a suggestion"] = function()
		local warning = assert(setup_capturing_warning({ keymap = { submit = "<C-s>" } }), "a warning was emitted")

		h.ok(warning:find("keymap", 1, true), "names the offending key")
		h.ok(not warning:find("did you mean", 1, true), "does not suggest a key, got: " .. warning)
	end,

	["an unknown nested key is reported by its full path"] = function()
		local warning = assert(setup_capturing_warning({ keymaps = { submitt = "<C-s>" } }), "a warning was emitted")

		h.ok(warning:find("keymaps.submitt", 1, true), "reports the dotted path, got: " .. warning)
		h.ok(not warning:find("did you mean", 1, true), "does not suggest a key")
	end,

	["an unrelated unknown key is reported without a guess"] = function()
		local warning = assert(setup_capturing_warning({ zzzzzzz = true }), "a warning was emitted")

		h.ok(warning:find("zzzzzzz", 1, true), "names the offending key")
		h.ok(not warning:find("did you mean", 1, true), "no wild guess, got: " .. warning)
	end,

	["an unknown key still leaves the rest of the config working"] = function()
		setup_capturing_warning({ keymap = {}, input = { min_height = 7 } })

		h.eq(7, config.get().input.min_height, "valid options still applied")
		h.eq("<CR><CR>", config.get().keymaps.submit, "defaults intact")
	end,

	["list-valued options are not treated as key sets"] = function()
		h.eq(nil, setup_capturing_warning({ args = { "--no-session", "--foo" } }))
	end,

	["a valid config warns about nothing"] = function()
		h.eq(
			nil,
			setup_capturing_warning({
				pi_cmd = "pi",
				args = {},
				keymaps = { submit = "<CR><CR>", abort = "<C-c>" },
				input = { min_height = 3, max_height = 15 },
				streaming_submit = "followUp",
				transcript = { folds = { tool_calls = "open", thinking = "open" } },
				set_title = true,
				debug = true,
			})
		)
	end,
}
