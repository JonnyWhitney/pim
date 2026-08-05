local h = require("helpers")
local tree = require("pim.session_tree")

return {
	["flatten renders branch order, labels, and the active leaf"] = function()
		local rows = tree.flatten({
			{
				entry = {
					type = "message",
					id = "one",
					message = { role = "user", content = "Start work" },
				},
				children = {
					{
						entry = {
							type = "message",
							id = "two",
							message = { role = "assistant", content = { { type = "text", text = "First answer" } } },
						},
						label = "first",
						children = {},
					},
					{
						entry = {
							type = "message",
							id = "three",
							message = { role = "assistant", content = { { type = "text", text = "Second answer" } } },
						},
						children = {},
					},
				},
			},
		}, "three")

		h.eq(
			{ "one", "two", "three" },
			vim.tbl_map(function(row)
				return row.id
			end, rows)
		)
		h.eq("  You: Start work", rows[1].line)
		h.eq("  ├─ pi: First answer [first]", rows[2].line)
		h.eq("● └─ pi: Second answer", rows[3].line)
	end,

	["preview messages follow only the selected branch"] = function()
		local data = {
			{
				entry = { type = "message", id = "one", message = { role = "user", content = "Start work" } },
				children = {
					{
						entry = { type = "compaction", id = "two", summary = "Older work", tokensBefore = 100 },
						children = {
							{
								entry = {
									type = "message",
									id = "three",
									message = {
										role = "assistant",
										content = { { type = "text", text = "Chosen answer" } },
									},
								},
								children = {},
							},
						},
					},
					{
						entry = {
							type = "message",
							id = "other",
							message = { role = "assistant", content = { { type = "text", text = "Other answer" } } },
						},
						children = {},
					},
				},
			},
		}

		local path = tree.path(data, "three")
		h.eq(
			{ "one", "two", "three" },
			vim.tbl_map(function(entry)
				return entry.id
			end, path)
		)

		local messages = assert(tree.preview_messages(data, "three"))
		h.eq(
			{ "user", "compactionSummary", "assistant" },
			vim.tbl_map(function(message)
				return message.role
			end, messages)
		)
		h.eq(nil, tree.preview_messages(data, "missing"))
	end,

	["summaries identify session entry types"] = function()
		h.eq(
			"You: an empty prompt",
			tree.summary({ type = "message", message = { role = "user", content = "an empty prompt" } })
		)
		h.eq("result: bash", tree.summary({ type = "message", message = { role = "toolResult", toolName = "bash" } }))
		h.eq(
			"! git status",
			tree.summary({ type = "message", message = { role = "bashExecution", command = "git status" } })
		)
		h.eq("model: fake/other", tree.summary({ type = "model_change", provider = "fake", modelId = "other" }))
		h.eq("thinking: high", tree.summary({ type = "thinking_level_change", thinkingLevel = "high" }))
		h.eq("compacted conversation", tree.summary({ type = "compaction" }))
		h.eq("branch summary", tree.summary({ type = "branch_summary" }))
	end,
}
