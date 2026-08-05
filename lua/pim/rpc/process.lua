local framing = require("pim.rpc.framing")

local STDERR_TAIL_LINES = 50

local M = {}
---@class PimProcessHandle
---@field write fun(line: string): boolean
---@field stop fun(wait_ms: integer|nil)
---@field kill fun(signal: string|nil)
---@field is_running fun(): boolean

---@param opts { cmd: string[], cwd: string|nil, on_line: fun(line: string), on_exit: fun(code: integer, intentional: boolean, stderr_tail: string[]), on_error: fun(traceback: string, count: integer)|nil, on_overflow: fun(dropped: integer)|nil, max_line_bytes: integer|nil }
---@return PimProcessHandle|nil
---@return string|nil
function M.spawn(opts)
	if vim.fn.executable(opts.cmd[1]) ~= 1 then
		return nil, ("%q is not executable or not on $PATH"):format(opts.cmd[1])
	end

	local running = true
	local intentional = false
	local reader = framing.new(opts.max_line_bytes)
	local queued_lines = {}
	local drain_scheduled = false
	local stderr_tail = {}

	-- Run handlers on the scheduled main loop, not in the libuv stream callback.
	local function drain()
		drain_scheduled = false
		local lines = queued_lines
		queued_lines = {}
		local failures, first_error = 0, nil
		-- One bad event must not prevent later events in this batch.
		for _, line in ipairs(lines) do
			local ok, err = xpcall(opts.on_line, debug.traceback, line)
			if not ok then
				failures = failures + 1
				first_error = first_error or err
			end
		end
		if failures > 0 and opts.on_error then
			opts.on_error(tostring(first_error), failures)
		end
	end

	local function on_stdout(err, data)
		if err or data == nil then
			return
		end
		local lines, dropped = framing.feed(reader, data)
		if dropped > 0 and opts.on_overflow then
			vim.schedule(function()
				opts.on_overflow(dropped)
			end)
		end
		if #lines == 0 then
			return
		end
		vim.list_extend(queued_lines, lines)
		if not drain_scheduled then
			drain_scheduled = true
			vim.schedule(drain)
		end
	end

	local function on_stderr(err, data)
		if err or data == nil then
			return
		end
		for line in data:gmatch("[^\n]+") do
			stderr_tail[#stderr_tail + 1] = line
			if #stderr_tail > STDERR_TAIL_LINES then
				table.remove(stderr_tail, 1)
			end
		end
	end

	local spawned, system_obj = pcall(vim.system, opts.cmd, {
		stdin = true,
		stdout = on_stdout,
		stderr = on_stderr,
		cwd = opts.cwd,
	}, function(result)
		vim.schedule(function()
			running = false
			opts.on_exit(result.code, intentional, stderr_tail)
		end)
	end)
	if not spawned then
		return nil, tostring(system_obj)
	end

	local handle = {}

	function handle.write(line)
		if not running then
			return false
		end
		system_obj:write(line .. "\n")
		return true
	end

	function handle.stop(wait_ms)
		if not running then
			return
		end
		intentional = true
		system_obj:write(nil)
		vim.wait(wait_ms or 2000, function()
			return not running
		end, 50)
		if not running then
			return
		end
		system_obj:kill("sigterm")
		vim.wait(500, function()
			return not running
		end, 50)
		if running then
			system_obj:kill("sigkill")
		end
	end

	function handle.kill(signal)
		if running then
			system_obj:kill(signal or "sigkill")
		end
	end

	function handle.is_running()
		return running
	end

	return handle
end

return M
