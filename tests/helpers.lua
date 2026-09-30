local M = {}

function M.eq(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			("%sexpected %s, got %s"):format(
				message and (message .. ": ") or "",
				vim.inspect(expected),
				vim.inspect(actual)
			),
			2
		)
	end
end

function M.ok(value, message)
	if not value then
		error(message or "expected value to be truthy", 2)
	end
end

function M.fails(fn, pattern)
	local success, err = pcall(fn)
	if success then
		error("expected function to raise an error, but it succeeded", 2)
	end
	if pattern and not tostring(err):find(pattern) then
		error(("error %q does not match pattern %q"):format(tostring(err), pattern), 2)
	end
end

---@param predicate fun(): boolean
---@param what string
---@param timeout_ms integer|nil
function M.wait_until(predicate, what, timeout_ms)
	timeout_ms = timeout_ms or 3000
	if not vim.wait(timeout_ms, predicate, 10) then
		error(("timed out after %dms waiting for %s"):format(timeout_ms, what), 2)
	end
end

---@param ms integer|nil
function M.settle(ms)
	vim.wait(ms or 100)
end

-- body(defer) is protected. defer(callback) registers a no-argument cleanup.
-- Cleanups are protected separately and are run in reverse registration order.
-- The body failure is reported first, followed by every cleanup failure.
function M.with_cleanup(body)
	local cleanups = {}
	local function defer(callback)
		assert(type(callback) == "function", "cleanup must be a function")
		cleanups[#cleanups + 1] = callback
	end
	local function pack(...)
		return { n = select("#", ...), ... }
	end
	local result = pack(xpcall(body, debug.traceback, defer))
	local errors = {}
	local cleanup_failed = not result[1] and type(result[2]) == "table" and result[2].cleanup_failed == true
	if not result[1] then
		errors[#errors + 1] = tostring(result[2])
	end
	for index = #cleanups, 1, -1 do
		local ok, err = xpcall(cleanups[index], debug.traceback)
		if not ok then
			cleanup_failed = true
			errors[#errors + 1] = "cleanup failed: " .. tostring(err)
		end
	end
	if #errors > 0 then
		local message = table.concat(errors, "\n")
		if cleanup_failed then
			-- A local error marker allows the runner to stop after contaminated cleanup.
			error(
				setmetatable({ cleanup_failed = true, message = message }, {
					__tostring = function(err)
						return err.message
					end,
				}),
				0
			)
		end
		error(message, 0)
	end
	return unpack(result, 2, result.n)
end

-- patch(defer, object, key, replacement) captures the exact current field value.
-- Restoration is registered before replacement. nil and false are preserved.
-- Nested patches are restored correctly by the reverse cleanup order.
function M.patch(defer, object, key, replacement)
	local original = object[key]
	defer(function()
		object[key] = original
	end)
	object[key] = replacement
	return original
end

-- Specs share one headless Neovim process. Runtime cleanup uses the application boundary.
function M.reset_all()
	require("pim.lifecycle").cleanup()
	-- Configuration and the event log survive application cleanup. Reset them only for test isolation.
	require("pim.log").clear()
	require("pim.config").setup()
end

return M
