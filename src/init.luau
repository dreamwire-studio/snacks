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

	This module holds the public API and its exported types; the wire format
	lives in Tags, encoding in Encoder + Writer, and decoding/walking in
	Decoder.
]=]

-- `@self` = this module's own directory: init.luau represents the `src`
-- directory itself, so a plain `./` here would resolve to siblings of src/.
local Decoder = require("@self/Decoder")
local Encoder = require("@self/Encoder")

local decodeValue = Decoder.decodeValue
local skipValue = Decoder.skipValue

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

export type Pack = {
	--[[ Phantom field, like Snack.__snack: a pack is really a `buffer`
	     holding zero or more snacks laid end to end. The distinct field keeps
	     Pack and Snack<T> from being assignable to each other, so a
	     multi-entry pack cannot accidentally be passed to `bite`. ]]
	__pack: true,
}

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
		error("snack: malformed snack (trailing bytes)", 0)
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

--- Concatenates any number of snacks and/or packs into a single Pack with
--- zero framing overhead: the result is exactly the pieces' bytes laid end
--- to end (the format is self-delimiting, so no separators are needed).
--- Nothing is re-encoded — this is pure `buffer.copy` — which also makes it
--- the append and merge operation: `pack(p, s)` appends, `pack(p1, p2)`
--- merges, and `pack()` is the empty pack.
local function pack(...: Snack<any> | Pack): Pack
	local pieceCount = select("#", ...)
	local total = 0
	for index = 1, pieceCount do
		local piece = select(index, ...) :: any
		if type(piece) ~= "buffer" then
			error(`snack.pack: expected a snack or pack at argument #{index}, got a value of type "{typeof(piece)}"`, 2)
		end
		total += buffer.len(piece)
	end

	local combined = buffer.create(total)
	local offset = 0
	for index = 1, pieceCount do
		local piece = (select(index, ...) :: any) :: buffer
		buffer.copy(combined, offset, piece, 0, buffer.len(piece))
		offset += buffer.len(piece)
	end
	return combined :: any
end

--- Decodes every entry of a pack. Returns the values as an array plus the
--- entry count — the count matters because entries can legitimately be nil,
--- which would make `#` unreliable on the array alone.
local function unpackEntries(p: Pack): ({ any }, number)
	local bytes = p :: any
	if type(bytes) ~= "buffer" then
		error(`snack.unpack: expected a pack, got a value of type "{typeof(p)}"`, 2)
	end
	local length = buffer.len(bytes)
	local values = {}
	local entryCount = 0
	local position = 0
	while position < length do
		local value, nextPosition = decodeValue(bytes, position)
		entryCount += 1
		values[entryCount] = value
		position = nextPosition
	end
	return values, entryCount
end

--- Number of entries in a pack, found by walking entry boundaries without
--- decoding anything. Errors on malformed bytes, so `pcall(snack.count, p)`
--- doubles as pack validation.
local function count(p: Pack): number
	local bytes = p :: any
	if type(bytes) ~= "buffer" then
		error(`snack.count: expected a pack, got a value of type "{typeof(p)}"`, 2)
	end
	local length = buffer.len(bytes)
	local entries = 0
	local position = 0
	while position < length do
		position = skipValue(bytes, position)
		entries += 1
	end
	return entries
end

--- Decodes only the pack entry at `index` (1-based), skipping over the
--- others without decoding them. Errors if the index is past the last entry.
local function nibble(p: Pack, index: number): any
	local bytes = p :: any
	if type(bytes) ~= "buffer" then
		error(`snack.nibble: expected a pack, got a value of type "{typeof(p)}"`, 2)
	end
	if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then
		error(`snack.nibble: index must be a positive integer, got {tostring(index)}`, 2)
	end

	local length = buffer.len(bytes)
	local entry = 0
	local position = 0
	while position < length do
		entry += 1
		if entry == index then
			return (decodeValue(bytes, position))
		end
		position = skipValue(bytes, position)
	end
	error(`snack.nibble: index {index} is out of range for a pack of {entry} entries`, 2)
end

local snack = {
	bite = bite,
	size = size,
	raw = raw,
	wrap = wrap,
	is = is,
	pack = pack,
	unpack = unpackEntries,
	count = count,
	nibble = nibble,
}

return setmetatable(snack, {
	__call = function<T>(_module: any, value: T): Snack<T>
		return Encoder.encode(value) :: any
	end,
})
