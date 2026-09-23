local h = require("helpers")
local config = require("pim.config")
local subagents = require("pim.subagents")

local function patched(object, key, value, fn)
	local original = object[key]
	object[key] = value
	local ok, err = pcall(fn)
	object[key] = original
	if not ok then
		error(err)
	end
end

return {
	["activation resolves the bundle and private host environment"] = function()
		local activation = assert(subagents.activation())
		h.eq("--extension", activation.args[1])
		h.eq(1, vim.fn.filereadable(activation.args[2]))
		h.eq("1", activation.env.PIM_HOST)
		h.eq(vim.fs.joinpath(vim.fn.stdpath("data"), "pim", "subagents"), activation.env.PIM_SUBAGENT_ROOT)
	end,
	["disabled activation leaves process arguments and environment unchanged"] = function()
		config.setup({ subagents = { enabled = false } })
		patched(subagents, "extension_path", function()
			error("disabled feature must not resolve the bundle")
		end, function()
			h.eq({ args = {} }, subagents.activation())
		end)
	end,
	["strict validation includes nested subagent keys"] = function()
		h.fails(function()
			config.setup({ subagents = { enabled = "yes" } })
		end, "subagents.enabled")
		local warning
		patched(vim, "notify", function(message)
			warning = message
		end, function()
			config.setup({ subagents = { unknown = true } })
		end)
		h.ok(warning:find("subagents.unknown", 1, true))
	end,
	["missing extension prevents process creation"] = function()
		patched(subagents, "extension_path", function()
			return nil
		end, function()
			local ok, err = require("pim.rpc.client").start()
			h.eq(false, ok)
			h.ok(assert(err):find("missing", 1, true))
		end)
	end,
	["client command and environment are passed to the process"] = function()
		local process = require("pim.rpc.process")
		for _, enabled in ipairs({ true, false }) do
			config.setup({
				pi_cmd = { "pi", "--offline" },
				args = { "--no-approve" },
				subagents = { enabled = enabled },
			})
			local captured
			patched(process, "spawn", function(opts)
				captured = opts
				return nil, "test stop"
			end, function()
				require("pim.rpc.client").start({ extra_args = { "--no-session" } })
			end)
			local expected = { "pi", "--offline", "--no-approve", "--no-session", "--mode", "rpc" }
			if enabled then
				vim.list_extend(expected, { "--extension", subagents.extension_path() })
				h.eq("1", captured.env.PIM_HOST)
			else
				h.eq(nil, captured.env)
			end
			h.eq(expected, captured.cmd)
		end
	end,
	["process environment is merged without changing the editor environment"] = function()
		local output
		local handle = require("pim.rpc.process").spawn({
			cmd = { "sh", "-c", 'printf "%s:%s\\n" "$PIM_TEST_ENV" "$PATH"' },
			env = { PIM_TEST_ENV = "private" },
			on_line = function(line)
				output = line
			end,
			on_exit = function() end,
		})
		h.ok(handle)
		h.wait_until(function()
			return output ~= nil
		end, "environment output")
		h.ok(output:find("private:", 1, true) == 1)
		h.ok(#output > #"private:")
		h.eq(nil, vim.env.PIM_TEST_ENV)
	end,
	["health reports enabled disabled missing and unsafe storage"] = function()
		local messages = {}
		local health = {}
		for _, level in ipairs({ "ok", "error", "info" }) do
			health[level] = function(message)
				messages[#messages + 1] = level .. ":" .. message
			end
		end
		subagents.check(health)
		h.ok(table.concat(messages, "\n"):find("Bundled subagent extension is available", 1, true))
		config.setup({ subagents = { enabled = false } })
		subagents.check(health)
		h.eq("info:Subagents are disabled", messages[#messages])
		config.setup()
		patched(subagents, "extension_path", function()
			return nil
		end, function()
			subagents.check(health)
			h.ok(messages[#messages]:find("error:", 1, true) == 1)
		end)
		local file = vim.fn.tempname()
		vim.fn.writefile({}, file)
		file = assert(vim.uv.fs_realpath(file))
		patched(subagents, "transcript_root", function()
			return file
		end, function()
			subagents.check(health)
			h.ok(messages[#messages]:find("not writable", 1, true))
		end)
		vim.fn.delete(file)
	end,
}
