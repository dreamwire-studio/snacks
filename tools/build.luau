--!strict

--[=[
	Bundles the src/ modules into the single-file module at build/init.luau.

	Wally and Roblox consumers get one dependency-free ModuleScript, while
	the sources stay split for readability. The bundler is deliberately dumb
	and relies on these conventions, which the sources follow:

	- internal modules live at src/<Name>.luau and are listed in dependency
	  order in MODULE_ORDER below
	- sibling requires are single lines of the exact form
	  `local <Name> = require("./<Name>")` (or `require("@self/<Name>")`
	  from init.luau, whose `./` would escape the directory); the bundler
	  drops them and the names resolve to the wrapped module locals instead
	- internal `export type` becomes a plain local `type` in the bundle
	  (IIFE bodies cannot export), so cross-module type references go through
	  `typeof(...)` expressions, never type namespaces like `Writer.Writer`
	- only src/init.luau exports types, and it is emitted last, unwrapped,
	  so its `export type` statements stay at the top level of the bundle

	Run with:
		lute tools/build.luau
]=]

local fs = require("@lute/fs")

local MODULE_ORDER = { "Tags", "Writer", "Encoder", "Decoder", "Digest" }
local ENTRY = "init"
local OUTPUT_DIRECTORY = "build"
local OUTPUT = "build/init.luau"

local function readFile(path: string): string
	local handle = fs.open(path, "r")
	local contents = fs.read(handle)
	fs.close(handle)
	return contents
end

--- Strips directives and sibling requires; internal modules additionally
--- lose the `export` on their type aliases.
local function transform(source: string, isEntry: boolean): string
	local lines: { string } = {}
	for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
		local isDirective = string.match(line, "^%-%-!") ~= nil
		local requirePath = string.match(line, '^local%s+[%w_]+%s*=%s*require%("([^"]+)"%)%s*$')
		local isSiblingRequire = requirePath ~= nil
			and (string.match(requirePath, "^%./[%w_]+$") ~= nil or string.match(requirePath, "^@self/[%w_]+$") ~= nil)
		if not isDirective and not isSiblingRequire then
			if not isEntry then
				local aliasBody = string.match(line, "^export type (.*)$")
				if aliasBody ~= nil then
					line = "type " .. aliasBody
				end
			end
			table.insert(lines, line)
		end
	end
	while lines[1] == "" do
		table.remove(lines, 1)
	end
	while lines[#lines] == "" do
		table.remove(lines)
	end
	return table.concat(lines, "\n")
end

local function indent(source: string): string
	local lines: { string } = {}
	for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
		table.insert(lines, if line == "" then "" else "\t" .. line)
	end
	return table.concat(lines, "\n")
end

local pieces: { string } = {}

table.insert(
	pieces,
	table.concat({
		"--!strict",
		"--!native",
		"",
		"--[=[",
		"\tTHIS FILE IS GENERATED — do not edit it directly.",
		"",
		"\tIt is bundled from the modules in src/ by tools/build.luau:",
		"\t\tlute tools/build.luau",
		"\tEdit those sources instead, then rebuild.",
		"]=]",
		"",
	}, "\n")
)

for _, name in MODULE_ORDER do
	local body = transform(readFile(`src/{name}.luau`), false)
	table.insert(pieces, `local {name} = (function()\n{indent(body)}\nend)()\n`)
end

table.insert(pieces, transform(readFile(`src/{ENTRY}.luau`), true))

local bundle = table.concat(pieces, "\n") .. "\n"

-- A surviving sibling require means a module was required that is not in
-- MODULE_ORDER (or the require did not match the expected form).
if string.find(bundle, 'require%("%./') ~= nil or string.find(bundle, 'require%("@self/') ~= nil then
	error("build: a sibling require survived bundling — check MODULE_ORDER and require formatting", 0)
end

if not fs.exists(OUTPUT_DIRECTORY) then
	fs.mkdir(OUTPUT_DIRECTORY)
end
local handle = fs.open(OUTPUT, "w")
fs.write(handle, bundle)
fs.close(handle)

print(`build: wrote {OUTPUT} ({#bundle} bytes) from {#MODULE_ORDER + 1} source files`)
