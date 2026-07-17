--!strict

--[=[
	Typed-usage fixture: exercises the exported phantom types exactly the way
	a consumer would. `lute check` / `luau-lsp analyze` verify it statically,
	and the test runner executes its assertions at runtime.
]=]

local snack = require("../src")

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
end
