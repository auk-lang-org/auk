/// `[T]`: inline-element arrays with copy-on-write and O(1) slice views (was runtime/c/arr.c,
/// ported line by line). The ABI is auk_rt.h's: `AukArr` (`abi.Arr`) by pointer, every
/// `auk_arr_*` entry point under its C name.

// the rest of the runtime (C, or another module's `export fn`, which such an `extern fn` resolves to)
extern fn auk__xmalloc(n: usize): raw.Ptr<u8> = "void *auk__xmalloc(size_t)"
extern fn auk__xcalloc(n: usize, size: usize): raw.Ptr<u8> = "void *auk__xcalloc(size_t, size_t)"
extern fn auk__xrealloc(p: raw.Ptr<u8>, n: usize): raw.Ptr<u8> = "void *auk__xrealloc(void *, size_t)"
// _Noreturn: `never` is core's only (TODO(dialect)), so their callers say `raw.unreachable()`
extern fn auk__panic_sb(loc: raw.Ptr<u8>, b: raw.Ptr<abi.StrBuf>) = "void auk__panic_sb(const char *, void *)"
extern fn auk__show_exhausted(): bool = "bool auk__show_exhausted(void)"
extern fn auk__sb_put_cstr(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<u8>) = "void auk__sb_put_cstr(void *, const char *)"
extern fn auk_sb_int(b: raw.Ptr<abi.StrBuf>, v: i64) = "void auk_sb_int(void *, int64_t)"
extern fn auk_sb_char(b: raw.Ptr<abi.StrBuf>, c: u32) = "void auk_sb_char(void *, uint32_t)"
extern fn auk_sb_lit(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<u8>) = "void auk_sb_lit(void *, const char *)"
extern fn auk_sb_str(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<abi.Str>) = "void auk_sb_str(void *, const void *)"
extern fn auk_sb_str_own(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<abi.Str>) = "void auk_sb_str_own(void *, void *)"
extern fn auk_sb_finish(b: raw.Ptr<abi.StrBuf>): raw.Ptr<abi.Str> = "void *auk_sb_finish(void *)"

/// Address of element i.
fn elem(a: raw.Ptr<abi.Arr>, i: i64): raw.Ptr<u8> uses raw = a.data.offset(i * i64(a.ops.size))

/// Copy one element of sz bytes: 8 and 16, the common sizes, as constant-size copies (inline
/// loads and stores, no memmove call; alignment is not assumed).
fn copy_elem(dst: raw.Ptr<u8>, src: raw.Ptr<u8>, sz: usize) uses raw {
  if sz == 8 {
    raw.copy(dst, src, 8)
  } else if sz == 16 {
    raw.copy(dst, src, 16)
  } else {
    raw.copy(dst, src, sz)
  }
}

fn retain_elem(ops: raw.Ptr<abi.ElemOps>, e: raw.Ptr<u8>) uses raw {
  let f = ops.retain
  if !f.is_null() { f(raw.cast(e)) }
}

fn release_elem(ops: raw.Ptr<abi.ElemOps>, e: raw.Ptr<u8>) uses raw {
  let f = ops.release
  if !f.is_null() { f(raw.cast(e)) }
}

// rc.auk's auk_refcount, auk__tmp_get/auk__tmp_done and auk_float_cmp, under the names this file
// uses (direct calls: they inline, as in C's one translation unit)

fn refcount(p: raw.Ptr<abi.Arr>): i64 uses raw = rc.auk_refcount(raw.cast(p))

fn tmp_get(t: raw.Ptr<abi.Tmp>, size: usize): raw.Ptr<u8> uses raw, ffi = rc.auk__tmp_get(t, size)

fn tmp_done(t: raw.Ptr<abi.Tmp>) uses raw = rc.auk__tmp_done(t)

pub fn float_cmp(a: float, b: float): i32 = rc.auk_float_cmp(a, b)

pub inline export fn auk_arr_len(a: raw.Ptr<abi.Arr>): i64 uses raw = if a.is_null() { 0 } else { a.len }

inline export fn auk_arr_data(a: raw.Ptr<abi.Arr>): raw.Ptr<()> uses raw =
  if a.is_null() { raw.null() } else { raw.cast(a.data) }

/// `noinline`: inlined into programs (rtlink), it made their push loops slower
/// (design/runtime-port.md, arr and map).
pub noinline export fn auk_arr_new(ops: raw.Ptr<abi.ElemOps>, cap: i64): raw.Ptr<abi.Arr> uses raw, ffi {
  if ops.is_null() {
    rc.auk__panic_rt("auk_arr_new: missing element ops")
    raw.unreachable()
  }
  let a: raw.Ptr<abi.Arr> = raw.cast(rc.auk__alloc(raw.size_of<abi.Arr>(), abi.K_ARR))
  a.ops = ops
  a.cap = heap.buf_fit(if cap > 0 { cap } else { 0 }, ops.size)
  a.data = if a.cap != 0 { heap.auk__buf_alloc(usize(a.cap) * ops.size) } else { raw.null() }
  a
}

export fn auk_arr_from(ops: raw.Ptr<abi.ElemOps>, elems: raw.Ptr<()>, n: i64): raw.Ptr<abi.Arr> uses raw, ffi {
  let a = auk_arr_new(ops, n)
  if n != 0 {
    raw.copy(a.data, elems, usize(n) * ops.size)
  }
  a.len = n
  let retain = ops.retain
  if !retain.is_null() {
    var i: i64 = 0
    while i < n {
      retain(raw.cast(elem(a, i)))
      i += 1
    }
  }
  a
}

pub export fn auk__arr_free(a: raw.Ptr<abi.Arr>) uses raw, ffi {
  if !a.base.is_null() {
    rc.release(raw.cast(a.base))
  } else {
    let release = a.ops.release
    if !release.is_null() {
      var i: i64 = 0
      while i < a.len {
        release(raw.cast(elem(a, i)))
        i += 1
      }
    }
    heap.auk__buf_free(a.data, usize(a.cap) * a.ops.size)
  }
  rc.auk__free_obj(raw.cast(a))
}

fn oob(loc: raw.Ptr<u8>, i: i64, len: i64) uses raw, ffi {
  var b = abi.StrBuf {}
  let pb = raw.addr_of(&b)
  auk__sb_put_cstr(pb, "index ")
  auk_sb_int(pb, i)
  auk__sb_put_cstr(pb, " out of range for length ")
  auk_sb_int(pb, len)
  auk__panic_sb(loc, pb)
  raw.unreachable()
}

inline export fn auk_arr_at(a: raw.Ptr<abi.Arr>, i: i64, loc: raw.Ptr<u8>): raw.Ptr<()> uses raw, ffi {
  let n = auk_arr_len(a)
  if i < 0 || i >= n {
    oob(loc, i, n)
  }
  raw.cast(elem(a, i))
}

inline export fn auk_arr_get_opt(a: raw.Ptr<abi.Arr>, i: i64, out: raw.Ptr<()>): bool uses raw {
  if i < 0 || i >= auk_arr_len(a) {
    return false
  }
  // a memmove call, not copy_elem: inlined into push loops, the faster copy made them stall
  // (without alias information, a list's header fields are reloaded after every element
  // store, and those loads stalled once nothing spaced them out)
  raw.copy(out, elem(a, i), a.ops.size)
  retain_elem(a.ops, raw.cast(out))
  true
}

/// A fresh owner copy of a with capacity >= cap.
fn copy_with_cap(a: raw.Ptr<abi.Arr>, cap0: i64): raw.Ptr<abi.Arr> uses raw, ffi {
  let cap = if cap0 < a.len { a.len } else { cap0 }
  let c = auk_arr_new(a.ops, cap)
  if a.len != 0 {
    raw.copy(c.data, a.data, usize(a.len) * a.ops.size)
  }
  c.len = a.len
  let retain = a.ops.retain
  if !retain.is_null() {
    var i: i64 = 0
    while i < c.len {
      retain(raw.cast(elem(c, i)))
      i += 1
    }
  }
  c
}

fn is_unique(a: raw.Ptr<abi.Arr>): bool uses raw = a.base.is_null() && refcount(a) == 1

fn ensure_unique_cap(pa: raw.Ptr<raw.Ptr<abi.Arr>>, need: i64) uses raw, ffi {
  let a = pa.load()
  if a.is_null() {
    rc.auk__panic_rt("mutating a NULL array")
    raw.unreachable()
  }
  if !is_unique(a) {
    rc.auk_note_cow()
    let c = copy_with_cap(a, if need > a.len { need } else { a.len })
    rc.release(raw.cast(a))
    pa.store(c)
    return
  }
  if need > a.cap {
    var cap = if a.cap != 0 { a.cap * 2 } else { 4 }
    while cap < need {
      cap *= 2
    }
    cap = heap.buf_fit(cap, a.ops.size)
    a.data = heap.auk__buf_resize(a.data, usize(a.cap) * a.ops.size, usize(cap) * a.ops.size)
    a.cap = cap
  }
}

pub export fn auk_arr_make_unique(pa: raw.Ptr<raw.Ptr<abi.Arr>>): raw.Ptr<()> uses raw, ffi {
  ensure_unique_cap(pa, pa.load().len)
  raw.cast(pa.load().data)
}

export fn auk_arr_set(pa: raw.Ptr<raw.Ptr<abi.Arr>>, i: i64, e: raw.Ptr<()>, loc: raw.Ptr<u8>) uses raw, ffi {
  let n = auk_arr_len(pa.load())
  if i < 0 || i >= n {
    oob(loc, i, n)
  }
  let sz = pa.load().ops.size
  // copy + retain the new value first: e may point into *pa
  var tmp: abi.Tmp
  let t = tmp_get(raw.addr_of(&tmp), sz)
  raw.copy(t, e, sz)
  retain_elem(pa.load().ops, t)
  ensure_unique_cap(pa, n)
  let a = pa.load()
  release_elem(a.ops, elem(a, i))
  raw.copy(elem(a, i), t, sz)
  tmp_done(raw.addr_of(&tmp))
}

/// Scratch room for an element of up to 32 bytes (uninitialized, as `abi.Tmp`; without
/// tmp_get's size test).
raw struct Scratch {
  w: [u64; 4],
}

/// `noinline`: generated code already inlines its own fast path for scalar elements and calls
/// this when that fails; inlined here too, it added a second copy and spills to push loops.
pub noinline export fn auk_arr_push(pa: raw.Ptr<raw.Ptr<abi.Arr>>, e: raw.Ptr<()>) uses raw, ffi {
  let a = pa.load()
  // unique with room: no copy-on-write and no realloc, so e (even an element of a) stays put
  if raw.likely(!a.is_null() && a.len < a.cap && a.base.is_null() && refcount(a) == 1) {
    let dst = elem(a, a.len)
    copy_elem(dst, raw.cast(e), a.ops.size)
    retain_elem(a.ops, dst)
    a.len += 1
    return
  }
  auk__arr_push_slow(pa, e)
}

/// auk_arr_push when the list must grow or be copied first.
noinline export fn auk__arr_push_slow(pa: raw.Ptr<raw.Ptr<abi.Arr>>, e: raw.Ptr<()>) uses raw, ffi {
  let sz = pa.load().ops.size
  if sz <= raw.size_of<Scratch>() {
    var b: Scratch
    push_via(pa, e, raw.cast(raw.addr_of(&b)))
    return
  }
  var tmp: abi.Tmp
  push_via(pa, e, tmp_get(raw.addr_of(&tmp), sz))
  tmp_done(raw.addr_of(&tmp))
}

/// auk_arr_push with t: room for the element.
fn push_via(pa: raw.Ptr<raw.Ptr<abi.Arr>>, e: raw.Ptr<()>, t: raw.Ptr<u8>) uses raw, ffi {
  let a0 = pa.load()
  let sz = a0.ops.size
  // e may point into *pa itself: copy before a possible realloc or copy-on-write
  copy_elem(t, raw.cast(e), sz)
  retain_elem(a0.ops, t)
  ensure_unique_cap(pa, a0.len + 1)
  let a = pa.load()
  copy_elem(elem(a, a.len), t, sz)
  a.len += 1
}

export fn auk_arr_push_own(pa: raw.Ptr<raw.Ptr<abi.Arr>>, e: raw.Ptr<()>) uses raw, ffi {
  // e is the caller's own value (never an element of *pa): moved in, no retain
  ensure_unique_cap(pa, pa.load().len + 1)
  let a = pa.load()
  raw.copy(elem(a, a.len), e, a.ops.size)
  a.len += 1
}

export fn auk_arr_pop(pa: raw.Ptr<raw.Ptr<abi.Arr>>, out: raw.Ptr<()>): bool uses raw, ffi {
  if auk_arr_len(pa.load()) == 0 {
    return false
  }
  ensure_unique_cap(pa, pa.load().len)
  let a = pa.load()
  a.len -= 1
  if !out.is_null() {
    raw.copy(out, elem(a, a.len), a.ops.size)
  } else {
    release_elem(a.ops, elem(a, a.len))
  }
  true
}

export fn auk_arr_insert(pa: raw.Ptr<raw.Ptr<abi.Arr>>, i: i64, e: raw.Ptr<()>, loc: raw.Ptr<u8>) uses raw, ffi {
  let n = auk_arr_len(pa.load())
  if i < 0 || i > n {
    oob(loc, i, n)
  }
  let sz = pa.load().ops.size
  var tmp: abi.Tmp
  let t = tmp_get(raw.addr_of(&tmp), sz)
  raw.copy(t, e, sz)
  retain_elem(pa.load().ops, t)
  ensure_unique_cap(pa, n + 1)
  let a = pa.load()
  raw.move(elem(a, i + 1), elem(a, i), usize(n - i) * sz)
  raw.copy(elem(a, i), t, sz)
  a.len += 1
  tmp_done(raw.addr_of(&tmp))
}

export fn auk_arr_remove(pa: raw.Ptr<raw.Ptr<abi.Arr>>, i: i64, out: raw.Ptr<()>, loc: raw.Ptr<u8>) uses raw, ffi {
  let n = auk_arr_len(pa.load())
  if i < 0 || i >= n {
    oob(loc, i, n)
  }
  ensure_unique_cap(pa, n)
  let a = pa.load()
  let sz = a.ops.size
  if !out.is_null() {
    raw.copy(out, elem(a, i), sz)
  } else {
    release_elem(a.ops, elem(a, i))
  }
  raw.move(elem(a, i), elem(a, i + 1), usize(n - i - 1) * sz)
  a.len -= 1
}

export fn auk_arr_clear(pa: raw.Ptr<raw.Ptr<abi.Arr>>) uses raw, ffi {
  let a = pa.load()
  if !is_unique(a) {
    pa.store(auk_arr_new(a.ops, 0))
    rc.release(raw.cast(a))
    return
  }
  let release = a.ops.release
  if !release.is_null() {
    var i: i64 = 0
    while i < a.len {
      release(raw.cast(elem(a, i)))
      i += 1
    }
  }
  a.len = 0
}

export fn auk_arr_slice(a: raw.Ptr<abi.Arr>, lo: i64, hi: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Arr> uses raw, ffi {
  let n = auk_arr_len(a)
  if lo < 0 || hi < lo || hi > n {
    var b = abi.StrBuf {}
    let pb = raw.addr_of(&b)
    auk__sb_put_cstr(pb, "slice ")
    auk_sb_int(pb, lo)
    auk__sb_put_cstr(pb, "..")
    auk_sb_int(pb, hi)
    auk__sb_put_cstr(pb, " out of range for length ")
    auk_sb_int(pb, n)
    auk__panic_sb(loc, pb)
    raw.unreachable()
  }
  if lo == 0 && hi == n {
    return raw.cast(rc.retain(raw.cast(a)))
  }
  let root = if !a.base.is_null() { a.base } else { a }
  let v: raw.Ptr<abi.Arr> = raw.cast(rc.auk__alloc(raw.size_of<abi.Arr>(), abi.K_ARR))
  v.ops = a.ops
  v.base = raw.cast(rc.retain(raw.cast(root)))
  v.data = elem(a, lo)
  v.len = hi - lo
  v.cap = v.len
  v
}

export fn auk_arr_take(a: raw.Ptr<abi.Arr>, n0: i64): raw.Ptr<abi.Arr> uses raw, ffi {
  let len = auk_arr_len(a)
  let n: i64 = if n0 < 0 { 0 } else { n0 }
  auk_arr_slice(a, 0, if n < len { n } else { len }, raw.null())
}

export fn auk_arr_skip(a: raw.Ptr<abi.Arr>, n0: i64): raw.Ptr<abi.Arr> uses raw, ffi {
  let len = auk_arr_len(a)
  let n: i64 = if n0 < 0 { 0 } else { n0 }
  auk_arr_slice(a, if n < len { n } else { len }, len, raw.null())
}

/// Panics with "<what> <n> is negative".
fn negative(loc: raw.Ptr<u8>, what: raw.Ptr<u8>, n: i64) uses raw, ffi {
  var b = abi.StrBuf {}
  let pb = raw.addr_of(&b)
  auk__sb_put_cstr(pb, what)
  auk__sb_put_cstr(pb, " ")
  auk_sb_int(pb, n)
  auk__sb_put_cstr(pb, " is negative")
  auk__panic_sb(loc, pb)
  raw.unreachable()
}

/// `xs.truncate(n)`: drops every element from index `n` on; nothing when `n >= len`. A unique
/// list keeps its buffer; a shared one is replaced by a copy of its first `n` elements.
export fn auk_arr_truncate(pa: raw.Ptr<raw.Ptr<abi.Arr>>, n: i64, loc: raw.Ptr<u8>) uses raw, ffi {
  if n < 0 { negative(loc, "truncate length", n) }
  let a = pa.load()
  let len = auk_arr_len(a)
  if n >= len { return }
  if !is_unique(a) {
    let c = auk_arr_new(a.ops, n)
    if n != 0 { raw.copy(c.data, a.data, usize(n) * a.ops.size) }
    c.len = n
    let retain = a.ops.retain
    if !retain.is_null() {
      var i: i64 = 0
      while i < n {
        retain(raw.cast(elem(c, i)))
        i += 1
      }
    }
    rc.release(raw.cast(a))
    pa.store(c)
    return
  }
  let release = a.ops.release
  if !release.is_null() {
    var i = n
    while i < len {
      release(raw.cast(elem(a, i)))
      i += 1
    }
  }
  a.len = n
}

/// `xs.repeat(n)`: `xs` `n` times over, in one allocation (`[0].repeat(n)` is `n` zeros).
export fn auk_arr_repeat(a: raw.Ptr<abi.Arr>, n: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Arr> uses raw, ffi {
  if n < 0 { negative(loc, "repeat count", n) }
  let len = auk_arr_len(a)
  if len == 0 || n == 1 { return raw.cast(rc.retain(raw.cast(a))) }
  let (total, overflow) = raw.mul_overflow(len, n)
  if overflow {
    rc.auk_panic_overflow(loc, "repeat")
    raw.unreachable()
  }
  let sz = a.ops.size
  let c = auk_arr_new(a.ops, total)
  let bytes = usize(len) * sz
  if total != 0 {
    // one copy of `a`, then the filled part doubled until the end
    raw.copy(c.data, a.data, bytes)
    let all = usize(total) * sz
    var done = bytes
    while done < all {
      let k = if done < all - done { done } else { all - done }
      raw.copy(c.data.offset(i64(done)), c.data, k)
      done += k
    }
  }
  c.len = total
  let retain = a.ops.retain
  if !retain.is_null() {
    var i: i64 = 0
    while i < total {
      retain(raw.cast(elem(c, i)))
      i += 1
    }
  }
  c
}

export fn auk_arr_copy(a: raw.Ptr<abi.Arr>): raw.Ptr<abi.Arr> uses raw, ffi = copy_with_cap(a, a.len)

export fn auk_arr_concat(a: raw.Ptr<abi.Arr>, b: raw.Ptr<abi.Arr>): raw.Ptr<abi.Arr> uses raw, ffi {
  var c = copy_with_cap(a, a.len + auk_arr_len(b))
  auk_arr_extend(raw.addr_of(&c), b)
  c
}

export fn auk_arr_extend(pa: raw.Ptr<raw.Ptr<abi.Arr>>, b: raw.Ptr<abi.Arr>) uses raw, ffi {
  let bn = auk_arr_len(b)
  if bn == 0 {
    return
  }
  let keep = rc.retain(raw.cast(b)) // b may be *pa
  ensure_unique_cap(pa, pa.load().len + bn)
  let a = pa.load()
  raw.copy(elem(a, a.len), b.data, usize(bn) * a.ops.size)
  let retain = a.ops.retain
  if !retain.is_null() {
    var i = a.len
    while i < a.len + bn {
      retain(raw.cast(elem(a, i)))
      i += 1
    }
  }
  a.len += bn
  rc.release(keep)
}

fn reverse_in_place(a: raw.Ptr<abi.Arr>) uses raw, ffi {
  let sz = a.ops.size
  var tmp: abi.Tmp
  let t = tmp_get(raw.addr_of(&tmp), sz)
  var i: i64 = 0
  var j = a.len - 1
  while i < j {
    raw.copy(t, elem(a, i), sz)
    raw.copy(elem(a, i), elem(a, j), sz)
    raw.copy(elem(a, j), t, sz)
    i += 1
    j -= 1
  }
  tmp_done(raw.addr_of(&tmp))
}

export fn auk_arr_reversed(a: raw.Ptr<abi.Arr>): raw.Ptr<abi.Arr> uses raw, ffi {
  let c = auk_arr_copy(a)
  reverse_in_place(c)
  c
}

export fn auk_arr_reverse(pa: raw.Ptr<raw.Ptr<abi.Arr>>) uses raw, ffi {
  let _ = auk_arr_make_unique(pa)
  reverse_in_place(pa.load())
}

// ---- sorting -------------------------------------------------------------------------------

raw struct SortCtx {
  cmp: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>, raw.Ptr<()>) => i32>,
  ctx: raw.Ptr<()>,
  sz: usize,
}

/// Stable merge sort of n elements at d (tmp: room for n).
fn merge_sort(d: raw.Ptr<u8>, tmp: raw.Ptr<u8>, n: i64, c: raw.Ptr<SortCtx>) uses raw, ffi {
  let sz = i64(c.sz)
  let cmp = c.cmp
  let ctx = c.ctx
  if n < 2 {
    return
  }
  if n <= 8 {
    // insertion sort
    var i: i64 = 1
    while i < n {
      raw.copy(tmp, d.offset(i * sz), sz)
      var j = i
      while j > 0 && cmp(raw.cast(d.offset((j - 1) * sz)), raw.cast(tmp), ctx) > 0 {
        raw.copy(d.offset(j * sz), d.offset((j - 1) * sz), sz)
        j -= 1
      }
      raw.copy(d.offset(j * sz), tmp, sz)
      i += 1
    }
    return
  }
  let m = n / 2
  merge_sort(d, tmp, m, c)
  merge_sort(d.offset(m * sz), tmp, n - m, c)
  if cmp(raw.cast(d.offset((m - 1) * sz)), raw.cast(d.offset(m * sz)), ctx) <= 0 {
    return
  }
  raw.copy(tmp, d, n * sz)
  var i: i64 = 0
  var j = m
  var k: i64 = 0
  while i < m && j < n {
    if cmp(raw.cast(tmp.offset(j * sz)), raw.cast(tmp.offset(i * sz)), ctx) < 0 {
      raw.copy(d.offset(k * sz), tmp.offset(j * sz), sz)
      j += 1
    } else {
      raw.copy(d.offset(k * sz), tmp.offset(i * sz), sz)
      i += 1
    }
    k += 1
  }
  if i < m {
    raw.copy(d.offset(k * sz), tmp.offset(i * sz), (m - i) * sz)
  }
  if j < n {
    raw.copy(d.offset(k * sz), tmp.offset(j * sz), (n - j) * sz)
  }
}

export fn auk_arr_sort_with(
  pa: raw.Ptr<raw.Ptr<abi.Arr>>,
  cmp: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>, raw.Ptr<()>) => i32>,
  ctx: raw.Ptr<()>,
) uses raw, ffi {
  let _ = auk_arr_make_unique(pa)
  let a = pa.load()
  if a.len < 2 {
    return
  }
  var c = SortCtx { cmp, ctx, sz: a.ops.size }
  let tmp = auk__xmalloc(usize(a.len) * c.sz)
  merge_sort(a.data, tmp, a.len, raw.addr_of(&c))
  raw.free(tmp)
}

/// Ints: equal ints are indistinguishable, so any order among them will do. Short arrays by
/// insertion; longer ones by an LSD radix sort (sign bit flipped) in digits of up to 11 bits over
/// just the bits that vary between keys. It needs a buffer the size of the array while it runs
/// (a comparison sort in place was several times slower).
fn sort_ints(d: raw.Ptr<i64>, n: i64) uses raw, ffi {
  if n <= 32 {
    var i: i64 = 1
    while i < n {
      let x = d.at(i)
      var j = i
      while j > 0 && d.at(j - 1) > x {
        d.at(j) = d.at(j - 1)
        j -= 1
      }
      d.at(j) = x
      i += 1
    }
    return
  }
  var src: raw.Ptr<u64> = raw.cast(d)
  let flip: u64 = 1 << 63
  // the byte positions where keys differ
  var all_and: u64 = ~u64(0)
  var all_or: u64 = 0
  var i: i64 = 0
  while i < n {
    let k = src.at(i) ^ flip
    all_and &= k
    all_or |= k
    i += 1
  }
  let diff = all_and ^ all_or
  if diff == 0 {
    return // all equal
  }
  // digits of up to 11 bits over the bits that vary: [lo, hi]
  let lo = i64(raw.ctz(diff))
  let hi = i64(63) - i64(raw.clz(diff))
  let span = hi - lo + 1
  let passes = (span + 10) / 11
  let width = (span + passes - 1) / passes
  let buckets = i64(1) << width
  let mask = u64(buckets) - 1
  let counts: raw.Ptr<i64> = raw.cast(auk__xcalloc(usize(passes * buckets), 8))
  i = 0
  while i < n {
    let k = (src.at(i) ^ flip) >> u64(lo)
    var p: i64 = 0
    while p < passes {
      let ix = p * buckets + i64((k >> u64(p * width)) & mask)
      counts.at(ix) = counts.at(ix) + 1
      p += 1
    }
    i += 1
  }
  let buf: raw.Ptr<u64> = raw.cast(auk__xmalloc(usize(n) * 8))
  var dst = buf
  var p: i64 = 0
  while p < passes {
    let c = counts.offset(p * buckets)
    let sh = u64(lo + p * width)
    var sum: i64 = 0
    var v: i64 = 0
    while v < buckets {
      let t = c.at(v)
      c.at(v) = sum
      sum += t
      v += 1
    }
    i = 0
    while i < n {
      let x = src.at(i)
      let b = i64(((x ^ flip) >> sh) & mask)
      let at = c.at(b)
      c.at(b) = at + 1
      dst.at(at) = x
      i += 1
    }
    let t = src
    src = dst
    dst = t
    p += 1
  }
  if src.int() != d.int() {
    raw.copy(d, src, usize(n) * 8)
  }
  raw.free(counts)
  raw.free(buf)
}

/// Floats: stable (0.0 and -0.0 compare equal but print differently), by auk_float_cmp.
fn merge_floats(d: raw.Ptr<float>, tmp: raw.Ptr<float>, n: i64) uses raw, ffi {
  if n <= 16 {
    var i: i64 = 1
    while i < n {
      let x = d.at(i)
      var j = i
      while j > 0 && float_cmp(d.at(j - 1), x) > 0 {
        d.at(j) = d.at(j - 1)
        j -= 1
      }
      d.at(j) = x
      i += 1
    }
    return
  }
  let m = n / 2
  merge_floats(d, tmp, m)
  merge_floats(d.offset(m), tmp, n - m)
  if float_cmp(d.at(m - 1), d.at(m)) <= 0 {
    return
  }
  raw.copy(tmp, d, usize(m) * 8)
  var i: i64 = 0
  var j = m
  var k: i64 = 0
  while i < m && j < n {
    if float_cmp(d.at(j), tmp.at(i)) < 0 {
      d.at(k) = d.at(j)
      j += 1
    } else {
      d.at(k) = tmp.at(i)
      i += 1
    }
    k += 1
  }
  while i < m {
    d.at(k) = tmp.at(i)
    k += 1
    i += 1
  }
}

/// Other elements: a stable merge sort of their indexes (perm), comparing the elements.
fn merge_perm(
  p: raw.Ptr<i64>,
  tmp: raw.Ptr<i64>,
  n: i64,
  data: raw.Ptr<u8>,
  size: i64,
  cmp: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => i32>,
) uses raw {
  if n <= 8 {
    var i: i64 = 1
    while i < n {
      let x = p.at(i)
      var j = i
      while j > 0 && cmp(raw.cast(data.offset(p.at(j - 1) * size)), raw.cast(data.offset(x * size))) > 0 {
        p.at(j) = p.at(j - 1)
        j -= 1
      }
      p.at(j) = x
      i += 1
    }
    return
  }
  let m = n / 2
  merge_perm(p, tmp, m, data, size, cmp)
  merge_perm(p.offset(m), tmp, n - m, data, size, cmp)
  if cmp(raw.cast(data.offset(p.at(m - 1) * size)), raw.cast(data.offset(p.at(m) * size))) <= 0 {
    return
  }
  raw.copy(tmp, p, usize(m) * 8)
  var i: i64 = 0
  var j = m
  var k: i64 = 0
  while i < m && j < n {
    if cmp(raw.cast(data.offset(p.at(j) * size)), raw.cast(data.offset(tmp.at(i) * size))) < 0 {
      p.at(k) = p.at(j)
      j += 1
    } else {
      p.at(k) = tmp.at(i)
      i += 1
    }
    k += 1
  }
  while i < m {
    p.at(k) = tmp.at(i)
    k += 1
    i += 1
  }
}

/// Sort *pa in place (made unique first), stable, by the elements' cmp (their element ops: the
/// same comparison as Auk's `<`, derived or user-written). Other than ints and floats, elements
/// are sorted through a permutation of their indexes, moved only once it is done, so a user cmp
/// that panics leaves the list as it was.
export fn auk_arr_sort(pa: raw.Ptr<raw.Ptr<abi.Arr>>) uses raw, ffi {
  let ops = pa.load().ops
  let cmp = ops.cmp
  if cmp.is_null() {
    rc.auk__panic_rt("sort: element type has no cmp")
    raw.unreachable()
  }
  let _ = auk_arr_make_unique(pa)
  let a = pa.load()
  let n = a.len
  if n < 2 {
    return
  }
  if ops.int() == rc.ops_int().int() {
    sort_ints(raw.cast(a.data), n)
    return
  }
  if ops.int() == value.ops_float().int() {
    let tmp: raw.Ptr<float> = raw.cast(auk__xmalloc(usize(n / 2 + 1) * 8))
    merge_floats(raw.cast(a.data), tmp, n)
    raw.free(tmp)
    return
  }
  let size = ops.size
  let perm: raw.Ptr<i64> = raw.cast(auk__xmalloc(usize(n) * 8))
  let ptmp: raw.Ptr<i64> = raw.cast(auk__xmalloc(usize(n / 2 + 1) * 8))
  var i: i64 = 0
  while i < n {
    perm.at(i) = i
    i += 1
  }
  merge_perm(perm, ptmp, n, a.data, i64(size), cmp)
  let sorted = auk__xmalloc(usize(n) * size)
  var k: i64 = 0
  while k < n {
    raw.copy(sorted.offset(usize(k) * size), a.data.offset(usize(perm.at(k)) * size), size)
    k += 1
  }
  raw.copy(a.data, sorted, usize(n) * size)
  raw.free(sorted)
  raw.free(ptmp)
  raw.free(perm)
}

export fn auk_arr_sorted(a: raw.Ptr<abi.Arr>): raw.Ptr<abi.Arr> uses raw, ffi {
  var c = auk_arr_copy(a)
  auk_arr_sort(raw.addr_of(&c))
  c
}

// ---- queries -------------------------------------------------------------------------------

export fn auk_arr_index_of(a: raw.Ptr<abi.Arr>, e: raw.Ptr<()>): abi.OptInt uses raw, ffi {
  let n = auk_arr_len(a)
  if n == 0 {
    return abi.OptInt {}
  }
  var i: i64 = 0
  if a.ops.int() == rc.ops_int().int() {
    let d: raw.Ptr<i64> = raw.cast(a.data)
    let x = raw.cast<i64>(e).load()
    while i < n {
      if d.at(i) == x {
        return abi.OptInt { some: true, val: i }
      }
      i += 1
    }
    return abi.OptInt {}
  }
  let eq = a.ops.eq
  if eq.is_null() {
    rc.auk__panic_rt("contains: element type has no eq")
    raw.unreachable()
  }
  while i < n {
    if eq(raw.cast(elem(a, i)), e) {
      return abi.OptInt { some: true, val: i }
    }
    i += 1
  }
  abi.OptInt {}
}

export fn auk_arr_contains(a: raw.Ptr<abi.Arr>, e: raw.Ptr<()>): bool uses raw, ffi = auk_arr_index_of(a, e).some

pub export fn auk_arr_eq(a: raw.Ptr<abi.Arr>, b: raw.Ptr<abi.Arr>): bool uses raw, ffi {
  if a.int() == b.int() {
    return true
  }
  let n = auk_arr_len(a)
  if n != auk_arr_len(b) {
    return false
  }
  if n == 0 {
    return true
  }
  let o = a.ops.int()
  if o == rc.ops_int().int() || o == rc.ops_char().int() {
    // plain values with no padding: equal elements are equal bytes
    return raw.compare(a.data, b.data, usize(n) * a.ops.size) == 0
  }
  let eq = a.ops.eq
  if eq.is_null() {
    rc.auk__panic_rt("element type has no eq")
    raw.unreachable()
  }
  var i: i64 = 0
  while i < n {
    if !eq(raw.cast(elem(a, i)), raw.cast(elem(b, i))) {
      return false
    }
    i += 1
  }
  true
}

pub export fn auk_arr_cmp(a: raw.Ptr<abi.Arr>, b: raw.Ptr<abi.Arr>): i32 uses raw, ffi {
  let na = auk_arr_len(a)
  let nb = auk_arr_len(b)
  var i: i64 = 0
  while i < na && i < nb {
    let cmp = a.ops.cmp
    if cmp.is_null() {
      rc.auk__panic_rt("element type has no cmp")
      raw.unreachable()
    }
    let c = cmp(raw.cast(elem(a, i)), raw.cast(elem(b, i)))
    if c != 0 {
      return if c < 0 { -1 } else { 1 }
    }
    i += 1
  }
  (if na > nb { 1 } else { 0 }) - (if na < nb { 1 } else { 0 })
}

pub export fn auk_arr_hash(a: raw.Ptr<abi.Arr>): u64 uses raw, ffi {
  var h: u64 = 0x1234
  var i: i64 = 0
  while i < auk_arr_len(a) {
    let hash = a.ops.hash
    if hash.is_null() {
      rc.auk__panic_rt("element type has no hash")
      raw.unreachable()
    }
    h = rc.auk_hash_combine(h, hash(raw.cast(elem(a, i))))
    i += 1
  }
  h
}

pub export fn auk_arr_show(a: raw.Ptr<abi.Arr>): raw.Ptr<abi.Str> uses raw, ffi {
  var b = abi.StrBuf {}
  let pb = raw.addr_of(&b)
  auk_sb_char(pb, 91) // '['
  var i: i64 = 0
  while i < auk_arr_len(a) && !auk__show_exhausted() {
    if i != 0 {
      auk_sb_lit(pb, ", ")
    }
    let show = a.ops.show
    if show.is_null() {
      rc.auk__panic_rt("show: element type has no show")
      raw.unreachable()
    }
    auk_sb_str_own(pb, show(raw.cast(elem(a, i))))
    i += 1
  }
  auk_sb_char(pb, 93) // ']'
  auk_sb_finish(pb)
}

export fn auk_arr_join(a: raw.Ptr<abi.Arr>, sep: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> uses raw, ffi {
  var b = abi.StrBuf {}
  let pb = raw.addr_of(&b)
  var i: i64 = 0
  while i < auk_arr_len(a) {
    if i != 0 {
      auk_sb_str(pb, sep)
    }
    let ops = a.ops
    if ops.int() == str.ops_str().int() {
      auk_sb_str(pb, raw.cast<raw.Ptr<abi.Str>>(elem(a, i)).load())
    } else if ops.int() == rc.ops_char().int() {
      auk_sb_char(pb, raw.cast<u32>(elem(a, i)).load())
    } else {
      let show = ops.show
      if show.is_null() {
        rc.auk__panic_rt("element type has no show")
        raw.unreachable()
      }
      auk_sb_str_own(pb, show(raw.cast(elem(a, i))))
    }
    i += 1
  }
  auk_sb_finish(pb)
}

export fn auk_arr_sum_int(a: raw.Ptr<abi.Arr>, loc: raw.Ptr<u8>): i64 uses raw, ffi {
  var s: i64 = 0
  let d: raw.Ptr<i64> = raw.cast(auk_arr_data(a))
  var i: i64 = 0
  while i < auk_arr_len(a) {
    // auk_add
    let (r, o) = raw.add_overflow(s, d.at(i))
    if o {
      rc.auk_panic_overflow(loc, "+")
      raw.unreachable()
    }
    s = r
    i += 1
  }
  s
}

export fn auk_arr_sum_float(a: raw.Ptr<abi.Arr>): float uses raw {
  var s = 0.0
  let d: raw.Ptr<float> = raw.cast(auk_arr_data(a))
  var i: i64 = 0
  while i < auk_arr_len(a) {
    s += d.at(i)
    i += 1
  }
  s
}
