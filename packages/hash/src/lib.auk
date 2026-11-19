/// Hashes and checksums: SHA-256 (one-shot and streaming), HMAC-SHA-256, CRC-32, FNV-1a 64, and a
/// constant-time comparison for MACs. Pure: no effects. Bytes are `[int]` (0..255).
/// Not for passwords: use a slow, salted password hash (argon2, bcrypt) for those.

fn is_bytes(bs: [int]): bool = bs.all(b => b >= 0 && b <= 255)

// ---- SHA-256 (FIPS 180-4) ----

let K = [
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
]

let H0 =
  [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

let MASK = 0xffffffff

/// A SHA-256 computation in progress: `new_sha256()`, then `update` with any number of byte
/// chunks, then `finish`. Hashing in chunks gives the same digest as hashing everything at once.
pub struct Sha256 { h: [int], buf: [int], len: int }

/// A fresh SHA-256 state.
pub fn new_sha256(): Sha256 = Sha256 { h: H0, buf: [], len: 0 }

// 64 zeros: the message schedule's storage, and padding.
imprint ZEROS = (0..64).map(_ => 0)

/// Feed more bytes into the hash: `s.update(chunk)`.
pub fn update(s: var Sha256, data: [int])
  requires is_bytes(data)
{
  let n = data.len()
  s.len += n
  let held = s.buf.len()
  if held >= 64 {
    // not a state this package leaves behind: the general way
    let all = s.buf + data
    var w = ZEROS
    var off = 0
    while off + 64 <= all.len() {
      compress(&s.h, &w, all, off)
      off += 64
    }
    s.buf = all.skip(off)
    return
  }
  if held + n < 64 {
    if n > 0 { s.buf = if held == 0 { data } else { s.buf + data } }
    return
  }
  var w = ZEROS
  var off = 0
  if held > 0 {
    // complete the block that was waiting
    off = 64 - held
    let block = s.buf + data.take(off)
    compress(&s.h, &w, block, 0)
  }
  // whole blocks straight from `data`; what's left waits for the next call
  while off + 64 <= n {
    compress(&s.h, &w, data, off)
    off += 64
  }
  s.buf = data.skip(off)
}

/// The 32-byte digest of everything fed in. `s` itself is unchanged, so you can keep updating it.
pub fn finish(s: Sha256): [int] {
  // the padding: 0x80, zeros up to 56 mod 64, then the length in bits as 8 big-endian bytes
  let held = s.buf.len()
  let total = (held + 9 + 63) / 64 * 64
  let pad = total - held  // 9..72
  var tail = s.buf + if pad <= 64 { ZEROS.take(pad) } else { ZEROS + ZEROS.take(pad - 64) }
  tail[held] = 0x80
  let bits = s.len * 8
  for i in 0..8 { tail[total - 8 + i] = (bits >> (56 - 8 * i)) & 0xff }
  var h = s.h
  var w = ZEROS
  var off = 0
  while off < total {
    compress(&h, &w, tail, off)
    off += 64
  }
  var out = ZEROS.take(4 * h.len())
  for i, x in h {
    out[4 * i] = (x >> 24) & 0xff
    out[4 * i + 1] = (x >> 16) & 0xff
    out[4 * i + 2] = (x >> 8) & 0xff
    out[4 * i + 3] = x & 0xff
  }
  out
}

/// The SHA-256 digest (32 bytes) of `data`.
pub fn sha256(data: [int]): [int] {
  var s = new_sha256()
  s.update(data)
  s.finish()
}

/// The SHA-256 of a string's UTF-8 bytes, as 64 lower-case hex digits.
pub fn sha256_hex(s: str): str = hex(sha256(s.bytes()))
/// The SHA-256 of bytes, as 64 lower-case hex digits.
pub fn sha256_hex(data: [int]): str = hex(sha256(data))

// One 64-byte block of `data` at `off` into the state `h`; `w` is 64 ints of scratch space.
// Only the low 32 bits of the working variables mean anything (sums wrap and are masked when
// stored), and a word doubled into both halves of an int turns each rotation into a shift.
fn compress(h: var [int], w: var [int], data: [int], off: int) {
  for i in 0..16 {
    let j = off + 4 * i
    w[i] = (data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) | data[j + 3]
  }
  for i in 16..64 {
    let x = w[i - 15]
    let xx = x | (x << 32)
    let y = w[i - 2]
    let yy = y | (y << 32)
    let s0 = (xx >> 7) ^ (xx >> 18) ^ (x >> 3)
    let s1 = (yy >> 17) ^ (yy >> 19) ^ (y >> 10)
    w[i] = (w[i - 16] +% s0 +% w[i - 7] +% s1) & MASK
  }
  var a = h[0]
  var b = h[1]
  var c = h[2]
  var d = h[3]
  var e = h[4]
  var f = h[5]
  var g = h[6]
  var hh = h[7]
  for i in 0..64 {
    let ee = (e & MASK) | (e << 32)
    let s1 = (ee >> 6) ^ (ee >> 11) ^ (ee >> 25)
    let ch = g ^ (e & (f ^ g))
    let t1 = hh +% s1 +% ch +% K[i] +% w[i]
    let aa = (a & MASK) | (a << 32)
    let s0 = (aa >> 2) ^ (aa >> 13) ^ (aa >> 22)
    let maj = (a & b) | (c & (a | b))
    hh = g
    g = f
    f = e
    e = d +% t1
    d = c
    c = b
    b = a
    a = t1 +% s0 +% maj
  }
  h[0] = (h[0] +% a) & MASK
  h[1] = (h[1] +% b) & MASK
  h[2] = (h[2] +% c) & MASK
  h[3] = (h[3] +% d) & MASK
  h[4] = (h[4] +% e) & MASK
  h[5] = (h[5] +% f) & MASK
  h[6] = (h[6] +% g) & MASK
  h[7] = (h[7] +% hh) & MASK
}

// ---- HMAC (RFC 2104) ----

/// HMAC-SHA-256 of `msg` under `key` (32 bytes). Compare MACs with `equal`, not `==`.
pub fn hmac_sha256(key: [int], msg: [int]): [int]
  requires is_bytes(key)
{
  let k = if key.len() > 64 { sha256(key) } else { key }
  // the key, zero-padded to one block, XORed with the inner and outer pad bytes
  var ipad = ZEROS
  var opad = ZEROS
  for i in 0..64 {
    let b = if i < k.len() { k[i] } else { 0 }
    ipad[i] = b ^ 0x36
    opad[i] = b ^ 0x5c
  }
  var inner = new_sha256()
  inner.update(ipad)
  inner.update(msg)
  var outer = new_sha256()
  outer.update(opad)
  outer.update(inner.finish())
  outer.finish()
}

// ---- CRC-32 (IEEE 802.3, as in zip, gzip and PNG) ----

fn crc_table(): [int] {
  var t: [int] = []
  for n in 0..256 {
    var c = n
    for _ in 0..8 {
      c = if (c & 1) == 1 { 0xedb88320 ^ (c >> 1) } else { c >> 1 }
    }
    t.push(c)
  }
  t
}

// Four tables in one list, for taking four bytes per step ("slicing by 4"): entry `256 * k + n`
// is the CRC of byte `n` followed by `k` zero bytes.
fn crc_tables(): [int] {
  var t = crc_table()
  for i in 256..1024 { t.push(t[t[i - 256] & 0xff] ^ (t[i - 256] >> 8)) }
  t
}

imprint CRC_TABLE = crc_table()
imprint CRC_TABLES = crc_tables()

/// The CRC-32 checksum of `data`, in 0..2^32: `crc32("123456789".bytes()) == 0xcbf43926`.
pub fn crc32(data: [int]): int = crc32_update(0, data)

/// Continue a CRC-32: `crc32_update(crc32(a), b) == crc32(a + b)`.
pub fn crc32_update(crc: int, data: [int]): int
  requires is_bytes(data)
{
  let n = data.len()
  var c = crc ^ MASK
  var i = 0
  // four bytes per step, as long as `c` is a real CRC (32 bits)
  if c >= 0 && c <= MASK {
    while i + 4 <= n {
      let x = c ^ (data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24))
      c = CRC_TABLES[768 + (x & 0xff)] ^
        CRC_TABLES[512 + ((x >> 8) & 0xff)] ^
        CRC_TABLES[256 + ((x >> 16) & 0xff)] ^
        CRC_TABLES[x >> 24]
      i += 4
    }
  }
  while i < n {
    c = CRC_TABLE[(c ^ data[i]) & 0xff] ^ (c >> 8)
    i += 1
  }
  c ^ MASK
}

// ---- FNV-1a, 64-bit (non-cryptographic; for hash tables and cache keys) ----

let FNV_OFFSET = (0xcbf29ce4 << 32) | 0x84222325
let FNV_PRIME = 0x100000001b3

/// The 64-bit FNV-1a hash of `data`. All 64 bits are used, so the `int` may be negative.
pub fn fnv1a64(data: [int]): int {
  var h = FNV_OFFSET
  for b in data { h = (h ^ b) *% FNV_PRIME }
  h
}

// ---- comparison ----

/// Constant-time equality for MACs and tokens: the time taken depends only on the lengths, not
/// on where the bytes differ. Different lengths are simply unequal.
pub fn equal(a: [int], b: [int]): bool {
  if a.len() != b.len() { return false }
  var diff = 0
  for i in 0..a.len() { diff = diff | (a[i] ^ b[i]) }
  diff == 0
}

let DIGITS = "0123456789abcdef".chars()
let BLANKS = "0".repeat(64).chars()

// Lower-case hex of bytes (`encoding.hex` does the same; kept here so `hash` has no deps).
fn hex(bs: [int]): str {
  let n = bs.len()
  var out = BLANKS
  while out.len() < 2 * n { out = out + out }
  for i in 0..n {
    let b = bs[i]
    out[2 * i] = DIGITS[(b >> 4) & 15]
    out[2 * i + 1] = DIGITS[b & 15]
  }
  if out.len() == 2 * n { str(out) } else { str(out[0..2 * n]) }
}

// ---- tests ----

fn rep(b: int, n: int): [int] {
  var out: [int] = []
  for _ in 0..n { out.push(b) }
  out
}

// A 64-bit value from two 32-bit halves (literals above 2^63 don't fit an `int`).
fn u64(hi: int, lo: int): int = (hi << 32) | lo

test "sha256: NIST FIPS 180-4 vectors" {
  assert sha256_hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  assert sha256_hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  assert sha256_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  let long = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
  assert sha256_hex(long) == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
  assert sha256("abc".bytes()).len() == 32
  assert sha256_hex("abc".bytes()) == sha256_hex("abc")
}

test "sha256: one million 'a' (streamed)" {
  var s = new_sha256()
  let chunk = rep(0x61, 1000)
  for _ in 0..1000 { s.update(chunk) }
  assert hex(s.finish()) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
}

test "sha256: padding boundaries and UTF-8" {
  // 55, 56 and 64 bytes straddle the one-block / two-block padding boundary.
  assert sha256_hex(rep(0x61, 55)) ==
    "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"
  assert sha256_hex(rep(0x61, 56)) ==
    "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
  assert sha256_hex(rep(0x61, 64)) ==
    "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
  assert sha256_hex("é") == sha256_hex([0xc3, 0xa9])
}

test "sha256: chunking never changes the digest" {
  var data: [int] = []
  for i in 0..300 { data.push((i * 7) % 256) }
  let want = sha256(data)
  for size in [1, 3, 63, 64, 65, 128, 299] {
    var s = new_sha256()
    for c in data.chunks(size) { s.update(c) }
    assert s.finish() == want
  }
  var s = new_sha256()
  s.update([])
  assert s.finish() == sha256([])
  // finish doesn't consume the state
  var t = new_sha256()
  t.update("ab".bytes())
  assert t.finish() == sha256("ab".bytes())
  t.update("c".bytes())
  assert t.finish() == sha256("abc".bytes())
}

test "hmac-sha256: RFC 4231 test cases" {
  assert hex(hmac_sha256(rep(0x0b, 20), "Hi There".bytes())) ==
    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
  assert hex(hmac_sha256("Jefe".bytes(), "what do ya want for nothing?".bytes())) ==
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
  assert hex(hmac_sha256(rep(0xaa, 20), rep(0xdd, 50))) ==
    "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
  var key4: [int] = []
  for i in 1..=25 { key4.push(i) }
  assert hex(hmac_sha256(key4, rep(0xcd, 50))) ==
    "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"
  // test case 5: output truncated to 128 bits
  assert hex(hmac_sha256(rep(0x0c, 20), "Test With Truncation".bytes()).take(16)) ==
    "a3b6167473100ee06e0c796c2955552b"
  assert hex(
    hmac_sha256(rep(0xaa, 131), "Test Using Larger Than Block-Size Key - Hash Key First".bytes()),
  ) ==
    "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
  let msg7 = "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."
  assert hex(hmac_sha256(rep(0xaa, 131), msg7.bytes())) ==
    "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"
}

test "crc32" {
  assert crc32([]) == 0
  assert crc32("123456789".bytes()) == 0xcbf43926
  assert crc32("The quick brown fox jumps over the lazy dog".bytes()) == 0x414fa339
  assert crc32("a".bytes()) == 0xe8b7be43
  let a = "hello, ".bytes()
  let b = "world".bytes()
  assert crc32_update(crc32(a), b) == crc32(a + b)
  assert crc32(rep(255, 1000)) >= 0
}

test "fnv1a64" {
  assert fnv1a64([]) == u64(0xcbf29ce4, 0x84222325)
  assert fnv1a64("a".bytes()) == u64(0xaf63dc4c, 0x8601ec8c)
  assert fnv1a64("foobar".bytes()) == u64(0x85944171, 0xf73967e8)
  assert fnv1a64("ab".bytes()) != fnv1a64("ba".bytes())
}

test "constant-time equal" {
  assert equal([], [])
  assert equal([1, 2, 3], [1, 2, 3])
  assert !equal([1, 2, 3], [1, 2, 4])
  assert !equal([1, 2, 3], [1, 2])
  assert !equal([0], [128])
  let mac = hmac_sha256("k".bytes(), "m".bytes())
  assert equal(mac, hmac_sha256("k".bytes(), "m".bytes()))
  assert !equal(mac, hmac_sha256("k".bytes(), "n".bytes()))
}
