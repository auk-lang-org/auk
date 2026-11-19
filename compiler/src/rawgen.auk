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
