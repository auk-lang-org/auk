/// The runtime's dialect (docs/lowlevel.md): fixed-width arithmetic and conversions, the `raw`
/// module's intrinsics, raw globals. Nothing here is reference counted: the checker allows
/// only types without references in `uses raw` code (E0419).

fn d(t: types.Ty): mir.MTy = mir.MTy.D(t)

/// Is the call at `node` one of core's `raw` intrinsics?
pub fn is_raw_call(lw: var mir.lower.Lower, node: int): bool = match lw.tp.instances[lw.inst].resolved.get(node) {
  some(Intrinsic(Raw(_), _)) => true
  _ => false
}

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

/// Sizes and offsets of types (the C layout rules; the same on every supported target).
fn layouts(lw: var mir.lower.Lower): mir.layout.Layouts = mir.layout.new(lw.g.info, lw.g.prog.aggs, "aarch64")

fn usize_ty(): types.Ty = types.Ty.Fixed(types.Fx.Usize)

/// The address of element `i` of the array of `t` at `p` (no pointer arithmetic in LLVM's
/// integers: the back end makes it a byte-offset GEP).
pub fn offset_ptr(p: mir.Ex, i: mir.Ex, t: types.Ty): mir.Ex {
  let bytes = mir.bin(mir.BOp.Mul, i.cast(mir.MTy.I64), mir.size_of(d(t)).cast(mir.MTy.I64))
  mir.ex(mir.K.Bin(mir.BOp.Add, p, bytes), p.ty)
}

/// Field `i` of the raw struct at `p` (a place).
fn field_place(lw: var mir.lower.Lower, p: mir.Ex, st: types.Ty, i: int): mir.Ex {
  let ft = mir.types.member_ty(lw.g.info, d(st), mir.Sel.F(i), lw.g.prog.aggs)
  p.deref(d(st)).field(mir.Sel.F(i), ft)
}

/// `p.f` through a pointer: the field's value, or the address of an array field's first element.
pub fn ptr_field(lw: var mir.lower.Lower, p: mir.Ex, pt: types.Ty, name: str, ft: types.Ty): mir.lower.Val {
  let (place, fty) = ptr_field_place(&lw, p, pt, name)
  match fty {
    Array(_, _) => lw.tmp(ft, place.addr().cast(d(ft)))
    _ => lw.tmp(ft, place)
  }
}

/// The place of field `name` of the raw struct `p` (a `raw.Ptr`) points at, and its type.
pub fn ptr_field_place(lw: var mir.lower.Lower, p: mir.Ex, pt: types.Ty, name: str): (mir.Ex, types.Ty) {
  let st = match pt {
    Ptr(x) => x
    _ => mir.bug("ptr_field of {lw.g.show_ty(pt)}")
  }
  let (dd, args) = match st {
    Named(dd, args) => (dd, args)
    _ => mir.bug("ptr_field of {lw.g.show_ty(pt)}")
  }
  let fields = types.fields(lw.tp.defs, dd)
  let i = fields.find_index(f => f.name == name) else mir.bug("no field {name}")
  let fty = types.subst(fields[i].ty, types.subst_of(lw.tp.defs, dd, args))
  (field_place(&lw, p, st, i), fty)
}

/// `p.at(i)` as a place.
pub fn at_place(lw: var mir.lower.Lower, e: ast.Expr): (mir.Ex, types.Ty) {
  let (recv, i) = match e.kind {
    MethodCall(r, _, args) => (r, args[0])
    _ => mir.bug("at_place")
  }
  let t = lw.ty(e.id)
  let p = lw.expr(recv)
  let iv = lw.expr(i)
  (offset_ptr(p.c, iv.c, t).deref(d(t)), t)
}

/// The LLVM memory order of a `raw.Order` constant (monotonic, acquire, release, acq_rel,
/// seq_cst).
fn llvm_order(lw: var mir.lower.Lower, node: int): int = match check_raw.order_index(lw.t, node) {
  some(0) => 2
  some(1) => 4
  some(2) => 5
  some(3) => 6
  _ => 7
}

/// A call to an intrinsic of core's `raw` module (`@raw_<name>`), its arguments evaluated.
pub fn intrinsic(lw: var mir.lower.Lower, e: ast.Expr, name: str, targs: [types.Ty], args: [mir.lower.ArgV], ret: types.Ty): mir.lower.Val {
  let xs = args.map(a => match a {
    Val(v) => v.c
    Addr(p, _) => p
  })
  let t0 = targs.get(0) else types.unit()
  let rmt = d(ret)
  let call = lw.t.calls.get(e.id)
  let order = (k: int) => match call {
    some(c) => match c.args.get(k) {
      some(a) => a.node
      none => -1
    }
    none => -1
  }
  let unit = mir.lower.val_unit()
  match name {
    "load" => lw.tmp(ret, xs[0].deref(d(t0)))
    "store" => {
      lw.set(xs[0].deref(d(t0)), xs[1])
      unit
    }
    "at" => lw.tmp(ret, offset_ptr(xs[0], xs[1], t0).deref(d(t0)))
    "offset" => lw.tmp(ret, offset_ptr(xs[0], xs[1], t0))
    "ptr_int" => lw.tmp(ret, xs[0].cast(rmt))
    "is_null" => lw.tmp(ret, mir.bin(mir.BOp.Eq, xs[0], mir.zero(xs[0].ty)))
    "addr_of" | "cast" | "from_int" => lw.tmp(ret, xs[0].cast(rmt))
    "null" => mir.lower.plain(mir.zero(rmt), ret)
    "size_of" | "align_of" => {
      var l = layouts(&lw)
      let x = mir.layout.lay(&l, d(t0))
      mir.lower.plain(mir.int_as(if name == "size_of" { x.size } else { x.align }, rmt), ret)
    }
    "copy" | "move" => {
      let sym = if name == "copy" { "@raw.memcpy" } else { "@raw.memmove" }
      lw.do_(mir.rt(sym, [xs[0], xs[1], xs[2].cast(mir.MTy.I64)], mir.MTy.Void))
      unit
    }
    "fill" => {
      lw.do_(mir.rt("@raw.memset", [xs[0], xs[1], xs[2].cast(mir.MTy.I64)], mir.MTy.Void))
      unit
    }
    "compare" => lw.tmp(ret, mir.rt("memcmp", [xs[0], xs[1], xs[2].cast(mir.MTy.U64)], rmt))
    "alloc" => xalloc(&lw, "malloc", [xs[0].cast(mir.MTy.U64)], xs[0], ret)
    "realloc" => xalloc(&lw, "realloc", [xs[0], xs[1].cast(mir.MTy.U64)], xs[1], ret)
    "free" => {
      lw.do_(mir.rt("free", [xs[0]], mir.MTy.Void))
      unit
    }
    "unreachable" => {
      lw.do_(mir.rt("@raw.unreachable", [], mir.MTy.Void))
      mir.lower.val_never()
    }
    "trap" => {
      lw.emit(mir.Stmt.Unreachable)
      mir.lower.val_never()
    }
    "likely" => lw.tmp(ret, mir.rt("@raw.likely", [xs[0]], rmt))
    "atomic_load" => lw.tmp(ret, mir.rt("@raw.atomic_load.{lw.llvm_order(order(1))}", [xs[0]], rmt))
    "atomic_store" => {
      lw.do_(mir.rt("@raw.atomic_store.{lw.llvm_order(order(2))}", [xs[0], xs[1]], mir.MTy.Void))
      unit
    }
    "atomic_swap" | "atomic_add" | "atomic_sub" | "atomic_and" | "atomic_or" =>
      lw.tmp(ret, mir.rt("@raw.{name}.{lw.llvm_order(order(2))}", [xs[0], xs[1]], rmt))
    "atomic_cas" => {
      let sym = "@raw.atomic_cas.{lw.llvm_order(order(3))}.{lw.llvm_order(order(4))}"
      lw.tmp(ret, mir.rt(sym, [xs[0], xs[1], xs[2]], rmt))
    }
    "fence" => {
      lw.do_(mir.rt("@raw.fence.{lw.llvm_order(order(0))}", [], mir.MTy.Void))
      unit
    }
    "setjmp" => lw.tmp(ret, mir.rt("@raw.setjmp", [xs[0]], rmt))
    "longjmp" => {
      lw.do_(mir.rt("@raw.longjmp", [xs[0]], mir.MTy.Void))
      lw.emit(mir.Stmt.Unreachable)
      mir.lower.val_never()
    }
    _ => mir.bug("unknown raw intrinsic `{name}`")
  }
}

/// `malloc`/`realloc` that abort when out of memory (as the runtime's `auk__xmalloc`).
fn xalloc(lw: var mir.lower.Lower, f: str, args: [mir.Ex], n: mir.Ex, ret: types.Ty): mir.lower.Val {
  let p = lw.bdecl(mir.rt(f, args, d(ret)))
  let failed = mir.and([mir.bin(mir.BOp.Eq, p, mir.zero(p.ty)), mir.bin(mir.BOp.Ne, n, mir.zero(n.ty))])
  lw.open_if(failed)
  lw.do_(mir.rt("abort", [], mir.MTy.Void))
  lw.emit(mir.Stmt.Unreachable)
  lw.close()
  mir.lower.plain(p, ret)
}

/// A node with a `typed.RawNode` (a conversion, ...).
pub fn raw_node(lw: var mir.lower.Lower, e: ast.Expr, n: typed.RawNode): mir.lower.Val {
  let ret = lw.ty(e.id)
  match n {
    Field(dd, i) => {
      let args = match e.kind {
        MethodCall(_, _, args) => args
        Call(_, args) => args
        TypeArgs(x, _) => match x.kind {
          MethodCall(_, _, args) => args
          _ => []
        }
        _ => []
      }
      if args.len() == 2 {
        // `raw.field_addr(p, .f)`
        let p = lw.expr(args[0])
        let st = match p.ty {
          Ptr(x) => x
          _ => types.Ty.Named(dd, [])
        }
        let place = field_place(&lw, p.c, st, i)
        lw.tmp(ret, place.addr().cast(d(ret)))
      } else {
        // `raw.offset_of<T>(.f)`
        let st = match lw.t.calls.get(e.id) {
          some(c) => match c.callee {
            Fn(_, targs) => lw.sub(targs[0])
            _ => types.Ty.Named(dd, [])
          }
          none => types.Ty.Named(dd, [])
        }
        var l = layouts(&lw)
        let off = mir.layout.offset(&l, d(st), mir.Sel.F(i))
        mir.lower.plain(mir.int_as(off, d(ret)), ret)
      }
    }
    FnOf => {
      let x = match e.kind {
        MethodCall(_, _, args) => args[0]
        Call(_, args) => args[0]
        _ => return mir.lower.val_never()
      }
      let f = match lw.tp.instances[lw.inst].resolved.get(x.id) {
        some(Instance(i)) => lw.g.inst_fn(i)
        _ => mir.bug("raw.fn_of: unresolved function")
      }
      mir.lower.plain(mir.fn_addr(f).cast(d(ret)), ret)
    }
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
