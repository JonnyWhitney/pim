-- This callback is assigned to `config` in an existing lazy.nvim Blink spec.
-- Existing source options must be assembled first, including sources.default.
-- pim must be available on runtimepath (for example, as a Blink dependency).
-- Existing menu, keymap, selection, and documentation options are passed through.
return function(_, opts)
	opts.sources = require("pim.completion.blink").setup(opts.sources)
	require("blink.cmp").setup(opts)
end
