local h = require("helpers")
local framing = require("pim.rpc.framing")

local function feed_all(chunks, reader)
	reader = reader or framing.new()
	local lines, dropped = {}, 0
	for _, chunk in ipairs(chunks) do
		local produced, lost = framing.feed(reader, chunk)
		vim.list_extend(lines, produced)
		dropped = dropped + lost
	end
	return reader, lines, dropped
end

return {
	["single complete line"] = function()
		local reader = framing.new()
		local lines = framing.feed(reader, '{"type":"response"}\n')
		h.eq("", reader.remainder)
		h.eq({ '{"type":"response"}' }, lines)
	end,

	["multiple lines in one chunk"] = function()
		local reader = framing.new()
		local lines = framing.feed(reader, "one\ntwo\nthree\n")
		h.eq("", reader.remainder)
		h.eq({ "one", "two", "three" }, lines)
	end,

	["partial line is carried in the remainder"] = function()
		local reader = framing.new()
		local lines = framing.feed(reader, '{"type":"eve')
		h.eq('{"type":"eve', reader.remainder)
		h.eq({}, lines)
	end,

	["line split across chunks reassembles"] = function()
		local reader, lines = feed_all({ '{"a":', "1}\n", '{"b":2', "}\n" })
		h.eq("", reader.remainder)
		h.eq({ '{"a":1}', '{"b":2}' }, lines)
	end,

	["chunk boundary directly after LF"] = function()
		local reader, lines = feed_all({ "one\n", "two\n" })
		h.eq("", reader.remainder)
		h.eq({ "one", "two" }, lines)
	end,

	["trailing CR is stripped"] = function()
		local lines = framing.feed(framing.new(), "one\r\ntwo\n")
		h.eq({ "one", "two" }, lines)
	end,

	["CR not followed by LF is preserved"] = function()
		local lines = framing.feed(framing.new(), "one\rtwo\n")
		h.eq({ "one\rtwo" }, lines)
	end,

	["blank lines are ignored"] = function()
		local reader = framing.new()
		local lines = framing.feed(reader, "one\n\n\r\ntwo\n")
		h.eq("", reader.remainder)
		h.eq({ "one", "two" }, lines)
	end,

	["UTF-8 character split mid-byte across chunks"] = function()
		local text = '{"msg":"héllo → wörld 🎉"}'
		local cut = text:find("🎉", 1, true) + 2
		local _, lines = feed_all({ text:sub(1, cut), text:sub(cut + 1) .. "\n" })
		h.eq({ text }, lines)
	end,

	["U+2028 and U+2029 inside a JSON string do not split lines"] = function()
		local line = '{"msg":"a\226\128\168b\226\128\169c"}'
		local reader = framing.new()
		local lines = framing.feed(reader, line .. "\n")
		h.eq("", reader.remainder)
		h.eq({ line }, lines)
		h.eq("a\226\128\168b\226\128\169c", vim.json.decode(lines[1]).msg)
	end,

	["remainder flushes once the LF arrives"] = function()
		local reader = framing.new()
		local lines = framing.feed(reader, "partial")
		h.eq("partial", reader.remainder)
		lines = framing.feed(reader, " done\n")
		h.eq("", reader.remainder)
		h.eq({ "partial done" }, lines)
	end,

	["empty chunk is a no-op"] = function()
		local reader = framing.new()
		framing.feed(reader, "abc")
		local lines = framing.feed(reader, "")
		h.eq("abc", reader.remainder)
		h.eq({}, lines)
	end,

	["a line that never terminates is dropped once it outgrows the cap"] = function()
		local reader = framing.new(64)
		local lines, dropped = framing.feed(reader, string.rep("x", 100))

		h.eq({}, lines)
		h.eq(100, dropped, "the abandoned bytes are reported")
		h.eq("", reader.remainder, "nothing is still being buffered")
		h.eq(true, reader.discarding, "the rest of that line is still to come")
	end,

	["a line inside the cap is buffered as usual"] = function()
		local reader = framing.new(64)
		local lines, dropped = framing.feed(reader, string.rep("x", 64))

		h.eq({}, lines)
		h.eq(0, dropped)
		h.eq(64, #reader.remainder)
		h.eq(false, reader.discarding)
	end,

	["a complete line over the cap is still delivered"] = function()
		local big = string.rep("x", 200)
		local reader = framing.new(64)
		local lines, dropped = framing.feed(reader, big .. "\n")

		h.eq({ big }, lines)
		h.eq(0, dropped)
	end,

	["the splitter resynchronises at the first LF after an oversized line"] = function()
		local reader = framing.new(64)
		framing.feed(reader, string.rep("x", 100))
		local lines = framing.feed(reader, 'tail of the junk\n{"n":1}\n')

		h.eq({ '{"n":1}' }, lines, "the abandoned line's tail is not emitted as a frame")
		h.eq(false, reader.discarding)
		h.eq("", reader.remainder)
	end,

	["discarding spans as many chunks as it takes"] = function()
		local reader = framing.new(64)
		framing.feed(reader, string.rep("x", 100))
		local _, lines = feed_all({ "still junk", "more junk", "end of junk\nkept\n" }, reader)

		h.eq({ "kept" }, lines)
		h.eq(false, reader.discarding)
	end,

	["chunk boundaries never change the framing (fuzz)"] = function()
		math.randomseed(20260730)

		local payloads = {
			'{"type":"response","id":"nvp-1","success":true}',
			'{"msg":"héllo → wörld 🎉"}',
			'{"msg":"a\226\128\168b\226\128\169c"}',
			'{"msg":"tab\\tquote\\"backslash\\\\"}',
			'{"msg":"' .. string.rep("long ", 200) .. '"}',
			"{}",
		}

		for _ = 1, 300 do
			local expected, parts = {}, {}
			for _ = 1, math.random(1, 6) do
				local line = payloads[math.random(#payloads)]
				expected[#expected + 1] = line
				parts[#parts + 1] = line
				parts[#parts + 1] = math.random(2) == 1 and "\r\n" or "\n"
			end
			local document = table.concat(parts)

			local chunks, pos = {}, 1
			while pos <= #document do
				local size = math.random(1, 12)
				chunks[#chunks + 1] = document:sub(pos, pos + size - 1)
				pos = pos + size
			end

			local reader, lines = feed_all(chunks)
			h.eq("", reader.remainder, "everything was consumed")
			h.eq(expected, lines, "chunking changed the framing")
		end
	end,

	["an unterminated final line is held, never emitted early (fuzz)"] = function()
		math.randomseed(1)

		for _ = 1, 100 do
			local complete = '{"n":1}'
			local dangling = '{"n":2,"partial":true'
			local document = complete .. "\n" .. dangling

			local chunks, pos = {}, 1
			while pos <= #document do
				local size = math.random(1, 5)
				chunks[#chunks + 1] = document:sub(pos, pos + size - 1)
				pos = pos + size
			end

			local reader, lines = feed_all(chunks)
			h.eq({ complete }, lines, "only the terminated line is emitted")
			h.eq(dangling, reader.remainder, "the rest waits for its LF")
		end
	end,

	["an oversized line leaks no fragment, whatever the chunking (fuzz)"] = function()
		math.randomseed(831)

		local cap, max_chunk = 128, 64
		for _ = 1, 200 do
			local before = '{"n":1}'
			local after = '{"n":2}'
			local junk = string.rep("j", cap + max_chunk + math.random(1, 400))
			local document = before .. "\n" .. junk .. "\n" .. after .. "\n"

			local chunks, pos = {}, 1
			while pos <= #document do
				local size = math.random(1, max_chunk)
				chunks[#chunks + 1] = document:sub(pos, pos + size - 1)
				pos = pos + size
			end

			local reader, lines, dropped = feed_all(chunks, framing.new(cap))
			h.eq({ before, after }, lines, "a good line either side of the junk")
			h.ok(dropped > cap, "the drop is reported and is at least the cap: " .. dropped)
			h.eq("", reader.remainder, "the reader is left clean")
			h.eq(false, reader.discarding, "and resynchronised")
		end
	end,
}
