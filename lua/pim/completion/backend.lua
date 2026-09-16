local M = {}
local blink_enabled = false
local attached = {}
local OMNIFUNC = "v:lua.require'pim.completion'.omnifunc"
local COMPLETEOPT = "menu,menuone,noselect"

local function local_map(buf, key)
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "i")) do
		if map.lhs == key then
			return map
		end
	end
end

local function restore(buf, saved)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	for key, callback in pairs(saved.callbacks) do
		local current = local_map(buf, key)
		if current and current.callback == callback then
			vim.keymap.del("i", key, { buffer = buf })
			if saved.maps[key] then
				vim.api.nvim_buf_call(buf, function()
					vim.fn.mapset("i", false, saved.maps[key])
				end)
			end
		end
	end
	if vim.bo[buf].omnifunc == OMNIFUNC then
		vim.bo[buf].omnifunc = saved.omnifunc
	end
	if vim.bo[buf].completeopt == COMPLETEOPT then
		vim.bo[buf].completeopt = saved.completeopt
	end
end

function M.is_blink_enabled()
	return blink_enabled
end

---Only an explicit integration setup enables Blink ownership. This setting
---survives process resets; no Blink module is required by the native backend.
function M.set_blink_enabled(enabled)
	blink_enabled = enabled
	if enabled then
		for buf, saved in pairs(attached) do
			restore(buf, saved)
		end
		attached = {}
	end
end

function M.attach(buf)
	if blink_enabled or attached[buf] then
		return
	end
	local callbacks = {
		["/"] = function()
			local cursor = vim.api.nvim_win_get_cursor(0)
			return cursor[1] == 1 and cursor[2] == 0 and "/<C-x><C-o>" or "/"
		end,
		["@"] = function()
			local col = vim.api.nvim_win_get_cursor(0)[2]
			local prev = col > 0 and vim.api.nvim_get_current_line():sub(col, col) or ""
			return (col == 0 or prev:match("%s")) and "@<C-x><C-o>" or "@"
		end,
	}
	attached[buf] = {
		omnifunc = vim.bo[buf].omnifunc,
		completeopt = vim.bo[buf].completeopt,
		maps = { ["/"] = local_map(buf, "/"), ["@"] = local_map(buf, "@") },
		callbacks = callbacks,
	}
	vim.bo[buf].omnifunc = OMNIFUNC
	vim.bo[buf].completeopt = COMPLETEOPT
	for key, callback in pairs(callbacks) do
		vim.keymap.set("i", key, callback, { buffer = buf, expr = true, desc = "pim omni completion" })
	end
end

function M.reset()
	for buf, saved in pairs(attached) do
		restore(buf, saved)
	end
	attached = {}
end

return M
