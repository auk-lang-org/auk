/// Err: message, code, cause chain and an optional typed payload (was runtime/c/err.c, ported
/// line by line). The ABI is auk_rt.h's: `AukErr` (`abi.Err`), every `auk_err_*` / `auk__err_*`
/// entry point under its C name.

// the rest of the runtime (C, for now)
extern fn auk__alloc(size: usize, kind: u32): raw.Ptr<()> = "void *auk__alloc(size_t, uint32_t)"
extern fn auk__free_obj(p: raw.Ptr<()>) = "void auk__free_obj(void *)"
extern fn auk__xmalloc(n: usize): raw.Ptr<()> = "void *auk__xmalloc(size_t)"
extern fn auk_retain(p: raw.Ptr<()>): raw.Ptr<()> = "void *auk_retain(void *)"
extern fn auk_release(p: raw.Ptr<()>) = "void auk_release(void *)"
extern fn auk_str_lit(s: raw.Ptr<u8>): raw.Ptr<abi.Str> = "void *auk_str_lit(const char *)"
extern fn auk_str_cstr(s: raw.Ptr<abi.Str>): raw.Ptr<u8> = "const char *auk_str_cstr(const void *)"
extern fn auk_sb_bytes(b: raw.Ptr<abi.StrBuf>, p: raw.Ptr<u8>, n: i64) = "void auk_sb_bytes(void *, const char *, int64_t)"
extern fn auk_sb_str(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<abi.Str>) = "void auk_sb_str(void *, const void *)"
extern fn auk_sb_finish(b: raw.Ptr<abi.StrBuf>): raw.Ptr<abi.Str> = "void *auk_sb_finish(void *)"
// libc
extern fn strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
extern fn strerror(err: i32): raw.Ptr<u8> = "char *strerror(int)"

/// New error; msg is borrowed.
export fn auk_err_new(msg: raw.Ptr<abi.Str>): raw.Ptr<abi.Err> uses raw, ffi {
  let e: raw.Ptr<abi.Err> = raw.cast(auk__alloc(raw.size_of<abi.Err>(), abi.K_ERR))
  e.msg = if msg.is_null() { auk_str_lit("") } else { raw.cast(auk_retain(raw.cast(msg))) }
  e
}

/// The bytes go through a string builder, so they count against a trace's show budget and
/// invalid UTF-8 is repaired.
export fn auk__err_bytes(msg: raw.Ptr<u8>, n: usize): raw.Ptr<abi.Err> uses raw, ffi {
  var b = abi.StrBuf {}
  auk_sb_bytes(raw.addr_of(&b), msg, i64(n))
  let s = auk_sb_finish(raw.addr_of(&b))
  let e = auk_err_new(s)
  auk_release(raw.cast(s))
  e
}

/// A new error with a NUL-terminated message.
export fn auk_err_new_cstr(msg: raw.Ptr<u8>): raw.Ptr<abi.Err> uses raw, ffi {
  if msg.is_null() {
    return auk__err_bytes("", 0)
  }
  auk__err_bytes(msg, strlen(msg))
}

export fn auk_err_wrap(msg: raw.Ptr<abi.Str>, cause: raw.Ptr<abi.Err>): raw.Ptr<abi.Err> uses raw, ffi {
  let e = auk_err_new(msg)
  e.cause = raw.cast(auk_retain(raw.cast(cause)))
  e
}

export fn auk_err_typed(type_id: u32, value: raw.Ptr<()>, ops: raw.Ptr<abi.ElemOps>, msg: raw.Ptr<abi.Str>): raw.Ptr<abi.Err> uses raw, ffi {
  let show = ops.show
  let m: raw.Ptr<abi.Str> = if !msg.is_null() {
    raw.cast(auk_retain(raw.cast(msg)))
  } else if !show.is_null() {
    show(value)
  } else {
    auk_str_lit("error")
  }
  let e = auk_err_new(m)
  auk_release(raw.cast(m))
  let pl = raw.field_addr(e, .payload)
  pl.type_id = type_id
  pl.ops = ops
  let data = auk__xmalloc(ops.size)
  pl.data = data
  raw.copy(data, value, ops.size)
  let retain = ops.retain
  if !retain.is_null() {
    retain(data)
  }
  e
}

export fn auk_err_payload(e: raw.Ptr<abi.Err>, type_id: u32): raw.Ptr<()> uses raw {
  if e.is_null() || e.payload.data.is_null() || e.payload.type_id != type_id {
    return raw.null()
  }
  e.payload.data
}

pub export fn auk_err_show(e: raw.Ptr<abi.Err>): raw.Ptr<abi.Str> uses raw, ffi {
  var b = abi.StrBuf {}
  var c = e
  while !c.is_null() {
    if c != e {
      auk_sb_bytes(raw.addr_of(&b), ": ", 2)
    }
    auk_sb_str(raw.addr_of(&b), c.msg)
    c = c.cause
  }
  auk_sb_finish(raw.addr_of(&b))
}

/// Iterative over the cause chain, so a long chain can't overflow the stack.
export fn auk__err_free(e0: raw.Ptr<abi.Err>) uses raw, ffi {
  var e = e0
  while !e.is_null() {
    let next = e.cause
    auk_release(raw.cast(e.msg))
    let data = e.payload.data
    if !data.is_null() {
      let release = e.payload.ops.release
      if !release.is_null() {
        release(data)
      }
      raw.free(data)
    }
    auk__free_obj(raw.cast(e))
    if next.is_null() {
      break
    }
    if raw.atomic_sub(raw.field_addr(raw.field_addr(next, .h), .rc), 1, raw.Order.AcqRel) != 1 {
      break
    }
    e = next
  }
}

/// "<what> <subject>: <strerror>" (or "<what>: <strerror>") with code err. The subject is
/// taken as a C string: it ends at an embedded NUL.
pub export fn auk__err_errno(what: raw.Ptr<u8>, subject: raw.Ptr<abi.Str>, err: i32): raw.Ptr<abi.Err> uses raw, ffi {
  let se = strerror(err)
  let subj: raw.Ptr<u8> = if subject.is_null() { raw.null() } else { auk_str_cstr(subject) }
  let nw: usize = if what.is_null() { 0 } else { strlen(what) }
  let ns: usize = if subj.is_null() { 0 } else { strlen(subj) + 1 }
  let ne = strlen(se)
  let m: raw.Ptr<u8> = raw.cast(auk__xmalloc(nw + ns + 2 + ne))
  var k: usize = 0
  raw.copy(m, what, nw)
  k += nw
  if !subj.is_null() {
    m.at(k) = 32 // ' '
    k += 1
    raw.copy(m.offset(k), subj, ns - 1)
    k += ns - 1
  }
  m.at(k) = 58 // ':'
  k += 1
  m.at(k) = 32 // ' '
  k += 1
  raw.copy(m.offset(k), se, ne)
  k += ne
  let e = auk__err_bytes(m, k)
  raw.free(m)
  e.code = i64(err)
  e
}
