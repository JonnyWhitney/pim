local h = require("helpers")
local log = require("pim.log")

local LOG_NAME = "pim://pi log"

local function own_buffer(defer, buf)
	defer(function()
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end)
	return buf
end

---@return { ok: boolean, err: any, name: string, buf: integer }
local function open_viewer()
	local result = h.with_cleanup(function(defer)
		vim.cmd("tabnew")
		local tab = vim.api.nvim_get_current_tabpage()
		own_buffer(defer, vim.api.nvim_get_current_buf())
		defer(function()
			if vim.api.nvim_tabpage_is_valid(tab) then
				vim.api.nvim_set_current_tabpage(tab)
				vim.cmd("tabclose!")
			end
		end)
		local create = vim.api.nvim_create_buf
		h.patch(defer, vim.api, "nvim_create_buf", function(...)
			return own_buffer(defer, create(...))
		end)
		local ok, err = pcall(log.open)
		local buf = vim.api.nvim_get_current_buf()
		return { ok = ok, err = err, name = vim.api.nvim_buf_get_name(buf), buf = buf }
	end)
	return result
end

return {
	["opening the viewer leaves a similarly named user buffer alone"] = function()
		h.with_cleanup(function(defer)
			local decoy = own_buffer(defer, vim.api.nvim_create_buf(true, false))
			vim.api.nvim_buf_set_name(decoy, "notes-pim://pi log-draft")
			vim.api.nvim_buf_set_lines(decoy, 0, -1, false, { "unsaved work" })
			log.add("*", "an entry to show")
			local result = open_viewer()
			h.ok(result.ok, ":PiLog did not raise: " .. tostring(result.err))
			h.ok(vim.api.nvim_buf_is_valid(decoy), "the user's buffer survived :PiLog")
			h.eq({ "unsaved work" }, vim.api.nvim_buf_get_lines(decoy, 0, -1, false))
			h.eq(LOG_NAME, result.name)
		end)
	end,
	["reopening the viewer reclaims its own buffer rather than suffixing"] = function()
		log.add("*", "an entry to show")
		local first = open_viewer()
		local second = open_viewer()
		h.ok(first.ok and second.ok, "neither open raised")
		h.eq(LOG_NAME, first.name)
		h.eq(LOG_NAME, second.name)
	end,
	["a user buffer holding the log name keeps it"] = function()
		h.with_cleanup(function(defer)
			local held = own_buffer(defer, vim.api.nvim_create_buf(true, false))
			vim.api.nvim_buf_set_name(held, LOG_NAME)
			vim.api.nvim_buf_set_lines(held, 0, -1, false, { "unsaved work" })
			log.add("*", "an entry to show")
			local result = open_viewer()
			h.ok(result.ok, ":PiLog did not raise: " .. tostring(result.err))
			h.ok(vim.api.nvim_buf_is_valid(held), "the user's buffer kept the name")
			h.eq(LOG_NAME .. " (2)", result.name)
		end)
	end,
}
