--!strict
--!native

--[=[
	snack

	Packs any supported Luau value — nil, boolean, number, string, vector,
	buffer, or table — into the smallest practical binary form (a `buffer`),
	and bites it back out again.

		local snack = require(path.to.snack)
		local bite = snack.bite

		local greeting: snack.String = snack("hello")
		print(bite(greeting)) --> "hello"

	A `Snack<T>` is a plain `buffer` at runtime. The table type it is declared
	as is a phantom type: it never exists at runtime and only carries `T` so
	that `bite` can hand the original type back at compile time.
]=]

-- Every encoded value starts with one tag byte; the payload layout depends on it.
local TAG_NIL = 0 -- no payload
local TAG_FALSE = 1 -- no payload
local TAG_TRUE = 2 -- no payload
local TAG_PINT = 3 -- LEB128 varint of the integer
local TAG_NINT = 4 -- LEB128 varint of the negated integer
local TAG_F32 = 5 -- 4-byte IEEE 754 float, used whenever it is bit-exact
local TAG_F64 = 6 -- 8-byte IEEE 754 float
local TAG_STRING = 7 -- varint byte length, then the raw bytes
local TAG_VECTOR = 8 -- x, y, z as three f32 (vectors are f32-backed natively)
local TAG_BUFFER = 9 -- varint byte length, then the raw bytes
local TAG_TABLE = 10 -- varint array count + values, then varint pair count + key/value pairs

-- Largest integer a double represents contiguously (2^53). Anything bigger is
-- stored as a float, because varint arithmetic past this point loses precision.
local MAX_SAFE_INTEGER = 2 ^ 53

-- Scratch buffer used to test whether a number survives an f32 round trip.
local F32_PROBE = buffer.create(4)

export type Snack<T> = {
	--[[ Phantom field. It never exists at runtime — a snack is really a
		`buffer` — it only carries T so bite/wrap can recover the type. ]]
	__snack: T,
}

export type Any = Snack<any>
export type Nil = Snack<nil>
export type Boolean = Snack<boolean>
export type Number = Snack<number>
export type String = Snack<string>
export type Table<T = any> = Snack<T>
export type Vector = Snack<typeof(vector.create(0, 0, 0))>
export type Buffer = Snack<buffer>

--[[
	Encoding
]]

type Writer = {
	buf: buffer,
	len: number,
}

local function reserve(writer: Writer, extra: number)
	local needed = writer.len + extra
	local capacity = buffer.len(writer.buf)
	if needed > capacity then
		repeat
			capacity *= 2
		until capacity >= needed
		local grown = buffer.create(capacity)
		buffer.copy(grown, 0, writer.buf, 0, writer.len)
		writer.buf = grown
	end
end

local function writeByte(writer: Writer, value: number)
	reserve(writer, 1)
	buffer.writeu8(writer.buf, writer.len, value)
	writer.len += 1
end

-- Unsigned LEB128: 7 bits of payload per byte, high bit set on all but the
-- last byte. Integers up to 2^53 need at most 8 bytes.
local function writeVarint(writer: Writer, value: number)
	reserve(writer, 8)
	repeat
		local byte = value % 128
		value = value // 128
		if value > 0 then
			byte += 128
		end
		buffer.writeu8(writer.buf, writer.len, byte)
		writer.len += 1
	until value == 0
end

local function writeNumber(writer: Writer, value: number)
	local isSafeInteger = value % 1 == 0
		and value >= -MAX_SAFE_INTEGER
		and value <= MAX_SAFE_INTEGER
		and not (value == 0 and 1 / value < 0) -- keep -0 on the float path so its sign survives
	if isSafeInteger then
		if value >= 0 then
			writeByte(writer, TAG_PINT)
			writeVarint(writer, value)
		else
			writeByte(writer, TAG_NINT)
			writeVarint(writer, -value)
		end
		return
	end

	buffer.writef32(F32_PROBE, 0, value)
	if buffer.readf32(F32_PROBE, 0) == value or value ~= value then
		writeByte(writer, TAG_F32)
		reserve(writer, 4)
		buffer.writef32(writer.buf, writer.len, value)
		writer.len += 4
	else
		writeByte(writer, TAG_F64)
		reserve(writer, 8)
		buffer.writef64(writer.buf, writer.len, value)
		writer.len += 8
	end
end

local function isArrayKey(key: any, arrayCount: number): boolean
	return type(key) == "number" and key % 1 == 0 and key >= 1 and key <= arrayCount
end

local encodeValue: (Writer, any, { [any]: boolean }) -> ()

-- Tables are read raw: rawlen/rawget/pairs never consult metamethods, so what
-- gets stored is exactly the table's own contents.
local function writeTable(writer: Writer, value: { [any]: any }, seen: { [any]: boolean })
	if seen[value] then
		error("snack: cannot serialize a cyclic table", 0)
	end
	seen[value] = true

	writeByte(writer, TAG_TABLE)

	local arrayCount = rawlen(value)
	writeVarint(writer, arrayCount)
	for index = 1, arrayCount do
		encodeValue(writer, rawget(value, index), seen)
	end

	local pairCount = 0
	for key in pairs(value) do
		if not isArrayKey(key, arrayCount) then
			pairCount += 1
		end
	end
	writeVarint(writer, pairCount)
	for key, entry in pairs(value) do
		if not isArrayKey(key, arrayCount) then
			encodeValue(writer, key, seen)
			encodeValue(writer, entry, seen)
		end
	end

	seen[value] = nil
end

encodeValue = function(writer: Writer, value: any, seen: { [any]: boolean })
	local kind = type(value)
	if kind == "nil" then
		writeByte(writer, TAG_NIL)
	elseif kind == "boolean" then
		writeByte(writer, if value then TAG_TRUE else TAG_FALSE)
	elseif kind == "number" then
		writeNumber(writer, value)
	elseif kind == "string" then
		writeByte(writer, TAG_STRING)
		writeVarint(writer, #value)
		reserve(writer, #value)
		buffer.writestring(writer.buf, writer.len, value)
		writer.len += #value
	elseif kind == "vector" then
		writeByte(writer, TAG_VECTOR)
		reserve(writer, 12)
		buffer.writef32(writer.buf, writer.len, value.x)
		buffer.writef32(writer.buf, writer.len + 4, value.y)
		buffer.writef32(writer.buf, writer.len + 8, value.z)
		writer.len += 12
	elseif kind == "buffer" then
		local length = buffer.len(value)
		writeByte(writer, TAG_BUFFER)
		writeVarint(writer, length)
		reserve(writer, length)
		buffer.copy(writer.buf, writer.len, value, 0, length)
		writer.len += length
	elseif kind == "table" then
		writeTable(writer, value, seen)
	else
		error(`snack: cannot serialize a value of type "{typeof(value)}"`, 0)
	end
end

local function encode(value: any): buffer
	local writer: Writer = { buf = buffer.create(16), len = 0 }
	encodeValue(writer, value, {})
	if writer.len == buffer.len(writer.buf) then
		return writer.buf
	end
	local exact = buffer.create(writer.len)
	buffer.copy(exact, 0, writer.buf, 0, writer.len)
	return exact
end

--[[
	Decoding

	Every read is bounds-checked up front so that a truncated or corrupt
	snack always fails with a clear "malformed snack" error instead of a
	raw buffer access error — and so that forged length fields cannot make
	bite allocate or loop disproportionately to the input size.
]]

local function need(bytes: buffer, position: number, count: number)
	if position + count > buffer.len(bytes) then
		error("snack.bite: malformed snack (truncated)", 0)
	end
end

local function readVarint(bytes: buffer, position: number): (number, number)
	local result = 0
	local multiplier = 1
	while true do
		need(bytes, position, 1)
		local byte = buffer.readu8(bytes, position)
		position += 1
		result += (byte % 128) * multiplier
		if byte < 128 then
			break
		end
		multiplier *= 128
		if multiplier > MAX_SAFE_INTEGER then
			error("snack.bite: malformed snack (varint too long)", 0)
		end
	end
	if result > MAX_SAFE_INTEGER then
		error("snack.bite: malformed snack (varint too large)", 0)
	end
	return result, position
end

local decodeValue: (buffer, number) -> (any, number)

decodeValue = function(bytes: buffer, position: number): (any, number)
	need(bytes, position, 1)
	local tag = buffer.readu8(bytes, position)
	position += 1

	if tag == TAG_NIL then
		return nil, position
	elseif tag == TAG_FALSE then
		return false, position
	elseif tag == TAG_TRUE then
		return true, position
	elseif tag == TAG_PINT then
		return readVarint(bytes, position)
	elseif tag == TAG_NINT then
		local value, nextPosition = readVarint(bytes, position)
		return -value, nextPosition
	elseif tag == TAG_F32 then
		need(bytes, position, 4)
		return buffer.readf32(bytes, position), position + 4
	elseif tag == TAG_F64 then
		need(bytes, position, 8)
		return buffer.readf64(bytes, position), position + 8
	elseif tag == TAG_STRING then
		local length, dataPosition = readVarint(bytes, position)
		need(bytes, dataPosition, length)
		return buffer.readstring(bytes, dataPosition, length), dataPosition + length
	elseif tag == TAG_VECTOR then
		need(bytes, position, 12)
		return vector.create(
			buffer.readf32(bytes, position),
			buffer.readf32(bytes, position + 4),
			buffer.readf32(bytes, position + 8)
		),
			position + 12
	elseif tag == TAG_BUFFER then
		local length, dataPosition = readVarint(bytes, position)
		need(bytes, dataPosition, length)
		local copy = buffer.create(length)
		buffer.copy(copy, 0, bytes, dataPosition, length)
		return copy, dataPosition + length
	elseif tag == TAG_TABLE then
		local result = {}

		local arrayCount, cursor = readVarint(bytes, position)
		-- Each encoded value takes at least one byte, so a count larger than
		-- the remaining bytes can only come from a forged length field.
		need(bytes, cursor, arrayCount)
		for index = 1, arrayCount do
			local entry, nextCursor = decodeValue(bytes, cursor)
			result[index] = entry
			cursor = nextCursor
		end

		local pairCount
		pairCount, cursor = readVarint(bytes, cursor)
		need(bytes, cursor, pairCount * 2)
		for _ = 1, pairCount do
			local key, keyEnd = decodeValue(bytes, cursor)
			local entry, entryEnd = decodeValue(bytes, keyEnd)
			if key == nil then
				error("snack.bite: malformed snack (nil table key)", 0)
			end
			result[key] = entry
			cursor = entryEnd
		end

		return result, cursor
	end

	error(`snack.bite: malformed snack (unknown tag {tag})`, 0)
end

--[[
	Public API
]]

--- Unpacks a snack back into the value that was passed to `snack(...)`.
--- Errors if given anything other than a buffer produced by snack (or a
--- byte-identical copy of one).
local function bite<T>(s: Snack<T>): T
	local bytes = s :: any
	if type(bytes) ~= "buffer" then
		error(`snack.bite: expected a snack, got a value of type "{typeof(s)}"`, 2)
	end
	local value, position = decodeValue(bytes, 0)
	if position ~= buffer.len(bytes) then
		error("snack.bite: malformed snack (trailing bytes)", 0)
	end
	return value :: T
end

--- Number of bytes the snack occupies.
local function size(s: Snack<any>): number
	local bytes = s :: any
	if type(bytes) ~= "buffer" then
		error(`snack.size: expected a snack, got a value of type "{typeof(s)}"`, 2)
	end
	return buffer.len(bytes)
end

--- The snack's underlying `buffer` (the same object, not a copy). Use this
--- when handing a snack to an API typed against `buffer`, such as a
--- DataStore or a RemoteEvent.
local function raw(s: Snack<any>): buffer
	local bytes = s :: any
	if type(bytes) ~= "buffer" then
		error(`snack.raw: expected a snack, got a value of type "{typeof(s)}"`, 2)
	end
	return bytes
end

--- Re-brands a `buffer` (for example one loaded back from a DataStore) as a
--- Snack<T> without copying or validating it. Annotate the result with the
--- type you expect: `local s: snack.String = snack.wrap(bytes)`.
local function wrap<T>(bytes: buffer): Snack<T>
	if type(bytes) ~= "buffer" then
		error(`snack.wrap: expected a buffer, got a value of type "{typeof(bytes)}"`, 2)
	end
	return bytes :: any
end

--- True if `value` is a buffer containing one complete, well-formed snack.
local function is(value: any): boolean
	if type(value) ~= "buffer" then
		return false
	end
	return (pcall(bite, value :: any))
end

local snack = {
	bite = bite,
	size = size,
	raw = raw,
	wrap = wrap,
	is = is,
}

return setmetatable(snack, {
	__call = function<T>(_module: any, value: T): Snack<T>
		return encode(value) :: any
	end,
})
