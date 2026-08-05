if vim.g.loaded_pim then
	return
end
vim.g.loaded_pim = true

vim.api.nvim_create_user_command("PiStart", function()
	require("pim").start()
end, { desc = "Open pi UI" })

vim.api.nvim_create_user_command("PiStop", function(opts)
	require("pim").stop({ confirm = not opts.bang })
end, { bang = true, desc = "Stop pi and close the pi tab. ! skips confirmation." })

vim.api.nvim_create_user_command("PiRestart", function()
	require("pim").restart()
end, { desc = "Restart pi and resume the current session" })

vim.api.nvim_create_user_command("PiToggle", function()
	require("pim").toggle()
end, { desc = "Show or hide the pi windows" })

vim.api.nvim_create_user_command("PiAbort", function()
	require("pim").abort()
end, { desc = "Abort the current pi agent run" })

vim.api.nvim_create_user_command("PiSend", function(opts)
	require("pim.ui.input").send(opts.args)
end, { nargs = "*", desc = "Send text or the input buffer to pi" })

vim.api.nvim_create_user_command("PiResume", function()
	require("pim.ui.pickers").session()
end, { desc = "Select a pi session for this directory" })

vim.api.nvim_create_user_command("PiTree", function()
	require("pim.ui.tree").open()
end, { desc = "Browse the current pi session tree" })

vim.api.nvim_create_user_command("PiNewSession", function()
	require("pim").new_session()
end, { desc = "Start a new pi session" })

vim.api.nvim_create_user_command("PiFork", function()
	require("pim.ui.pickers").fork()
end, { desc = "Fork pi from an earlier prompt" })

vim.api.nvim_create_user_command("PiClone", function()
	require("pim").clone()
end, { desc = "Clone the current pi branch" })

vim.api.nvim_create_user_command("PiModel", function()
	require("pim.ui.pickers").model()
end, { desc = "Pick the pi model" })

vim.api.nvim_create_user_command("PiThinking", function()
	require("pim.ui.pickers").thinking()
end, { desc = "Pick the pi thinking level" })

vim.api.nvim_create_user_command("PiLog", function()
	require("pim.log").open()
end, { desc = "Show the pim event log" })
