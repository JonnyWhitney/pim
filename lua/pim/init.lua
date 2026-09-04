local M = {}

---@param opts table|nil
function M.setup(opts)
	require("pim.config").setup(opts)
end

local function setup_transcript_keymaps()
	local layout = require("pim.ui.layout")
	local keymaps = require("pim.config").get().keymaps
	local buf = layout.transcript_buf()

	vim.keymap.set("n", keymaps.toggle_fold, function()
		vim.cmd("silent! normal! za")
	end, { buffer = buf, desc = "Toggle fold under cursor" })

	vim.keymap.set("n", keymaps.abort, M.abort, { buffer = buf, desc = "Abort the pi agent" })
end

local function restore_input()
	M.start()
end

function M.watch_input_close()
	local layout = require("pim.ui.layout")
	local win = layout.input_win()
	if not win then
		return
	end

	vim.api.nvim_create_autocmd("WinClosed", {
		group = vim.api.nvim_create_augroup("pim-exit", { clear = true }),
		pattern = tostring(win),
		once = true,
		callback = function()
			if layout.is_closing() or vim.v.exiting ~= vim.NIL then
				return
			end
			-- WinClosed runs while Neovim changes the layout. Ask after that work completes.
			vim.schedule(function()
				M.stop({ on_decline = restore_input })
			end)
		end,
	})
end

---@param extra_args string[]|nil
---@return boolean
local function connect(extra_args)
	local client = require("pim.rpc.client")
	local state = require("pim.state")
	local transcript = require("pim.ui.transcript")

	state.reset()
	local started, spawn_error = client.start({
		extra_args = extra_args,
		on_event = require("pim.events").handle,
		on_ui_request = require("pim.ui.dialogs").handle,
		on_exit = function(code, intentional, stderr_tail)
			require("pim.ui.dialogs").reset()
			require("pim.ui.tree").reset()
			transcript.divider(("*pi exited (code %d%s)*"):format(code, intentional and ", requested" or ""))
			---@type integer|PimStateNone
			local exit_code = state.NONE
			if not intentional then
				exit_code = code
			end
			state.update({ connected = false, is_streaming = false, stopped = intentional, exit_code = exit_code })
			if not intentional then
				local detail = #stderr_tail > 0 and ("\n" .. table.concat(stderr_tail, "\n")) or ""
				vim.notify(
					("[pim] pi stopped with code %d.%s Run :PiRestart to resume the session."):format(code, detail),
					vim.log.levels.ERROR
				)
			end
		end,
	})

	if not started then
		local message = ("Cannot start pi: %s"):format(spawn_error)
		state.update({ connected = false, spawn_error = spawn_error })
		transcript.divider("*" .. message .. "*")
		vim.notify(
			("[pim] %s\npi_cmd = %s"):format(message, vim.inspect(require("pim.config").get().pi_cmd)),
			vim.log.levels.ERROR
		)
		return false
	end

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("pim-shutdown", { clear = true }),
		callback = function()
			require("pim.ui.statusline").shutdown()
			require("pim.ui.transcript").shutdown()
			require("pim.ui.dialogs").reset()
			require("pim.rpc.client").stop(1000)
		end,
	})
	return true
end

function M.start()
	local client = require("pim.rpc.client")
	local layout = require("pim.ui.layout")

	layout.open()
	setup_transcript_keymaps()
	require("pim.ui.input").setup()
	require("pim.completion").attach()
	require("pim.ui.statusline").attach()
	M.watch_input_close()

	if client.is_running() then
		return
	end

	if connect() then
		M.refresh()
	end
end

function M.restart()
	local client = require("pim.rpc.client")
	if client.is_running() then
		client.stop()
	end

	local session_file = require("pim.state").get().session_file
	local extra_args = nil
	if session_file and vim.uv.fs_stat(session_file) then
		extra_args = { "--session", session_file }
	end

	if connect(extra_args) then
		M.refresh()
	end
end

function M.toggle()
	local layout = require("pim.ui.layout")
	if layout.is_open() then
		layout.hide()
	else
		M.start()
	end
end

function M.refresh()
	local client = require("pim.rpc.client")
	local events = require("pim.events")
	local state = require("pim.state")

	client.get_state(function(success, data)
		if not success then
			vim.notify("[pim] get_state failed: " .. tostring(data), vim.log.levels.ERROR)
		elseif type(data) ~= "table" then
			vim.notify("[pim] pi did not return state data", vim.log.levels.WARN)
		else
			state.apply_rpc_state(data)
			state.poll_stats()
		end
	end)
	client.get_messages(function(success, data)
		if not success then
			vim.notify("[pim] failed to load history: " .. tostring(data), vim.log.levels.ERROR)
		elseif type(data) ~= "table" then
			vim.notify("[pim] pi did not return history data", vim.log.levels.WARN)
		else
			events.load_messages(data.messages)
		end
	end)
	require("pim.completion").refresh_commands()
end

function M.new_session()
	require("pim.rpc.client").new_session(function(success, data)
		if not success then
			vim.notify("[pim] new_session failed: " .. tostring(data), vim.log.levels.ERROR)
		elseif type(data) == "table" and data.cancelled then
			vim.notify("[pim] new session cancelled by an extension", vim.log.levels.WARN)
		else
			M.refresh()
		end
	end)
end

local function can_change_session()
	if require("pim.ui.tree").is_open() then
		vim.notify("[pim] Close the tree before changing the session", vim.log.levels.WARN)
		return false
	end
	local state = require("pim.state").get()
	if not state.is_streaming and not state.is_compacting and not state.bash_running and not state.retrying then
		return true
	end
	vim.notify("[pim] Cannot change the session while pi is busy", vim.log.levels.WARN)
	return false
end

---@param entry_id string
function M.fork(entry_id)
	if not can_change_session() then
		return
	end

	require("pim.rpc.client").fork(entry_id, function(success, data)
		if not success then
			vim.notify("[pim] fork failed: " .. tostring(data), vim.log.levels.ERROR)
		elseif type(data) == "table" and data.cancelled then
			vim.notify("[pim] fork cancelled by an extension", vim.log.levels.WARN)
		elseif type(data) ~= "table" or type(data.text) ~= "string" then
			vim.notify("[pim] pi did not return the forked prompt", vim.log.levels.WARN)
		else
			require("pim.ui.input").replace(data.text)
			M.refresh()
		end
	end)
end

function M.clone()
	if not can_change_session() then
		return
	end

	require("pim.rpc.client").clone(function(success, data)
		if not success then
			vim.notify("[pim] clone failed: " .. tostring(data), vim.log.levels.ERROR)
		elseif type(data) == "table" and data.cancelled then
			vim.notify("[pim] clone cancelled by an extension", vim.log.levels.WARN)
		else
			require("pim.ui.input").replace("")
			M.refresh()
		end
	end)
end

local function teardown()
	local layout = require("pim.ui.layout")
	local exit_neovim = layout.owns_only_ui()
	require("pim.rpc.client").stop()
	layout.destroy()
	if exit_neovim then
		vim.cmd("quit")
	end
end

---@param opts { confirm: boolean|nil, on_decline: fun()|nil }|nil
function M.stop(opts)
	opts = opts or {}
	if opts.confirm == false then
		teardown()
		return
	end

	local prompt = require("pim.ui.layout").is_open() and "Stop pi and close the pi tab?" or "Stop pi?"

	vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
		if choice == "Yes" then
			teardown()
		elseif opts.on_decline then
			opts.on_decline()
		end
	end)
end

local function queued_messages(data)
	if type(data) ~= "table" or type(data.steering) ~= "table" or type(data.followUp) ~= "table" then
		return nil
	end

	local messages = {}
	for _, queue in ipairs({ data.steering, data.followUp }) do
		for _, text in ipairs(queue) do
			if type(text) ~= "string" then
				return nil
			end
			messages[#messages + 1] = text
		end
	end
	return messages
end

function M.abort()
	local state = require("pim.state").get()
	if state.bash_running then
		require("pim.bash").abort()
	elseif state.is_streaming then
		local client = require("pim.rpc.client")
		client.clear_queue(function(success, data)
			if not success then
				vim.notify("[pim] clear_queue failed: " .. tostring(data), vim.log.levels.ERROR)
			else
				local messages = queued_messages(data)
				if messages then
					local recovered, err = pcall(require("pim.ui.input").restore_queued, messages)
					if not recovered then
						vim.notify("[pim] Cannot restore cleared prompts: " .. tostring(err), vim.log.levels.ERROR)
					end
				else
					vim.notify("[pim] pi returned invalid clear_queue data", vim.log.levels.ERROR)
				end
			end
			client.abort()
		end)
	end
end

return M
