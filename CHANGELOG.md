# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - 2026-07-18

### Changed

- The source is now split into focused modules (`src/Tags`, `src/Writer`,
  `src/Encoder`, `src/Decoder`, `src/init`) bundled into the published
  single-file module at `build/init.luau` by `tools/build.luau`. Consumers
  still receive one dependency-free ModuleScript; tests and coverage run
  against the built artifact.

## [0.2.0] - 2026-07-18

### Added

- **Packs**: combine many snacks into one buffer with zero framing overhead.
  - `snack.pack(...)` concatenates snacks and/or packs — one function covers
    building, appending, and merging; `snack.pack()` is the empty pack.
  - `snack.unpack(p)` decodes every entry, returning the values plus an entry
    count (entries can be `nil`, so the count is authoritative).
  - `snack.nibble(p, index)` decodes a single entry, structurally skipping the
    others without materializing them.
  - `snack.count(p)` counts entries without decoding; `pcall(snack.count, p)`
    doubles as pack validation.
  - Exported `snack.Pack` phantom type, deliberately not interchangeable with
    `Snack<T>` so multi-entry packs cannot be passed to `bite` by accident.

### Changed

- Malformed-input errors are now prefixed `snack:` instead of `snack.bite:`,
  since the decoder is shared by `bite`, `unpack`, `nibble`, and `count`.

## [0.1.0] - 2026-07-17

### Added

- `snack(value)` packs `nil`, `boolean`, `number`, `string`, `vector`, `buffer`,
  and `table` values into a compact binary `buffer`.
- `snack.bite(s)` unpacks a snack back into the original value.
- `snack.size(s)`, `snack.raw(s)`, `snack.wrap(bytes)`, and `snack.is(value)`
  helpers for storage and transport workflows.
- Exported phantom types: `Snack<T>`, `Any`, `Nil`, `Boolean`, `Number`,
  `String`, `Table<T>`, `Vector`, and `Buffer`.
- Size-adaptive number encoding (varint integers, f32 when bit-exact, f64
  otherwise) with `-0`, `NaN`, and infinity preserved.
- Hardened decoder: truncated, forged, or corrupt input fails with a
  descriptive `malformed snack` error instead of a raw buffer access error.
