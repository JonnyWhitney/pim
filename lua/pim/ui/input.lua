local layout = require("pim.ui.layout")

local M = {}

local history = {}
local nav_index = nil
local draft = nil
local attached = {}
local locked = false

local function get_text(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function set_text(buf, text)
	local lines = vim.split(text, "\n", { plain = true })
	local restore_lock = not vim.bo[buf].modifiable
	if restore_lock then
		vim.bo[buf].modifiable = true
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	if restore_lock then
		vim.bo[buf].modifiable = false
	end
	local win = layout.input_win()
	if win then
		vim.api.nvim_win_set_cursor(win, { #lines, math.max(#lines[#lines] - 1, 0) })
	end
end

local function resize()
	local win = layout.input_win()
	local buf = layout.input_buf()
	if not win or not buf then
		return
	end
	local cfg = require("pim.config").get().input
	local height = math.min(math.max(vim.api.nvim_buf_line_count(buf), cfg.min_height), cfg.max_height)
	if vim.api.nvim_win_get_height(win) ~= height then
		vim.api.nvim_win_set_config(win, { height = height })
	end
end

local function push_history(text)
	if history[#history] ~= text then
		history[#history + 1] = text
	end
	nav_index, draft = nil, nil
end

local function history_prev()
	local buf = layout.input_buf()
	if not buf or #history == 0 then
		return
	end
	if nav_index == nil then
		-- Save the unsent text so Down can restore it after history navigation.
		draft = get_text(buf)
		nav_index = #history + 1
	end
	if nav_index > 1 then
		nav_index = nav_index - 1
		set_text(buf, history[nav_index])
	end
end

local function history_next()
	local buf = layout.input_buf()
	if not buf or nav_index == nil then
		return
	end
	if nav_index < #history then
		nav_index = nav_index + 1
		set_text(buf, history[nav_index])
	else
		nav_index = nil
		set_text(buf, draft or "")
		draft = nil
	end
end

local function on_text_changed()
	resize()
	if nav_index ~= nil then
		local buf = layout.input_buf()
		if buf and get_text(buf) ~= history[nav_index] then
			nav_index, draft = nil, nil
		end
	end
end

---@param text string
---@param behavior "steer"|"followUp"|nil
---@param on_reject fun()|nil
local function dispatch(text, behavior, on_reject)
	local command, exclude_from_context = require("pim.bash").parse(text)
	if command then
		require("pim.bash").run(command, exclude_from_context)
		return
	end

	if not require("pim.state").is_busy() then
		layout.scroll_transcript_to_bottom()
	end
	local streaming_behavior = behavior or require("pim.config").get().streaming_submit
	require("pim.rpc.client").prompt(text, { streaming_behavior = streaming_behavior }, function(success, err)
		if not success then
			vim.notify("[pim] prompt rejected: " .. tostring(err), vim.log.levels.ERROR)
			if on_reject then
				on_reject()
			end
		end
	end)
end

---@param behavior "steer"|"followUp"|nil
function M.submit(behavior)
	if locked then
		vim.notify("[pim] Close the tree before sending a prompt", vim.log.levels.WARN)
		return
	end
	local buf = layout.input_buf()
	if not buf then
		return
	end
	local text = vim.trim(get_text(buf))
	if text == "" then
		return
	end

	push_history(text)
	set_text(buf, "")
	resize()

	dispatch(text, behavior, function()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		if vim.trim(get_text(buf)) == "" then
			set_text(buf, text)
			resize()
			return
		end
		vim.notify("[pim] pi did not send the prompt. Press <Up> to recall it.", vim.log.levels.WARN)
	end)
end

function M.send(text)
	if locked then
		vim.notify("[pim] Close the tree before sending a prompt", vim.log.levels.WARN)
		return
	end
	text = vim.trim(text or "")
	if text == "" then
		M.submit()
		return
	end
	push_history(text)
	dispatch(text)
end

function M.replace(text)
	local buf = layout.input_buf()
	if buf then
		set_text(buf, text or "")
		resize()
	end
end

---@param messages string[]
function M.restore_queued(messages)
	if #messages == 0 then
		return
	end

	for _, text in ipairs(messages) do
		history[#history + 1] = text
	end
	nav_index, draft = nil, nil

	local buf = layout.input_buf()
	if not buf then
		return
	end
	if get_text(buf) == "" then
		set_text(buf, messages[1])
		resize()
		return
	end

	vim.notify("[pim] Kept the current draft. Press <Up> to recall cleared queued prompts.", vim.log.levels.INFO)
end

---@param value boolean
function M.set_locked(value)
	locked = value
	local buf = layout.input_buf()
	if buf then
		vim.bo[buf].modifiable = not locked
	end
end

function M.is_locked()
	return locked
end

function M.reset()
	history = {}
	nav_index, draft = nil, nil
	attached = {}
	M.set_locked(false)
end

function M.setup()
	local buf = layout.input_buf()
	if not buf then
		return
	end
	local keymaps = require("pim.config").get().keymaps
	vim.bo[buf].modifiable = not locked

	vim.keymap.set("n", keymaps.submit, function()
		M.submit()
	end, { buffer = buf, desc = "Send prompt to pi" })

	vim.keymap.set("n", keymaps.submit_followup, function()
		M.submit("followUp")
	end, { buffer = buf, desc = "Send follow-up prompt to pi" })

	vim.keymap.set("n", keymaps.abort, require("pim").abort, { buffer = buf, desc = "Stop pi agent run" })

	vim.keymap.set("n", "<Up>", function()
		if vim.fn.line(".") == 1 then
			vim.schedule(history_prev)
			return ""
		end
		return "<Up>"
	end, { buffer = buf, expr = true, desc = "Previous prompt at first line" })

	vim.keymap.set("n", "<Down>", function()
		if vim.fn.line(".") == vim.fn.line("$") then
			vim.schedule(history_next)
			return ""
		end
		return "<Down>"
	end, { buffer = buf, expr = true, desc = "Next prompt at last line" })

	if not attached[buf] then
		attached[buf] = true
		vim.api.nvim_buf_attach(buf, false, {
			on_lines = function()
				vim.schedule(on_text_changed)
			end,
			on_detach = function()
				attached[buf] = nil
			end,
		})
	end

	resize()
end

return M
