--!strict

--[=[
	A growable byte writer over `buffer`.

	Buffers cannot be resized, so the writer doubles its capacity whenever a
	write would overflow, and `finish` returns the bytes trimmed to their
	exact final size (memory efficiency is the whole point of snack, so the
	returned buffer never carries slack capacity).
]=]

export type Writer = {
	buf: buffer,
	len: number,
}

local function new(): Writer
	return { buf = buffer.create(16), len = 0 }
end

--- Grows the backing buffer until `extra` more bytes fit.
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

--- Unsigned LEB128: 7 bits of payload per byte, high bit set on all but the
--- last byte. Integers up to 2^53 need at most 8 bytes.
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

--- The written bytes as an exactly-sized buffer. Returns the backing buffer
--- directly when it happens to be a perfect fit; copies otherwise.
local function finish(writer: Writer): buffer
	if writer.len == buffer.len(writer.buf) then
		return writer.buf
	end
	local exact = buffer.create(writer.len)
	buffer.copy(exact, 0, writer.buf, 0, writer.len)
	return exact
end

return {
	new = new,
	reserve = reserve,
	writeByte = writeByte,
	writeVarint = writeVarint,
	finish = finish,
}
