local M = {}

-- vim.ui dialogs are interactive. Show one blocking request at a time.
local queue = {}
local active = nil

local function is_active(request)
	return active ~= nil and active.request.id == request.id
end

local process_next

local function finish(response)
	local current = active
	if not current then
		return
	end
	active = nil
	if current.timer then
		current.timer:stop()
		current.timer:close()
	end
	if current.cleanup then
		pcall(current.cleanup)
	end
	if response then
		require("pim.rpc.client").respond_ui(current.request.id, response)
	end
	vim.schedule(process_next)
end

local function show_select(request)
	vim.ui.select(request.options or {}, { prompt = request.title }, function(choice)
		if not is_active(request) then
			return
		end
		if choice == nil then
			finish({ cancelled = true })
		else
			finish({ value = choice })
		end
	end)
end

local function show_confirm(request)
	local prompt = request.title
	if request.message and request.message ~= "" then
		prompt = prompt .. " — " .. request.message
	end
	vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
		if not is_active(request) then
			return
		end
		if choice == nil then
			finish({ cancelled = true })
		else
			finish({ confirmed = choice == "Yes" })
		end
	end)
end

local function show_input(request)
	local prompt = request.title
	if request.placeholder and request.placeholder ~= "" then
		prompt = ("%s (%s)"):format(prompt, request.placeholder)
	end
	vim.ui.input({ prompt = prompt .. ": " }, function(text)
		if not is_active(request) then
			return
		end
		if text == nil then
			finish({ cancelled = true })
		else
			finish({ value = text })
		end
	end)
end

local function show_editor(request)
	local transcript_win = require("pim.ui.layout").transcript_win()
	if transcript_win then
		vim.api.nvim_set_current_win(transcript_win)
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	local prefill = vim.split(request.prefill or "", "\n", { plain = true })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, prefill)

	vim.cmd("botright " .. math.min(math.max(#prefill + 2, 5), 12) .. "split")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	local title = (request.title or "extension editor") .. "  —  <CR><CR> Submit · q Cancel"
	vim.api.nvim_set_option_value("winbar", " " .. title:gsub("%%", "%%%%"), { win = win })

	local function submit()
		if not is_active(request) then
			return
		end
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		finish({ value = text })
	end

	local function cancel()
		if is_active(request) then
			finish({ cancelled = true })
		end
	end

	vim.keymap.set("n", "<CR><CR>", submit, { buffer = buf, desc = "Submit to extension" })
	vim.keymap.set("n", "q", cancel, { buffer = buf, desc = "Cancel extension dialog" })
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = cancel,
	})

	return function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end
end

process_next = function()
	if active ~= nil or #queue == 0 then
		return
	end
	local request = table.remove(queue, 1)
	active = { request = request }

	local timer = request.timeout and request.timeout > 0 and vim.uv.new_timer() or nil
	if timer then
		active.timer = timer
		timer:start(request.timeout, 0, function()
			vim.schedule(function()
				-- Do not respond after pi uses its timeout default.
				if is_active(request) then
					vim.notify(
						("[pim] Dialog %q timed out. pi used its default."):format(request.title or request.method),
						vim.log.levels.WARN
					)
					finish(nil)
				end
			end)
		end)
	end

	if request.method == "select" then
		show_select(request)
	elseif request.method == "confirm" then
		show_confirm(request)
	elseif request.method == "input" then
		show_input(request)
	elseif request.method == "editor" then
		active.cleanup = show_editor(request)
	end
end

local BLOCKING = { select = true, confirm = true, input = true, editor = true }

function M.handle(request)
	local method = request.method

	if BLOCKING[method] then
		queue[#queue + 1] = request
		process_next()
		return
	end

	if method == "notify" then
		local levels = { info = vim.log.levels.INFO, warning = vim.log.levels.WARN, error = vim.log.levels.ERROR }
		vim.notify("[pi] " .. (request.message or ""), levels[request.notifyType] or vim.log.levels.INFO)
	elseif method == "setStatus" then
		require("pim.state").set_ext_status(request.statusKey, request.statusText)
	elseif method == "setWidget" then
		require("pim.state").set_ext_widget(request.widgetKey, request.widgetLines)
	elseif method == "setTitle" then
		if require("pim.config").get().set_title then
			vim.o.titlestring = request.title or ""
		end
	elseif method == "set_editor_text" then
		require("pim.ui.input").replace(request.text)
	else
		require("pim.log").add("!", ("Unsupported extension_ui_request method %q"):format(tostring(method)))
		require("pim.rpc.client").respond_ui(request.id, { cancelled = true })
	end
end

function M.reset()
	queue = {}
	finish(nil)
end

return M
