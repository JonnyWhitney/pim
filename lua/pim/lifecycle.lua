local M = {}

local function clear_autocmds()
	for _, group in ipairs({ "pim-exit", "pim-shutdown" }) do
		pcall(vim.api.nvim_del_augroup_by_name, group)
	end
end

function M.cleanup()
	clear_autocmds()
	require("pim.rpc.client").reset()
	require("pim.ui.dialogs").reset()
	require("pim.ui.tree").reset()
	require("pim.ui.input").reset()
	require("pim.completion").reset()
	require("pim.ui.statusline").reset()
	require("pim.bash").reset()
	require("pim.events").reset()
	require("pim.ui.transcript").reset()
	require("pim.state").reset_observers()
	require("pim.state").reset()
	require("pim.ui.layout").destroy()
end

return M
