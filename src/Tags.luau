--!strict

--[=[
	Wire-format constants shared by the encoder and decoder.

	Every encoded value starts with one tag byte; the payload layout depends
	on it. Tags 11-255 are reserved for future format revisions and are
	rejected by the decoder.
]=]

local Tags = {
	-- No payload: the tag byte is the whole value.
	NIL = 0,
	FALSE = 1,
	TRUE = 2,

	-- Unsigned LEB128 varint of the integer (NINT stores the negated value,
	-- so -5 is written as varint 5 under the NINT tag).
	PINT = 3,
	NINT = 4,

	-- IEEE 754 floats. F32 is chosen whenever the 4-byte form is bit-exact
	-- for the value; F64 is the lossless fallback.
	F32 = 5,
	F64 = 6,

	-- Varint byte length, then the raw bytes.
	STRING = 7,

	-- x, y, z as three f32 (native vectors are f32-backed, so no precision
	-- is lost).
	VECTOR = 8,

	-- Varint byte length, then the raw bytes.
	BUFFER = 9,

	-- Varint array count + that many values, then varint pair count + that
	-- many key/value pairs.
	TABLE = 10,

	-- Largest integer a double represents contiguously (2^53). Bigger values
	-- are stored as floats, because varint arithmetic past this point loses
	-- precision — and the decoder rejects varints beyond it for the same
	-- reason.
	MAX_SAFE_INTEGER = 2 ^ 53,
}

return table.freeze(Tags)
