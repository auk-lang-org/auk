/// The core library's shared helpers (was the top of runtime/c/core.c, ported line by line):
/// results, errors with a code, bytes to and from `[int]`, a growable byte buffer, reading a
/// whole `FILE *`. Used by `core_fs`, `core_net`, `core_env` and `core_proc`.

// the rest of the runtime (C, for now)
extern fn auk__xmalloc(n: usize): raw.Ptr<()> = "void *auk__xmalloc(size_t)"
extern fn auk__xrealloc(p: raw.Ptr<()>, n: usize): raw.Ptr<()> = "void *auk__xrealloc(void *, size_t)"
extern fn auk_arr_make_unique(pa: raw.Ptr<raw.Ptr<abi.Arr>>): raw.Ptr<()> = "void *auk_arr_make_unique(void *)"
extern fn auk_arr_len(a: raw.Ptr<abi.Arr>): i64 = "int64_t auk_arr_len(const void *)"
extern var auk_ops_int: abi.ElemOps = "auk_ops_int"
// libc
extern fn fread(p: raw.Ptr<()>, size: usize, n: usize, f: raw.Ptr<()>): usize = "size_t fread(void *, size_t, size_t, void *)"
extern fn ferror(f: raw.Ptr<()>): i32 = "int ferror(void *)"

/// An Err with the builder's text (consumed) and code.
pub fn err_code_sb(b: raw.Ptr<abi.StrBuf>, code: i32): raw.Ptr<abi.Err> uses raw, ffi {
  let e = str.auk__err_sb(b)
  e.code = i64(code)
  e
}

pub fn unit_ok(): abi.ResUnit = abi.ResUnit { ok: true }
pub fn unit_err(e: raw.Ptr<abi.Err>): abi.ResUnit = abi.ResUnit { err: e }
pub fn str_err(e: raw.Ptr<abi.Err>): abi.ResStr = abi.ResStr { err: e }
pub fn arr_ok(a: raw.Ptr<abi.Arr>): abi.ResArr = abi.ResArr { ok: true, val: a }
pub fn arr_err(e: raw.Ptr<abi.Err>): abi.ResArr = abi.ResArr { err: e }

/// n bytes as a fresh [int] (0..255).
pub export fn auk__bytes_to_arr(b: raw.Ptr<u8>, n: i64): raw.Ptr<abi.Arr> uses raw, ffi {
  var a = arr.auk_arr_new(raw.addr_of(&auk_ops_int), n)
  let d: raw.Ptr<i64> = raw.cast(auk_arr_make_unique(raw.addr_of(&a)))
  var i: i64 = 0
  while i < n {
    d.at(i) = i64(b.at(i))
    i += 1
  }
  a.len = n
  a
}

/// An [int] as bytes (malloc'd, *n of them), or null with the first index and value outside
/// 0..255 in *bad_i and *bad_x.
pub fn arr_to_bytes(a: raw.Ptr<abi.Arr>, n: raw.Ptr<i64>, bad_i: raw.Ptr<i64>, bad_x: raw.Ptr<i64>): raw.Ptr<u8> uses raw, ffi {
  let len = auk_arr_len(a)
  let xs: raw.Ptr<i64> = if len > 0 { raw.cast(a.data) } else { raw.null() }
  let buf: raw.Ptr<u8> = raw.cast(auk__xmalloc(usize(len) + 1))
  var i: i64 = 0
  while i < len {
    let x = xs.at(i)
    if x < 0 || x > 255 {
      raw.free(buf)
      bad_i.store(i)
      bad_x.store(x)
      return raw.null()
    }
    buf.at(i) = u8(x)
    i += 1
  }
  n.store(len)
  buf
}

/// A growable byte buffer.
pub raw struct Bytes {
  p: raw.Ptr<u8>,
  n: i64,
  cap: i64,
}

pub fn bytes_add(b: raw.Ptr<Bytes>, p: raw.Ptr<u8>, n: i64) uses raw, ffi {
  if b.n + n > b.cap {
    var cap: i64 = if b.cap == 0 { 65536 } else { b.cap }
    while cap < b.n + n {
      cap *= 2
    }
    b.p = raw.cast(auk__xrealloc(raw.cast(b.p), usize(cap)))
    b.cap = cap
  }
  raw.copy(b.p.offset(b.n), p, n)
  b.n += n
}

/// Read all of f (a FILE *) into b; returns 0 or an errno.
pub fn slurp(f: raw.Ptr<()>, b: raw.Ptr<Bytes>): i32 uses raw, ffi {
  let buf: raw.Ptr<u8> = raw.cast(auk__xmalloc(65536))
  loop {
    let n = fread(raw.cast(buf), 1, 65536, f)
    if n == 0 {
      break
    }
    bytes_add(b, buf, i64(n))
  }
  raw.free(buf)
  if ferror(f) != 0 {
    let e = cfacts.errno()
    return if e != 0 { e } else { cfacts.EIO }
  }
  0
}
