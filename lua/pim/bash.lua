local M = {}

local counter = 0

---@param text string
---@return string|nil
---@return boolean
function M.parse(text)
	if not require("pim.config").get().bash_passthrough then
		return nil, false
	end

	-- A second ! prevents pi from adding output to the next prompt context.
	local exclude = text:sub(1, 2) == "!!"
	if not exclude and text:sub(1, 1) ~= "!" then
		return nil, false
	end

	local command = vim.trim(text:sub(exclude and 3 or 2))
	if command == "" then
		return nil, false
	end
	return command, exclude
end

local function show(key, message, final)
	require("pim.ui.transcript").set(
		key,
		"bash",
		require("pim.ui.render").message(message),
		final and { final = true } or nil
	)
end

---@param command string
---@param exclude_from_context boolean
function M.run(command, exclude_from_context)
	local state = require("pim.state")

	counter = counter + 1
	local key = ("bash-%d"):format(counter)
	local base = { role = "bashExecution", command = command, excludeFromContext = exclude_from_context }

	show(key, vim.tbl_extend("force", base, { running = true }), false)
	state.update({ bash_running = true })

	require("pim.rpc.client").bash(command, exclude_from_context, function(success, payload)
		state.update({ bash_running = false })
		if not success or type(payload) ~= "table" then
			show(key, vim.tbl_extend("force", base, { failed = true, output = tostring(payload) }), true)
			return
		end
		show(key, vim.tbl_extend("force", payload, base), true)
	end)
end

function M.abort()
	require("pim.rpc.client").abort_bash()
end

function M.reset()
	counter = 0
end

return M
