local h = require("helpers")
local process = require("pim.rpc.process")

local function run(cmd, handlers)
	local exited = false
	local handle, err = process.spawn({
		cmd = cmd,
		on_line = handlers.on_line,
		on_error = handlers.on_error,
		on_overflow = handlers.on_overflow,
		max_line_bytes = handlers.max_line_bytes,
		on_exit = function()
			exited = true
		end,
	})
	h.ok(handle ~= nil, "spawn failed: " .. tostring(err))
	h.ok(
		vim.wait(5000, function()
			return exited
		end, 10),
		"timed out waiting for the process to exit"
	)
	return handle
end

return {
	["spawning a missing binary reports an error instead of raising"] = function()
		local handle, err = process.spawn({
			cmd = { "pim-definitely-not-a-real-binary" },
			on_line = function() end,
			on_exit = function() end,
		})

		h.eq(nil, handle)
		h.ok(
			tostring(err):find("not executable or not on $PATH", 1, true),
			"error names the problem, got: " .. tostring(err)
		)
	end,

	["spawning a path that exists but is not executable is rejected"] = function()
		local handle, err = process.spawn({
			cmd = { vim.fn.tempname() },
			on_line = function() end,
			on_exit = function() end,
		})

		h.eq(nil, handle)
		h.ok(err ~= nil, "an error message is returned")
	end,

	["a throwing line handler does not swallow the rest of the batch"] = function()
		local seen, failures = {}, 0

		run({ "printf", "one\\ntwo\\nthree\\n" }, {
			on_line = function(line)
				if line == "two" then
					error("handler blew up")
				end
				seen[#seen + 1] = line
			end,
			on_error = function(_, count)
				failures = failures + count
			end,
		})

		h.eq({ "one", "three" }, seen, "lines after the failure still arrive")
		h.eq(1, failures, "the failure is reported exactly once")
	end,

	["the error report carries a traceback"] = function()
		local traceback

		run({ "printf", "boom\\n" }, {
			on_line = function()
				error("handler blew up")
			end,
			on_error = function(text)
				traceback = text
			end,
		})

		h.ok(traceback ~= nil, "on_error was called")
		h.ok(traceback:find("handler blew up", 1, true), "traceback carries the original message")
		h.ok(traceback:find("stack traceback", 1, true), "traceback carries a stack")
	end,

	["an oversized line is dropped and the stream resynchronises"] = function()
		local seen, dropped = {}, 0

		run({ "sh", "-c", ("printf %%s %s; sleep 0.2; printf 'tail\\nkept\\n'"):format(string.rep("x", 40)) }, {
			max_line_bytes = 16,
			on_line = function(line)
				seen[#seen + 1] = line
			end,
			on_overflow = function(bytes)
				dropped = dropped + bytes
			end,
		})

		h.eq({ "kept" }, seen, "the abandoned line's tail is not delivered as a line")
		h.eq(40, dropped, "the overflow is reported once, with the abandoned byte count")
	end,

	["a clean run reports no failures"] = function()
		local seen, failures = {}, 0

		run({ "printf", "alpha\\nbeta\\n" }, {
			on_line = function(line)
				seen[#seen + 1] = line
			end,
			on_error = function()
				failures = failures + 1
			end,
		})

		h.eq({ "alpha", "beta" }, seen)
		h.eq(0, failures)
	end,
}
