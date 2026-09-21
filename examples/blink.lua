-- These source options are merged into an existing Blink configuration.
-- pim must be available on runtimepath, for example as a Blink dependency.
-- Existing providers, filetype overrides, and menu options should be retained.
return {
	sources = {
		default = { "lsp", "omni", "path", "buffer", "pim" },
		providers = {
			pim = { name = "pim", module = "pim.completion.blink" },
		},
	},
}
