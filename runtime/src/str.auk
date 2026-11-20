/// Strings (was runtime/c/str.c, ported line by line with str_fmt.auk): immutable UTF-8
/// strings, the string builder, the show budget, searching and parsing. str_fmt.auk has the
/// formatting (numbers, quoting, format specs). The ABI is auk_rt.h's: every `auk_str_*`,
/// `auk_sb_*`, `auk_char_*` and `auk__*` function of str.c under its C name.
///
/// Each `export fn` is `pub` too: another module of the package calls it as `str.name(…)`, never
/// through an `extern fn` of the same symbol (which the compiler would rename: see
/// design/runtime-port.md, "Found porting str.c").

// the rest of the runtime (C, or another module's `export fn`, which such an `extern fn` resolves to)
extern fn auk__xmalloc(n: usize): raw.Ptr<u8> = "void *auk__xmalloc(size_t)"
extern fn auk__xrealloc(p: raw.Ptr<u8>, n: usize): raw.Ptr<u8> = "void *auk__xrealloc(void *, size_t)"
// _Noreturn: its callers say `raw.unreachable()` (no `never` outside core, TODO(dialect))
extern fn auk__err_bytes(p: raw.Ptr<u8>, n: usize): raw.Ptr<abi.Err> = "void *auk__err_bytes(const char *, size_t)"
extern fn auk__heap_usable(h: raw.Ptr<abi.Header>): usize = "size_t auk__heap_usable(void *)"
extern fn auk__heap_resize(h: raw.Ptr<abi.Header>, size: usize): raw.Ptr<abi.Header> =
  "void *auk__heap_resize(void *, size_t)"
extern fn auk_hash_bytes(p: raw.Ptr<u8>, n: usize): u64 = "uint64_t auk_hash_bytes(const void *, size_t)"
extern fn auk_arr_new(ops: raw.Ptr<abi.ElemOps>, cap: i64): raw.Ptr<abi.Arr> = "void *auk_arr_new(const void *, int64_t)"
extern fn auk_arr_make_unique(pa: raw.Ptr<raw.Ptr<abi.Arr>>): raw.Ptr<()> = "void *auk_arr_make_unique(void *)"
extern fn auk_arr_push(pa: raw.Ptr<raw.Ptr<abi.Arr>>, e: raw.Ptr<()>) = "void auk_arr_push(void *, const void *)"
extern fn auk_arr_slice(a: raw.Ptr<abi.Arr>, lo: i64, hi: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Arr> =
  "void *auk_arr_slice(void *, int64_t, int64_t, const char *)"

// the C library
extern fn c_strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn c_memchr(p: raw.Ptr<u8>, c: i32, n: usize): raw.Ptr<u8> = "void *memchr(const void *, int, size_t)"
extern fn c_strtod(s: raw.Ptr<u8>, end: raw.Ptr<raw.Ptr<u8>>): float = "double strtod(const char *, char **)"

/// &auk_ops_str (below), for the other modules.
pub fn ops_str(): raw.Ptr<abi.ElemOps> uses raw = raw.addr_of(&auk_ops_str)

/// strlen.
pub fn cstr_len(s: raw.Ptr<u8>): i64 uses ffi = i64(c_strlen(s))

/// strtod.
pub fn strtod(s: raw.Ptr<u8>, end: raw.Ptr<raw.Ptr<u8>>): float uses ffi = c_strtod(s, end)

// ---- the show budget ------------------------------------------------------------------------
// While the tracer or the debugger shows a value, text appended to a builder counts against a
// per-thread budget, so a huge value is shown as a prefix instead of in full.

raw thread var show_left: i64 = -1
raw thread var dbg_busy: bool = false

pub export fn auk__dbg_busy(): bool = dbg_busy

pub export fn auk__dbg_set_busy(b: bool): bool {
  let old = dbg_busy
  dbg_busy = b
  old
}

pub export fn auk__show_left(): i64 = show_left

pub export fn auk__set_show_left(v: i64) {
  show_left = v
}

fn showing(): bool uses raw = raw.atomic_load(raw.addr_of(&trace.auk_trace_live), raw.Order.Relaxed) || dbg_busy

pub export fn auk__show_exhausted(): bool uses raw = showing() && show_left == 0

/// Count n appended bytes against the budget; false: drop them.
export fn auk__show_take(n: i64): bool uses raw {
  if !showing() || show_left < 0 { return true }
  if show_left == 0 { return false }
  show_left = if n >= show_left { 0 } else { show_left - n }
  true
}

// ---- accessors ------------------------------------------------------------------------------

pub fn sdata(s: raw.Ptr<abi.Str>): raw.Ptr<u8> uses raw = if s.is_null() { "" } else { s.data }

pub fn slen(s: raw.Ptr<abi.Str>): i64 uses raw = if s.is_null() { 0 } else { s.len_bytes }

pub inline export fn auk_str_len(s: raw.Ptr<abi.Str>): i64 uses raw = if s.is_null() { 0 } else { s.len_chars }

pub inline export fn auk_str_byte_len(s: raw.Ptr<abi.Str>): i64 uses raw = if s.is_null() { 0 } else { s.len_bytes }

pub inline export fn auk_str_cstr(s: raw.Ptr<abi.Str>): raw.Ptr<u8> uses raw = if s.is_null() { "" } else { s.data }

fn is_ascii(s: raw.Ptr<abi.Str>): bool uses raw = s.is_null() || s.is_ascii

fn arr_len(a: raw.Ptr<abi.Arr>): i64 uses raw = if a.is_null() { 0 } else { a.len }

// ---- UTF-8 ----------------------------------------------------------------------------------

/// Is s[0..n) valid UTF-8? Then *chars and *ascii describe it.
fn utf8_valid(s: raw.Ptr<u8>, n: i64, chars: raw.Ptr<i64>, ascii: raw.Ptr<bool>): bool uses raw {
  var i: i64 = 0
  var count: i64 = 0
  var all_ascii = true
  while i < n {
    let c = s.at(i)
    if c < 0x80 {
      i += 1
    } else {
      all_ascii = false
      var len: i64 = 0
      var cp: u32 = 0
      if c >= 0xC2 && c <= 0xDF {
        len = 2
        cp = u32(c & 0x1F)
      } else if c >= 0xE0 && c <= 0xEF {
        len = 3
        cp = u32(c & 0x0F)
      } else if c >= 0xF0 && c <= 0xF4 {
        len = 4
        cp = u32(c & 0x07)
      } else {
        return false
      }
      if i + len > n { return false }
      var k: i64 = 1
      while k < len {
        if (s.at(i + k) & 0xC0) != 0x80 { return false }
        cp = (cp << 6) | u32(s.at(i + k) & 0x3F)
        k += 1
      }
      if len == 3 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF)) { return false }
      if len == 4 && (cp < 0x10000 || cp > 0x10FFFF) { return false }
      i += len
    }
    count += 1
  }
  chars.store(count)
  ascii.store(all_ascii)
  true
}

export fn auk_utf8_valid(p: raw.Ptr<u8>, n: i64, chars_out: raw.Ptr<i64>, ascii_out: raw.Ptr<bool>): bool uses raw {
  var chars: i64 = 0
  var ascii = true
  if n > 0 && !utf8_valid(p, n, raw.addr_of(&chars), raw.addr_of(&ascii)) { return false }
  if !chars_out.is_null() { chars_out.store(chars) }
  if !ascii_out.is_null() { ascii_out.store(ascii) }
  true
}

/// Length of the valid UTF-8 sequence at s[i..n), or 0 if invalid.
fn utf8_seq_len(s: raw.Ptr<u8>, n: i64, i: i64): i64 uses raw {
  if s.at(i) < 0x80 { return 1 }
  var len: i64 = 2
  while len <= 4 {
    var chars: i64 = 0
    var ascii = false
    if i + len <= n && utf8_valid(s.offset(i), len, raw.addr_of(&chars), raw.addr_of(&ascii)) && chars == 1 {
      return len
    }
    len += 1
  }
  0
}

/// Byte k of s past i, or 0 past the end.
fn byte_at(s: raw.Ptr<u8>, n: i64, i: i64): u32 uses raw = if i < n { u32(s.at(i)) } else { 0 }

/// Decode one char at s[i..n) (valid input); *len gets its length. Bytes past n read as 0.
pub fn utf8_decode(s: raw.Ptr<u8>, n: i64, i: i64, len: raw.Ptr<i64>): u32 uses raw {
  let b0 = u32(s.at(i))
  if b0 < 0x80 {
    len.store(1)
    return b0
  }
  if b0 < 0xE0 {
    len.store(2)
    return ((b0 & 0x1F) << 6) | (byte_at(s, n, i + 1) & 0x3F)
  }
  if b0 < 0xF0 {
    len.store(3)
    return ((b0 & 0x0F) << 12) | ((byte_at(s, n, i + 1) & 0x3F) << 6) | (byte_at(s, n, i + 2) & 0x3F)
  }
  len.store(4)
  ((b0 & 0x07) << 18) | ((byte_at(s, n, i + 1) & 0x3F) << 12) | ((byte_at(s, n, i + 2) & 0x3F) << 6) |
    (byte_at(s, n, i + 3) & 0x3F)
}

/// Encode c (surrogates and out-of-range become U+FFFD) into b; returns the length.
pub fn utf8_encode(c0: u32, b: raw.Ptr<u8>): i32 uses raw {
  let c: u32 = if c0 > 0x10FFFF || (c0 >= 0xD800 && c0 <= 0xDFFF) { 0xFFFD } else { c0 }
  if c < 0x80 {
    b.at(0) = u8(c)
    return 1
  }
  if c < 0x800 {
    b.at(0) = u8(0xC0 | (c >> 6))
    b.at(1) = u8(0x80 | (c & 0x3F))
    return 2
  }
  if c < 0x10000 {
    b.at(0) = u8(0xE0 | (c >> 12))
    b.at(1) = u8(0x80 | ((c >> 6) & 0x3F))
    b.at(2) = u8(0x80 | (c & 0x3F))
    return 3
  }
  b.at(0) = u8(0xF0 | (c >> 18))
  b.at(1) = u8(0x80 | ((c >> 12) & 0x3F))
  b.at(2) = u8(0x80 | ((c >> 6) & 0x3F))
  b.at(3) = u8(0x80 | (c & 0x3F))
  4
}

export fn auk_utf8_encode(c: u32, buf: raw.Ptr<u8>): i32 uses raw = utf8_encode(c, buf)

// ---- the builder ----------------------------------------------------------------------------

/// A C array of 4 bytes (a local `var` needs a value: a raw struct literal is one).
pub raw struct Bytes4 {
  b: [u8; 4],
}

/// Where the builder's text is: its inline bytes or its heap buffer.
pub fn sb_data(b: raw.Ptr<abi.StrBuf>): raw.Ptr<u8> uses raw =
  if b.buf.is_null() { raw.cast(raw.field_addr(b, .small)) } else { b.buf }

pub fn sb_reserve(b: raw.Ptr<abi.StrBuf>, extra: i64) uses raw, ffi {
  if b.buf.is_null() {
    // inline until the text outgrows it, then to the heap with what's there
    if b.len + extra <= abi.SB_SMALL { return }
    var cap = abi.SB_SMALL * 2
    while cap < b.len + extra + 1 { cap *= 2 }
    let heap = auk__xmalloc(usize(cap))
    raw.copy(heap, raw.field_addr(b, .small), b.len)
    b.buf = heap
    b.cap = cap
    return
  }
  if b.len + extra < b.cap { return }
  var cap = b.cap * 2
  while cap < b.len + extra + 1 { cap *= 2 }
  b.buf = auk__xrealloc(b.buf, usize(cap))
  b.cap = cap
}

/// Append n bytes, outside the show budget (whole strings, message text).
pub inline export fn auk__sb_put(b: raw.Ptr<abi.StrBuf>, p: raw.Ptr<u8>, n: i64) uses raw, ffi {
  if n <= 0 { return }
  sb_reserve(b, n)
  raw.copy(sb_data(b).offset(b.len), p, n)
  b.len += n
}

pub export fn auk__sb_put_cstr(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<u8>) uses raw, ffi =
  auk__sb_put(b, s, i64(c_strlen(s)))

/// Append n bytes as a piece of text: it counts against the show budget. Whole strings (a part
/// already built, e.g. a field's show) don't, so a capped show is an exact prefix of the full
/// one.
pub export fn auk_sb_bytes(b: raw.Ptr<abi.StrBuf>, p: raw.Ptr<u8>, n: i64) uses raw, ffi {
  if auk__show_take(n) { auk__sb_put(b, p, n) }
}

pub export fn auk_sb_lit(b: raw.Ptr<abi.StrBuf>, cstr: raw.Ptr<u8>) uses raw, ffi =
  auk_sb_bytes(b, cstr, if cstr.is_null() { 0 } else { i64(c_strlen(cstr)) })

pub inline export fn auk_sb_str(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<abi.Str>) uses raw, ffi =
  auk__sb_put(b, sdata(s), slen(s))

pub inline export fn auk_sb_str_own(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<abi.Str>) uses raw, ffi {
  auk_sb_str(b, s)
  rc.release(raw.cast(s))
}

pub export fn auk_sb_char(b: raw.Ptr<abi.StrBuf>, c: u32) uses raw, ffi {
  var buf: Bytes4
  let p: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  let n = utf8_encode(c, p)
  auk_sb_bytes(b, p, i64(n))
}

pub inline export fn auk_sb_finish(b: raw.Ptr<abi.StrBuf>): raw.Ptr<abi.Str> uses raw, ffi {
  let s = auk_str_from_bytes(sb_data(b), b.len)
  auk_sb_free(b)
  s
}

pub inline export fn auk_sb_free(b: raw.Ptr<abi.StrBuf>) uses raw {
  raw.free(b.buf)
  b.buf = raw.null()
  b.len = 0
  b.cap = 0
}

/// A C array of 2048 bytes.
raw struct Bytes2048 {
  b: [u8; 2048],
}

/// Panic with the builder's text (it is consumed).
pub export fn auk__panic_sb(loc: raw.Ptr<u8>, b: raw.Ptr<abi.StrBuf>) uses raw, ffi {
  // copied out (bounded like every panic message) so the builder can be freed first
  var m: Bytes2048
  let n: i64 = if b.len < 2048 { b.len } else { 2048 }
  raw.copy(raw.addr_of(&m), sb_data(b), n)
  auk_sb_free(b)
  rc.auk__panic_bytes(loc, raw.cast(raw.addr_of(&m)), usize(n))
  raw.unreachable()
}

/// A new error with the builder's text (it is consumed).
pub export fn auk__err_sb(b: raw.Ptr<abi.StrBuf>): raw.Ptr<abi.Err> uses raw, ffi {
  let e = auk__err_bytes(sb_data(b), usize(b.len))
  auk_sb_free(b)
  e
}

// ---- construction ---------------------------------------------------------------------------

/// A string from n bytes at p whose metadata is already known.
pub inline export fn auk__str_raw(p: raw.Ptr<u8>, n: i64, chars: i64, ascii: bool): raw.Ptr<abi.Str> uses raw, ffi {
  let s: raw.Ptr<abi.Str> = raw.cast(rc.auk__alloc_nz(raw.size_of<abi.Str>() + usize(n) + 1, abi.K_STR))
  if n > 0 { raw.copy(s.data, p, n) }
  s.data.at(n) = 0
  s.len_bytes = n
  s.len_chars = chars
  s.is_ascii = ascii
  s
}

/// A string from bytes already known to be valid UTF-8.
pub export fn auk__str_new(p: raw.Ptr<u8>, n: i64): raw.Ptr<abi.Str> uses raw, ffi {
  var chars: i64 = 0
  var ascii = true
  var i: i64 = 0
  while i < n {
    let u = p.at(i)
    if u >= 0x80 { ascii = false }
    if (u & 0xC0) != 0x80 { chars += 1 }
    i += 1
  }
  auk__str_raw(p, n, chars, ascii)
}

/// A string from arbitrary bytes, each invalid byte replaced with U+FFFD.
pub export fn auk_str_from_bytes(p: raw.Ptr<u8>, n: i64): raw.Ptr<abi.Str> uses raw, ffi {
  if n <= 0 || p.is_null() { return auk__str_raw("", 0, 0, true) }
  var chars: i64 = 0
  var ascii = false
  if utf8_valid(p, n, raw.addr_of(&chars), raw.addr_of(&ascii)) { return auk__str_raw(p, n, chars, ascii) }
  var b = abi.StrBuf {}
  var i: i64 = 0
  while i < n {
    let len = utf8_seq_len(p, n, i)
    if len != 0 {
      auk_sb_bytes(raw.addr_of(&b), p.offset(i), len)
      i += len
    } else {
      auk_sb_bytes(raw.addr_of(&b), "\u{FFFD}", 3)
      i += 1
    }
  }
  auk_sb_finish(raw.addr_of(&b))
}

pub export fn auk_str_lit(cstr: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi =
  auk_str_from_bytes(cstr, if cstr.is_null() { 0 } else { i64(c_strlen(cstr)) })

fn res_str_err(e: raw.Ptr<abi.Err>): abi.ResStr = abi.ResStr { ok: false, err: e }

fn try_from_bytes(s: raw.Ptr<u8>, n: i64): abi.ResStr uses raw, ffi {
  var chars: i64 = 0
  var ascii = true
  if n <= 0 || utf8_valid(s, n, raw.addr_of(&chars), raw.addr_of(&ascii)) {
    return abi.ResStr { ok: true, val: auk__str_raw(s, if n < 0 { 0 } else { n }, chars, ascii) }
  }
  var i: i64 = 0
  while i < n {
    let len = utf8_seq_len(s, n, i)
    if len == 0 { break }
    i += len
  }
  var b = abi.StrBuf {}
  auk__sb_put_cstr(raw.addr_of(&b), "invalid UTF-8 at byte ")
  str_fmt.auk_sb_int(raw.addr_of(&b), i)
  res_str_err(auk__err_sb(raw.addr_of(&b)))
}

export fn auk_str_try_from_bytes(p: raw.Ptr<u8>, n: i64): abi.ResStr uses raw, ffi = try_from_bytes(p, n)

export fn auk_str_from_utf8(bytes: raw.Ptr<abi.Arr>): abi.ResStr uses raw, ffi {
  let n = arr_len(bytes)
  let xs: raw.Ptr<i64> = if n > 0 { raw.cast(bytes.data) } else { raw.null() }
  let buf = auk__xmalloc(usize(n) + 1)
  var i: i64 = 0
  while i < n {
    let x = xs.at(i)
    if x < 0 || x > 255 {
      raw.free(buf)
      var b = abi.StrBuf {}
      let bp = raw.addr_of(&b)
      auk__sb_put_cstr(bp, "byte ")
      str_fmt.auk_sb_int(bp, x)
      auk__sb_put_cstr(bp, " at index ")
      str_fmt.auk_sb_int(bp, i)
      auk__sb_put_cstr(bp, " is out of range 0..255")
      return res_str_err(auk__err_sb(bp))
    }
    buf.at(i) = u8(x)
    i += 1
  }
  let r = try_from_bytes(buf, n)
  raw.free(buf)
  r
}

// ---- indexing -------------------------------------------------------------------------------

// Where the last char index looked up in a non-ASCII string was: indexing such a string has
// to count chars, and a loop `s[i]`, `s[i..j]` over one resumes from here instead of from the
// start (linear, not quadratic). Per thread: nothing crosses a task by reference (heap.auk),
// and the string can't change under it: strings are immutable but for auk_str_append on a
// unique one, which only adds to the end and forgets the cursor when it moves the string;
// auk__str_free and the heap sweep forget it too, so a new string at the same address can't
// match it.
raw struct Cursor {
  s: raw.Ptr<abi.Str>,
  c: i64,
  b: i64,
}

raw thread var cursor: Cursor = Cursor {}

/// Forget the cursor if it is in s (s is going away or moving).
pub fn forget_cursor(s: raw.Ptr<abi.Str>) uses raw {
  let cur = raw.addr_of(&cursor)
  if cur.s == s { cur.s = raw.null() }
}

/// Forget the cursor whatever string it is in (the heap sweep).
pub export fn auk__str_cursor_reset() uses raw {
  let cur = raw.addr_of(&cursor)
  cur.s = raw.null()
}

pub export fn auk__str_byte_offset(s: raw.Ptr<abi.Str>, i: i64): i64 uses raw {
  if s.is_null() { return 0 }
  if s.is_ascii { return i }
  if i >= s.len_chars { return s.len_bytes }
  let p = s.data
  let n = s.len_bytes
  let cur = raw.addr_of(&cursor)
  var b: i64 = 0
  var c: i64 = 0
  if cur.s == s {
    if cur.c <= i {
      b = cur.b
      c = cur.c
    } else if cur.c - i < i {
      // nearer the cursor than the start: count back
      b = cur.b
      c = cur.c
      while c > i {
        b -= 1
        while (p.at(b) & 0xC0) == 0x80 { b -= 1 }
        c -= 1
      }
    }
  }
  while c < i {
    b += 1
    while b < n && (p.at(b) & 0xC0) == 0x80 { b += 1 }
    c += 1
  }
  cur.s = s
  cur.c = i
  cur.b = b
  b
}

/// s[i]: inlined into programs for the common case (an ASCII string, i in range), so that an
/// index loop over text is a byte load, not a call per char.
pub inline export fn auk_str_char_at(s: raw.Ptr<abi.Str>, i: i64, loc: raw.Ptr<u8>): u32 uses raw, ffi {
  if !s.is_null() && s.is_ascii && u64(i) < u64(s.len_bytes) { return u32(s.data.at(i)) }
  auk__str_char_at_slow(s, i, loc)
}

/// The rest of auk_str_char_at: out of range (a panic), or a string with non-ASCII text.
pub noinline export fn auk__str_char_at_slow(s: raw.Ptr<abi.Str>, i: i64, loc: raw.Ptr<u8>): u32 uses raw, ffi {
  let n = auk_str_len(s)
  if i < 0 || i >= n {
    var b = abi.StrBuf {}
    let bp = raw.addr_of(&b)
    auk__sb_put_cstr(bp, "index ")
    str_fmt.auk_sb_int(bp, i)
    auk__sb_put_cstr(bp, " out of range for string of length ")
    str_fmt.auk_sb_int(bp, n)
    auk__panic_sb(loc, bp)
    raw.unreachable()
  }
  if s.is_ascii { return u32(s.data.at(i)) }
  var len: i64 = 0
  utf8_decode(s.data, s.len_bytes, auk__str_byte_offset(s, i), raw.addr_of(&len))
}

pub export fn auk_str_get(s: raw.Ptr<abi.Str>, i: i64): abi.OptChar uses raw, ffi {
  if i < 0 || i >= auk_str_len(s) { return abi.OptChar {} }
  abi.OptChar { some: true, val: auk_str_char_at(s, i, raw.null()) }
}

pub export fn auk_str_slice(s: raw.Ptr<abi.Str>, a: i64, b: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi {
  let n = auk_str_len(s)
  if a < 0 || b < a || b > n {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    auk__sb_put_cstr(mp, "slice ")
    str_fmt.auk_sb_int(mp, a)
    auk__sb_put_cstr(mp, "..")
    str_fmt.auk_sb_int(mp, b)
    auk__sb_put_cstr(mp, " out of range for string of length ")
    str_fmt.auk_sb_int(mp, n)
    auk__panic_sb(loc, mp)
    raw.unreachable()
  }
  if a == 0 && b == n && !s.is_null() { return raw.cast(rc.retain(raw.cast(s))) }
  if is_ascii(s) { return auk__str_raw(sdata(s).offset(a), b - a, b - a, true) }
  // one scan: the end is found from the start, not from byte 0 again
  let ba = auk__str_byte_offset(s, a)
  let p = s.data
  let nb = s.len_bytes
  var bb = ba
  var c = a
  while c < b {
    bb += 1
    while bb < nb && (p.at(bb) & 0xC0) == 0x80 { bb += 1 }
    c += 1
  }
  if b < s.len_chars {
    // the next slice usually starts where this one ends
    let cur = raw.addr_of(&cursor)
    cur.s = s
    cur.c = b
    cur.b = bb
  }
  auk__str_raw(p.offset(ba), bb - ba, b - a, false)
}

pub inline export fn auk_str_concat(a: raw.Ptr<abi.Str>, b: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> uses raw, ffi {
  let na = slen(a)
  let nb = slen(b)
  let s: raw.Ptr<abi.Str> = raw.cast(rc.auk__alloc_nz(raw.size_of<abi.Str>() + usize(na + nb) + 1, abi.K_STR))
  raw.copy(s.data, sdata(a), na)
  raw.copy(s.data.offset(na), sdata(b), nb)
  s.data.at(na + nb) = 0
  s.len_bytes = na + nb
  s.len_chars = auk_str_len(a) + auk_str_len(b)
  s.is_ascii = is_ascii(a) && is_ascii(b)
  s
}

/// Header flags bits 16 to 21: log2 of the capacity (bytes from the header on) of a string that
/// auk_str_append grew; 0 when unknown.
raw let CAP_SHIFT: u32 = 16

pub export fn auk_str_append(ps: raw.Ptr<raw.Ptr<abi.Str>>, b0: raw.Ptr<abi.Str>) uses raw, ffi {
  var a = ps.load()
  var b = b0
  let nb = slen(b)
  if nb == 0 { return }
  if a.is_null() || raw.atomic_load(raw.field_addr(raw.field_addr(a, .h), .rc), raw.Order.Acquire) != 1 {
    if !a.is_null() { rc.auk_note_cow() }
    ps.store(auk_str_concat(a, b))
    rc.release(raw.cast(a))
    return
  }
  // unique: nobody else can see a change; grow in place
  let na = a.len_bytes
  let chars = auk_str_len(b)
  let ascii = is_ascii(b)
  let need = raw.size_of<abi.Str>() + usize(na + nb) + 1
  // a string grown here before remembers its capacity (a power of two, its exponent in the
  // header's flags), so that a run of appends doesn't ask the allocator for it each time
  let e = (a.h.flags >> CAP_SHIFT) & 63
  let have = if e != 0 { usize(1) << usize(e) } else { auk__heap_usable(raw.field_addr(a, .h)) }
  if have < need {
    var ne: u32 = 6
    while (usize(1) << usize(ne)) < need { ne += 1 }
    let self = a == b
    if !a.is_ascii { forget_cursor(a) }
    a = raw.cast(auk__heap_resize(raw.field_addr(a, .h), usize(1) << usize(ne)))
    a.h.flags = (a.h.flags & ~(u32(63) << CAP_SHIFT)) | (ne << CAP_SHIFT)
    if self { b = a }
  }
  raw.move(a.data.offset(na), b.data, nb)  // b isn't null: nb > 0
  a.data.at(na + nb) = 0
  a.len_bytes = na + nb
  a.len_chars += chars
  a.is_ascii = a.is_ascii && ascii
  ps.store(a)
}

fn bytes_eq(a: raw.Ptr<u8>, na: i64, b: raw.Ptr<u8>, nb: i64): bool uses raw =
  na == nb && raw.compare(a, b, na) == 0

pub inline export fn auk_str_eq(a: raw.Ptr<abi.Str>, b: raw.Ptr<abi.Str>): bool uses raw =
  a == b || bytes_eq(sdata(a), slen(a), sdata(b), slen(b))

pub inline export fn auk_str_eq_lit(s: raw.Ptr<abi.Str>, lit: raw.Ptr<u8>): bool uses raw, ffi {
  let l: raw.Ptr<u8> = if lit.is_null() { "" } else { lit }
  bytes_eq(sdata(s), slen(s), l, i64(c_strlen(l)))
}

pub export fn auk_str_switch(s: raw.Ptr<abi.Str>, cases: raw.Ptr<abi.StrCase>, n: i64): i64 uses raw {
  let d = sdata(s)
  let len = slen(s)
  var lo: i64 = 0
  var hi = n
  while lo < hi {
    let mid = lo + (hi - lo) / 2
    let c = cases.offset(mid)
    let r: i32 = if c.len < len { -1 } else if c.len > len { 1 } else if len == 0 { 0 } else { raw.compare(c.s, d, len) }
    if r == 0 { return mid }
    if r < 0 { lo = mid + 1 } else { hi = mid }
  }
  -1
}

/// memcmp on the common prefix, then length: exactly lexicographic byte order.
pub inline export fn auk_str_cmp(a: raw.Ptr<abi.Str>, b: raw.Ptr<abi.Str>): i32 uses raw {
  let na = slen(a)
  let nb = slen(b)
  let c = raw.compare(sdata(a), sdata(b), if na < nb { na } else { nb })
  if c != 0 { return if c < 0 { -1 } else { 1 } }
  (if na > nb { 1 } else { 0 }) - (if na < nb { 1 } else { 0 })
}

pub inline export fn auk_str_hash(s: raw.Ptr<abi.Str>): u64 uses raw, ffi = auk_hash_bytes(sdata(s), usize(slen(s)))

pub export fn auk__str_free(s: raw.Ptr<abi.Str>) uses raw, ffi {
  if !s.is_ascii { forget_cursor(s) }
  rc.auk__free_obj(raw.cast(s))
}

// the element ops of `str`: here, so that the string functions inline into them

fn elem_eq(a: raw.Ptr<()>, b: raw.Ptr<()>): bool uses raw =
  auk_str_eq(raw.cast<raw.Ptr<abi.Str>>(a).load(), raw.cast<raw.Ptr<abi.Str>>(b).load())

fn elem_cmp(a: raw.Ptr<()>, b: raw.Ptr<()>): i32 uses raw =
  auk_str_cmp(raw.cast<raw.Ptr<abi.Str>>(a).load(), raw.cast<raw.Ptr<abi.Str>>(b).load())

fn elem_hash(a: raw.Ptr<()>): u64 uses raw, ffi = auk_str_hash(raw.cast<raw.Ptr<abi.Str>>(a).load())

fn elem_show(a: raw.Ptr<()>): raw.Ptr<abi.Str> uses raw, ffi =
  str_fmt.auk_str_quote(raw.cast<raw.Ptr<abi.Str>>(a).load())

export var auk_ops_str: abi.ElemOps = abi.ElemOps {
  size: 8,
  retain: raw.fn_of(rc.auk__ptr_retain),
  release: raw.fn_of(rc.auk__ptr_release),
  eq: raw.fn_of(elem_eq),
  cmp: raw.fn_of(elem_cmp),
  hash: raw.fn_of(elem_hash),
  show: raw.fn_of(elem_show),
  copy: raw.fn_of(copy.auk__str_copy_elem),
}

// ---- searching ------------------------------------------------------------------------------

/// Byte offset of needle in hay starting at from, or -1.
fn find_bytes(hay: raw.Ptr<u8>, hn: i64, needle: raw.Ptr<u8>, nn: i64, from: i64): i64 uses raw, ffi {
  if nn == 0 { return if from <= hn { from } else { -1 } }
  var i = from
  let c0 = needle.at(0)
  let last = hn - nn  // the last offset a match can start at
  while i <= last {
    // a few bytes inline first: when the first byte is common, a memchr call per candidate
    // costs more than the bytes it skips
    let stop = if i + 16 <= last { i + 16 } else { last + 1 }
    while i < stop && hay.at(i) != c0 { i += 1 }
    if i > last { return -1 }
    if hay.at(i) != c0 {
      let at = c_memchr(hay.offset(i), i32(c0), usize(last + 1 - i))
      if at.is_null() { return -1 }
      i = i64(at.int()) - i64(hay.int())
    }
    // the last byte first: a needle whose first byte is common mostly fails here, inline
    if hay.at(i + nn - 1) == needle.at(nn - 1) && raw.compare(hay.offset(i), needle, nn) == 0 { return i }
    i += 1
  }
  -1
}

fn chars_in(p: raw.Ptr<u8>, n: i64): i64 uses raw {
  var c: i64 = 0
  var i: i64 = 0
  while i < n {
    if (p.at(i) & 0xC0) != 0x80 { c += 1 }
    i += 1
  }
  c
}

/// Sub-string by byte range [a, b) of s (valid UTF-8, a and b on boundaries).
fn sub_bytes(s: raw.Ptr<abi.Str>, a: i64, b: i64): raw.Ptr<abi.Str> uses raw, ffi {
  if !s.is_null() && a == 0 && b == s.len_bytes { return raw.cast(rc.retain(raw.cast(s))) }
  let p = sdata(s).offset(a)
  let ascii = is_ascii(s)
  auk__str_raw(p, b - a, if ascii { b - a } else { chars_in(p, b - a) }, ascii)
}

fn push_own(a: raw.Ptr<raw.Ptr<abi.Arr>>, s: raw.Ptr<abi.Str>) uses raw, ffi {
  var e = s
  auk_arr_push(a, raw.cast(raw.addr_of(&e)))
  rc.release(raw.cast(s))
}

/// ' ', '\t', '\n', '\r', '\v', '\f'
pub fn is_ws(c: u8): bool = c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C

pub export fn auk_str_split_ws(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Arr> uses raw, ffi {
  var out = auk_arr_new(raw.addr_of(&auk_ops_str), 0)
  let p = sdata(s)
  let n = slen(s)
  var i: i64 = 0
  while i < n {
    while i < n && is_ws(p.at(i)) { i += 1 }
    if i >= n { break }
    let st = i
    while i < n && !is_ws(p.at(i)) { i += 1 }
    push_own(raw.addr_of(&out), sub_bytes(s, st, i))
  }
  out
}

pub export fn auk_str_split(s: raw.Ptr<abi.Str>, sep: raw.Ptr<abi.Str>): raw.Ptr<abi.Arr> uses raw, ffi {
  var out = auk_arr_new(raw.addr_of(&auk_ops_str), 0)
  let p = sdata(s)
  let n = slen(s)
  let sn = slen(sep)
  if sn == 0 {
    var i: i64 = 0
    while i < n {
      var len: i64 = 0
      utf8_decode(p, n, i, raw.addr_of(&len))
      push_own(raw.addr_of(&out), sub_bytes(s, i, i + len))
      i += len
    }
    return out
  }
  var st: i64 = 0
  loop {
    let at = find_bytes(p, n, sdata(sep), sn, st)
    if at < 0 { break }
    push_own(raw.addr_of(&out), sub_bytes(s, st, at))
    st = at + sn
  }
  push_own(raw.addr_of(&out), sub_bytes(s, st, n))
  out
}

pub export fn auk_str_trim_start(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> uses raw, ffi {
  let p = sdata(s)
  let n = slen(s)
  var a: i64 = 0
  while a < n && is_ws(p.at(a)) { a += 1 }
  sub_bytes(s, a, n)
}

pub export fn auk_str_trim_end(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> uses raw, ffi {
  let p = sdata(s)
  var b = slen(s)
  while b > 0 && is_ws(p.at(b - 1)) { b -= 1 }
  sub_bytes(s, 0, b)
}

pub export fn auk_str_trim(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> uses raw, ffi {
  let p = sdata(s)
  let n = slen(s)
  var a: i64 = 0
  var b = n
  while a < n && is_ws(p.at(a)) { a += 1 }
  while b > a && is_ws(p.at(b - 1)) { b -= 1 }
  sub_bytes(s, a, b)
}

pub export fn auk_str_lines(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Arr> uses raw, ffi {
  var out = auk_arr_new(raw.addr_of(&auk_ops_str), 0)
  let p = sdata(s)
  let n = slen(s)
  var st: i64 = 0
  while st < n {
    let nl = c_memchr(p.offset(st), 0x0A, usize(n - st))
    let end = if nl.is_null() { n } else { i64(nl.int()) - i64(p.int()) }
    var e = end
    if e > st && p.at(e - 1) == 0x0D { e -= 1 }
    push_own(raw.addr_of(&out), sub_bytes(s, st, e))
    st = end + 1
  }
  out
}

pub inline export fn auk_str_starts_with(s: raw.Ptr<abi.Str>, pre: raw.Ptr<abi.Str>): bool uses raw {
  let n = slen(pre)
  n <= slen(s) && raw.compare(sdata(s), sdata(pre), n) == 0
}

pub inline export fn auk_str_ends_with(s: raw.Ptr<abi.Str>, suf: raw.Ptr<abi.Str>): bool uses raw {
  let n = slen(suf)
  let sn = slen(s)
  n <= sn && raw.compare(sdata(s).offset(sn - n), sdata(suf), n) == 0
}

pub export fn auk_str_contains(s: raw.Ptr<abi.Str>, sub: raw.Ptr<abi.Str>): bool uses raw, ffi =
  find_bytes(sdata(s), slen(s), sdata(sub), slen(sub), 0) >= 0

/// Does s contain the char c? Without building a string for c.
pub export fn auk_str_contains_char(s: raw.Ptr<abi.Str>, c: u32): bool uses raw, ffi {
  let n = slen(s)
  if n == 0 { return false }
  if c < 0x80 { return !c_memchr(s.data, i32(c), usize(n)).is_null() }
  if s.is_ascii { return false }
  var buf: u64 = 0
  let b: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  let bn = i64(utf8_encode(c, b))
  find_bytes(s.data, n, b, bn, 0) >= 0
}

pub export fn auk_str_find(s: raw.Ptr<abi.Str>, sub: raw.Ptr<abi.Str>): abi.OptInt uses raw, ffi {
  let p = sdata(s)
  let at = find_bytes(p, slen(s), sdata(sub), slen(sub), 0)
  if at < 0 { return abi.OptInt {} }
  abi.OptInt { some: true, val: if !s.is_null() && s.is_ascii { at } else { chars_in(p, at) } }
}

pub export fn auk_str_replace(s: raw.Ptr<abi.Str>, from: raw.Ptr<abi.Str>, to: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> uses raw, ffi {
  let f = sdata(from)
  let fn_ = slen(from)
  let p = sdata(s)
  let n = slen(s)
  if fn_ == 0 { return if s.is_null() { auk_str_lit("") } else { raw.cast(rc.retain(raw.cast(s))) } }
  var first = find_bytes(p, n, f, fn_, 0)
  if first < 0 { return if s.is_null() { auk_str_lit("") } else { raw.cast(rc.retain(raw.cast(s))) } }
  var b = abi.StrBuf {}
  let bp = raw.addr_of(&b)
  var st: i64 = 0
  loop {
    let at = if first >= 0 { first } else { find_bytes(p, n, f, fn_, st) }
    first = -1
    if at < 0 { break }
    auk_sb_bytes(bp, p.offset(st), at - st)
    auk_sb_str(bp, to)
    st = at + fn_
  }
  auk_sb_bytes(bp, p.offset(st), n - st)
  auk_sb_finish(bp)
}

fn map_ascii(s: raw.Ptr<abi.Str>, up: bool): raw.Ptr<abi.Str> uses raw, ffi {
  let r = auk__str_raw(sdata(s), slen(s), auk_str_len(s), is_ascii(s))
  let d = r.data
  let n = r.len_bytes
  var i: i64 = 0
  while i < n {
    let c = d.at(i)
    if up && c >= 0x61 && c <= 0x7A { d.at(i) = c - 32 }
    if !up && c >= 0x41 && c <= 0x5A { d.at(i) = c + 32 }
    i += 1
  }
  r
}

pub export fn auk_str_upper(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> uses raw, ffi = map_ascii(s, true)

pub export fn auk_str_lower(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> uses raw, ffi = map_ascii(s, false)

pub export fn auk_str_repeat(s: raw.Ptr<abi.Str>, n: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi {
  if n < 0 {
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    auk__sb_put_cstr(mp, "repeat count ")
    str_fmt.auk_sb_int(mp, n)
    auk__sb_put_cstr(mp, " is negative")
    auk__panic_sb(loc, mp)
    raw.unreachable()
  }
  let bl = slen(s)
  let (total, overflow) = raw.mul_overflow(bl, n)
  if overflow {
    rc.auk_panic_overflow(loc, "repeat")
    raw.unreachable()
  }
  let r: raw.Ptr<abi.Str> = raw.cast(rc.auk__alloc_nz(raw.size_of<abi.Str>() + usize(total) + 1, abi.K_STR))
  if bl > 0 {
    let src = sdata(s)
    var i: i64 = 0
    while i < n {
      raw.copy(r.data.offset(i * bl), src, bl)
      i += 1
    }
  }
  r.data.at(total) = 0
  r.len_bytes = total
  r.len_chars = auk_str_len(s) * n
  r.is_ascii = is_ascii(s)
  r
}

pub export fn auk_str_chars(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Arr> uses raw, ffi {
  let n = auk_str_len(s)
  var out = auk_arr_new(rc.ops_char(), n)
  let d: raw.Ptr<u32> = raw.cast(auk_arr_make_unique(raw.addr_of(&out)))
  let p = sdata(s)
  let bn = slen(s)
  if is_ascii(s) {
    var i: i64 = 0
    while i < bn {
      d.at(i) = u32(p.at(i))
      i += 1
    }
    out.len = bn
    return out
  }
  var i: i64 = 0
  var k: i64 = 0
  while i < bn {
    var len: i64 = 0
    d.at(k) = utf8_decode(p, bn, i, raw.addr_of(&len))
    k += 1
    i += len
  }
  out.len = k
  out
}

pub export fn auk_str_bytes(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Arr> uses raw, ffi {
  let p = sdata(s)
  let n = slen(s)
  var out = auk_arr_new(rc.ops_int(), n)
  let d: raw.Ptr<i64> = raw.cast(auk_arr_make_unique(raw.addr_of(&out)))
  var i: i64 = 0
  while i < n {
    d.at(i) = i64(p.at(i))
    i += 1
  }
  out.len = n
  out
}

/// The UTF-8 length of char c (a surrogate or out-of-range value becomes U+FFFD: 3 bytes).
fn utf8_len(c: u32): i64 {
  if c < 0x80 { return 1 }
  if c < 0x800 { return 2 }
  if c < 0x10000 || c > 0x10FFFF { return 3 }
  4
}

/// One pass to size the string, one to encode straight into it (no builder, no copy).
fn str_of_chars(cs: raw.Ptr<u32>, n: i64): raw.Ptr<abi.Str> uses raw, ffi {
  var bytes: i64 = 0
  var any: u32 = 0
  var i: i64 = 0
  while i < n {
    any |= cs.at(i)
    i += 1
  }
  let ascii = any < 0x80
  if ascii {
    bytes = n
  } else {
    i = 0
    while i < n {
      bytes += utf8_len(cs.at(i))
      i += 1
    }
  }
  let s: raw.Ptr<abi.Str> = raw.cast(rc.auk__alloc_nz(raw.size_of<abi.Str>() + usize(bytes) + 1, abi.K_STR))
  var d = s.data
  if ascii {
    i = 0
    while i < n {
      d.at(i) = u8(cs.at(i))
      i += 1
    }
  } else {
    i = 0
    while i < n {
      d = d.offset(utf8_encode(cs.at(i), d))
      i += 1
    }
  }
  s.data.at(bytes) = 0
  s.len_bytes = bytes
  s.len_chars = n
  s.is_ascii = ascii
  s
}

pub export fn auk_str_from_chars(chars: raw.Ptr<abi.Arr>): raw.Ptr<abi.Str> uses raw, ffi {
  let n = arr_len(chars)
  str_of_chars(if n > 0 { raw.cast(chars.data) } else { raw.null() }, n)
}

pub export fn auk_str_from_char_range(chars: raw.Ptr<abi.Arr>, lo: i64, hi: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi {
  let n = arr_len(chars)
  if lo < 0 || hi < lo || hi > n {
    let _ = auk_arr_slice(chars, lo, hi, loc)  // panics with the slice's message
  }
  str_of_chars(if hi > lo { raw.cast<u32>(chars.data).offset(lo) } else { raw.null() }, hi - lo)
}

// ---- parsing --------------------------------------------------------------------------------

/// "<a>\"<s up to a NUL>\"<b>" as a new error.
fn quoted_err(a: raw.Ptr<u8>, s: raw.Ptr<abi.Str>, b: raw.Ptr<u8>): raw.Ptr<abi.Err> uses raw, ffi {
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  auk__sb_put_cstr(mp, a)
  auk__sb_put_cstr(mp, "\"")
  auk__sb_put_cstr(mp, auk_str_cstr(s))
  auk__sb_put_cstr(mp, "\"")
  auk__sb_put_cstr(mp, b)
  auk__err_sb(mp)
}

pub fn is_digit(c: u8): bool = c >= 0x30 && c <= 0x39

export fn auk_int_parse(s: raw.Ptr<abi.Str>): abi.ResInt uses raw, ffi {
  let p = sdata(s)
  let n = slen(s)
  var i: i64 = 0
  var neg = false
  if i < n && (p.at(i) == 0x2B || p.at(i) == 0x2D) {  // '+' '-'
    neg = p.at(i) == 0x2D
    i += 1
  }
  if i >= n { return abi.ResInt { err: quoted_err("int.parse: invalid int ", s, "") } }
  var acc: u64 = 0
  let limit: u64 = if neg { 9223372036854775808 } else { 9223372036854775807 }
  var prev_digit = false
  while i < n {
    let c = p.at(i)
    if c == 0x5F && prev_digit && i + 1 < n && is_digit(p.at(i + 1)) {  // '_'
      prev_digit = false
      i += 1
      continue
    }
    if !is_digit(c) { return abi.ResInt { err: quoted_err("int.parse: invalid int ", s, "") } }
    let d = u64(c - 0x30)
    if acc > (limit - d) / 10 { return abi.ResInt { err: quoted_err("int.parse: ", s, " is out of range") } }
    acc = acc * 10 + d
    prev_digit = true
    i += 1
  }
  // -acc wraps: 2^63 is INT64_MIN
  abi.ResInt { ok: true, val: if neg { 0 - i64(acc) } else { i64(acc) } }
}

export fn auk_float_parse(s: raw.Ptr<abi.Str>): abi.ResFloat uses raw, ffi {
  let p = sdata(s)
  let n = slen(s)
  var bad = n == 0 || is_ws(p.at(0)) || i64(c_strlen(p)) != n
  // reject hex floats and other strtod extras
  var i: i64 = 0
  while i < n && !bad {
    let c = p.at(i)
    if c == 0x78 || c == 0x58 || c == 0x28 { bad = true }  // 'x' 'X' '('
    i += 1
  }
  if !bad {
    var end: raw.Ptr<u8> = raw.null()
    let d = c_strtod(p, raw.addr_of(&end))
    if end == p.offset(n) { return abi.ResFloat { ok: true, val: d } }
  }
  abi.ResFloat { err: quoted_err("float.parse: invalid float ", s, "") }
}

pub inline export fn auk_char_is_digit(c: u32): bool = c >= 0x30 && c <= 0x39

pub inline export fn auk_char_is_alpha(c: u32): bool = (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)

pub inline export fn auk_char_is_space(c: u32): bool = c < 128 && is_ws(u8(c))

pub inline export fn auk_char_upper(c: u32): u32 = if c >= 0x61 && c <= 0x7A { c - 32 } else { c }

pub inline export fn auk_char_lower(c: u32): u32 = if c >= 0x41 && c <= 0x5A { c + 32 } else { c }

pub inline export fn auk_char_from_int(n: i64): abi.OptChar {
  if n < 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF) { return abi.OptChar {} }
  abi.OptChar { some: true, val: u32(n) }
}
