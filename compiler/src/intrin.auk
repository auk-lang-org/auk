/// Runtime calls compiled inline (src/mir/llvm/intrin.rs): the hot ones (checked arithmetic,
/// list reads and writes, reference counting) get their fast path in the generated code and call
/// the runtime only on the slow or failing path. A failing path calls the *same* runtime
/// function with the same arguments (which then panics), so messages and edge cases are exactly
/// the runtime's.
///
/// Layouts used here (runtime/c/auk_rt.h): `AukHeader { rc: i64 @0, kind: u32 @8 }`,
/// `AukArr { h @0, ops @16, len @24, cap @32, data @40, base @48 }`, `AukElemOps { size @0 }`.
/// Handle kinds (`heap::is_handle`): 6..=10.

let ARR_OPS = 16
let ARR_LEN = 24
let ARR_CAP = 32
let ARR_DATA = 40
let ARR_BASE = 48
let HDR_KIND = 8
let HANDLE_FIRST = 6
let HANDLE_COUNT = 5

fn is_int(e: mir.Ex): bool = match e.ty {
  D(Int) | I64 => true
  _ => false
}

/// Compile runtime call `sym(args)` inline, if it is one of the known ones.
pub fn rt_inline(g: var codegen.Gen, sym: str, args: [mir.Ex], ret: mir.MTy): codegen.V? uses ffi {
  if !g.inline_rt { return none }
  let n = args.len()
  let b = g.b
  let i64 = g.t_i64
  if (sym == "auk_add" || sym == "auk_sub" || sym == "auk_mul") &&
    n == 3 &&
    is_int(args[0]) &&
    is_int(args[1]) {
    let op = if sym == "auk_add" {
      "llvm.sadd.with.overflow"
    } else if sym == "auk_sub" {
      "llvm.ssub.with.overflow"
    } else {
      "llvm.smul.with.overflow"
    }
    let vals = eval_args(&g, args)
    let (f, ft) = codegen.intrinsic(g, op, [i64])
    let r = llvm.builder.build_call2(b, ft, f, [vals[0], vals[1]], "")
    let of = llvm.builder.build_extract_value(b, r, 1, "")
    fail_if(&g, of, sym, args, vals, ret)
    return codegen.V.S(llvm.builder.build_extract_value(g.b, r, 0, ""))
  }
  if (sym == "auk_div" || sym == "auk_mod") && n == 3 && is_int(args[0]) && is_int(args[1]) {
    let vals = eval_args(&g, args)
    let (x, y) = (vals[0], vals[1])
    let zero = llvm.values.const_int(i64, 0, 0)
    let m1 = llvm.values.const_int(i64, -1, 1)
    let by0 = llvm.builder.build_icmp(b, llvm.INT_EQ, y, zero, "")
    if sym == "auk_div" {
      // also MIN / -1 overflows
      let min = llvm.values.const_int(i64, -9223372036854775807 - 1, 1)
      let xm = llvm.builder.build_icmp(b, llvm.INT_EQ, x, min, "")
      let ym = llvm.builder.build_icmp(b, llvm.INT_EQ, y, m1, "")
      let ov = llvm.builder.build_and(b, xm, ym, "")
      let bad = llvm.builder.build_or(b, by0, ov, "")
      fail_if(&g, bad, sym, args, vals, ret)
      return codegen.V.S(llvm.builder.build_sdiv(g.b, x, y, ""))
    }
    // x % -1 is 0 (and x % 1 is too, without MIN % -1's overflow)
    fail_if(&g, by0, sym, args, vals, ret)
    let ym = llvm.builder.build_icmp(g.b, llvm.INT_EQ, y, m1, "")
    let y1 = llvm.builder.build_select(g.b, ym, llvm.values.const_int(i64, 1, 0), y, "")
    return codegen.V.S(llvm.builder.build_srem(g.b, x, y1, ""))
  }
  if (sym == "auk_shl" || sym == "auk_shr") && n == 3 && is_int(args[0]) && is_int(args[1]) {
    let vals = eval_args(&g, args)
    let bad = llvm.builder.build_icmp(
      b,
      llvm.INT_UGT,
      vals[1],
      llvm.values.const_int(i64, 63, 0),
      "",
    )
    fail_if(&g, bad, sym, args, vals, ret)
    return codegen.V.S(
      if sym == "auk_shl" {
        llvm.builder.build_shl(g.b, vals[0], vals[1], "")
      } else {
        llvm.builder.build_ashr(g.b, vals[0], vals[1], "")
      },
    )
  }
  // exact float operations (bit-identical to Rust's f64 methods in the runtime)
  let fname = match sym {
    "auk_fsqrt" => "llvm.sqrt"
    "auk_fabs" => "llvm.fabs"
    "auk_ffloor" => "llvm.floor"
    "auk_fceil" => "llvm.ceil"
    "auk_fround" => "llvm.round"
    _ => ""
  }
  if fname != "" && n == 1 {
    let vals = eval_args(&g, args)
    let (f, ft) = codegen.intrinsic(g, fname, [g.t_f64])
    return codegen.V.S(llvm.builder.build_call2(g.b, ft, f, [vals[0]], ""))
  }
  if sym == "auk_arr_len" && n == 1 {
    let vals = eval_args(&g, args)
    return codegen.V.S(arr_len(&g, vals[0]))
  }
  if sym == "auk_arr_at" && n == 3 && is_int(args[1]) {
    let size = g.elem_hint
    g.elem_hint = none
    let vals = eval_args(&g, args)
    let (a, i) = (vals[0], vals[1])
    let len = arr_len(&g, a)
    let bad = llvm.builder.build_icmp(g.b, llvm.INT_UGE, i, len, "")
    fail_if(&g, bad, sym, args, vals, ret)
    let sz = match size {
      some(s) => llvm.values.const_int(g.t_i64, s, 0)
      none => {
        let ops = codegen.load_ty(g, g.t_ptr, codegen.gep(g, a, ARR_OPS))
        codegen.load_ty(g, g.t_i64, ops)
      }
    }
    return codegen.V.S(elem_addr(g, a, i, sz))
  }
  if sym == "auk_arr_set" && n == 4 && is_int(args[1]) {
    let (s, size) = plain_elem(&g, args[2]) else return none
    let vals = eval_args(&g, args)
    let (pa, i, ep) = (vals[0], vals[1], vals[2])
    // fast: a unique list and i in range
    let (a, slow, done) = unique_list(&g, pa)
    let len = codegen.load_ty(g, g.t_i64, codegen.gep(g, a, ARR_LEN))
    let inr = llvm.builder.build_icmp(g.b, llvm.INT_ULT, i, len, "")
    let st = codegen.new_block(g, "set.store")
    llvm.builder.build_cond_br(g.b, likely(g, inr), st, slow)
    codegen.switch_to(&g, st)
    let v = codegen.load_ty(g, s, ep)
    let at = elem_addr(g, a, i, llvm.values.const_int(g.t_i64, size, 0))
    codegen.store(g, v, at)
    slow_and_join(&g, slow, done, sym, args, vals, ret)
    return codegen.V.Nil
  }
  if sym == "auk_arr_push" && n == 2 {
    let (s, size) = plain_elem(&g, args[1]) else return none
    let vals = eval_args(&g, args)
    let (pa, ep) = (vals[0], vals[1])
    // fast: a unique list with room for one more
    let (a, slow, done) = unique_list(&g, pa)
    let len = codegen.load_ty(g, g.t_i64, codegen.gep(g, a, ARR_LEN))
    let cap = codegen.load_ty(g, g.t_i64, codegen.gep(g, a, ARR_CAP))
    let room = llvm.builder.build_icmp(g.b, llvm.INT_SLT, len, cap, "")
    let st = codegen.new_block(g, "push.store")
    llvm.builder.build_cond_br(g.b, likely(g, room), st, slow)
    codegen.switch_to(&g, st)
    let v = codegen.load_ty(g, s, ep)
    let at = elem_addr(g, a, len, llvm.values.const_int(g.t_i64, size, 0))
    codegen.store(g, v, at)
    let n1 = llvm.builder.build_add(g.b, len, llvm.values.const_int(g.t_i64, 1, 0), "")
    codegen.store(g, n1, codegen.gep(g, a, ARR_LEN))
    slow_and_join(&g, slow, done, sym, args, vals, ret)
    return codegen.V.Nil
  }
  if sym == "auk_arr_push_own" && n == 2 {
    // moving an owned value in: a plain copy of its bytes, whatever the type
    let e = args[1]
    let ety = match e.k {
      Cast(x) => x.ty
      _ => e.ty
    }
    let et = match ety {
      Ptr(t) => t
      _ => return none
    }
    let size = codegen.lay(&g, et).size
    let vals = eval_args(&g, args)
    let (pa, ep) = (vals[0], vals[1])
    let (a, slow, done) = unique_list(&g, pa)
    let len = codegen.load_ty(g, g.t_i64, codegen.gep(g, a, ARR_LEN))
    let cap = codegen.load_ty(g, g.t_i64, codegen.gep(g, a, ARR_CAP))
    let room = llvm.builder.build_icmp(g.b, llvm.INT_SLT, len, cap, "")
    let st = codegen.new_block(g, "push.store")
    llvm.builder.build_cond_br(g.b, likely(g, room), st, slow)
    codegen.switch_to(&g, st)
    let at = elem_addr(g, a, len, llvm.values.const_int(g.t_i64, size, 0))
    codegen.copy(&g, at, ep, et)
    let n1 = llvm.builder.build_add(g.b, len, llvm.values.const_int(g.t_i64, 1, 0), "")
    codegen.store(g, n1, codegen.gep(g, a, ARR_LEN))
    slow_and_join(&g, slow, done, sym, args, vals, ret)
    return codegen.V.Nil
  }
  if sym == "auk_retain" && n == 1 {
    let vals = eval_args(&g, args)
    let p = vals[0]
    rc_update(&g, p, true, args, vals, ret)
    return codegen.V.S(p)
  }
  if sym == "auk_release" && n == 1 {
    let vals = eval_args(&g, args)
    rc_update(&g, vals[0], false, args, vals, ret)
    return codegen.V.Nil
  }
  none
}

/// The scalar type and size of a list element passed as `(void *)&v`, if it holds no
/// references (no retain/release needed: storing it is a plain store).
fn plain_elem(g: var codegen.Gen, e: mir.Ex): (llvm.Type, int)? {
  let ety = match e.k {
    Cast(x) => x.ty
    _ => e.ty
  }
  let et = match ety {
    Ptr(t) => t
    _ => return none
  }
  match et {
    D(d) => if mir.types.is_ptr(g.lay.info, d) { return none }
    _ => return none
  }
  let s = codegen.scalar(g, et) else return none
  (s, codegen.lay(&g, et).size)
}

/// Load the list `*pa` and branch on whether it may be mutated in place: non-NULL and
/// unique (one reference, not a slice view). Continues in the "unique" block; returns the
/// list and the slow and join blocks.
fn unique_list(
  g: var codegen.Gen,
  pa: llvm.Value,
): (llvm.Value, llvm.BasicBlock, llvm.BasicBlock) uses ffi {
  let a = codegen.load_ty(g, g.t_ptr, pa)
  let nonnull = llvm.builder.build_is_not_null(g.b, a, "")
  let check = codegen.new_block(g, "list.check")
  let slow = codegen.new_block(g, "list.slow")
  let done = codegen.new_block(g, "list.done")
  llvm.builder.build_cond_br(g.b, likely(g, nonnull), check, slow)
  codegen.switch_to(&g, check)
  let base = codegen.load_ty(g, g.t_ptr, codegen.gep(g, a, ARR_BASE))
  let noview = llvm.builder.build_is_null(g.b, base, "")
  let rc = codegen.load_ty(g, g.t_i64, a)
  let one = llvm.builder.build_icmp(g.b, llvm.INT_EQ, rc, llvm.values.const_int(g.t_i64, 1, 0), "")
  let uniq = llvm.builder.build_and(g.b, noview, one, "")
  let fast = codegen.new_block(g, "list.unique")
  llvm.builder.build_cond_br(g.b, likely(g, uniq), fast, slow)
  codegen.switch_to(&g, fast)
  (a, slow, done)
}

/// End the fast path (jump to `done`), emit the slow path (the runtime call) and continue
/// after both.
fn slow_and_join(
  g: var codegen.Gen,
  slow: llvm.BasicBlock,
  done: llvm.BasicBlock,
  sym: str,
  args: [mir.Ex],
  vals: [llvm.Value],
  ret: mir.MTy,
) uses ffi {
  codegen.br(g, done)
  codegen.switch_to(&g, slow)
  slow_call(&g, sym, args, vals, ret)
  codegen.br(g, done)
  codegen.switch_to(&g, done)
}

/// The arguments' values, each converted to its own scalar type.
fn eval_args(g: var codegen.Gen, args: [mir.Ex]): [llvm.Value] uses ffi {
  var out: [llvm.Value] = []
  for a in args { out.push(codegen.val(&g, a)) }
  out
}

/// `cond` marked as almost always true.
fn likely(g: codegen.Gen, cond: llvm.Value): llvm.Value uses ffi {
  let (f, ft) = codegen.intrinsic(g, "llvm.expect", [g.t_i1])
  llvm.builder.build_call2(g.b, ft, f, [cond, llvm.values.const_int(g.t_i1, 1, 0)], "")
}

/// If `bad`, call the runtime function itself (which panics) on a cold path.
fn fail_if(
  g: var codegen.Gen,
  bad: llvm.Value,
  sym: str,
  args: [mir.Ex],
  vals: [llvm.Value],
  ret: mir.MTy,
) uses ffi {
  let ok = llvm.builder.build_not(g.b, bad, "")
  let cold = codegen.new_block(g, "rt.fail")
  let cont = codegen.new_block(g, "rt.ok")
  llvm.builder.build_cond_br(g.b, likely(g, ok), cont, cold)
  codegen.switch_to(&g, cold)
  let c = slow_call(&g, sym, args, vals, ret)
  llvm.values.add_call_site_attribute(
    c,
    llvm.ATTRIBUTE_FUNCTION_INDEX,
    codegen.enum_attr(g, "cold"),
  )
  llvm.builder.build_unreachable(g.b)
  codegen.switch_to(&g, cont)
}

/// The out-of-line call to runtime function `sym` with already evaluated (scalar) arguments.
fn slow_call(
  g: var codegen.Gen,
  sym: str,
  args: [mir.Ex],
  vals: [llvm.Value],
  ret: mir.MTy,
): llvm.Value uses ffi {
  let ps = args.map(a => a.ty)
  let (sig, _, _) = codegen.c_sig(&g, ps, ret)
  let f = codegen.rt_func(&g, sym, sig)
  codegen.build_call(g, sig, f, vals)
}

/// `auk_arr_len`: a list's length (0 for NULL).
fn arr_len(g: var codegen.Gen, a: llvm.Value): llvm.Value uses ffi {
  let nonnull = llvm.builder.build_is_not_null(g.b, a, "")
  let ld = codegen.new_block(g, "len.load")
  let done = codegen.new_block(g, "len")
  let from = codegen.insert_block(g)
  llvm.builder.build_cond_br(g.b, likely(g, nonnull), ld, done)
  codegen.switch_to(&g, ld)
  let n = codegen.load_ty(g, g.t_i64, codegen.gep(g, a, ARR_LEN))
  let loaded = codegen.insert_block(g)
  codegen.br(g, done)
  codegen.switch_to(&g, done)
  let phi = llvm.builder.build_phi(g.b, g.t_i64, "")
  llvm.values.add_incoming(phi, [llvm.values.const_int(g.t_i64, 0, 0), n], [from, loaded])
  phi
}

/// The address of element `i` (size `size` bytes) of list `a`.
fn elem_addr(g: codegen.Gen, a: llvm.Value, i: llvm.Value, size: llvm.Value): llvm.Value uses ffi {
  let data = codegen.load_ty(g, g.t_ptr, codegen.gep(g, a, ARR_DATA))
  let off = llvm.builder.build_mul(g.b, i, size, "")
  llvm.builder.build_in_bounds_gep2(g.b, g.t_i8, data, [off], "")
}

/// `auk_retain(p)` / `auk_release(p)` inline: nothing for NULL and immortal objects (a
/// negative count), the runtime for handles (their heap keeps a ledger), an atomic add or
/// subtract otherwise; the last release frees the object through the runtime.
fn rc_update(
  g: var codegen.Gen,
  p: llvm.Value,
  retain: bool,
  args: [mir.Ex],
  vals: [llvm.Value],
  ret: mir.MTy,
) uses ffi {
  let sym = if retain { "auk_retain" } else { "auk_release" }
  let i64 = g.t_i64
  let done = codegen.new_block(g, "rc.done")
  let check = codegen.new_block(g, "rc.check")
  let nonnull = llvm.builder.build_is_not_null(g.b, p, "")
  llvm.builder.build_cond_br(g.b, nonnull, check, done)
  codegen.switch_to(&g, check)
  let rc = codegen.load_ty(g, i64, p)
  llvm.builder.set_ordering(rc, llvm.ATOMIC_ORDERING_MONOTONIC)
  llvm.values.set_alignment(rc, 8)
  let mortal = llvm.builder.build_icmp(g.b, llvm.INT_SGE, rc, llvm.values.const_int(i64, 0, 0), "")
  let kinds = codegen.new_block(g, "rc.kind")
  llvm.builder.build_cond_br(g.b, likely(g, mortal), kinds, done)
  codegen.switch_to(&g, kinds)
  let kind = codegen.load_ty(g, g.t_i32, codegen.gep(g, p, HDR_KIND))
  let rel = llvm.builder.build_sub(g.b, kind, llvm.values.const_int(g.t_i32, HANDLE_FIRST, 0), "")
  let handle = llvm.builder.build_icmp(
    g.b,
    llvm.INT_ULT,
    rel,
    llvm.values.const_int(g.t_i32, HANDLE_COUNT, 0),
    "",
  )
  let slow = codegen.new_block(g, "rc.handle")
  let fast = codegen.new_block(g, "rc.atomic")
  let not_handle = llvm.builder.build_not(g.b, handle, "")
  llvm.builder.build_cond_br(g.b, likely(g, not_handle), fast, slow)
  codegen.switch_to(&g, slow)
  slow_call(&g, sym, args, vals, ret)
  codegen.br(g, done)
  codegen.switch_to(&g, fast)
  let one = llvm.values.const_int(i64, 1, 0)
  if retain {
    llvm.builder.build_atomic_rmw(
      g.b,
      llvm.ATOMIC_RMW_BIN_OP_ADD,
      p,
      one,
      llvm.ATOMIC_ORDERING_MONOTONIC,
      0,
    )
    codegen.br(g, done)
  } else {
    let old = llvm.builder.build_atomic_rmw(
      g.b,
      llvm.ATOMIC_RMW_BIN_OP_SUB,
      p,
      one,
      llvm.ATOMIC_ORDERING_RELEASE,
      0,
    )
    let last = llvm.builder.build_icmp(g.b, llvm.INT_EQ, old, one, "")
    let free = codegen.new_block(g, "rc.free")
    llvm.builder.build_cond_br(g.b, last, free, done)
    codegen.switch_to(&g, free)
    llvm.builder.build_fence(g.b, llvm.ATOMIC_ORDERING_ACQUIRE, 0, "")
    let (sig, _, _) = codegen.c_sig(&g, [mir.void_ptr()], mir.MTy.Void)
    let f = codegen.rt_func(&g, "auk__free_last", sig)
    codegen.build_call(g, sig, f, [p])
    codegen.br(g, done)
  }
  codegen.switch_to(&g, done)
}
