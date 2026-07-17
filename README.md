# 🍪 snack

[![CI](https://github.com/dreamwire-studio/snacks/actions/workflows/ci.yml/badge.svg)](https://github.com/dreamwire-studio/snacks/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Pack any Luau value into the smallest practical pile of bytes — then `bite` it back out.

`snack` converts `nil`, `boolean`, `number`, `string`, `vector`, `buffer`, and `table`
values into compact binary [`buffer`](https://luau.org/library#buffer-library)s. Buffers are
the densest way to hold data at rest in the Roblox engine: a packed snack is raw bytes with
no per-field table overhead, goes straight into DataStores (which accept buffers directly),
and squeezes far more state under the ~900-byte unreliable remote budget.

```lua
local snack = require(ReplicatedStorage.Packages.snack)
local bite = snack.bite

local a: snack.String = snack("string")
local b: snack.Number = snack(0)
local c: snack.Boolean = snack(false)

print(bite(a)) --> "string"
print(bite(b)) --> 0
print(bite(c)) --> false
```

A `Snack<T>` remembers what went in, so `bite` hands the original type straight back to the
type checker — no casts at the call site.

---

## Installation

Add snack to your `wally.toml` and install:

```toml
[dependencies]
snack = "dreamwire-studio/snack@0.1.0"
```

```sh
wally install
```

Then require it through your Rojo project as usual:

```lua
local snack = require(ReplicatedStorage.Packages.snack)
```

No dependencies, one ModuleScript, works on the server, the client, and in plain Luau
runtimes (tested against both [Lute](https://github.com/luau-lang/lute) and the
[`luau` CLI](https://github.com/luau-lang/luau)).

---

## Quick tour

```lua
local snack = require(ReplicatedStorage.Packages.snack)
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
descriptive `snack.bite: malformed snack (...)` error rather than a raw buffer access
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
| Run the test suite (580 tests, incl. 512 seeded fuzz round trips) | `lute tests/run.luau` |
| Same suite on the reference CLI | `luau tests/run.luau` |
| Coverage run + 100% line-coverage gate | `luau --coverage tests/run.luau && lute tests/coverage.luau` |
| Typecheck, current solver | `luau-lsp analyze --platform standard src/init.luau tests/run.luau tests/typecheck.luau` |
| Typecheck, new solver | `lute check src/init.luau tests/run.luau tests/typecheck.luau` |
| Format | `stylua src tests` |

CI ([ci.yml](.github/workflows/ci.yml)) runs the suite on Linux, Windows, and macOS for
every push and pull request, and fails if line coverage of `src/init.luau` drops below
100%. Publishing a GitHub release tagged `vX.Y.Z` (matching the `wally.toml` version)
re-verifies everything and publishes to Wally via
[release.yml](.github/workflows/release.yml) — set a `WALLY_AUTH_TOKEN` repository secret
for it.

The module is a single file ([src/init.luau](src/init.luau)) with no requires, compiled
`--!strict` and marked `--!native` so buffer-heavy encoding benefits from native codegen
in Roblox.

## License

[GPL-3.0](LICENSE) © Reece Harris
