/// Deep copies, for values crossing a task boundary (heap.auk): spawn arguments, `await` results
/// and channel messages. A copy is allocated in the current heap and shares nothing with the
/// original, except immortal objects (literals, imprints: never freed) and handles (tasks,
/// connections, listeners, channels: shared by reference count, never tracked). (Was
/// runtime/c/copy.c, ported line by line.)

// the rest of the runtime (C, or another module's `export fn`, which such an `extern fn` resolves to)
extern fn auk_str_from_bytes(p: raw.Ptr<u8>, n: i64): raw.Ptr<abi.Str> = "void *auk_str_from_bytes(const char *, int64_t)"
extern fn auk_arr_new(ops: raw.Ptr<abi.ElemOps>, cap: i64): raw.Ptr<abi.Arr> = "void *auk_arr_new(const void *, int64_t)"
extern fn auk_arr_at(a: raw.Ptr<abi.Arr>, i: i64, loc: raw.Ptr<u8>): raw.Ptr<()> = "void *auk_arr_at(const void *, int64_t, const char *)"
extern fn auk_map_new(k: raw.Ptr<abi.ElemOps>, v: raw.Ptr<abi.ElemOps>): raw.Ptr<abi.Map> = "void *auk_map_new(const void *, const void *)"
extern fn auk_map_set(pm: raw.Ptr<raw.Ptr<abi.Map>>, k: raw.Ptr<()>, v: raw.Ptr<()>) =
  "void auk_map_set(void *, const void *, const void *)"
extern fn auk_err_new(msg: raw.Ptr<abi.Str>): raw.Ptr<abi.Err> = "void *auk_err_new(const void *)"

fn immortal(p: raw.Ptr<()>): bool uses raw =
  raw.atomic_load(raw.field_addr(raw.cast<abi.Header>(p), .rc), raw.Order.Relaxed) < 0

/// A closure env or box: size bytes with its drop and copy functions.
export fn auk_obj_alloc(size: usize, drop: raw.Fn<(raw.Ptr<abi.Obj>) => ()>, copy: raw.Fn<(raw.Ptr<abi.Obj>) => raw.Ptr<abi.Obj>>): raw.Ptr<()> uses raw, ffi {
  var n = size
  if n < raw.size_of<abi.Obj>() {
    n = raw.size_of<abi.Obj>()
  }
  let o: raw.Ptr<abi.Obj> = raw.cast(rc.auk__alloc(n, abi.K_OBJ))
  o.drop = drop
  o.copy = copy
  raw.cast(o)
}

export fn auk_obj_copy(o: raw.Ptr<abi.Obj>): raw.Ptr<abi.Obj> uses raw, ffi {
  if o.is_null() || immortal(raw.cast(o)) {
    return o
  }
  let cp = o.copy
  if !cp.is_null() {
    return cp(o)
  }
  raw.cast(rc.retain(raw.cast(o)))
}

export fn auk_str_copy(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> uses raw, ffi {
  if s.is_null() || immortal(raw.cast(s)) {
    return s
  }
  auk_str_from_bytes(s.data, s.len_bytes)
}

/// Copy one element of ops from src to dst (a byte copy plus a retain without a `copy`).
pub export fn auk__copy_elem(ops: raw.Ptr<abi.ElemOps>, src: raw.Ptr<()>, dst: raw.Ptr<()>) uses raw {
  let cp = ops.copy
  if !cp.is_null() {
    cp(src, dst)
    return
  }
  raw.copy(dst, src, ops.size)
  let retain = ops.retain
  if !retain.is_null() {
    retain(dst)
  }
}

export fn auk_arr_copy_deep(a: raw.Ptr<abi.Arr>): raw.Ptr<abi.Arr> uses raw, ffi {
  if a.is_null() || immortal(raw.cast(a)) {
    return a
  }
  let ops = a.ops
  let n = a.len
  let b = auk_arr_new(ops, n)
  var i: i64 = 0
  while i < n {
    auk__copy_elem(ops, auk_arr_at(a, i, raw.null()), raw.cast(b.data.offset(usize(i) * ops.size)))
    i += 1
  }
  b.len = n
  b
}

export fn auk_map_copy_deep(m: raw.Ptr<abi.Map>): raw.Ptr<abi.Map> uses raw, ffi {
  if m.is_null() || immortal(raw.cast(m)) {
    return m
  }
  let kops = m.kops
  let vops = m.vops
  var out = auk_map_new(kops, vops)
  let kb = rc.auk__xcalloc(1, kops.size)
  let vb = rc.auk__xcalloc(1, vops.size)
  var i: i64 = 0
  while i < m.n {
    if !m.dead.at(i) {
      auk__copy_elem(kops, raw.cast(abi.map_key(m, i)), kb)
      auk__copy_elem(vops, raw.cast(abi.map_val(m, i)), vb)
      // the map retains its own copies of borrowed elements
      auk_map_set(raw.addr_of(&out), kb, vb)
      let krelease = kops.release
      if !krelease.is_null() {
        krelease(kb)
      }
      let vrelease = vops.release
      if !vrelease.is_null() {
        vrelease(vb)
      }
    }
    i += 1
  }
  raw.free(kb)
  raw.free(vb)
  out
}

export fn auk_err_copy_deep(e: raw.Ptr<abi.Err>): raw.Ptr<abi.Err> uses raw, ffi {
  if e.is_null() || immortal(raw.cast(e)) {
    return e
  }
  let msg = auk_str_copy(e.msg)
  let c = auk_err_new(msg)
  rc.release(raw.cast(msg))
  c.code = e.code
  c.cause = auk_err_copy_deep(e.cause)
  if !e.payload.data.is_null() {
    c.payload.type_id = e.payload.type_id
    c.payload.ops = e.payload.ops
    c.payload.data = rc.auk__xmalloc(e.payload.ops.size)
    auk__copy_elem(e.payload.ops, e.payload.data, c.payload.data)
  }
  c
}

export fn auk_value_copy(v: abi.Value): abi.Value uses raw, ffi {
  var out = v
  let t = v.tag
  if t == abi.V_STR {
    out.u.s = auk_str_copy(v.u.s)
  } else if t == abi.V_LIST {
    out.u.list = auk_arr_copy_deep(v.u.list)
  } else if t == abi.V_MAP {
    out.u.map = auk_map_copy_deep(v.u.map)
  }
  out
}

// ---- `copy` entries of the built-in element ops ----

pub export fn auk__str_copy_elem(src: raw.Ptr<()>, dst: raw.Ptr<()>) uses raw, ffi {
  raw.cast<raw.Ptr<abi.Str>>(dst).store(auk_str_copy(raw.cast<raw.Ptr<abi.Str>>(src).load()))
}

pub export fn auk__arr_copy_elem(src: raw.Ptr<()>, dst: raw.Ptr<()>) uses raw, ffi {
  raw.cast<raw.Ptr<abi.Arr>>(dst).store(auk_arr_copy_deep(raw.cast<raw.Ptr<abi.Arr>>(src).load()))
}

pub export fn auk__map_copy_elem(src: raw.Ptr<()>, dst: raw.Ptr<()>) uses raw, ffi {
  raw.cast<raw.Ptr<abi.Map>>(dst).store(auk_map_copy_deep(raw.cast<raw.Ptr<abi.Map>>(src).load()))
}

pub export fn auk__err_copy_elem(src: raw.Ptr<()>, dst: raw.Ptr<()>) uses raw, ffi {
  raw.cast<raw.Ptr<abi.Err>>(dst).store(auk_err_copy_deep(raw.cast<raw.Ptr<abi.Err>>(src).load()))
}

pub export fn auk__obj_copy_elem(src: raw.Ptr<()>, dst: raw.Ptr<()>) uses raw, ffi {
  raw.cast<raw.Ptr<abi.Obj>>(dst).store(auk_obj_copy(raw.cast<raw.Ptr<abi.Obj>>(src).load()))
}

/// A handle (a task): shared, not copied.
pub export fn auk__handle_copy_elem(src: raw.Ptr<()>, dst: raw.Ptr<()>) uses raw, ffi {
  raw.cast<raw.Ptr<()>>(dst).store(rc.retain(raw.cast<raw.Ptr<()>>(src).load()))
}

/// A closure {code, env}: the same code with a copy of the env.
pub export fn auk__closure_copy_elem(src: raw.Ptr<()>, dst: raw.Ptr<()>) uses raw, ffi {
  let s: raw.Ptr<abi.Closure> = raw.cast(src)
  let d: raw.Ptr<abi.Closure> = raw.cast(dst)
  d.func = s.func
  d.env = if s.env.is_null() { raw.null() } else { auk_obj_copy(s.env) }
}

pub export fn auk__value_copy_elem(src: raw.Ptr<()>, dst: raw.Ptr<()>) uses raw, ffi {
  raw.cast<abi.Value>(dst).store(auk_value_copy(raw.cast<abi.Value>(src).load()))
}
