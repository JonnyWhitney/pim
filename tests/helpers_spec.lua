local h = require("helpers")

return {
	["successful bodies return values and clean up in reverse order"] = function()
		local order = {}
		local a, b = h.with_cleanup(function(defer)
			defer(function()
				order[#order + 1] = "first"
			end)
			defer(function()
				order[#order + 1] = "second"
			end)
			return false, "value"
		end)
		h.eq({ "second", "first" }, order)
		h.eq(false, a)
		h.eq("value", b)
	end,
	["failed bodies restore functions absent fields and false values"] = function()
		local original = function() end
		local object = { fn = original, flag = false }
		h.fails(function()
			h.with_cleanup(function(defer)
				h.patch(defer, object, "fn", function() end)
				h.patch(defer, object, "absent", true)
				h.patch(defer, object, "flag", true)
				error("deliberate body failure")
			end)
		end, "deliberate body failure")
		h.eq(original, object.fn)
		h.eq(nil, object.absent)
		h.eq(false, object.flag)
	end,
	["nested patches capture the value at entry and unwind in order"] = function()
		local object = { value = "original" }
		h.with_cleanup(function(defer)
			h.patch(defer, object, "value", "outer")
			h.fails(function()
				h.with_cleanup(function(inner)
					h.patch(inner, object, "value", "inner")
					h.patch(inner, object, "value", "innermost")
					error("nested failure")
				end)
			end, "nested failure")
			h.eq("outer", object.value)
		end)
		h.eq("original", object.value)
	end,
	["throwing cleanups do not hide body errors or skip later cleanup"] = function()
		for _, fail_body in ipairs({ false, true }) do
			local order = {}
			local ok, err = pcall(function()
				h.with_cleanup(function(defer)
					defer(function()
						order[#order + 1] = "last"
					end)
					defer(function()
						order[#order + 1] = "throwing"
						error("deliberate cleanup failure")
					end)
					defer(function()
						order[#order + 1] = "first"
						error("second cleanup failure")
					end)
					if fail_body then
						error("original body failure")
					end
				end)
			end)
			h.eq(false, ok)
			h.eq(true, assert(err).cleanup_failed)
			h.eq({ "first", "throwing", "last" }, order)
			h.ok(tostring(err):find("deliberate cleanup failure", 1, true))
			h.ok(tostring(err):find("second cleanup failure", 1, true))
			if fail_body then
				h.ok(tostring(err):find("original body failure", 1, true))
			end
		end
	end,
	["nested cleanup failures remain marked for the runner"] = function()
		local ok, err = pcall(function()
			h.with_cleanup(function()
				h.with_cleanup(function(defer)
					defer(function()
						error("inner cleanup failure")
					end)
				end)
			end)
		end)
		h.eq(false, ok)
		h.eq(true, assert(err).cleanup_failed)
		h.ok(tostring(err):find("inner cleanup failure", 1, true))
	end,
	["temporary resources are removed after a deliberate failure"] = function()
		local directory = vim.fn.tempname()
		local original_env = vim.env.PIM_HELPER_TEST_ENV
		local buf
		h.fails(function()
			h.with_cleanup(function(defer)
				defer(function()
					h.eq(0, vim.fn.delete(directory, "rf"))
				end)
				vim.fn.mkdir(directory, "p")
				h.patch(defer, vim.env, "PIM_HELPER_TEST_ENV", "temporary")
				buf = vim.api.nvim_create_buf(false, true)
				defer(function()
					if vim.api.nvim_buf_is_valid(buf) then
						vim.api.nvim_buf_delete(buf, { force = true })
					end
				end)
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "test content" })
				error("resource failure")
			end)
		end, "resource failure")
		h.eq(nil, vim.uv.fs_stat(directory))
		h.eq(original_env, vim.env.PIM_HELPER_TEST_ENV)
		h.eq(false, vim.api.nvim_buf_is_valid(buf))
	end,
}
