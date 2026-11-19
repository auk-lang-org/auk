/// The runtime's dialect (docs/lowlevel.md): fixed-width arithmetic and conversions, the `raw`
/// module's intrinsics, raw globals. Nothing here is reference counted: the checker allows
/// only types without references in `uses raw` code (E0419).

fn d(t: types.Ty): mir.MTy = mir.MTy.D(t)

/// Is the body being lowered a `uses raw` function?
pub fn raw_fn(lw: var mir.lower.Lower): bool = match lw.tp.instances[lw.inst].body {
  Fn(f) => lw.tp.fns[f].effects.contains("raw")
  _ => false
}

/// A number literal of a fixed-width type.
pub fn fixed_lit(l: ast.Lit, neg: bool, ty: types.Ty): mir.lower.Val = match l {
  Int(n) => mir.lower.plain(mir.int_as(if neg { 0 -% n } else { n }, d(ty)), ty)
  Float(x) => mir.lower.plain(mir.ex(mir.K.Float(if neg { -x } else { x }), d(types.Ty.Float)).cast(d(ty)), ty)
  _ => mir.lower.plain(mir.zero(d(ty)), ty)
}

/// `a op b` on a fixed-width type: integers wrap, division by zero traps.
pub fn fixed_bin(lw: var mir.lower.Lower, op: ast.BinOp, a: mir.Ex, b: mir.Ex, ty: types.Ty): mir.Ex {
  let float = ty == types.Ty.Fixed(types.Fx.F32)
  let bop = match op {
    Add | AddWrap => mir.BOp.Add
    Sub | SubWrap => mir.BOp.Sub
    Mul | MulWrap => mir.BOp.Mul
    Div => mir.BOp.Div
    Rem => mir.BOp.Rem
    BitAnd => mir.BOp.BitAnd
    BitOr => mir.BOp.BitOr
    BitXor => mir.BOp.BitXor
    Shl => mir.BOp.Shl
    _ => mir.BOp.Shr
  }
  if !float && (bop == mir.BOp.Div || bop == mir.BOp.Rem) {
    let bv = if mir.is_simple(b) { b } else { lw.bdecl(b) }
    lw.open_if(mir.bin(mir.BOp.Eq, bv, mir.zero(d(ty))))
    lw.emit(mir.Stmt.Unreachable)
    lw.close()
    return mir.ex(mir.K.Bin(bop, a, bv), d(ty))
  }
  mir.ex(mir.K.Bin(bop, a, b), d(ty))
}

/// `-x` and `~x` on a fixed-width type.
pub fn fixed_un(op: mir.UOp, a: mir.Ex, ty: types.Ty): mir.Ex = mir.ex(mir.K.Un(op, a), d(ty))

/// A node with a `typed.RawNode` (a conversion, ...).
pub fn raw_node(lw: var mir.lower.Lower, e: ast.Expr, n: typed.RawNode): mir.lower.Val {
  match n {
    Conv(to) => {
      let x = match e.kind {
        Call(_, args) => args[0]
        _ => return mir.lower.val_never()
      }
      let v = lw.expr(x)
      if v.is_never() { return v }
      let from = v.ty
      let c = if to == types.Ty.Bool {
        mir.bin(mir.BOp.Ne, v.c, mir.zero(d(from)))
      } else {
        v.c.cast(d(to))
      }
      lw.tmp(to, c)
    }
  }
}
