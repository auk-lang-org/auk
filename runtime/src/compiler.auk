/// Small entry points used only by compiler-generated code: messages that the generated code
/// would otherwise format itself, hashing helpers, and the imprint evaluator's protocol
/// (compile-time evaluation of `imprint` constants) (was runtime/c/compiler.c, ported line by
/// line).

// the rest of the runtime (C, for now)
extern fn auk__sb_put_cstr(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<u8>) = "void auk__sb_put_cstr(void *, const char *)"
extern fn auk__err_sb(b: raw.Ptr<abi.StrBuf>): raw.Ptr<abi.Err> = "void *auk__err_sb(void *)"
extern fn auk_str_cstr(s: raw.Ptr<abi.Str>): raw.Ptr<u8> = "const char *auk_str_cstr(const void *)"
extern fn auk_str_byte_len(s: raw.Ptr<abi.Str>): i64 = "int64_t auk_str_byte_len(const void *)"
extern fn auk__fmt_i64(out: raw.Ptr<u8>, v: i64): i32 = "int auk__fmt_i64(char *, int64_t)"
extern fn auk__fmt_hex(out: raw.Ptr<u8>, v: u64, min_digits: i32, upper: bool): i32 = "int auk__fmt_hex(char *, uint64_t, int, bool)"
extern fn auk_arr_len(a: raw.Ptr<abi.Arr>): i64 = "int64_t auk_arr_len(const void *)"
extern fn auk_map_len(m: raw.Ptr<abi.Map>): i64 = "int64_t auk_map_len(const void *)"
extern fn auk_map_next(m: raw.Ptr<abi.Map>, it: raw.Ptr<i64>, k: raw.Ptr<raw.Ptr<()>>, v: raw.Ptr<raw.Ptr<()>>): bool =
  "bool auk_map_next(const void *, int64_t *, void **, void **)"
// rc.c's, declared by value.auk (a second `extern var` of one symbol would link to `auk_ops_float.1`)
raw let OPS_FLOAT: raw.Ptr<abi.ElemOps> = raw.addr_of(&value.auk_ops_float)
// libc
extern fn fopen(path: raw.Ptr<u8>, mode: raw.Ptr<u8>): raw.Ptr<()> = "FILE *fopen(const char *, const char *)"
extern fn fclose(f: raw.Ptr<()>): i32 = "int fclose(FILE *)"
extern fn fputc(c: i32, f: raw.Ptr<()>): i32 = "int fputc(int, FILE *)"
extern fn fwrite(p: raw.Ptr<()>, size: usize, n: usize, f: raw.Ptr<()>): usize = "size_t fwrite(const void *, size_t, size_t, FILE *)"
extern fn fflush(f: raw.Ptr<()>): i32 = "int fflush(FILE *)"
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(pthread_mutex_t *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(pthread_mutex_t *)"
extern fn c_exit(code: i32): never = "void _exit(int)"

/// <prefix><Value tag name> as a new error (from_value's "expected X for `T`, got Y").
export fn auk__err_with_tag(prefix: raw.Ptr<u8>, tag: i32): raw.Ptr<abi.Err> uses raw, ffi {
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  auk__sb_put_cstr(mp, prefix)
  auk__sb_put_cstr(mp, value.auk_value_tag_name(u32(tag)))
  auk__err_sb(mp)
}

/// <a><s up to a NUL><b> as a new error.
export fn auk__err_concat(a: raw.Ptr<u8>, s: raw.Ptr<abi.Str>, b: raw.Ptr<u8>): raw.Ptr<abi.Err> uses raw, ffi {
  var m = abi.StrBuf {}
  let mp = raw.addr_of(&m)
  auk__sb_put_cstr(mp, a)
  auk__sb_put_cstr(mp, auk_str_cstr(s))
  auk__sb_put_cstr(mp, b)
  auk__err_sb(mp)
}

/// The hash of a float (as the float element ops hash it).
export fn auk_hash_float(x: float): u64 uses raw, ffi {
  let hash = OPS_FLOAT.hash
  hash(raw.cast(raw.addr_of(&x)))
}

/// The hash of a Value (as the Value element ops hash it: value.auk's auk_ops_value.hash).
export fn auk_value_hash(v: raw.Ptr<abi.Value>): u64 uses raw, ffi = value.elem_hash(raw.cast(v))

// ---- the imprint evaluator's records -------------------------------------------------------
// Records go to the file named by the helper's argv[1]: `B<c>\n` / `E<c>\n` when constant c
// starts / finishes computing, `C<c>\n` (then exit 3) when it is needed while being computed,
// and `V<c> <value>\n` for each imprint's value: `N`, `T`, `F`, `I<int>;`, `D<16 hex digits:
// the f64 bits>;`, `S<n>:<n bytes>`, `L<n>;<n values>` or `M<n>;<n (S-key, value) pairs>`.

raw var imprint_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
/// A FILE *.
raw var imprint_out: raw.Ptr<()> = raw.null()

/// Open the records file named by argv[1]; false without one.
export fn auk__imprint_open(argc: i32, argv: raw.Ptr<raw.Ptr<u8>>): bool uses raw, ffi {
  if argc < 2 {
    return false
  }
  let f = fopen(argv.at(1), "wb")
  if f.is_null() {
    return false
  }
  pthread_mutex_lock(raw.addr_of(&imprint_lock))
  imprint_out = f
  pthread_mutex_unlock(raw.addr_of(&imprint_lock))
  true
}

export fn auk__imprint_close() uses raw, ffi {
  pthread_mutex_lock(raw.addr_of(&imprint_lock))
  if !imprint_out.is_null() {
    fclose(imprint_out)
  }
  imprint_out = raw.null()
  let _ = pthread_mutex_unlock(raw.addr_of(&imprint_lock))
}

raw struct NumBuf { b: [u8; 24] }

/// v in decimal to f.
fn imprint_put_int(f: raw.Ptr<()>, v: i64) uses raw, ffi {
  var b = NumBuf {}
  let bp: raw.Ptr<u8> = raw.cast(raw.addr_of(&b))
  let n = auk__fmt_i64(bp, v)
  let _ = fwrite(raw.cast(bp), 1, usize(n), f)
}

/// bits as 16 lowercase hex digits to f.
fn imprint_put_hex16(f: raw.Ptr<()>, bits: i64) uses raw, ffi {
  var b = NumBuf {}
  let bp: raw.Ptr<u8> = raw.cast(raw.addr_of(&b))
  let n = auk__fmt_hex(bp, u64(bits), 16, false)
  let _ = fwrite(raw.cast(bp), 1, usize(n), f)
}

export fn auk__imprint_mark(tag: i32, c: i64) uses raw, ffi {
  pthread_mutex_lock(raw.addr_of(&imprint_lock))
  let f = imprint_out
  if !f.is_null() {
    // C's fputc((char)tag, f): fputc writes the low byte
    putc(f, i32(u8(tag)))
    imprint_put_int(f, c)
    putc(f, 10) // '\n'
    fflush(f)
  }
  pthread_mutex_unlock(raw.addr_of(&imprint_lock))
  if u8(tag) == 67 { // 'C'
    c_exit(3)
  }
}

/// fputc(c, f), its result unused.
fn putc(f: raw.Ptr<()>, c: i32) uses raw, ffi {
  let _ = fputc(c, f)
}

fn dump_str(f: raw.Ptr<()>, s: raw.Ptr<abi.Str>) uses raw, ffi {
  let n = auk_str_byte_len(s)
  putc(f, 83) // 'S'
  imprint_put_int(f, n)
  putc(f, 58) // ':'
  let _ = fwrite(raw.cast(auk_str_cstr(s)), 1, usize(n), f)
}

fn dump(f: raw.Ptr<()>, v: raw.Ptr<abi.Value>) uses raw, ffi {
  let t = v.tag
  if t == abi.V_NULL {
    putc(f, 78) // 'N'
  } else if t == abi.V_BOOL {
    putc(f, if v.u.b { 84 } else { 70 }) // 'T' / 'F'
  } else if t == abi.V_INT {
    putc(f, 73) // 'I'
    imprint_put_int(f, v.u.i)
    putc(f, 59) // ';'
  } else if t == abi.V_FLOAT {
    putc(f, 68) // 'D'
    // auk_fbits: the f64's bits
    imprint_put_hex16(f, raw.cast<i64>(raw.field_addr(v, .u)).load())
    putc(f, 59)
  } else if t == abi.V_STR {
    dump_str(f, v.u.s)
  } else if t == abi.V_LIST {
    let a = v.u.list
    let n = auk_arr_len(a)
    putc(f, 76) // 'L'
    imprint_put_int(f, n)
    putc(f, 59)
    let items: raw.Ptr<abi.Value> = raw.cast(a.data)
    var i: i64 = 0
    while i < n {
      dump(f, items.offset(i))
      i += 1
    }
  } else if t == abi.V_MAP {
    let m = v.u.map
    putc(f, 77) // 'M'
    imprint_put_int(f, auk_map_len(m))
    putc(f, 59)
    var it: i64 = 0
    var kp: raw.Ptr<()> = raw.null()
    var vp: raw.Ptr<()> = raw.null()
    while auk_map_next(m, raw.addr_of(&it), raw.addr_of(&kp), raw.addr_of(&vp)) {
      dump_str(f, raw.cast<raw.Ptr<abi.Str>>(kp).load())
      dump(f, raw.cast(vp))
    }
  }
}

export fn auk__imprint_value(c: i64, v: raw.Ptr<abi.Value>) uses raw, ffi {
  pthread_mutex_lock(raw.addr_of(&imprint_lock))
  let f = imprint_out
  if !f.is_null() {
    putc(f, 86) // 'V'
    imprint_put_int(f, c)
    putc(f, 32) // ' '
    dump(f, v)
    putc(f, 10)
    fflush(f)
  }
  let _ = pthread_mutex_unlock(raw.addr_of(&imprint_lock))
}
