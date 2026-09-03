local h = require("helpers")
local client = require("pim.rpc.client")
local config = require("pim.config")
local pickers = require("pim.ui.pickers")
local state = require("pim.state")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local original_select = vim.ui.select

local function start_fake()
	config.setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" } })
	client.start({ on_event = require("pim.events").handle })
end

local function with_select(stub, fn)
	vim.ui.select = stub
	local ok, err = pcall(fn)
	vim.ui.select = original_select
	if not ok then
		error(err, 0)
	end
end

local function with_trust_project(fn)
	local root = vim.fn.tempname()
	local project = root .. "/work/project"
	local original_agent_dir = vim.env.PI_CODING_AGENT_DIR
	local original_cwd = assert(vim.uv.cwd())
	vim.fn.mkdir(project, "p")
	vim.env.PI_CODING_AGENT_DIR = root .. "/agent"
	assert(vim.uv.chdir(project))
	local ok, err = pcall(fn, project, root .. "/work")
	assert(vim.uv.chdir(original_cwd))
	vim.env.PI_CODING_AGENT_DIR = original_agent_dir
	vim.fn.delete(root, "rf")
	if not ok then
		error(err, 0)
	end
end

local function capture_notify(fn)
	local original_notify = vim.notify
	local messages = {}
	---@diagnostic disable-next-line: duplicate-set-field
	vim.notify = function(message, level)
		messages[#messages + 1] = { message = message, level = level }
	end
	local ok, err = pcall(fn)
	vim.notify = original_notify
	if not ok then
		error(err, 0)
	end
	return messages
end

return {
	["model picker lists models, marks the current one, and sets the choice"] = function()
		start_fake()
		state.update({ model = { id = "fake-model", provider = "fake" } })

		local seen
		with_select(function(items, opts, on_choice)
			seen = { items = items, format = opts.format_item }
			on_choice(items[2])
		end, function()
			pickers.model()
			h.wait_until(function()
				---@type { id: string }|nil
				local model = state.get().model
				return seen ~= nil and model ~= nil and model.id == "other-model"
			end, "the model to update to the picked one", 5000)
		end)

		h.eq(2, #seen.items)
		h.ok(seen.format(seen.items[1]):find("● ", 1, true), "current model marked")
		h.ok(
			seen.format(seen.items[2]):find("Other Model (fake) — 200k ctx", 1, true),
			"label shows name/provider/ctx"
		)
	end,

	["model picker cancel changes nothing"] = function()
		start_fake()
		state.update({ model = { id = "fake-model", provider = "fake" } })

		local shown = false
		with_select(function(_, _, on_choice)
			shown = true
			on_choice(nil)
		end, function()
			pickers.model()
			h.wait_until(function()
				return shown
			end, "the model picker to be shown", 5000)
		end)

		---@type { id: string }
		local model = assert(state.get().model)
		h.eq("fake-model", model.id)
	end,

	["a model list payload that is not a table notifies instead of raising"] = function()
		local original_models = client.get_available_models
		local original_notify = vim.notify
		local notified
		---@diagnostic disable-next-line: duplicate-set-field
		client.get_available_models = function(callback)
			callback(true, nil)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		vim.notify = function(message)
			notified = message
		end

		local shown = false
		local ok, err = pcall(with_select, function()
			shown = true
		end, pickers.model)

		client.get_available_models = original_models
		vim.notify = original_notify

		h.ok(ok, "the picker must not raise, got: " .. tostring(err))
		h.eq(false, shown, "no picker is shown when there is nothing to pick from")
		h.ok(notified ~= nil and notified:find("model list", 1, true), "the user is told, got: " .. tostring(notified))
	end,

	["thinking picker sets the level and the event confirms it"] = function()
		start_fake()
		state.update({ thinking_level = "medium" })

		local seen
		with_select(function(items, opts, on_choice)
			seen = { items = items, format = opts.format_item }
			on_choice("high")
		end, function()
			pickers.thinking()
			h.wait_until(function()
				return state.get().thinking_level == "high"
			end, "the thinking level to update", 5000)
		end)

		h.eq({ "low", "medium", "high", "xhigh", "max" }, seen.items)
		h.ok(seen.format("medium"):find("● ", 1, true), "current level marked")
	end,

	["thinking picker falls back to the built-in levels when pi cannot list them"] = function()
		local original_levels = client.get_available_thinking_levels
		local builtin = { "off", "minimal", "low", "medium", "high", "xhigh" }

		for _, answer in ipairs({
			{ success = false, payload = "unknown command: get_available_thinking_levels" },
			{ success = true, payload = nil },
			{ success = true, payload = { levels = {} } },
		}) do
			---@diagnostic disable-next-line: duplicate-set-field
			client.get_available_thinking_levels = function(callback)
				callback(answer.success, answer.payload)
			end

			local seen
			with_select(function(items)
				seen = items
			end, pickers.thinking)

			h.eq(builtin, seen, "fallback list for " .. vim.inspect(answer):gsub("%s+", " "))
		end

		client.get_available_thinking_levels = original_levels
	end,

	["trust picker applies all three choices"] = function()
		local trust = require("pim.trust")
		for _, case in ipairs({
			{ label = "Trust", decision = true, inherited = false },
			{ label = "Trust parent folder", decision = true, inherited = true },
			{ label = "Do not trust", decision = false, inherited = false },
		}) do
			with_trust_project(function(project, parent)
				if case.inherited then
					trust.reject(project)
				end
				capture_notify(function()
					with_select(function(items, _, on_choice)
						h.eq(3, #items)
						for _, item in ipairs(items) do
							if item.label:find(case.label, 1, true) == 1 then
								on_choice(item)
								return
							end
						end
						error("choice was not shown: " .. case.label)
					end, pickers.trust)
				end)

				local entry = assert(trust.get_entry(project), "selected trust entry must exist")
				h.eq(case.decision, entry.decision)
				h.eq(trust.canonical_path(case.inherited and parent or project), entry.path)
			end)
		end
	end,

	["trust picker prompt shows and marks a direct saved decision"] = function()
		with_trust_project(function(project)
			local trust = require("pim.trust")
			trust.reject(project)
			with_select(function(items, opts)
				h.ok(opts.prompt:find(trust.canonical_path(project), 1, true), "prompt shows the canonical project")
				h.ok(opts.prompt:find("saved: untrusted", 1, true), "prompt shows the saved decision")
				h.ok(opts.format_item(items[3]):find("● Do not trust", 1, true), "saved choice is marked")
			end, pickers.trust)
		end)
	end,

	["trust picker shows an inherited decision and marks its matching parent choice"] = function()
		with_trust_project(function(project, parent)
			local trust = require("pim.trust")
			trust.trust(parent)
			with_select(function(items, opts)
				h.ok(opts.prompt:find("saved: trusted (inherited from", 1, true), "prompt identifies inheritance")
				h.ok(opts.prompt:find(trust.canonical_path(parent), 1, true), "prompt shows the saved parent")
				h.ok(opts.format_item(items[2]):find("● Trust parent folder", 1, true), "parent choice is marked")
			end, pickers.trust)
		end)
	end,

	["trust picker cancellation does not change the store"] = function()
		with_trust_project(function(project)
			local trust = require("pim.trust")
			trust.trust(project)
			local store = trust.store_path()
			local before = table.concat(vim.fn.readfile(store, "b"), "\n")
			with_select(function(_, _, on_choice)
				on_choice(nil)
			end, pickers.trust)
			h.eq(before, table.concat(vim.fn.readfile(store, "b"), "\n"))
		end)
	end,

	["trust picker reports read, validation, and lock failures"] = function()
		with_trust_project(function()
			local trust = require("pim.trust")
			local original_get_entry = trust.get_entry
			for _, failure in ipairs({
				"failed to read trust store",
				"invalid trust store",
				"failed to acquire trust store lock",
			}) do
				---@diagnostic disable-next-line: duplicate-set-field
				trust.get_entry = function()
					error(failure)
				end
				local shown = false
				local messages = capture_notify(function()
					with_select(function()
						shown = true
					end, pickers.trust)
				end)
				h.eq(false, shown)
				h.ok(messages[1].message:find("Cannot read project trust", 1, true))
				h.ok(messages[1].message:find(failure, 1, true))
			end
			trust.get_entry = original_get_entry
		end)
	end,

	["trust picker reports write failures"] = function()
		with_trust_project(function()
			local trust = require("pim.trust")
			local original_trust = trust.trust
			---@diagnostic disable-next-line: duplicate-set-field
			trust.trust = function()
				error("failed to write trust store")
			end
			local messages = capture_notify(function()
				with_select(function(items, _, on_choice)
					on_choice(items[1])
				end, pickers.trust)
			end)
			trust.trust = original_trust
			h.ok(messages[1].message:find("Cannot update project trust", 1, true))
			h.ok(messages[1].message:find("failed to write trust store", 1, true))
		end)
	end,

	["trust picker requests a restart when pi is running"] = function()
		with_trust_project(function()
			local original_running = client.is_running
			---@diagnostic disable-next-line: duplicate-set-field
			client.is_running = function()
				return true
			end
			local messages = capture_notify(function()
				with_select(function(items, _, on_choice)
					on_choice(items[1])
				end, pickers.trust)
			end)
			client.is_running = original_running
			h.ok(messages[1].message:find(":PiRestart", 1, true), "restart instruction is shown")
		end)
	end,
}
