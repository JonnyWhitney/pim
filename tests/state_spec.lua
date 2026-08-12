local h = require("helpers")
local state = require("pim.state")
local statusline = require("pim.ui.statusline")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function connect_fake_pi(scenario)
	require("pim.config").setup({ pi_cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua", scenario } })
	local client = require("pim.rpc.client")
	h.ok(client.start({}), "fake pi started")
	h.wait_until(client.is_running, "fake pi to be running", 5000)
end

return {
	["apply_rpc_state maps the RPC payload"] = function()
		state.apply_rpc_state({
			model = { id = "m1", name = "Model One", provider = "prov" },
			thinkingLevel = "medium",
			isStreaming = false,
			isCompacting = false,
			sessionId = "sid",
			sessionName = "my session",
			sessionFile = "/tmp/s.jsonl",
		})
		local current = state.get()
		h.eq(true, current.connected)
		h.eq("Model One", current.model.name)
		h.eq("medium", current.thinking_level)
		h.eq("my session", current.session_name)
		h.eq("/tmp/s.jsonl", current.session_file)
	end,

	["apply_rpc_state clears fields the new snapshot omits"] = function()
		state.apply_rpc_state({
			model = { id = "m1", name = "Model One" },
			thinkingLevel = "high",
			sessionId = "old-id",
			sessionName = "refactor",
			sessionFile = "/tmp/old.jsonl",
		})

		state.apply_rpc_state({ sessionId = "fresh-id" })

		local current = state.get()
		h.eq("fresh-id", current.session_id)
		h.eq(nil, current.session_name, "the previous session's name must not survive")
		h.eq(nil, current.session_file, "restart() would otherwise resume the session we just left")
		h.eq(nil, current.thinking_level)
		h.eq(nil, current.model)
	end,

	["state stores the resolved pi config directory"] = function()
		h.eq(require("pim.config").pi_config_dir(), state.get().config_dir)
		state.reset()
		h.eq(require("pim.config").pi_config_dir(), state.get().config_dir)
	end,

	["update assigns false as false, not nil"] = function()
		state.update({ connected = true, is_streaming = true })
		state.update({ connected = false, is_streaming = false })

		h.eq(false, state.get().connected)
		h.eq(false, state.get().is_streaming)
	end,

	["update clears a field with NONE and only with NONE"] = function()
		state.update({ exit_code = 7, context_percent = 42 })

		state.update({ exit_code = nil })
		h.eq(7, state.get().exit_code, "a nil value cannot clear a field")

		state.update({ exit_code = state.NONE })
		h.eq(nil, state.get().exit_code)
		h.eq(42, state.get().context_percent, "NONE clears only the key it is assigned to")
	end,

	["poll_stats stores current context usage"] = function()
		connect_fake_pi()

		state.poll_stats()

		h.wait_until(function()
			return state.get().context_tokens == 12000
		end, "poll_stats to store context usage", 5000)
		local current = state.get()
		h.eq(100000, current.context_window)
		h.eq(12, current.context_percent)
	end,

	["poll_stats clears stale context usage when contextUsage is absent"] = function()
		connect_fake_pi("nocontext")
		state.update({ context_tokens = 42000, context_window = 100000, context_percent = 42 })

		state.poll_stats()

		h.wait_until(function()
			return state.get().context_percent == nil
		end, "poll_stats to clear stale context usage", 5000)
		local current = state.get()
		h.eq(nil, current.context_tokens)
		h.eq(nil, current.context_window)
	end,

	["poll_stats clears all context usage when the current count is null"] = function()
		connect_fake_pi("nullcontext")
		state.update({ context_tokens = 42000, context_window = 100000, context_percent = 42 })

		state.poll_stats()

		h.wait_until(function()
			return state.get().context_percent == nil
		end, "poll_stats to clear null context usage", 5000)
		local current = state.get()
		h.eq(nil, current.context_tokens)
		h.eq(nil, current.context_window)
	end,

	["observers fire on every update"] = function()
		local seen = 0
		state.subscribe(function()
			seen = seen + 1
		end)
		state.update({ is_streaming = true })
		state.update({ is_streaming = false })
		h.eq(2, seen)
	end,

	["events toggle streaming, compaction, retry, and session info"] = function()
		state.handle_event({ type = "agent_start" })
		h.eq(true, state.get().is_streaming)
		state.handle_event({ type = "agent_end", willRetry = false })
		h.eq(false, state.get().is_streaming)

		state.handle_event({ type = "compaction_start", reason = "manual" })
		h.eq(true, state.get().is_compacting)
		state.handle_event({ type = "compaction_end", reason = "manual" })
		h.eq(false, state.get().is_compacting)

		state.handle_event({ type = "auto_retry_start", attempt = 1 })
		h.eq(true, state.get().retrying)
		state.handle_event({ type = "auto_retry_end", success = true })
		h.eq(false, state.get().retrying)

		state.handle_event({ type = "session_info_changed", name = "renamed" })
		h.eq("renamed", state.get().session_name)
		state.handle_event({ type = "thinking_level_changed", level = "high" })
		h.eq("high", state.get().thinking_level)
	end,

	["a summarization retry marks the session as retrying"] = function()
		state.handle_event({
			type = "summarization_retry_scheduled",
			attempt = 1,
			maxAttempts = 3,
			delayMs = 2000,
			errorMessage = "terminated",
		})
		h.eq(true, state.get().retrying)
		state.handle_event({ type = "summarization_retry_finished" })
		h.eq(false, state.get().retrying)

		state.handle_event({ type = "summarization_retry_attempt_start", source = "compaction", reason = "threshold" })
		h.eq(true, state.get().retrying)
		state.handle_event({ type = "summarization_retry_finished" })
		h.eq(false, state.get().retrying)
	end,

	["ext status entries set and clear"] = function()
		state.set_ext_status("gate", "guard: on")
		h.eq("guard: on", state.get().ext_status.gate)
		state.set_ext_status("gate", nil)
		h.eq(nil, state.get().ext_status.gate)
	end,

	["winbar shows pi details before dynamic session state"] = function()
		local bar = statusline.build({
			connected = true,
			model = { id = "m1", name = "Model One", provider = "prov" },
			thinking_level = "medium",
			config_dir = "~/.pi-personal/agent",
			context_tokens = 12000,
			context_window = 100000,
			context_percent = 12,
			session_name = "refactor",
			ext_status = { gate = "guard: on" },
			ext_widgets = { widget = { "widget: ready" } },
		})
		h.eq(
			" pi │ Provider: prov │ Model: Model One │ Thinking: medium │ Config: ~/.pi-personal/agent │ ctx:12k/100k (12%%) │ refactor │ guard: on │ widget: ready",
			bar
		)
	end,

	["winbar uses a regular dash for unavailable pi details"] = function()
		local bar = statusline.build({ connected = true, ext_status = {} })
		h.eq(" pi │ Provider: - │ Model: - │ Thinking: - │ Config: -", bar)
	end,

	["winbar escapes statusline metacharacters"] = function()
		local bar = statusline.build({
			connected = true,
			session_name = "100% done",
			ext_status = {},
		})
		h.ok(bar:find("100%%%% done"), "percent signs must be doubled")
	end,

	["winbar shows connection lifecycle"] = function()
		local connecting = statusline.build({ connected = false, ext_status = {} })
		h.ok(connecting:find("connecting…", 1, true), "connecting marker")

		local dead = statusline.build({ connected = false, exit_code = 9, ext_status = {} })
		h.ok(dead:find("exited(9)", 1, true), "exit marker")

		local stopped = statusline.build({ connected = false, stopped = true, ext_status = {} })
		h.ok(stopped:find("stopped", 1, true), "stopped marker")
		h.ok(not stopped:find("connecting", 1, true), "no connecting marker after a requested stop")

		local unstarted = statusline.build({ connected = false, spawn_error = "not executable", ext_status = {} })
		h.ok(unstarted:find("failed to start", 1, true), "spawn failure marker")
		h.ok(not unstarted:find("connecting", 1, true), "no connecting marker after a failed spawn")
	end,

	["statusline shutdown is idempotent"] = function()
		statusline.attach()
		state.update({ is_streaming = true })

		statusline.shutdown()
		statusline.shutdown()

		state.update({ is_streaming = false })
	end,

	["winbar shows thinking when off"] = function()
		local bar = statusline.build({ connected = true, thinking_level = "off", ext_status = {} })
		h.ok(bar:find("Thinking: off", 1, true), "thinking level present when off")
	end,
}
