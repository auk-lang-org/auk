/// Reference counting, allocation, panics, checked arithmetic, hashing and the scalar element
/// ops (was runtime/c/rc.c, ported line by line). The ABI is auk_rt.h's: every function under its
/// C name, the element-ops tables (`auk_ops_int`, …) as `export var`s.
///
/// Generated code doesn't call auk_retain/auk_release on the fast path: the compiler inlines
/// them (`intrin.rc_update`: nothing for NULL or a negative, immortal count; the runtime for
/// handles; a relaxed atomic add, or a release subtract whose last reference fences (acquire)
/// and calls auk__free_last). The definitions here keep exactly those semantics and orderings.
///
/// Each `export fn` another module of the package uses is `pub` too, and called as `rc.name(…)`
/// (a direct call: it inlines within the Auk half).

// the rest of the runtime (C, or another module's `export fn`, which such an `extern fn` resolves to)
extern fn auk__conn_free(p: raw.Ptr<()>) = "void auk__conn_free(void *)"
extern fn auk__listener_free(p: raw.Ptr<()>) = "void auk__listener_free(void *)"
// the C library
extern fn c_snprintf(buf: raw.Ptr<u8>, cap: usize, fmt: raw.Ptr<u8>, ...): i32 =
  "int snprintf(char *, size_t, const char *, ...)"
extern fn c_malloc(n: usize): raw.Ptr<()> = "void *malloc(size_t)"
extern fn c_calloc(n: usize, size: usize): raw.Ptr<()> = "void *calloc(size_t, size_t)"
extern fn c_realloc(p: raw.Ptr<()>, n: usize): raw.Ptr<()> = "void *realloc(void *, size_t)"
extern fn c_strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn c_getenv(name: raw.Ptr<u8>): raw.Ptr<u8> = "char *getenv(const char *)"
extern fn c_fputs(s: raw.Ptr<u8>, f: raw.Ptr<()>): i32 = "int fputs(const char *, void *)"
extern fn c_fwrite(p: raw.Ptr<u8>, size: usize, n: usize, f: raw.Ptr<()>): usize =
  "size_t fwrite(const void *, size_t, size_t, void *)"
extern fn c_fflush(f: raw.Ptr<()>): i32 = "int fflush(void *)"
extern fn c_exit(code: i32): never = "void _exit(int)"
extern fn pthread_mutex_lock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_lock(void *)"
extern fn pthread_mutex_unlock(m: raw.Ptr<cfacts.PthreadMutex>): i32 = "int pthread_mutex_unlock(void *)"
// libm
extern fn c_pow(a: float, b: float): float = "double pow(double, double)"
extern fn c_fmod(a: float, b: float): float = "double fmod(double, double)"
extern fn c_sqrt(a: float): float = "double sqrt(double)"
extern fn c_fabs(a: float): float = "double fabs(double)"
extern fn c_floor(a: float): float = "double floor(double)"
extern fn c_ceil(a: float): float = "double ceil(double)"
extern fn c_round(a: float): float = "double round(double)"
extern fn c_sin(a: float): float = "double sin(double)"
extern fn c_cos(a: float): float = "double cos(double)"
extern fn c_tan(a: float): float = "double tan(double)"
extern fn c_asin(a: float): float = "double asin(double)"
extern fn c_acos(a: float): float = "double acos(double)"
extern fn c_atan(a: float): float = "double atan(double)"
extern fn c_exp(a: float): float = "double exp(double)"
extern fn c_log(a: float): float = "double log(double)"
extern fn c_log10(a: float): float = "double log10(double)"
extern fn c_log2(a: float): float = "double log2(double)"
extern fn c_atan2(y: float, x: float): float = "double atan2(double, double)"

// ---- allocation & leak counter ------------------------------------------------------------

raw var live_objects: i64 = 0

export fn auk_live_objects(): i64 uses raw = raw.atomic_load(raw.addr_of(&live_objects), raw.Order.SeqCst)

/// The live objects that aren't the program's: a compiler written in Auk runs the programs it
/// compiles in its own process, where its own objects stay live, so it marks them just before
/// calling the program's entry point, and the leak check counts from there.
raw var leak_baseline: i64 = 0

export fn auk_leak_baseline() uses raw {
  raw.atomic_store(raw.addr_of(&leak_baseline), raw.atomic_load(raw.addr_of(&live_objects), raw.Order.SeqCst), raw.Order.SeqCst)
}

fn oom(): never uses raw, ffi {
  let _ = c_fputs("panic: out of memory\n", cfacts.stderr())
  c_exit(101)
}

pub export fn auk__xmalloc(n: usize): raw.Ptr<()> uses raw, ffi {
  let p = c_malloc(if n == 0 { 1 } else { n })
  if p.is_null() {
    oom()
  }
  p
}

pub export fn auk__xcalloc(n: usize, size: usize): raw.Ptr<()> uses raw, ffi {
  let p = c_calloc(if n == 0 { 1 } else { n }, if size == 0 { 1 } else { size })
  if p.is_null() {
    oom()
  }
  p
}

pub export fn auk__xrealloc(p: raw.Ptr<()>, n: usize): raw.Ptr<()> uses raw, ffi {
  let q = c_realloc(p, if n == 0 { 1 } else { n })
  if q.is_null() {
    oom()
  }
  q
}

/// A zeroed heap object with rc 1 (counted as live).
pub export fn auk__alloc(size: usize, kind: u32): raw.Ptr<()> uses raw, ffi {
  let h = heap.auk__heap_alloc(size, kind)
  raw.atomic_store(raw.field_addr(h, .rc), 1, raw.Order.Relaxed)
  let _ = raw.atomic_add(raw.addr_of(&live_objects), 1, raw.Order.Relaxed)
  raw.cast(h)
}

/// Free the object memory itself (and update the live counter).
pub export fn auk__free_obj(p: raw.Ptr<()>) uses raw, ffi {
  let _ = raw.atomic_sub(raw.addr_of(&live_objects), 1, raw.Order.Relaxed)
  heap.auk__heap_free(raw.cast(p))
}

pub export fn auk__make_immortal(p: raw.Ptr<()>) uses raw {
  if p.is_null() {
    return
  }
  let h: raw.Ptr<abi.Header> = raw.cast(p)
  if raw.atomic_load(raw.field_addr(h, .rc), raw.Order.SeqCst) < 0 {
    return
  }
  // INT64_MIN / 2
  raw.atomic_store(raw.field_addr(h, .rc), -4611686018427387904, raw.Order.SeqCst)
  let _ = raw.atomic_sub(raw.addr_of(&live_objects), 1, raw.Order.Relaxed)
}

export fn auk_make_immortal(p: raw.Ptr<()>) uses raw = auk__make_immortal(p)

raw var cleanup_lock: cfacts.PthreadMutex = cfacts.PTHREAD_MUTEX_INITIALIZER
/// The cleanup function (a `void (*)(void)`, NULL when none), under cleanup_lock.
raw var cleanup: raw.Ptr<()> = raw.null()

export fn auk_set_cleanup(f: raw.Fn<() => ()>) uses raw, ffi {
  let _ = pthread_mutex_lock(raw.addr_of(&cleanup_lock))
  cleanup = raw.cast(f)
  let _ = pthread_mutex_unlock(raw.addr_of(&cleanup_lock))
}

export fn auk_leak_check(): i64 uses raw, ffi {
  if c_getenv("AUK_LEAK_CHECK").is_null() {
    return 0
  }
  let _ = pthread_mutex_lock(raw.addr_of(&cleanup_lock))
  let fp = cleanup
  let _ = pthread_mutex_unlock(raw.addr_of(&cleanup_lock))
  if !fp.is_null() {
    let f: raw.Fn<() => ()> = raw.cast(fp)
    f()
  }
  let n = auk_live_objects() - raw.atomic_load(raw.addr_of(&leak_baseline), raw.Order.SeqCst)
  if n != 0 {
    let _ = c_fflush(cfacts.stdout())
    var m = abi.StrBuf {}
    let mp = raw.addr_of(&m)
    str.auk__sb_put_cstr(mp, "leak: ")
    str_fmt.auk_sb_int(mp, n)
    str.auk__sb_put_cstr(mp, " runtime object(s) still live at exit\n")
    str_fmt.auk__sb_eprint(mp)
    let _ = c_fflush(cfacts.stderr())
  }
  n
}

/// heap.auk's auk__note_handle, called through this pointer by `retain`/`release` so that LLVM
/// can't inline it there (the dialect has no `noinline`/`cold` yet): inlined, its locking made
/// every caller save registers on the fast path too (C called it across translation units).
/// External and mutable, so it isn't folded back into a direct call.
export var auk__note_handle_slow: raw.Fn<(raw.Ptr<()>, i64) => ()> = raw.fn_of(heap.auk__note_handle)

/// auk_retain for the package's own modules (inlined into them; the handle path out of line).
pub fn retain(p: raw.Ptr<()>): raw.Ptr<()> uses raw {
  if p.is_null() {
    return p
  }
  let h: raw.Ptr<abi.Header> = raw.cast(p)
  if raw.atomic_load(raw.field_addr(h, .rc), raw.Order.Relaxed) < 0 {
    return p
  }
  let _ = raw.atomic_add(raw.field_addr(h, .rc), 1, raw.Order.Relaxed)
  if abi.is_handle(h.kind) {
    let f = auk__note_handle_slow
    f(p, 1)
  }
  p
}

/// auk_release for the package's own modules.
pub fn release(p: raw.Ptr<()>) uses raw, ffi {
  if p.is_null() {
    return
  }
  let h: raw.Ptr<abi.Header> = raw.cast(p)
  if raw.atomic_load(raw.field_addr(h, .rc), raw.Order.Relaxed) < 0 {
    return
  }
  if abi.is_handle(h.kind) {
    let f = auk__note_handle_slow
    f(p, -1)
  }
  if raw.atomic_sub(raw.field_addr(h, .rc), 1, raw.Order.Release) != 1 {
    return
  }
  raw.fence(raw.Order.Acquire)
  auk__free_now(p)
}

// The exported pair (generated code's slow path for handles, C, FFI) calls heap.auk__note_handle
// directly: it reaches a thread-local then, so rtlink doesn't offer these two to programs (where
// they'd be inlined at every handle site for nothing), as the C ones weren't.

export fn auk_retain(p: raw.Ptr<()>): raw.Ptr<()> uses raw, ffi {
  if p.is_null() {
    return p
  }
  let h: raw.Ptr<abi.Header> = raw.cast(p)
  if raw.atomic_load(raw.field_addr(h, .rc), raw.Order.Relaxed) < 0 {
    return p
  }
  let _ = raw.atomic_add(raw.field_addr(h, .rc), 1, raw.Order.Relaxed)
  if abi.is_handle(h.kind) {
    heap.auk__note_handle(p, 1)
  }
  p
}

export fn auk_release(p: raw.Ptr<()>) uses raw, ffi {
  if p.is_null() {
    return
  }
  let h: raw.Ptr<abi.Header> = raw.cast(p)
  if raw.atomic_load(raw.field_addr(h, .rc), raw.Order.Relaxed) < 0 {
    return
  }
  if abi.is_handle(h.kind) {
    heap.auk__note_handle(p, -1)
  }
  if raw.atomic_sub(raw.field_addr(h, .rc), 1, raw.Order.Release) != 1 {
    return
  }
  raw.fence(raw.Order.Acquire)
  auk__free_now(p)
}

/// The slow end of auk_release inlined by the LLVM back end: generated code has already dropped
/// the last reference (its decrement returned 1) and issued the acquire fence.
export fn auk__free_last(p: raw.Ptr<()>) uses raw, ffi = auk__free_now(p)

/// A C array of 24 bytes (C's `char buf[21]`).
raw struct Bytes24 {
  b: [u8; 24],
}

/// Write n in decimal to buf (at least 21 bytes); returns buf.
fn dec(n: i64, buf: raw.Ptr<u8>): raw.Ptr<u8> uses raw {
  var tmp = Bytes24 {}
  let t: raw.Ptr<u8> = raw.cast(raw.addr_of(&tmp))
  var i: i64 = 0
  var u: u64 = if n < 0 { u64(0) - u64(n) } else { u64(n) }
  while true {
    t.at(i) = u8(u % 10) + 48
    i += 1
    u = u / 10
    if u == 0 {
      break
    }
  }
  var j: i64 = 0
  if n < 0 {
    buf.at(j) = 45
    j += 1
  }
  while i > 0 {
    i -= 1
    buf.at(j) = t.at(i)
    j += 1
  }
  buf.at(j) = 0
  buf
}

/// Free an object whose last reference is gone (or whose heap is being swept): release what it
/// holds and free its memory, by kind.
pub export fn auk__free_now(p: raw.Ptr<()>) uses raw, ffi {
  let h: raw.Ptr<abi.Header> = raw.cast(p)
  let k = h.kind
  if k == abi.K_STR {
    str.auk__str_free(raw.cast(p))
  } else if k == abi.K_ARR {
    arr.auk__arr_free(raw.cast(p))
  } else if k == abi.K_MAP {
    map.auk__map_free(raw.cast(p))
  } else if k == abi.K_ERR {
    err.auk__err_free(raw.cast(p))
  } else if k == abi.K_TASK {
    task.auk__task_free(raw.cast(p))
  } else if k == abi.K_CONN {
    auk__conn_free(p)
  } else if k == abi.K_LISTENER {
    auk__listener_free(p)
  } else if k == abi.K_CHAN {
    chan.auk__chan_free(raw.cast(p))
  } else if k == abi.K_FRAME {
    auk__free_obj(p)
  } else if k == abi.K_OBJ {
    let o: raw.Ptr<abi.Obj> = raw.cast(p)
    let drop = o.drop
    if !drop.is_null() {
      drop(o)
    }
    auk__free_obj(p)
  } else {
    var buf = Bytes24 {}
    auk__panic3("runtime", "release of an object with unknown kind ", dec(i64(k), raw.cast(raw.addr_of(&buf))), raw.null())
  }
}

pub export fn auk_refcount(p: raw.Ptr<()>): i64 uses raw {
  if p.is_null() {
    return 0
  }
  raw.atomic_load(raw.field_addr(raw.cast<abi.Header>(p), .rc), raw.Order.SeqCst)
}

// ---- panics --------------------------------------------------------------------------------

/// The one panic path: flush stdout, print `panic: <msg>\n  at <loc>`, record it in the trace,
/// and _exit(101) (no atexit handlers: other threads may still be busy). Under a recovery point
/// (`catch`, a task thread) it jumps back there instead (catch.auk).
pub export fn auk__panic(loc: raw.Ptr<u8>, msg: raw.Ptr<u8>, n0: usize): never uses raw, ffi {
  let _ = c_fflush(cfacts.stdout())
  // messages are bounded at 2047 bytes, cut at a UTF-8 boundary
  var n = n0
  if n > 2047 {
    n = 2047
    while n > 0 && (msg.at(n) & 0xC0) == 0x80 {
      n -= 1
    }
  }
  let place: raw.Ptr<u8> = if loc.is_null() { "<unknown>" } else { loc }
  let caught = recover.auk__catch_active() != 0
  dbg.auk__dbg_on_panic(place, msg, n, caught)
  if caught {
    trace.auk__trace_on_panic(loc, msg, n, true)
    recover.auk__catch_throw(place, msg, n)
  }
  let e = cfacts.stderr()
  let _ = c_fputs("panic: ", e)
  let _ = c_fwrite(msg, 1, n, e)
  let _ = c_fputs("\n  at ", e)
  let _ = c_fputs(place, e)
  let _ = c_fputs("\n", e)
  let _ = c_fflush(e)
  trace.auk__trace_on_panic(loc, msg, n, false)
  c_exit(101)
}

/// A C array of 2048 bytes.
raw struct Bytes2048 {
  b: [u8; 2048],
}

/// The text of the panic being raised on this thread: messages are bounded at 2047 bytes
/// (auk__panic), and a caught panic doesn't leak a buffer (catch.auk copies what it keeps).
raw thread var panic_buf: Bytes2048 = Bytes2048 {}

fn panic_text(): raw.Ptr<u8> uses raw = raw.cast(raw.addr_of(&panic_buf))

/// Panic with the n bytes at p (anything past the bound is dropped here; auk__panic then cuts
/// the message at a UTF-8 boundary).
pub export fn auk__panic_bytes(loc: raw.Ptr<u8>, p: raw.Ptr<u8>, n0: usize): never uses raw, ffi {
  let buf = panic_text()
  var n = n0
  if n > 2047 {
    n = 2047
  }
  if n > 0 && p != buf {
    raw.move(buf, p, n)
  }
  buf.at(n) = 0
  auk__panic(loc, buf, n)
}

/// Append the C string s (NULL: nothing) to the n bytes of buf, within the bound.
fn put_part(buf: raw.Ptr<u8>, n: usize, s: raw.Ptr<u8>): usize uses raw, ffi {
  var k: usize = if s.is_null() { 0 } else { c_strlen(s) }
  if k > 2047 - n {
    k = 2047 - n
  }
  if k > 0 {
    raw.copy(buf.offset(n), s, k)
  }
  n + k
}

pub export fn auk__panic3(loc: raw.Ptr<u8>, a: raw.Ptr<u8>, b: raw.Ptr<u8>, c: raw.Ptr<u8>): never uses raw, ffi {
  let buf = panic_text()
  let n = put_part(buf, put_part(buf, put_part(buf, 0, a), b), c)
  buf.at(n) = 0
  auk__panic(loc, buf, n)
}

pub export fn auk__panic_rt(msg: raw.Ptr<u8>): never uses raw, ffi = auk__panic3("runtime", msg, raw.null(), raw.null())

pub export fn auk__tmp_get(t: raw.Ptr<abi.Tmp>, size: usize): raw.Ptr<u8> uses raw, ffi {
  t.heap = if size <= 256 { raw.null() } else { raw.cast(auk__xmalloc(size)) }
  if t.heap.is_null() { raw.cast(raw.field_addr(t, .stack)) } else { t.heap }
}

pub export fn auk__tmp_done(t: raw.Ptr<abi.Tmp>) uses raw {
  raw.free(t.heap)
}

/// The panic entry point for generated code: msg is NUL-terminated.
pub export fn auk_panic_str(loc: raw.Ptr<u8>, msg: raw.Ptr<u8>): never uses raw, ffi {
  if msg.is_null() {
    auk__panic(loc, "", 0)
  }
  auk__panic(loc, msg, c_strlen(msg))
}

pub export fn auk_panic_overflow(loc: raw.Ptr<u8>, op: raw.Ptr<u8>): never uses raw, ffi =
  auk__panic3(loc, "integer overflow in `", op, "`")

export fn auk_panic_div_zero(loc: raw.Ptr<u8>): never uses raw, ffi = auk__panic3(loc, "division by zero", raw.null(), raw.null())

export fn auk_unwrap_none(loc: raw.Ptr<u8>): never uses raw, ffi = auk__panic3(loc, "unwrapped `none`", raw.null(), raw.null())

export fn auk_unwrap_err(loc: raw.Ptr<u8>, e: raw.Ptr<abi.Err>): never uses raw, ffi {
  let s = err.auk_err_show(e)
  // C built the message in a 2048-byte local first; here straight in the panic buffer
  // (auk__panic_bytes skips the copy then): the same bytes
  let m = panic_text()
  let np: usize = 20
  let ns: usize = if usize(s.len_bytes) < 2048 - np { usize(s.len_bytes) } else { 2048 - np }
  let prefix: raw.Ptr<u8> = "unwrapped an error: "
  raw.copy(m, prefix, np)
  raw.copy(m.offset(np), raw.field_addr(s, .data), ns)
  release(raw.cast(s))
  auk__panic_bytes(loc, m, np + ns)
}

// ---- arithmetic ----------------------------------------------------------------------------

export fn auk_add(a: i64, b: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  let (r, o) = raw.add_overflow(a, b)
  if o {
    auk_panic_overflow(loc, "+")
  }
  r
}

export fn auk_sub(a: i64, b: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  let (r, o) = raw.sub_overflow(a, b)
  if o {
    auk_panic_overflow(loc, "-")
  }
  r
}

export fn auk_mul(a: i64, b: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  let (r, o) = raw.mul_overflow(a, b)
  if o {
    auk_panic_overflow(loc, "*")
  }
  r
}

/// INT64_MIN.
raw let I64_MIN: i64 = -9223372036854775807 - 1

export fn auk_div(a: i64, b: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  if b == 0 {
    auk_panic_div_zero(loc)
  }
  if a == I64_MIN && b == -1 {
    auk_panic_overflow(loc, "/")
  }
  a / b
}

export fn auk_mod(a: i64, b: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  if b == 0 {
    auk_panic_div_zero(loc)
  }
  if b == -1 {
    return 0
  }
  a % b
}

export fn auk_neg(a: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  if a == I64_MIN {
    auk_panic_overflow(loc, "-")
  }
  0 - a
}

// i64 arithmetic wraps
export fn auk_wadd(a: i64, b: i64): i64 = a + b

export fn auk_wsub(a: i64, b: i64): i64 = a - b

export fn auk_wmul(a: i64, b: i64): i64 = a * b

fn bad_shift(n: i64, loc: raw.Ptr<u8>): never uses raw, ffi {
  var buf = Bytes24 {}
  auk__panic3(loc, "shift amount ", dec(n, raw.cast(raw.addr_of(&buf))), " is outside 0..63")
}

export fn auk_shl(a: i64, n: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  if u64(n) > 63 {
    bad_shift(n, loc)
  }
  i64(u64(a) << u64(n))
}

export fn auk_shr(a: i64, n: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  if u64(n) > 63 {
    bad_shift(n, loc)
  }
  a >> n
}

pub inline export fn auk_int_cmp(a: i64, b: i64): i32 {
  let gt: i32 = if a > b { 1 } else { 0 }
  let lt: i32 = if a < b { 1 } else { 0 }
  gt - lt
}

export fn auk_pow(a0: i64, b0: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  var a = a0
  var b = b0
  if b < 0 {
    auk__panic3(loc, "negative exponent in `**`", raw.null(), raw.null())
  }
  var r: i64 = 1
  while b > 0 {
    if (b & 1) != 0 {
      let (x, o) = raw.mul_overflow(r, a)
      r = x
      if o {
        auk_panic_overflow(loc, "**")
      }
    }
    b = b >> 1
    if b > 0 {
      let (y, o) = raw.mul_overflow(a, a)
      a = y
      if o {
        auk_panic_overflow(loc, "**")
      }
    }
  }
  r
}

export fn auk_int_abs(a: i64, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  if a == I64_MIN {
    auk_panic_overflow(loc, "abs")
  }
  if a < 0 { 0 - a } else { a }
}

export fn auk_fpow(a: float, b: float): float uses ffi = c_pow(a, b)

export fn auk_fmod(a: float, b: float): float uses ffi = c_fmod(a, b)

export fn auk_fsqrt(a: float): float uses ffi = c_sqrt(a)

export fn auk_fabs(a: float): float uses ffi = c_fabs(a)

export fn auk_ffloor(a: float): float uses ffi = c_floor(a)

export fn auk_fceil(a: float): float uses ffi = c_ceil(a)

export fn auk_fround(a: float): float uses ffi = c_round(a)

export fn auk_fsin(a: float): float uses ffi = c_sin(a)

export fn auk_fcos(a: float): float uses ffi = c_cos(a)

export fn auk_ftan(a: float): float uses ffi = c_tan(a)

export fn auk_fasin(a: float): float uses ffi = c_asin(a)

export fn auk_facos(a: float): float uses ffi = c_acos(a)

export fn auk_fatan(a: float): float uses ffi = c_atan(a)

export fn auk_fexp(a: float): float uses ffi = c_exp(a)

export fn auk_fln(a: float): float uses ffi = c_log(a)

export fn auk_flog10(a: float): float uses ffi = c_log10(a)

export fn auk_flog2(a: float): float uses ffi = c_log2(a)

export fn auk_fatan2(y: float, x: float): float uses ffi = c_atan2(y, x)

/// The IEEE 754 bits of a float, as an int.
pub export fn auk_fbits(a: float): i64 uses raw {
  var x = a
  raw.cast<i64>(raw.addr_of(&x)).load()
}

export fn auk_ffrom_bits(n: i64): float uses raw {
  var x = n
  raw.cast<float>(raw.addr_of(&x)).load()
}

/// The bits of a float rounded to single precision (0 to 2^32 - 1).
export fn auk_fbits32(a: float): i64 uses raw {
  var f = f32(a)
  i64(raw.cast<u32>(raw.addr_of(&f)).load())
}

/// A single-precision float from its low 32 bits.
export fn auk_ffrom_bits32(n: i64): float uses raw {
  var u = u32(n)
  float(raw.cast<f32>(raw.addr_of(&u)).load())
}

/// A C array of 64 bytes.
raw struct Bytes64 {
  b: [u8; 64],
}

export fn auk_float_to_int(x: float, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  if x != x {
    auk__panic3(loc, "int(NaN)", raw.null(), raw.null())
  }
  if !(x >= -9223372036854775808.0 && x < 9223372036854775808.0) {
    var g = Bytes64 {}
    let gp: raw.Ptr<u8> = raw.cast(raw.addr_of(&g))
    let _ = c_snprintf(gp, 64, "%g", x)
    auk__panic3(loc, "int(", gp, ") is out of range")
  }
  i64(x)
}

pub inline export fn auk_float_cmp(a: float, b: float): i32 {
  if a != a || b != b {
    let na: i32 = if a != a { 1 } else { 0 }
    let nb: i32 = if b != b { 1 } else { 0 }
    return na - nb
  }
  let gt: i32 = if a > b { 1 } else { 0 }
  let lt: i32 = if a < b { 1 } else { 0 }
  gt - lt
}

// ---- hashing -------------------------------------------------------------------------------

pub inline export fn auk_hash_bytes(p: raw.Ptr<()>, n: usize): u64 uses raw {
  let b: raw.Ptr<u8> = raw.cast(p)
  var h: u64 = 1469598103934665603
  var i: usize = 0
  while i < n {
    h = h ^ u64(b.at(i))
    h = h * 1099511628211
    i += 1
  }
  auk_hash_int(i64(h))
}

pub inline export fn auk_hash_int(x: i64): u64 {
  var z = u64(x) + 0x9e3779b97f4a7c15
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
  z = (z ^ (z >> 27)) * 0x94d049bb133111eb
  z ^ (z >> 31)
}

pub inline export fn auk_hash_combine(h: u64, x: u64): u64 = auk_hash_int(i64(h * 31 + x))

// ---- the element ops ------------------------------------------------------------------------
// (C's AukElemOps tables, by function address: constant initializers, relocations only.)

fn int_eq(a: raw.Ptr<()>, b: raw.Ptr<()>): bool uses raw = raw.cast<i64>(a).load() == raw.cast<i64>(b).load()

fn int_cmp(a: raw.Ptr<()>, b: raw.Ptr<()>): i32 uses raw = auk_int_cmp(raw.cast<i64>(a).load(), raw.cast<i64>(b).load())

fn int_hash(a: raw.Ptr<()>): u64 uses raw = auk_hash_int(raw.cast<i64>(a).load())

fn int_show(a: raw.Ptr<()>): raw.Ptr<abi.Str> uses raw, ffi = str_fmt.auk_str_from_int(raw.cast<i64>(a).load())

export var auk_ops_int: abi.ElemOps = abi.ElemOps {
  size: 8,
  eq: raw.fn_of(int_eq),
  cmp: raw.fn_of(int_cmp),
  hash: raw.fn_of(int_hash),
  show: raw.fn_of(int_show),
}

fn float_eq(a: raw.Ptr<()>, b: raw.Ptr<()>): bool uses raw = raw.cast<float>(a).load() == raw.cast<float>(b).load()

fn float_cmp(a: raw.Ptr<()>, b: raw.Ptr<()>): i32 uses raw = auk_float_cmp(raw.cast<float>(a).load(), raw.cast<float>(b).load())

fn float_hash(a: raw.Ptr<()>): u64 uses raw {
  var d = raw.cast<float>(a).load()
  if d == 0.0 {
    d = 0.0  // -0.0 == 0.0
  }
  auk_hash_int(auk_fbits(d))
}

fn float_show(a: raw.Ptr<()>): raw.Ptr<abi.Str> uses raw, ffi = str_fmt.auk_str_from_float(raw.cast<float>(a).load())

pub export var auk_ops_float: abi.ElemOps = abi.ElemOps {
  size: 8,
  eq: raw.fn_of(float_eq),
  cmp: raw.fn_of(float_cmp),
  hash: raw.fn_of(float_hash),
  show: raw.fn_of(float_show),
}

fn bool_eq(a: raw.Ptr<()>, b: raw.Ptr<()>): bool uses raw = raw.cast<bool>(a).load() == raw.cast<bool>(b).load()

fn bool_cmp(a: raw.Ptr<()>, b: raw.Ptr<()>): i32 uses raw {
  let x: i32 = if raw.cast<bool>(a).load() { 1 } else { 0 }
  let y: i32 = if raw.cast<bool>(b).load() { 1 } else { 0 }
  x - y
}

fn bool_hash(a: raw.Ptr<()>): u64 uses raw = auk_hash_int(if raw.cast<bool>(a).load() { 1 } else { 0 })

fn bool_show(a: raw.Ptr<()>): raw.Ptr<abi.Str> uses raw, ffi = str_fmt.auk_str_from_bool(raw.cast<bool>(a).load())

export var auk_ops_bool: abi.ElemOps = abi.ElemOps {
  size: 1,
  eq: raw.fn_of(bool_eq),
  cmp: raw.fn_of(bool_cmp),
  hash: raw.fn_of(bool_hash),
  show: raw.fn_of(bool_show),
}

fn char_eq(a: raw.Ptr<()>, b: raw.Ptr<()>): bool uses raw = raw.cast<u32>(a).load() == raw.cast<u32>(b).load()

fn char_cmp(a: raw.Ptr<()>, b: raw.Ptr<()>): i32 uses raw {
  let x = raw.cast<u32>(a).load()
  let y = raw.cast<u32>(b).load()
  let gt: i32 = if x > y { 1 } else { 0 }
  let lt: i32 = if x < y { 1 } else { 0 }
  gt - lt
}

fn char_hash(a: raw.Ptr<()>): u64 uses raw = auk_hash_int(i64(raw.cast<u32>(a).load()))

fn char_show(a: raw.Ptr<()>): raw.Ptr<abi.Str> uses raw, ffi = str_fmt.auk_char_quote(raw.cast<u32>(a).load())

export var auk_ops_char: abi.ElemOps = abi.ElemOps {
  size: 4,
  eq: raw.fn_of(char_eq),
  cmp: raw.fn_of(char_cmp),
  hash: raw.fn_of(char_hash),
  show: raw.fn_of(char_show),
}

fn unit_eq(a: raw.Ptr<()>, b: raw.Ptr<()>): bool = true

fn unit_cmp(a: raw.Ptr<()>, b: raw.Ptr<()>): i32 = 0

fn unit_hash(a: raw.Ptr<()>): u64 = 0

fn unit_show(a: raw.Ptr<()>): raw.Ptr<abi.Str> uses raw, ffi = str.auk_str_lit("()")

export var auk_ops_unit: abi.ElemOps = abi.ElemOps {
  size: 1,
  eq: raw.fn_of(unit_eq),
  cmp: raw.fn_of(unit_cmp),
  hash: raw.fn_of(unit_hash),
  show: raw.fn_of(unit_show),
}

pub export fn auk__ptr_retain(p: raw.Ptr<()>) uses raw, ffi {
  let _ = retain(raw.cast<raw.Ptr<()>>(p).load())
}

pub export fn auk__ptr_release(p: raw.Ptr<()>) uses raw, ffi = release(raw.cast<raw.Ptr<()>>(p).load())

// `auk_ops_str` is str.auk's (its element functions inline the string functions there)

fn arr_eq(a: raw.Ptr<()>, b: raw.Ptr<()>): bool uses raw, ffi =
  arr.auk_arr_eq(raw.cast<raw.Ptr<abi.Arr>>(a).load(), raw.cast<raw.Ptr<abi.Arr>>(b).load())

fn arr_cmp(a: raw.Ptr<()>, b: raw.Ptr<()>): i32 uses raw, ffi =
  arr.auk_arr_cmp(raw.cast<raw.Ptr<abi.Arr>>(a).load(), raw.cast<raw.Ptr<abi.Arr>>(b).load())

fn arr_hash(a: raw.Ptr<()>): u64 uses raw, ffi = arr.auk_arr_hash(raw.cast<raw.Ptr<abi.Arr>>(a).load())

fn arr_show(a: raw.Ptr<()>): raw.Ptr<abi.Str> uses raw, ffi = arr.auk_arr_show(raw.cast<raw.Ptr<abi.Arr>>(a).load())

export var auk_ops_arr: abi.ElemOps = abi.ElemOps {
  size: 8,
  retain: raw.fn_of(auk__ptr_retain),
  release: raw.fn_of(auk__ptr_release),
  eq: raw.fn_of(arr_eq),
  cmp: raw.fn_of(arr_cmp),
  hash: raw.fn_of(arr_hash),
  show: raw.fn_of(arr_show),
  copy: raw.fn_of(copy.auk__arr_copy_elem),
}

fn map_eq(a: raw.Ptr<()>, b: raw.Ptr<()>): bool uses raw, ffi =
  map.auk_map_eq(raw.cast<raw.Ptr<abi.Map>>(a).load(), raw.cast<raw.Ptr<abi.Map>>(b).load())

fn map_show(a: raw.Ptr<()>): raw.Ptr<abi.Str> uses raw, ffi = map.auk_map_show(raw.cast<raw.Ptr<abi.Map>>(a).load())

export var auk_ops_map: abi.ElemOps = abi.ElemOps {
  size: 8,
  retain: raw.fn_of(auk__ptr_retain),
  release: raw.fn_of(auk__ptr_release),
  eq: raw.fn_of(map_eq),
  show: raw.fn_of(map_show),
  copy: raw.fn_of(copy.auk__map_copy_elem),
}

fn err_show(a: raw.Ptr<()>): raw.Ptr<abi.Str> uses raw, ffi = err.auk_err_show(raw.cast<raw.Ptr<abi.Err>>(a).load())

export var auk_ops_err: abi.ElemOps = abi.ElemOps {
  size: 8,
  retain: raw.fn_of(auk__ptr_retain),
  release: raw.fn_of(auk__ptr_release),
  show: raw.fn_of(err_show),
  copy: raw.fn_of(copy.auk__err_copy_elem),
}

export var auk_ops_obj: abi.ElemOps = abi.ElemOps {
  size: 8,
  retain: raw.fn_of(auk__ptr_retain),
  release: raw.fn_of(auk__ptr_release),
  copy: raw.fn_of(copy.auk__obj_copy_elem),
}

export var auk_ops_task: abi.ElemOps = abi.ElemOps {
  size: 8,
  retain: raw.fn_of(auk__ptr_retain),
  release: raw.fn_of(auk__ptr_release),
  copy: raw.fn_of(copy.auk__handle_copy_elem),
}

fn closure_retain(p: raw.Ptr<()>) uses raw, ffi {
  let _ = retain(raw.cast(raw.cast<abi.Closure>(p).env))
}

fn closure_release(p: raw.Ptr<()>) uses raw, ffi = release(raw.cast(raw.cast<abi.Closure>(p).env))

export var auk_ops_closure: abi.ElemOps = abi.ElemOps {
  size: 16,
  retain: raw.fn_of(closure_retain),
  release: raw.fn_of(closure_release),
  copy: raw.fn_of(copy.auk__closure_copy_elem),
}

export fn auk_closure_retain(c: abi.Closure) uses raw, ffi {
  let _ = retain(raw.cast(c.env))
}

export fn auk_closure_release(c: abi.Closure) uses raw, ffi = release(raw.cast(c.env))

/// The tables' addresses, for the package's other modules.
pub fn ops_int(): raw.Ptr<abi.ElemOps> uses raw = raw.addr_of(&auk_ops_int)
pub fn ops_float(): raw.Ptr<abi.ElemOps> uses raw = raw.addr_of(&auk_ops_float)
pub fn ops_char(): raw.Ptr<abi.ElemOps> uses raw = raw.addr_of(&auk_ops_char)
