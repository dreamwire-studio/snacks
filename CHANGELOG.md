# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
