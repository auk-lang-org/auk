/// The debugger engine's text helpers (was the "text helpers" part of runtime/c/dbg.c, ported
/// line by line): a growable NUL-terminated text (`Text`, C's `DText`), JSON strings, words,
/// whole numbers, cutting a value's text at a UTF-8 boundary. dbg.auk is the engine.

extern fn c_strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn strcmp(a: raw.Ptr<u8>, b: raw.Ptr<u8>): i32 = "int strcmp(const char *, const char *)"
extern fn strtoll(s: raw.Ptr<u8>, end: raw.Ptr<raw.Ptr<u8>>, base: i32): i64 = "long long strtoll(const char *, char **, int)"

/// A growable NUL-terminated text (zeroed: empty, p null).
pub raw struct Text {
  p: raw.Ptr<u8>,
  n: usize,
  cap: usize,
}

pub fn add(t: raw.Ptr<Text>, s: raw.Ptr<u8>, n: usize) uses raw, ffi {
  if t.n + n + 1 > t.cap {
    var cap: usize = if t.cap == 0 { 128 } else { t.cap * 2 }
    while cap < t.n + n + 1 {
      cap *= 2
    }
    t.p = raw.cast(raw.realloc(t.p, cap))
    t.cap = cap
  }
  raw.copy(t.p.offset(t.n), s, n)
  t.n += n
  t.p.at(t.n) = 0
}

pub fn put(t: raw.Ptr<Text>, s: raw.Ptr<u8>) uses raw, ffi {
  add(t, s, c_strlen(s))
}

pub fn put_int(t: raw.Ptr<Text>, v: i64) uses raw, ffi {
  var b: [u8; 24]
  let bp = raw.cast<u8>(raw.addr_of(&b))
  let n = str_fmt.auk__fmt_i64(bp, v)
  add(t, bp, usize(n))
}

/// A JSON string of s[0..n) (UTF-8).
pub fn json(t: raw.Ptr<Text>, s: raw.Ptr<u8>, n: usize) uses raw, ffi {
  put(t, "\"")
  var i: usize = 0
  while i < n {
    let c = s.at(i)
    if c == 0x22 {
      put(t, "\\\"")
    } else if c == 0x5C {
      put(t, "\\\\")
    } else if c == 0x0A {
      put(t, "\\n")
    } else if c == 0x0D {
      put(t, "\\r")
    } else if c == 0x09 {
      put(t, "\\t")
    } else if c < 0x20 {
      var u: [u8; 24]
      let up = raw.cast<u8>(raw.addr_of(&u))
      let k = str_fmt.auk__fmt_hex(up, u64(c), 4, false)
      put(t, "\\u")
      add(t, up, usize(k))
    } else {
      add(t, s.offset(i), 1)
    }
    i += 1
  }
  put(t, "\"")
}

pub fn jsonc(t: raw.Ptr<Text>, s: raw.Ptr<u8>) uses raw, ffi {
  json(t, s, c_strlen(s))
}

/// s JSON-escaped without the quotes (malloc'd).
pub fn esc(s: raw.Ptr<u8>): raw.Ptr<u8> uses raw, ffi {
  var t = Text {}
  jsonc(raw.addr_of(&t), s)
  let r: raw.Ptr<u8> = raw.cast(raw.alloc(t.n - 1))
  raw.copy(r, t.p.offset(1), t.n - 2)
  r.at(t.n - 2) = 0
  raw.free(t.p)
  r
}

pub fn dup_n(s: raw.Ptr<u8>, n: usize): raw.Ptr<u8> uses raw, ffi {
  let r: raw.Ptr<u8> = raw.cast(raw.alloc(n + 1))
  raw.copy(r, s, n)
  r.at(n) = 0
  r
}

pub fn dup_s(s: raw.Ptr<u8>): raw.Ptr<u8> uses raw, ffi = dup_n(s, c_strlen(s))

pub fn len(s: raw.Ptr<u8>): usize uses ffi = c_strlen(s)

/// strcmp(a, b) == 0.
pub fn eq(a: raw.Ptr<u8>, b: raw.Ptr<u8>): bool uses ffi = strcmp(a, b) == 0

pub fn is_space(c: u8): bool = c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C

pub fn skip_space(s0: raw.Ptr<u8>): raw.Ptr<u8> uses raw {
  var s = s0
  while s.load() != 0 && is_space(s.load()) {
    s = s.offset(1)
  }
  s
}

/// text after its first n whitespace-separated words.
pub fn after_words(text: raw.Ptr<u8>, n: i64): raw.Ptr<u8> uses raw {
  var t = skip_space(text)
  var i: i64 = 0
  while i < n {
    while t.load() != 0 && !is_space(t.load()) {
      t = t.offset(1)
    }
    t = skip_space(t)
    i += 1
  }
  t
}

/// The whitespace-separated words of s (malloc'd array of malloc'd strings, *n of them).
pub fn split_words(s: raw.Ptr<u8>, n: raw.Ptr<i64>): raw.Ptr<raw.Ptr<u8>> uses raw, ffi {
  var w: raw.Ptr<raw.Ptr<u8>> = raw.null()
  var k: i64 = 0
  var cap: i64 = 0
  var p = skip_space(s)
  while p.load() != 0 {
    var e = p
    while e.load() != 0 && !is_space(e.load()) {
      e = e.offset(1)
    }
    if k == cap {
      cap = if cap == 0 { 8 } else { cap * 2 }
      w = raw.cast(raw.realloc(w, usize(cap) * raw.size_of<raw.Ptr<u8>>()))
    }
    w.at(k) = dup_n(p, usize(e.int() - p.int()))
    k += 1
    p = skip_space(e)
  }
  n.store(k)
  w
}

pub fn free_words(w: raw.Ptr<raw.Ptr<u8>>, n: i64) uses raw {
  var i: i64 = 0
  while i < n {
    raw.free(w.at(i))
    i += 1
  }
  raw.free(w)
}

/// A whole decimal number (an optional sign, then digits).
pub fn parse_i64(s: raw.Ptr<u8>, out: raw.Ptr<i64>): bool uses raw, ffi {
  if s.is_null() || s.load() == 0 {
    return false
  }
  var end: raw.Ptr<u8> = raw.null()
  cfacts.set_errno(0)
  let v = strtoll(s, raw.addr_of(&end), 10)
  if end.load() != 0 || cfacts.errno() != 0 || is_space(s.load()) {
    return false
  }
  out.store(v)
  true
}

/// s cut to at most max bytes at a UTF-8 boundary, with "…" when cut (malloc'd).
pub fn cut_text(s: raw.Ptr<u8>, n: usize, max: usize): raw.Ptr<u8> uses raw, ffi {
  if n <= max {
    return dup_n(s, n)
  }
  var end = max
  while end > 0 && (s.at(end) & 0xC0) == 0x80 {
    end -= 1
  }
  let r: raw.Ptr<u8> = raw.cast(raw.alloc(end + 4))
  raw.copy(r, s, end)
  let ell: raw.Ptr<u8> = "\u{2026}"
  raw.copy(r.offset(end), ell, 4)
  r
}

/// s trimmed of surrounding whitespace (malloc'd).
pub fn trimmed(s0: raw.Ptr<u8>): raw.Ptr<u8> uses raw, ffi {
  let s = skip_space(s0)
  var n = c_strlen(s)
  while n > 0 && is_space(s.at(n - 1)) {
    n -= 1
  }
  dup_n(s, n)
}

/// Does s end with suffix?
pub fn ends_with(s: raw.Ptr<u8>, suffix: raw.Ptr<u8>): bool uses raw, ffi {
  let n = c_strlen(s)
  let k = c_strlen(suffix)
  k <= n && raw.compare(s.offset(n - k), suffix, k) == 0
}

/// n zeroed bytes (C's auk__xcalloc; raw.alloc aborts on failure).
pub fn zalloc(n: usize): raw.Ptr<()> uses raw {
  let p: raw.Ptr<u8> = raw.cast(raw.alloc(n))
  raw.fill(p, 0, n)
  raw.cast(p)
}
