--!strict

--[=[
	Value encoding: turns any supported Luau value (nil, boolean, number,
	string, vector, buffer, table) into snack's wire format.

	Number packing picks the first lossless form: integers with magnitude up
	to 2^53 become PINT/NINT varints; everything else becomes F32 when the
	f32 round trip is bit-exact and F64 otherwise. -0 is kept on the float
	path so its sign survives.

	Tables are read raw: rawlen/rawget/pairs never consult metamethods, so
	what gets stored is exactly the table's own contents. Cyclic tables and
	unsupported value types raise immediately.
]=]

local Tags = require("./Tags")
local Writer = require("./Writer")

-- The writer state type, named through typeof so it survives single-file
-- bundling (type namespaces like Writer.Writer do not).
type WriterState = typeof(Writer.new())

-- Scratch buffer used to test whether a number survives an f32 round trip.
local F32_PROBE = buffer.create(4)

local function writeNumber(writer: WriterState, value: number)
	local isSafeInteger = value % 1 == 0
		and value >= -Tags.MAX_SAFE_INTEGER
		and value <= Tags.MAX_SAFE_INTEGER
		and not (value == 0 and 1 / value < 0) -- keep -0 on the float path so its sign survives
	if isSafeInteger then
		if value >= 0 then
			Writer.writeByte(writer, Tags.PINT)
			Writer.writeVarint(writer, value)
		else
			Writer.writeByte(writer, Tags.NINT)
			Writer.writeVarint(writer, -value)
		end
		return
	end

	buffer.writef32(F32_PROBE, 0, value)
	if buffer.readf32(F32_PROBE, 0) == value or value ~= value then
		Writer.writeByte(writer, Tags.F32)
		Writer.reserve(writer, 4)
		buffer.writef32(writer.buf, writer.len, value)
		writer.len += 4
	else
		Writer.writeByte(writer, Tags.F64)
		Writer.reserve(writer, 8)
		buffer.writef64(writer.buf, writer.len, value)
		writer.len += 8
	end
end

--- Integer keys 1..arrayCount are written positionally in the array part,
--- so the pair part must skip them.
local function isArrayKey(key: any, arrayCount: number): boolean
	return type(key) == "number" and key % 1 == 0 and key >= 1 and key <= arrayCount
end

local encodeValue: (WriterState, any, { [any]: boolean }) -> ()

local function writeTable(writer: WriterState, value: { [any]: any }, seen: { [any]: boolean })
	-- `seen` holds the tables on the current encoding path only (entries are
	-- cleared on the way out), so shared non-cyclic references are legal and
	-- get duplicated, while true cycles are rejected.
	if seen[value] then
		error("snack: cannot serialize a cyclic table", 0)
	end
	seen[value] = true

	Writer.writeByte(writer, Tags.TABLE)

	local arrayCount = rawlen(value)
	Writer.writeVarint(writer, arrayCount)
	for index = 1, arrayCount do
		encodeValue(writer, rawget(value, index), seen)
	end

	local pairCount = 0
	for key in pairs(value) do
		if not isArrayKey(key, arrayCount) then
			pairCount += 1
		end
	end
	Writer.writeVarint(writer, pairCount)
	for key, entry in pairs(value) do
		if not isArrayKey(key, arrayCount) then
			encodeValue(writer, key, seen)
			encodeValue(writer, entry, seen)
		end
	end

	seen[value] = nil
end

encodeValue = function(writer: WriterState, value: any, seen: { [any]: boolean })
	local kind = type(value)
	if kind == "nil" then
		Writer.writeByte(writer, Tags.NIL)
	elseif kind == "boolean" then
		Writer.writeByte(writer, if value then Tags.TRUE else Tags.FALSE)
	elseif kind == "number" then
		writeNumber(writer, value)
	elseif kind == "string" then
		Writer.writeByte(writer, Tags.STRING)
		Writer.writeVarint(writer, #value)
		Writer.reserve(writer, #value)
		buffer.writestring(writer.buf, writer.len, value)
		writer.len += #value
	elseif kind == "vector" then
		Writer.writeByte(writer, Tags.VECTOR)
		Writer.reserve(writer, 12)
		buffer.writef32(writer.buf, writer.len, value.x)
		buffer.writef32(writer.buf, writer.len + 4, value.y)
		buffer.writef32(writer.buf, writer.len + 8, value.z)
		writer.len += 12
	elseif kind == "buffer" then
		local length = buffer.len(value)
		Writer.writeByte(writer, Tags.BUFFER)
		Writer.writeVarint(writer, length)
		Writer.reserve(writer, length)
		buffer.copy(writer.buf, writer.len, value, 0, length)
		writer.len += length
	elseif kind == "table" then
		writeTable(writer, value, seen)
	else
		error(`snack: cannot serialize a value of type "{typeof(value)}"`, 0)
	end
end

--- Encodes one value into a fresh, exactly-sized buffer.
local function encode(value: any): buffer
	local writer = Writer.new()
	encodeValue(writer, value, {})
	return Writer.finish(writer)
end

return {
	encode = encode,
}
