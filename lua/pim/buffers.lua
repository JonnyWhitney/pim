local M = {}

---@param name string
---@return integer|nil
function M.find_named(name)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(buf) == name then
			return buf
		end
	end
	return nil
end

---@param buf integer
---@param base string
---@param role string
function M.claim(buf, base, role)
	vim.b[buf].pim_role = role

	local existing = M.find_named(base)
	-- Delete only a buffer that pim marked as its own. User buffers keep their data.
	if existing ~= nil and vim.b[existing].pim_role ~= nil then
		pcall(vim.api.nvim_buf_delete, existing, { force = true })
		existing = M.find_named(base)
	end
	if existing == nil then
		pcall(vim.api.nvim_buf_set_name, buf, base)
		return
	end

	local n = 2
	while M.find_named(("%s (%d)"):format(base, n)) ~= nil do
		n = n + 1
	end
	pcall(vim.api.nvim_buf_set_name, buf, ("%s (%d)"):format(base, n))
end

return M
