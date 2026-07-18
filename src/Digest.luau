--!strict

--[=[
	Transcoding between raw snack/pack bytes and printable strings, for
	transports that cannot carry binary: HTTP JSON bodies, headers, query
	strings, and the like.

	Three algorithms:

	- "hex": lowercase hexadecimal, 2 characters per byte. Decoding accepts
	  either case.
	- "base64": RFC 4648 section 4 with "=" padding, ~1.33 characters per
	  byte. The safe default for JSON bodies.
	- "base64-urlsafe": RFC 4648 section 5 ("-" and "_" instead of "+" and
	  "/"), emitted without padding because "=" would itself need escaping in
	  a URL. Decoding accepts optional padding.

	Encoding is pure transcoding — no header, no framing — so decoding
	returns a buffer byte-identical to the one that was encoded. Decoders are
	strict: characters outside the chosen alphabet, impossible lengths,
	misplaced padding, and non-zero trailing bits are all rejected with
	positioned errors.
]=]

local HEX_ALPHABET = "0123456789abcdef"
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_URLSAFE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local PADDING = string.byte("=")

-- Encode tables are the alphabet's bytes themselves: readu8 at the value's
-- index yields its character. Decode tables map a character byte (+1, for
-- 1-based indexing) back to its value, with -1 marking invalid characters.
local function buildDecodeTable(alphabet: string): { number }
	local decodeTable = table.create(256, -1)
	for index = 1, #alphabet do
		decodeTable[string.byte(alphabet, index) + 1] = index - 1
	end
	return decodeTable
end

local HEX_ENCODE = buffer.fromstring(HEX_ALPHABET)
local HEX_DECODE = buildDecodeTable(HEX_ALPHABET)
for index = 1, 6 do
	-- Uppercase A-F decode too; encoding always emits lowercase.
	HEX_DECODE[string.byte("ABCDEF", index) + 1] = 9 + index
end

local BASE64_ENCODE = buffer.fromstring(BASE64_ALPHABET)
local BASE64_DECODE = buildDecodeTable(BASE64_ALPHABET)
local URLSAFE_ENCODE = buffer.fromstring(BASE64_URLSAFE_ALPHABET)
local URLSAFE_DECODE = buildDecodeTable(BASE64_URLSAFE_ALPHABET)

local function encodeHex(bytes: buffer): string
	local length = buffer.len(bytes)
	local output = buffer.create(length * 2)
	for offset = 0, length - 1 do
		local value = buffer.readu8(bytes, offset)
		buffer.writeu8(output, offset * 2, buffer.readu8(HEX_ENCODE, value // 16))
		buffer.writeu8(output, offset * 2 + 1, buffer.readu8(HEX_ENCODE, value % 16))
	end
	return buffer.tostring(output)
end

local function decodeHex(text: string): buffer
	local length = #text
	if length % 2 ~= 0 then
		error("snack.undigest: malformed digest (odd hex length)", 0)
	end
	local input = buffer.fromstring(text)
	local output = buffer.create(length // 2)
	for offset = 0, length - 1, 2 do
		local high = HEX_DECODE[buffer.readu8(input, offset) + 1]
		local low = HEX_DECODE[buffer.readu8(input, offset + 1) + 1]
		if high < 0 or low < 0 then
			local position = if high < 0 then offset + 1 else offset + 2
			error(`snack.undigest: malformed digest (invalid character at position {position})`, 0)
		end
		buffer.writeu8(output, offset // 2, high * 16 + low)
	end
	return output
end

local function encodeBase64(bytes: buffer, alphabet: buffer, withPadding: boolean): string
	local length = buffer.len(bytes)
	local fullChunks = length // 3
	local remainder = length % 3
	local outputLength = fullChunks * 4 + (if remainder == 0 then 0 elseif remainder == 1 then 2 else 3)
	if withPadding and remainder > 0 then
		outputLength += 3 - remainder
	end

	local output = buffer.create(outputLength)
	local inPosition = 0
	local outPosition = 0
	for _ = 1, fullChunks do
		local chunk = buffer.readu8(bytes, inPosition) * 65536
			+ buffer.readu8(bytes, inPosition + 1) * 256
			+ buffer.readu8(bytes, inPosition + 2)
		buffer.writeu8(output, outPosition, buffer.readu8(alphabet, chunk // 262144))
		buffer.writeu8(output, outPosition + 1, buffer.readu8(alphabet, chunk // 4096 % 64))
		buffer.writeu8(output, outPosition + 2, buffer.readu8(alphabet, chunk // 64 % 64))
		buffer.writeu8(output, outPosition + 3, buffer.readu8(alphabet, chunk % 64))
		inPosition += 3
		outPosition += 4
	end

	if remainder == 1 then
		local value = buffer.readu8(bytes, inPosition)
		buffer.writeu8(output, outPosition, buffer.readu8(alphabet, value // 4))
		buffer.writeu8(output, outPosition + 1, buffer.readu8(alphabet, value % 4 * 16))
		outPosition += 2
	elseif remainder == 2 then
		local value = buffer.readu8(bytes, inPosition) * 256 + buffer.readu8(bytes, inPosition + 1)
		buffer.writeu8(output, outPosition, buffer.readu8(alphabet, value // 1024))
		buffer.writeu8(output, outPosition + 1, buffer.readu8(alphabet, value // 16 % 64))
		buffer.writeu8(output, outPosition + 2, buffer.readu8(alphabet, value % 16 * 4))
		outPosition += 3
	end

	while outPosition < outputLength do
		buffer.writeu8(output, outPosition, PADDING)
		outPosition += 1
	end

	return buffer.tostring(output)
end

local function decodeBase64Char(decodeTable: { number }, input: buffer, offset: number): number
	local value = decodeTable[buffer.readu8(input, offset) + 1]
	if value < 0 then
		error(`snack.undigest: malformed digest (invalid character at position {offset + 1})`, 0)
	end
	return value
end

local function decodeBase64(text: string, decodeTable: { number }): buffer
	-- Padding is optional (url-safe digests are emitted without it), but if
	-- present it must be well-formed: at most two "=" at the very end, with
	-- the total length a multiple of 4. "=" anywhere else falls out of the
	-- alphabet check below.
	local coreLength = #text
	local paddingCount = 0
	while coreLength > 0 and string.byte(text, coreLength) == PADDING do
		coreLength -= 1
		paddingCount += 1
	end
	if paddingCount > 2 or (paddingCount > 0 and #text % 4 ~= 0) then
		error("snack.undigest: malformed digest (misplaced padding)", 0)
	end

	local remainder = coreLength % 4
	if remainder == 1 then
		error("snack.undigest: malformed digest (truncated base64)", 0)
	end

	local fullQuads = coreLength // 4
	local outputLength = fullQuads * 3 + (if remainder == 0 then 0 elseif remainder == 2 then 1 else 2)
	local input = buffer.fromstring(text)
	local output = buffer.create(outputLength)

	local inPosition = 0
	local outPosition = 0
	for _ = 1, fullQuads do
		local a = decodeBase64Char(decodeTable, input, inPosition)
		local b = decodeBase64Char(decodeTable, input, inPosition + 1)
		local c = decodeBase64Char(decodeTable, input, inPosition + 2)
		local d = decodeBase64Char(decodeTable, input, inPosition + 3)
		local chunk = a * 262144 + b * 4096 + c * 64 + d
		buffer.writeu8(output, outPosition, chunk // 65536)
		buffer.writeu8(output, outPosition + 1, chunk // 256 % 256)
		buffer.writeu8(output, outPosition + 2, chunk % 256)
		inPosition += 4
		outPosition += 3
	end

	if remainder == 2 then
		local a = decodeBase64Char(decodeTable, input, inPosition)
		local b = decodeBase64Char(decodeTable, input, inPosition + 1)
		if b % 16 ~= 0 then
			error("snack.undigest: malformed digest (non-zero trailing bits)", 0)
		end
		buffer.writeu8(output, outPosition, a * 4 + b // 16)
	elseif remainder == 3 then
		local a = decodeBase64Char(decodeTable, input, inPosition)
		local b = decodeBase64Char(decodeTable, input, inPosition + 1)
		local c = decodeBase64Char(decodeTable, input, inPosition + 2)
		if c % 4 ~= 0 then
			error("snack.undigest: malformed digest (non-zero trailing bits)", 0)
		end
		local value = a * 1024 + b * 16 + c // 4
		buffer.writeu8(output, outPosition, value // 256)
		buffer.writeu8(output, outPosition + 1, value % 256)
	end

	return output
end

--- Bytes → printable string under the given algorithm.
local function encode(bytes: buffer, algorithm: string): string
	if algorithm == "hex" then
		return encodeHex(bytes)
	elseif algorithm == "base64" then
		return encodeBase64(bytes, BASE64_ENCODE, true)
	elseif algorithm == "base64-urlsafe" then
		return encodeBase64(bytes, URLSAFE_ENCODE, false)
	end
	error(`snack.digest: unknown algorithm "{algorithm}" (expected "hex", "base64", or "base64-urlsafe")`, 0)
end

--- Printable string → the exact bytes that were encoded.
local function decode(text: string, algorithm: string): buffer
	if algorithm == "hex" then
		return decodeHex(text)
	elseif algorithm == "base64" then
		return decodeBase64(text, BASE64_DECODE)
	elseif algorithm == "base64-urlsafe" then
		return decodeBase64(text, URLSAFE_DECODE)
	end
	error(`snack.undigest: unknown algorithm "{algorithm}" (expected "hex", "base64", or "base64-urlsafe")`, 0)
end

return {
	encode = encode,
	decode = decode,
}
