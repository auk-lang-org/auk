/// DEFLATE (RFC 1951) and its gzip (RFC 1952) and zlib (RFC 1950) wrappers, plus the CRC-32
/// and Adler-32 checksums they use. Pure: no effects. Bytes are `[int]` (0–255), as in core
/// `fs.read_bytes` and `net`.
///
/// The decoder handles every block type (stored, fixed and dynamic Huffman). The encoder
/// writes stored and fixed-Huffman blocks with LZ77 matching: its output is valid for any
/// decoder, but it compresses less than zlib (no dynamic Huffman blocks or lazy matching).

/// Why decompression failed. Every `at` is a 0-based byte offset into the input.
pub enum ZErr {
  Truncated,                     // the input ended inside the stream
  BadHeader(at: int, why: str),  // a gzip or zlib header or trailer is wrong
  BadData(at: int, why: str),    // invalid DEFLATE data near byte `at`
  BadChecksum(what: str),        // "CRC-32", "Adler-32" or "length" didn't match
}

/// A one-line description of an error, e.g. `bad deflate data at 12: distance too far back`.
pub fn message(e: ZErr): str
fn message(Truncated): str = "compressed data is truncated"
fn message(BadHeader(at, why)): str = "bad header at {at}: {why}"
fn message(BadData(at, why)): str = "bad deflate data at {at}: {why}"
fn message(BadChecksum(what)): str = "{what} check failed: the data is corrupt"

// ---- checksums ----

let MASK = 0xffffffff

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

/// The CRC-32 (IEEE, as in gzip and zip) of `data`: `crc32("123456789".bytes()) == 0xcbf43926`.
pub fn crc32(data: [int]): int = crc32_update(0, data)

/// Continues a CRC-32: `crc32_update(crc32(a), b) == crc32(a + b)`.
pub fn crc32_update(crc: int, data: [int]): int {
  let n = data.len()
  var c = crc ^ MASK
  var i = 0
  // four bytes per step, as long as `c` is a real CRC (32 bits)
  if c >= 0 && c <= MASK {
    while i + 4 <= n {
      let x = c ^
        ((data[i] & 0xff) |
          (data[i + 1] & 0xff) << 8 |
          (data[i + 2] & 0xff) << 16 |
          (data[i + 3] & 0xff) << 24)
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

/// The Adler-32 (as in zlib) of `data`: `adler32("Wikipedia".bytes()) == 0x11e60398`.
pub fn adler32(data: [int]): int {
  var a = 1
  var b = 0
  var n = 0
  for x in data {
    a += x
    b += a
    n += 1
    // a and b stay far below 2^63 for 4096 bytes, so reduce only now and then
    if n == 4096 {
      a %= 65521
      b %= 65521
      n = 0
    }
  }
  (b % 65521) << 16 | (a % 65521)
}

// ---- DEFLATE decoding (RFC 1951), after Mark Adler's puff.c ----

// Extra bits and base values for length symbols 257..285 and distance symbols 0..29 (RFC 1951
// §3.2.5): each group of four (two for distances) adds one extra bit.
fn lext(): [int] = (0..29).map(i => if i < 8 || i == 28 { 0 } else { (i - 4) / 4 })
fn dext(): [int] = (0..30).map(i => if i < 4 { 0 } else { (i - 2) / 2 })

fn bases(start: int, ext: [int]): [int] {
  var out: [int] = []
  var base = start
  for e in ext {
    out.push(base)
    base += 1 << e
  }
  out
}

imprint LEXT = lext()
imprint DEXT = dext()
// Length symbol 284 would reach 258 with its extra bits, but 285 means exactly 258.
imprint LBASE = bases(3, lext()).take(28) + [258]
imprint DBASE = bases(1, dext())
// The order code-length code lengths are sent in.
let ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

// The input as a bit stream, read LSB first: `src[..end]`, with the next byte at `pos` and `cnt`
// not yet used bits of the byte before it in `buf`.
struct In { src: [int], end: int, pos: int, buf: int, cnt: int }

fn bits(s: var In, need: int): int!ZErr {
  var val = s.buf
  while s.cnt < need {
    if s.pos >= s.end { fail(Truncated) }
    val = val | (s.src[s.pos] << s.cnt)
    s.pos += 1
    s.cnt += 8
  }
  s.buf = val >> need
  s.cnt -= need
  val & (1 << need) - 1
}

// A canonical Huffman code: how many codes have each length 0..15, and the symbols in code
// order. `fast` maps the next FAST bits of input to `(symbol << 4) | length` for every code
// of at most FAST bits, and to 0 for longer ones.
struct Huff { count: [int], symbol: [int], fast: [int] }

let FAST = 9

imprint ZEROS = (0..1024).map(_ => 0)
imprint NO_FAST = (0..512).map(_ => 0)

fn filled(n: int, v: int): [int] {
  var xs: [int] = []
  for _ in 0..n { xs.push(v) }
  xs
}

// `n` zeros to fill in by index, which is much cheaper than `n` pushes.
fn zeros(n: int): [int] {
  var z = ZEROS
  while z.len() < n { z = z + z }
  if z.len() == n { z } else { z.take(n) }
}

// Builds the code for `lengths` (one per symbol, 0 = unused), with the `fast` table only if
// `lookup`. The int is 0 for a complete code, negative for an over-subscribed one and positive
// for an incomplete one.
fn huff(lengths: [int], lookup: bool): (Huff, int) {
  var count = ZEROS.take(16)
  for l in lengths { count[l] += 1 }
  var symbol = zeros(lengths.len())
  if count[0] == lengths.len() { return (Huff { count, symbol, fast: NO_FAST }, 0) }
  var left = 1
  for len in 1..16 {
    left = (left << 1) - count[len]
    if left < 0 { return (Huff { count, symbol, fast: NO_FAST }, left) }
  }
  var offs = ZEROS.take(16)
  for len in 1..15 { offs[len + 1] = offs[len] + count[len] }
  for sym in 0..lengths.len() {
    let l = lengths[sym]
    if l != 0 {
      symbol[offs[l]] = sym
      offs[l] += 1
    }
  }
  let fast = if lookup { fast_table(count, symbol) } else { NO_FAST }
  (Huff { count, symbol, fast }, left)
}

// Codes are stored MSB first, so a code of `len` bits is found at every index whose low `len`
// bits are the code reversed.
fn fast_table(count: [int], symbol: [int]): [int] {
  var t = NO_FAST
  var code = 0
  var k = 0
  for len in 1..=FAST {
    for _ in 0..count[len] {
      let e = (symbol[k] << 4) | len
      var j = rev(code, len)
      while j < 512 {
        t[j] = e
        j += 1 << len
      }
      code += 1
      k += 1
    }
    code = code << 1
  }
  t
}

// Reads one symbol from bits already in hand (the next one is bit 0 of `buf`), a bit at a time
// (codes are stored MSB first): `(symbol << 4) | length`, or -1 if no code matches the next
// 15 bits.
fn walk(h: Huff, buf: int): int {
  var code = 0
  var first = 0
  var index = 0
  var b = buf
  for len in 1..16 {
    code = code | (b & 1)
    b = b >> 1
    let count = h.count[len]
    if code - count < first { return (h.symbol[index + (code - first)] << 4) | len }
    index += count
    first = (first + count) << 1
    code = code << 1
  }
  -1
}

// The output is a buffer that is longer than what has been written so far (`n` ints, passed
// in and returned), so bytes go in by index; it doubles when it runs short.

fn stored(s: var In, out: var [int], n: int): int!ZErr {
  // drop the bits left in the current byte
  s.buf = 0
  s.cnt = 0
  let p = s.pos
  let src = s.src
  if p + 4 > s.end { fail(Truncated) }
  let len = src[p] | (src[p + 1] << 8)
  let nlen = src[p + 2] | (src[p + 3] << 8)
  if len != (~nlen & 0xffff) { fail(BadData(p, "stored block length check failed")) }
  if p + 4 + len > s.end { fail(Truncated) }
  while out.len() < n + len { out = out + out }
  for k in 0..len { out[n + k] = src[p + 4 + k] }
  s.pos = p + 4 + len
  n + len
}

// The Huffman-coded data of one block. Whole bytes are read ahead into `buf` (up to 56 bits),
// which is enough for one length/distance pair (at most 48 bits), and handed back at the end,
// so `s` is left as reading a bit at a time would leave it (`pos - (cnt >> 3)` is where that
// would be). A code that seems to end past the last bit read is the input running out.
fn codes(s: var In, out: var [int], n0: int, lens: Huff, dists: Huff): int!ZErr {
  let src = s.src
  let end = s.end
  let lfast = lens.fast
  let dfast = dists.fast
  var pos = s.pos
  var buf = s.buf
  var cnt = s.cnt
  var n = n0
  loop {
    while cnt <= 48 && pos < end {
      buf = buf | (src[pos] << cnt)
      pos += 1
      cnt += 8
    }
    if n + 258 > out.len() { out = out + out }
    var e = lfast[buf & 511]
    if e == 0 {
      e = walk(lens, buf)
      if e < 0 {
        if cnt < 15 { fail(Truncated) }
        fail(BadData(pos - ((cnt - 15) >> 3), "invalid Huffman code"))
      }
    }
    if (e & 15) > cnt { fail(Truncated) }
    buf = buf >> (e & 15)
    cnt -= e & 15
    let sym = e >> 4
    if sym < 256 {
      out[n] = sym
      n += 1
    } else if sym == 256 {
      break
    } else {
      let i = sym - 257
      if i >= 29 { fail(BadData(pos - (cnt >> 3), "invalid length symbol {sym}")) }
      let lx = LEXT[i]
      if lx > cnt { fail(Truncated) }
      let len = LBASE[i] + (buf & (1 << lx) - 1)
      buf = buf >> lx
      cnt -= lx
      var de = dfast[buf & 511]
      if de == 0 {
        de = walk(dists, buf)
        if de < 0 {
          if cnt < 15 { fail(Truncated) }
          fail(BadData(pos - ((cnt - 15) >> 3), "invalid Huffman code"))
        }
      }
      if (de & 15) > cnt { fail(Truncated) }
      buf = buf >> (de & 15)
      cnt -= de & 15
      let d = de >> 4
      if d >= 30 { fail(BadData(pos - (cnt >> 3), "invalid distance symbol {d}")) }
      let dx = DEXT[d]
      if dx > cnt { fail(Truncated) }
      let dist = DBASE[d] + (buf & (1 << dx) - 1)
      buf = buf >> dx
      cnt -= dx
      if dist > n { fail(BadData(pos - (cnt >> 3), "distance too far back")) }
      let start = n - dist
      for k in 0..len { out[n + k] = out[start + k] }
      n += len
    }
  }
  s.unread(pos, buf, cnt)
  n
}

// Ends reading ahead: hands back the whole bytes among the `cnt` unused bits of `buf`, where
// `pos` is the next byte to read.
fn unread(s: var In, pos: int, buf: int, cnt: int) {
  s.pos = pos - (cnt >> 3)
  s.cnt = cnt & 7
  s.buf = buf & (1 << (cnt & 7)) - 1
}

fn fixed_lengths(): [int] {
  var ls: [int] = []
  for sym in 0..288 {
    ls.push(if sym < 144 { 8 } else if sym < 256 { 9 } else if sym < 280 { 7 } else { 8 })
  }
  ls
}

let FIXED_LENS = huff(fixed_lengths(), true).0
let FIXED_DISTS = huff(filled(30, 5), true).0

fn dynamic(s: var In, out: var [int], n0: int): int!ZErr {
  let at = s.pos
  let nlen = s.bits(5)? + 257
  let ndist = s.bits(5)? + 1
  let ncode = s.bits(4)? + 4
  if nlen > 286 || ndist > 30 { fail(BadData(at, "too many length or distance symbols")) }
  var cl = ZEROS.take(19)
  for i in 0..ncode { cl[ORDER[i]] = s.bits(3)? }
  let (clcode, cl_left) = huff(cl, false)
  if cl_left != 0 { fail(BadData(at, "incomplete code length code")) }
  let total = nlen + ndist
  // the code lengths, reading ahead as `codes` does (a symbol and its repeat count: 22 bits)
  let src = s.src
  var pos = s.pos
  var buf = s.buf
  var cnt = s.cnt
  var lengths = ZEROS.take(total)
  var k = 0
  while k < total {
    while cnt <= 48 && pos < s.end {
      buf = buf | (src[pos] << cnt)
      pos += 1
      cnt += 8
    }
    let e = walk(clcode, buf)
    if e < 0 {
      if cnt < 15 { fail(Truncated) }
      fail(BadData(pos - ((cnt - 15) >> 3), "invalid Huffman code"))
    }
    if (e & 15) > cnt { fail(Truncated) }
    buf = buf >> (e & 15)
    cnt -= e & 15
    let sym = e >> 4
    if sym < 16 {
      lengths[k] = sym
      k += 1
    } else {
      if sym == 16 && k == 0 { fail(BadData(pos - (cnt >> 3), "repeat with no first length")) }
      let len = if sym == 16 { lengths[k - 1] } else { 0 }
      let width = if sym == 16 { 2 } else if sym == 17 { 3 } else { 7 }
      if width > cnt { fail(Truncated) }
      let n = if sym == 18 { 11 } else { 3 } + (buf & (1 << width) - 1)
      buf = buf >> width
      cnt -= width
      if k + n > total { fail(BadData(pos - (cnt >> 3), "too many code lengths")) }
      for _ in 0..n {
        lengths[k] = len
        k += 1
      }
    }
  }
  s.unread(pos, buf, cnt)
  if lengths[256] == 0 { fail(BadData(at, "no end-of-block code")) }
  let (lens, l_left) = huff(lengths.take(nlen), true)
  if l_left < 0 || (l_left > 0 && nlen - lens.count[0] != 1) {
    fail(BadData(at, "bad literal/length code lengths"))
  }
  let (dists, d_left) = huff(lengths.skip(nlen), true)
  if d_left < 0 || (d_left > 0 && ndist - dists.count[0] != 1) {
    fail(BadData(at, "bad distance code lengths"))
  }
  s.codes(&out, n0, lens, dists)
}

// Inflates the DEFLATE stream in bs[from..end]; also returns the offset just past it.
fn inflate_at(bs: [int], from: int, end: int): ([int], int)!ZErr {
  var s = In { src: bs, end, pos: from, buf: 0, cnt: 0 }
  var out = ZEROS
  var n = 0
  loop {
    let last = s.bits(1)?
    let at = s.pos
    n = match s.bits(2)? {
      0 => s.stored(&out, n)?
      1 => s.codes(&out, n, FIXED_LENS, FIXED_DISTS)?
      2 => s.dynamic(&out, n)?
      _ => fail(BadData(at, "invalid block type 3"))
    }
    if last == 1 { break (if n == out.len() { out } else { out.take(n) }, s.pos) }
  }
}

/// Decompresses raw DEFLATE data (no header or checksum). Bytes after the final block are
/// ignored.
pub fn inflate(data: [int]): [int]!ZErr = (inflate_at(data, 0, data.len())?).0

// ---- DEFLATE encoding: LZ77 with hash chains, then stored or fixed-Huffman blocks ----

// A plain bit stream writer, LSB first. It spells out the format (the tables below are built
// with it in mind, and the tests write hand-made streams with it); `deflate` itself packs bits
// straight into its output buffer.
struct Out { bytes: [int], acc: int, n: int }

fn put(o: var Out, v: int, nbits: int) {
  o.acc = o.acc | (v << o.n)
  o.n += nbits
  while o.n >= 8 {
    o.bytes.push(o.acc & 0xff)
    o.acc = o.acc >> 8
    o.n -= 8
  }
}

// Pads to a byte boundary with zero bits.
fn align(o: var Out) {
  if o.n > 0 {
    o.bytes.push(o.acc & 0xff)
    o.acc = 0
    o.n = 0
  }
}

// Huffman codes go out MSB first, so reverse the low `len` bits.
fn rev(code: int, len: int): int {
  var r = 0
  var c = code
  for _ in 0..len {
    r = (r << 1) | (c & 1)
    c = c >> 1
  }
  r
}

// The fixed literal/length code for `sym`: (code, length).
fn fixed_code(sym: int): (int, int) when sym < 144 = (0x30 + sym, 8)
fn fixed_code(sym: int): (int, int) when sym < 256 = (0x190 + sym - 144, 9)
fn fixed_code(sym: int): (int, int) when sym < 280 = (sym - 256, 7)
fn fixed_code(sym: int): (int, int) = (0xc0 + sym - 280, 8)

fn put_sym(o: var Out, sym: int) {
  let (code, len) = fixed_code(sym)
  o.put(rev(code, len), len)
}

// The index into LBASE for a match length 3..258.
fn len_index(len: int): int {
  var i = 28
  while LBASE[i] > len { i -= 1 }
  i
}

// The distance symbol for a distance 1..32768.
fn dist_index(dist: int): int {
  var i = 29
  while DBASE[i] > dist { i -= 1 }
  i
}

// What `deflate` writes for each symbol, worked out once: the bits (LSB first, as they enter
// the stream) shifted left by 4, plus how many there are.

// A literal/length symbol 0..287 in the fixed code.
fn sym_bits(sym: int): int {
  let (code, len) = fixed_code(sym)
  rev(code, len) << 4 | len
}

// A match length 3..258: its length symbol, then the extra bits.
fn len_bits(len: int): int {
  if len < 3 { return 0 }
  let li = len_index(len)
  let (code, n) = fixed_code(257 + li)
  (rev(code, n) | (len - LBASE[li]) << n) << 4 | (n + LEXT[li])
}

// `dist_index` as a table, zlib's way: by distance - 1 up to 256, and from there by
// (distance - 1) >> 7, since every symbol from 16 on covers a multiple of 128 distances.
fn dist_codes(): [int] {
  var t: [int] = []
  for d in 1..=256 { t.push(dist_index(d)) }
  for k in 0..256 { t.push(dist_index((k << 7) + 1)) }
  t
}

imprint SYM_BITS = (0..288).map(sym => sym_bits(sym))
imprint LEN_BITS = (0..259).map(len => len_bits(len))
imprint DIST_CODE = dist_codes()
imprint DIST_REV = (0..30).map(d => rev(d, 5))

let WINDOW = 32768
let HASH_SIZE = 32768
let MAX_CHAIN = 64
let MAX_MATCH = 258
let BLOCK = 65535

// "No position yet" for every hash.
imprint NO_HEADS = (0..32768).map(_ => -1)

// A token is a literal byte (0..255) or a match `(len << 16) | dist`.
fn is_match(t: int): bool = t > 255

fn hash3(bs: [int], i: int): int = ((bs[i] << 10) ^ (bs[i + 1] << 5) ^ bs[i + 2]) & (HASH_SIZE - 1)

// LZ77 tokens for bs[start..end], written to `toks`; returns how many. Matches may reach back
// before `start`. `head` is the latest position with each hash and `prev` the position before
// each position (by position mod WINDOW) with the same hash: every position that has three
// bytes to hash is entered as it is passed.
fn tokens(head: var [int], prev: var [int], toks: var [int], bs: [int], start: int, end: int): int {
  let n = bs.len()
  var nt = 0
  var i = start
  // the hash of the three bytes at i, as long as there are three; each position's hash
  // follows from the one before
  var h = if i + 2 < n { hash3(bs, i) } else { 0 }
  while i < end {
    // the longest earlier match for position i, not reaching past `end`
    var best = 0
    var dist = 0
    if i + 2 < end {
      let max = if end - i < MAX_MATCH { end - i } else { MAX_MATCH }
      var cand = head[h]
      var chain = 0
      var want = bs[i]  // bs[i + best]: what a longer match must have there
      while cand >= 0 && i - cand <= WINDOW && chain < MAX_CHAIN {
        if bs[cand + best] == want {
          var l = 0
          while l < max && bs[cand + l] == bs[i + l] { l += 1 }
          if l > best {
            best = l
            dist = i - cand
            if l == max { break }
            want = bs[i + best]
          }
        }
        let next = prev[cand & (WINDOW - 1)]
        if next >= cand { break }  // a slot reused by a newer position: the chain ends here
        cand = next
        chain += 1
      }
    }
    let stop = if best >= 3 { i + best } else { i + 1 }
    toks[nt] = if best >= 3 { (best << 16) | dist } else { bs[i] }
    nt += 1
    while i < stop {
      if i + 2 < n {
        prev[i & (WINDOW - 1)] = head[h]
        head[h] = i
      }
      i += 1
      if i + 2 < n { h = ((h << 5) ^ bs[i + 2]) & (HASH_SIZE - 1) }
    }
  }
  nt
}

fn dist_code(dist: int): int = if dist <= 256 {
  DIST_CODE[dist - 1]
} else {
  DIST_CODE[256 + ((dist - 1) >> 7)]
}

// The size in bits of `toks[..nt]` as a fixed-Huffman block (with header and end-of-block code).
fn fixed_cost(toks: [int], nt: int): int {
  var bits = 3 + 7
  for k in 0..nt {
    let t = toks[k]
    if is_match(t) {
      bits += (LEN_BITS[t >> 16] & 15) + 5 + DEXT[dist_code(t & 0xffff)]
    } else {
      bits += SYM_BITS[t] & 15
    }
  }
  bits
}

// The block writers put their bits into `bytes` from bit offset `at` on and return the offset
// they reach; `bytes` must be long enough (see `room`). The bits of a last, partly used byte
// are in `bytes` too, with the rest of that byte zero.

// Makes sure `bytes` can take `extra` more bytes from bit offset `at`.
fn room(bytes: var [int], at: int, extra: int) {
  while bytes.len() < (at >> 3) + extra + 2 { bytes = bytes + bytes }
}

fn fixed_block(bytes: var [int], at: int, toks: [int], nt: int, last: bool): int {
  var p = at >> 3
  var n = at & 7
  // the block header: the last-block bit, then type 1 in two bits
  var acc = (bytes[p] & (1 << n) - 1) | if last { 3 } else { 2 } << n
  n += 3
  for k in 0..nt {
    let t = toks[k]
    if is_match(t) {
      let l = LEN_BITS[t >> 16]
      acc = acc | (l >> 4) << n
      n += l & 15
      let dist = t & 0xffff
      let d = dist_code(dist)
      acc = acc | (DIST_REV[d] | (dist - DBASE[d]) << 5) << n
      n += 5 + DEXT[d]
    } else {
      let l = SYM_BITS[t]
      acc = acc | (l >> 4) << n
      n += l & 15
    }
    while n >= 8 {
      bytes[p] = acc & 0xff
      p += 1
      acc = acc >> 8
      n -= 8
    }
  }
  // the end-of-block symbol 256: seven zero bits
  n += 7
  while n >= 8 {
    bytes[p] = acc & 0xff
    p += 1
    acc = acc >> 8
    n -= 8
  }
  bytes[p] = acc
  p * 8 + n
}

fn stored_block(bytes: var [int], at: int, bs: [int], start: int, end: int, last: bool): int {
  // the header (the last-block bit, type 0 in two bits), then zero bits up to a byte boundary
  var p = at >> 3
  let used = at & 7
  bytes[p] = (bytes[p] & (1 << used) - 1) | if last { 1 } else { 0 } << used
  if used > 5 { bytes[p + 1] = 0 }
  p = (at + 10) >> 3
  let n = end - start
  bytes[p] = n & 0xff
  bytes[p + 1] = n >> 8
  bytes[p + 2] = ~n & 0xff
  bytes[p + 3] = (~n >> 8) & 0xff
  p += 4
  for i in 0..n { bytes[p + i] = bs[start + i] }
  (p + n) * 8
}

/// Compresses `data` as raw DEFLATE: LZ77 matching (hash chains over a 32 KiB window) coded
/// with the fixed Huffman code, with a stored block for any 64 KiB chunk that wouldn't shrink.
pub fn deflate(data: [int]): [int] {
  let n = data.len()
  var bytes = ZEROS
  var at = 0
  if n == 0 {
    at = fixed_block(&bytes, at, [], 0, true)
    return bytes.take((at + 7) >> 3)
  }
  var head = NO_HEADS
  var prev = if n < WINDOW { NO_HEADS.take(n) } else { NO_HEADS }
  var toks = zeros(if n < BLOCK { n } else { BLOCK })
  var start = 0
  while start < n {
    let end = if n - start > BLOCK { start + BLOCK } else { n }
    let last = end == n
    let nt = tokens(&head, &prev, &toks, data, start, end)
    let cost = fixed_cost(toks, nt)
    if cost > (end - start) * 8 + 40 {
      room(&bytes, at, end - start + 5)
      at = stored_block(&bytes, at, data, start, end, last)
    } else {
      room(&bytes, at, cost >> 3)
      at = fixed_block(&bytes, at, toks, nt, last)
    }
    start = end
  }
  bytes.take((at + 7) >> 3)
}

/// Wraps `data` in stored (uncompressed) DEFLATE blocks: no compression, but valid DEFLATE.
pub fn store(data: [int]): [int] {
  let n = data.len()
  var bytes = zeros(n + 5 * (n / BLOCK + 1))
  var at = 0
  var start = 0
  loop {
    let end = if n - start > BLOCK { start + BLOCK } else { n }
    at = stored_block(&bytes, at, data, start, end, end == n)
    start = end
    if start == n { break }
  }
  bytes.take(at >> 3)
}

// ---- gzip (RFC 1952) ----

fn le32(x: int): [int] = [x & 0xff, (x >> 8) & 0xff, (x >> 16) & 0xff, (x >> 24) & 0xff]
fn be32(x: int): [int] = [(x >> 24) & 0xff, (x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff]

fn read_le32(bs: [int], i: int): int =
  bs[i] | (bs[i + 1] << 8) | (bs[i + 2] << 16) | (bs[i + 3] << 24)

fn read_be32(bs: [int], i: int): int =
  (bs[i] << 24) | (bs[i + 1] << 16) | (bs[i + 2] << 8) | bs[i + 3]

/// Compresses `data` as a gzip member (no file name, modification time 0, OS "unknown").
pub fn gzip(data: [int]): [int] {
  var out = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255]
  out += deflate(data)
  out += le32(crc32(data))
  out += le32(data.len() & MASK)
  out
}

/// Decompresses gzip data: every member, concatenated (as `gzip -d` does). Each member's CRC-32
/// and length are checked; the optional header fields (extra, name, comment, header CRC) are
/// read and skipped.
pub fn gunzip(data: [int]): [int]!ZErr {
  if data.len() == 0 { fail(Truncated) }
  var out: [int] = []
  var pos = 0
  while pos < data.len() {
    let start = gzip_header(data, pos)?
    let (got, end) = inflate_at(data, start, data.len())?
    if end + 8 > data.len() { fail(Truncated) }
    if read_le32(data, end) != crc32(got) { fail(BadChecksum("CRC-32")) }
    if read_le32(data, end + 4) != (got.len() & MASK) { fail(BadChecksum("length")) }
    if out.len() == 0 { out = got } else { out += got }
    pos = end + 8
  }
  out
}

// Checks a gzip member header at `at` and returns the offset of its DEFLATE data.
fn gzip_header(bs: [int], at: int): int!ZErr {
  if at + 10 > bs.len() { fail(Truncated) }
  if bs[at] != 0x1f || bs[at + 1] != 0x8b { fail(BadHeader(at, "not gzip data")) }
  if bs[at + 2] != 8 { fail(BadHeader(at + 2, "compression method {bs[at + 2]} isn't deflate")) }
  let flags = bs[at + 3]
  if (flags & 0xe0) != 0 { fail(BadHeader(at + 3, "reserved flag bits are set")) }
  var p = at + 10
  if (flags & 4) != 0 {
    // FEXTRA: a 2-byte length, then that many bytes
    if p + 2 > bs.len() { fail(Truncated) }
    p += 2 + (bs[p] | (bs[p + 1] << 8))
  }
  if (flags & 8) != 0 { p = past_zero(bs, p)? }   // FNAME
  if (flags & 16) != 0 { p = past_zero(bs, p)? }  // FCOMMENT
  if (flags & 2) != 0 {
    // FHCRC: the low 16 bits of the CRC-32 of the header so far
    if p + 2 > bs.len() { fail(Truncated) }
    let want = bs[p] | (bs[p + 1] << 8)
    if (crc32(bs[at..p]) & 0xffff) != want { fail(BadChecksum("header CRC")) }
    p += 2
  }
  if p > bs.len() { fail(Truncated) }
  p
}

fn past_zero(bs: [int], from: int): int!ZErr {
  var i = from
  while i < bs.len() {
    if bs[i] == 0 { return i + 1 }
    i += 1
  }
  fail(Truncated)
}

// ---- zlib (RFC 1950) ----

/// Compresses `data` as a zlib stream (header `78 01`, Adler-32 trailer).
pub fn zlib(data: [int]): [int] {
  var out = [0x78, 0x01]
  out += deflate(data)
  out += be32(adler32(data))
  out
}

/// Decompresses a zlib stream and checks its Adler-32. Preset dictionaries aren't supported,
/// and nothing may follow the stream.
pub fn unzlib(data: [int]): [int]!ZErr {
  if data.len() < 2 { fail(Truncated) }
  let cmf = data[0]
  let flg = data[1]
  if (cmf & 15) != 8 { fail(BadHeader(0, "compression method {cmf & 15} isn't deflate")) }
  if (cmf >> 4) > 7 { fail(BadHeader(0, "window size too large")) }
  if ((cmf << 8) | flg) % 31 != 0 { fail(BadHeader(1, "header check failed")) }
  if (flg & 0x20) != 0 { fail(BadHeader(1, "preset dictionaries aren't supported")) }
  let (got, end) = inflate_at(data, 2, data.len())?
  if end + 4 > data.len() { fail(Truncated) }
  if read_be32(data, end) != adler32(got) { fail(BadChecksum("Adler-32")) }
  if end + 4 != data.len() { fail(BadHeader(end + 4, "data after the end of the stream")) }
  got
}

// ---- zip archives (PKWARE APPNOTE) ----

/// One file in a zip archive. A name ending in `/` is a directory, with empty `data`.
pub struct Entry { name: str, data: [int] }

fn read_le16(bs: [int], i: int): int = bs[i] | (bs[i + 1] << 8)

fn put16(o: var [int], x: int) {
  o.push(x & 0xff)
  o.push((x >> 8) & 0xff)
}

fn put32(o: var [int], x: int) {
  o.put16(x & 0xffff)
  o.put16((x >> 16) & 0xffff)
}

let LOCAL_SIG = 0x04034b50
let CENTRAL_SIG = 0x02014b50
let END_SIG = 0x06054b50
let DOS_DATE = 0x21  // 1980-01-01, the earliest date zip can hold

/// Builds a zip archive. Each file is deflated, or stored when deflating doesn't make it
/// smaller. Names are UTF-8 (flag bit 11); every timestamp is 1980-01-01 00:00, so the same
/// entries always give the same bytes.
pub fn zip(entries: [Entry]): [int]
  requires entries.len() < 0xffff
{
  var out: [int] = []
  var central: [int] = []
  for e in entries {
    let name = e.name.bytes()
    let packed = deflate(e.data)
    let (method, body) = if packed.len() < e.data.len() { (8, packed) } else { (0, e.data) }
    let dir = e.name.ends_with("/")
    // the fields local and central headers share: version needed, flags (UTF-8), method,
    // time, date, CRC-32, sizes, name length
    var common: [int] = []
    common.put16(if method == 8 { 20 } else { 10 })
    common.put16(0x800)
    common.put16(method)
    common.put16(0)
    common.put16(DOS_DATE)
    common.put32(crc32(e.data))
    common.put32(body.len())
    common.put32(e.data.len())
    common.put16(name.len())
    central.put32(CENTRAL_SIG)
    central.put16(0x314)  // made by Unix, so unzip applies the mode below
    central += common
    central += [0, 0, 0, 0, 0, 0, 0, 0]           // extra, comment, disk, internal attributes
    let mode = if dir { 0x41ed } else { 0x81a4 }  // 0o40755, 0o100644
    central.put32((mode << 16) | if dir { 0x10 } else { 0 })
    central.put32(out.len())
    central += name
    out.put32(LOCAL_SIG)
    out += common
    out += [0, 0]
    out += name
    out += body
  }
  let at = out.len()
  out += central
  out.put32(END_SIG)
  out.put32(0)  // disk numbers
  out.put16(entries.len())
  out.put16(entries.len())
  out.put32(central.len())
  out.put32(at)
  out.put16(0)  // comment length
  out
}

/// Reads a zip archive's files, in central-directory order, and checks each CRC-32 and size.
/// Handles stored and deflated entries and data descriptors. Encrypted entries, other methods
/// and zip64 archives are `BadHeader` errors. Names are returned as written: check them for
/// `..` and leading `/` before using them as paths.
pub fn unzip(data: [int]): [Entry]!ZErr {
  let end = find_end(data)?
  let count = read_le16(data, end + 10)
  let at = read_le32(data, end + 16)
  if count == 0xffff || at == MASK { fail(BadHeader(end, "zip64 archives aren't supported")) }
  var p = at
  var out: [Entry] = []
  for _ in 0..count {
    if p + 46 > data.len() { fail(Truncated) }
    if read_le32(data, p) != CENTRAL_SIG { fail(BadHeader(p, "bad central directory entry")) }
    let flags = read_le16(data, p + 8)
    let method = read_le16(data, p + 10)
    let crc = read_le32(data, p + 16)
    let csize = read_le32(data, p + 20)
    let size = read_le32(data, p + 24)
    let nlen = read_le16(data, p + 28)
    let local = read_le32(data, p + 42)
    if p + 46 + nlen > data.len() { fail(Truncated) }
    let name = str.from_utf8(
      data[p + 46..p + 46 + nlen],
    ) else fail(BadHeader(p + 46, "file name isn't UTF-8"))
    if (flags & 1) != 0 { fail(BadHeader(p + 8, "{name} is encrypted")) }
    if csize == MASK || size == MASK || local == MASK {
      fail(BadHeader(p + 20, "zip64 archives aren't supported"))
    }
    let bytes = entry_data(data, local, method, csize)?
    if bytes.len() != size { fail(BadChecksum("length")) }
    if crc32(bytes) != crc { fail(BadChecksum("CRC-32")) }
    out.push(Entry { name, data: bytes })
    p += 46 + nlen + read_le16(data, p + 30) + read_le16(data, p + 32)
  }
  out
}

// Finds the end-of-central-directory record, which may be followed by a comment.
fn find_end(bs: [int]): int!ZErr {
  if bs.len() < 22 { fail(Truncated) }
  var i = bs.len() - 22
  let stop = if bs.len() > 22 + 0xffff { bs.len() - 22 - 0xffff } else { 0 }
  while i >= stop {
    if read_le32(bs, i) == END_SIG && i + 22 + read_le16(bs, i + 20) == bs.len() { return i }
    i -= 1
  }
  fail(BadHeader(0, "not a zip archive"))
}

// Reads the data of the entry whose local header starts at `at`.
fn entry_data(bs: [int], at: int, method: int, csize: int): [int]!ZErr {
  if at + 30 > bs.len() { fail(Truncated) }
  if read_le32(bs, at) != LOCAL_SIG { fail(BadHeader(at, "bad local file header")) }
  let start = at + 30 + read_le16(bs, at + 26) + read_le16(bs, at + 28)
  if start + csize > bs.len() { fail(Truncated) }
  match method {
    0 => bs[start..start + csize]
    8 => (inflate_at(bs, start, start + csize)?).0
    m => fail(BadHeader(at + 8, "compression method {m} isn't supported"))
  }
}

// ---- tests ----

test "checksums" {
  assert crc32("123456789".bytes()) == 0xcbf43926
  assert crc32([]) == 0
  assert crc32_update(crc32("1234".bytes()), "56789".bytes()) == 0xcbf43926
  assert adler32("Wikipedia".bytes()) == 0x11e60398
  assert adler32([]) == 1
  var big: [int] = []
  for i in 0..10000 { big.push(255 - i % 7) }
  assert adler32(big) == 0xc0307601
}

// Test vectors are written in lower-case hex (`xxd -p`).
fn unhex(h: str): [int] = h.chars().chunks(2).map(p => digit(p[0]) * 16 + digit(p[1]))

fn digit(c: char): int = if c.is_digit() { int(c) - 48 } else { int(c) - 87 }

// These vectors were generated before the Duck → Auk rename; the literals must match the bytes.
// "hello, duck!\n" from `gzip -c -n` (no name, no time) and `gzip -c -9 hello.txt` (with both).
let GZIP_N = unhex("1f8b0800000000000003cb48cdc9c9d75148294dce56e402007a16d23b0d000000")

let GZIP_NAMED = unhex(
  "1f8b0808701b5669020368656c6c6f2e74787400cb48cdc9c9d75148294dce56e402007a16d23b0d" + "000000",
)

// python3: zlib.compress((PARA + PARA).encode(), 9), a dynamic-Huffman block.
let PARA = "Duck is statically typed and compiled to native code. Braces delimit blocks; no semicolons. A newline ends a statement unless the line ends with an operator. Effects are declared: uses fs, net, time. Packages declare their effects, and quack refuses to install a package that needs an effect your project has not allowed. "

let ZLIB_DYNAMIC = unhex(
  "78daed50cd4dc6300c5de50d50750038813eeeac1012979aa676895daa6e8f9b0f8901b8728a1cbf" +
    "5fdff6bc800de6c939a75a4ff8b951419282acebc635065748ecbf28be0a8d786e2993a150e5951d" +
    "6f55f3628f1085d1ca59ab8a8d7882d051590824c590ba09ad248e5d2a99c167c22fe0609fc317ba" +
    "514bae6dc4cb3451f6a0360ab35ce32d0fd82dbc271b42de0738af91e835e525bdf74c1d76497303" +
    "dd05865ee7730f101a4d5d203ab144a25a23d976a7072b79c8d215577ed838756fd89a7e5cc39c2c" +
    "7a3a82a7079511b7ff0bfef182dfb698e7ed",
)

test "known vectors from gzip and python zlib" {
  let hello = "hello, duck!\n".bytes()
  assert gunzip(GZIP_N)? == hello
  assert gunzip(GZIP_NAMED)? == hello
  assert gunzip(GZIP_N + GZIP_NAMED)? == hello + hello  // two members
  assert unzlib(ZLIB_DYNAMIC)? == (PARA + PARA).bytes()
  // raw DEFLATE: fixed Huffman with matches, and a stored block
  assert inflate([75, 76, 74, 78, 68, 69, 10, 25, 169, 57, 57, 249, 0])? ==
    "abcabcabcabcabcabc hello".bytes()
  assert inflate([1, 7, 0, 248, 255, 115, 116, 111, 114, 101, 100, 33])? == "stored!".bytes()
  assert str.from_utf8(gunzip(GZIP_N)?)? == "hello, duck!\n"
}

test "gzip header fields: extra, comment and header CRC" {
  let body = GZIP_N.skip(10)
  // FEXTRA (4 bytes) + FCOMMENT "hi" + FHCRC
  var head = [31, 139, 8, 4 | 16 | 2, 0, 0, 0, 0, 0, 3, 4, 0, 65, 66, 1, 0, 104, 105, 0]
  let hcrc = crc32(head) & 0xffff
  head = head + [hcrc & 0xff, hcrc >> 8]
  assert gunzip(head + body)? == "hello, duck!\n".bytes()
  var bad = head
  bad[bad.len() - 1] = bad[bad.len() - 1] ^ 1
  assert gunzip(bad + body) is err(BadChecksum("header CRC"))
}

fn sample(n: int): [int] {
  // text-like data with repeats, plus some noise
  let words = ["auk", "raft", "pond", "feather", " ", "\n", "the", "a", "wing"]
  var out: [int] = []
  var x = 12345
  while out.len() < n {
    x = (x *% 1103515245 +% 12345) & 0x7fffffff
    for b in words[(x >> 8) % words.len()].bytes() { out.push(b) }
    if x % 13 == 0 { out.push((x >> 3) & 0xff) }
  }
  out.take(n)
}

test "round trips: deflate, store, gzip, zlib" {
  var noise: [int] = []
  var x = 7
  for _ in 0..3000 {
    x = x *% 6364136223846793005 +% 1442695040888963407
    noise.push((x >> 33) & 0xff)
  }
  let cases = [
    [],
    [0],
    "a".bytes(),
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".bytes(),
    "abcabcabcabcabcabc hello".bytes(),
    (PARA + PARA).bytes(),
    sample(5000),
    noise,
    filled(70000, 7),  // spans two blocks; one long run of max-length matches
    sample(140000),    // three blocks, matches across block boundaries
  ]
  for c in cases {
    assert inflate(deflate(c))? == c
    assert inflate(store(c))? == c
    assert gunzip(gzip(c))? == c
    assert unzlib(zlib(c))? == c
  }
  // it compresses: repetitive text shrinks a lot, noise is stored at about its own size
  assert deflate(sample(5000)).len() < 2000
  assert deflate((PARA + PARA).bytes()).len() < 320
  assert deflate(filled(70000, 7)).len() < 500
  assert deflate(noise).len() <= noise.len() + 10
  assert store("stored!".bytes()) == [1, 7, 0, 248, 255, 115, 116, 111, 114, 101, 100, 33]
}

test "output decodes with other decoders' framing" {
  // our gzip and zlib headers are the standard minimal ones
  let g = gzip("hello, duck!\n".bytes())
  assert g.take(4) == [31, 139, 8, 0]
  assert g.skip(g.len() - 8) == [122, 22, 210, 59, 13, 0, 0, 0]
  let z = zlib([])
  assert z.take(2) == [0x78, 0x01] && z.skip(z.len() - 4) == [0, 0, 0, 1]
}

test "corrupt input" {
  assert gunzip([]) is err(Truncated)
  assert gunzip(GZIP_N.take(20)) is err(Truncated)
  assert gunzip(GZIP_N.take(GZIP_N.len() - 3)) is err(Truncated)
  assert gunzip([31, 138] + GZIP_N.skip(2)) is err(BadHeader(0, _))
  assert gunzip([31, 139, 7] + GZIP_N.skip(3)) is err(BadHeader(2, _))
  assert gunzip([31, 139, 8, 0x20] + GZIP_N.skip(4)) is err(BadHeader(3, _))
  var crc = GZIP_N
  crc[crc.len() - 8] = crc[crc.len() - 8] ^ 0xff
  assert gunzip(crc) is err(BadChecksum("CRC-32"))
  var size = GZIP_N
  size[size.len() - 4] = 14
  assert gunzip(size) is err(BadChecksum("length"))
  assert gunzip(GZIP_N + [0]) is err(_)  // trailing garbage
  var z = ZLIB_DYNAMIC
  z[z.len() - 1] = z[z.len() - 1] ^ 1
  assert unzlib(z) is err(BadChecksum("Adler-32"))
  assert unzlib([0x78]) is err(Truncated)
  assert unzlib([0x79, 0x9c] + ZLIB_DYNAMIC.skip(2)) is err(BadHeader(0, _))
  assert unzlib([0x78, 0x9d] + ZLIB_DYNAMIC.skip(2)) is err(BadHeader(1, _))
  assert unzlib([0x78, 0xbb, 0, 0, 0, 1] + ZLIB_DYNAMIC.skip(2)) is err(BadHeader(1, _))
  assert unzlib(ZLIB_DYNAMIC + [0]) is err(BadHeader(_, _))
  assert inflate([]) is err(Truncated)
  assert inflate([7]) is err(BadData(_, "invalid block type 3"))
  assert inflate([1, 7, 0, 248, 254, 115]) is err(BadData(1, "stored block length check failed"))
  assert inflate([1, 7, 0, 248, 255, 115]) is err(Truncated)
  // fixed block: literal 'a', then length 3 at distance 1 is fine, distance 2 is too far
  var o = Out { bytes: [], acc: 0, n: 0 }
  o.put(1, 1)
  o.put(1, 2)
  o.put_sym(97)
  o.put_sym(257)
  o.put(rev(1, 5), 5)  // distance code 1 = distance 2
  o.put_sym(256)
  o.align()
  assert inflate(o.bytes) is err(BadData(_, "distance too far back"))
  // dynamic block whose code length code is over-subscribed (every length 1)
  var d = Out { bytes: [], acc: 0, n: 0 }
  d.put(1, 1)
  d.put(2, 2)
  d.put(0, 5)
  d.put(0, 5)
  d.put(15, 4)
  for _ in 0..19 { d.put(1, 3) }
  d.align()
  assert inflate(d.bytes) is err(BadData(_, "incomplete code length code"))
  // a truncated dynamic stream
  assert unzlib(ZLIB_DYNAMIC.take(100)) is err(Truncated)
  assert message(BadData(3, "x")) == "bad deflate data at 3: x"
  assert message(BadChecksum("CRC-32")) == "CRC-32 check failed: the data is corrupt"
}

// `zip -rX -z small.zip a.txt d` (Info-ZIP 3.0): stored files, a directory and a comment "hi".
let ZIP_CLI = unhex(
  "504b03040a0000000000175e5e5d7a16d23b0d0000000d00000005000000612e74787468656c6c6f" +
    "2c206475636b210a504b03040a0000000000175e5e5d00000000000000000000000002000000642f" +
    "504b0304140000000800175e5e5d37bae58a0c0000002400000007000000642f712e7478742b2c4d" +
    "4cce5628c447720100504b01021e030a0000000000175e5e5d7a16d23b0d0000000d000000050000" +
    "000000000001000000a48100000000612e747874504b01021e030a0000000000175e5e5d00000000" +
    "0000000000000000020000000000000000001000ed4130000000642f504b01021e03140000000800" +
    "175e5e5d37bae58a0c00000024000000070000000000000001000000a48150000000642f712e7478" +
    "74504b05060000000003000300980000008100000002006869",
)

// python3 zipfile writing to an unseekable stream: deflated, sizes in data descriptors.
let ZIP_STREAMED = unhex(
  "504b0304140008000800000021000000000000000000000000000c00000073747265616d65642e74" +
    "7874edc6211100400800b02a547b81c4c0f73f52e036b5f99dafa232c6cccccccccccccccccc8eb6" +
    "504b0708c0a4d2632600000088130000504b0304140008000800125e5e5d00000000000000000000" +
    "000009000000706c61696e2e747874cbc80400504b0708ac2a93d80400000002000000504b010214" +
    "0314000800080000002100c0a4d26326000000881300000c00000000000000000000008001000000" +
    "0073747265616d65642e747874504b01021403140008000800125e5e5dac2a93d804000000020000" +
    "00090000000000000000000000800160000000706c61696e2e747874504b05060000000002000200" +
    "710000009b0000000000",
)

test "unzip archives from zip and python" {
  let es = unzip(ZIP_CLI)?
  assert es.map(e => e.name) == ["a.txt", "d/", "d/q.txt"]
  assert es[0].data == "hello, duck!\n".bytes()
  assert es[1].data == []
  assert es[2].data == "quack quack quack quack quack quack\n".bytes()
  let st = unzip(ZIP_STREAMED)?
  assert st.map(e => e.name) == ["streamed.txt", "plain.txt"]
  assert st[0].data == "stream me ".repeat(500).bytes()
  assert st[1].data == "hi".bytes()
}

test "zip round trips and is deterministic" {
  let es = [
    Entry { name: "a.txt", data: "hello, auk!\n".bytes() },
    Entry { name: "dir/", data: [] },
    Entry { name: "dir/big.txt", data: sample(20000) },
    Entry { name: "dir/ünï.bin", data: [0, 255, 7] },
    Entry { name: "empty", data: [] },
  ]
  let z = zip(es)
  assert unzip(z)? == es
  assert zip(es) == z
  assert z.len() < 20000 / 2  // big.txt was deflated
  assert unzip(zip([]))? == []
  assert zip([]) == [80, 75, 5, 6] + filled(18, 0)
}

test "corrupt zip archives" {
  assert unzip([]) is err(Truncated)
  assert unzip(GZIP_N) is err(BadHeader(0, "not a zip archive"))
  assert unzip(ZIP_CLI.take(ZIP_CLI.len() - 1)) is err(BadHeader(0, _))  // comment cut short
  var crc = ZIP_CLI
  crc[35] = crc[35] ^ 1  // the first file's data: "hello" becomes "iello"
  assert unzip(crc) is err(BadChecksum("CRC-32"))
  var method = ZIP_STREAMED
  method[0x9b + 10] = 12  // bzip2 in the first central entry
  assert unzip(method) is err(BadHeader(_, "compression method 12 isn't supported"))
  var locked = ZIP_STREAMED
  locked[0x9b + 8] = locked[0x9b + 8] | 1
  assert unzip(locked) is err(BadHeader(_, "streamed.txt is encrypted"))
  var moved = ZIP_CLI
  moved[0x81 + 42] = 1  // the first central entry's local header offset
  assert unzip(moved) is err(BadHeader(1, "bad local file header"))
  // the central directory (0x98 bytes at 0x81) is missing
  assert unzip(ZIP_CLI.take(0x81) + ZIP_CLI.skip(0x81 + 0x98)) is err(Truncated)
}

test "encoder tables agree with the definitions" {
  for dist in 1..=32768 { assert dist_code(dist) == dist_index(dist) }
  for len in 3..=258 {
    let li = len_index(len)
    let (code, n) = fixed_code(257 + li)
    assert (LEN_BITS[len] & 15) == n + LEXT[li]
    assert ((LEN_BITS[len] >> 4) & (1 << n) - 1) == rev(code, n)
    assert (LEN_BITS[len] >> (4 + n)) == len - LBASE[li]
  }
  // the fast decoding table finds the same symbols as reading a bit at a time
  for h in [FIXED_LENS, FIXED_DISTS] {
    for bits in 0..512 {
      let e = h.fast[bits]
      assert e == 0 || e == walk(h, bits)
      assert e != 0 || walk(h, bits) < 0 || (walk(h, bits) & 15) > FAST
    }
  }
}
