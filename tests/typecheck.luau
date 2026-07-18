--!strict

--[=[
	Typed-usage fixture: exercises the exported phantom types exactly the way
	a consumer would. `lute check` / `luau-lsp analyze` verify it statically,
	and the test runner executes its assertions at runtime.
]=]

local snack = require("../build")

return function()
	local greeting: snack.String = snack("hello")
	local answer: snack.Number = snack(42)
	local flag: snack.Boolean = snack(false)
	local nothing: snack.Nil = snack(nil)
	local items: snack.Table = snack({ 1, 2, 3 })
	local typedItems: snack.Table<{ number }> = snack({ 4, 5 })
	local direction: snack.Vector = snack(vector.create(1, 0, 0))
	local blob: snack.Buffer = snack(buffer.fromstring("bytes"))

	local greetingValue: string = snack.bite(greeting)
	local answerValue: number = snack.bite(answer)
	local flagValue: boolean = snack.bite(flag)
	local nothingValue: nil = snack.bite(nothing)
	local itemsValue = snack.bite(items)
	local typedItemsValue: { number } = snack.bite(typedItems)
	local directionValue = snack.bite(direction)
	local blobValue: buffer = snack.bite(blob)

	assert(greetingValue == "hello", "greeting round trip")
	assert(answerValue == 42, "answer round trip")
	assert(flagValue == false, "flag round trip")
	assert(nothingValue == nil, "nothing round trip")
	assert((itemsValue :: { number })[3] == 3, "items round trip")
	assert(typedItemsValue[2] == 5, "typedItems round trip")
	assert(directionValue == vector.create(1, 0, 0), "direction round trip")
	assert(buffer.tostring(blobValue) == "bytes", "blob round trip")

	-- Round trip through raw bytes, the way a DataStore save/load goes.
	local stored: buffer = snack.raw(greeting)
	local restored = snack.wrap(stored) :: snack.String
	assert(snack.bite(restored) == "hello", "wrap round trip")

	-- Packs: many snacks in one buffer, with typed construction.
	local bundle: snack.Pack = snack.pack(greeting, answer)
	local bundleValues, bundleCount = snack.unpack(bundle)
	assert(bundleCount == 2, "pack count")
	assert(bundleValues[1] == "hello", "pack first entry")
	assert(snack.nibble(bundle, 2) == 42, "nibble second entry")
	local merged: snack.Pack = snack.pack(bundle, flag)
	assert(snack.count(merged) == 3, "merged pack count")

	-- Digests: printable transport encodings. Undigested is both a
	-- Snack<any> and a Pack, so bite and the pack functions both typecheck.
	local digested: string = snack.digest(greeting)
	local restoredSnack: snack.Undigested = snack.undigest(digested)
	assert(snack.bite(restoredSnack) == "hello", "hex digest round trip")
	local packDigest: string = snack.digest(merged, "base64-urlsafe")
	local restoredPack = snack.undigest(packDigest, "base64-urlsafe")
	assert(snack.count(restoredPack) == 3, "pack digest round trip")
	assert(snack.nibble(restoredPack, 1) == "hello", "nibble after undigest")
end
