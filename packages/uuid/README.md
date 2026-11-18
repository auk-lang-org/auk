# uuid

UUIDs as specified by RFC 9562. The package generates random (v4) and time-ordered (v7) IDs, parses every common spelling, and formats the canonical lower-case form. It also gives you the nil and max UUIDs, version and variant fields, the v7 timestamp, and ordering. Tested against the RFC 9562 Appendix A examples.

**Effects:** `rand`, and only the generators need it (`v4`, `v7`, `v7_after`). Random bits come from core's cryptographic `rand.bytes`, so `rand.seed` has no effect on them. Parsing, formatting and comparison are pure. `v7` takes the clock as an argument, so the package never needs `time`.

```auk
fn main(): int! uses rand, time {
  let id = uuid.v4()
  print("{id}")                                   // e.g. 3f1c2a9e-5b7d-4e0f-9a21-6c8d4b2e7f10
  let ev = uuid.v7(time.now())                    // sortable: newer IDs compare greater
  let u = uuid.parse("{{919108F7-52D1-4320-9BAC-F847DB4148A8}}")?
  print(u)                                        // 919108f7-52d1-4320-9bac-f847db4148a8
  print("{u.version()} {u.variant()}")            // 4 Rfc
  print(ev.timestamp())                           // some(ms)
  var last = uuid.nil()
  for _ in 0..3 { last = uuid.v7_after(last, time.now()) }   // strictly increasing
  match uuid.parse("not-a-uuid") {
    err(e) => print(uuid.message(e))              // bad length 10 (want 36 chars ...)
    ok(_) => {}
  }
  0
}
```

## API
Types:
- `struct Uuid { bytes: [int] }`: 16 bytes in network order. `==` compares bytes. `<` and `sort` order the bytes left to right, which for v7 means creation time (the canonical text sorts the same way). Build values with `parse`, `from_bytes` or a generator.
- `enum Variant { Ncs, Rfc, Microsoft, Future }`: the variant bits. Everything this package generates is `Rfc`.
- `enum UuidErr { BadLength(len: int), BadChar(at: int, c: char) }` (`at` is a 0-based char index), and `message(e): str`.

Generating:
- `v4(): Uuid uses rand`: 122 random bits.
- `v7(ms: int): Uuid uses rand`: a 48-bit Unix millisecond timestamp (`time.now()`) plus 74 random bits (RFC 9562 §5.7). IDs from different milliseconds sort by time. Requires `0 <= ms <= MAX_MS` (2^48 - 1, which lasts until the year 10889).
- `v7_after(prev: Uuid, ms: int): Uuid uses rand`: a v7 that sorts strictly after `prev`. If `ms` is past `prev`'s timestamp this is just `v7(ms)`. Otherwise (the same millisecond, or a clock that stepped back) it keeps `prev`'s timestamp and adds a random 1..2^32 to its 74 random bits (RFC 9562 §6.2, method 2). If those bits run out it moves to the next millisecond. If `prev` isn't a v7, it returns `v7(ms)`.
- `v4_from(random: [int])` (16 bytes) and `v7_from(ms, random: [int])` (10 bytes): the same layouts built from bytes you supply, for reproducible tests. The version and variant bits are overwritten.
- `nil()`, `max()`: `00000000-…-000000000000` and `ffffffff-…-ffffffffffff`. `from_bytes(bs): Uuid!UuidErr` (16 bytes, kept as they are).

Reading:
- `version(u): int` (4, 7, ...; only meaningful when the variant is `Rfc`), `variant(u): Variant`
- `timestamp(u): int?`: the Unix ms of a v7, `none` for any other kind
- `is_nil(u)`, `is_max(u)`, `cmp(a, b)`

Text:
- `show(u)`, i.e. `"{u}"`: `919108f7-52d1-4320-9bac-f847db4148a8`
- `simple(u)`: `919108f752d143209bacf847db4148a8`. `urn(u)`: `urn:uuid:919108f7-…`
- `parse(s): Uuid!UuidErr` accepts upper or lower case in four spellings: canonical 8-4-4-4-12, braced `{…}`, `urn:uuid:…` and 32 bare hex digits. It rejects everything else, including surrounding whitespace.

## Notes
- v1, v3, v5, v6 and v8 UUIDs parse and report their version, but this package can't generate them. v3 and v5 need MD5 or SHA-1, which `hash` 0.1 doesn't have. v1 and v6 need a MAC address or node ID. Use v7 for new time-ordered IDs, as RFC 9562 recommends.
- `v4` and `v7` are unguessable because they use the OS generator. Even so, don't use a UUID as a secret or a session token; use 32 bytes from `rand.bytes` for that.
