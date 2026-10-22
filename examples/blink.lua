-- These source options are merged into an existing Blink configuration.
-- pim must be available on runtimepath, for example as a Blink dependency.
-- Existing providers, filetype overrides, and menu options should be retained.
return {
	sources = {
		default = { "lsp", "omni", "path", "buffer", "pim" },
		providers = {
			pim = { name = "pim", module = "pim.completion.blink" },
			path = {
				opts = {
					get_cwd = function(ctx)
						if vim.b[ctx.bufnr].pim_role == "input" then
							return vim.fn.getcwd()
						end
						return vim.fn.expand(("#%d:p:h"):format(ctx.bufnr))
					end,
				},
			},
			buffer = {
				opts = {
					get_bufnrs = function()
						local buffers = {}
						local in_pim = vim.b.pim_role == "input"

						for _, win in ipairs(vim.api.nvim_list_wins()) do
							local buf = vim.api.nvim_win_get_buf(win)
							local role = vim.b[buf].pim_role
							local ordinary = vim.bo[buf].buftype ~= "nofile"
							local conversation = in_pim and (role == "input" or role == "transcript")

							if ordinary or conversation then
								buffers[#buffers + 1] = buf
							end
						end

						return buffers
					end,
				},
			},
		},
	},
}
