local h = require("helpers")
local control = require("pim.subagents.control")
local cleanup = require("pim.subagents.cleanup")

local function replace(module, fields, fn)
	local saved = {}
	for key, value in pairs(fields) do
		saved[key] = module[key]
		module[key] = value
	end
	local ok, err = xpcall(fn, debug.traceback)
	for key, value in pairs(saved) do
		module[key] = value
	end
	if not ok then
		error(err, 0)
	end
end

local function storage(fn)
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")
	root = assert(vim.uv.fs_realpath(root))
	local ok, err = xpcall(function()
		replace(require("pim.subagents"), {
			transcript_root = function()
				return root
			end,
		}, function()
			fn(root)
		end)
	end, debug.traceback)
	vim.fn.delete(root, "rf")
	if not ok then
		error(err, 0)
	end
end

local function manifest(root, id, status)
	local directory = vim.fs.joinpath(root, "parent", id)
	vim.fn.mkdir(directory, "p")
	local value = {
		schemaVersion = 1,
		invocationId = id,
		mode = "single",
		status = status or "completed",
		transcriptDir = directory,
		parentSessionId = "parent",
		parentSessionFile = root .. "/session.jsonl",
		agents = {
			{
				id = "child",
				label = "review",
				status = status or "completed",
				transcriptPath = directory .. "/child.jsonl",
			},
		},
	}
	vim.fn.writefile({ vim.json.encode(value) }, directory .. "/invocation.json")
	return value
end

return {
	["stops steer only after matching acknowledgement and only once"] = function()
		local sent = {}
		control.reset()
		require("pim.state").update({ session_id = "parent" })
		replace(require("pim.rpc.client"), {
			prompt = function(text, _, callback)
				sent[#sent + 1] = { "prompt", text }
				callback(true)
			end,
			request = function(kind, params, callback)
				sent[#sent + 1] = { kind, params.message }
				callback(true)
			end,
		}, function()
			control.request({ invocation_id = "invocation" }, "child")
			h.eq(1, #sent)
			local token = sent[1][2]:match("^/pim%-internal%-agent%-stop (%S+) invocation child$")
			h.ok(token and token:match("^[A-Za-z0-9_-]+$"))
			local ack = {
				method = "setStatus",
				statusKey = "pim-agent-stop",
				statusText = vim.json.encode({ token = token, labels = { "review", "tests" } }),
			}
			h.ok(control.acknowledge(ack))
			h.eq("steer", sent[2][1])
			h.ok(sent[2][2]:find('"review", "tests"', 1, true))
			control.acknowledge(ack)
			h.eq(2, #sent)
			h.eq(false, control.acknowledge({ method = "notify" }))
			h.ok(control.acknowledge({ method = "setStatus", statusKey = "pim-agent-stop", statusText = "{}" }))
		end)
	end,

	["no-op stops, parent abort, failed requests and session changes do not steer"] = function()
		for _, scenario in ipairs({ "noop", "abort", "failed", "session" }) do
			control.reset()
			require("pim.state").update({ session_id = "parent" })
			local token
			replace(require("pim.rpc.client"), {
				prompt = function(text, _, callback)
					token = text:match("^/pim%-internal%-agent%-stop (%S+)")
					callback(scenario ~= "failed", "rejected")
				end,
				request = function(kind)
					h.eq("abort", kind)
				end,
			}, function()
				control.request({ invocation_id = "invocation" }, "*")
				if scenario == "abort" then
					require("pim.rpc.client").abort()
				end
				if scenario == "session" then
					require("pim.state").update({ session_id = "other" })
				end
				control.acknowledge({
					method = "setStatus",
					statusKey = "pim-agent-stop",
					statusText = vim.json.encode({ token = token, labels = scenario == "noop" and {} or { "review" } }),
				})
			end)
		end
	end,

	["stop picker routes single and aggregate choices without historical children"] = function()
		local state = require("pim.subagents.state")
		state.reset()
		local value = {
			schemaVersion = 1,
			mode = "parallel",
			status = "running",
			transcriptDir = "/tmp/live",
			invocationId = "live",
			agents = {
				{ id = "a", label = "A", status = "running", transcriptPath = "/tmp/live/a.jsonl" },
				{ id = "b", label = "B", status = "pending", transcriptPath = "/tmp/live/b.jsonl" },
			},
		}
		state.update("call", value)
		local old = vim.deepcopy(value)
		old.invocationId = "old"
		state.update("old-call", old, nil, true)
		for _, all in ipairs({ false, true }) do
			replace(vim.ui, {
				select = function(items, _, callback)
					h.eq(all and 1 or 2, #items)
					callback(items[1])
				end,
			}, function()
				replace(control, {
					request = function(invocation, id)
						h.eq("live", invocation.invocation_id)
						h.eq(all and "*" or "a", id)
					end,
				}, function()
					control.stop(all)
				end)
			end)
		end
	end,

	["cleanup retains parent sessions and starts grace on first orphan observation"] = function()
		storage(function(root)
			local value = manifest(root, "retained")
			vim.fn.writefile({}, value.parentSessionFile)
			h.eq(1, cleanup.run(true, 100).retained)
			vim.fn.delete(value.parentSessionFile)
			h.eq(1, cleanup.run(false, 200).retained)
			h.eq(1, cleanup.run(false, 200 + 29 * 86400).retained)
			h.eq(1, cleanup.run(false, 200 + 30 * 86400).removed)
		end)
	end,

	["cleanup force bypasses grace but protects active and ambiguous manifests"] = function()
		storage(function(root)
			manifest(root, "orphan")
			manifest(root, "active", "running")
			local invalid = manifest(root, "invalid")
			invalid.parentSessionFile = nil
			vim.fn.writefile({ vim.json.encode(invalid) }, invalid.transcriptDir .. "/invocation.json")
			local ambiguous = manifest(root, "ambiguous")
			vim.fn.writefile({ "unrecognized" }, ambiguous.transcriptDir .. "/unknown.txt")
			local live = manifest(root, "live")
			require("pim.subagents.state").update("call", vim.tbl_extend("force", live, { status = "running" }))
			local report = cleanup.run(true, 100)
			h.eq({ removed = 1, retained = 2, skipped = 2 }, report)
		end)
	end,

	["cleanup rejects symlinks, traversal and malformed orphan markers"] = function()
		storage(function(root)
			local link = manifest(root, "linked")
			h.ok(vim.uv.fs_symlink(root, link.transcriptDir .. "/child.jsonl"))
			local bad = manifest(root, "traversal")
			bad.agents[1].transcriptPath = root .. "/victim"
			vim.fn.writefile({ vim.json.encode(bad) }, bad.transcriptDir .. "/invocation.json")
			local marker = manifest(root, "marker")
			vim.fn.writefile({ "{}" }, marker.transcriptDir .. "/orphaned.json")
			h.eq({ removed = 0, retained = 0, skipped = 3 }, cleanup.run(true, 100))
		end)
	end,

	["restored parent sessions reset the orphan grace period"] = function()
		storage(function(root)
			local value = manifest(root, "restored")
			h.eq(1, cleanup.run(false, 100).retained)
			vim.fn.writefile({}, value.parentSessionFile)
			h.eq(1, cleanup.run(false, 200).retained)
			h.eq(nil, vim.uv.fs_lstat(value.transcriptDir .. "/orphaned.json"))
			vim.fn.delete(value.parentSessionFile)
			h.eq(1, cleanup.run(false, 100 + 30 * 86400).retained)
		end)
	end,

	["cleanup rejects linked roots and malformed manifests"] = function()
		storage(function(root)
			local value = manifest(root, "broken")
			vim.fn.writefile({ "not json" }, value.transcriptDir .. "/invocation.json")
			h.eq(1, cleanup.run(true).skipped)
			local linked = root .. "/linked"
			h.ok(vim.uv.fs_symlink(root .. "/parent", linked))
			replace(require("pim.subagents"), {
				transcript_root = function()
					return linked
				end,
			}, function()
				h.eq({ removed = 0, retained = 0, skipped = 1 }, cleanup.run(true))
			end)
		end)
	end,

	["disabled subagent controls do not select, stop or clean"] = function()
		require("pim.config").setup({ subagents = { enabled = false } })
		replace(vim.ui, {
			select = function()
				error("Selection must not be opened")
			end,
		}, function()
			replace(cleanup, {
				run = function()
					error("Cleanup must not be run")
				end,
			}, function()
				control.stop(false)
				control.stop(true)
				cleanup.clean(false)
				cleanup.clean(true)
			end)
		end)
	end,

	["cleanup grace configuration is strictly validated"] = function()
		local config = require("pim.config")
		for _, value in ipairs({ -1, 0.5, "30", math.huge }) do
			h.fails(function()
				config.setup({ subagents = { orphan_grace_days = value } })
			end, "orphan_grace_days")
		end
		config.setup({ subagents = { orphan_grace_days = 0 } })
		h.eq(0, config.get().subagents.orphan_grace_days)
	end,
}
