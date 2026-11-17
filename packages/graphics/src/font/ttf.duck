/// TrueType tables (module `graphics.font.ttf`): byte readers, glyph outlines (`glyf`, simple and
/// composite), character maps (`cmap` formats 4 and 12), and pair kerning from `kern` and GPOS.

pub fn u16(d: [int], i: int): int = d[i] << 8 | d[i + 1]

pub fn i16(d: [int], i: int): int {
  let v = u16(d, i)
  if v >= 0x8000 { v - 0x10000 } else { v }
}

pub fn u32(d: [int], i: int): int = d[i] << 24 | (d[i + 1] << 16) | (d[i + 2] << 8) | d[i + 3]

pub fn tag(d: [int], i: int): str = str((i..i + 4).map(j => char(d[j]) else '?'))

fn f2dot14(d: [int], i: int): float = float(i16(d, i)) / 16384.0

fn i8(b: int): int = if b >= 0x80 { b - 0x100 } else { b }

fn bits(n: int): int {
  var c = 0
  var v = n
  while v != 0 {
    c += v & 1
    v = v >> 1
  }
  c
}

// ---- outlines ----

/// One closed contour in font units, y up. Off-curve points are quadratic control points; two in a
/// row imply an on-curve point halfway between them.
pub struct Contour { xs: [float], ys: [float], on: [bool] }

/// The outline of glyph `g`: empty for a blank glyph (a space) or one out of range.
pub fn outline(f: graphics.font.Font, g: int): [Contour] = glyph(f, g, 0)

fn glyph(f: graphics.font.Font, g: int, depth: int): [Contour] {
  if g < 0 || g >= f.glyphs || depth > 8 { return [] }
  let d = f.data
  let (a, b) = if f.long_loca {
    (u32(d, f.loca + 4 * g), u32(d, f.loca + 4 * g + 4))
  } else {
    (2 * u16(d, f.loca + 2 * g), 2 * u16(d, f.loca + 2 * g + 2))
  }
  if b <= a || b > f.glyf_len || a + 10 > b { return [] }
  let p = f.glyf + a
  let n = i16(d, p)
  if n >= 0 { simple(d, p, n, f.glyf + b) } else { composite(f, p + 10, depth) }
}

fn simple(d: [int], p: int, n: int, end: int): [Contour] {
  if n == 0 { return [] }
  var ends: [int] = []
  for i in 0..n { ends.push(u16(d, p + 10 + 2 * i)) }
  let npts = ends[n - 1] + 1
  var q = p + 10 + 2 * n
  q += 2 + u16(d, q)  // skip the hinting instructions
  var flags: [int] = []
  while flags.len() < npts && q < end {
    let fl = d[q]
    q += 1
    flags.push(fl)
    if (fl & 8) != 0 && q < end {
      for _ in 0..d[q] { flags.push(fl) }
      q += 1
    }
  }
  if flags.len() < npts { return [] }
  var xs: [float] = []
  var v = 0
  for i in 0..npts {
    let fl = flags[i]
    if (fl & 2) != 0 {
      v += if (fl & 16) != 0 { d[q] } else { -d[q] }
      q += 1
    } else if (fl & 16) == 0 {
      v += i16(d, q)
      q += 2
    }
    xs.push(float(v))
  }
  var ys: [float] = []
  v = 0
  for i in 0..npts {
    let fl = flags[i]
    if (fl & 4) != 0 {
      v += if (fl & 32) != 0 { d[q] } else { -d[q] }
      q += 1
    } else if (fl & 32) == 0 {
      v += i16(d, q)
      q += 2
    }
    ys.push(float(v))
  }
  if q > end { return [] }
  var out: [Contour] = []
  var s = 0
  for e in ends {
    if e >= s && e < npts {
      out.push(Contour {
        xs: xs[s..e + 1],
        ys: ys[s..e + 1],
        on: flags[s..e + 1].map(fl => (fl & 1) != 0),
      })
    }
    s = e + 1
  }
  out
}

fn composite(f: graphics.font.Font, start: int, depth: int): [Contour] {
  let d = f.data
  var q = start
  var out: [Contour] = []
  loop {
    let fl = u16(d, q)
    let g = u16(d, q + 2)
    q += 4
    var dx = 0.0
    var dy = 0.0
    if (fl & 1) != 0 {
      if (fl & 2) != 0 {
        dx = float(i16(d, q))
        dy = float(i16(d, q + 2))
      }
      q += 4
    } else {
      if (fl & 2) != 0 {
        dx = float(i8(d[q]))
        dy = float(i8(d[q + 1]))
      }
      q += 2
    }
    // x' = a x + c y + dx, y' = b x + e y + dy
    var a = 1.0
    var b = 0.0
    var c = 0.0
    var e = 1.0
    if (fl & 8) != 0 {
      a = f2dot14(d, q)
      e = a
      q += 2
    } else if (fl & 0x40) != 0 {
      a = f2dot14(d, q)
      e = f2dot14(d, q + 2)
      q += 4
    } else if (fl & 0x80) != 0 {
      a = f2dot14(d, q)
      b = f2dot14(d, q + 2)
      c = f2dot14(d, q + 4)
      e = f2dot14(d, q + 6)
      q += 8
    }
    for ct in glyph(f, g, depth + 1) {
      var xs: [float] = []
      var ys: [float] = []
      for i in 0..ct.xs.len() {
        xs.push(a * ct.xs[i] + c * ct.ys[i] + dx)
        ys.push(b * ct.xs[i] + e * ct.ys[i] + dy)
      }
      out.push(Contour { xs, ys, on: ct.on })
    }
    if (fl & 0x20) == 0 { break }
  }
  out
}

// ---- character maps ----

/// The best Unicode subtable of the `cmap` at `t`: (offset, format), or (0, 0) if there is none.
pub fn pick_cmap(d: [int], t: int): (int, int) {
  var best = (0, 0)
  var score = 0
  for i in 0..u16(d, t + 2) {
    let r = t + 4 + 8 * i
    let plat = u16(d, r)
    let enc = u16(d, r + 2)
    let sub = t + u32(d, r + 4)
    if sub + 4 > d.len() { continue }
    let fmt = u16(d, sub)
    let s = if fmt == 12 && (plat == 0 || (plat == 3 && enc == 10)) {
      4
    } else if fmt == 4 && (plat == 0 || (plat == 3 && enc == 1)) {
      3
    } else if fmt == 4 && plat == 3 && enc == 0 {
      1
    } else {
      0
    }
    if s > score {
      score = s
      best = (sub, fmt)
    }
  }
  best
}

/// The glyph for code point `c` in the subtable at `t` (format `fmt`); 0 (the missing glyph) if
/// the font has none.
pub fn cmap(d: [int], t: int, fmt: int, c: int): int {
  if fmt == 4 {
    if c > 0xffff { return 0 }
    let segs = u16(d, t + 6) / 2
    var lo = 0
    var hi = segs
    while lo < hi {  // the first segment ending at or after c
      let mid = (lo + hi) / 2
      if u16(d, t + 14 + 2 * mid) < c { lo = mid + 1 } else { hi = mid }
    }
    if lo >= segs { return 0 }
    let start = u16(d, t + 16 + 2 * segs + 2 * lo)
    if c < start { return 0 }
    let delta = u16(d, t + 16 + 4 * segs + 2 * lo)
    let ro_at = t + 16 + 6 * segs + 2 * lo
    let ro = u16(d, ro_at)
    if ro == 0 { return (c + delta) & 0xffff }
    let g = u16(d, ro_at + ro + 2 * (c - start))
    if g == 0 { 0 } else { (g + delta) & 0xffff }
  } else if fmt == 12 {
    var lo = 0
    var hi = u32(d, t + 12)
    while lo < hi {
      let mid = (lo + hi) / 2
      let r = t + 16 + 12 * mid
      if c < u32(d, r) {
        hi = mid
      } else if c > u32(d, r + 4) {
        lo = mid + 1
      } else {
        return u32(d, r + 8) + c - u32(d, r)
      }
    }
    0
  } else {
    0
  }
}

// ---- kerning ----

/// The pairs of a format-0 `kern` table at `t`: (left << 16 | right) to an adjustment in units.
pub fn kern_pairs(d: [int], t: int, len: int): {int: int} {
  var out: {int: int} = {}
  var p = t + 4
  for _ in 0..u16(d, t + 2) {
    if p + 6 > t + len { break }
    let sub_len = u16(d, p + 2)
    let cov = u16(d, p + 4)
    // format 0, horizontal, not cross-stream or minimum values
    if (cov >> 8) == 0 && (cov & 0x7) == 1 {
      let n = u16(d, p + 6)
      for i in 0..n {
        let r = p + 14 + 6 * i
        if r + 6 > d.len() { break }
        out[u32(d, r)] = i16(d, r + 4)
      }
    }
    p += sub_len
  }
  out
}

/// The pair-adjustment subtables (absolute offsets) of the lookups GPOS's `kern` feature uses.
pub fn gpos_pairs(d: [int], t: int): [int] {
  let features = t + u16(d, t + 6)
  let lookups = t + u16(d, t + 8)
  var idx: [int] = []
  for i in 0..u16(d, features) {
    let r = features + 2 + 6 * i
    if tag(d, r) != "kern" { continue }
    let ft = features + u16(d, r + 4)
    for j in 0..u16(d, ft + 2) { idx.push(u16(d, ft + 4 + 2 * j)) }
  }
  var out: [int] = []
  for li in idx.unique().sort() {
    if li >= u16(d, lookups) { continue }
    let lk = lookups + u16(d, lookups + 2 + 2 * li)
    let kind = u16(d, lk)
    for k in 0..u16(d, lk + 4) {
      let st = lk + u16(d, lk + 6 + 2 * k)
      if kind == 2 {
        out.push(st)
      } else if kind == 9 && u16(d, st + 2) == 2 {
        out.push(st + u32(d, st + 4))
      }
    }
  }
  out
}

fn coverage(d: [int], t: int, g: int): int {
  let fmt = u16(d, t)
  let n = u16(d, t + 2)
  var lo = 0
  var hi = n
  if fmt == 1 {
    while lo < hi {
      let mid = (lo + hi) / 2
      let v = u16(d, t + 4 + 2 * mid)
      if v == g { return mid }
      if v < g { lo = mid + 1 } else { hi = mid }
    }
  } else if fmt == 2 {
    while lo < hi {
      let mid = (lo + hi) / 2
      let r = t + 4 + 6 * mid
      if g < u16(d, r) {
        hi = mid
      } else if g > u16(d, r + 2) {
        lo = mid + 1
      } else {
        return u16(d, r + 4) + g - u16(d, r)
      }
    }
  }
  -1
}

fn class(d: [int], t: int, g: int): int {
  let fmt = u16(d, t)
  if fmt == 1 {
    let first = u16(d, t + 2)
    if g >= first && g < first + u16(d, t + 4) { u16(d, t + 6 + 2 * (g - first)) } else { 0 }
  } else if fmt == 2 {
    var lo = 0
    var hi = u16(d, t + 2)
    while lo < hi {
      let mid = (lo + hi) / 2
      let r = t + 4 + 6 * mid
      if g < u16(d, r) {
        hi = mid
      } else if g > u16(d, r + 2) {
        lo = mid + 1
      } else {
        return u16(d, r + 4)
      }
    }
    0
  } else {
    0
  }
}

/// The GPOS horizontal advance adjustment, in units, for glyph `a` followed by `b`; none if no
/// subtable covers the pair.
pub fn gpos_kern(d: [int], subtables: [int], a: int, b: int): int? {
  for st in subtables {
    let ci = coverage(d, st + u16(d, st + 2), a)
    if ci < 0 { continue }
    let vf1 = u16(d, st + 4)
    let size = 2 * (bits(vf1) + bits(u16(d, st + 6)))
    let xadv = 2 * bits(vf1 & 3)  // XAdvance comes after XPlacement and YPlacement
    let fmt = u16(d, st)
    if fmt == 1 {
      if ci >= u16(d, st + 8) { continue }
      let ps = st + u16(d, st + 10 + 2 * ci)
      var lo = 0
      var hi = u16(d, ps)
      while lo < hi {
        let mid = (lo + hi) / 2
        let r = ps + 2 + mid * (2 + size)
        let g = u16(d, r)
        if g == b { return if (vf1 & 4) != 0 { i16(d, r + 2 + xadv) } else { 0 } }
        if g < b { lo = mid + 1 } else { hi = mid }
      }
    } else if fmt == 2 {
      let c1 = class(d, st + u16(d, st + 8), a)
      let c2 = class(d, st + u16(d, st + 10), b)
      let n2 = u16(d, st + 14)
      if c1 >= u16(d, st + 12) || c2 >= n2 { continue }
      let r = st + 16 + (c1 * n2 + c2) * size
      return if (vf1 & 4) != 0 { i16(d, r + xadv) } else { 0 }
    }
  }
  none
}
