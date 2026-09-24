local h = require("helpers")
local tree = require("pim.session_tree")

return {
	["hidden parents promote visible descendants without changing source links"] = function()
		local function node(kind, id, children)
			return {
				entry = { type = kind, id = id, parentId = "original", message = { role = "user", content = id } },
				children = children,
			}
		end
		local a = node("message", "a")
		local b = node("message", "b", { node("message", "nested") })
		local c = node("message", "c")
		local data = {
			node("branch_summary", "hidden-root", {
				node("message", "root", {
					node("compaction", "hidden", { node("branch_summary", "consecutive", { a, b }) }),
					node("compaction", "empty"),
					c,
					node("branch_summary", "hidden-leaf"),
				}),
			}),
		}
		local original = vim.deepcopy(data)
		local rows = tree.flatten(data, "hidden-leaf")
		h.eq(
			{ "  You: root", "  ├─ You: a", "  ├─ You: b", "  │  └─ You: nested", "  └─ You: c" },
			vim.tbl_map(function(row)
				return row.line
			end, rows)
		)
		h.eq(a.entry, rows[2].entry)
		h.eq(b.entry, rows[3].entry)
		h.eq("c", rows[5].id)
		h.eq(5, #assert(tree.path(data, "a")))
		h.eq(
			{ "root", "a" },
			vim.tbl_map(function(message)
				return message.content
			end, assert(tree.preview_messages(data, "a")))
		)
		h.eq(original, data)
		h.eq({}, tree.flatten({ node("compaction", "one", { node("branch_summary", "two") }) }, "two"))
	end,
	["tool results are hidden while their descendants remain selectable"] = function()
		local result = {
			entry = { type = "message", id = "result", message = { role = "toolResult", toolName = "bash" } },
			children = {
				{
					entry = { type = "message", id = "reply", message = { role = "assistant", content = "Done" } },
				},
			},
		}
		local data = {
			{
				entry = { type = "message", id = "call", message = { role = "assistant", content = "Running" } },
				children = {
					result,
					{
						entry = { type = "message", id = "other", message = { role = "assistant", content = "Other" } },
					},
				},
			},
		}
		local rows = tree.flatten(data, "reply")
		h.eq(
			{ "  pi: Running", "● ├─ pi: Done", "  └─ pi: Other" },
			vim.tbl_map(function(row)
				return row.line
			end, rows)
		)
		h.eq(
			{ "call", "result", "reply" },
			vim.tbl_map(function(entry)
				return entry.id
			end, assert(tree.path(data, "reply")))
		)
		h.eq(
			{ "assistant", "toolResult", "assistant" },
			vim.tbl_map(function(message)
				return message.role
			end, assert(tree.preview_messages(data, "reply")))
		)
		h.eq(
			{},
			tree.flatten(
				{ {
					entry = { type = "message", id = "result", message = { role = "toolResult" } },
				} },
				"result"
			)
		)
	end,
	["consecutive pi responses share one row without changing preview paths"] = function()
		local function message(id, role, text, children)
			return {
				entry = { type = "message", id = id, message = { role = role, content = text } },
				children = children,
			}
		end
		local data = {
			message("prompt", "user", "Start", {
				message("first", "assistant", "[response]", {
					message("result", "toolResult", "output", {
						message("second", "assistant", "[response]", {
							message("third", "assistant", "[response]", {
								message("followup", "user", "Continue"),
							}),
						}),
					}),
				}),
			}),
		}
		local original = vim.deepcopy(data)
		local rows = tree.flatten(data, "third")
		h.eq(
			{ "prompt", "third", "followup" },
			vim.tbl_map(function(row)
				return row.id
			end, rows)
		)
		h.eq(
			{ "  You: Start", "● └─ pi: [response] x 3", "     └─ You: Continue" },
			vim.tbl_map(function(row)
				return row.line
			end, rows)
		)
		h.eq(
			{ "user", "assistant", "toolResult", "assistant", "assistant" },
			vim.tbl_map(function(message)
				return message.role
			end, assert(tree.preview_messages(data, rows[2].id)))
		)
		h.eq(original, data)
	end,
	["pi response groups stop at branches and labels"] = function()
		local function assistant(id, children, label)
			return {
				entry = { type = "message", id = id, message = { role = "assistant", content = id } },
				children = children,
				label = label,
			}
		end
		local rows = tree.flatten(
			{ assistant("first", {
				assistant("second", { assistant("branch-a"), assistant("branch-b") }),
			}) },
			"branch-b"
		)
		h.eq(
			{ "  pi: first x 2", "  ├─ pi: branch-a", "● └─ pi: branch-b" },
			vim.tbl_map(function(row)
				return row.line
			end, rows)
		)
		local labeled = tree.flatten({ assistant("first", { assistant("second", nil, "saved") }) }, "second")
		h.eq(
			{ "  pi: first", "● └─ pi: second [saved]" },
			vim.tbl_map(function(row)
				return row.line
			end, labeled)
		)
	end,
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

		local path = assert(tree.path(data, "three"), "known entry must have a path")
		h.eq(
			{ "one", "two", "three" },
			vim.tbl_map(function(entry)
				return entry.id
			end, path)
		)

		local messages = assert(tree.preview_messages(data, "three"))
		h.eq(
			{ "user", "assistant" },
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
