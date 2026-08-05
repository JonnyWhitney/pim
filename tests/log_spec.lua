local h = require("helpers")
local log = require("pim.log")

local LOG_NAME = "pim://pi log"

---@return { ok: boolean, err: any, name: string, buf: integer }
local function open_viewer()
	vim.cmd("tabnew")
	local ok, err = pcall(log.open)
	local buf = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(buf)
	vim.cmd("tabclose")
	return { ok = ok, err = err, name = name, buf = buf }
end

return {
	["opening the viewer leaves a similarly named user buffer alone"] = function()
		local decoy = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(decoy, "notes-pim://pi log-draft")
		vim.api.nvim_buf_set_lines(decoy, 0, -1, false, { "unsaved work" })

		log.add("*", "an entry to show")
		local result = open_viewer()
		local survived = vim.api.nvim_buf_is_valid(decoy)
		local content = survived and vim.api.nvim_buf_get_lines(decoy, 0, -1, false) or nil
		pcall(vim.api.nvim_buf_delete, decoy, { force = true })

		h.ok(result.ok, ":PiLog did not raise: " .. tostring(result.err))
		h.ok(survived, "the user's buffer survived :PiLog")
		h.eq({ "unsaved work" }, content, "with its content intact")
		h.eq(LOG_NAME, result.name, "and the viewer still gets the name it wanted")
	end,

	["reopening the viewer reclaims its own buffer rather than suffixing"] = function()
		log.add("*", "an entry to show")
		local first = open_viewer()
		local second = open_viewer()

		h.ok(first.ok and second.ok, "neither open raised")
		h.eq(LOG_NAME, first.name)
		h.eq(LOG_NAME, second.name, "the second viewer reclaimed the name from the first")
	end,

	["a user buffer holding the log name keeps it"] = function()
		local held = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(held, LOG_NAME)
		vim.api.nvim_buf_set_lines(held, 0, -1, false, { "unsaved work" })

		log.add("*", "an entry to show")
		local result = open_viewer()
		local survived = vim.api.nvim_buf_is_valid(held)
		pcall(vim.api.nvim_buf_delete, held, { force = true })

		h.ok(result.ok, ":PiLog did not raise: " .. tostring(result.err))
		h.ok(survived, "the user's buffer kept the name")
		h.eq(LOG_NAME .. " (2)", result.name, "the viewer took a free suffix instead")
	end,
}
