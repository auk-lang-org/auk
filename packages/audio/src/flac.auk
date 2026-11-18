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
  for j in 0..16 { w.push(audio.pcm.u32le(d, at + 4 * j)) }
  var a = m.h[0]
  var b = m.h[1]
  var c = m.h[2]
  var dd = m.h[3]
  for i in 0..64 {
    var f = 0
    var g = 0
    if i < 16 {
      f = (b & c) | (~b & M32 & dd)
      g = i
    } else if i < 32 {
      f = (dd & b) | (~dd & M32 & c)
      g = (5 * i + 1) % 16
    } else if i < 48 {
      f = b ^ c ^ dd
      g = (3 * i + 5) % 16
    } else {
      f = c ^ (b | (~dd & M32))
      g = (7 * i) % 16
    }
    f = (f + a + MD5_K[i] + w[g]) & M32
    a = dd
    dd = c
    c = b
    let s = MD5_S[i]
    b = (b + (((f << s) | (f >> (32 - s))) & M32)) & M32
  }
  m.h[0] = (m.h[0] + a) & M32
  m.h[1] = (m.h[1] + b) & M32
  m.h[2] = (m.h[2] + c) & M32
  m.h[3] = (m.h[3] + dd) & M32
}

fn md5_update(m: var Md5, d: [int]) {
  m.total += d.len()
  var data = m.buf + d
  var p = 0
  while p + 64 <= data.len() {
    m.md5_block(data, p)
    p += 64
  }
  m.buf = data.skip(p)
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

// Reads one subframe of `n` samples at `bps` bits into `out`.
fn subframe(b: var Bits, n: int, bps0: int, out: var [int]): ()! {
  if b.rd(1) != 0 { fail("subframe padding bit is set") }
  let kind = b.rd(6)
  var wasted = 0
  if b.rd(1) == 1 { wasted = b.unary() + 1 }
  let bps = bps0 - wasted
  if bps < 1 { fail("{wasted} wasted bits in a {bps0}-bit subframe") }
  out = []
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
    for i in order..n {
      var sum = 0
      for j in 0..order { sum += coefs[j] * out[i - 1 - j] }
      out[i] = out[i] + (sum >> shift)
    }
  } else {
    fail("reserved subframe type {kind}")
  }
  if wasted > 0 {
    for i in 0..n { out[i] = out[i] << wasted }
  }
}

fn fixed_restore(s: var [int], order: int) {
  let n = s.len()
  match order {
    0 => {}
    1 => for i in 1..n { s[i] = s[i] + s[i - 1] }
    2 => for i in 2..n { s[i] = s[i] + 2 * s[i - 1] - s[i - 2] }
    3 => for i in 3..n { s[i] = s[i] + 3 * s[i - 1] - 3 * s[i - 2] + s[i - 3] }
    _ => for i in 4..n { s[i] = s[i] + 4 * s[i - 1] - 6 * s[i - 2] + 4 * s[i - 3] - s[i - 4] }
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
  for p in 0..(1 << porder) {
    let cnt = if p == 0 { psize - order } else { psize }
    let k = b.rd(pbits)
    if k == esc {
      let nb = b.rd(5)
      for _ in 0..cnt { out.push(b.srd(nb)) }
    } else {
      for _ in 0..cnt {
        let v = (b.unary() << k) | b.rd(k)
        out.push((v >> 1) ^ -(v & 1))
      }
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
    var out: [int] = []
    subframe(&b, n, bps + if side { 1 } else { 0 }, &out) else e => fail("{e} (frame at byte {at})")
    subs.push(out)
  }
  let fend = b.align()
  if b.over() { fail("truncated") }
  if b.rd(16) != crc16(d, at, fend) { fail("frame CRC-16 mismatch at byte {at}") }
  // undo stereo decorrelation
  if ch_code == 8 {
    for i in 0..n { subs[1][i] = subs[0][i] - subs[1][i] }
  } else if ch_code == 9 {
    for i in 0..n { subs[0][i] = subs[0][i] + subs[1][i] }
  } else if ch_code == 10 {
    for i in 0..n {
      let side = subs[1][i]
      let mid = (subs[0][i] << 1) | (side & 1)
      subs[0][i] = (mid + side) >> 1
      subs[1][i] = (mid - side) >> 1
    }
  }
  if bps != s.bps { fail("frame at byte {at} has {bps} bits per sample, the stream {s.bps}") }
  for c in 0..nch {
    for v in subs[c] { chans[c].push(v) }
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

fn zig(r: int): int = if r >= 0 { r << 1 } else { ((-r) << 1) - 1 }

// The best partition order and Rice parameters for a residual: (porder, params, bits).
fn rice(res: [int], n: int, order: int): (int, [int], int) {
  // the highest order: partitions must divide n and hold more than `order` samples
  var maxp = 0
  while maxp < 6 && (n % (2 << maxp)) == 0 && (n >> (maxp + 1)) > order { maxp += 1 }
  // sums of zigzagged residuals per partition at the finest order
  let parts = 1 << maxp
  let psize = n >> maxp
  var sums = audio.pcm.izeros(parts)
  var i = 0
  for p in 0..parts {
    let cnt = if p == 0 { psize - order } else { psize }
    var s = 0
    for _ in 0..cnt {
      s += zig(res[i])
      i += 1
    }
    sums[p] = s
  }
  var best = (0, [0], -1)
  var po = maxp
  while po >= 0 {
    let np = 1 << po
    var params: [int] = []
    var bits = 0
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
      bits += cost
    }
    let pbits = if params.any(k => k > 14) { 5 } else { 4 }
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

fn fixed_res(x: [int], order: int): [int] {
  let n = x.len()
  var r: [int] = []
  for i in order..n {
    r.push(
      match order {
        0 => x[i]
        1 => x[i] - x[i - 1]
        2 => x[i] - 2 * x[i - 1] + x[i - 2]
        3 => x[i] - 3 * x[i - 1] + 3 * x[i - 2] - x[i - 3]
        _ => x[i] - 4 * x[i - 1] + 6 * x[i - 2] - 4 * x[i - 3] + x[i - 4]
      },
    )
  }
  r
}

fn fits32(r: [int]): bool = r.all(v => v >= -2147483648 && v <= 2147483647)

fn plan_from(
  kind: int,
  order: int,
  coefs: [int],
  prec: int,
  shift: int,
  x: [int],
  bps: int,
  wasted: int,
  res: [int],
): Plan? {
  if !fits32(res) { return none }
  let n = x.len()
  let (porder, params, rbits) = rice(res, n, order)
  let head = 8 +
    if wasted > 0 { wasted } else { 0 } +
    order * bps +
    if kind == 3 { 4 + 5 + order * prec } else { 0 }
  some(Plan {
    kind,
    order,
    coefs,
    prec,
    shift,
    wasted,
    bps,
    res,
    porder,
    params,
    bits: head + rbits,
  })
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

fn lpc_res(x: [int], q: [int], shift: int): [int] {
  let order = q.len()
  var r: [int] = []
  for i in order..x.len() {
    var sum = 0
    for j in 0..order { sum += q[j] * x[i - 1 - j] }
    r.push(x[i] - (sum >> shift))
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

fn best_subframe(x0: [int], bps0: int): Plan {
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
  if x0.all(v => v == x0[0]) {
    return Plan { kind: 0, bits: 8 + bps0, ..verbatim }
  }
  // wasted bits: trailing zeros common to every sample
  var all = 0
  for v in x0 { all = all | v }
  var wasted = 0
  while wasted < bps0 - 1 && ((all >> wasted) & 1) == 0 { wasted += 1 }
  let x = if wasted > 0 { x0.map(v => v >> wasted) } else { x0 }
  let bps = bps0 - wasted
  var best = verbatim
  for order in 0..5 {
    if order < n {
      match plan_from(2, order, [], 0, 0, x, bps, wasted, fixed_res(x, order)) {
        some(p) when p.bits < best.bits => best = p
        _ => {}
      }
    }
  }
  let maxo = if n > 16 { 8 } else { 0 }
  if maxo > 0 {
    let w = tukey(n)
    let xf = (0..n).map(i => float(x[i]) * w[i])
    var r: [float] = []
    for lag in 0..maxo + 1 {
      var s = 0.0
      for i in lag..n { s += xf[i] * xf[i - lag] }
      r.push(s)
    }
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
          some((q, shift)) => match plan_from(
            3,
            bo,
            q,
            prec,
            shift,
            x,
            bps,
            wasted,
            lpc_res(x, q, shift),
          ) {
            some(p) when p.bits < best.bits => best = p
            _ => {}
          }
          none => {}
        }
      }
    }
  }
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
  var i = 0
  for part in 0..p.params.len() {
    let k = p.params[part]
    w.put(k, pbits)
    let cnt = if part == 0 { psize - p.order } else { psize }
    for _ in 0..cnt {
      let u = zig(p.res[i])
      i += 1
      let q = u >> k
      if q + 1 + k <= 32 {
        w.put((1 << k) | (u & (1 << k) - 1), q + 1 + k)
      } else {
        w.put_zeros(q)
        w.put(1, 1)
        w.put(u, k)
      }
    }
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
    for i in 0..n {
      for c in 0..nch {
        let v = xs[c][i]
        for k in 0..bytes { raw.push((v >> (8 * k)) & 0xff) }
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
      let side = (0..n).map(i => l[i] - r[i])
      let mid = (0..n).map(i => (l[i] + r[i]) >> 1)
      let pl = best_subframe(l, bits)
      let pr = best_subframe(r, bits)
      let ps = best_subframe(side, bits + 1)
      let pm = best_subframe(mid, bits)
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
      plans = xs.map(x => best_subframe(x, bits))
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
