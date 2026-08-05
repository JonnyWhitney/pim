local config = require("pim.config")
local log = require("pim.log")
local process = require("pim.rpc.process")

local M = {}

local DEFAULT_REQUEST_TIMEOUT_MS = 30000

-- Shell commands can run for an unknown time. Do not reject them as inactive RPC calls.
local NO_DEADLINE = { bash = true }

---@type PimProcessHandle|nil
local proc = nil
local next_id = 0
local pending = {}
local handlers = {}

local function build_cmd(extra_args)
	local opts = config.get()
	local cmd = type(opts.pi_cmd) == "table" and vim.deepcopy(opts.pi_cmd) or { opts.pi_cmd }
	vim.list_extend(cmd, opts.args)
	vim.list_extend(cmd, extra_args or {})
	vim.list_extend(cmd, { "--mode", "rpc" })
	return cmd
end

local function cancel_timer(entry)
	if entry.timer then
		entry.timer:stop()
		entry.timer:close()
		entry.timer = nil
	end
end

local function take_pending(id)
	local entry = pending[id]
	if entry then
		pending[id] = nil
		cancel_timer(entry)
	end
	return entry
end

local function reject_all_pending(reason)
	-- Detach the table before callbacks run. A callback can start a new request.
	local rejected = pending
	pending = {}
	for _, entry in pairs(rejected) do
		cancel_timer(entry)
		entry.callback(false, reason)
	end
end

local function start_deadline(id, entry, timeout_ms)
	local timer = vim.uv.new_timer()
	if not timer then
		log.add("!", ("No timer is available. %s has no timeout."):format(entry.command))
		return nil
	end
	timer:start(timeout_ms, 0, function()
		vim.schedule(function()
			if pending[id] ~= entry then
				return
			end
			take_pending(id)
			log.add("!", ("%s had no response after %d ms"):format(entry.command, timeout_ms))
			entry.callback(false, "pi did not respond")
		end)
	end)
	return timer
end

local function handle_response(message)
	local entry
	if message.id then
		entry = take_pending(message.id)
	end
	if entry then
		if message.success == true then
			entry.callback(true, message.data)
		else
			entry.callback(false, message.error)
		end
	elseif message.success == false then
		log.add("!", ("Unexpected %s error: %s"):format(tostring(message.command), tostring(message.error)))
		vim.notify(
			("[pim] pi error (%s): %s"):format(tostring(message.command), tostring(message.error)),
			vim.log.levels.ERROR
		)
	end
end

local function on_line(line)
	log.raw("<-", line)
	local ok, message = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
	if not ok or type(message) ~= "table" then
		log.add("!", "Cannot decode line: " .. line)
		return
	end

	if message.type == "response" then
		handle_response(message)
	elseif message.type == "extension_ui_request" then
		if handlers.on_ui_request then
			handlers.on_ui_request(message)
		end
	elseif handlers.on_event then
		handlers.on_event(message)
	end
end

---@param opts { on_event: fun(event: table)|nil, on_ui_request: fun(request: table)|nil, on_exit: fun(code: integer, intentional: boolean, stderr_tail: string[])|nil, cwd: string|nil, extra_args: string[]|nil, request_timeout_ms: integer|nil }|nil
---@return boolean
---@return string|nil
function M.start(opts)
	if M.is_running() then
		error("[pim] pi is already running", 0)
	end
	handlers = opts or {}
	next_id = 0
	reject_all_pending("pi restarted")

	local cmd = build_cmd(opts and opts.extra_args)
	log.add("*", "spawn: " .. table.concat(cmd, " "))
	local handle, err = process.spawn({
		cmd = cmd,
		cwd = opts and opts.cwd or nil,
		on_line = on_line,
		on_error = function(traceback, count)
			log.add("!", ("%d handler error(s), first:\n%s"):format(count, traceback))
			vim.notify(
				("[pim] Cannot handle %d incoming message%s. See :PiLog."):format(count, count == 1 and "" or "s"),
				vim.log.levels.ERROR
			)
		end,
		on_overflow = function(dropped)
			log.add("!", ("Dropped %d bytes without a line terminator. Read the next message."):format(dropped))
			vim.notify(
				"[pim] pi sent a message that is too large. Part of the conversation can be missing. See :PiLog.",
				vim.log.levels.WARN
			)
		end,
		on_exit = function(code, intentional, stderr_tail)
			log.add("*", ("pi exited with code %d%s"):format(code, intentional and " (requested)" or ""))
			reject_all_pending("pi exited")
			if handlers.on_exit then
				handlers.on_exit(code, intentional, stderr_tail)
			end
		end,
	})

	if not handle then
		log.add("!", "spawn failed: " .. tostring(err))
		return false, err
	end
	proc = handle
	return true
end

function M.stop(wait_ms)
	if proc then
		proc.stop(wait_ms)
	end
end

function M.kill()
	if proc then
		proc.kill()
	end
end

function M.is_running()
	return proc ~= nil and proc.is_running()
end

---@param command_type string
---@param params table|nil
---@param callback fun(success: boolean, payload: any)|nil
function M.request(command_type, params, callback)
	local active = proc
	if not active or not active.is_running() then
		if callback then
			callback(false, "pi is not running")
		end
		return
	end

	next_id = next_id + 1
	local id = "nvp-" .. next_id
	local message = vim.tbl_extend("force", params or {}, { type = command_type, id = id })
	if callback then
		local entry = { command = command_type, callback = callback }
		pending[id] = entry
		if not NO_DEADLINE[command_type] then
			entry.timer = start_deadline(id, entry, handlers.request_timeout_ms or DEFAULT_REQUEST_TIMEOUT_MS)
		end
	end

	local line = vim.json.encode(message)
	log.raw("->", line)
	active.write(line)
end

---@param id string
---@param payload table
function M.respond_ui(id, payload)
	local active = proc
	if not active or not active.is_running() then
		return
	end
	local message = vim.tbl_extend("force", payload, { type = "extension_ui_response", id = id })
	local line = vim.json.encode(message)
	log.raw("->", line)
	active.write(line)
end

function M.get_state(callback)
	M.request("get_state", nil, callback)
end

function M.get_messages(callback)
	M.request("get_messages", nil, callback)
end

function M.get_commands(callback)
	M.request("get_commands", nil, callback)
end

function M.abort(callback)
	M.request("abort", nil, callback)
end

---@param command string
---@param exclude_from_context boolean|nil
function M.bash(command, exclude_from_context, callback)
	M.request("bash", { command = command, excludeFromContext = exclude_from_context or nil }, callback)
end

function M.abort_bash(callback)
	M.request("abort_bash", nil, callback)
end

function M.get_available_models(callback)
	M.request("get_available_models", nil, callback)
end

function M.set_model(provider, model_id, callback)
	M.request("set_model", { provider = provider, modelId = model_id }, callback)
end

function M.get_available_thinking_levels(callback)
	M.request("get_available_thinking_levels", nil, callback)
end

---@param level "off"|"minimal"|"low"|"medium"|"high"|"xhigh"|"max"
function M.set_thinking_level(level, callback)
	M.request("set_thinking_level", { level = level }, callback)
end

function M.switch_session(session_path, callback)
	M.request("switch_session", { sessionPath = session_path }, callback)
end

function M.new_session(callback)
	M.request("new_session", nil, callback)
end

function M.get_fork_messages(callback)
	M.request("get_fork_messages", nil, callback)
end

function M.get_tree(callback)
	M.request("get_tree", nil, callback)
end

---@param entry_id string
function M.fork(entry_id, callback)
	M.request("fork", { entryId = entry_id }, callback)
end

function M.clone(callback)
	M.request("clone", nil, callback)
end

---@param message string
---@param opts { images: table[]|nil, streaming_behavior: "steer"|"followUp"|nil }|nil
function M.prompt(message, opts, callback)
	M.request("prompt", {
		message = message,
		images = opts and opts.images or nil,
		streamingBehavior = opts and opts.streaming_behavior or nil,
	}, callback)
end

return M
