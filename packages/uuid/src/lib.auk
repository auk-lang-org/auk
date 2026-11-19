/// UUIDs (RFC 9562): random v4 and time-ordered v7 generation, parsing, formatting, nil/max,
/// version and variant. Only the generators use `rand` (core's cryptographic `rand.bytes`);
/// parsing, formatting and comparison are pure. v7 takes the clock as an argument, so the
/// package needs no `time` effect: `uuid.v7(time.now())`.

/// A UUID: 16 bytes (0..255) in network order. `"{u}"` gives the canonical lower-case form,
/// `==` compares bytes, and `<`/`sort` order bytes left to right, which for v7 is creation time.
/// Build one with `parse`, `from_bytes` or a generator so it always has exactly 16 bytes.
pub struct Uuid { bytes: [int] }

/// The variant field (the top bits of byte 8). Everything this package generates is `Rfc`.
pub enum Variant {
  Ncs,        // 0xxx: reserved, NCS backward compatibility (includes the nil UUID)
  Rfc,        // 10xx: RFC 9562 / RFC 4122
  Microsoft,  // 110x: reserved, Microsoft GUIDs
  Future,     // 111x: reserved for future definition (includes the max UUID)
}

/// Why parsing failed. `at` is a 0-based char index into the input.
pub enum UuidErr {
  BadLength(len: int),        // not 32, 36, 38 (`{...}`) or 45 (`urn:uuid:...`) chars
  BadChar(at: int, c: char),  // a non-hex char, or a misplaced or missing '-'
}

/// A one-line description of an error, e.g. `bad char 'x' at 3`.
pub fn message(e: UuidErr): str
fn message(BadLength(n)): str = "bad length {n} (want 36 chars like 8-4-4-4-12 hex digits)"
fn message(BadChar(at, c)): str = "bad char '{c}' at {at}"

fn is_bytes(bs: [int]): bool = bs.all(b => b >= 0 && b <= 255)

// ---- constructors ----

/// The nil UUID `00000000-0000-0000-0000-000000000000`.
pub fn nil(): Uuid = Uuid { bytes: fill(0) }

/// The max UUID `ffffffff-ffff-ffff-ffff-ffffffffffff` (RFC 9562 §5.10).
pub fn max(): Uuid = Uuid { bytes: fill(255) }

fn fill(b: int): [int] {
  var out: [int] = []
  for _ in 0..16 { out.push(b) }
  out
}

/// A UUID from exactly 16 bytes, unchanged (no version or variant bits are set).
pub fn from_bytes(bs: [int]): Uuid!UuidErr
  requires is_bytes(bs)
{
  if bs.len() != 16 { fail(BadLength(bs.len())) }
  Uuid { bytes: bs }
}

/// A random (version 4) UUID: 122 bits from the OS's cryptographic generator.
pub fn v4(): Uuid uses rand = v4_from(rand.bytes(16))

/// A version 4 UUID from 16 bytes you supply (for reproducible tests): the version and variant
/// bits are overwritten, the other 122 bits are kept.
pub fn v4_from(random: [int]): Uuid
  requires random.len() == 16 && is_bytes(random)
{
  var bs = random
  bs[6] = 0x40 | (bs[6] & 0x0f)
  bs[8] = 0x80 | (bs[8] & 0x3f)
  Uuid { bytes: bs }
}

/// The largest Unix millisecond timestamp a v7 UUID can hold (48 bits, until the year 10889).
pub let MAX_MS = (1 << 48) - 1

/// A time-ordered (version 7) UUID for the Unix time `ms` (milliseconds, e.g. `time.now()`),
/// with 74 random bits. UUIDs from different milliseconds sort by time; within one millisecond
/// their order is random (use `v7_after` when you need strictly increasing IDs).
pub fn v7(ms: int): Uuid uses rand
  requires ms >= 0 && ms <= MAX_MS
{
  v7_from(ms, rand.bytes(10))
}

/// A version 7 UUID from a timestamp and 10 bytes you supply (for reproducible tests). Layout
/// (RFC 9562 §5.7): 48-bit big-endian `unix_ts_ms`, 4-bit version 7, 12-bit `rand_a`, 2-bit
/// variant, 62-bit `rand_b`; the random bits come from `random` with the version and variant
/// bits overwritten.
pub fn v7_from(ms: int, random: [int]): Uuid
  requires ms >= 0 && ms <= MAX_MS
  requires random.len() == 10 && is_bytes(random)
{
  Uuid {
    bytes: [
      (ms >> 40) & 0xff,
      (ms >> 32) & 0xff,
      (ms >> 24) & 0xff,
      (ms >> 16) & 0xff,
      (ms >> 8) & 0xff,
      ms & 0xff,
      0x70 | (random[0] & 0x0f),
      random[1],
      0x80 | (random[2] & 0x3f),
      random[3],
      random[4],
      random[5],
      random[6],
      random[7],
      random[8],
      random[9],
    ],
  }
}

let RAND_B_SPAN = 1 << 62

/// A version 7 UUID that sorts strictly after `prev`, for IDs generated faster than once per
/// millisecond or across a clock that stepped back. When `ms` is later than `prev`'s timestamp
/// this is just `v7(ms)`; otherwise it keeps `prev`'s timestamp and adds a random amount
/// (1..2^32) to its 74 random bits (RFC 9562 §6.2, method 2), moving to the next millisecond if
/// they run out. If `prev` isn't a v7 UUID (e.g. `nil()`), this is `v7(ms)`. At `MAX_MS` there
/// is no next millisecond: when the random bits run out there it returns the greatest v7 UUID
/// (`ffffffff-ffff-7fff-bfff-ffffffffffff`), which may equal `prev`, so only then is the result
/// not strictly after `prev`.
pub fn v7_after(prev: Uuid, ms: int): Uuid uses rand
  requires ms >= 0 && ms <= MAX_MS
{
  let t = timestamp(prev) else return v7(ms)
  if ms > t { return v7(ms) }
  let step = rand.bytes(4).reduce(0, (acc, b) => (acc << 8) | b) + 1
  let p = prev.bytes
  var a = (p[6] & 0x0f) << 8 | p[7]
  var b = p[8] & 0x3f
  for i in 9..16 { b = (b << 8) | p[i] }
  b += step
  if b >= RAND_B_SPAN {
    b -= RAND_B_SPAN
    a += 1
  }
  if a > 0xfff {
    // all 74 bits used up: borrow the next millisecond, or saturate at the last one
    if t == MAX_MS { return v7_from(MAX_MS, fill(255).take(10)) }
    return v7_from(t + 1, rand.bytes(10))
  }
  Uuid {
    bytes: [
      p[0],
      p[1],
      p[2],
      p[3],
      p[4],
      p[5],
      0x70 | (a >> 8),
      a & 0xff,
      0x80 | (b >> 56),
      (b >> 48) & 0xff,
      (b >> 40) & 0xff,
      (b >> 32) & 0xff,
      (b >> 24) & 0xff,
      (b >> 16) & 0xff,
      (b >> 8) & 0xff,
      b & 0xff,
    ],
  }
}

// ---- fields ----

/// The version number (the high nibble of byte 6): 4 for `v4`, 7 for `v7`. Only meaningful
/// when `variant(u) == Rfc`.
pub fn version(u: Uuid): int = u.bytes[6] >> 4

/// The variant, from the top bits of byte 8.
pub fn variant(u: Uuid): Variant {
  let b = u.bytes[8]
  if b < 0x80 {
    Ncs
  } else if b < 0xc0 {
    Rfc
  } else if b < 0xe0 {
    Microsoft
  } else {
    Future
  }
}

/// The Unix millisecond timestamp of a v7 UUID, or `none` for any other kind.
pub fn timestamp(u: Uuid): int? {
  if version(u) != 7 || variant(u) != Rfc { return none }
  let b = u.bytes
  b[0] << 40 | (b[1] << 32) | (b[2] << 24) | (b[3] << 16) | (b[4] << 8) | b[5]
}

pub fn is_nil(u: Uuid): bool = u.bytes.all(b => b == 0)
pub fn is_max(u: Uuid): bool = u.bytes.all(b => b == 255)

/// Byte-wise order (negative, 0 or positive), so `<` and `sort` work. v7 UUIDs order by time.
pub fn cmp(a: Uuid, b: Uuid): int {
  for i in 0..16 {
    if a.bytes[i] != b.bytes[i] { return a.bytes[i] - b.bytes[i] }
  }
  0
}

// ---- text ----

let HEX = "0123456789abcdef".chars()

fn hex(bs: [int]): str {
  var out: [char] = []
  for b in bs {
    out.push(HEX[b >> 4])
    out.push(HEX[b & 15])
  }
  str(out)
}

// The canonical form's hyphens, with a '0' for each hex digit to fill in, and where the two
// digits of each byte go.
let BLANK = "00000000-0000-0000-0000-000000000000".chars()
let PLACE = [0, 2, 4, 6, 9, 11, 14, 16, 19, 21, 24, 26, 28, 30, 32, 34]
let BLANK_SIMPLE = "00000000000000000000000000000000".chars()

/// The canonical form: lower-case hex in 8-4-4-4-12 groups,
/// `"919108f7-52d1-4320-9bac-f847db4148a8"`. `"{u}"` gives the same.
pub fn show(u: Uuid): str {
  let b = u.bytes
  if b.len() != 16 {
    // not a UUID this package built: the general way
    return "{hex(b.take(4))}-{hex(b[4..6])}-{hex(b[6..8])}-{hex(b[8..10])}-{hex(b.skip(10))}"
  }
  var out = BLANK
  for i in 0..16 {
    let x = b[i]
    let at = PLACE[i]
    out[at] = HEX[x >> 4]
    out[at + 1] = HEX[x & 15]
  }
  str(out)
}

/// 32 hex digits without hyphens: `"919108f752d143209bacf847db4148a8"`.
pub fn simple(u: Uuid): str {
  let b = u.bytes
  if b.len() != 16 { return hex(b) }
  var out = BLANK_SIMPLE
  for i in 0..16 {
    let x = b[i]
    out[2 * i] = HEX[x >> 4]
    out[2 * i + 1] = HEX[x & 15]
  }
  str(out)
}

/// The URN form: `"urn:uuid:919108f7-52d1-4320-9bac-f847db4148a8"`.
pub fn urn(u: Uuid): str = "urn:uuid:{show(u)}"

let URN_PREFIX = "urn:uuid:".chars()
let NO_BYTES = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

/// Parses a UUID in any common spelling, upper or lower case: canonical 8-4-4-4-12
/// (`919108f7-52d1-4320-9bac-f847db4148a8`), braced (`{919108F7-...}`), URN
/// (`urn:uuid:919108f7-...`) or 32 bare hex digits. Nothing else (no whitespace, no other
/// grouping) is accepted.
pub fn parse(s: str): Uuid!UuidErr {
  let cs = s.chars()
  let n = cs.len()
  if n == 32 { return hex_digits(cs, 0, false) }
  if n == 36 { return hex_digits(cs, 0, true) }
  if n == 38 {
    if cs[0] != '{' { fail(BadChar(0, cs[0])) }
    if cs[37] != '}' { fail(BadChar(37, cs[37])) }
    return hex_digits(cs, 1, true)
  }
  if n == 45 {
    for i in 0..9 {
      if cs[i].lower() != URN_PREFIX[i] { fail(BadChar(i, cs[i])) }
    }
    return hex_digits(cs, 9, true)
  }
  fail(BadLength(n))
}

// 32 hex digits starting at `from`, with hyphens after digits 8, 12, 16 and 20 if `dashed`.
fn hex_digits(cs: [char], from: int, dashed: bool): Uuid!UuidErr {
  var i = from
  var bs = NO_BYTES
  for k in 0..16 {
    if dashed && (k == 4 || k == 6 || k == 8 || k == 10) {
      if cs[i] != '-' { fail(BadChar(i, cs[i])) }
      i += 1
    }
    let hi = nibble(cs[i])
    if hi < 0 { fail(BadChar(i, cs[i])) }
    let lo = nibble(cs[i + 1])
    if lo < 0 { fail(BadChar(i + 1, cs[i + 1])) }
    bs[k] = (hi << 4) | lo
    i += 2
  }
  Uuid { bytes: bs }
}

// The value of a hex digit (either case), or -1.
fn nibble(c: char): int {
  if c >= '0' && c <= '9' { return int(c) - int('0') }
  if c >= 'a' && c <= 'f' { return int(c) - int('a') + 10 }
  if c >= 'A' && c <= 'F' { return int(c) - int('A') + 10 }
  -1
}

// ---- tests ----

test "parse and format: fixed vectors" {
  let u = parse("919108f7-52d1-4320-9bac-f847db4148a8")?
  assert u.bytes ==
    [0x91, 0x91, 0x08, 0xf7, 0x52, 0xd1, 0x43, 0x20, 0x9b, 0xac, 0xf8, 0x47, 0xdb, 0x41, 0x48, 0xa8]
  assert "{u}" == "919108f7-52d1-4320-9bac-f847db4148a8"
  assert u.simple() == "919108f752d143209bacf847db4148a8"
  assert u.urn() == "urn:uuid:919108f7-52d1-4320-9bac-f847db4148a8"
  // every accepted spelling gives the same UUID
  for s in [
    "919108F7-52D1-4320-9BAC-F847DB4148A8",
    "{{919108f7-52d1-4320-9bac-f847db4148a8}}",
    "{{919108F7-52d1-4320-9BAC-f847db4148a8}}",
    "urn:uuid:919108f7-52d1-4320-9bac-f847db4148a8",
    "URN:UUID:919108F7-52D1-4320-9BAC-F847DB4148A8",
    "919108f752d143209bacf847db4148a8",
  ] {
    assert parse(s)? == u
  }
  // RFC 9562 Appendix A examples round-trip
  for s in [
    "c232ab00-9414-11ec-b3c8-9f6bdeced846",  // v1
    "5df41881-3aed-3515-88a7-2f4a814cf09e",  // v3
    "919108f7-52d1-4320-9bac-f847db4148a8",  // v4
    "2ed6657d-e927-568b-95e1-2665a8aea6a2",  // v5
    "1ec9414c-232a-6b00-b3c8-9f6bdeced846",  // v6
    "017f22e2-79b0-7cc3-98c4-dc0c0c07398f",  // v7
    "00000000-0000-0000-0000-000000000000",
    "ffffffff-ffff-ffff-ffff-ffffffffffff",
  ] {
    assert (parse(s)?).show() == s
  }
}

test "parse errors" {
  assert parse("") is err(BadLength(0))
  assert parse("919108f7-52d1-4320-9bac-f847db4148a") is err(BadLength(35))
  assert parse(" 919108f7-52d1-4320-9bac-f847db4148a8") is err(BadLength(37))
  assert parse("919108f7x52d1-4320-9bac-f847db4148a8") is err(BadChar(8, 'x'))
  assert parse("919108f7-52d1-4320-9bac-f847db4148ag") is err(BadChar(35, 'g'))
  assert parse("9191-08f752d1-4320-9bac-f847db4148a8") is err(BadChar(4, '-'))
  assert parse("(919108f7-52d1-4320-9bac-f847db4148a8)") is err(BadChar(0, '('))
  assert parse("{{919108f7-52d1-4320-9bac-f847db4148a8]") is err(BadChar(37, ']'))
  assert parse("urn:uid::919108f7-52d1-4320-9bac-f847db4148a8") is err(BadChar(5, 'i'))
  assert parse("919108f752d143209bacf847db4148a-") is err(BadChar(31, '-'))
  assert parse("919108f7-52d1-4320-9bac-f847db4148é8") is err(BadChar(34, 'é'))
  assert message(BadChar(3, 'x')) == "bad char 'x' at 3"
  assert message(BadLength(2)).starts_with("bad length 2")
}

test "nil, max, from_bytes" {
  assert "{nil()}" == "00000000-0000-0000-0000-000000000000"
  assert "{max()}" == "ffffffff-ffff-ffff-ffff-ffffffffffff"
  assert nil().is_nil() && !max().is_nil() && max().is_max()
  assert nil().variant() == Ncs && max().variant() == Future
  assert nil() < max()
  let bs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
  assert "{from_bytes(bs)?}" == "01020304-0506-0708-090a-0b0c0d0e0f10"
  assert from_bytes([1, 2]) is err(BadLength(2))
}

test "v4: version and variant bits" {
  // RFC 9562 A.3: these bytes already carry the v4 bits, so they are kept as they are
  let want = parse("919108f7-52d1-4320-9bac-f847db4148a8")?
  assert v4_from(want.bytes) == want
  // all-ones and all-zeros inputs: only the version nibble and variant bits change
  assert "{v4_from(fill(255))}" == "ffffffff-ffff-4fff-bfff-ffffffffffff"
  assert "{v4_from(fill(0))}" == "00000000-0000-4000-8000-000000000000"
  for _ in 0..200 {
    let u = v4()
    assert u.version() == 4 && u.variant() == Rfc
    assert "{u}".chars()[14] == '4'
    assert "89ab".contains("{u}".chars()[19])
    assert parse("{u}")? == u
    assert u.timestamp() == none
  }
  assert v4() != v4()
}

test "v7: RFC 9562 layout" {
  // RFC 9562 A.6: 2022-02-22 14:22:22.000 -05:00 = 1645557742000 ms = 0x017F22E279B0,
  // rand_a = 0xCC3, rand_b = 0x18C4DC0C0C07398F
  let ms = 1645557742000
  let u = v7_from(ms, [0x0c, 0xc3, 0x18, 0xc4, 0xdc, 0x0c, 0x0c, 0x07, 0x39, 0x8f])
  assert "{u}" == "017f22e2-79b0-7cc3-98c4-dc0c0c07398f"
  assert u.version() == 7 && u.variant() == Rfc
  assert u.timestamp() == some(ms)
  assert (parse("017F22E2-79B0-7CC3-98C4-DC0C0C07398F")?).timestamp() == some(ms)
  // the version and variant bits are forced whatever the random input
  assert "{v7_from(0, fill(255).take(10))}" == "00000000-0000-7fff-bfff-ffffffffffff"
  assert "{v7_from(MAX_MS, fill(0).take(10))}" == "ffffffff-ffff-7000-8000-000000000000"
  assert v7_from(MAX_MS, fill(0).take(10)).timestamp() == some(MAX_MS)
}

test "v7: generated IDs sort by time" {
  var ids: [Uuid] = []
  for i in 0..100 {
    let u = v7(1_700_000_000_000 + i * 1000)
    assert u.version() == 7 && u.variant() == Rfc
    assert u.timestamp() == some(1_700_000_000_000 + i * 1000)
    ids.push(u)
  }
  assert ids.reverse().sort() == ids
  assert ids.map(u => "{u}").reverse().sort() == ids.map(u => "{u}")  // text sorts the same
}

test "v7_after: strictly increasing within one millisecond" {
  var prev = v7(1000)
  for _ in 0..500 {
    let next = v7_after(prev, 1000)
    assert next > prev
    assert next.timestamp() == some(1000) && next.version() == 7 && next.variant() == Rfc
    prev = next
  }
  // a clock that steps back keeps the previous timestamp
  let back = v7_after(prev, 999)
  assert back > prev && back.timestamp() == some(1000)
  // a later millisecond starts fresh
  assert v7_after(prev, 1001).timestamp() == some(1001)
  // exhausted random bits roll over to the next millisecond
  let full = v7_from(5000, fill(255).take(10))
  let after = v7_after(full, 5000)
  assert after > full && after.timestamp() == some(5001)
  // ...except at MAX_MS, which saturates at the greatest v7 UUID
  let last = v7_from(MAX_MS, fill(255).take(10))
  assert "{last}" == "ffffffff-ffff-7fff-bfff-ffffffffffff"
  assert v7_after(last, 0) == last && v7_after(last, MAX_MS) == last
  let near = v7_from(MAX_MS, [255, 255, 255, 255, 255, 255, 255, 255, 255, 0])
  assert v7_after(near, MAX_MS) > near
  // a non-v7 predecessor just starts a fresh v7
  assert v7_after(max(), 0).timestamp() == some(0)
}

test "comparison and Data" {
  let a = parse("00000000-0000-0000-0000-000000000001")?
  let b = parse("00000000-0000-0000-0000-000000000100")?
  let c = parse("10000000-0000-0000-0000-000000000000")?
  assert a < b && b < c && a.cmp(a) == 0
  assert [c, a, b].sort() == [a, b, c]
  assert [c, a, b].max() == some(c)
  let back: Uuid = from_value(to_value(a))?
  assert back == a
}
