/// FLAC (module `audio.flac`). The decoder reads every stream the format allows: fixed or
/// variable block sizes, 4 to 32 bits per sample, 1 to 8 channels, constant, verbatim, fixed and
/// LPC subframes, wasted bits, Rice and Rice2 residuals with escape codes, and all stereo
/// decorrelation modes. It checks every frame's CRC-8 and CRC-16, and reads Vorbis comments.
/// A leading ID3v2 tag is skipped.
///
/// The encoder is close to `flac -5`: 4096-frame blocks, LPC up to order 8 chosen by the
/// Levinson-Durbin error (Tukey window), fixed predictors, partitioned Rice coding (up to 64
/// partitions), wasted-bit detection, and the best of left/right, left/side, side/right and
/// mid/side per frame. It writes STREAMINFO with the MD5 of the samples, then Vorbis comments.

// ---- checksums ----

fn crc8_table(): [int] = (0..256).map(i => {
  var c = i
  for _ in 0..8 { c = if (c & 0x80) != 0 { ((c << 1) ^ 0x07) & 0xff } else { (c << 1) & 0xff } }
  c
})

fn crc16_table(): [int] = (0..256).map(i => {
  var c = i << 8
  for _ in 0..8 {
    c = if (c & 0x8000) != 0 { ((c << 1) ^ 0x8005) & 0xffff } else { (c << 1) & 0xffff }
  }
  c
})

imprint CRC8 = crc8_table()
imprint CRC16 = crc16_table()

fn crc8(d: [int], from: int, to: int): int {
  var c = 0
  for i in from..to { c = CRC8[c ^ d[i]] }
  c
}

fn crc16(d: [int], from: int, to: int): int {
  var c = 0
  for i in from..to { c = (c << 8) & 0xffff ^ CRC16[(c >> 8) ^ d[i]] }
  c
}

// ---- MD5 (RFC 1321), for STREAMINFO ----

let M32 = 0xffffffff

fn md5_k(): [int] = (0..64).map(i => int(floor(abs(sin(float(i + 1))) * 4294967296.0)))

imprint MD5_K = md5_k()

let MD5_S = [
  7,
  12,
  17,
  22,
  7,
  12,
  17,
  22,
  7,
  12,
  17,
  22,
  7,
  12,
  17,
  22,
  5,
  9,
  14,
  20,
  5,
  9,
  14,
  20,
  5,
  9,
  14,
  20,
  5,
  9,
  14,
  20,
  4,
  11,
  16,
  23,
  4,
  11,
  16,
  23,
  4,
  11,
  16,
  23,
  4,
  11,
  16,
  23,
  6,
  10,
  15,
  21,
  6,
  10,
  15,
  21,
  6,
  10,
  15,
  21,
  6,
  10,
  15,
  21,
]

struct Md5 { h: [int], buf: [int], total: int }

fn md5_new(): Md5 = Md5 { h: [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476], buf: [], total: 0 }

fn md5_block(m: var Md5, d: [int], at: int) {
  var w: [int] = []
  for j in 0..16 {
    let q = at + 4 * j
    w.push(d[q] | (d[q + 1] << 8) | (d[q + 2] << 16) | (d[q + 3] << 24))
  }
  let ks = MD5_K
  let ss = MD5_S
  var a = m.h[0]
  var b = m.h[1]
  var c = m.h[2]
  var dd = m.h[3]
  // the four rounds; every value stays below 2^32, so the sums can't overflow
  for i in 0..16 {
    let f = ((b & c) | (~b & M32 & dd)) + a + ks[i] + w[i] & M32
    a = dd
    dd = c
    c = b
    let s = ss[i]
    b = (b + (((f << s) | (f >> (32 - s))) & M32)) & M32
  }
  for i in 16..32 {
    let f = ((dd & b) | (~dd & M32 & c)) + a + ks[i] + w[(5 * i + 1) & 15] & M32
    a = dd
    dd = c
    c = b
    let s = ss[i]
    b = (b + (((f << s) | (f >> (32 - s))) & M32)) & M32
  }
  for i in 32..48 {
    let f = (b ^ c ^ dd) + a + ks[i] + w[(3 * i + 5) & 15] & M32
    a = dd
    dd = c
    c = b
    let s = ss[i]
    b = (b + (((f << s) | (f >> (32 - s))) & M32)) & M32
  }
  for i in 48..64 {
    let f = (c ^ (b | (~dd & M32))) + a + ks[i] + w[(7 * i) & 15] & M32
    a = dd
    dd = c
    c = b
    let s = ss[i]
    b = (b + (((f << s) | (f >> (32 - s))) & M32)) & M32
  }
  m.h[0] = (m.h[0] + a) & M32
  m.h[1] = (m.h[1] + b) & M32
  m.h[2] = (m.h[2] + c) & M32
  m.h[3] = (m.h[3] + dd) & M32
}

fn md5_update(m: var Md5, d: [int]) {
  m.total += d.len()
  var p = 0
  // `buf` holds fewer than 64 bytes: complete its block first, then take blocks straight from `d`
  if m.buf.len() > 0 {
    let need = 64 - m.buf.len()
    if d.len() < need {
      m.buf = m.buf + d
      return
    }
    m.md5_block(m.buf + d[0..need], 0)
    p = need
  }
  while p + 64 <= d.len() {
    m.md5_block(d, p)
    p += 64
  }
  m.buf = d[p..d.len()]
}

fn md5_finish(m: var Md5): [int] {
  let bits = m.total * 8
  var pad = [0x80]
  while (m.buf.len() + pad.len()) % 64 != 56 { pad.push(0) }
  audio.pcm.put32le(&pad, bits & M32)
  audio.pcm.put32le(&pad, (bits >> 32) & M32)
  let total = m.total
  m.md5_update(pad)
  m.total = total
  var out: [int] = []
  for v in m.h { audio.pcm.put32le(&out, v) }
  out
}

/// The MD5 of `data` as 16 bytes: `md5("abc".bytes())` is 900150983cd24fb0d6963f7d28e17f72.
pub fn md5(data: [int]): [int] {
  var m = md5_new()
  m.md5_update(data)
  m.md5_finish()
}

// ---- reading bits ----

struct Bits { d: [int], pos: int, acc: int, n: int }

fn over(b: Bits): bool = b.pos > b.d.len()

fn rd(b: var Bits, k: int): int {
  if k == 0 { return 0 }
  while b.n < k {
    b.acc = (b.acc << 8) | if b.pos < b.d.len() { b.d[b.pos] } else { 0 }
    b.pos += 1
    b.n += 8
  }
  b.n -= k
  let v = b.acc >> b.n
  b.acc = b.acc & (1 << b.n) - 1
  v
}

fn srd(b: var Bits, k: int): int = if k == 0 { 0 } else { audio.pcm.sext(b.rd(k), k) }

// The number of 0 bits before the next 1 (which is consumed).
fn unary(b: var Bits): int {
  var q = 0
  loop {
    if b.n == 0 {
      if b.pos > b.d.len() + 8 { return q }
      b.acc = if b.pos < b.d.len() { b.d[b.pos] } else { 0 }
      b.pos += 1
      b.n = 8
    }
    if b.acc == 0 {
      q += b.n
      b.n = 0
    } else {
      while (b.acc >> (b.n - 1)) == 0 {
        b.n -= 1
        q += 1
      }
      b.n -= 1
      b.acc = b.acc & (1 << b.n) - 1
      return q
    }
  }
}

// The byte position of the next unread bit, after dropping the rest of the current byte.
fn align(b: var Bits): int {
  b.n -= b.n % 8
  b.acc = b.acc & (1 << b.n) - 1
  b.pos - b.n / 8
}

// ---- metadata ----

struct Stream {
  rate: int,
  nch: int,
  bps: int,
  total: int,
  max_block: int,
  tags: {str: str},
  frames_at: int,
}

pub fn id3_offset(d: [int]): int {
  if d.len() >= 10 && audio.pcm.tag(d, 0).starts_with("ID3") {
    let size = (d[6] << 21) | (d[7] << 14) | (d[8] << 7) | d[9]
    10 + size + if (d[5] & 0x10) != 0 { 10 } else { 0 }
  } else {
    0
  }
}

fn comments(d: [int], at: int, end: int): {str: str} {
  var tags: {str: str} = {}
  if at + 8 > end { return tags }
  var p = at + 4 + audio.pcm.u32le(d, at)
  if p + 4 > end { return tags }
  let n = audio.pcm.u32le(d, p)
  p += 4
  for _ in 0..n {
    if p + 4 > end { break }
    let len = audio.pcm.u32le(d, p)
    if p + 4 + len > end { break }
    let s = str.from_utf8(d[p + 4..p + 4 + len]) else ""
    match s.find("=") {
      some(i) => {
        let k = s[0..i].lower()
        let v = s[i + 1..s.len()]
        tags[k] = if tags.contains(k) { tags[k] + "; " + v } else { v }
      }
      none => {}
    }
    p += 4 + len
  }
  tags
}

fn stream(d: [int]): Stream!audio.AErr {
  let start = id3_offset(d)
  if d.len() < start + 4 + 38 { fail(audio.Truncated("FLAC header")) }
  if audio.pcm.tag(d, start) != "fLaC" { fail(audio.Corrupt("not a FLAC file")) }
  var s = Stream { rate: 0, nch: 0, bps: 0, total: 0, max_block: 0, tags: {}, frames_at: 0 }
  var p = start + 4
  var seen = false
  loop {
    if p + 4 > d.len() { fail(audio.Truncated("FLAC metadata")) }
    let last = (d[p] & 0x80) != 0
    let kind = d[p] & 0x7f
    let len = audio.pcm.u24be(d, p + 1)
    let body = p + 4
    if body + len > d.len() { fail(audio.Truncated("FLAC metadata block")) }
    if kind == 0 {
      if len < 34 { fail(audio.Corrupt("FLAC STREAMINFO is {len} bytes")) }
      s.max_block = audio.pcm.u16be(d, body + 2)
      let x = audio.pcm.u64be(d, body + 10)
      s.rate = (x >> 44) & 0xfffff
      s.nch = ((x >> 41) & 7) + 1
      s.bps = ((x >> 36) & 31) + 1
      s.total = x & 0xfffffffff
      seen = true
    } else if kind == 4 {
      s.tags = comments(d, body, body + len)
    }
    p = body + len
    if last { break }
  }
  if !seen { fail(audio.Corrupt("FLAC file has no STREAMINFO")) }
  s.frames_at = p
  s
}

// ---- decoding frames ----

let RATES = [0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000]
let SIZES = [0, 8, 12, 0, 16, 20, 24, 32]

fn block_size(code: int): int = if code == 1 {
  192
} else if code <= 5 {
  576 << (code - 2)
} else {
  256 << (code - 8)
}

// Reads one subframe of `n` samples at `bps` bits.
fn subframe(b: var Bits, n: int, bps0: int): [int]! {
  if b.rd(1) != 0 { fail("subframe padding bit is set") }
  let kind = b.rd(6)
  var wasted = 0
  if b.rd(1) == 1 { wasted = b.unary() + 1 }
  let bps = bps0 - wasted
  if bps < 1 { fail("{wasted} wasted bits in a {bps0}-bit subframe") }
  var out: [int] = []
  if kind == 0 {
    let v = b.srd(bps)
    for _ in 0..n { out.push(v) }
  } else if kind == 1 {
    for _ in 0..n { out.push(b.srd(bps)) }
  } else if kind >= 8 && kind <= 12 {
    let order = kind - 8
    if order > n { fail("fixed order {order} for {n} samples") }
    for _ in 0..order { out.push(b.srd(bps)) }
    residual(&b, n, order, &out)?
    fixed_restore(&out, order)
  } else if kind >= 32 {
    let order = kind - 31
    if order > n { fail("LPC order {order} for {n} samples") }
    for _ in 0..order { out.push(b.srd(bps)) }
    let prec = b.rd(4) + 1
    if prec == 16 { fail("invalid LPC coefficient precision") }
    let shift = b.srd(5)
    if shift < 0 { fail("negative LPC shift {shift}") }
    var coefs: [int] = []
    for _ in 0..order { coefs.push(b.srd(prec)) }
    residual(&b, n, order, &out)?
    // Wrapping arithmetic: in a valid stream nothing overflows, while a damaged frame (caught
    // by its CRC-16 once its subframes are read) mustn't panic first.
    for i in order..n {
      var sum = 0
      for j in 0..order { sum = sum +% coefs[j] *% out[i - 1 - j] }
      out[i] = out[i] +% (sum >> shift)
    }
  } else {
    fail("reserved subframe type {kind}")
  }
  if wasted > 0 {
    for i in 0..n { out[i] = out[i] << wasted }
  }
  out
}

// Wrapping arithmetic, as for LPC: a damaged frame mustn't overflow before its CRC is checked.
fn fixed_restore(s: var [int], order: int) {
  let n = s.len()
  match order {
    0 => {}
    1 => for i in 1..n { s[i] = s[i] +% s[i - 1] }
    2 => for i in 2..n { s[i] = s[i] +% 2 *% s[i - 1] -% s[i - 2] }
    3 => for i in 3..n { s[i] = s[i] +% 3 *% s[i - 1] -% 3 *% s[i - 2] +% s[i - 3] }
    _ => for i in 4..n {
      s[i] = s[i] +% 4 *% s[i - 1] -% 6 *% s[i - 2] +% 4 *% s[i - 3] -% s[i - 4]
    }
  }
}

fn residual(b: var Bits, n: int, order: int, out: var [int]): ()! {
  let method = b.rd(2)
  if method > 1 { fail("reserved residual coding method {method}") }
  let pbits = 4 + method
  let esc = (1 << pbits) - 1
  let porder = b.rd(4)
  let psize = n >> porder
  if (psize << porder) != n || psize < order { fail("partition order {porder} for {n} samples") }
  let d = b.d
  let len = d.len()
  for p in 0..(1 << porder) {
    let cnt = if p == 0 { psize - order } else { psize }
    let k = b.rd(pbits)
    if k == esc {
      let nb = b.rd(5)
      for _ in 0..cnt { out.push(b.srd(nb)) }
    } else {
      // Rice codes: `unary` then `rd(k)`, on local copies of the reader's state
      var pos = b.pos
      var acc = b.acc
      var nb = b.n
      for _ in 0..cnt {
        var q = 0
        loop {
          if nb == 0 {
            if pos > len + 8 { break }
            acc = if pos < len { d[pos] } else { 0 }
            pos += 1
            nb = 8
          }
          if acc == 0 {
            q += nb
            nb = 0
          } else {
            while (acc >> (nb - 1)) == 0 {
              nb -= 1
              q += 1
            }
            nb -= 1
            acc = acc & (1 << nb) - 1
            break
          }
        }
        var low = 0
        if k != 0 {
          while nb < k {
            acc = (acc << 8) | if pos < len { d[pos] } else { 0 }
            pos += 1
            nb += 8
          }
          nb -= k
          low = acc >> nb
          acc = acc & (1 << nb) - 1
        }
        let v = (q << k) | low
        out.push((v >> 1) ^ -(v & 1))
      }
      b.pos = pos
      b.acc = acc
      b.n = nb
    }
    if b.over() { fail("truncated") }
  }
}

// One frame: (frames decoded, next byte position), with each channel's samples appended to
// `chans` as integers.
fn frame(d: [int], at: int, s: Stream, chans: var [[int]]): (int, int)! {
  var b = Bits { d, pos: at, acc: 0, n: 0 }
  if b.rd(15) != 0x7ffc { fail("lost frame sync at byte {at}") }
  b.rd(1)  // blocking strategy: fixed or variable, the decoder needn't care
  let bs_code = b.rd(4)
  let rate_code = b.rd(4)
  let ch_code = b.rd(4)
  let size_code = b.rd(3)
  b.rd(1)
  // the frame or sample number, UTF-8 style
  let first = b.rd(8)
  var extra = 0
  while extra < 7 && (first & (0x80 >> extra)) != 0 { extra += 1 }
  if extra == 1 || extra == 7 { fail("bad frame number at byte {at}") }
  for _ in 1..if extra == 0 { 1 } else { extra } { b.rd(8) }
  let n = if bs_code == 6 {
    b.rd(8) + 1
  } else if bs_code == 7 {
    b.rd(16) + 1
  } else if bs_code == 0 {
    fail("reserved block size at byte {at}")
  } else {
    block_size(bs_code)
  }
  if rate_code == 12 {
    b.rd(8)
  } else if rate_code == 13 || rate_code == 14 {
    b.rd(16)
  } else if rate_code == 15 {
    fail("invalid sample rate code at byte {at}")
  }
  let hend = b.align()
  if b.over() { fail("truncated") }
  if b.rd(8) != crc8(d, at, hend) { fail("frame header CRC-8 mismatch at byte {at}") }
  let bps = if size_code == 0 { s.bps } else { SIZES[size_code] }
  if bps == 0 { fail("reserved sample size at byte {at}") }
  let nch = if ch_code < 8 {
    ch_code + 1
  } else if ch_code <= 10 {
    2
  } else {
    fail("reserved channel assignment at byte {at}")
  }
  if nch != s.nch { fail("frame at byte {at} has {nch} channels, the stream {s.nch}") }
  var subs: [[int]] = []
  for c in 0..nch {
    let side = (ch_code == 8 && c == 1) || (ch_code == 9 && c == 0) || (ch_code == 10 && c == 1)
    let out = subframe(
      &b,
      n,
      bps + if side { 1 } else { 0 },
    ) else e => fail("{e} (frame at byte {at})")
    subs.push(out)
  }
  let fend = b.align()
  if b.over() { fail("truncated") }
  if b.rd(16) != crc16(d, at, fend) { fail("frame CRC-16 mismatch at byte {at}") }
  // undo stereo decorrelation (on the two lists as locals, so the writes are in place)
  if ch_code >= 8 {
    var l = subs[0]
    var r = subs[1]
    subs = []
    // wrapping: a frame can pass its CRC and still hold samples out of range
    if ch_code == 8 {
      for i in 0..n { r[i] = l[i] -% r[i] }
    } else if ch_code == 9 {
      for i in 0..n { l[i] = l[i] +% r[i] }
    } else {
      for i in 0..n {
        let side = r[i]
        let mid = (l[i] << 1) | (side & 1)
        l[i] = (mid +% side) >> 1
        r[i] = (mid -% side) >> 1
      }
    }
    subs = [l, r]
  }
  if bps != s.bps { fail("frame at byte {at} has {bps} bits per sample, the stream {s.bps}") }
  for c in 0..nch {
    var ch = chans[c]
    for v in subs[c] { ch.push(v) }
    chans[c] = ch
  }
  (n, fend + 2)
}

fn info_of(s: Stream): audio.Info = audio.Info {
  container: "flac",
  codec: "flac",
  rate: s.rate,
  channels: s.nch,
  frames: s.total,
  bits: s.bps,
  tags: s.tags,
}

pub fn probe(d: [int]): audio.Info!audio.AErr = info_of(stream(d)?)

pub fn decode(d: [int]): audio.Audio!audio.AErr {
  let s = stream(d)?
  if s.rate < 1 { fail(audio.Unsupported("FLAC stream without a sample rate")) }
  var ints: [[int]] = []
  for _ in 0..s.nch { ints.push([]) }
  var p = s.frames_at
  var got = 0
  while p + 2 <= d.len() && (s.total == 0 || got < s.total) {
    let (n, next) = frame(d, p, s, &ints) else e => {
      if "{e}".starts_with("truncated") { fail(audio.Truncated("FLAC frame at byte {p}")) }
      fail(audio.Corrupt("{e}"))
    }
    got += n
    p = next
  }
  if s.total > 0 && got < s.total {
    fail(audio.Truncated("FLAC stream ({got} of {s.total} frames)"))
  }
  let scale = 1.0 / float(1 << (s.bps - 1))
  let chans = ints.map(ch => {
    var out: [float] = []
    let n = if s.total > 0 && ch.len() > s.total { s.total } else { ch.len() }
    for i in 0..n { out.push(float(ch[i]) * scale) }
    out
  })
  audio.Audio { rate: s.rate, chans, tags: s.tags }
}

// ---- writing bits ----

struct W { out: [int], acc: int, n: int }

fn put(w: var W, v: int, k: int) {
  if k == 0 { return }
  w.acc = (w.acc << k) | (v & (1 << k) - 1)
  w.n += k
  while w.n >= 8 {
    w.n -= 8
    w.out.push((w.acc >> w.n) & 0xff)
  }
  w.acc = w.acc & (1 << w.n) - 1
}

fn put_zeros(w: var W, q: int) {
  var left = q
  while left >= 32 {
    w.put(0, 32)
    left -= 32
  }
  w.put(0, left)
}

fn flush(w: var W) {
  if w.n > 0 { w.put(0, 8 - w.n) }
}

fn utf8_num(w: var W, v: int) {
  if v < 0x80 {
    w.put(v, 8)
  } else {
    var extra = 1
    while v >= (1 << (5 * extra + 6)) { extra += 1 }
    let lead = (0xff00 >> (extra + 1)) & 0xff
    w.put(lead | (v >> (6 * extra)), 8)
    var i = extra - 1
    while i >= 0 {
      w.put(0x80 | (v >> (6 * i)) & 0x3f, 8)
      i -= 1
    }
  }
}

// ---- choosing a subframe ----

// One way to code a subframe. kind: 0 constant, 1 verbatim, 2 fixed, 3 LPC.
struct Plan {
  kind: int,
  order: int,
  coefs: [int],
  prec: int,
  shift: int,
  wasted: int,
  bps: int,    // after removing wasted bits
  res: [int],  // the residual (kind 2 and 3)
  porder: int,
  params: [int],  // a Rice parameter per partition
  bits: int,      // the coded size
}

// The finest partition order for `n` samples predicted at `order`: partitions must divide n and
// hold more than `order` samples.
fn max_porder(n: int, order: int): int {
  var maxp = 0
  while maxp < 6 && (n % (2 << maxp)) == 0 && (n >> (maxp + 1)) > order { maxp += 1 }
  maxp
}

// The best partition order and Rice parameters, (porder, params, bits), for a residual of
// n - order values whose zigzagged sums per partition at order `maxp` are `sums0`.
fn rice(sums0: [int], n: int, order: int, maxp: int): (int, [int], int) {
  var sums = sums0
  var best = (0, [0], -1)
  var po = maxp
  while po >= 0 {
    let np = 1 << po
    var params: [int] = []
    var bits = 0
    var big = false
    for p in 0..np {
      let cnt = (n >> po) - if p == 0 { order } else { 0 }
      let s = sums[p]
      // the cost of parameter k is about cnt * (k + 1) + s / 2^k: take the k where it stops falling
      var k = 0
      var cost = cnt + s
      while k < 30 {
        let next = cnt * (k + 2) + (s >> (k + 1))
        if next >= cost { break }
        cost = next
        k += 1
      }
      params.push(k)
      if k > 14 { big = true }
      bits += cost
    }
    let pbits = if big { 5 } else { 4 }
    bits += 6 + np * pbits
    if best.2 < 0 || bits < best.2 { best = (po, params, bits) }
    // merge pairs of partitions for the next order down
    if po > 0 {
      var merged: [int] = []
      for p in 0..(np / 2) { merged.push(sums[2 * p] + sums[2 * p + 1]) }
      sums = merged
    }
    po -= 1
  }
  best
}

// The sums of the zigzagged residuals of `res` (n - order values) in each of the 2^maxp
// partitions, and the OR of them all (which is below 2^32 exactly when every residual fits in 32
// bits).
fn res_sums(res: [int], n: int, order: int, maxp: int): ([int], int) {
  let psize = n >> maxp
  var sums: [int] = []
  var any = 0
  var i = 0
  for p in 0..(1 << maxp) {
    let end = (p + 1) * psize - order
    var s = 0
    while i < end {
      let r = res[i]
      let u = (r << 1) ^ (r >> 63)
      s += u
      any = any | u
      i += 1
    }
    sums.push(s)
  }
  (sums, any)
}

// `res_sums` of the fixed predictor's residual, without building it. Samples have at most 25
// bits, so nothing here can overflow.
fn fixed_sums(x: [int], order: int, maxp: int): ([int], int) {
  let n = x.len()
  let psize = n >> maxp
  var sums: [int] = []
  var any = 0
  var t = order
  for p in 0..(1 << maxp) {
    let end = (p + 1) * psize
    var s = 0
    if order == 0 {
      while t < end {
        let r = x[t]
        let u = (r << 1) ^ (r >> 63)
        s = s +% u
        any = any | u
        t += 1
      }
    } else if order == 1 {
      while t < end {
        let r = x[t] -% x[t - 1]
        let u = (r << 1) ^ (r >> 63)
        s = s +% u
        any = any | u
        t += 1
      }
    } else if order == 2 {
      while t < end {
        let r = x[t] -% 2 *% x[t - 1] +% x[t - 2]
        let u = (r << 1) ^ (r >> 63)
        s = s +% u
        any = any | u
        t += 1
      }
    } else if order == 3 {
      while t < end {
        let r = x[t] -% 3 *% x[t - 1] +% 3 *% x[t - 2] -% x[t - 3]
        let u = (r << 1) ^ (r >> 63)
        s = s +% u
        any = any | u
        t += 1
      }
    } else {
      while t < end {
        let r = x[t] -% 4 *% x[t - 1] +% 6 *% x[t - 2] -% 4 *% x[t - 3] +% x[t - 4]
        let u = (r << 1) ^ (r >> 63)
        s = s +% u
        any = any | u
        t += 1
      }
    }
    sums.push(s)
  }
  (sums, any)
}

// `fixed_sums` for orders 0 to 4 in one pass: each order's sums, then each order's OR. Needs
// more than 4 samples and partitions of more than 4 (so every order has the same partitions).
// The order-k residual is the difference of two neighbouring order-(k-1) residuals.
fn fixed_sums5(x: [int], maxp: int): ([[int]], [int]) {
  let n = x.len()
  let psize = n >> maxp
  var t0: [int] = []
  var t1: [int] = []
  var t2: [int] = []
  var t3: [int] = []
  var t4: [int] = []
  var a0 = 0
  var a1 = 0
  var a2 = 0
  var a3 = 0
  var a4 = 0
  // the previous sample and the previous residual of orders 1 to 3
  var e0 = 0
  var e1 = 0
  var e2 = 0
  var e3 = 0
  var s0 = 0
  var s1 = 0
  var s2 = 0
  var s3 = 0
  var s4 = 0
  // the first four samples: order k starts at sample k
  for t in 0..4 {
    let d0 = x[t]
    let d1 = d0 -% e0
    let d2 = d1 -% e1
    let d3 = d2 -% e2
    e0 = d0
    e1 = d1
    e2 = d2
    e3 = d3
    let u0 = (d0 << 1) ^ (d0 >> 63)
    s0 = s0 +% u0
    a0 = a0 | u0
    if t >= 1 {
      let u1 = (d1 << 1) ^ (d1 >> 63)
      s1 = s1 +% u1
      a1 = a1 | u1
    }
    if t >= 2 {
      let u2 = (d2 << 1) ^ (d2 >> 63)
      s2 = s2 +% u2
      a2 = a2 | u2
    }
    if t >= 3 {
      let u3 = (d3 << 1) ^ (d3 >> 63)
      s3 = s3 +% u3
      a3 = a3 | u3
    }
  }
  var t = 4
  for p in 0..(1 << maxp) {
    let end = (p + 1) * psize
    while t < end {
      let d0 = x[t]
      let d1 = d0 -% e0
      let d2 = d1 -% e1
      let d3 = d2 -% e2
      let d4 = d3 -% e3
      e0 = d0
      e1 = d1
      e2 = d2
      e3 = d3
      let u0 = (d0 << 1) ^ (d0 >> 63)
      let u1 = (d1 << 1) ^ (d1 >> 63)
      let u2 = (d2 << 1) ^ (d2 >> 63)
      let u3 = (d3 << 1) ^ (d3 >> 63)
      let u4 = (d4 << 1) ^ (d4 >> 63)
      s0 = s0 +% u0
      s1 = s1 +% u1
      s2 = s2 +% u2
      s3 = s3 +% u3
      s4 = s4 +% u4
      a0 = a0 | u0
      a1 = a1 | u1
      a2 = a2 | u2
      a3 = a3 | u3
      a4 = a4 | u4
      t += 1
    }
    t0.push(s0)
    t1.push(s1)
    t2.push(s2)
    t3.push(s3)
    t4.push(s4)
    s0 = 0
    s1 = 0
    s2 = 0
    s3 = 0
    s4 = 0
  }
  ([t0, t1, t2, t3, t4], [a0, a1, a2, a3, a4])
}

fn fixed_res(x: [int], order: int): [int] {
  let n = x.len()
  var r: [int] = []
  match order {
    0 => for i in 0..n { r.push(x[i]) }
    1 => for i in 1..n { r.push(x[i] -% x[i - 1]) }
    2 => for i in 2..n { r.push(x[i] -% 2 *% x[i - 1] +% x[i - 2]) }
    3 => for i in 3..n { r.push(x[i] -% 3 *% x[i - 1] +% 3 *% x[i - 2] -% x[i - 3]) }
    _ => for i in 4..n {
      r.push(x[i] -% 4 *% x[i - 1] +% 6 *% x[i - 2] -% 4 *% x[i - 3] +% x[i - 4])
    }
  }
  r
}

// A subframe's size in bits before its residual.
fn head_bits(kind: int, order: int, prec: int, bps: int, wasted: int): int = 8 +
  if wasted > 0 { wasted } else { 0 } +
  order * bps +
  if kind == 3 {
    4 + 5 + order * prec
  } else {
    0
  }

// The Tukey(0.5) window.
fn tukey(n: int): [float] {
  let np = n / 4
  (0..n).map(i => {
    if np < 1 {
      1.0
    } else if i < np {
      0.5 - 0.5 * cos(float.pi * float(i) / float(np))
    } else if i >= n - np {
      0.5 - 0.5 * cos(float.pi * float(n - 1 - i) / float(np))
    } else {
      1.0
    }
  })
}

// Levinson-Durbin: the predictor coefficients for each order 1..max, and each order's error.
fn levinson(r: [float], max: int): ([[float]], [float]) {
  var lpcs: [[float]] = []
  var errs: [float] = []
  var a: [float] = []
  var err = r[0]
  for i in 0..max {
    if err <= 0.0 { break }
    var acc = -r[i + 1]
    for j in 0..i { acc -= a[j] * r[i - j] }
    let k = acc / err
    var next = a
    next.push(k)
    for j in 0..i { next[j] = a[j] + k * a[i - 1 - j] }
    a = next
    err *= 1.0 - k * k
    // a predicts with -a: x[t] ~ sum(-a[j] * x[t - 1 - j])
    lpcs.push(a.map(c => -c))
    errs.push(err)
  }
  (lpcs, errs)
}

fn ilog2(v: int): int {
  var e = 0
  while (v >> (e + 1)) > 0 { e += 1 }
  e
}

// Quantizes coefficients to `prec` bits: (coefs, shift), or none if they don't fit.
fn quantize(lp: [float], prec: int): ([int], int)? {
  let cmax = lp.map(c => abs(c)).max()?
  if cmax <= 0.0 { return none }
  let log2cmax = int(floor(log2(cmax)))
  var shift = prec - 1 - log2cmax - 1
  if shift > 15 { shift = 15 }
  if shift < 0 { return none }
  let qmax = (1 << (prec - 1)) - 1
  let qmin = -(1 << (prec - 1))
  var err = 0.0
  var q: [int] = []
  for c in lp {
    err += c * float(1 << shift)
    var v = int(round(err))
    if v > qmax { v = qmax } else if v < qmin { v = qmin }
    err -= float(v)
    q.push(v)
  }
  some((q, shift))
}

// Samples have at most 25 bits and coefficients 15, so nothing here can overflow.
fn lpc_res(x: [int], q: [int], shift: int): [int] {
  let order = q.len()
  var r: [int] = []
  for i in order..x.len() {
    var sum = 0
    for j in 0..order { sum = sum +% q[j] *% x[i - 1 - j] }
    r.push(x[i] -% (sum >> shift))
  }
  r
}

fn precision(n: int): int = if n <= 192 {
  7
} else if n <= 384 {
  8
} else if n <= 576 {
  9
} else if n <= 1152 {
  10
} else if n <= 2304 {
  11
} else if n <= 4608 {
  12
} else {
  13
}

// The autocorrelation of `xf` (more than 8 values) at lags 0 to 8. Each lag's sum adds its
// terms in index order; the nine sums advance together.
fn autocorr8(xf: [float]): [float] {
  let n = xf.len()
  var r: [float] = []
  for lag in 0..9 {
    var s = 0.0
    for i in lag..8 { s += xf[i] * xf[i - lag] }
    r.push(s)
  }
  var s0 = r[0]
  var s1 = r[1]
  var s2 = r[2]
  var s3 = r[3]
  var s4 = r[4]
  var s5 = r[5]
  var s6 = r[6]
  var s7 = r[7]
  var s8 = r[8]
  for i in 8..n {
    let v = xf[i]
    s0 += v * v
    s1 += v * xf[i - 1]
    s2 += v * xf[i - 2]
    s3 += v * xf[i - 3]
    s4 += v * xf[i - 4]
    s5 += v * xf[i - 5]
    s6 += v * xf[i - 6]
    s7 += v * xf[i - 7]
    s8 += v * xf[i - 8]
  }
  [s0, s1, s2, s3, s4, s5, s6, s7, s8]
}

// `win` is the Tukey window for the usual block size (used when it is `x0`'s size).
fn best_subframe(x0: [int], bps0: int, win: [float]): Plan {
  let n = x0.len()
  let verbatim = Plan {
    kind: 1,
    order: 0,
    coefs: [],
    prec: 0,
    shift: 0,
    wasted: 0,
    bps: bps0,
    res: [],
    porder: 0,
    params: [],
    bits: 8 + n * bps0,
  }
  // constant, and wasted bits: trailing zeros common to every sample
  var same = true
  var all = 0
  if n > 0 {
    let first = x0[0]
    for v in x0 {
      if v != first { same = false }
      all = all | v
    }
  }
  if same { return Plan { kind: 0, bits: 8 + bps0, ..verbatim } }
  var wasted = 0
  while wasted < bps0 - 1 && ((all >> wasted) & 1) == 0 { wasted += 1 }
  let x = if wasted > 0 { x0.map(v => v >> wasted) } else { x0 }
  let bps = bps0 - wasted
  var best = verbatim
  // the fixed predictors: size each from its partition sums, and build only the winner's residual
  var fo = -1
  var fbest = (0, [0], -1)
  // usually all five orders have the same partitions, and one pass sizes them all
  let maxp4 = if n > 4 { max_porder(n, 4) } else { -1 }
  let together = maxp4 >= 0 && maxp4 == max_porder(n, 0) && (n >> maxp4) > 4
  let (sums5, any5) = if together { fixed_sums5(x, maxp4) } else { ([], []) }
  for order in 0..5 {
    if order < n {
      let maxp = if together { maxp4 } else { max_porder(n, order) }
      let (sums, any) = if together {
        (sums5[order], any5[order])
      } else {
        fixed_sums(x, order, maxp)
      }
      if (any >> 32) == 0 {
        let r = rice(sums, n, order, maxp)
        let bits = head_bits(2, order, 0, bps, wasted) + r.2
        if bits < if fo < 0 { best.bits } else { head_bits(2, fo, 0, bps, wasted) + fbest.2 } {
          fo = order
          fbest = r
        }
      }
    }
  }
  if fo >= 0 {
    best = Plan {
      kind: 2,
      order: fo,
      coefs: [],
      prec: 0,
      shift: 0,
      wasted,
      bps,
      res: [],
      porder: fbest.0,
      params: fbest.1,
      bits: head_bits(2, fo, 0, bps, wasted) + fbest.2,
    }
  }
  let maxo = if n > 16 { 8 } else { 0 }
  if maxo > 0 {
    let w = if win.len() == n { win } else { tukey(n) }
    var xf: [float] = []
    for i in 0..n { xf.push(float(x[i]) * w[i]) }
    let r = autocorr8(xf)
    let (lpcs, errs) = levinson(r, maxo)
    if lpcs.len() > 0 {
      // estimate each order's size from its prediction error, then code the best
      var bo = 0
      var bbits = -1.0
      for i in 0..lpcs.len() {
        let order = i + 1
        let e = errs[i] * 0.5 / float(n)
        let per = if e > 0.0 { 0.5 * log2(e) } else { 0.0 }
        let est =
          if per > 0.0 { per } else { 0.0 } * float(n - order) + float(order * (bps + precision(n)))
        if bbits < 0.0 || est < bbits {
          bbits = est
          bo = order
        }
      }
      var prec = precision(n)
      let room = 32 - bps - ilog2(bo)
      if room < prec { prec = room }
      if prec >= 5 {
        match quantize(lpcs[bo - 1], prec) {
          some((q, shift)) => {
            let res = lpc_res(x, q, shift)
            let maxp = max_porder(n, bo)
            let (sums, any) = res_sums(res, n, bo, maxp)
            if (any >> 32) == 0 {
              let (porder, params, rbits) = rice(sums, n, bo, maxp)
              let bits = head_bits(3, bo, prec, bps, wasted) + rbits
              if bits < best.bits {
                best = Plan {
                  kind: 3,
                  order: bo,
                  coefs: q,
                  prec,
                  shift,
                  wasted,
                  bps,
                  res,
                  porder,
                  params,
                  bits,
                }
              }
            }
          }
          none => {}
        }
      }
    }
  }
  if best.kind == 2 { best.res = fixed_res(x, best.order) }
  Plan { wasted, bps: if best.kind == 1 || best.kind == 0 { bps0 } else { bps }, ..best }
}

fn put_subframe(w: var W, p: Plan, x: [int]) {
  w.put(0, 1)
  let kind = match p.kind {
    0 => 0
    1 => 1
    2 => 8 + p.order
    _ => 31 + p.order
  }
  w.put(kind, 6)
  // constant and verbatim plans keep the samples as they are
  let wasted = if p.kind >= 2 { p.wasted } else { 0 }
  if wasted > 0 {
    w.put(1, 1)
    w.put_zeros(wasted - 1)
    w.put(1, 1)
  } else {
    w.put(0, 1)
  }
  let bps = p.bps
  if p.kind == 0 {
    w.put(x[0], bps)
    return
  }
  if p.kind == 1 {
    for v in x { w.put(v, bps) }
    return
  }
  for i in 0..p.order { w.put(x[i] >> wasted, bps) }
  if p.kind == 3 {
    w.put(p.prec - 1, 4)
    w.put(p.shift, 5)
    for c in p.coefs { w.put(c, p.prec) }
  }
  let method = if p.params.any(k => k > 14) { 1 } else { 0 }
  let pbits = 4 + method
  w.put(method, 2)
  w.put(p.porder, 4)
  let n = x.len()
  let psize = n >> p.porder
  let res = p.res
  var i = 0
  for part in 0..p.params.len() {
    let k = p.params[part]
    w.put(k, pbits)
    let cnt = if part == 0 { psize - p.order } else { psize }
    // `put` for each code, on local copies of the writer's state (its list is emptied
    // meanwhile, so pushes don't copy)
    var out = w.out
    w.out = []
    var acc = w.acc
    var nb = w.n
    let low = (1 << k) - 1
    for _ in 0..cnt {
      let r = res[i]
      let u = (r << 1) ^ (r >> 63)
      i += 1
      let q = u >> k
      if q + 1 + k <= 32 {
        acc = (acc << (q + 1 + k)) | (1 << k) | (u & low)
        nb += q + 1 + k
        while nb >= 8 {
          nb -= 8
          out.push((acc >> nb) & 0xff)
        }
        acc = acc & (1 << nb) - 1
      } else {
        w.out = out
        w.acc = acc
        w.n = nb
        w.put_zeros(q)
        w.put(1, 1)
        w.put(u, k)
        out = w.out
        w.out = []
        acc = w.acc
        nb = w.n
      }
    }
    w.out = out
    w.acc = acc
    w.n = nb
  }
}

fn rate_code(rate: int): (int, int, int) {
  match RATES.find_index(r => r == rate) {
    some(i) when i > 0 => (i, 0, 0)
    _ => if rate % 1000 == 0 && rate / 1000 < 256 {
      (12, rate / 1000, 8)
    } else if rate < 65536 {
      (13, rate, 16)
    } else if rate % 10 == 0 && rate / 10 < 65536 {
      (14, rate / 10, 16)
    } else {
      (0, 0, 0)
    }
  }
}

fn bs_code(n: int): (int, int, int) {
  if n == 192 { return (1, 0, 0) }
  for c in 2..6 { if n == (576 << (c - 2)) { return (c, 0, 0) } }
  for c in 8..16 { if n == (256 << (c - 8)) { return (c, 0, 0) } }
  if n <= 256 { (6, n - 1, 8) } else { (7, n - 1, 16) }
}

/// A FLAC file with `bits` (8, 12, 16, 20 or 24) bits per sample.
pub fn encode(a: audio.Audio, bits: int): [int]!audio.AErr {
  let nch = a.chans.len()
  if nch < 1 || nch > 8 { fail(audio.BadArg("FLAC holds 1 to 8 channels, not {nch}")) }
  if ![8, 12, 16, 20, 24].contains(bits) {
    fail(audio.BadArg("FLAC bits per sample must be 8, 12, 16, 20 or 24, not {bits}"))
  }
  if a.rate < 1 || a.rate > 655350 { fail(audio.BadArg("FLAC can't hold sample rate {a.rate}")) }
  let total = a.chans[0].len()
  let ints = a.chans.map(ch => ch.map(x => audio.pcm.quant(x, bits)))
  let block = 4096
  let size_code = match bits {
    8 => 1
    12 => 2
    16 => 4
    20 => 5
    _ => 6
  }
  let (rcode, rval, rbits) = rate_code(a.rate)
  let bytes = (bits + 7) / 8
  var md = md5_new()
  let win = if total >= block { tukey(block) } else { [] }
  var w = W { out: [], acc: 0, n: 0 }
  var minf = -1
  var maxf = 0
  var start = 0
  var num = 0
  while start < total {
    let n = if total - start < block { total - start } else { block }
    let xs = ints.map(ch => ch[start..start + n])
    // the MD5 covers the samples interleaved, little-endian, in whole bytes
    var raw: [int] = []
    if nch == 2 && bytes == 2 {
      let l = xs[0]
      let r = xs[1]
      for i in 0..n {
        let a = l[i]
        let b = r[i]
        raw.push(a & 0xff)
        raw.push((a >> 8) & 0xff)
        raw.push(b & 0xff)
        raw.push((b >> 8) & 0xff)
      }
    } else {
      for i in 0..n {
        for c in 0..nch {
          let v = xs[c][i]
          for k in 0..bytes { raw.push((v >> (8 * k)) & 0xff) }
        }
      }
    }
    md.md5_update(raw)
    // pick the channel coding
    var chcode = nch - 1
    var plans: [Plan] = []
    var data: [[int]] = []
    if nch == 2 {
      let l = xs[0]
      let r = xs[1]
      var side: [int] = []
      var mid: [int] = []
      for i in 0..n {
        side.push(l[i] - r[i])
        mid.push((l[i] + r[i]) >> 1)
      }
      let pl = best_subframe(l, bits, win)
      let pr = best_subframe(r, bits, win)
      let ps = best_subframe(side, bits + 1, win)
      let pm = best_subframe(mid, bits, win)
      let opts = [
        (1, pl, pr, l, r),
        (8, pl, ps, l, side),
        (9, ps, pr, side, r),
        (10, pm, ps, mid, side),
      ]
      let o = opts.sort_by(o => o.1.bits + o.2.bits)[0]
      chcode = if o.0 == 1 { 1 } else { o.0 }
      plans = [o.1, o.2]
      data = [o.3, o.4]
    } else {
      data = xs
      plans = xs.map(x => best_subframe(x, bits, win))
    }
    let fstart = w.out.len()
    let (bcode, bval, bbits) = bs_code(n)
    w.put(0xfff8, 16)
    w.put(bcode, 4)
    w.put(rcode, 4)
    w.put(chcode, 4)
    w.put(size_code, 3)
    w.put(0, 1)
    w.utf8_num(num)
    w.put(bval, bbits)
    w.put(rval, rbits)
    w.put(crc8(w.out, fstart, w.out.len()), 8)
    for c in 0..plans.len() { w.put_subframe(plans[c], data[c]) }
    w.flush()
    w.put(crc16(w.out, fstart, w.out.len()), 16)
    let fsize = w.out.len() - fstart
    if minf < 0 || fsize < minf { minf = fsize }
    if fsize > maxf { maxf = fsize }
    start += n
    num += 1
  }
  // STREAMINFO, then the Vorbis comments, then the frames
  let tags = a.tags.keys().filter(k => a.tags[k] != "")
  var head = "fLaC".bytes()
  head.push(0)
  head = head + [0, 0, 34]
  var si = W { out: [], acc: 0, n: 0 }
  si.put(block, 16)
  si.put(block, 16)
  si.put(if minf < 0 { 0 } else { minf }, 24)
  si.put(maxf, 24)
  si.put(a.rate, 20)
  si.put(nch - 1, 3)
  si.put(bits - 1, 5)
  si.put(total >> 32, 4)
  si.put(total & M32, 32)
  head = head + si.out + md.md5_finish()
  var vc: [int] = []
  let vendor = "auk audio 0.1".bytes()
  audio.pcm.put32le(&vc, vendor.len())
  vc = vc + vendor
  audio.pcm.put32le(&vc, tags.len())
  for k in tags {
    let c = (k.upper() + "=" + a.tags[k]).bytes()
    audio.pcm.put32le(&vc, c.len())
    vc = vc + c
  }
  head.push(0x84)
  head = head + [(vc.len() >> 16) & 0xff, (vc.len() >> 8) & 0xff, vc.len() & 0xff] + vc
  head + w.out
}

// ---- tests: damaged frames ----

// A stream of `nch` channels at 16 bits whose one frame of `n` samples has channel assignment
// `ch_code` and the subframes `subs` writes; with `good_crc` false its CRC-16 is wrong.
fn crafted(nch: int, ch_code: int, n: int, subs: (var W) => (), good_crc: bool): [int] {
  let silent = audio.new(8000, (0..nch).map(_ => (0..n).map(_ => 0.0)))
  let s0 = encode(silent, 16)!
  let s = stream(s0)!
  var w = W { out: s0.take(s.frames_at), acc: 0, n: 0 }
  let at = w.out.len()
  w.put(0xfff8, 16)  // sync, fixed block size
  w.put(7, 4)        // block size: 16 bits of n - 1 after the frame number
  w.put(0, 4)        // sample rate and size from STREAMINFO
  w.put(ch_code, 4)
  w.put(0, 4)
  w.put(0, 8)  // frame number 0
  w.put(n - 1, 16)
  w.put(crc8(w.out, at, w.out.len()), 8)
  subs(&w)
  w.flush()
  w.put(crc16(w.out, at, w.out.len()) ^ if good_crc { 0 } else { 1 }, 16)
  w.out
}

// An escaped residual partition (partition order 0) of `count` 31-bit values `v`.
fn escaped(w: var W, count: int, v: int) {
  w.put(0, 2)   // Rice, 4-bit parameters
  w.put(0, 4)   // partition order 0
  w.put(15, 4)  // escape: raw values
  w.put(31, 5)
  for _ in 0..count { w.put(v, 31) }
}

// An LPC order 1 subframe at `bits` bits: warm-up sample `warm`, coefficient `coef`, shift 0,
// and `count` residuals `v`.
fn lpc1(w: var W, bits: int, warm: int, coef: int, count: int, v: int) {
  w.put(64, 8)  // padding 0, LPC order 1, no wasted bits (0 100000 0)
  w.put(warm, bits)
  w.put(14, 4)  // precision 15
  w.put(0, 5)   // shift 0
  w.put(coef, 15)
  w.escaped(count, v)
}

// A fixed order 4 subframe of `n` samples: warm-up 0 and residuals `v`.
fn fixed4(w: var W, n: int, v: int) {
  w.put(24, 8)                    // padding 0, fixed order 4, no wasted bits (0 001100 0)
  for _ in 0..4 { w.put(0, 16) }  // warm-up
  w.escaped(n - 4, v)
}

let BIG = 0x3fffffff

test "FLAC: damaged frames are errors, not overflows" {
  // predictions that outgrow 64 bits before the frame's CRC-16 is read: with a bad CRC the
  // frame is corrupt; with a good one it decodes to nonsense, but doesn't panic
  let lpc = (w: var W) => lpc1(&w, 16, 32767, 16383, 15, BIG)  // times 16383 per sample
  assert decode(crafted(1, 0, 16, lpc, false)) is err(Corrupt(_))
  assert decode(crafted(1, 0, 16, lpc, true)) is ok(_)
  let fixed = (w: var W) => fixed4(&w, 4096, BIG)  // grows as n^4
  assert decode(crafted(1, 0, 4096, fixed, false)) is err(Corrupt(_))
  assert decode(crafted(1, 0, 4096, fixed, true)) is ok(_)
  // stereo decorrelation of samples near +-2^63 (LPC doubling each sample), after a good CRC
  for code in [8, 9, 10] {
    let pair = (w: var W) => {
      // the side channel (the second, or the first for 9) has 17 bits
      lpc1(&w, if code == 9 { 17 } else { 16 }, 0, 2, 33, BIG)
      lpc1(&w, if code == 9 { 16 } else { 17 }, 0, 2, 33, if code == 9 { BIG } else { -BIG })
    }
    assert decode(crafted(2, code, 34, pair, true)) is ok(_)
  }
}
