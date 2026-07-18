--!strict

--[=[
	Decoding and structural walking of snack's wire format.

	Every read is bounds-checked up front so that a truncated or corrupt
	snack always fails with a clear "malformed snack" error instead of a raw
	buffer access error — and so that forged length fields cannot make the
	decoder allocate or loop disproportionately to the input size.

	`decodeValue` materializes one value; `skipValue` walks the same grammar
	without building anything, which is what lets pack operations (count,
	nibble) step over entries they don't need. The two share `need` and
	`readVarint`, so malformed input fails identically through either path.
]=]

local Tags = require("./Tags")

--- Errors unless `count` more bytes are available at `position`.
local function need(bytes: buffer, position: number, count: number)
	if position + count > buffer.len(bytes) then
		error("snack: malformed snack (truncated)", 0)
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
		if multiplier > Tags.MAX_SAFE_INTEGER then
			error("snack: malformed snack (varint too long)", 0)
		end
	end
	-- A structurally valid 8-byte varint can still encode up to 2^56 - 1;
	-- values past 2^53 would round silently in a double, so refuse them.
	if result > Tags.MAX_SAFE_INTEGER then
		error("snack: malformed snack (varint too large)", 0)
	end
	return result, position
end

local decodeValue: (buffer, number) -> (any, number)

decodeValue = function(bytes: buffer, position: number): (any, number)
	need(bytes, position, 1)
	local tag = buffer.readu8(bytes, position)
	position += 1

	if tag == Tags.NIL then
		return nil, position
	elseif tag == Tags.FALSE then
		return false, position
	elseif tag == Tags.TRUE then
		return true, position
	elseif tag == Tags.PINT then
		return readVarint(bytes, position)
	elseif tag == Tags.NINT then
		local value, nextPosition = readVarint(bytes, position)
		return -value, nextPosition
	elseif tag == Tags.F32 then
		need(bytes, position, 4)
		return buffer.readf32(bytes, position), position + 4
	elseif tag == Tags.F64 then
		need(bytes, position, 8)
		return buffer.readf64(bytes, position), position + 8
	elseif tag == Tags.STRING then
		local length, dataPosition = readVarint(bytes, position)
		need(bytes, dataPosition, length)
		return buffer.readstring(bytes, dataPosition, length), dataPosition + length
	elseif tag == Tags.VECTOR then
		need(bytes, position, 12)
		return vector.create(
			buffer.readf32(bytes, position),
			buffer.readf32(bytes, position + 4),
			buffer.readf32(bytes, position + 8)
		),
			position + 12
	elseif tag == Tags.BUFFER then
		local length, dataPosition = readVarint(bytes, position)
		need(bytes, dataPosition, length)
		local copy = buffer.create(length)
		buffer.copy(copy, 0, bytes, dataPosition, length)
		return copy, dataPosition + length
	elseif tag == Tags.TABLE then
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
				error("snack: malformed snack (nil table key)", 0)
			end
			result[key] = entry
			cursor = entryEnd
		end

		return result, cursor
	end

	error(`snack: malformed snack (unknown tag {tag})`, 0)
end

--- Walks one encoded value structurally, returning the position just past
--- it, without materializing anything.
local skipValue: (buffer, number) -> number

skipValue = function(bytes: buffer, position: number): number
	need(bytes, position, 1)
	local tag = buffer.readu8(bytes, position)
	position += 1

	if tag == Tags.NIL or tag == Tags.FALSE or tag == Tags.TRUE then
		return position
	elseif tag == Tags.PINT or tag == Tags.NINT then
		local _, nextPosition = readVarint(bytes, position)
		return nextPosition
	elseif tag == Tags.F32 then
		need(bytes, position, 4)
		return position + 4
	elseif tag == Tags.F64 then
		need(bytes, position, 8)
		return position + 8
	elseif tag == Tags.STRING or tag == Tags.BUFFER then
		local length, dataPosition = readVarint(bytes, position)
		need(bytes, dataPosition, length)
		return dataPosition + length
	elseif tag == Tags.VECTOR then
		need(bytes, position, 12)
		return position + 12
	elseif tag == Tags.TABLE then
		local arrayCount, cursor = readVarint(bytes, position)
		need(bytes, cursor, arrayCount)
		for _ = 1, arrayCount do
			cursor = skipValue(bytes, cursor)
		end
		local pairCount
		pairCount, cursor = readVarint(bytes, cursor)
		need(bytes, cursor, pairCount * 2)
		for _ = 1, pairCount do
			cursor = skipValue(bytes, cursor)
			cursor = skipValue(bytes, cursor)
		end
		return cursor
	end

	error(`snack: malformed snack (unknown tag {tag})`, 0)
end

return {
	decodeValue = decodeValue,
	skipValue = skipValue,
}
