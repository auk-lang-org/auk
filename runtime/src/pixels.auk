/// Frames (`pixels.Frame`, pure): 32-bit pixels and the hot loops of filling, blending and
/// copying them, for gui programs and the graphics package (was runtime/c/pixels.c, ported line
/// by line).
///
/// A frame holds w×h colors 0xTTRRGGBB, rows top to bottom. The top byte is transparency: 0 is
/// opaque (so a plain 0xRRGGBB is an opaque color) and 255 fully transparent; alpha is 255 - T,
/// straight (not premultiplied). A frame is a handle shared by reference count and copied before
/// a write while shared, so it behaves like any Auk value. Rectangles are clipped to the frame,
/// so drawing partly (or wholly) outside it is fine.

// the rest of the runtime (C, or another module's `export fn`, which such an `extern fn` resolves to)
extern fn auk__sb_put_cstr(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<u8>) = "void auk__sb_put_cstr(void *, const char *)"
extern fn auk_sb_int(b: raw.Ptr<abi.StrBuf>, v: i64) = "void auk_sb_int(void *, int64_t)"
extern fn auk__sb_u64(b: raw.Ptr<abi.StrBuf>, v: u64) = "void auk__sb_u64(void *, uint64_t)"
extern fn auk__sb_eprint(b: raw.Ptr<abi.StrBuf>) = "void auk__sb_eprint(void *)"
// _Noreturn: `never` is core's only (TODO(dialect)), so its callers say `raw.unreachable()`
extern fn auk__panic_sb(loc: raw.Ptr<u8>, b: raw.Ptr<abi.StrBuf>) = "void auk__panic_sb(const char *, void *)"
extern fn auk_arr_len(a: raw.Ptr<abi.Arr>): i64 = "int64_t auk_arr_len(const void *)"
extern fn auk_arr_new(ops: raw.Ptr<abi.ElemOps>, cap: i64): raw.Ptr<abi.Arr> = "void *auk_arr_new(const void *, int64_t)"
extern fn auk_arr_make_unique(pa: raw.Ptr<raw.Ptr<abi.Arr>>): raw.Ptr<()> = "void *auk_arr_make_unique(void *)"
// libc
extern fn getenv(name: raw.Ptr<u8>): raw.Ptr<u8> = "char *getenv(const char *)"
extern fn strcmp(a: raw.Ptr<u8>, b: raw.Ptr<u8>): i32 = "int strcmp(const char *, const char *)"

raw let MAX_PIXELS: i64 = 268435456 // 1 << 28
/// Copies of shared frames at least this big are reported under AUK_GUI_TRACE=1.
raw let REPORT_PIXELS: i64 = 256 * 1024

raw let INT64_MAX: i64 = 9223372036854775807
raw let INT64_MIN: i64 = -9223372036854775807 - 1

fn frame_alloc(w: i64, h: i64): raw.Ptr<abi.Frame> uses raw, ffi {
  let f: raw.Ptr<abi.Frame> = raw.cast(rc.auk__alloc(raw.size_of<abi.Frame>() + usize(w * h) * 4, abi.K_FRAME))
  f.w = w
  f.hgt = h
  f
}

// report_copy's function-local statics
raw var report_on: i32 = -1
raw var report_count: u64 = 0

/// Report (under AUK_GUI_TRACE=1) that a big shared frame was copied before a write: easy to
/// cause by accident (`let before = frame` kept alive across a draw loop) and costly at window
/// sizes. The first 20 are reported, then a count every 100.
fn report_copy(w: i64, h: i64, loc: raw.Ptr<u8>, what: raw.Ptr<u8>) uses raw, ffi {
  if w * h < REPORT_PIXELS {
    return
  }
  let on = raw.addr_of(&report_on)
  if raw.atomic_load(on, raw.Order.SeqCst) < 0 {
    let v = getenv("AUK_GUI_TRACE")
    raw.atomic_store(on, if !v.is_null() && strcmp(v, "1") == 0 { 1 } else { 0 }, raw.Order.SeqCst)
  }
  if raw.atomic_load(on, raw.Order.SeqCst) == 0 {
    return
  }
  let n = raw.atomic_add(raw.addr_of(&report_count), 1, raw.Order.SeqCst) + 1
  if n <= 20 {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    auk__sb_put_cstr(mp, "pixels.")
    auk__sb_put_cstr(mp, what)
    if !loc.is_null() {
      auk__sb_put_cstr(mp, " at ")
      auk__sb_put_cstr(mp, loc)
    }
    auk__sb_put_cstr(mp, ": copied a shared ")
    auk_sb_int(mp, w)
    auk__sb_put_cstr(mp, "x")
    auk_sb_int(mp, h)
    auk__sb_put_cstr(mp, " frame (")
    auk_sb_int(mp, w * h * 4 / 1000000)
    auk__sb_put_cstr(mp, " MB) to change it; something else still holds it (keep one reference to a frame you draw into)\n")
    auk__sb_eprint(mp)
  } else if n % 100 == 0 {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    auk__sb_put_cstr(mp, "pixels: ")
    auk__sb_u64(mp, n)
    auk__sb_put_cstr(mp, " copies of shared frames so far\n")
    auk__sb_eprint(mp)
  }
}

/// The frame in *pf, writable: copied first if anything else holds it.
fn unique(pf: raw.Ptr<raw.Ptr<abi.Frame>>, loc: raw.Ptr<u8>, what: raw.Ptr<u8>): raw.Ptr<u32> uses raw, ffi {
  let f = pf.load()
  let w = f.w
  let h = f.hgt
  if raw.atomic_load(raw.field_addr(raw.field_addr(f, .h), .rc), raw.Order.Acquire) != 1 {
    report_copy(w, h, loc, what)
    let g = frame_alloc(w, h)
    raw.copy(g.data, f.data, usize(w * h) * 4)
    rc.auk_release(raw.cast(f))
    pf.store(g)
  }
  pf.load().data
}

fn sat_add(a: i64, b: i64): i64 uses raw {
  let (r, o) = raw.add_overflow(a, b)
  if o {
    return if b > 0 { INT64_MAX } else { INT64_MIN }
  }
  r
}

/// A rectangle clipped to a frame: [x0, x1) × [y0, y1).
raw struct PxRect {
  x0: i64,
  y0: i64,
  x1: i64,
  y1: i64,
}

/// Clip (x, y, w, h) to an fw×fh frame; false if nothing is left.
fn clip(x: i64, y: i64, w: i64, h: i64, fw: i64, fh: i64, r: raw.Ptr<PxRect>): bool uses raw {
  r.x0 = if x > 0 { x } else { 0 }
  r.y0 = if y > 0 { y } else { 0 }
  let xe = sat_add(x, w)
  let ye = sat_add(y, h)
  r.x1 = if xe < fw { xe } else { fw }
  r.y1 = if ye < fh { ye } else { fh }
  r.x0 < r.x1 && r.y0 < r.y1
}

/// t / 255 rounded to nearest (as (t + 127) / 255), for t in 0..=65025, without dividing.
fn div255(t0: u32): u32 {
  let t = t0 + 128
  (t + (t >> 8)) >> 8
}

/// An opaque dst with 1 - sa of it kept (ia = 255 - sa) plus a color's premultiplied share (crb
/// = red and blue times sa, packed as 0x00RR00BB lanes of 16 bits; cg = green times sa): red and
/// blue are worked out together in one 32-bit multiply. Exact, the same as div255 per channel:
/// each lane stays below 65536 (d·ia + c·sa ≤ 255·255).
fn mix_opaque(d: u32, ia: u32, crb: u32, cg: u32): u32 {
  let rb0 = (d & 0x00ff00ff) * ia + crb + 0x00800080
  let rb = ((rb0 + ((rb0 >> 8) & 0x00ff00ff)) >> 8) & 0x00ff00ff
  rb | div255(((d >> 8) & 0xff) * ia + cg) << 8
}

/// src (0xTTRRGGBB) over dst with src's alpha scaled by cov (0..=255).
fn over(dst: u32, src: u32, cov: u32): u32 {
  let sa = div255((u32(255) - (src >> 24)) * cov)
  if sa == 0 {
    return dst
  }
  if sa == 255 {
    return src & 0xffffff
  }
  let da = u32(255) - (dst >> 24)
  if da == 255 {
    // an opaque destination, the usual case
    let ia = u32(255) - sa
    let r = div255(((dst >> 16) & 0xff) * ia + ((src >> 16) & 0xff) * sa) << 16
    let g = div255(((dst >> 8) & 0xff) * ia + ((src >> 8) & 0xff) * sa) << 8
    let b = div255((dst & 0xff) * ia + (src & 0xff) * sa)
    return r | g | b
  }
  // straight alpha: oa = sa + da (1 - sa), c = (sc sa + dc da (1 - sa)) / oa
  let k = div255(da * (u32(255) - sa))
  let oa = sa + k
  if oa == 0 {
    return 0xff000000
  }
  let r = ((((src >> 16) & 0xff) * sa + ((dst >> 16) & 0xff) * k + oa / 2) / oa) << 16
  let g = ((((src >> 8) & 0xff) * sa + ((dst >> 8) & 0xff) * k + oa / 2) / oa) << 8
  let b = ((src & 0xff) * sa + (dst & 0xff) * k + oa / 2) / oa
  (u32(255) - oa) << 24 | r | g | b
}

fn color(c: i64): u32 = u32(c)

/// "pixels.<what>: <a>x<b>"-style messages: <pre><a><mid><b><post>. _Noreturn (its callers say
/// `raw.unreachable()`).
fn panic_size(loc: raw.Ptr<u8>, pre: raw.Ptr<u8>, a: i64, mid: raw.Ptr<u8>, b: i64, post: raw.Ptr<u8>) uses raw, ffi {
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  auk__sb_put_cstr(mp, pre)
  auk_sb_int(mp, a)
  auk__sb_put_cstr(mp, mid)
  auk_sb_int(mp, b)
  auk__sb_put_cstr(mp, post)
  auk__panic_sb(loc, mp)
  raw.unreachable()
}

/// A w×h frame filled with color c.
export fn auk_frame_new(w: i64, h: i64, c: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Frame> uses raw, ffi {
  let (n, o) = raw.mul_overflow(w, h)
  if w < 0 || h < 0 || o || n > MAX_PIXELS {
    panic_size(loc, "pixels.frame: size ", w, "x", h, "")
    raw.unreachable()
  }
  let f = frame_alloc(w, h)
  if c != 0 {
    let v = color(c)
    let d = f.data
    var i: i64 = 0
    while i < n {
      d.at(i) = v
      i += 1
    }
  }
  f
}

/// A w×h frame of the colors px (rows top to bottom).
export fn auk_frame_from_list(w: i64, h: i64, px: raw.Ptr<abi.Arr>, loc: raw.Ptr<u8>): raw.Ptr<abi.Frame> uses raw, ffi {
  let n = auk_arr_len(px)
  let (wh, o) = raw.mul_overflow(w, h)
  if w < 0 || h < 0 || o || wh != n || n > MAX_PIXELS {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    auk__sb_put_cstr(mp, "pixels.from_list: ")
    auk_sb_int(mp, n)
    auk__sb_put_cstr(mp, " colors is not ")
    auk_sb_int(mp, w)
    auk__sb_put_cstr(mp, "x")
    auk_sb_int(mp, h)
    auk__panic_sb(loc, mp)
    raw.unreachable()
  }
  let f = frame_alloc(w, h)
  let src: raw.Ptr<i64> = if n > 0 { raw.cast(px.data) } else { raw.null() }
  let d = f.data
  var i: i64 = 0
  while i < n {
    d.at(i) = color(src.at(i))
    i += 1
  }
  f
}

/// The frame's colors as a list, rows top to bottom.
export fn auk_frame_to_list(f: raw.Ptr<abi.Frame>): raw.Ptr<abi.Arr> uses raw, ffi {
  let n = f.w * f.hgt
  var out = auk_arr_new(rc.ops_int(), n)
  let d: raw.Ptr<i64> = raw.cast(auk_arr_make_unique(raw.addr_of(&out)))
  let s = f.data
  var i: i64 = 0
  while i < n {
    d.at(i) = i64(s.at(i))
    i += 1
  }
  out.len = n
  out
}

export fn auk_frame_width(f: raw.Ptr<abi.Frame>): i64 uses raw = f.w

export fn auk_frame_height(f: raw.Ptr<abi.Frame>): i64 uses raw = f.hgt

fn check(x: i64, y: i64, w: i64, h: i64, loc: raw.Ptr<u8>, what: raw.Ptr<u8>) uses raw, ffi {
  if x < 0 || y < 0 || x >= w || y >= h {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    auk__sb_put_cstr(mp, "pixels.")
    auk__sb_put_cstr(mp, what)
    auk__sb_put_cstr(mp, ": (")
    auk_sb_int(mp, x)
    auk__sb_put_cstr(mp, ", ")
    auk_sb_int(mp, y)
    auk__sb_put_cstr(mp, ") is outside the ")
    auk_sb_int(mp, w)
    auk__sb_put_cstr(mp, "x")
    auk_sb_int(mp, h)
    auk__sb_put_cstr(mp, " frame")
    auk__panic_sb(loc, mp)
    raw.unreachable()
  }
}

/// The color at (x, y).
export fn auk_frame_get(f: raw.Ptr<abi.Frame>, x: i64, y: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  check(x, y, f.w, f.hgt, loc, "get")
  i64(f.data.at(y * f.w + x))
}

/// Set the color at (x, y).
export fn auk_frame_set(pf: raw.Ptr<raw.Ptr<abi.Frame>>, x: i64, y: i64, c: i64, loc: raw.Ptr<u8>) uses raw, ffi {
  check(x, y, pf.load().w, pf.load().hgt, loc, "set")
  let px = unique(pf, loc, "set")
  px.at(y * pf.load().w + x) = color(c)
}

/// Set a rectangle to c (transparency included).
export fn auk_frame_fill(pf: raw.Ptr<raw.Ptr<abi.Frame>>, x: i64, y: i64, w: i64, h: i64, c: i64, loc: raw.Ptr<u8>) uses raw, ffi {
  var r = PxRect {}
  if !clip(x, y, w, h, pf.load().w, pf.load().hgt, raw.addr_of(&r)) {
    return
  }
  let px = unique(pf, loc, "fill")
  let fw = pf.load().w
  let v = color(c)
  var row = r.y0
  while row < r.y1 {
    let p = px.offset(row * fw)
    var i = r.x0
    while i < r.x1 {
      p.at(i) = v
      i += 1
    }
    row += 1
  }
}

/// Are all of p[0..n) opaque?
fn all_opaque(p: raw.Ptr<u32>, n: i64): bool uses raw {
  var i: i64 = 0
  while i < n {
    if p.at(i) >> 24 != 0 {
      return false
    }
    i += 1
  }
  true
}

/// Paint c over a rectangle, as transparent as c is.
export fn auk_frame_blend(pf: raw.Ptr<raw.Ptr<abi.Frame>>, x: i64, y: i64, w: i64, h: i64, c64: i64, loc: raw.Ptr<u8>) uses raw, ffi {
  let c = color(c64)
  if c >> 24 == 255 {
    return
  }
  var r = PxRect {}
  if !clip(x, y, w, h, pf.load().w, pf.load().hgt, raw.addr_of(&r)) {
    return
  }
  let px = unique(pf, loc, "blend")
  let fw = pf.load().w
  let sa = u32(255) - (c >> 24)
  let len = r.x1 - r.x0
  if sa == 255 {
    var row = r.y0
    while row < r.y1 {
      let p = px.offset(row * fw + r.x0)
      var i: i64 = 0
      while i < len {
        p.at(i) = c
        i += 1
      }
      row += 1
    }
    return
  }
  // over an opaque pixel, with the color's share of each channel worked out once
  let ia = u32(255) - sa
  let crb = (c & 0x00ff00ff) * sa
  let cg = ((c >> 8) & 0xff) * sa
  var row = r.y0
  while row < r.y1 {
    let p = px.offset(row * fw + r.x0)
    if all_opaque(p, len) {
      // all opaque, the usual case: a loop without branches
      var i: i64 = 0
      while i < len {
        p.at(i) = mix_opaque(p.at(i), ia, crb, cg)
        i += 1
      }
    } else {
      var i: i64 = 0
      while i < len {
        p.at(i) = over(p.at(i), c, 255)
        i += 1
      }
    }
    row += 1
  }
}

/// Copy (or with blend, paint over) the w×h rectangle at (sx, sy) of src to (x, y).
fn copy_rect(pf: raw.Ptr<raw.Ptr<abi.Frame>>, x: i64, y: i64, src: raw.Ptr<abi.Frame>, sx: i64, sy: i64, w: i64, h: i64,
             blend: bool, loc: raw.Ptr<u8>) uses raw, ffi {
  // clipped to the source, then the destination
  var s = PxRect {}
  if !clip(sx, sy, w, h, src.w, src.hgt, raw.addr_of(&s)) {
    return
  }
  let dx = x + (s.x0 - sx)
  let dy = y + (s.y0 - sy)
  var d = PxRect {}
  if !clip(dx, dy, s.x1 - s.x0, s.y1 - s.y0, pf.load().w, pf.load().hgt, raw.addr_of(&d)) {
    return
  }
  let ox = s.x0 + (d.x0 - dx)
  let oy = s.y0 + (d.y0 - dy)
  let len = d.x1 - d.x0
  let rows = d.y1 - d.y0
  let sw = src.w
  // the source may be this very frame: take the rectangle out first, as it may overlap
  let same = src == pf.load()
  var tmp: raw.Ptr<u32> = raw.null()
  if same {
    tmp = raw.cast(rc.auk__xmalloc(usize(len * rows) * 4 + 4))
    var r: i64 = 0
    while r < rows {
      raw.copy(tmp.offset(r * len), src.data.offset((oy + r) * sw + ox), usize(len) * 4)
      r += 1
    }
  }
  let px = unique(pf, loc, if blend { "composite" } else { "blit" })
  let fw = pf.load().w
  var r: i64 = 0
  while r < rows {
    let from = if same { tmp.offset(r * len) } else { src.data.offset((oy + r) * sw + ox) }
    let to = px.offset((d.y0 + r) * fw + d.x0)
    if blend {
      var i: i64 = 0
      while i < len {
        to.at(i) = over(to.at(i), from.at(i), 255)
        i += 1
      }
    } else {
      raw.move(to, from, usize(len) * 4)
    }
    r += 1
  }
  raw.free(tmp)
}

/// Copy the w×h rectangle at (sx, sy) of src to (x, y).
export fn auk_frame_blit(pf: raw.Ptr<raw.Ptr<abi.Frame>>, x: i64, y: i64, src: raw.Ptr<abi.Frame>, sx: i64, sy: i64, w: i64, h: i64,
                         loc: raw.Ptr<u8>) uses raw, ffi {
  copy_rect(pf, x, y, src, sx, sy, w, h, false, loc)
}

/// Paint the w×h rectangle at (sx, sy) of src over (x, y), by its transparency.
export fn auk_frame_composite(pf: raw.Ptr<raw.Ptr<abi.Frame>>, x: i64, y: i64, src: raw.Ptr<abi.Frame>, sx: i64, sy: i64, w: i64,
                              h: i64, loc: raw.Ptr<u8>) uses raw, ffi {
  copy_rect(pf, x, y, src, sx, sy, w, h, true, loc)
}

/// Paint c through mask (coverage 0..255, mw per row) placed at (x, y): how text glyphs are
/// drawn.
export fn auk_frame_blit_mask(pf: raw.Ptr<raw.Ptr<abi.Frame>>, x: i64, y: i64, mask: raw.Ptr<abi.Arr>, mw: i64, c64: i64,
                              loc: raw.Ptr<u8>) uses raw, ffi {
  if mw < 1 {
    var mb = abi.StrBuf {}
    let mp = raw.addr_of(&mb)
    auk__sb_put_cstr(mp, "pixels.blit_mask: mask width ")
    auk_sb_int(mp, mw)
    auk__sb_put_cstr(mp, " (expected at least 1)")
    auk__panic_sb(loc, mp)
    raw.unreachable()
  }
  let mn = auk_arr_len(mask)
  if mn == 0 {
    return
  }
  let c = color(c64)
  if c >> 24 == 255 {
    return
  }
  let m: raw.Ptr<i64> = raw.cast(mask.data)
  let mh = mn / mw
  var r = PxRect {}
  if !clip(x, y, mw, mh, pf.load().w, pf.load().hgt, raw.addr_of(&r)) {
    return
  }
  let px = unique(pf, loc, "blit_mask")
  let fw = pf.load().w
  let opaque = c >> 24 == 0
  let len = r.x1 - r.x0
  let crb = c & 0x00ff00ff
  let cg = (c >> 8) & 0xff
  var row = r.y0
  while row < r.y1 {
    let mrow = m.offset((row - y) * mw + (r.x0 - x))
    let prow = px.offset(row * fw + r.x0)
    if opaque && all_opaque(prow, len) {
      // the usual case for text: no branches, so it vectorizes. Exact for every coverage: 0
      // leaves the pixel as it was and 255 gives the color.
      var i: i64 = 0
      while i < len {
        let a64 = mrow.at(i)
        let a: u32 = if a64 < 0 { 0 } else if a64 > 255 { 255 } else { u32(a64) }
        prow.at(i) = mix_opaque(prow.at(i), u32(255) - a, crb * a, cg * a)
        i += 1
      }
    } else {
      var i: i64 = 0
      while i < len {
        let a64 = mrow.at(i)
        // C's `continue` when a64 <= 0
        if a64 > 0 {
          let a: u32 = if a64 > 255 { 255 } else { u32(a64) }
          let d = prow.at(i)
          if !opaque || d >> 24 != 0 {
            prow.at(i) = over(d, c, a)
          } else if a == 255 {
            prow.at(i) = c
          } else {
            // an opaque color over an opaque pixel
            prow.at(i) = mix_opaque(d, u32(255) - a, (c & 0x00ff00ff) * a, ((c >> 8) & 0xff) * a)
          }
        }
        i += 1
      }
    }
    row += 1
  }
}
