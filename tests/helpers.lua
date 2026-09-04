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

-- Specs share one headless Neovim process. Runtime cleanup uses the application boundary.
function M.reset_all()
	require("pim.lifecycle").cleanup()
	-- Configuration and the event log survive application cleanup. Reset them only for test isolation.
	require("pim.log").clear()
	require("pim.config").setup()
end

return M
