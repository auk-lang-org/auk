/// Formatting (was the second half of runtime/c/str.c, ported line by line): numbers to text
/// without printf, the shortest round-tripping float, quoting, and format specs (`{x:>8.2}`).
/// Every `export fn` keeps its C name and is `pub` (other modules call it as `str_fmt.name`).

extern fn auk__xmalloc(n: usize): raw.Ptr<u8> = "void *auk__xmalloc(size_t)"
extern fn c_snprintf(buf: raw.Ptr<u8>, cap: usize, fmt: raw.Ptr<u8>, ...): i32 =
  "int snprintf(char *, size_t, const char *, ...)"
extern fn c_fwrite(p: raw.Ptr<u8>, size: usize, n: usize, f: raw.Ptr<()>): usize =
  "size_t fwrite(const void *, size_t, size_t, void *)"
extern fn c_atoi(s: raw.Ptr<u8>): i32 = "int atoi(const char *)"

/// C arrays as locals (a `var` needs a value: a raw struct literal is one).
raw struct Bytes24 {
  b: [u8; 24],
}

raw struct Bytes40 {
  b: [u8; 40],
}

raw struct Bytes64 {
  b: [u8; 64],
}

// ---- formatting -----------------------------------------------------------------------------

/// v in decimal, written into the end of buf (20 bytes); returns where it starts.
fn int_digits(v: i64, buf: raw.Ptr<u8>): i64 uses raw {
  var i: i64 = 20
  var n: u64 = if v < 0 { 0 - u64(v) } else { u64(v) }
  loop {
    i -= 1
    buf.at(i) = u8(n % 10) + 0x30
    n = n / 10
    if n == 0 { break }
  }
  if v < 0 {
    i -= 1
    buf.at(i) = 0x2D  // '-'
  }
  i
}

pub inline export fn auk_str_from_int(v: i64): raw.Ptr<abi.Str> uses raw, ffi {
  var buf: Bytes24
  let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  let at = int_digits(v, p)
  str.auk__str_raw(p.offset(at), i64(20) - at, i64(20) - at, true)
}

/// Append v in decimal (what interpolating an int does: no temporary string).
pub inline export fn auk_sb_int(b: raw.Ptr<abi.StrBuf>, v: i64) uses raw, ffi {
  var buf: Bytes24
  let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  let at = int_digits(v, p)
  str.auk__sb_put(b, p.offset(at), i64(20) - at)
}

// ---- text without printf --------------------------------------------------------------------
// Integers need no printf (only floats use C's `snprintf`, a varargs call): numbers
// are formatted here, messages are built with the builder (outside the show budget) and then
// copied, printed or duplicated.

/// v in decimal into out (at least 21 bytes), NUL-terminated: its length (`%lld`).
pub export fn auk__fmt_i64(out: raw.Ptr<u8>, v: i64): i32 uses raw {
  var buf: Bytes24
  let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  let at = int_digits(v, p)
  let n = i64(20) - at
  raw.copy(out, p.offset(at), n)
  out.at(n) = 0
  i32(n)
}

/// v in decimal into out (at least 21 bytes), NUL-terminated: its length (`%llu`).
pub export fn auk__fmt_u64(out: raw.Ptr<u8>, v0: u64): i32 uses raw {
  var buf: Bytes24
  let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  var v = v0
  var i: i64 = 20
  loop {
    i -= 1
    p.at(i) = u8(v % 10) + 0x30
    v = v / 10
    if v == 0 { break }
  }
  let n = i64(20) - i
  raw.copy(out, p.offset(i), n)
  out.at(n) = 0
  i32(n)
}

/// v in hex (upper or lower case digits, at least min_digits of them: 1..16) into out (at least
/// 17 bytes), NUL-terminated: its length (`%llx`, `%016llx`, `%X`).
pub export fn auk__fmt_hex(out: raw.Ptr<u8>, v0: u64, min_digits: i32, upper: bool): i32 uses raw {
  let digits: raw.Ptr<u8> = if upper { "0123456789ABCDEF" } else { "0123456789abcdef" }
  var buf: Bytes24
  let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  var v = v0
  var i: i64 = 16
  loop {
    i -= 1
    p.at(i) = digits.at(v & 15)
    v = v >> 4
    if v == 0 { break }
  }
  while i64(16) - i < i64(min_digits) {
    i -= 1
    p.at(i) = 0x30
  }
  let n = i64(16) - i
  raw.copy(out, p.offset(i), n)
  out.at(n) = 0
  i32(n)
}

/// s into out[0..cap), cut to cap - 1 bytes and NUL-terminated (`snprintf(out, cap, "%s", s)`).
pub export fn auk__cstr_copy(out: raw.Ptr<u8>, cap: usize, s: raw.Ptr<u8>) uses raw, ffi {
  if cap == 0 { return }
  var n = usize(str.cstr_len(s))
  if n > cap - 1 { n = cap - 1 }
  raw.copy(out, s, n)
  out.at(n) = 0
}

/// Append v in decimal, outside the show budget.
pub export fn auk__sb_u64(b: raw.Ptr<abi.StrBuf>, v: u64) uses raw, ffi {
  var buf: Bytes24
  let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  let n = auk__fmt_u64(p, v)
  str.auk__sb_put(b, p, i64(n))
}

/// Append v in hex (see auk__fmt_hex), outside the show budget.
pub export fn auk__sb_hex(b: raw.Ptr<abi.StrBuf>, v: u64, min_digits: i32, upper: bool) uses raw, ffi {
  var buf: Bytes24
  let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  let n = auk__fmt_hex(p, v, min_digits, upper)
  str.auk__sb_put(b, p, i64(n))
}

/// The builder's text, NUL-terminated (valid until the builder changes).
pub export fn auk__sb_cstr(b: raw.Ptr<abi.StrBuf>): raw.Ptr<u8> uses raw, ffi {
  str.sb_reserve(b, 1)
  str.sb_data(b).at(b.len) = 0
  str.sb_data(b)
}

/// The builder's text into out[0..cap), cut and NUL-terminated as snprintf would; the builder
/// is freed.
pub export fn auk__sb_take_into(b: raw.Ptr<abi.StrBuf>, out: raw.Ptr<u8>, cap: usize) uses raw, ffi {
  auk__cstr_copy(out, cap, auk__sb_cstr(b))
  str.auk_sb_free(b)
}

/// The builder's text as a malloc'd C string; the builder is freed.
pub export fn auk__sb_take_cstr(b: raw.Ptr<abi.StrBuf>): raw.Ptr<u8> uses raw, ffi {
  let n = b.len
  let s = auk__xmalloc(usize(n) + 1)
  raw.copy(s, str.sb_data(b), n)
  s.at(n) = 0
  str.auk_sb_free(b)
  s
}

/// Write the builder's text to stderr in one piece (as one fprintf would); the builder is
/// freed.
pub export fn auk__sb_eprint(b: raw.Ptr<abi.StrBuf>) uses raw, ffi {
  let _ = c_fwrite(str.sb_data(b), 1, usize(b.len), cfacts.stderr())
  str.auk_sb_free(b)
}

/// Does `%.<prec>e` of v read back as v? Leaves the text in buf.
fn round_trips(v: float, prec: i32, buf: raw.Ptr<u8>, n: usize): bool uses raw, ffi {
  let _ = c_snprintf(buf, n, "%.*e", prec, v)
  str.strtod(buf, raw.null()) == v
}

/// C's signbit.
fn sign_bit(v: float): bool uses raw {
  var x = v
  (raw.cast<u64>(raw.addr_of(&x)).load() >> 63) != 0
}

fn is_nan(v: float): bool = v != v

fn is_inf(v: float): bool = v == v && v - v != v - v

/// The shortest text that reads back as v (at most 32 bytes with the NUL), into out. JavaScript
/// style: plain decimals for exponents -6..20 (with ".0" when integral), else d.ddde<exp>.
pub export fn auk__fmt_float_shortest(v: float, out: raw.Ptr<u8>, outn: usize) uses raw, ffi {
  var res_buf = Bytes40 {}
  let res: raw.Ptr<u8> = raw.cast(raw.addr_of(&res_buf))
  var k: i64 = 0
  if is_nan(v) {
    auk__cstr_copy(res, 40, "NaN")
    k = 3
  } else if is_inf(v) {
    auk__cstr_copy(res, 40, if v < 0.0 { "-inf" } else { "inf" })
    k = str.cstr_len(res)
  } else if v == 0.0 {
    auk__cstr_copy(res, 40, if sign_bit(v) { "-0.0" } else { "0.0" })
    k = str.cstr_len(res)
  } else {
    var digits_buf = Bytes24 {}
    let digits: raw.Ptr<u8> = raw.cast(raw.addr_of(&digits_buf))
    var nd: i64 = 0
    var exp: i64 = 0
    var neg = sign_bit(v)
    // Fast path, for a value that is a short decimal: the fewest decimal places k at which
    // m = round(|v| * 10^k) gives |v| back as m / 10^k. m and 10^k are exact floats and the
    // division rounds correctly, so that is the test "the text m / 10^k reads back as v", and
    // the first k that passes has the fewest digits: the digits the search below finds.
    let av = if neg { 0.0 - v } else { v }
    var found = false
    if av >= 0.000001 && av < 1000000000000000.0 {
      var p10 = 1.0
      var k10: i64 = 0
      while k10 <= 20 && !found {
        let scaled = av * p10
        if scaled >= 1000000000000000.0 { break }
        let m = i64(scaled + 0.5)
        if m > 0 && float(m) / p10 == av {
          var ibuf: Bytes24
          let ip: raw.Ptr<u8> = raw.cast(raw.addr_of(&ibuf))
          nd = i64(auk__fmt_i64(ip, m))
          raw.copy(digits, ip, nd)
          exp = nd - 1 - k10
          found = true
        }
        p10 = p10 * 10.0
        k10 += 1
      }
    }
    if !found {
      // the smallest precision that round-trips (17 digits always do; a precision that
      // round-trips means every larger one does too)
      var tmp_buf = Bytes40 {}
      let tmp: raw.Ptr<u8> = raw.cast(raw.addr_of(&tmp_buf))
      var lo: i32 = 0
      var hi: i32 = 16
      while lo < hi {
        let mid = (lo + hi) / 2
        if round_trips(v, mid, tmp, 40) { hi = mid } else { lo = mid + 1 }
      }
      let _ = round_trips(v, lo, tmp, 40)
      // tmp = [-]d[.ddd]e(+|-)XX
      var p: i64 = 0
      neg = tmp.at(0) == 0x2D  // '-'
      if neg { p += 1 }
      while tmp.at(p) != 0 && tmp.at(p) != 0x65 {  // 'e'
        if tmp.at(p) != 0x2E {  // '.'
          digits.at(nd) = tmp.at(p)
          nd += 1
        }
        p += 1
      }
      exp = if tmp.at(p) == 0x65 { i64(c_atoi(tmp.offset(p + 1))) } else { 0 }
    }
    while nd > 1 && digits.at(nd - 1) == 0x30 { nd -= 1 }
    if neg {
      res.at(k) = 0x2D
      k += 1
    }
    if exp < -6 || exp >= 21 {
      res.at(k) = digits.at(0)
      k += 1
      if nd > 1 {
        res.at(k) = 0x2E
        k += 1
        raw.copy(res.offset(k), digits.offset(1), nd - 1)
        k += nd - 1
      }
      res.at(k) = 0x65
      k += 1
      k += i64(auk__fmt_i64(res.offset(k), exp))
    } else {
      let point = exp + 1  // digits before the decimal point
      if point <= 0 {
        res.at(k) = 0x30
        res.at(k + 1) = 0x2E
        k += 2
        var i: i64 = 0
        while i < 0 - point {
          res.at(k) = 0x30
          k += 1
          i += 1
        }
        raw.copy(res.offset(k), digits, nd)
        k += nd
      } else if point >= nd {
        raw.copy(res.offset(k), digits, nd)
        k += nd
        var i: i64 = 0
        while i < point - nd {
          res.at(k) = 0x30
          k += 1
          i += 1
        }
        res.at(k) = 0x2E
        res.at(k + 1) = 0x30
        k += 2
      } else {
        raw.copy(res.offset(k), digits, point)
        k += point
        res.at(k) = 0x2E
        k += 1
        raw.copy(res.offset(k), digits.offset(point), nd - point)
        k += nd - point
      }
    }
  }
  if outn == 0 { return }
  let n: usize = if usize(k) < outn - 1 { usize(k) } else { outn - 1 }
  raw.copy(out, res, n)
  out.at(n) = 0
}

pub export fn auk_str_from_float(v: float): raw.Ptr<abi.Str> uses raw, ffi {
  var buf = Bytes40 {}
  let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  auk__fmt_float_shortest(v, p, 40)
  let n = str.cstr_len(p)
  str.auk__str_raw(p, n, n, true)
}

pub export fn auk_str_from_char(c: u32): raw.Ptr<abi.Str> uses raw, ffi {
  var b: str.Bytes4
  let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&b))
  let n = str.utf8_encode(c, p)
  str.auk__str_raw(p, i64(n), 1, n == 1)
}

pub inline export fn auk_str_from_bool(b: bool): raw.Ptr<abi.Str> uses raw, ffi =
  if b { str.auk__str_raw("true", 4, 4, true) } else { str.auk__str_raw("false", 5, 5, true) }

fn quote_char(b: raw.Ptr<abi.StrBuf>, c: u32, q: u32) uses raw, ffi {
  if c == 0x0A {
    str.auk_sb_bytes(b, "\\n", 2)
    return
  }
  if c == 0x09 {
    str.auk_sb_bytes(b, "\\t", 2)
    return
  }
  if c == 0x0D {
    str.auk_sb_bytes(b, "\\r", 2)
    return
  }
  if c == 0x00 {
    str.auk_sb_bytes(b, "\\0", 2)
    return
  }
  if c == 0x5C {
    str.auk_sb_bytes(b, "\\\\", 2)
    return
  }
  if c == q {
    str.auk_sb_char(b, 0x5C)
    str.auk_sb_char(b, c)
  } else if c < 0x20 || c == 0x7F {
    var buf = Bytes24 {}
    let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
    p.at(0) = 0x5C  // "\u{"
    p.at(1) = 0x75
    p.at(2) = 0x7B
    var n = i64(3) + i64(auk__fmt_hex(p.offset(3), u64(c), 1, true))
    p.at(n) = 0x7D  // '}'
    n += 1
    str.auk_sb_bytes(b, p, n)
  } else {
    str.auk_sb_char(b, c)
  }
}

pub export fn auk_str_quote(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> uses raw, ffi {
  var b = abi.StrBuf {}
  let bp = raw.addr_of(&b)
  str.auk_sb_char(bp, 0x22)  // '"'
  let p = str.sdata(s)
  let n = str.slen(s)
  var i: i64 = 0
  while i < n && !str.auk__show_exhausted() {
    var len: i64 = 0
    let c = str.utf8_decode(p, n, i, raw.addr_of(&len))
    quote_char(bp, c, 0x22)
    i += len
  }
  str.auk_sb_char(bp, 0x22)
  str.auk_sb_finish(bp)
}

pub export fn auk_char_quote(c: u32): raw.Ptr<abi.Str> uses raw, ffi {
  var b = abi.StrBuf {}
  let bp = raw.addr_of(&b)
  str.auk_sb_char(bp, 0x27)  // '\''
  quote_char(bp, c, 0x27)
  str.auk_sb_char(bp, 0x27)
  str.auk_sb_finish(bp)
}

// ---- format specs ---------------------------------------------------------------------------

raw struct Spec {
  fill: u32,
  /// 0, '<', '>', '^'
  align: u8,
  zero: bool,
  /// -1: none
  width: i64,
  /// -1: none
  prec: i64,
  /// 0: decimal, or the type char 'x' 'X' 'o' 'b' (ints only)
  radix: u8,
}

/// Panic over spec: `bad format spec "<spec>"`, or with too_large `format spec "<spec>" is too
/// large`.
fn bad_spec(spec: raw.Ptr<u8>, too_large: bool) uses raw, ffi {
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  str.auk__sb_put_cstr(mp, if too_large { "format spec \"" } else { "bad format spec \"" })
  let shown = str.auk_str_lit(spec)  // invalid UTF-8 shown repaired
  str.auk_sb_str(mp, shown)
  rc.release(raw.cast(shown))
  str.auk__sb_put_cstr(mp, if too_large { "\" is too large" } else { "\"" })
  str.auk__panic_sb("format", mp)
  raw.unreachable()
}

/// '<' '>' '^'
fn is_align(c: u8): bool = c == 0x3C || c == 0x3E || c == 0x5E

fn parse_spec(spec: raw.Ptr<u8>): Spec uses raw, ffi {
  var sp = Spec { fill: 0x20, align: 0, zero: false, width: -1, prec: -1, radix: 0 }
  if spec.is_null() { return sp }
  let s = spec
  let n = str.cstr_len(spec)
  var p: i64 = 0
  if n > 0 {
    var len: i64 = 0
    let c = str.utf8_decode(s, n, 0, raw.addr_of(&len))
    let a: u8 = if len < n { s.at(len) } else { 0 }
    if is_align(a) {
      sp.fill = c
      sp.align = a
      p = len + 1
    } else if is_align(s.at(0)) {
      sp.align = s.at(0)
      p = 1
    }
  }
  if s.at(p) == 0x30 {
    sp.zero = true
    p += 1
  }
  if str.is_digit(s.at(p)) {
    sp.width = 0
    while str.is_digit(s.at(p)) {
      sp.width = sp.width * 10 + i64(s.at(p) - 0x30)
      p += 1
    }
  }
  if s.at(p) == 0x2E {  // '.'
    p += 1
    if !str.is_digit(s.at(p)) { bad_spec(spec, false) }
    sp.prec = 0
    while str.is_digit(s.at(p)) {
      sp.prec = sp.prec * 10 + i64(s.at(p) - 0x30)
      p += 1
    }
  }
  let t = s.at(p)
  if t == 0x78 || t == 0x58 || t == 0x6F || t == 0x62 {  // 'x' 'X' 'o' 'b'
    sp.radix = t
    p += 1
  }
  if s.at(p) != 0 { bad_spec(spec, false) }
  if sp.width > 1048576 || sp.prec > 1048576 { bad_spec(spec, true) }
  sp
}

/// Pad body (owned, consumed) according to sp.
fn pad(body: raw.Ptr<abi.Str>, sp: Spec, numeric: bool): raw.Ptr<abi.Str> uses raw, ffi {
  let n = str.auk_str_len(body)
  if sp.width <= n { return body }
  let extra = sp.width - n
  var b = abi.StrBuf {}
  let bp = raw.addr_of(&b)
  let p = str.sdata(body)
  let bn = str.slen(body)
  if numeric && sp.zero && sp.align == 0 {
    var i: i64 = 0
    if bn > 0 && (p.at(0) == 0x2D || p.at(0) == 0x2B) {
      str.auk_sb_bytes(bp, p, 1)
      i = 1
    }
    var k: i64 = 0
    while k < extra {
      str.auk_sb_char(bp, 0x30)
      k += 1
    }
    str.auk_sb_bytes(bp, p.offset(i), bn - i)
  } else {
    let al: u8 = if sp.align != 0 { sp.align } else if numeric { 0x3E } else { 0x3C }
    let left = if al == 0x3E { extra } else if al == 0x5E { extra / 2 } else { 0 }
    var k: i64 = 0
    while k < left {
      str.auk_sb_char(bp, sp.fill)
      k += 1
    }
    str.auk_sb_str(bp, body)
    k = 0
    while k < extra - left {
      str.auk_sb_char(bp, sp.fill)
      k += 1
    }
  }
  rc.release(raw.cast(body))
  str.auk_sb_finish(bp)
}

/// The bits of v in base 16, 8 or 2 (a negative v as its 64-bit two's complement).
fn int_in_radix(v: i64, t: u8): raw.Ptr<abi.Str> uses raw, ffi {
  let shift: u64 = if t == 0x62 { 1 } else if t == 0x6F { 3 } else { 4 }
  let digits: raw.Ptr<u8> = if t == 0x58 { "0123456789ABCDEF" } else { "0123456789abcdef" }
  var u = u64(v)
  let mask: u64 = (u64(1) << shift) - 1
  var buf = Bytes64 {}
  let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  var n: i64 = 0
  loop {
    p.at(i64(63) - n) = digits.at(u & mask)
    n += 1
    u = u >> shift
    if u == 0 { break }
  }
  str.auk__str_raw(p.offset(i64(64) - n), n, n, true)
}

pub export fn auk_fmt_int(v: i64, spec: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi {
  let sp = parse_spec(spec)
  pad(if sp.radix != 0 { int_in_radix(v, sp.radix) } else { auk_str_from_int(v) }, sp, true)
}

pub export fn auk_fmt_float(v: float, spec: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi {
  let sp = parse_spec(spec)
  let body = if sp.prec >= 0 && !is_nan(v) && !is_inf(v) {
    let prec = i32(sp.prec)
    let n = c_snprintf(raw.null(), 0, "%.*f", prec, v)
    let buf = auk__xmalloc(usize(n) + 1)
    let _ = c_snprintf(buf, usize(n) + 1, "%.*f", prec, v)
    let s = str.auk__str_raw(buf, i64(n), i64(n), true)
    raw.free(buf)
    s
  } else {
    auk_str_from_float(v)
  }
  pad(body, sp, true)
}

pub export fn auk_fmt_str(s: raw.Ptr<abi.Str>, spec: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi {
  let sp = parse_spec(spec)
  let body: raw.Ptr<abi.Str> = if sp.prec >= 0 && sp.prec < str.auk_str_len(s) {
    str.auk_str_slice(s, 0, sp.prec, raw.null())
  } else if s.is_null() {
    str.auk_str_lit("")
  } else {
    raw.cast(rc.retain(raw.cast(s)))
  }
  pad(body, sp, false)
}

pub export fn auk_fmt_char(c: u32, spec: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi {
  let sp = parse_spec(spec)
  pad(auk_str_from_char(c), sp, false)
}

pub export fn auk_fmt_bool(v: bool, spec: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi {
  let sp = parse_spec(spec)
  pad(auk_str_from_bool(v), sp, false)
}
