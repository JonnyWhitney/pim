local h = require("helpers")
local content = require("pim.content")

return {
	["to_text keeps complete content and describes non-text blocks"] = function()
		h.eq(
			"first\nsecond\n[image: image/png]\n[document block]",
			content.to_text({
				{ type = "text", text = "first" },
				{ type = "text", text = "second" },
				{ type = "image", mimeType = "image/png" },
				{ type = "document" },
			})
		)
	end,

	["first_text returns only the first text block"] = function()
		h.eq(
			"first",
			content.first_text({
				{ type = "image", mimeType = "image/png" },
				{ type = "text", text = "first" },
				{ type = "text", text = "second" },
			})
		)
	end,

	["string content passes through text extraction"] = function()
		h.eq("plain", content.to_text("plain"))
		h.eq("plain", content.first_text("plain"))
		h.eq("", content.to_text(nil))
		h.eq(nil, content.first_text(nil))
	end,

	["one_line normalizes whitespace and truncates by character"] = function()
		h.eq("one two three", content.one_line("  one\n\ttwo   three  ", 20))
		h.eq("αβγ…", content.one_line("αβγδε", 4))
		h.eq("αβγδ", content.one_line("αβγδ", 4))
	end,
}
