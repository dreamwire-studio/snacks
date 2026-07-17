--!strict

--[=[
	Coverage gate: parses the lcov-style coverage.out written by
	`luau --coverage tests/run.luau` and fails unless every instrumented
	line of src/init.luau was executed.

	Run with:
		lute tests/coverage.luau
]=]

local fs = require("@lute/fs")
local process = require("@lute/process")

local TARGET = "src/init.luau"

local coverageFile = fs.open("coverage.out", "r")
local contents = fs.read(coverageFile)
fs.close(coverageFile)

local inTarget = false
local hits: { [number]: number } = {}

for line in string.gmatch(contents, "[^\r\n]+") do
	local sourceFile = string.match(line, "^SF:(.+)$")
	if sourceFile ~= nil then
		inTarget = string.sub(sourceFile, -#TARGET) == TARGET
		continue
	end
	if not inTarget then
		continue
	end
	local lineText, hitText = string.match(line, "^DA:(%d+),(%d+)$")
	if lineText ~= nil then
		local lineNumber = tonumber(lineText) :: number
		local hitCount = tonumber(hitText) :: number
		hits[lineNumber] = math.max(hits[lineNumber] or 0, hitCount)
	end
end

local total = 0
local missed: { number } = {}
for lineNumber, hitCount in pairs(hits) do
	total += 1
	if hitCount == 0 then
		table.insert(missed, lineNumber)
	end
end
table.sort(missed)

if total == 0 then
	print(`coverage: no data found for {TARGET} — run "luau --coverage tests/run.luau" first`)
	process.exit(1)
end

local covered = total - #missed
local percent = string.format("%.1f%%", 100 * covered / total)
print(`coverage: {covered}/{total} instrumented lines of {TARGET} ({percent})`)
if #missed > 0 then
	print(`coverage: missed lines: {table.concat(missed, ", ")}`)
	process.exit(1)
end
