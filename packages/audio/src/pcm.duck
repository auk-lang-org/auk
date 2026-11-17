/// Bytes and sample codecs (module `audio.pcm`): integers in either byte order, the PCM sample
/// formats, G.711 A-law and μ-law, and IMA and Microsoft ADPCM. Samples are floats nominally in
/// -1.0..1.0; integer formats scale by 2^(bits-1) (so s16 32767 is 32767/32768), as ffmpeg does.

// ---- integers ----

pub fn u16le(d: [int], i: int): int = d[i] | (d[i + 1] << 8)
pub fn u24le(d: [int], i: int): int = d[i] | (d[i + 1] << 8) | (d[i + 2] << 16)
pub fn u32le(d: [int], i: int): int = d[i] | (d[i + 1] << 8) | (d[i + 2] << 16) | (d[i + 3] << 24)
pub fn u16be(d: [int], i: int): int = (d[i] << 8) | d[i + 1]
pub fn u24be(d: [int], i: int): int = (d[i] << 16) | (d[i + 1] << 8) | d[i + 2]
pub fn u32be(d: [int], i: int): int = (d[i] << 24) | (d[i + 1] << 16) | (d[i + 2] << 8) | d[i + 3]
pub fn u64le(d: [int], i: int): int = u32le(d, i) | (u32le(d, i + 4) << 32)
pub fn u64be(d: [int], i: int): int = (u32be(d, i) << 32) | u32be(d, i + 4)

/// `v` (an unsigned `bits`-bit value) as a two's complement signed value.
pub fn sext(v: int, bits: int): int = if v >= (1 << (bits - 1)) { v - (1 << bits) } else { v }

pub fn put8(out: var [int], v: int) { out.push(v & 0xff) }

pub fn put16le(out: var [int], v: int) {
  out.push(v & 0xff)
  out.push((v >> 8) & 0xff)
}

pub fn put32le(out: var [int], v: int) {
  out.push(v & 0xff)
  out.push((v >> 8) & 0xff)
  out.push((v >> 16) & 0xff)
  out.push((v >> 24) & 0xff)
}

pub fn put16be(out: var [int], v: int) {
  out.push((v >> 8) & 0xff)
  out.push(v & 0xff)
}

pub fn put32be(out: var [int], v: int) {
  out.push((v >> 24) & 0xff)
  out.push((v >> 16) & 0xff)
  out.push((v >> 8) & 0xff)
  out.push(v & 0xff)
}

/// Four bytes at `i` as text (a RIFF/AIFF chunk id); `?` for bytes that aren't printable ASCII.
pub fn tag(d: [int], i: int): str {
  if i + 4 > d.len() { return "" }
  str(d[i..i + 4].map(b => if b >= 32 && b < 127 { char(b) else '?' } else { '?' }))
}

/// Text from bytes, dropping NULs (RIFF INFO strings end with one or more).
pub fn text(d: [int]): str = str.from_utf8(d.filter(b => b != 0)) else ""

pub fn zeros(n: int): [float] {
  var xs: [float] = []
  for _ in 0..n { xs.push(0.0) }
  xs
}

pub fn izeros(n: int): [int] {
  var xs: [int] = []
  for _ in 0..n { xs.push(0) }
  xs
}

// ---- sample formats ----

/// Bytes per sample in a byte-aligned format (0 for ADPCM).
pub fn width(f: audio.Fmt): int = match f {
  audio.U8 => 1
  audio.S8 => 1
  audio.S16 => 2
  audio.S24 => 3
  audio.S32 => 4
  audio.F32 => 4
  audio.F64 => 8
  audio.Alaw => 1
  audio.Ulaw => 1
  audio.Ima => 0
}

/// Significant bits per sample (what ffprobe calls bits_per_sample).
pub fn bits(f: audio.Fmt): int = match f {
  audio.Ima => 4
  audio.Alaw => 8
  audio.Ulaw => 8
  f => width(f) * 8
}

/// `x` rounded to a `bits`-bit signed integer, clipped to its range.
pub fn quant(x: float, bits: int): int {
  let top = 1 << (bits - 1)
  if !(x == x) { return 0 }  // NaN
  let v = x * float(top)
  if v >= float(top - 1) { top - 1 } else if v <= -float(top) { -top } else { int(round(v)) }
}

/// Decodes `n` interleaved frames of `nch` channels starting at byte `at`.
pub fn decode(d: [int], at: int, n: int, nch: int, f: audio.Fmt, big: bool): [[float]] {
  var chans: [[float]] = []
  for _ in 0..nch { chans.push([]) }
  let w = width(f)
  var p = at
  for _ in 0..n {
    for c in 0..nch {
      chans[c].push(sample(d, p, f, big))
      p += w
    }
  }
  chans
}

fn sample(d: [int], p: int, f: audio.Fmt, big: bool): float = match f {
  audio.U8 => float(d[p] - 128) / 128.0
  audio.S8 => float(sext(d[p], 8)) / 128.0
  audio.S16 => float(sext(if big { u16be(d, p) } else { u16le(d, p) }, 16)) / 32768.0
  audio.S24 => float(sext(if big { u24be(d, p) } else { u24le(d, p) }, 24)) / 8388608.0
  audio.S32 => float(sext(if big { u32be(d, p) } else { u32le(d, p) }, 32)) / 2147483648.0
  audio.F32 => float.from_bits32(if big { u32be(d, p) } else { u32le(d, p) })
  audio.F64 => float.from_bits(if big { u64be(d, p) } else { u64le(d, p) })
  audio.Alaw => float(ALAW[d[p]]) / 32768.0
  audio.Ulaw => float(ULAW[d[p]]) / 32768.0
  audio.Ima => 0.0
}

/// Interleaves and encodes every frame of `chans`.
pub fn encode(chans: [[float]], f: audio.Fmt, big: bool): [int] {
  var out: [int] = []
  let n = if chans.len() == 0 { 0 } else { chans[0].len() }
  for i in 0..n {
    for ch in chans { put_sample(&out, ch[i], f, big) }
  }
  out
}

fn put_sample(out: var [int], x: float, f: audio.Fmt, big: bool) {
  match f {
    audio.U8 => out.push(quant(x, 8) + 128)
    audio.S8 => out.push(quant(x, 8) & 0xff)
    audio.S16 => if big { put16be(&out, quant(x, 16)) } else { put16le(&out, quant(x, 16)) }
    audio.S24 => {
      let v = quant(x, 24)
      if big {
        out.push((v >> 16) & 0xff)
        out.push((v >> 8) & 0xff)
        out.push(v & 0xff)
      } else {
        out.push(v & 0xff)
        out.push((v >> 8) & 0xff)
        out.push((v >> 16) & 0xff)
      }
    }
    audio.S32 => if big { put32be(&out, quant(x, 32)) } else { put32le(&out, quant(x, 32)) }
    audio.F32 => if big { put32be(&out, x.bits32()) } else { put32le(&out, x.bits32()) }
    audio.F64 => {
      let b = x.bits()
      if big {
        put32be(&out, b >> 32)
        put32be(&out, b)
      } else {
        put32le(&out, b)
        put32le(&out, b >> 32)
      }
    }
    audio.Alaw => out.push(alaw(quant(x, 16)))
    audio.Ulaw => out.push(ulaw(quant(x, 16)))
    audio.Ima => {}
  }
}

// ---- G.711: decoding after Sun's g711.c ----

fn ulaw_to_lin(u0: int): int {
  let u = ~u0 & 0xff
  let t = ((u & 0x0f) << 3) + 0x84 << ((u & 0x70) >> 4)
  if (u & 0x80) != 0 { 0x84 - t } else { t - 0x84 }
}

fn alaw_to_lin(a0: int): int {
  let a = a0 ^ 0x55
  let seg = (a & 0x70) >> 4
  var t = (a & 0x0f) << 4
  t = if seg == 0 { t + 8 } else if seg == 1 { t + 0x108 } else { (t + 0x108) << (seg - 1) }
  if (a & 0x80) != 0 { t } else { -t }
}

imprint ULAW = (0..256).map(u => ulaw_to_lin(u))
imprint ALAW = (0..256).map(a => alaw_to_lin(a))

// Encoding tables at 14-bit resolution, built as ffmpeg's pcm_tablegen does: each input goes
// to the code whose decoded value is nearest (so encoding matches ffmpeg byte for byte).
fn xlaw_table(dec: (int) => int, mask: int): [int] {
  var t = izeros(16384)
  t[8192] = mask
  var j = 1
  for i in 0..127 {
    let v1 = dec(i ^ mask)
    let v2 = dec((i + 1) ^ mask)
    let v = (v1 + v2 + 4) >> 3
    while j < v {
      t[8192 - j] = i ^ (mask ^ 0x80)
      t[8192 + j] = i ^ mask
      j += 1
    }
  }
  while j < 8192 {
    t[8192 - j] = 127 ^ (mask ^ 0x80)
    t[8192 + j] = 127 ^ mask
    j += 1
  }
  t[0] = t[1]
  t
}

imprint TO_ULAW = xlaw_table(u => ulaw_to_lin(u), 0xff)
imprint TO_ALAW = xlaw_table(a => alaw_to_lin(a), 0xd5)

/// A 16-bit sample as μ-law.
pub fn ulaw(pcm: int): int = TO_ULAW[(pcm + 32768) >> 2]

/// A 16-bit sample as A-law.
pub fn alaw(pcm: int): int = TO_ALAW[(pcm + 32768) >> 2]

// ---- IMA ADPCM (WAV flavour: 4-bit, blocks with a header per channel) ----

let IMA_STEP = [
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  16,
  17,
  19,
  21,
  23,
  25,
  28,
  31,
  34,
  37,
  41,
  45,
  50,
  55,
  60,
  66,
  73,
  80,
  88,
  97,
  107,
  118,
  130,
  143,
  157,
  173,
  190,
  209,
  230,
  253,
  279,
  307,
  337,
  371,
  408,
  449,
  494,
  544,
  598,
  658,
  724,
  796,
  876,
  963,
  1060,
  1166,
  1282,
  1411,
  1552,
  1707,
  1878,
  2066,
  2272,
  2499,
  2749,
  3024,
  3327,
  3660,
  4026,
  4428,
  4871,
  5358,
  5894,
  6484,
  7132,
  7845,
  8630,
  9493,
  10442,
  11487,
  12635,
  13899,
  15289,
  16818,
  18500,
  20350,
  22385,
  24623,
  27086,
  29794,
  32767,
]

let IMA_INDEX = [-1, -1, -1, -1, 2, 4, 6, 8]

fn clampi(v: int, lo: int, hi: int): int = if v < lo { lo } else if v > hi { hi } else { v }

// One decoder (or encoder) channel: the predicted sample and the step index.
struct Ima { pred: int, index: int }

fn ima_step(st: var Ima, nib: int): int {
  let step = IMA_STEP[st.index]
  var diff = step >> 3
  if (nib & 1) != 0 { diff += step >> 2 }
  if (nib & 2) != 0 { diff += step >> 1 }
  if (nib & 4) != 0 { diff += step }
  st.pred = clampi(if (nib & 8) != 0 { st.pred - diff } else { st.pred + diff }, -32768, 32767)
  st.index = clampi(st.index + IMA_INDEX[nib & 7], 0, 88)
  st.pred
}

/// Frames per block of IMA ADPCM with this block size.
pub fn ima_frames(block: int, nch: int): int = (block - 4 * nch) * 2 / nch + 1

/// Decodes IMA ADPCM blocks of `block` bytes from `d[at..at + size]`; `frames` caps the output
/// (the `fact` chunk's count), or -1.
pub fn ima_decode(d: [int], at: int, size: int, nch: int, block: int, frames: int): [[float]]! {
  var chans: [[float]] = []
  for _ in 0..nch { chans.push([]) }
  let per = ima_frames(block, nch)
  if per < 1 { fail("bad IMA ADPCM block size {block}") }
  var p = at
  let end = at + size
  while p + 4 * nch <= end {
    let blen = if end - p < block { end - p } else { block }
    var sts: [Ima] = []
    for c in 0..nch {
      let h = p + 4 * c
      sts.push(Ima { pred: sext(u16le(d, h), 16), index: clampi(d[h + 2], 0, 88) })
      chans[c].push(float(sts[c].pred) / 32768.0)
    }
    // then groups of 4 bytes (8 samples) per channel, low nibble first
    var q = p + 4 * nch
    let stop = p + blen
    while q + 4 * nch <= stop {
      for c in 0..nch {
        for k in 0..4 {
          let b = d[q + 4 * c + k]
          chans[c].push(float(ima_step(&sts[c], b & 0xf)) / 32768.0)
          chans[c].push(float(ima_step(&sts[c], b >> 4)) / 32768.0)
        }
      }
      q += 4 * nch
    }
    p += blen
  }
  if frames >= 0 && chans[0].len() > frames {
    chans = chans.map(ch => ch.take(frames))
  }
  chans
}

/// The nibble that moves `st` closest to `target`, applied to `st`.
fn ima_nibble(st: var Ima, target: int): int {
  let step = IMA_STEP[st.index]
  var diff = target - st.pred
  var nib = 0
  if diff < 0 {
    nib = 8
    diff = -diff
  }
  var s = step
  if diff >= s {
    nib |= 4
    diff -= s
  }
  s = s >> 1
  if diff >= s {
    nib |= 2
    diff -= s
  }
  s = s >> 1
  if diff >= s { nib |= 1 }
  st.ima_step(nib)
  nib
}

/// Encodes as IMA ADPCM blocks of `block` bytes (the last block is padded with silence).
pub fn ima_encode(chans: [[float]], block: int): [int] {
  let nch = chans.len()
  let per = ima_frames(block, nch)
  let n = chans[0].len()
  var out: [int] = []
  var sts: [Ima] = []
  for _ in 0..nch { sts.push(Ima { pred: 0, index: 0 }) }
  var i = 0
  while i < n {
    for c in 0..nch {
      let s0 = quant(chans[c][i], 16)
      sts[c].pred = s0
      put16le(&out, s0)
      out.push(sts[c].index)
      out.push(0)
    }
    // the block's other per - 1 frames, 8 per group
    var k = 1
    while k < per {
      for c in 0..nch {
        for j in 0..4 {
          let a = quant(chans[c].get(i + k + 2 * j) else 0.0, 16)
          let b = quant(chans[c].get(i + k + 2 * j + 1) else 0.0, 16)
          let lo = ima_nibble(&sts[c], a)
          let hi = ima_nibble(&sts[c], b)
          out.push(lo | (hi << 4))
        }
      }
      k += 8
    }
    i += per
  }
  out
}

// ---- Microsoft ADPCM (decode only) ----

let MS_ADAPT = [230, 230, 230, 230, 307, 409, 512, 614, 768, 614, 512, 409, 307, 230, 230, 230]

/// Decodes MS ADPCM blocks; `coefs` are the (c1, c2) pairs from the format chunk.
pub fn ms_decode(
  d: [int],
  at: int,
  size: int,
  nch: int,
  block: int,
  coefs: [(int, int)],
  frames: int,
): [[float]]! {
  var chans: [[float]] = []
  for _ in 0..nch { chans.push([]) }
  if block < 7 * nch { fail("bad MS ADPCM block size {block}") }
  var p = at
  let end = at + size
  while p + 7 * nch <= end {
    let stop = if end - p < block { end } else { p + block }
    var c1: [int] = []
    var c2: [int] = []
    var delta: [int] = []
    var s1: [int] = []
    var s2: [int] = []
    for c in 0..nch {
      let (a, b) = coefs.get(d[p + c]) else fail("bad MS ADPCM predictor {d[p + c]}")
      c1.push(a)
      c2.push(b)
      delta.push(sext(u16le(d, p + nch + 2 * c), 16))
      s1.push(sext(u16le(d, p + 3 * nch + 2 * c), 16))
      s2.push(sext(u16le(d, p + 5 * nch + 2 * c), 16))
    }
    for c in 0..nch { chans[c].push(float(s2[c]) / 32768.0) }
    for c in 0..nch { chans[c].push(float(s1[c]) / 32768.0) }
    var c = 0
    for q in p + 7 * nch..stop {
      for nib in [d[q] >> 4, d[q] & 0xf] {
        let pred = (s1[c] * c1[c] + s2[c] * c2[c]) >> 8
        let v = clampi(pred + sext(nib, 4) * delta[c], -32768, 32767)
        s2[c] = s1[c]
        s1[c] = v
        delta[c] = (MS_ADAPT[nib] * delta[c]) >> 8
        if delta[c] < 16 { delta[c] = 16 }
        chans[c].push(float(v) / 32768.0)
        c = (c + 1) % nch
      }
    }
    p = stop
  }
  if frames >= 0 && chans[0].len() > frames {
    chans = chans.map(ch => ch.take(frames))
  }
  chans
}
