local h = require("helpers")
local config = require("pim.config")
local client = require("pim.rpc.client")

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function start_fake(scenario, handlers)
	local cmd = { "nvim", "-l", tests_dir .. "/fake_pi.lua" }
	if scenario then
		cmd[#cmd + 1] = scenario
	end
	config.setup({ pi_cmd = cmd })
	client.start(handlers)
end

local function wait_for(predicate, what)
	h.wait_until(predicate, what or "condition", 5000)
end

return {
	["get_state round-trips through a real child process"] = function()
		start_fake()
		local result
		client.get_state(function(success, data)
			result = { success = success, data = data }
		end)
		wait_for(function()
			return result ~= nil
		end, "get_state response")

		h.eq(true, result.success)
		h.eq("fake-session-id", result.data.sessionId)
		h.eq("fake-model", result.data.model.id)
	end,

	["concurrent requests correlate by id"] = function()
		start_fake()
		local results = {}
		client.get_messages(function(_, data)
			results.messages = data
		end)
		client.get_state(function(_, data)
			results.state = data
		end)
		wait_for(function()
			return results.messages ~= nil and results.state ~= nil
		end, "both responses")

		h.eq("fake-session-id", results.state.sessionId)
		h.ok(type(results.messages.messages) == "table", "messages list present")
	end,

	["fork, clone, and tree requests round-trip through pi"] = function()
		start_fake()
		local result = {}

		client.get_fork_messages(function(success, data)
			result.messages = { success = success, data = data }
		end)
		client.fork("fork-2", function(success, data)
			result.fork = { success = success, data = data }
		end)
		client.clone(function(success, data)
			result.clone = { success = success, data = data }
		end)
		client.get_tree(function(success, data)
			result.tree = { success = success, data = data }
		end)

		wait_for(function()
			return result.messages ~= nil and result.fork ~= nil and result.clone ~= nil and result.tree ~= nil
		end, "fork, clone, and tree responses")

		h.eq(true, result.messages.success)
		h.eq("Fix the parser error", result.messages.data.messages[2].text)
		h.eq(true, result.fork.success)
		h.eq("Fix the parser error", result.fork.data.text)
		h.eq(true, result.clone.success)
		h.eq(false, result.clone.data.cancelled)
		h.eq(true, result.tree.success)
		h.eq("tree-5", result.tree.data.leafId)
	end,

	["unknown command surfaces the error payload"] = function()
		start_fake()
		local result
		client.request("bogus", nil, function(success, payload)
			result = { success = success, payload = payload }
		end)
		wait_for(function()
			return result ~= nil
		end, "error response")

		h.eq(false, result.success)
		h.ok(result.payload:find("unknown command"), "error message mentions unknown command")
	end,

	["a success response with no data yields nil, not the error field"] = function()
		start_fake()
		local result
		client.request("bare_ack", nil, function(success, payload)
			result = { success = success, payload = payload }
		end)
		wait_for(function()
			return result ~= nil
		end, "bare ack response")

		h.eq(true, result.success)
		h.eq(nil, result.payload)
	end,

	["prompt is acked and events fan out in order"] = function()
		local events = {}
		start_fake(nil, {
			on_event = function(event)
				events[#events + 1] = event.type
			end,
		})

		local acked
		client.prompt("hi", nil, function(success)
			acked = success
		end)
		wait_for(function()
			return events[#events] == "agent_settled"
		end, "agent_settled event")

		h.eq(true, acked)
		h.eq({
			"agent_start",
			"turn_start",
			"message_start",
			"message_end",
			"message_start",
			"message_update",
			"message_update",
			"message_update",
			"message_update",
			"message_end",
			"turn_end",
			"agent_end",
			"agent_settled",
		}, events)
	end,

	["streaming events carry the full accumulated message"] = function()
		local last_update
		start_fake(nil, {
			on_event = function(event)
				if event.type == "message_update" then
					last_update = event
				end
			end,
		})

		client.prompt("hi", nil, nil)
		wait_for(function()
			return last_update ~= nil and last_update.message.content[1].text == "Hello from fake pi"
		end, "final message_update")

		local sub = last_update.assistantMessageEvent.type
		h.ok(sub == "text_delta" or sub == "text_end", "update carries an assistantMessageEvent")
	end,

	["graceful stop closes stdin and reports intentional exit code 0"] = function()
		local exited
		start_fake(nil, {
			on_exit = function(code, intentional)
				exited = { code = code, intentional = intentional }
			end,
		})

		client.stop()
		wait_for(function()
			return exited ~= nil
		end, "exit callback")

		h.eq(0, exited.code)
		h.eq(true, exited.intentional)
	end,

	["pending requests are rejected on shutdown"] = function()
		start_fake()
		local result
		client.request("never_reply", nil, function(success, payload)
			result = { success = success, payload = payload }
		end)

		client.stop()
		wait_for(function()
			return result ~= nil
		end, "pending rejection")

		h.eq(false, result.success)
		h.eq("pi exited", result.payload)
	end,

	["a request pi never answers is rejected once its deadline passes"] = function()
		start_fake(nil, { request_timeout_ms = 120 })
		local result, calls = nil, 0
		client.request("never_reply", nil, function(success, payload)
			calls = calls + 1
			result = { success = success, payload = payload }
		end)

		wait_for(function()
			return result ~= nil
		end, "the request deadline")

		h.eq(false, result.success)
		h.eq("pi did not respond", result.payload)
		h.eq(true, client.is_running(), "only the request is abandoned; pi is left alone")

		client.stop()
		h.settle(50)
		h.eq(1, calls, "the callback ran exactly once")
	end,

	["a bash request outlives the deadline other commands get"] = function()
		start_fake(nil, { request_timeout_ms = 60 })
		local result
		client.bash("slow command", false, function(success, payload)
			result = { success = success, payload = payload }
		end)

		wait_for(function()
			return result ~= nil
		end, "the bash response")

		h.eq(true, result.success)
		h.eq("ran: slow command", result.payload.output)
	end,

	["crash mid-stream reports unintentional exit with the real code"] = function()
		local exited
		start_fake("crash", {
			on_exit = function(code, intentional)
				exited = { code = code, intentional = intentional }
			end,
		})

		client.prompt("hi", nil, nil)
		wait_for(function()
			return exited ~= nil
		end, "crash exit")

		h.eq(7, exited.code)
		h.eq(false, exited.intentional)
		h.eq(false, client.is_running())
	end,

	["starting a missing binary returns an error instead of raising"] = function()
		config.setup({ pi_cmd = "pim-definitely-not-a-real-binary" })

		local started, err = client.start({})

		h.eq(false, started)
		h.ok(tostring(err):find("not executable", 1, true), "error explains why, got: " .. tostring(err))
		h.eq(false, client.is_running())
	end,

	["a failed start leaves the client reusable"] = function()
		config.setup({ pi_cmd = "pim-definitely-not-a-real-binary" })
		client.start({})

		start_fake()
		local result
		client.get_state(function(success, data)
			result = { success = success, data = data }
		end)
		wait_for(function()
			return result ~= nil
		end, "get_state after a failed start")

		h.eq(true, result.success)
	end,

	["requests while pi is not running fail immediately"] = function()
		local result
		client.get_state(function(success, payload)
			result = { success = success, payload = payload }
		end)
		h.eq(false, result.success)
		h.eq("pi is not running", result.payload)
	end,
}
