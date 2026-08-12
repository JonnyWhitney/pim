local SCENARIOS = {
	crash = true,
	tool = true,
	dialog = true,
	hostile = true,
	nocontext = true,
	nullcontext = true,
	retry = true,
}

local scenario = "basic"
for _, value in ipairs(arg) do
	if SCENARIOS[value] then
		scenario = value
	end
end

local function send(message)
	io.stdout:write(vim.json.encode(message) .. "\n")
	io.stdout:flush()
end

local state = {
	model = { provider = "fake", id = "fake-model" },
	thinkingLevel = "off",
	isStreaming = false,
	isCompacting = false,
	steeringMode = "all",
	followUpMode = "one-at-a-time",
	sessionId = "fake-session-id",
	autoCompactionEnabled = true,
	messageCount = 0,
	pendingMessageCount = 0,
}

local function assistant(text)
	return { role = "assistant", content = { { type = "text", text = text } } }
end

local function user(text)
	return { role = "user", content = { { type = "text", text = text } } }
end

local function tool_result(text)
	return { content = { { type = "text", text = text } } }
end

local fork_messages = {
	{ entryId = "tree-1", text = "Start the parser" },
	{ entryId = "tree-3", text = "Fix the parser error" },
}

local function messages_for_session()
	if state.sessionId == "switched-session" then
		return { user("old prompt"), assistant("old answer") }
	elseif state.sessionId == "forked-session" then
		return { user("Start the parser"), assistant("forked history") }
	elseif state.sessionId == "cloned-session" then
		return { user("Start the parser"), assistant("cloned history") }
	end
	return {}
end

local session_tree = {
	{
		entry = { type = "message", id = "tree-1", parentId = nil, message = user("Start the parser") },
		children = {
			{
				entry = {
					type = "message",
					id = "tree-2",
					parentId = "tree-1",
					message = assistant("I will inspect it."),
				},
				children = {
					{
						entry = {
							type = "message",
							id = "tree-3",
							parentId = "tree-2",
							message = user("Fix the parser error"),
						},
						label = "parser work",
						children = {
							{
								entry = {
									type = "message",
									id = "tree-4",
									parentId = "tree-3",
									message = assistant("I fixed the lexer."),
								},
								children = {},
							},
							{
								entry = {
									type = "message",
									id = "tree-5",
									parentId = "tree-3",
									message = assistant("I fixed the parser."),
								},
								children = {},
							},
						},
					},
				},
			},
		},
	},
}

local function run_tool_turn(cmd)
	local call = { type = "toolCall", id = "call-1", name = "bash", arguments = { command = "ls" } }
	send({ type = "response", id = cmd.id, command = "prompt", success = true })
	send({ type = "agent_start" })
	send({ type = "turn_start" })
	send({ type = "message_start", message = user(cmd.message) })
	send({ type = "message_end", message = user(cmd.message) })
	send({ type = "message_start", message = { role = "assistant", content = {} } })
	send({
		type = "message_update",
		message = { role = "assistant", content = { call } },
		assistantMessageEvent = { type = "toolcall_end" },
	})
	send({ type = "message_end", message = { role = "assistant", content = { call } } })
	send({ type = "tool_execution_start", toolCallId = "call-1", toolName = "bash", args = call.arguments })
	send({
		type = "tool_execution_update",
		toolCallId = "call-1",
		toolName = "bash",
		args = call.arguments,
		partialResult = tool_result("file-a"),
	})
	send({
		type = "tool_execution_update",
		toolCallId = "call-1",
		toolName = "bash",
		args = call.arguments,
		partialResult = tool_result("file-a\nfile-b"),
	})
	send({
		type = "tool_execution_end",
		toolCallId = "call-1",
		toolName = "bash",
		result = tool_result("file-a\nfile-b"),
		isError = false,
	})
	local result_message = {
		role = "toolResult",
		toolCallId = "call-1",
		toolName = "bash",
		content = { { type = "text", text = "file-a\nfile-b" } },
		isError = false,
	}
	send({ type = "message_start", message = result_message })
	send({ type = "message_end", message = result_message })
	send({ type = "turn_end", message = { role = "assistant", content = { call } }, toolResults = {} })
	send({ type = "turn_start" })
	send({ type = "message_start", message = assistant("") })
	send({
		type = "message_update",
		message = assistant("Two files."),
		assistantMessageEvent = { type = "text_delta", delta = "Two files." },
	})
	send({ type = "message_end", message = assistant("Two files.") })
	send({ type = "turn_end", message = assistant("Two files."), toolResults = {} })
	send({ type = "agent_end", willRetry = false })
	send({ type = "agent_settled" })
end

local function run_retry_turn(cmd)
	send({ type = "response", id = cmd.id, command = "prompt", success = true })
	send({ type = "agent_start" })
	send({ type = "turn_start" })
	send({ type = "message_start", message = user(cmd.message) })
	send({ type = "message_end", message = user(cmd.message) })
	send({ type = "agent_end", willRetry = true })
	send({ type = "auto_retry_start", attempt = 1 })
	send({ type = "auto_retry_end", success = true })
	send({ type = "agent_start" })
	send({ type = "message_start", message = assistant("") })
	send({
		type = "message_update",
		message = assistant("Hello on the second try"),
		assistantMessageEvent = { type = "text_delta", delta = "Hello on the second try" },
	})
	send({ type = "message_end", message = assistant("Hello on the second try") })
	send({ type = "turn_end", message = assistant("Hello on the second try"), toolResults = {} })
	send({ type = "agent_end", willRetry = false })
	send({ type = "agent_settled" })
end

-- Send malformed and fragmented JSONL before a valid event to test stream recovery.
local function run_hostile_turn(cmd)
	send({ type = "response", id = cmd.id, command = "prompt", success = true })
	send({ type = "agent_start" })

	io.stdout:write("this is not json at all\n")
	io.stdout:write("[1, 2, 3]\n")
	io.stdout:write("42\n")
	io.stdout:write('"a bare string"\n')
	io.stdout:write("\n   \n")
	io.stdout:flush()

	send({ type = "tool_execution_start", toolName = "bash" })
	send({ type = "tool_execution_update", toolName = "bash", partialResult = "orphan" })
	send({ type = "tool_execution_end", toolName = "bash", result = "orphan" })
	send({ type = "message_update" })
	send({ type = "message_end" })

	send({ type = "unknown_future_event", payload = { nested = { deeply = true } } })
	send({ type = 12345 })
	send({ notype = "at all" })

	local split = vim.json.encode({ type = "message_start", message = assistant("") })
	io.stdout:write(split:sub(1, 15))
	io.stdout:flush()
	vim.uv.sleep(30)
	io.stdout:write(split:sub(16) .. "\n")
	io.stdout:flush()

	send({ type = "message_update", message = assistant(string.rep("x", 60000)) })

	send({ type = "message_end", message = assistant("survived") })
	send({ type = "agent_end", willRetry = false })
	send({ type = "agent_settled" })
end

local awaiting_dialog = false

local function finish_dialog_turn(answer)
	local text = "You picked: " .. answer
	send({ type = "message_start", message = assistant("") })
	send({
		type = "message_update",
		message = assistant(text),
		assistantMessageEvent = { type = "text_delta", delta = text },
	})
	send({ type = "message_end", message = assistant(text) })
	send({ type = "turn_end", message = assistant(text), toolResults = {} })
	send({ type = "agent_end", willRetry = false })
	send({ type = "agent_settled" })
end

local function handle_dialog_response(cmd)
	awaiting_dialog = false
	local answer
	if cmd.cancelled then
		answer = "cancelled"
	elseif cmd.confirmed ~= nil then
		answer = tostring(cmd.confirmed)
	else
		answer = cmd.value or "?"
	end
	finish_dialog_turn(answer)
end

local function handle(cmd)
	if cmd.type == "get_state" then
		local argv = {}
		for i = 1, #arg do
			argv[i] = arg[i]
		end
		local data = vim.tbl_extend("force", state, { fakeArgv = argv })
		send({ type = "response", id = cmd.id, command = "get_state", success = true, data = data })
	elseif cmd.type == "get_messages" then
		send({
			type = "response",
			id = cmd.id,
			command = "get_messages",
			success = true,
			data = { messages = messages_for_session() },
		})
	elseif cmd.type == "get_tree" then
		send({
			type = "response",
			id = cmd.id,
			command = "get_tree",
			success = true,
			data = { tree = session_tree, leafId = "tree-5" },
		})
	elseif cmd.type == "get_fork_messages" then
		send({
			type = "response",
			id = cmd.id,
			command = "get_fork_messages",
			success = true,
			data = { messages = fork_messages },
		})
	elseif cmd.type == "fork" then
		local text = nil
		for _, message in ipairs(fork_messages) do
			if message.entryId == cmd.entryId then
				text = message.text
				break
			end
		end
		if not text then
			send({ type = "response", id = cmd.id, command = "fork", success = false, error = "unknown fork entry" })
			return
		end
		state.sessionId = "forked-session"
		send({
			type = "response",
			id = cmd.id,
			command = "fork",
			success = true,
			data = { text = text, cancelled = false },
		})
	elseif cmd.type == "clone" then
		state.sessionId = "cloned-session"
		send({ type = "response", id = cmd.id, command = "clone", success = true, data = { cancelled = false } })
	elseif cmd.type == "switch_session" then
		state.sessionId = "switched-session"
		send({
			type = "response",
			id = cmd.id,
			command = "switch_session",
			success = true,
			data = { cancelled = false },
		})
	elseif cmd.type == "new_session" then
		state.sessionId = "fresh-session"
		send({ type = "response", id = cmd.id, command = "new_session", success = true, data = { cancelled = false } })
	elseif cmd.type == "extension_ui_response" then
		if awaiting_dialog then
			handle_dialog_response(cmd)
		end
	elseif cmd.type == "prompt" and scenario == "dialog" then
		send({ type = "response", id = cmd.id, command = "prompt", success = true })
		send({ type = "agent_start" })
		send({ type = "turn_start" })
		send({ type = "message_start", message = user(cmd.message) })
		send({ type = "message_end", message = user(cmd.message) })
		awaiting_dialog = true
		send({
			type = "extension_ui_request",
			id = "ui-1",
			method = "select",
			title = "Pick one",
			options = { "alpha", "beta" },
		})
	elseif cmd.type == "prompt" and scenario == "tool" then
		run_tool_turn(cmd)
	elseif cmd.type == "prompt" and scenario == "hostile" then
		run_hostile_turn(cmd)
	elseif cmd.type == "prompt" and scenario == "retry" then
		run_retry_turn(cmd)
	elseif cmd.type == "prompt" then
		send({ type = "response", id = cmd.id, command = "prompt", success = true })
		send({ type = "agent_start" })
		send({ type = "turn_start" })
		send({ type = "message_start", message = user(cmd.message) })
		send({ type = "message_end", message = user(cmd.message) })
		send({ type = "message_start", message = assistant("") })
		send({
			type = "message_update",
			message = assistant(""),
			assistantMessageEvent = { type = "text_start" },
		})
		send({
			type = "message_update",
			message = assistant("Hello"),
			assistantMessageEvent = { type = "text_delta", delta = "Hello" },
		})
		if scenario == "crash" then
			os.exit(7)
		end
		send({
			type = "message_update",
			message = assistant("Hello from fake pi"),
			assistantMessageEvent = { type = "text_delta", delta = " from fake pi" },
		})
		send({
			type = "message_update",
			message = assistant("Hello from fake pi"),
			assistantMessageEvent = { type = "text_end" },
		})
		send({ type = "message_end", message = assistant("Hello from fake pi") })
		send({ type = "turn_end", message = assistant("Hello from fake pi") })
		send({ type = "agent_end", willRetry = false })
		send({ type = "agent_settled" })
	elseif cmd.type == "get_commands" then
		send({
			type = "response",
			id = cmd.id,
			command = "get_commands",
			success = true,
			data = {
				commands = {
					{
						name = "rpc-select",
						description = "Demo select dialog",
						source = "extension",
						sourceInfo = { path = "/x/rpc-demo.ts", source = "extension", scope = "project" },
					},
					{ name = "review", description = "Review the code", source = "prompt" },
					{ name = "legacy-cmd", description = "Old shape", sourceInfo = { source = "skill" } },
				},
			},
		})
	elseif cmd.type == "get_available_models" then
		send({
			type = "response",
			id = cmd.id,
			command = "get_available_models",
			success = true,
			data = {
				models = {
					{ id = "fake-model", name = "Fake Model", provider = "fake", contextWindow = 100000 },
					{ id = "other-model", name = "Other Model", provider = "fake", contextWindow = 200000 },
				},
			},
		})
	elseif cmd.type == "get_available_thinking_levels" then
		send({
			type = "response",
			id = cmd.id,
			command = "get_available_thinking_levels",
			success = true,
			data = { levels = { "low", "medium", "high", "xhigh", "max" } },
		})
	elseif cmd.type == "set_model" then
		state.model = { id = cmd.modelId, name = cmd.modelId, provider = cmd.provider }
		send({ type = "response", id = cmd.id, command = "set_model", success = true, data = state.model })
	elseif cmd.type == "set_thinking_level" then
		state.thinkingLevel = cmd.level
		send({ type = "response", id = cmd.id, command = "set_thinking_level", success = true })
		send({ type = "thinking_level_changed", level = cmd.level })
	elseif cmd.type == "get_session_stats" then
		local usage = nil
		if scenario == "nullcontext" then
			usage = { tokens = vim.NIL, contextWindow = 100000, percent = vim.NIL }
		elseif scenario ~= "nocontext" then
			usage = { tokens = 12000, contextWindow = 100000, percent = 12 }
		end
		send({
			type = "response",
			id = cmd.id,
			command = "get_session_stats",
			success = true,
			data = { sessionId = state.sessionId, contextUsage = usage },
		})
	elseif cmd.type == "bash" then
		local command = tostring(cmd.command)
		if command:find("slow", 1, true) then
			vim.uv.sleep(150)
		end
		send({
			type = "response",
			id = cmd.id,
			command = "bash",
			success = true,
			data = {
				output = "ran: " .. command,
				exitCode = command:find("fail", 1, true) and 3 or 0,
				cancelled = false,
				truncated = false,
			},
		})
	elseif cmd.type == "abort_bash" then
		send({ type = "response", id = cmd.id, command = "abort_bash", success = true })
	elseif cmd.type == "abort" then
		send({ type = "response", id = cmd.id, command = "abort", success = true })
	elseif cmd.type == "bare_ack" then
		send({
			type = "response",
			id = cmd.id,
			command = "bare_ack",
			success = true,
			error = "this error must never reach the caller",
		})
	elseif cmd.type == "never_reply" then
	else
		send({
			type = "response",
			id = cmd.id,
			command = cmd.type,
			success = false,
			error = "unknown command: " .. tostring(cmd.type),
		})
	end
end

while true do
	local line = io.stdin:read("*l")
	if line == nil then
		break
	end
	local ok, cmd = pcall(vim.json.decode, line)
	if ok and type(cmd) == "table" then
		handle(cmd)
	else
		send({ type = "response", command = "parse", success = false, error = "invalid JSON line" })
	end
end
