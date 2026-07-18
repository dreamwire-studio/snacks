# snack

[![CI](https://github.com/dreamwire-studio/snacks/actions/workflows/ci.yml/badge.svg)](https://github.com/dreamwire-studio/snacks/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Pack any Luau value into the smallest practical pile of bytes — then `bite` it back out.

`snack` converts `nil`, `boolean`, `number`, `string`, `vector`, `buffer`, and `table`
values into compact binary [`buffer`](https://luau.org/library#buffer-library)s. Buffers are
the densest way to hold data at rest in the Roblox engine: a packed snack is raw bytes with
no per-field table overhead, goes straight into DataStores (which accept buffers directly),
and squeezes far more state under the ~900-byte unreliable remote budget.

```lua
local snack = require(game.ReplicatedStorage.Packages.Snack)

local apple: snack.String = snack("string")
local bannana: snack.Number = snack(0)
local carrot: snack.Boolean = snack(false)

print(snack.bite(apple)) --> "string"
print(snack.bite(bannana)) --> 0
print(snack.bite(carrot)) --> false

local pack_lunch = snack.pack(apple, bannana, carrot)

print(snack.nibble(pack_lunch, 1)) --> "string"
print(snack.nibble(pack_lunch, 2)) --> 0
print(snack.nibble(pack_lunch, 3)) --> false

local values, n = snack.unpack(pack_lunch)
for index = 1, n do
	print(values[index]) --> "string", 0, false
end

print(snack.digest(pack_lunch)) 					--> "0706737472696e67030001" (default hex)
print(snack.digest(pack_lunch, "base64")) 			--> "BwZzdHJpbmcDAAE="
print(snack.digest(pack_lunch, "base64-urlsafe")) 	--> "BwZzdHJpbmcDAAE"

local restored = snack.undigest("0706737472696e67030001")
print(snack.nibble(restored, 1)) --> "string"
```

A `Snack<T>` remembers what went in, so `bite` hands the original type straight back to the
type checker — no casts at the call site.

---

## Installation

Add snack to your `wally.toml` and install:

```toml
[dependencies]
Snack = "dreamwire-studio/snack@0.3.0"
```

```sh
wally install
```

Then require it through your Rojo project as usual:

```lua
local snack = require(game.ReplicatedStorage.Packages.Snack)
```

No dependencies, one ModuleScript, works on the server, the client, and in plain Luau
runtimes (tested against both [Lute](https://github.com/luau-lang/lute) and the
[`luau` CLI](https://github.com/luau-lang/luau)).

---

## Quick tour

```lua
local snack = require(game.ReplicatedStorage.Packages.Snack)
local bite = snack.bite

-- Pack anything supported, including nested tables of mixed values:
local save: snack.Table = snack({
	coins = 12500,
	level = 42,
	position = vector.create(12.5, 4, -100),
	inventory = { "sword", "shield", "potion" },
})

print(snack.size(save)) --> 82   (the JSON equivalent is ~92 bytes and cannot hold a vector)

-- Unpack it later:
local data = bite(save)
print(data.coins) --> 12500

-- Ship it somewhere that wants a plain buffer, then re-brand it on the way back:
someDataStore:SetAsync(key, snack.raw(save))

local stored = someDataStore:GetAsync(key)
if snack.is(stored) then
	local restored = bite(snack.wrap(stored) :: snack.Table)
end
```

---

## API

### `snack(value) → Snack<T>`

The module itself is callable. Packs `value` into a fresh, exactly-sized buffer and returns
it. Accepts `nil`, `boolean`, `number`, `string`, `vector`, `buffer`, and `table` (nested
arbitrarily). Anything else — functions, threads, userdata such as `Instance` or `CFrame` —
raises `snack: cannot serialize a value of type "..."`. Cyclic tables raise
`snack: cannot serialize a cyclic table`.

### `snack.bite(s: Snack<T>) → T`

Unpacks a snack back into the value that was packed. Bind it locally for the short spelling:

```lua
local bite = snack.bite
print(bite(a))
```

`bite` fully validates its input: a truncated, corrupt, or forged buffer raises a
descriptive `snack: malformed snack (...)` error rather than a raw buffer access
error, and forged length fields cannot cause large allocations or long loops. Wrap the
call in `pcall` (or pre-check with `snack.is`) when the bytes come from an untrusted peer.

### `snack.size(s: Snack<any>) → number`

Byte length of the packed snack. Sugar for `buffer.len(snack.raw(s))`.

### `snack.raw(s: Snack<any>) → buffer`

The snack's underlying `buffer` — the same object, not a copy. A snack already *is* a
buffer at runtime; `raw` just tells the type checker so, for handing to APIs typed against
`buffer` (DataStores, remotes, `buffer.*` functions).

### `snack.wrap(bytes: buffer) → Snack<T>`

The inverse of `raw`: re-brands a plain buffer (for example, one loaded back from a
DataStore) as a snack, without copying or validating. Annotate or cast the result to tell
the type checker what you expect back:

```lua
local restored = snack.wrap(stored) :: snack.String
```

`wrap` trusts you; pair it with `snack.is` when the bytes might not be a snack.

### `snack.is(value: any) → boolean`

`true` only if `value` is a buffer containing exactly one complete, well-formed snack.
(A multi-entry pack is deliberately *not* a valid snack — validate packs with
`pcall(snack.count, p)` instead.)

### `snack.pack(...: Snack | Pack) → Pack`

Concatenates any number of snacks and/or packs into one buffer — a *pack*. Because the
wire format is self-delimiting, entries are laid end to end with **zero framing bytes**:
a pack's size is exactly the sum of its pieces, and nothing is re-encoded (it is pure
`buffer.copy`). That makes `pack` three operations in one:

```lua
local p = snack.pack(a, b)        -- build
local p2 = snack.pack(p, c)       -- append
local all = snack.pack(p, p2)     -- merge
local empty = snack.pack()        -- the empty pack (0 bytes)
```

### `snack.unpack(p: Pack) → ({any}, number)`

Decodes every entry, returning the values as an array **plus the entry count**. Use the
count rather than `#values`, because entries can legitimately be `nil`:

```lua
local values, n = snack.unpack(p)
for index = 1, n do
	handle(values[index])
end
```

### `snack.nibble(p: Pack, index: number) → any`

Decodes *only* the entry at `index` (1-based). Other entries are skipped structurally —
their boundaries are walked, but no tables, strings, or buffers are materialized — so
nibbling one entry out of a large pack is much cheaper than unpacking everything. Errors
if `index` is past the last entry.

### `snack.count(p: Pack) → number`

Number of entries, found by walking boundaries without decoding. Errors on malformed
bytes, so `pcall(snack.count, p)` doubles as pack validation.

### `snack.digest(s: Snack | Pack, algorithm?) → string`

Transcodes a snack or pack into a printable string for transports that can't carry
binary — HTTP JSON bodies, headers, query strings. Three algorithms:

| Algorithm | Output | Size |
| --- | --- | --- |
| `"hex"` (default) | lowercase hexadecimal | 2 chars/byte |
| `"base64"` | RFC 4648 standard, `=`-padded | ~1.33 chars/byte |
| `"base64-urlsafe"` | RFC 4648 url-safe (`-`/`_`), unpadded | ~1.33 chars/byte |

Digesting is **pure transcoding** — no header, no framing — so the digest is exactly the
buffer's bytes in printable form, and `undigest` restores them byte-identically.

### `snack.undigest(text: string, algorithm?) → Undigested`

Reverses `digest`: pass the same algorithm that produced the text (default `"hex"`).
Because the round trip is byte-exact, whatever went in comes back out — a digested snack
is still a snack, a digested pack is still a pack — and the returned `Undigested` type is
both a `Snack<any>` *and* a `Pack`, so `bite` and the pack functions all accept it
directly:

```lua
local greeting = snack.bite(snack.undigest(text))          -- if you digested a snack
local entries = snack.count(snack.undigest(text, "base64")) -- if you digested a pack
```

Malformed text errors with a positioned message (`invalid character at position N`, `odd
hex length`, `misplaced padding`, `truncated base64`, `non-zero trailing bits`); decoding
is strict so anything that decodes re-digests canonically. The *decoded bytes* are not
validated — pair with `snack.is` or `pcall(snack.count, ...)` when the text comes from an
untrusted peer.

### Exported types

| Type | Meaning |
| --- | --- |
| `snack.Snack<T>` | A packed value that unpacks to `T` |
| `snack.Any` | `Snack<any>` |
| `snack.Nil` | `Snack<nil>` |
| `snack.Boolean` | `Snack<boolean>` |
| `snack.Number` | `Snack<number>` |
| `snack.String` | `Snack<string>` |
| `snack.Table<T = any>` | `Snack<T>` — optionally precise: `snack.Table<{ number }>` |
| `snack.Vector` | `Snack<vector>` |
| `snack.Buffer` | `Snack<buffer>` |
| `snack.Pack` | Zero or more snacks in one buffer — deliberately not assignable to/from `Snack<T>`, so a multi-entry pack can't be passed to `bite` by accident |
| `snack.DigestAlgorithm` | `"hex" \| "base64" \| "base64-urlsafe"` |
| `snack.Undigested` | What `undigest` returns: `Snack<any> & Pack`, usable as either |

> **Why `snack.String` and not `snack.string`?** Luau reserves the primitive type names:
> `export type string = ...` fails to compile with `TypeError: Redefinition of type
> 'string'`, and `nil` is a keyword that cannot appear as a type name at all. Capitalized
> aliases are the closest legal spelling.

> **Phantom types.** At runtime every snack is a plain `buffer` — `typeof(a)` is
> `"buffer"`. The `Snack<T>` table type never exists at runtime; it exists only so the
> type checker can carry `T` from `snack(...)` to `bite(...)`. Don't index a snack; use
> `snack.raw` when you need the honest runtime type.

---

## What it costs on the wire

Every value is one tag byte plus a payload. Integers and lengths use unsigned LEB128
varints (7 bits per byte), and numbers automatically take the smallest lossless form.
Measured sizes:

| Value | Bytes |
| --- | --- |
| `nil` | 1 |
| `true` / `false` | 1 |
| integers 0–127 (and −1…−127) | 2 |
| integers to ±16383 | 3 |
| integers to ±2^53 | 4–9 |
| `0.5` (fits f32 exactly) | 5 |
| `1/3` (needs full f64) | 9 |
| `""` | 2 |
| `"hello"` | 7 (1 tag + 1 length + 5 bytes) |
| string of *n* bytes | 1 + varint(*n*) + *n* |
| `vector.create(1, 2, 3)` | 13 (three f32s) |
| buffer of *n* bytes | 1 + varint(*n*) + *n* |
| `{}` | 3 |
| `{ 1, 2, 3 }` | 9 |
| `{ coins = 250 }` | 13 |

### Format specification

| Tag | Name | Payload |
| --- | --- | --- |
| 0 | NIL | — |
| 1 | FALSE | — |
| 2 | TRUE | — |
| 3 | PINT | varint of the integer |
| 4 | NINT | varint of the negated integer |
| 5 | F32 | 4-byte IEEE 754 float |
| 6 | F64 | 8-byte IEEE 754 float |
| 7 | STRING | varint byte length, then the bytes |
| 8 | VECTOR | x, y, z as three f32s |
| 9 | BUFFER | varint byte length, then the bytes |
| 10 | TABLE | varint array count + that many values, then varint pair count + that many key/value pairs |
| 11–255 | — | reserved; `bite` rejects them |

Number packing picks the first lossless form: integers with magnitude ≤ 2^53 become
PINT/NINT varints; anything else becomes F32 when the f32 round trip is bit-exact and F64
otherwise. `-0` is kept on the float path so its sign survives, `NaN` stays `NaN`, and the
infinities fit in an F32. Every number `bite`s back `==`-equal to what went in.

Tables encode their array part (`1..rawlen(t)`, holes included as NIL) followed by all
remaining key/value pairs. Keys may be any supported type. Vectors store the three f32
components natively backing them (Roblox `Vector3` *is* the native f32 vector type), so
vector round trips are lossless too.

A *pack* is simply zero or more encoded values laid end to end — the self-delimiting
format needs no count header or separators, so packing adds no bytes at all and merging
two packs is plain concatenation.

The format is stable within a major version: bytes packed by any `0.x` release will be
bitten correctly by any later `0.x` release.

---

## Guarantees and caveats

- **Lossless round trips** for every supported value: all numbers (including `-0`, `NaN`,
  ±infinity, and integers to ±2^53), 8-bit-clean strings, vectors, buffer contents, and
  arbitrarily nested tables.
- **Tables are read raw.** Encoding uses `rawlen`/`rawget`/`pairs`, so metamethods are
  never consulted, and metatables are **not** stored or restored — a snack captures a
  table's own contents only. Decoded tables are always plain tables.
- **Cycles are rejected** with a clear error. Shared (non-cyclic) references are legal but
  are duplicated in the output, so `bite` returns independent copies.
- **Dictionary byte layout follows `pairs` order**, which Luau does not specify. Decoding
  is always correct, but don't treat the encoded bytes of hash-part tables as a canonical
  fingerprint across VM versions.
- **Deep nesting** is recursive; the suite exercises 100 levels. Pathologically deep
  structures (thousands of levels) can hit the VM's stack limit, which surfaces as a
  catchable error.
- **Unsupported types** (`function`, `thread`, and userdata such as `Instance`, `CFrame`,
  `Color3`) raise immediately, even when nested inside tables. Decompose rich userdata
  into tables of numbers before packing.
- **Untrusted bytes are safe to bite**: every read is bounds-checked and forged length
  fields are caught before they can drive allocations or loops, so malformed input always
  raises `malformed snack` — guard with `pcall` or `snack.is`.

---

## Recipes

### DataStores

DataStores accept buffers directly, and store them more compactly than JSON-encoded
tables:

```lua
local store = DataStoreService:GetDataStore("PlayerSaves")

-- Save
store:SetAsync(tostring(player.UserId), snack.raw(snack(playerData)))

-- Load
local stored = store:GetAsync(tostring(player.UserId))
if snack.is(stored) then
	local playerData = snack.bite(snack.wrap(stored) :: snack.Table)
end
```

### Remotes

Buffers replicate efficiently through remotes, which matters most for unreliable remotes
and their ~900-byte payload budget:

```lua
-- Sender
remote:FireServer(snack.raw(snack({ action = "jump", direction = vector.create(0, 1, 0) })))

-- Receiver: remote payloads are attacker-controlled, so validate before trusting
remote.OnServerEvent:Connect(function(player, payload)
	if typeof(payload) == "buffer" and snack.is(payload) then
		local message = snack.bite(snack.wrap(payload) :: snack.Table)
	end
end)
```

### Batching messages with packs

Accumulate small messages during a frame and flush them as one payload — one remote
call, one buffer, no per-message overhead:

```lua
-- Sender: queue snacks cheaply, combine on flush
local queue = {}

local function send(message)
	table.insert(queue, snack(message))
end

RunService.Heartbeat:Connect(function()
	if #queue > 0 then
		remote:FireServer(snack.raw(snack.pack(table.unpack(queue)) :: any))
		table.clear(queue)
	end
end)

-- Receiver: validate, then take the pack apart
remote.OnServerEvent:Connect(function(player, payload)
	if typeof(payload) ~= "buffer" then
		return
	end
	local bundle = payload :: any
	if not pcall(snack.count, bundle) then
		return -- malformed or forged
	end
	local messages, n = snack.unpack(bundle)
	for index = 1, n do
		handleMessage(player, messages[index])
	end
end)
```

### Shipping snacks over HTTP

`HttpService` bodies and headers are strings, so digest at the boundary — hex or base64
in a JSON body, url-safe in a query string:

```lua
-- Send: a pack of events as base64 inside a JSON body
HttpService:PostAsync(
	endpoint,
	HttpService:JSONEncode({
		events = snack.digest(eventPack, "base64"),
	})
)

-- Or in a query string, where "=" and "/" would need escaping:
local url = `{endpoint}?state={snack.digest(save, "base64-urlsafe")}`

-- Receive (e.g. a webhook response): undigest, validate, then use
local body = HttpService:JSONDecode(response)
local restored = snack.undigest(body.events, "base64")
if pcall(snack.count, restored) then
	local values, n = snack.unpack(restored)
end
```

### Keeping many values packed in memory

A snack is just bytes, so long-lived state you rarely touch (undo history, chunk data,
replay frames) can sit packed and be bitten on demand:

```lua
local frames: { snack.Table } = {}
table.insert(frames, snack(captureFrame()))  -- packed at rest
local oldest = snack.bite(frames[1])         -- unpacked only when needed
```

---

## Development

Tooling is pinned with [Rokit](https://github.com/rojo-rbx/rokit):

```sh
rokit install
```

| Task | Command |
| --- | --- |
| Build the single-file module into `build/init.luau` | `lute tools/build.luau` |
| Run the test suite (736 tests, incl. 640 seeded fuzz round trips) | `lute tests/run.luau` |
| Same suite on the reference CLI | `luau tests/run.luau` |
| Coverage run + 100% line-coverage gate | `luau --coverage tests/run.luau && lute tests/coverage.luau` |
| Typecheck, current solver | `luau-lsp analyze --platform standard src build/init.luau tests` |
| Typecheck, new solver | `lute check src/init.luau build/init.luau tests/run.luau tools/build.luau` |
| Format | `stylua src tests tools` |

### Source layout and the build step

The published module is one dependency-free file, but it is *developed* as focused
modules and bundled by a build step:

| Path | Role |
| --- | --- |
| [src/Tags.luau](src/Tags.luau) | Wire-format constants shared by both sides |
| [src/Writer.luau](src/Writer.luau) | Growable byte writer over `buffer` |
| [src/Encoder.luau](src/Encoder.luau) | Value → bytes |
| [src/Decoder.luau](src/Decoder.luau) | Bytes → value, plus the structural skip walker packs use |
| [src/Digest.luau](src/Digest.luau) | Hex/base64 transcoding for text transports |
| [src/init.luau](src/init.luau) | Public API and all exported types |
| [tools/build.luau](tools/build.luau) | Bundles the above into `build/init.luau` |

`lute tools/build.luau` wraps each internal module in an IIFE local (in dependency
order), strips the sibling requires, and appends the entry module so its `export type`
statements stay top-level. `build/` is generated — never edit it, and never commit it;
tests, coverage, and publishing all run against it so what's verified is exactly what
ships. Everything is compiled `--!strict` and the bundle is marked `--!native` so
buffer-heavy encoding benefits from native codegen in Roblox.

CI ([ci.yml](.github/workflows/ci.yml)) builds and then runs the suite on Linux, Windows,
and macOS for every push and pull request, and fails if line coverage of
`build/init.luau` drops below 100%. Publishing a GitHub release tagged `vX.Y.Z` (matching
the `wally.toml` version) re-verifies everything, rebuilds, and publishes to Wally via
[release.yml](.github/workflows/release.yml) — set a `WALLY_AUTH_TOKEN_SNACKS` repository secret
for it.

## License

[GPL-3.0](LICENSE) © DreamWire Studio
