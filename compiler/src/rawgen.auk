/// The runtime's dialect (docs/lowlevel.md) in the LLVM back end: the `@raw.*` calls that
/// lowering emits for core's `raw` intrinsics (`mir/lower/lowlevel.auk`) become memory
/// intrinsics, atomics, fences, `_setjmp`/`_longjmp`. No TBAA or other alias metadata is
/// attached (codegen emits none), so `raw.cast` reinterpretation and union punning stay valid.

/// Is `sym` a raw intrinsic call?
pub fn is_raw(sym: str): bool = sym.starts_with("@raw.")

/// `@raw.<op>[.<order>[.<order>]]` with its arguments; the result as a codegen value.
pub fn call(g: var codegen.Gen, sym: str, args: [mir.Ex], ret: mir.MTy): codegen.V uses ffi {
  let parts = sym.split(".")
  let op = parts[1]
  let ord = (k: int) => match parts.get(k) {
    some(s) => int.parse(s) else 7
    none => 7
  }
  let b = g.b
  match op {
    "memcpy" | "memmove" => {
      let dst = codegen.val(&g, args[0])
      let src = codegen.val(&g, args[1])
      let n = codegen.val(&g, args[2])
      if op == "memcpy" {
        let _ = llvm.builder.build_mem_cpy(b, dst, 1, src, 1, n)
      } else {
        let _ = llvm.builder.build_mem_move(b, dst, 1, src, 1, n)
      }
      codegen.V.Nil
    }
    "memset" => {
      let dst = codegen.val(&g, args[0])
      let v = codegen.val(&g, args[1])
      let n = codegen.val(&g, args[2])
      let _ = llvm.builder.build_mem_set(b, dst, v, n, 1)
      codegen.V.Nil
    }
    "unreachable" => {
      let _ = llvm.builder.build_unreachable(b)
      g.terminated = true
      codegen.V.Nil
    }
    "likely" => {
      let v = codegen.val(&g, args[0])
      let c = codegen.truth(g, v)
      let (f, ft) = codegen.intrinsic(g, "llvm.expect", [g.t_i1])
      let r = llvm.builder.build_call2(b, ft, f, [c, llvm.values.const_int(g.t_i1, 1, 0)], "")
      codegen.V.S(codegen.bool8(g, r))
    }
    "atomic_load" => {
      let p = codegen.val(&g, args[0])
      let t = codegen.scalar(g, ret) else mir.bug("atomic load of an aggregate")
      let l = llvm.builder.build_load2(b, t, p, "")
      llvm.builder.set_ordering(l, ord(2))
      llvm.values.set_alignment(l, codegen.lay(&g, ret).size)
      codegen.V.S(l)
    }
    "atomic_store" => {
      let p = codegen.val(&g, args[0])
      let v = codegen.val(&g, args[1])
      let s = llvm.builder.build_store(b, v, p)
      llvm.builder.set_ordering(s, ord(2))
      llvm.values.set_alignment(s, codegen.lay(&g, args[1].ty).size)
      codegen.V.Nil
    }
    "atomic_swap" | "atomic_add" | "atomic_sub" | "atomic_and" | "atomic_or" => {
      let p = codegen.val(&g, args[0])
      let v = codegen.val(&g, args[1])
      // LLVMAtomicRMWBinOp: Xchg, Add, Sub, And, Nand, Or
      let rop = match op {
        "atomic_swap" => 0
        "atomic_add" => 1
        "atomic_sub" => 2
        "atomic_and" => 3
        _ => 5
      }
      codegen.V.S(llvm.builder.build_atomic_rmw(b, rop, p, v, ord(2), 0))
    }
    "atomic_cas" => {
      let p = codegen.val(&g, args[0])
      let old = codegen.val(&g, args[1])
      let new = codegen.val(&g, args[2])
      let r = llvm.builder.build_atomic_cmp_xchg(b, p, old, new, ord(2), ord(3), 0)
      let v = llvm.builder.build_extract_value(b, r, 0, "")
      let okv = llvm.builder.build_extract_value(b, r, 1, "")
      // the `(T, bool)` result
      let a = codegen.temp(&g, ret)
      codegen.store(g, v, codegen.gep(g, a, codegen.offset(&g, ret, mir.Sel.F(0))))
      codegen.store(g, codegen.bool8(g, okv), codegen.gep(g, a, codegen.offset(&g, ret, mir.Sel.F(1))))
      codegen.V.M(a)
    }
    "overflow" => {
      // `@raw.overflow.sadd`: llvm.sadd.with.overflow, its result as a `(T, bool)`
      let a = codegen.val(&g, args[0])
      let b2 = codegen.val(&g, args[1])
      let ty = llvm.values.type_of(a)
      let (f, ft) = codegen.intrinsic(g, "llvm.{parts[2]}.with.overflow", [ty])
      let r = llvm.builder.build_call2(b, ft, f, [a, b2], "")
      let v = llvm.builder.build_extract_value(b, r, 0, "")
      let o = llvm.builder.build_extract_value(b, r, 1, "")
      let out = codegen.temp(&g, ret)
      codegen.store(g, v, codegen.gep(g, out, codegen.offset(&g, ret, mir.Sel.F(0))))
      codegen.store(g, codegen.bool8(g, o), codegen.gep(g, out, codegen.offset(&g, ret, mir.Sel.F(1))))
      codegen.V.M(out)
    }
    "bits" => {
      let x = codegen.val(&g, args[0])
      let ty = llvm.values.type_of(x)
      let (iname, extra) = match parts[2] {
        "ctz" => ("llvm.cttz", true)
        "clz" => ("llvm.ctlz", true)
        "popcount" => ("llvm.ctpop", false)
        _ => ("llvm.bswap", false)
      }
      let (f, ft) = codegen.intrinsic(g, iname, [ty])
      // cttz/ctlz of 0 is the width (not poison)
      let xs = if extra { [x, llvm.values.const_int(g.t_i1, 0, 0)] } else { [x] }
      codegen.V.S(llvm.builder.build_call2(b, ft, f, xs, ""))
    }
    "fence" => {
      let _ = llvm.builder.build_fence(b, ord(2), 0, "")
      codegen.V.Nil
    }
    "setjmp" => {
      // libc's `_setjmp` (LLVM lowers `llvm.eh.sjlj.setjmp` to nothing on AArch64), a call
      // that returns twice; the calling function is `optnone` (`codegen.program`)
      let buf = codegen.val(&g, args[0])
      let sig = codegen.Sig { ty: llvm.ir.function_type(g.t_i32, [g.t_ptr], 0), attrs: [] }
      let f = codegen.rt_func(&g, "_setjmp", sig)
      let rt = codegen.enum_attr(g, "returns_twice")
      llvm.values.add_attribute_at_index(f, llvm.ATTRIBUTE_FUNCTION_INDEX, rt)
      let c = llvm.builder.build_call2(b, sig.ty, f, [buf], "")
      llvm.values.add_call_site_attribute(c, llvm.ATTRIBUTE_FUNCTION_INDEX, rt)
      let nz = llvm.builder.build_icmp(b, llvm.INT_NE, c, llvm.values.const_int(g.t_i32, 0, 0), "")
      codegen.V.S(codegen.bool8(g, nz))
    }
    "longjmp" => {
      let buf = codegen.val(&g, args[0])
      let sig = codegen.Sig { ty: llvm.ir.function_type(g.t_void, [g.t_ptr, g.t_i32], 0), attrs: [] }
      let f = codegen.rt_func(&g, "_longjmp", sig)
      llvm.values.add_attribute_at_index(f, llvm.ATTRIBUTE_FUNCTION_INDEX, codegen.enum_attr(g, "noreturn"))
      let _ = llvm.builder.build_call2(b, sig.ty, f, [buf, llvm.values.const_int(g.t_i32, 1, 0)], "")
      codegen.V.Nil
    }
    _ => mir.bug("unknown raw call {sym}")
  }
}

/// A global of the runtime's dialect: `raw var` (internal, like a C `static`), `raw thread var`
/// (also `_Thread_local`: LLVM's default general-dynamic model, which Mach-O lowers to TLV
/// descriptors and ELF to `__tls_get_addr`; a linker relaxes it in an executable), `export var`
/// (external, its own name). Its constant initializer is written out as bytes.
pub fn global(g: var codegen.Gen, gl: mir.Global): llvm.Value! uses ffi {
  let l = codegen.lay(&g, gl.ty)
  if gl.kind == 5 {
    // `extern var`: defined in C, declared here (no initializer)
    let gv = llvm.values.add_global(g.m, llvm.ir.array_type2(g.t_i8, l.size), gl.name)
    llvm.values.set_linkage(gv, llvm.EXTERNAL_LINKAGE)
    return gv
  }
  // addresses are placeholders (null) until every global exists: `init_globals`
  let init = image(&g, gl, false)?
  let gv = llvm.values.add_global(g.m, llvm.values.type_of(init), gl.name)
  llvm.values.set_initializer(gv, init)
  llvm.values.set_linkage(gv, if gl.kind == 4 { llvm.EXTERNAL_LINKAGE } else { llvm.INTERNAL_LINKAGE })
  if gl.kind == 2 { llvm.values.set_thread_local(gv, 1) }
  llvm.values.set_alignment(gv, max(l.align, 8))
  gv
}

/// The initializer of a raw global: its bytes, as a packed struct of byte runs and pointers
/// when it holds addresses (null placeholders unless `real`).
fn image(g: var codegen.Gen, gl: mir.Global, real: bool): llvm.Value! uses ffi {
  let size = max(codegen.lay(&g, gl.ty).size, 1)
  var bytes = (0..size).map(_ => 0)
  var ptrs: [(int, llvm.Value)] = []
  match gl.init {
    some(e) => fill(&g, &bytes, &ptrs, real, 0, gl.ty, e)?
    none => {}
  }
  if ptrs.len() == 0 {
    let ty = llvm.ir.array_type2(g.t_i8, size)
    return if bytes.all(b => b == 0) { llvm.values.const_null(ty) } else { codegen.const_bytes(g, bytes) }
  }
  var fields: [llvm.Value] = []
  var at = 0
  for (off, p) in ptrs.sort_by(p => p.0) {
    if off > at { fields.push(codegen.const_bytes(g, bytes[at..off])) }
    fields.push(p)
    at = off + 8
  }
  if at < bytes.len() { fields.push(codegen.const_bytes(g, bytes[at..bytes.len()])) }
  llvm.values.const_struct_in_context(g.cx, fields, 1)
}

/// The real initializers of the raw globals that hold addresses (all globals exist now).
pub fn init_globals(g: var codegen.Gen): ()! uses ffi {
  for i, gl in g.prog.globals {
    if gl.kind == 0 || gl.kind == 5 || !has_addr(gl.init) { continue }
    let init = image(&g, gl, true)?
    llvm.values.set_initializer(g.globals[i], init)
  }
}

fn has_addr(e: mir.Ex?): bool = match e {
  some(x) => match x.k {
    GlobalAddr(_) | FnAddr(_) => true
    Cast(y) => has_addr(some(y))
    Agg(ms) => ms.any(m => has_addr(some(m.1)))
    _ => false
  }
  none => false
}

/// Write the constant `e` (of type `t`) into `bytes` at `off`; addresses go to `ptrs`.
fn fill(g: var codegen.Gen, bytes: var [int], ptrs: var [(int, llvm.Value)], real: bool, off: int, t: mir.MTy, e: mir.Ex): ()! uses ffi {
  match e.k {
    Int(n) => {
      let sz = codegen.lay(&g, t).size
      for k in 0..min(sz, 8) { bytes[off + k] = (n >> (8 * k)) & 255 }
    }
    Zero => {}
    Float(x) => {
      let sz = codegen.lay(&g, t).size
      let bits = float_bits(x, sz == 4)
      for k in 0..sz { bytes[off + k] = (bits >> (8 * k)) & 255 }
    }
    Cast(x) => fill(&g, &bytes, &ptrs, real, off, t, x)?
    GlobalAddr(x) => ptrs.push((off, if real { g.globals[x] } else { llvm.values.const_null(g.t_ptr) }))
    FnAddr(Fn(f)) => ptrs.push((off, if real { g.funcs[f].0 } else { llvm.values.const_null(g.t_ptr) }))
    Agg(ms) => for (s, v) in ms {
      let at = off + codegen.offset(&g, t, s)
      let mt = mir.types.member_ty(g.lay.info, t, s, g.prog.aggs)
      fill(&g, &bytes, &ptrs, real, at, mt, v)?
    }
    _ => return fail("an initializer of a raw global isn't constant")
  }
}

/// The IEEE bits of `x` as a double, or as a float when `f32` (rounded to nearest even;
/// subnormal floats become zero).
fn float_bits(x: float, f32: bool): int uses ffi {
  let p = ffi.alloc(8)
  ffi.write_f64(p, 0, x)
  let b = ffi.read_i64(p, 0)
  ffi.free(p)
  if !f32 { return b }
  let sign = (b >> 63) & 1
  let exp = (b >> 52) & 0x7ff
  let man = b & ((1 << 52) - 1)
  if exp == 0x7ff { return (sign << 31) | (0xff << 23) | (if man != 0 { 1 << 22 } else { 0 }) }
  var e32 = exp - 1023 + 127
  if exp == 0 || e32 <= 0 { return sign << 31 }
  var m = man >> 29
  let rest = man & ((1 << 29) - 1)
  let half = 1 << 28
  if rest > half || (rest == half && (m & 1) == 1) {
    m += 1
    if m == 1 << 23 {
      m = 0
      e32 += 1
    }
  }
  if e32 >= 0xff { return (sign << 31) | (0xff << 23) }
  (sign << 31) | (e32 << 23) | m
}

/// Does the body call `raw.setjmp` (so its function is compiled `optnone`)?
pub fn calls_setjmp(ss: [mir.Stmt]): bool {
  for s in ss {
    let hit = match s {
      Let(_, e) | Do(e) | Ret(some(e)) | Set(_, e) => ex_setjmp(e)
      If(c, a, b2) => ex_setjmp(c) || calls_setjmp(a) || calls_setjmp(b2)
      Loop(a, b2) => calls_setjmp(a) || calls_setjmp(b2)
      _ => false
    }
    if hit { return true }
  }
  false
}

fn ex_setjmp(e: mir.Ex): bool = match e.k {
  Call(Rt(s), args) => s == "@raw.setjmp" || args.any(ex_setjmp)
  Call(_, args) => args.any(ex_setjmp)
  Field(x, _) | Deref(x) | Addr(x) | Un(_, x) | Cast(x) | RtField(x, _) => ex_setjmp(x)
  Bin(_, a, b) | Elem(a, b) => ex_setjmp(a) || ex_setjmp(b)
  And(xs) => xs.any(ex_setjmp)
  Cond(a, b, c) => ex_setjmp(a) || ex_setjmp(b) || ex_setjmp(c)
  Agg(ms) => ms.any(m => ex_setjmp(m.1))
  _ => false
}
