/// Calls to user C functions (src/mir/lower/ffi.rs): each argument is converted to its C type
/// as `cffi.Conv` says, the C function is called, then out-parameters are written back,
/// temporary C arrays freed, and the result converted to its Auk type (C strings are copied,
/// and freed with the `+free` function when they're owned).

fn d(t: types.Ty): mir.MTy = mir.MTy.D(t)

/// Work left for after the call.
enum After {
  /// Free a temporary C array.
  Free(buf: mir.Ex),
  /// Copy a C array back into the list variable at the address, then free it.
  ArrBack(p: mir.Ex, buf: mir.Ex, kind: int),
  /// Write the C value in the temporary back to the `var` at the address (of Auk type `Ty`).
  Out(p: mir.Ex, tmp: mir.Ex, c: cffi.Conv, t: types.Ty),
}

/// Rust's `Elem as i64`.
fn elem_code(e: cffi.Elem): int = match e {
  Raw => 0
  I8 => 1
  U8 => 2
  I16 => 3
  U16 => 4
  I32 => 5
  U32 => 6
  F32 => 7
}

fn int_mty(bytes: int, signed: bool): mir.MTy = match (bytes, signed) {
  (1, true) => mir.MTy.I8
  (1, false) => mir.MTy.U8
  (2, true) => mir.MTy.I16
  (2, false) => mir.MTy.U16
  (4, true) => mir.MTy.I32
  (4, false) => mir.MTy.U32
  (_, true) => mir.MTy.I64
  (_, false) => mir.MTy.U64
}

/// The machine type a value has on the C side.
fn c_mty(c: cffi.Conv): mir.MTy = match c {
  Int(bytes, signed) => int_mty(bytes, signed)
  Bool => mir.MTy.Bool
  Float(f32) => if f32 { mir.MTy.F32 } else { d(types.Ty.Float) }
  Str(_) | OptStr(_) => mir.MTy.CStr
  Unit => mir.MTy.Void
  Ptr | OptPtr | List(_, _) | Out(_) => mir.void_ptr()
}

/// Call the user C function `f`.
pub fn ffi_call(lw: var mir.lower.Lower, f: int, args: [mir.lower.ArgV], ret: types.Ty, lc: mir.Ex): mir.lower.Val {
  let (sig, convs) = match lw.tp.fns[f].kind {
    Ffi(sig, convs, _) => (sig, convs)
    _ => mir.bug("ffi_call of a non-C function")
  }
  match sig.embed {
    some(path) => return embedded(&lw, path, ret, lc)
    none => {}
  }
  if !sig.indirect && !sig.cast && !lw.g.prog.c_syms.contains(sig.name) { lw.g.prog.c_syms.push(sig.name) }
  var cs: [mir.Ex] = []
  var after: [After] = []
  for k, a in args {
    if k >= convs.len() { break }
    let conv = convs[k]
    let c = match (a, conv) {
      (Addr(p, ty), List(elem, true)) => {
        let arr = p.deref(d(ty))
        let buf = lw.f.b.decl_as(
          mir.void_ptr(),
          mir.rt("auk_ffi_arr_in", [arr, mir.int_as(elem_code(elem), mir.MTy.I32)], mir.void_ptr()),
        )
        after.push(After.ArrBack(p, buf, elem_code(elem)))
        buf
      }
      (Addr(p, ty), Out(inner)) => {
        let init = match inner {
          OptStr(_) => mir.zero(mir.MTy.CStr)
          _ => {
            let cur = mir.lower.plain(p.deref(d(ty)), ty)
            ffi_in(&lw, cur, inner)
          }
        }
        let tmp = lw.f.b.decl_as(c_mty(inner), init)
        after.push(After.Out(p, tmp, inner, ty))
        tmp.addr().cast(mir.void_ptr())
      }
      (Addr(p, ty), conv) => {
        // not reached: a `var` parameter is always an out-parameter or a list
        let cur = mir.lower.plain(p.deref(d(ty)), ty)
        ffi_in(&lw, cur, conv)
      }
      (Val(v), List(elem, _)) => {
        let x = lw.val_as(v, v.ty)
        let buf = lw.f.b.decl_as(
          mir.void_ptr(),
          mir.rt("auk_ffi_arr_in", [x, mir.int_as(elem_code(elem), mir.MTy.I32)], mir.void_ptr()),
        )
        after.push(After.Free(buf))
        buf
      }
      (Val(_), Out(inner)) => {
        // a function value can't have `var` parameters; pass a scratch slot
        let tmp = lw.f.b.decl_as(c_mty(inner), mir.zero(c_mty(inner)))
        tmp.addr().cast(mir.void_ptr())
      }
      (Val(v), conv) => ffi_in(&lw, v, conv)
    }
    cs.push(c)
  }
  let rconv = convs.last()!
  var call = mir.unit()
  if sig.cast {
    // no call: the same address, typed as the result
    call = cs[0].cast(c_mty(rconv))
  } else if sig.indirect {
    let code = cs[0]
    call = mir.ex(mir.K.Call(mir.Callee.CPtr(code), cs.skip(1)), c_mty(rconv))
  } else {
    call = mir.rt(sig.name, cs, c_mty(rconv))
  }
  var raw: mir.Ex? = none
  if rconv == cffi.Conv.Unit {
    lw.do_(call)
  } else {
    raw = some(lw.f.b.decl_as(c_mty(rconv), call))
  }
  // the result first (a C string is copied before anything can free it)
  let out = match raw {
    none => none
    some(r) => some(ffi_out(&lw, r, rconv, ret, sig.name, sig.free, lc))
  }
  for a in after {
    match a {
      Free(buf) => lw.do_(mir.rt("auk_ffi_free", [buf], mir.MTy.Void))
      ArrBack(p, buf, kind) =>
        lw.do_(mir.rt("auk_ffi_arr_out", [p.cast(mir.void_ptr()), buf, mir.int_as(kind, mir.MTy.I32)], mir.MTy.Void))
      Out(p, tmp, inner, ty) => {
        let place = p.deref(d(ty))
        let v = ffi_out_ex(&lw, tmp, inner, ty, sig.name, sig.free, lc)
        let n = lw.decl(ty, v)
        match lw.g.release(ty, place) {
          some(r) => lw.emit(r)
          none => {}
        }
        lw.set(place, n)
      }
    }
  }
  match out {
    none => if ret == types.Ty.Never { mir.lower.val_never() } else { mir.lower.val_unit() }
    some(v) => v
  }
}

/// `"#embed path"`: the file (checked readable) as constant data in the program, as its
/// address, its length, or a new `[int]`/`str` of its bytes.
fn embedded(lw: var mir.lower.Lower, path: str, ret: types.Ty, lc: mir.Ex): mir.lower.Val {
  let bytes = match lw.g.embeds.get(path) {
    some(b) => b
    none => []
  }
  let n = mir.int_(bytes.len())
  let data = mir.ex(mir.K.CStr(bytes), mir.MTy.CStr)
  let e = match ret {
    Int => n
    Str => mir.rt("auk_str_from_bytes", [data, n], d(types.Ty.Str))
    List(_) => mir.rt("auk_ffi_bytes", [data.cast(mir.void_ptr()), n, lc], d(ret))
    _ => data.cast(d(ret))
  }
  lw.tmp(ret, e)
}

/// An Auk value as its C argument.
fn ffi_in(lw: var mir.lower.Lower, v: mir.lower.Val, conv: cffi.Conv): mir.Ex {
  let ty = v.ty
  let x = lw.val_as(v, ty)
  match conv {
    Int(_, _) | Bool | Float(_) => x.cast(c_mty(conv))
    Str(_) => mir.rt("auk_str_cstr", [x], mir.MTy.CStr)
    OptStr(_) => {
      let o = lw.lvalue(v, ty)
      let s = mir.rt("auk_str_cstr", [lw.fld(o, mir.Sel.F(1))], mir.MTy.CStr)
      mir.cond(lw.fld(o, mir.Sel.F(0)), s, mir.zero(mir.MTy.CStr))
    }
    Ptr => x.cast(mir.void_ptr())
    OptPtr => {
      let o = lw.lvalue(v, ty)
      mir.cond(lw.fld(o, mir.Sel.F(0)), lw.fld(o, mir.Sel.F(1)).cast(mir.void_ptr()), mir.zero(mir.void_ptr()))
    }
    _ => mir.zero(mir.void_ptr())
  }
}

/// The C value in variable `r` as an Auk value of type `ty` (an owned temporary).
fn ffi_out(lw: var mir.lower.Lower, r: mir.Ex, conv: cffi.Conv, ty: types.Ty, name: str, free: str?, lc: mir.Ex): mir.lower.Val {
  let e = ffi_out_ex(&lw, r, conv, ty, name, free, lc)
  lw.tmp(ty, e)
}

fn nonnull(r: mir.Ex): mir.Ex = mir.bin(mir.BOp.Ne, r.cast(mir.void_ptr()), mir.zero(mir.void_ptr()))

/// The C value in variable `r` converted to Auk type `ty` (owned). An owned C string is freed
/// here, after its copy.
fn ffi_out_ex(lw: var mir.lower.Lower, r: mir.Ex, conv: cffi.Conv, ty: types.Ty, name: str, free: str?, lc: mir.Ex): mir.Ex {
  let e = match conv {
    Int(_, _) | Bool | Float(_) | Ptr => return r.cast(d(ty))
    OptPtr => {
      let inner = match ty {
        Opt(i) => i
        _ => mir.bug("ffi: OptPtr of a non-optional")
      }
      return mir.agg(d(ty), [(mir.Sel.F(0), nonnull(r).cast(mir.MTy.Bool)), (mir.Sel.F(1), r.cast(d(inner)))])
    }
    Str(_) => mir.rt("auk_ffi_str", [r, mir.cstr(name), lc], d(types.Ty.Str))
    OptStr(_) => {
      let s = mir.rt("auk_ffi_str_or_null", [r], d(types.Ty.Str))
      mir.agg(d(ty), [(mir.Sel.F(0), nonnull(r).cast(mir.MTy.Bool)), (mir.Sel.F(1), s)])
    }
    _ => return mir.zero(d(ty))
  }
  let v = lw.decl(ty, e)
  let owned = match conv {
    Str(o) | OptStr(o) => o
    _ => false
  }
  match free {
    some(f) => if owned {
      lw.open_if(nonnull(r))
      lw.emit(mir.Stmt.Do(mir.rt(f, [r.cast(mir.void_ptr())], mir.MTy.Void)))
      lw.close()
    }
    none => {}
  }
  v
}
