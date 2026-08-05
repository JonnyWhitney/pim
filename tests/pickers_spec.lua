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
				return seen ~= nil and state.get().model ~= nil and state.get().model.id == "other-model"
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

		h.eq("fake-model", state.get().model.id)
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
}
