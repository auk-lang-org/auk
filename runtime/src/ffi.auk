/// User-level FFI (docs/ffi-plan.md): the core `ffi` module (`ffi.Ptr`, raw memory) and the
/// helpers generated code calls to marshal values to and from C: C strings and C arrays of list
/// elements. An `ffi.Ptr` (and every `extern type` of user code) is a plain machine address: not
/// reference counted, never freed automatically. (Was runtime/c/ffi.c, ported line by line.)

// the rest of the runtime (C, for now)
extern fn auk__fmt_hex(out: raw.Ptr<u8>, v: u64, min_digits: i32, upper: bool): i32 =
  "int auk__fmt_hex(char *, uint64_t, int, bool)"
extern fn auk__xmalloc(n: usize): raw.Ptr<()> = "void *auk__xmalloc(size_t)"
extern fn auk_str_lit(s: raw.Ptr<u8>): raw.Ptr<abi.Str> = "void *auk_str_lit(const char *)"
extern fn auk_str_cstr(s: raw.Ptr<abi.Str>): raw.Ptr<u8> = "const char *auk_str_cstr(const void *)"
extern fn auk__sb_put_cstr(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<u8>) = "void auk__sb_put_cstr(void *, const char *)"
extern fn auk__sb_take_into(b: raw.Ptr<abi.StrBuf>, out: raw.Ptr<u8>, cap: usize) =
  "void auk__sb_take_into(void *, char *, size_t)"
// _Noreturn: its callers say `raw.unreachable()` (no `never` here, TODO(dialect))
extern fn auk_panic_str(loc: raw.Ptr<u8>, msg: raw.Ptr<u8>) = "void auk_panic_str(const char *, const char *)"
extern fn auk_arr_new(ops: raw.Ptr<abi.ElemOps>, cap: i64): raw.Ptr<abi.Arr> = "void *auk_arr_new(const void *, int64_t)"
extern fn auk_arr_make_unique(pa: raw.Ptr<raw.Ptr<abi.Arr>>): raw.Ptr<()> = "void *auk_arr_make_unique(void *)"
extern var auk_ops_int: abi.ElemOps = "auk_ops_int"
// libc
extern fn calloc(n: usize, size: usize): raw.Ptr<()> = "void *calloc(size_t, size_t)"
extern fn dlsym(handle: raw.Ptr<()>, name: raw.Ptr<u8>): raw.Ptr<()> = "void *dlsym(void *, const char *)"

/// C's `char m[N]` locals (a fixed array is a raw struct's field, not a local's type).
raw struct Buf32 {
  b: [u8; 32],
}

raw struct Buf96 {
  b: [u8; 96],
}

raw struct Buf160 {
  b: [u8; 160],
}

// ---- ffi.Ptr ------------------------------------------------------------------------------

export fn auk_ffi_ptr(addr: i64): raw.Ptr<()> uses raw = raw.from_int(addr)

export fn auk_ffi_addr(p: raw.Ptr<()>): i64 uses raw = i64(p.int())

/// "0x1f2e3d" (`"{p}"`); NULL is "0x0".
export fn auk_ffi_ptr_show(p: raw.Ptr<()>): raw.Ptr<abi.Str> uses raw, ffi {
  var buf = Buf32 {}
  let b: raw.Ptr<u8> = raw.cast(raw.addr_of(&buf))
  b.at(0) = 48 // '0'
  b.at(1) = 120 // 'x'
  let _ = auk__fmt_hex(b.offset(2), u64(p.int()), 1, false)
  auk_str_lit(b)
}

export fn auk_ffi_alloc(n: i64, loc: raw.Ptr<u8>): raw.Ptr<()> uses raw, ffi {
  if n < 0 {
    auk_panic_str(loc, "ffi.alloc: negative size")
    raw.unreachable()
  }
  let p = calloc(1, if n == 0 { 1 } else { usize(n) })
  if p.is_null() {
    auk_panic_str(loc, "ffi.alloc: out of memory")
    raw.unreachable()
  }
  p
}

/// ffi.symbol: the address of C symbol `name` in this process (the executable, the runtime,
/// every loaded library), or NULL. `auk build` exports the runtime's symbols from executables,
/// so a compiler written in Auk finds them for the code it JIT-compiles.
export fn auk_ffi_symbol(name: raw.Ptr<abi.Str>): raw.Ptr<()> uses raw, ffi =
  dlsym(raw.from_int(cfacts.RTLD_DEFAULT), auk_str_cstr(name))

export fn auk_ffi_free(p: raw.Ptr<()>) uses raw = raw.free(p)

fn check_ptr(p: raw.Ptr<u8>, what: raw.Ptr<u8>, loc: raw.Ptr<u8>) uses raw, ffi {
  if p.is_null() {
    var m = Buf96 {}
    var b = abi.StrBuf {}
    auk__sb_put_cstr(raw.addr_of(&b), "ffi.")
    auk__sb_put_cstr(raw.addr_of(&b), what)
    auk__sb_put_cstr(raw.addr_of(&b), " through a null pointer")
    auk__sb_take_into(raw.addr_of(&b), raw.cast(raw.addr_of(&m)), raw.size_of<Buf96>())
    auk_panic_str(loc, raw.cast(raw.addr_of(&m)))
    raw.unreachable()
  }
}

export fn auk_ffi_read_u8(p: raw.Ptr<u8>, off: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  check_ptr(p, "read_u8", loc)
  i64(p.at(off))
}

export fn auk_ffi_read_i32(p: raw.Ptr<u8>, off: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  check_ptr(p, "read_i32", loc)
  var v: i32 = 0
  raw.copy(raw.addr_of(&v), p.offset(off), 4)
  i64(v)
}

export fn auk_ffi_read_i64(p: raw.Ptr<u8>, off: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  check_ptr(p, "read_i64", loc)
  var v: i64 = 0
  raw.copy(raw.addr_of(&v), p.offset(off), 8)
  v
}

export fn auk_ffi_read_f64(p: raw.Ptr<u8>, off: i64, loc: raw.Ptr<u8>): float uses raw, ffi {
  check_ptr(p, "read_f64", loc)
  var v: float = 0.0
  raw.copy(raw.addr_of(&v), p.offset(off), 8)
  v
}

export fn auk_ffi_read_ptr(p: raw.Ptr<u8>, off: i64, loc: raw.Ptr<u8>): raw.Ptr<()> uses raw, ffi {
  check_ptr(p, "read_ptr", loc)
  var v: raw.Ptr<()> = raw.null()
  raw.copy(raw.addr_of(&v), p.offset(off), 8)
  v
}

export fn auk_ffi_write_u8(p: raw.Ptr<u8>, off: i64, v: i64, loc: raw.Ptr<u8>) uses raw, ffi {
  check_ptr(p, "write_u8", loc)
  p.at(off) = u8(v)
}

export fn auk_ffi_write_i32(p: raw.Ptr<u8>, off: i64, v: i64, loc: raw.Ptr<u8>) uses raw, ffi {
  check_ptr(p, "write_i32", loc)
  var x = i32(v)
  raw.copy(p.offset(off), raw.addr_of(&x), 4)
}

export fn auk_ffi_write_i64(p: raw.Ptr<u8>, off: i64, v: i64, loc: raw.Ptr<u8>) uses raw, ffi {
  check_ptr(p, "write_i64", loc)
  var x = v
  raw.copy(p.offset(off), raw.addr_of(&x), 8)
}

export fn auk_ffi_write_f64(p: raw.Ptr<u8>, off: i64, v: float, loc: raw.Ptr<u8>) uses raw, ffi {
  check_ptr(p, "write_f64", loc)
  var x = v
  raw.copy(p.offset(off), raw.addr_of(&x), 8)
}

export fn auk_ffi_write_ptr(p: raw.Ptr<u8>, off: i64, v: raw.Ptr<()>, loc: raw.Ptr<u8>) uses raw, ffi {
  check_ptr(p, "write_ptr", loc)
  var x = v
  raw.copy(p.offset(off), raw.addr_of(&x), 8)
}

/// ffi.cstr: the C string at p, copied (invalid UTF-8 becomes U+FFFD).
export fn auk_ffi_cstr(p: raw.Ptr<u8>, loc: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi {
  check_ptr(p, "cstr", loc)
  auk_str_lit(p)
}

/// ffi.bytes: n bytes at p as a list of ints 0..255.
export fn auk_ffi_bytes(p: raw.Ptr<u8>, n: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Arr> uses raw, ffi {
  if n < 0 {
    auk_panic_str(loc, "ffi.bytes: negative length")
    raw.unreachable()
  }
  var out = auk_arr_new(raw.addr_of(&auk_ops_int), n)
  if n == 0 {
    return out
  }
  check_ptr(p, "bytes", loc)
  let d: raw.Ptr<i64> = raw.cast(auk_arr_make_unique(raw.addr_of(&out)))
  var i: i64 = 0
  while i < n {
    d.at(i) = i64(p.at(i))
    i += 1
  }
  out.len = n
  out
}

// ---- marshalling (generated code) ---------------------------------------------------------

/// A string result of a C function: copied; NULL panics (`str`, not `str?`).
export fn auk_ffi_str(p: raw.Ptr<u8>, func: raw.Ptr<u8>, loc: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi {
  if p.is_null() {
    var m = Buf160 {}
    var b = abi.StrBuf {}
    auk__sb_put_cstr(raw.addr_of(&b), func)
    auk__sb_put_cstr(raw.addr_of(&b), " returned NULL where a `str` was expected (declare the result `str?`)")
    auk__sb_take_into(raw.addr_of(&b), raw.cast(raw.addr_of(&m)), raw.size_of<Buf160>())
    auk_panic_str(loc, raw.cast(raw.addr_of(&m)))
    raw.unreachable()
  }
  auk_str_lit(p)
}

/// A `str?` from C: NULL stays NULL (the `none` case), anything else is copied.
export fn auk_ffi_str_or_null(p: raw.Ptr<u8>): raw.Ptr<abi.Str> uses raw, ffi =
  if p.is_null() { raw.null() } else { auk_str_lit(p) }

/// The size of one element of kind in a C array (rawsz: the list's own element size).
fn elem_size(kind: i32, rawsz: usize): usize {
  let k = i64(kind)
  if k == abi.FFI_I8 || k == abi.FFI_U8 {
    1
  } else if k == abi.FFI_I16 || k == abi.FFI_U16 {
    2
  } else if k == abi.FFI_I32 || k == abi.FFI_U32 || k == abi.FFI_F32 {
    4
  } else {
    rawsz
  }
}

/// A malloc'd C array of a list's elements (`[T]` passed as `T *`), converted to `kind`. Never
/// NULL, so C sees a valid pointer for an empty list; free it with auk_ffi_free.
export fn auk_ffi_arr_in(a: raw.Ptr<abi.Arr>, kind: i32): raw.Ptr<()> uses raw, ffi {
  let n: i64 = if a.is_null() { 0 } else { a.len }
  let rawsz: usize = if a.is_null() { 8 } else { a.ops.size }
  let sz = elem_size(kind, rawsz)
  let buf: raw.Ptr<u8> = raw.cast(auk__xmalloc(if n == 0 { 1 } else { usize(n) * sz }))
  if n == 0 {
    return raw.cast(buf)
  }
  let src = a.data
  let k = i64(kind)
  if k == abi.FFI_RAW {
    raw.copy(buf, src, usize(n) * sz)
    return raw.cast(buf)
  }
  var i: i64 = 0
  while i < n {
    if k == abi.FFI_F32 {
      var x: float = 0.0
      raw.copy(raw.addr_of(&x), src.offset(i * 8), 8)
      var f = f32(x)
      raw.copy(buf.offset(i * 4), raw.addr_of(&f), 4)
    } else {
      var x: i64 = 0
      raw.copy(raw.addr_of(&x), src.offset(i * 8), 8)
      if k == abi.FFI_I8 || k == abi.FFI_U8 {
        let v = u8(x)
        buf.at(i) = v
      } else if k == abi.FFI_I16 || k == abi.FFI_U16 {
        var v = u16(x)
        raw.copy(buf.offset(i * 2), raw.addr_of(&v), 2)
      } else {
        var v = u32(x)
        raw.copy(buf.offset(i * 4), raw.addr_of(&v), 4)
      }
    }
    i += 1
  }
  raw.cast(buf)
}

/// After a call that may have written the C array `buf` (a `var [T]` argument): copy it back
/// into the list (made unique first) and free it.
export fn auk_ffi_arr_out(pa: raw.Ptr<raw.Ptr<abi.Arr>>, buf: raw.Ptr<()>, kind: i32) uses raw, ffi {
  let a0 = pa.load()
  let n: i64 = if a0.is_null() { 0 } else { a0.len }
  if n == 0 {
    raw.free(buf)
    return
  }
  let rawsz = a0.ops.size
  let d: raw.Ptr<u8> = raw.cast(auk_arr_make_unique(pa))
  let src: raw.Ptr<u8> = raw.cast(buf)
  let k = i64(kind)
  if k == abi.FFI_RAW {
    raw.copy(d, src, usize(n) * rawsz)
    raw.free(buf)
    return
  }
  var i: i64 = 0
  while i < n {
    var v: i64 = 0
    if k == abi.FFI_I8 {
      v = i64(i8(src.at(i)))
    } else if k == abi.FFI_U8 {
      v = i64(src.at(i))
    } else if k == abi.FFI_I16 {
      var x: i16 = 0
      raw.copy(raw.addr_of(&x), src.offset(i * 2), 2)
      v = i64(x)
    } else if k == abi.FFI_U16 {
      var x: u16 = 0
      raw.copy(raw.addr_of(&x), src.offset(i * 2), 2)
      v = i64(x)
    } else if k == abi.FFI_I32 {
      var x: i32 = 0
      raw.copy(raw.addr_of(&x), src.offset(i * 4), 4)
      v = i64(x)
    } else if k == abi.FFI_U32 {
      var x: u32 = 0
      raw.copy(raw.addr_of(&x), src.offset(i * 4), 4)
      v = i64(x)
    }
    if k == abi.FFI_F32 {
      var f: f32 = 0.0
      raw.copy(raw.addr_of(&f), src.offset(i * 4), 4)
      var x = float(f)
      raw.copy(d.offset(i * 8), raw.addr_of(&x), 8)
    } else {
      raw.copy(d.offset(i * 8), raw.addr_of(&v), 8)
    }
    i += 1
  }
  raw.free(buf)
}

/// ffi.from_bytes: a malloc'd copy of the bytes (ints 0..255); the caller frees it.
export fn auk_ffi_from_bytes(a: raw.Ptr<abi.Arr>): raw.Ptr<()> uses raw, ffi = auk_ffi_arr_in(a, i32(abi.FFI_U8))
