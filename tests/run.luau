--!strict

--[=[
	snack test suite.

	Run with either standalone runtime:
		lute tests/run.luau
		luau tests/run.luau

	Coverage (writes coverage.out next to the working directory):
		luau --coverage tests/run.luau
]=]

local snack = require("../src")
local runTypedUsage = require("./typecheck")

local bite = snack.bite

--[[
	Harness
]]

local totalCount = 0
local failures: { string } = {}
local currentGroup = "?"

local function group(name: string)
	currentGroup = name
end

local function test(name: string, body: () -> ())
	totalCount += 1
	local ok, err = pcall(body :: any)
	if not ok then
		table.insert(failures, `[{currentGroup}] {name} — {tostring(err)}`)
	end
end

local function expectEqual(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(`{label}: expected {tostring(expected)}, got {tostring(actual)}`, 0)
	end
end

local function expectError(body: () -> any, messageFragment: string)
	local ok, err = pcall(body)
	if ok then
		error(`expected an error containing "{messageFragment}", but nothing was raised`, 0)
	end
	if not string.find(tostring(err), messageFragment, 1, true) then
		error(`expected an error containing "{messageFragment}", got "{tostring(err)}"`, 0)
	end
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	local kindA, kindB = type(a), type(b)
	if kindA ~= kindB then
		return false
	end
	if kindA == "number" then
		return a ~= a and b ~= b -- NaN == NaN for comparison purposes
	end
	if kindA == "buffer" then
		return buffer.tostring(a) == buffer.tostring(b)
	end
	if kindA == "table" then
		local surplus = 0
		for key, value in pairs(a) do
			if not deepEqual(value, b[key]) then
				return false
			end
			surplus += 1
		end
		for _ in pairs(b) do
			surplus -= 1
		end
		return surplus == 0
	end
	return false
end

local function expectDeepEqual(actual: any, expected: any, label: string)
	if not deepEqual(actual, expected) then
		error(`{label}: decoded value does not deep-equal the original`, 0)
	end
end

-- Round trip helper: encode, decode, compare, and optionally assert the size.
local function roundTrip(value: any, expectedSize: number?)
	local packed = snack(value)
	expectDeepEqual(bite(packed), value, "round trip")
	if expectedSize ~= nil then
		expectEqual(snack.size(packed), expectedSize, "encoded size")
	end
end

-- Builds a buffer from raw byte values, for crafting malformed snacks.
local function craft(...: number): buffer
	local byteValues = { ... }
	local crafted = buffer.create(#byteValues)
	for index, value in byteValues do
		buffer.writeu8(crafted, index - 1, value)
	end
	return crafted
end

local function biteBytes(...: number): any
	return bite(snack.wrap(craft(...)))
end

--[[
	nil and booleans
]]

group("nil and booleans")

test("nil round trips in 1 byte", function()
	roundTrip(nil, 1)
end)

test("false round trips in 1 byte", function()
	roundTrip(false, 1)
end)

test("true round trips in 1 byte", function()
	roundTrip(true, 1)
end)

--[[
	numbers
]]

group("numbers")

test("zero packs to 2 bytes", function()
	roundTrip(0, 2)
end)

test("small positive integers pack to 2 bytes", function()
	roundTrip(1, 2)
	roundTrip(64, 2)
	roundTrip(127, 2)
end)

test("varint boundaries", function()
	roundTrip(128, 3)
	roundTrip(16383, 3)
	roundTrip(16384, 4)
	roundTrip(2097151, 4)
	roundTrip(2097152, 5)
end)

test("negative integers", function()
	roundTrip(-1, 2)
	roundTrip(-127, 2)
	roundTrip(-128, 3)
	roundTrip(-300, 3)
end)

test("largest safe integers", function()
	roundTrip(2 ^ 53, 9)
	roundTrip(-(2 ^ 53), 9)
end)

test("integers beyond 2^53 fall back to floats", function()
	roundTrip(2 ^ 53 + 2, 9)
	roundTrip(2 ^ 60, 5) -- power of two: exact as f32
end)

test("f32-exact fractions pack to 5 bytes", function()
	roundTrip(0.5, 5)
	roundTrip(0.25, 5)
	roundTrip(-1.5, 5)
end)

test("full-precision fractions pack to 9 bytes", function()
	roundTrip(1 / 3, 9)
	roundTrip(0.1 + 0.2, 9)
	roundTrip(3.141592653589793, 9)
	roundTrip(1e300, 9)
end)

test("negative zero keeps its sign", function()
	local decoded: number = bite(snack(-0.0))
	expectEqual(decoded, 0, "value")
	expectEqual(1 / decoded < 0, true, "sign of 1/x")
	expectEqual(snack.size(snack(-0.0)), 5, "encoded size")
end)

test("NaN stays NaN", function()
	local nan = 0 / 0
	local decoded: number = bite(snack(nan))
	expectEqual(decoded ~= decoded, true, "NaN check")
	expectEqual(snack.size(snack(nan)), 5, "encoded size")
end)

test("infinities", function()
	roundTrip(math.huge, 5)
	roundTrip(-math.huge, 5)
end)

--[[
	strings
]]

group("strings")

test("empty string packs to 2 bytes", function()
	roundTrip("", 2)
end)

test("short string", function()
	roundTrip("hello", 7)
end)

test("string length crossing the varint boundary", function()
	roundTrip(string.rep("s", 300), 303)
end)

test("long string grows the writer several times", function()
	roundTrip(string.rep("x", 20000), 20004)
end)

test("strings are 8-bit clean", function()
	roundTrip("\0\1\127\128\255\0", 8)
end)

test("utf-8 text survives byte-for-byte", function()
	roundTrip("héllo 🌮")
end)

test("a 30-char string exactly fills the writer", function()
	-- 1 tag + 1 length + 30 bytes = 32 = a power-of-two capacity, covering
	-- the no-trim return path in encode.
	roundTrip(string.rep("a", 30), 32)
end)

--[[
	vectors
]]

group("vectors")

test("vector packs to 13 bytes", function()
	roundTrip(vector.create(1, 2, 3), 13)
end)

test("fractional and extreme components", function()
	roundTrip(vector.create(0.5, -2.25, 1e10))
	roundTrip(vector.create(-0.125, 65536.5, -1e-20))
end)

test("vector components keep full f32 precision", function()
	-- The vector itself already quantized 1/3 to f32, so the trip is lossless.
	roundTrip(vector.create(1 / 3, 2 / 3, -1 / 7))
end)

test("zero vector", function()
	roundTrip(vector.create(0, 0, 0), 13)
end)

--[[
	buffers
]]

group("buffers")

test("empty buffer packs to 2 bytes", function()
	roundTrip(buffer.create(0), 2)
end)

test("buffer contents survive byte-for-byte", function()
	roundTrip(buffer.fromstring("\1\2\3\0\255"), 7)
end)

test("decoded buffer is an independent copy", function()
	local original = buffer.fromstring("abc")
	local decoded: buffer = bite(snack(original))
	buffer.writeu8(original, 0, (string.byte("z")))
	expectEqual(buffer.tostring(decoded), "abc", "decoded copy")
end)

--[[
	tables
]]

group("tables")

test("empty table packs to 3 bytes", function()
	roundTrip({}, 3)
end)

test("plain array", function()
	roundTrip({ 1, 2, 3 }, 9)
end)

test("dictionary", function()
	roundTrip({ name = "taco", crunchy = true })
end)

test("mixed array and dictionary", function()
	local mixed: { [any]: any } = { 10, 20, 30, label = "mixed", [10] = true }
	roundTrip(mixed)
end)

test("numeric keys outside the array part", function()
	roundTrip({ [0] = "zero", [-5] = "negative", [1.5] = "fraction", [1e6] = "sparse" })
end)

test("boolean keys", function()
	roundTrip({ [true] = "yes", [false] = "no" })
end)

test("array containing an explicit nil hole", function()
	local holed: { any } = { 1, nil, 3 }
	roundTrip(holed)
end)

test("nested tables", function()
	local innermost: { any } = { 1, 2, vector.create(1, 1, 1) }
	roundTrip({ a = { b = { c = innermost } } })
end)

test("100 levels of nesting", function()
	local root: { [string]: any } = {}
	local node = root
	for _ = 1, 100 do
		local child: { [string]: any } = {}
		node.child = child
		node = child
	end
	node.leaf = "bottom"
	roundTrip(root)
end)

test("every supported type in one table", function()
	local nested: { any } = { 1, "two", { three = 3 } }
	local everything: { [string]: any } = {
		flag = true,
		count = -42,
		ratio = 2 / 7,
		text = "snack",
		direction = vector.create(0, 1, 0),
		blob = buffer.fromstring("raw"),
		nested = nested,
	}
	roundTrip(everything)
end)

test("table keys are rebuilt from their contents", function()
	local original: { [{ number }]: string } = { [{ 1, 2 }] = "point" }
	local decoded = bite(snack(original))
	local foundKey: { number }? = nil
	local foundValue: string? = nil
	for key, value in pairs(decoded) do
		foundKey, foundValue = key, value
	end
	expectEqual(foundValue, "point", "value under table key")
	expectDeepEqual(foundKey, { 1, 2 }, "table key contents")
end)

test("shared (non-cyclic) references are duplicated, not rejected", function()
	local shared = { 1, 2 }
	roundTrip({ left = shared, right = shared })
end)

test("metatables are ignored and raw contents are stored", function()
	local proxy = setmetatable({ real = true }, {
		__index = function()
			return "from metatable"
		end,
		__iter = function()
			error("iterated through __iter", 0)
		end,
	})
	local decoded = bite(snack(proxy)) :: { [any]: any }
	expectEqual(decoded.real, true, "raw field")
	expectEqual(rawget(decoded, "ghost"), nil, "no metatable field")
	expectEqual(getmetatable(decoded :: any), nil, "no metatable on decode")
end)

--[[
	unsupported values
]]

group("unsupported values")

test("functions are rejected", function()
	expectError(function()
		return snack(print)
	end, 'cannot serialize a value of type "function"')
end)

test("threads are rejected", function()
	expectError(function()
		return snack(coroutine.create(function() end))
	end, 'cannot serialize a value of type "thread"')
end)

test("unsupported values nested in tables are rejected", function()
	expectError(function()
		return snack({ ok = 1, bad = print })
	end, 'cannot serialize a value of type "function"')
end)

test("directly cyclic tables are rejected", function()
	local cyclic: { [string]: any } = {}
	cyclic.self = cyclic
	expectError(function()
		return snack(cyclic)
	end, "cyclic table")
end)

test("indirectly cyclic tables are rejected", function()
	local a: { [string]: any } = {}
	local b: { [string]: any } = { a = a }
	a.b = b
	expectError(function()
		return snack(a)
	end, "cyclic table")
end)

--[[
	malformed snacks
]]

group("malformed snacks")

test("bite rejects non-buffers", function()
	expectError(function()
		return bite(42 :: any)
	end, "expected a snack")
end)

test("empty buffer is truncated", function()
	expectError(function()
		return biteBytes()
	end, "truncated")
end)

test("unknown tags are rejected", function()
	expectError(function()
		return biteBytes(11)
	end, "unknown tag 11")
	expectError(function()
		return biteBytes(255)
	end, "unknown tag 255")
end)

test("trailing bytes are rejected", function()
	expectError(function()
		return biteBytes(0, 0)
	end, "trailing bytes")
end)

test("truncated varint", function()
	expectError(function()
		return biteBytes(3, 128)
	end, "truncated")
end)

test("overlong varint", function()
	expectError(function()
		return biteBytes(3, 128, 128, 128, 128, 128, 128, 128, 128, 1)
	end, "varint too long")
end)

test("varint values beyond 2^53 are rejected", function()
	-- Eight bytes encoding 2^56 - 1: structurally valid LEB128, but the value
	-- exceeds what a double can hold precisely, so bite must refuse it.
	expectError(function()
		return biteBytes(3, 255, 255, 255, 255, 255, 255, 255, 127)
	end, "varint too large")
end)

test("truncated floats", function()
	expectError(function()
		return biteBytes(5, 0, 0, 0)
	end, "truncated")
	expectError(function()
		return biteBytes(6, 0)
	end, "truncated")
end)

test("truncated string payload", function()
	expectError(function()
		return biteBytes(7, 5, 65)
	end, "truncated")
end)

test("truncated vector payload", function()
	expectError(function()
		return biteBytes(8, 0, 0, 0, 0)
	end, "truncated")
end)

test("truncated buffer payload", function()
	expectError(function()
		return biteBytes(9, 3)
	end, "truncated")
end)

test("forged array count cannot cause a huge loop", function()
	expectError(function()
		return biteBytes(10, 200, 1)
	end, "truncated")
end)

test("forged pair count cannot cause a huge loop", function()
	expectError(function()
		return biteBytes(10, 0, 200, 1)
	end, "truncated")
end)

test("nil table keys are rejected", function()
	expectError(function()
		return biteBytes(10, 0, 1, 0, 0)
	end, "nil table key")
end)

--[[
	api surface
]]

group("api surface")

test("size matches the raw buffer length", function()
	local packed = snack("hello")
	expectEqual(snack.size(packed), buffer.len(snack.raw(packed)), "size")
end)

test("raw returns the underlying buffer without copying", function()
	local packed = snack("hello")
	expectEqual(snack.raw(packed) :: any, packed :: any, "identity")
end)

test("wrap round trips through raw bytes", function()
	local stored = snack.raw(snack({ score = 100 }))
	local restored: snack.Table = snack.wrap(stored)
	expectDeepEqual(bite(restored), { score = 100 }, "wrap")
end)

test("size, raw, and wrap reject non-buffers", function()
	expectError(function()
		return snack.size(5 :: any)
	end, "expected a snack")
	expectError(function()
		return snack.raw("nope" :: any)
	end, "expected a snack")
	expectError(function()
		return snack.wrap({} :: any)
	end, "expected a buffer")
end)

test("is accepts well-formed snacks", function()
	expectEqual(snack.is(snack.raw(snack(nil))), true, "nil snack")
	expectEqual(snack.is(snack.raw(snack({ 1, 2 }))), true, "table snack")
end)

test("is rejects non-buffers and malformed buffers", function()
	expectEqual(snack.is("hello"), false, "string")
	expectEqual(snack.is(nil), false, "nil")
	expectEqual(snack.is(craft(255)), false, "unknown tag")
	expectEqual(snack.is(craft(0, 0)), false, "trailing bytes")
	expectEqual(snack.is(buffer.create(0)), false, "empty buffer")
end)

test("encoding the same value twice is deterministic", function()
	local value = { 1, 2, 3, label = "same", nested = { true } }
	local first = buffer.tostring(snack.raw(snack(value)))
	local second = buffer.tostring(snack.raw(snack(value)))
	expectEqual(first == second, true, "identical bytes")
end)

test("snacks can themselves be packed as buffers", function()
	local inner = snack("filling")
	local outer = snack(snack.raw(inner))
	local unwrapped: buffer = bite(outer)
	expectEqual(bite(snack.wrap(unwrapped)), "filling", "nested snack")
end)

test("typed usage fixture", function()
	runTypedUsage()
end)

--[[
	packs
]]

group("packs")

local function packBytes(p: snack.Pack): buffer
	return (p :: any) :: buffer
end

test("pack lays snacks end to end with zero overhead", function()
	local first = snack("hello")
	local second = snack(42)
	local bundle = snack.pack(first, second)
	expectEqual(
		buffer.tostring(packBytes(bundle)),
		buffer.tostring(snack.raw(first)) .. buffer.tostring(snack.raw(second)),
		"exact concatenation"
	)
	expectEqual(buffer.len(packBytes(bundle)), snack.size(first) + snack.size(second), "size is the sum")
end)

test("unpack returns every value plus the entry count", function()
	local bundle = snack.pack(snack("hello"), snack(42), snack(true))
	local values, total = snack.unpack(bundle)
	expectEqual(total, 3, "count")
	expectEqual(values[1], "hello", "first")
	expectEqual(values[2], 42, "second")
	expectEqual(values[3], true, "third")
end)

test("the empty pack has no bytes and no entries", function()
	local empty = snack.pack()
	expectEqual(buffer.len(packBytes(empty)), 0, "zero bytes")
	expectEqual(snack.count(empty), 0, "zero entries")
	local values, total = snack.unpack(empty)
	expectEqual(total, 0, "unpack count")
	expectEqual(next(values), nil, "no values")
end)

test("a single snack packs to identical bytes", function()
	local single = snack({ score = 9 })
	local bundle = snack.pack(single)
	expectEqual(buffer.tostring(packBytes(bundle)), buffer.tostring(snack.raw(single)), "same bytes")
	local values, total = snack.unpack(bundle)
	expectEqual(total, 1, "one entry")
	expectDeepEqual(values[1], { score = 9 }, "value")
end)

test("a well-formed snack is a valid one-entry pack", function()
	expectEqual(snack.count(snack("solo") :: any), 1, "count of a bare snack")
end)

test("pack also appends and merges", function()
	local left = snack.pack(snack(1), snack(2))
	local right = snack.pack(snack(3))
	local merged = snack.pack(left, right, snack(4))
	expectEqual(snack.count(merged), 4, "merged count")
	local values = snack.unpack(merged)
	expectEqual(values[1], 1, "first")
	expectEqual(values[2], 2, "second")
	expectEqual(values[3], 3, "third")
	expectEqual(values[4], 4, "fourth")
end)

test("nil entries are preserved and counted", function()
	local bundle = snack.pack(snack(nil), snack(nil), snack(1))
	expectEqual(snack.count(bundle), 3, "count")
	local values, total = snack.unpack(bundle)
	expectEqual(total, 3, "unpack count")
	expectEqual(values[1], nil, "first is nil")
	expectEqual(values[3], 1, "third")
	local trailing = snack.pack(snack(1), snack(nil))
	local _, trailingTotal = snack.unpack(trailing)
	expectEqual(trailingTotal, 2, "trailing nil still counted")
	expectEqual(snack.nibble(trailing, 2), nil, "nibbling a nil entry")
end)

test("nibble decodes single entries of every type", function()
	local expected: { any } = {
		true,
		false,
		5,
		-5,
		0.5,
		1 / 3,
		"text",
		vector.create(1, 2, 3),
		buffer.fromstring("blob"),
		{ 1, 2, nested = { deep = true } },
	}
	local pieces = {}
	for index = 1, #expected do
		pieces[index] = snack(expected[index])
	end
	local bundle = snack.pack(table.unpack(pieces))
	-- Nibbling the last entry forces a skip over every other tag type, and
	-- nibbling each index checks the skip landed on the right boundary.
	for index = #expected, 1, -1 do
		expectDeepEqual(snack.nibble(bundle, index), expected[index], `entry {index}`)
	end
end)

test("pack copies bytes eagerly", function()
	local original = snack("abc")
	local bundle = snack.pack(original)
	buffer.writeu8(snack.raw(original), 2, (string.byte("z")))
	local values = snack.unpack(bundle)
	expectEqual(values[1], "abc", "pack unaffected by later mutation")
end)

test("bite refuses a multi-entry pack", function()
	expectError(function()
		return bite(snack.pack(snack(1), snack(2)) :: any)
	end, "trailing bytes")
end)

test("pack rejects non-buffer arguments by position", function()
	expectError(function()
		return snack.pack(5 :: any)
	end, 'expected a snack or pack at argument #1, got a value of type "number"')
	expectError(function()
		return snack.pack(snack(1), "loose string" :: any)
	end, "argument #2")
end)

test("unpack, count, and nibble reject non-buffers", function()
	expectError(function()
		return snack.unpack(5 :: any)
	end, "snack.unpack: expected a pack")
	expectError(function()
		return snack.count({} :: any)
	end, "snack.count: expected a pack")
	expectError(function()
		return snack.nibble("nope" :: any, 1)
	end, "snack.nibble: expected a pack")
end)

test("nibble rejects bad indexes", function()
	local bundle = snack.pack(snack(1))
	expectError(function()
		return snack.nibble(bundle, 0)
	end, "index must be a positive integer")
	expectError(function()
		return snack.nibble(bundle, 1.5)
	end, "index must be a positive integer")
	expectError(function()
		return snack.nibble(bundle, "first" :: any)
	end, "index must be a positive integer")
end)

test("nibble errors past the last entry", function()
	expectError(function()
		return snack.nibble(snack.pack(snack(1), snack(2)), 3)
	end, "index 3 is out of range for a pack of 2 entries")
	expectError(function()
		return snack.nibble(snack.pack(), 1)
	end, "pack of 0 entries")
end)

test("malformed packs fail while skipping", function()
	expectError(function()
		return snack.count(craft(0, 200) :: any)
	end, "unknown tag 200")
	expectError(function()
		return snack.count(craft(0, 7, 5) :: any)
	end, "truncated")
	expectError(function()
		return snack.nibble(craft(3, 128) :: any, 2)
	end, "truncated")
	expectError(function()
		return snack.unpack(craft(255) :: any)
	end, "unknown tag 255")
end)

--[[
	fuzzing: 512 random values, deterministic seed
]]

group("fuzzing")

local function randomValue(depth: number): any
	local maxRoll = if depth >= 3 then 7 else 9
	local roll = math.random(1, maxRoll)
	if roll == 1 then
		return nil
	elseif roll == 2 then
		return math.random() < 0.5
	elseif roll == 3 then
		-- Two bounded rolls multiplied: covers integers across the full ±2^52
		-- varint range while keeping each interval well under the 2^31 limit
		-- math.random enforces on some platforms (macOS arm64 rejects 2^32+1).
		return math.random(-2 ^ 26, 2 ^ 26) * math.random(0, 2 ^ 26)
	elseif roll == 4 then
		return (math.random() - 0.5) * 2 ^ math.random(-20, 60)
	elseif roll == 5 then
		local length = math.random(0, 40)
		local chars = table.create(length)
		for index = 1, length do
			chars[index] = string.char(math.random(0, 255))
		end
		return table.concat(chars)
	elseif roll == 6 then
		return vector.create(math.random() * 100, math.random() * -50, math.random() * 0.01)
	elseif roll == 7 then
		local length = math.random(0, 24)
		local blob = buffer.create(length)
		for offset = 0, length - 1 do
			buffer.writeu8(blob, offset, math.random(0, 255))
		end
		return blob
	elseif roll == 8 then
		local list = {}
		for index = 1, math.random(0, 6) do
			list[index] = randomValue(depth + 1)
		end
		return list
	else
		local map = {}
		for _ = 1, math.random(0, 6) do
			map[`key{math.random(1, 1000)}`] = randomValue(depth + 1)
		end
		return map
	end
end

math.randomseed(0x5EED)
for iteration = 1, 512 do
	test(`random value #{iteration}`, function()
		local value = randomValue(0)
		expectDeepEqual(bite(snack(value)), value, "fuzz round trip")
	end)
end

group("pack fuzzing")

for iteration = 1, 64 do
	test(`random pack #{iteration}`, function()
		local entryCount = math.random(0, 5)
		local values: { [number]: any } = {}
		local pieces = {}
		for index = 1, entryCount do
			values[index] = randomValue(0)
			pieces[index] = snack(values[index])
		end
		local bundle = snack.pack(table.unpack(pieces, 1, entryCount))
		expectEqual(snack.count(bundle), entryCount, "count")
		local decoded, decodedCount = snack.unpack(bundle)
		expectEqual(decodedCount, entryCount, "unpack count")
		for index = 1, entryCount do
			expectDeepEqual(decoded[index], values[index], `entry {index}`)
		end
		if entryCount > 0 then
			local pickIndex = math.random(1, entryCount)
			expectDeepEqual(snack.nibble(bundle, pickIndex), values[pickIndex], "nibble")
		end
	end)
end

--[[
	report
]]

for _, failure in failures do
	print(`FAIL {failure}`)
end
print(`snack: {totalCount - #failures}/{totalCount} tests passed`)
if #failures > 0 then
	error(`{#failures} test(s) failed`, 0)
end
