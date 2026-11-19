/// Expressions, second half (src/check/expr.rs from `place` to the end): places, operators,
/// indexing, interpolation, `?`, `?.`, `else`, `await`, `catch`, closures, blocks, `if`,
/// `match`, loops, `let`, assignment and struct literals, then `parse_format`.
///
/// Every `impl Checker` method is a function taking `c: var check.Checker` (see check.auk);
/// methods of the first half (check_expr.auk) are reached as `c.f(..)` through check.auk's
/// forwarding functions. Rust's `if let` chains are nested `match`es; Rust's
/// `HashMap<String, Span>` of bound names is a `{str: diag.Span}`.

pub fn place(c: var check.Checker, e: ast.Expr, mutate: bool, use_: check.PlaceUse): types.Ty {
  match e.kind {
    Name(n) => {
      if c.lookup_local(n) == none && c.prog.raw_ok(c.cur_module()) {
        match check_raw.global_place(&c, e, n, mutate) {
          some(t) => return t
          none => {}
        }
      }
      let l = c.lookup_local(n) else {
        let what = match use_ {
          Assign => "assign to"
          _ => "change"
        }
        let m = c.cur_module()
        if c.items[m].consts.contains(n) {
          c.err(
            diag.new("E0320", e.span, "can't {what} `{n}`: it is a module constant")
              .note("constants never change; use a `var` inside a function"),
          )
        } else {
          let _ = c.unknown_name(e.span, n, false)
        }
        return types.Ty.Error
      }
      c.cx.t.names[e.id] = typed.NameRef.Local(l)
      let t = c.local_ty(l)
      c.record(e.id, t)
      if mutate {
        let m = c.cur_module()
        if !c.tables[m].locals[l].mutable {
          let msg = match use_ {
            Assign => "can't assign to `{n}`: it isn't mutable"
            Ref => "can't pass `&{n}`: `{n}` isn't mutable"
            Receiver(f) => "`{f}` changes its first argument, but `{n}` isn't mutable"
          }
          var d = diag.new("E0320", e.span, msg)
          match c.local_fix(l) {
            some((span, text, what)) => d = d.note("declare it with `var` to change it ({what})").fix(span, text)
            none => d = d.note("only `var` locals and `var` parameters can change; copy it into a `var` first")
          }
          c.err(d)
        } else if c.is_captured(l) {
          c.err(
            diag.new("E0323", e.span, "a closure can't change `{n}`, a variable it captures")
              .note("closures capture by value, so the change would be lost; use a `for` loop, or `reduce` to build the result"),
          )
        }
      }
      t
    }
    Field(x, name) when c.prog.raw_ok(c.cur_module()) => {
      // the runtime's dialect: a field through a `raw.Ptr` needn't be a mutable place
      let bt = c.place(x, false, use_)
      if mutate && !(c.shallow(bt) is types.Ty.Ptr(_)) { let _ = c.place(x, true, use_) }
      let t = c.field_of(e, x, bt, name)
      c.record(e.id, t)
      t
    }
    MethodCall(_, name, _) when name.name == "at" && c.prog.raw_ok(c.cur_module()) => {
      // `p.at(i) = v`: element `i` of the array at `p`
      let t = c.infer(e, none)
      let is_at = match c.cx.t.calls.get(e.id) {
        some(call) => match call.callee {
          Fn(f, _) => c.fns[f].kind is typed.FnKind.Intrinsic(typed.Intrinsic.Raw("at"), _)
          _ => false
        }
        none => false
      }
      if mutate && !is_at && !t.has_error() {
        c.err(diag.new("E0027", e.span, "this expression can't be changed"))
      }
      t
    }
    Field(x, name) => {
      let bt = c.place(x, mutate, use_)
      let t = c.field_of(e, x, bt, name)
      c.record(e.id, t)
      t
    }
    TupleField(x, index) => {
      let bt = c.place(x, mutate, use_)
      let t = match c.shallow(bt) {
        Tuple(ts) when index < ts.len() => ts[index]
        Error => types.Ty.Error
        _ => {
          c.err(diag.new("E0223", e.span, "`.{index}` needs a tuple, found `{c.show(bt)}`"))
          types.Ty.Error
        }
      }
      c.record(e.id, t)
      t
    }
    Index(x, index) => {
      let bt = c.place(x, mutate, use_)
      let t = match c.shallow(bt) {
        List(t1) => {
          let _ = c.check(index, types.Ty.Int)
          t1
        }
        Map(k, v) => {
          let _ = c.check(index, k)
          v
        }
        Str => {
          let _ = c.check(index, types.Ty.Int)
          c.err(
            diag.new("E0322", e.span, "strings are immutable: `s[i]` can't be assigned")
              .note("build a new string, e.g. with `s.chars()` and `str(cs)`"),
          )
          types.Ty.Char
        }
        Error => types.Ty.Error
        _ => {
          c.err(diag.new("E0270", e.span, "can't index a `{c.show(bt)}`"))
          types.Ty.Error
        }
      }
      c.record(e.id, t)
      t
    }
    _ => {
      if mutate {
        c.err(
          diag.new("E0027", e.span, "this expression can't be changed")
            .note("only variables, fields and indexes (like `a.b[i]`) can be assigned or passed with `&`"),
        )
      }
      c.infer(e, none)
    }
  }
}

/// How to make local `l` mutable: (span, replacement, description).
pub fn local_fix(c: check.Checker, l: int): (diag.Span, str, str)? {
  let m = c.cur_module()
  match c.let_fixes.get((m, l)) {
    some(s) => return (s, "var", "`let` makes an immutable binding")
    none => {}
  }
  match c.param_fixes.get((m, l)) {
    some(s) => return (s, "var ", "parameters are immutable unless declared `var`, and then the caller passes `&x`")
    none => {}
  }
  none
}

// ---- operators ----

pub fn unary(c: var check.Checker, e: ast.Expr, op: ast.UnOp, x: ast.Expr, exp: check.Exp): types.Ty {
  match op {
    Not => {
      let _ = c.check(x, types.Ty.Bool)
      types.Ty.Bool
    }
    BitNot => {
      let t = c.infer(x, raw_hint(c, exp, types.Ty.Int))
      if c.bit_operand(x, t, "~", true) { int_or_fixed(c, t) } else { types.Ty.Error }
    }
    Neg => {
      var t = types.Ty.Error
      var done = false
      match check_expr.raw_lit(&c, x, match x.kind {
        Lit(l) => l
        _ => ast.Lit.Bool(false)
      }, true, check.exp_ty(exp)) {
        some(rt) => {
          t = rt
          c.record(x.id, t)
          done = true
        }
        none => {}
      }
      if !done { match x.kind {
        Lit(l) => match l {
          Int(_) | Float(_) => {
            t = c.lit(x, l, true)
            c.record(x.id, t)
            done = true
          }
          _ => {}
        }
        _ => {}
      } }
      if !done { t = c.infer(x, check.exp_ty(exp)) }
      match c.shallow(t) {
        Int | Float | Measured(_, _) | Error | Fixed(_) => t
        Var(_) => c.cant_infer(x.span, "the negated value")
        _ => {
          c.err(diag.new("E0260", e.span, "can't negate a `{c.show(t)}`").note("`-x` works on `int` and `float`"))
          types.Ty.Error
        }
      }
    }
  }
}

pub fn binary(c: var check.Checker, e: ast.Expr, op: ast.BinOp, l: ast.Expr, r: ast.Expr, exp: check.Exp): types.Ty {
  match op {
    And | Or => {
      let _ = c.check(l, types.Ty.Bool)
      let _ = c.check(r, types.Ty.Bool)
      types.Ty.Bool
    }
    Eq | Ne | Lt | Le | Gt | Ge => {
      let lt = c.infer(l, none)
      if !c.number_compare(e, op, l, r, lt) {
        let _ = c.check(r, lt)
      }
      let shape = match op {
        Eq | Ne => c.b.eq
        _ => c.b.ord
      }
      c.compare(e, op, lt, shape, l, r)
      types.Ty.Bool
    }
    BitAnd | BitOr | BitXor | Shl | Shr => {
      // one error is enough: `x | true` on a bool reports the left side only
      let lt = c.infer(l, raw_hint(c, exp, types.Ty.Int))
      let ok = c.bit_operand(l, lt, op.symbol(), true)
      if types.is_fixed_int(c.shallow(lt)) {
        // the runtime's dialect: both sides of the same fixed-width type
        let rt = c.infer(r, lt)
        if ok { c.operand_with(r, lt, rt, op, l) }
        return lt
      }
      let rt = c.infer(r, types.Ty.Int)
      if types.is_fixed_int(c.shallow(rt)) && num_lit(l) {
        // the runtime's dialect: `1 << n` as `n << 1` would type it: the literal takes `n`'s type
        let lt2 = c.infer(l, rt)
        c.operand_with(r, lt2, rt, op, l)
        return rt
      }
      if ok && c.bit_operand(r, rt, op.symbol(), true) { types.Ty.Int } else { types.Ty.Error }
    }
    _ => c.arith(e, op, l, r, exp)
  }
}

/// An operand of `& | ^ << >> ~` (already inferred as `t`): a plain `int`. A unit is
/// E0293 (with an `int(x)` fix when `fix`), anything else E0260. False after an error.
/// The expected type when it is a fixed-width number (the runtime's dialect), else `dflt`.
fn raw_hint(c: check.Checker, exp: check.Exp, dflt: types.Ty): types.Ty = match check.exp_ty(exp) {
  some(t) => if c.shallow(t) is types.Ty.Fixed(_) { t } else { dflt }
  none => dflt
}

fn int_or_fixed(c: check.Checker, t: types.Ty): types.Ty =
  if types.is_fixed_int(c.shallow(t)) { t } else { types.Ty.Int }

pub fn bit_operand(c: var check.Checker, x: ast.Expr, t: types.Ty, op: str, fix: bool): bool {
  match c.shallow(t) {
    Int | Never => true
    Fixed(k) when k != types.Fx.F32 => true
    Error => false
    Var(_) => {
      if c.unify(t, types.Ty.Int) { return true }
      let _ = c.cant_infer(x.span, "the operand of `{op}`")
      false
    }
    Measured(b, _) => {
      let ts = c.show(t)
      var d = diag.new("E0293", x.span, "`{op}` works on bits, but this is `{ts}`, a value with a unit")
        .note("bitwise operators take a plain `int`; a unit of measure has no meaning for single bits")
      if b == types.Ty.Int && fix {
        d = d
          .note("strip the unit with `int(x)` first")
          .fix(diag.Span { end_line: x.span.line, end_col: x.span.col, ..x.span }, "int(")
          .fix(x.span.after(), ")")
      }
      c.err(d)
      false
    }
    _ => {
      let ts = c.show(t)
      var d = diag.new("E0260", x.span, "can't apply `{op}` to `{ts}`").note("bitwise operators work on `int` only")
      // Rust's `op.trim_end_matches('=')`
      var o = op
      while o.ends_with("=") { o = o.strip_suffix("=") else o }
      let logical: str? = match o {
        "&" => "&&"
        "|" => "||"
        "^" => "!="
        "~" => "!"
        _ => none
      }
      if c.shallow(t) == types.Ty.Bool {
        match logical {
          some(l) => d = d.note("for booleans use `{l}`")
          none => {}
        }
      }
      c.err(d)
      false
    }
  }
}

/// `==`/`<` on `t`: built in for primitives, otherwise a user `eq`/`cmp` or the shape.
pub fn compare(c: var check.Checker, e: ast.Expr, op: ast.BinOp, t: types.Ty, shape: int, l: ast.Expr, r_: ast.Expr) {
  let args = [typed.Arg { node: l.id, by_ref: false }, typed.Arg { node: r_.id, by_ref: false }]
  let r = c.resolve(t)
  let ord = shape == c.b.ord
  if check_expr.is_prim(r) || r.has_error() || r == types.Ty.Never || types.is_raw_scalar(r) { return }
  if r.has_vars() {
    let _ = c.cant_infer(e.span, "the operands of `{op.symbol()}`")
    return
  }
  let meth = if ord { "cmp" } else { "eq" }
  let generic = match r {
    Param(_) | Any(_) => true
    _ => false
  }
  if !generic {
    var cands: [int] = []
    for f in c.method_cands(meth, r, 2) {
      if !(c.fns[f].params[0].ty is types.Ty.Param(_)) { cands.push(f) }
    }
    if cands.len() > 0 {
      let f = cands[0]
      let (s, targs) = c.instantiate(f)
      let p0 = c.fns[f].params[0].ty.subst(s)
      let p1 = c.fns[f].params[1].ty.subst(s)
      let _ = c.unify(p0, r)
      let _ = c.unify(p1, r)
      c.note_call(e.id, typed.Call { callee: typed.Callee.Fn(f, targs), args })
      return
    }
  }
  let why = if ord {
    "to compare with `{op.symbol()}` (it needs `Ord`; define `fn cmp(a: T, b: T): int`)"
  } else {
    "to compare with `{op.symbol()}`"
  }
  c.defer_fit(r, shape, e.span, why)
  c.note_call(e.id, typed.Call { callee: typed.Callee.Shape(shape, 0, r), args })
}

fn is_int_float(t: types.Ty): bool = match t {
  Int | Float => true
  _ => false
}

pub fn arith(c: var check.Checker, e: ast.Expr, op: ast.BinOp, l: ast.Expr, r: ast.Expr, exp: check.Exp): types.Ty {
  // `*` `/` `**` change units, so the expected type's unit says nothing about an operand
  let scale = match op {
    Mul | Div | MulWrap | Pow => true
    _ => false
  }
  let hint: types.Ty? = if scale {
    match check.exp_ty(exp) {
      some(t) => types.erase_units(c.resolve(t))
      none => none
    }
  } else {
    check.exp_ty(exp)
  }
  let lt = c.infer(l, hint)
  let ls = c.shallow(lt)
  match ls {
    Measured(b, _) => {
      let unit_op = match op {
        Add | Sub | Mul | Div | Rem | Pow => true
        AddWrap | SubWrap | MulWrap => b == types.Ty.Int
        _ => false
      }
      if unit_op {
        let rhint = if scale { b } else { lt }
        let rt = c.infer(r, rhint)
        return c.unit_operands(e, op, l, r, lt, rt)
      }
    }
    _ => {}
  }
  let ok_prim = match op {
    Add => match ls {
      Int | Float | Str | List(_) => true
      _ => false
    }
    Sub | Mul | Div | Rem | Pow => is_int_float(ls)
    AddWrap | SubWrap | MulWrap => ls == types.Ty.Int
    _ => false
  } || match ls {
    // the runtime's dialect: fixed-width numbers (integers wrap)
    Fixed(k) => match op {
      Add | Sub | Mul | Div | Rem => true
      AddWrap | SubWrap | MulWrap => k != types.Fx.F32
      _ => false
    }
    _ => false
  }
  if ok_prim {
    if is_int_float(ls) {
      // `2.0 * d`: a plain number scales a unit value
      let rt = c.infer(r, lt)
      if c.shallow(rt) is types.Ty.Measured(_, _) {
        return c.unit_operands(e, op, l, r, lt, rt)
      }
      // the runtime's dialect: `1 + x` with `x` fixed-width: the literal takes `x`'s type, as
      // in `x + 1`
      let wrap_f32 = c.shallow(rt) == types.Ty.Fixed(types.Fx.F32) && !(op == ast.BinOp.Add || op == ast.BinOp.Sub || op == ast.BinOp.Mul || op == ast.BinOp.Div || op == ast.BinOp.Rem)
      if (c.shallow(rt) is types.Ty.Fixed(_)) && num_lit(l) && !wrap_f32 {
        let lt2 = c.infer(l, rt)
        c.operand_with(r, lt2, rt, op, l)
        return lt2
      }
      c.operand_with(r, lt, rt, op, l)
    } else {
      c.check_operand(r, lt, op, l)
    }
    return lt
  }
  let user_op = match op {
    Add | Sub | Mul | Div | Rem => true
    _ => false
  }
  match ls {
    Error => {
      let _ = c.infer(r, none)
      types.Ty.Error
    }
    Var(_) => {
      let rt = c.infer(r, none)
      if c.unify(lt, rt) {
        match c.shallow(rt) {
          Int | Float | Str | List(_) | Measured(_, _) => return rt
          _ => {}
        }
      }
      c.cant_infer(l.span, "the left side of `{op.symbol()}`")
    }
    Named(_, _) | Param(_) when user_op => {
      let fname = match op {
        Add => "add"
        Sub => "sub"
        Mul => "mul"
        Div => "div"
        _ => "mod"
      }
      let cands = c.method_cands(fname, lt, 2)
      if cands.len() > 0 {
        let f = cands[0]
        let (s, targs) = c.instantiate(f)
        let info = c.fns[f]
        let p0 = info.params[0].ty.subst(s)
        let _ = c.unify(p0, lt)
        let p1 = info.params[1].ty.subst(s)
        let _ = c.check(r, p1)
        c.note_call(
          e.id,
          typed.Call {
            callee: typed.Callee.Fn(f, targs),
            args: [typed.Arg { node: l.id, by_ref: false }, typed.Arg { node: r.id, by_ref: false }],
          },
        )
        return info.ret.subst(s)
      }
      let ts = c.show(lt)
      c.err(
        diag.new("E0261", e.span, "`{op.symbol()}` isn't defined for `{ts}`")
          .note("define `fn {fname}(a: {ts}, b: {ts}): {ts}` to give `{ts}` the `{op.symbol()}` operator"),
      )
      let _ = c.infer(r, none)
      types.Ty.Error
    }
    Task(_) => {
      let _ = c.infer(r, none)
      c.err(
        diag.new("E0333", l.span, "`{c.text(l.span)}` is an un-awaited `async fn` call, so `{op.symbol()}` can't use its value")
          .note("`await` the call to get its result")
          .fix(diag.Span { end_line: l.span.line, end_col: l.span.col, ..l.span }, "await "),
      )
      types.Ty.Error
    }
    _ => {
      let rt = c.infer(r, none)
      let lts = c.show(lt)
      let rts = c.show(rt)
      var d = diag.new("E0260", e.span, "can't apply `{op.symbol()}` to `{lts}` and `{rts}`")
      let wrap = match op {
        AddWrap | SubWrap | MulWrap => true
        _ => false
      }
      let ls2 = c.shallow(lt)
      d = if ls2 == types.Ty.Char && op == ast.BinOp.Add {
        d.note("`+` doesn't work on chars; build a string with `str(c)` or `\"{{a}}{{b}}\"`")
      } else if ls2 == types.Ty.Bool {
        d.note("arithmetic needs numbers; use `&&` / `||` for booleans")
      } else if wrap {
        d.note("wrapping arithmetic is only for `int`")
      } else {
        d.note("arithmetic works on `int` and `float` (both sides the same type); `+` also joins `str` and lists")
      }
      c.err(d)
      types.Ty.Error
    }
  }
}

/// The right operand of a primitive arithmetic operator: same type as the left.
/// A number literal (`1`, `2.5`, `-1`)?
fn num_lit(e: ast.Expr): bool = match e.kind {
  Lit(Int(_)) | Lit(Float(_)) => true
  Unary(Neg, x) => x.kind is ast.ExprKind.Lit(ast.Lit.Int(_)) || x.kind is ast.ExprKind.Lit(ast.Lit.Float(_))
  _ => false
}

pub fn check_operand(c: var check.Checker, r: ast.Expr, lt: types.Ty, op: ast.BinOp, l: ast.Expr) {
  let rt = c.infer(r, lt)
  c.operand_with(r, lt, rt, op, l)
}

/// `==` `<` ... on numbers when either side has a unit (or the left is a literal `0`):
/// the units must be equal. Returns false when this isn't such a comparison (nothing
/// checked yet).
pub fn number_compare(c: var check.Checker, e: ast.Expr, op: ast.BinOp, l: ast.Expr, r: ast.Expr, lt: types.Ty): bool {
  let lr = c.resolve(lt)
  match lr {
    Int | Float | Measured(_, _) => {}
    _ => return false
  }
  let rt = c.infer(r, lt)
  let rr = c.resolve(rt)
  if (rr is types.Ty.Fixed(_)) && num_lit(l) {
    // the runtime's dialect: `1 < x` as `x > 1`: the literal takes `x`'s fixed-width type
    let lt2 = c.infer(l, rt)
    if c.resolve(lt2) != rr { let _ = c.coerce_at(r, rt, lt2, false) }
    return true
  }
  if !(lr is types.Ty.Measured(_, _)) && !(rr is types.Ty.Measured(_, _)) {
    let _ = c.coerce_at(r, rt, lt, false)
    return true
  }
  if types.base(lr) != types.base(rr) || rr.has_error() {
    let _ = c.coerce_at(r, rt, lt, false)
  } else if types.units_of(lr) != types.units_of(rr) && !check_expr.is_zero_lit(l) && !check_expr.is_zero_lit(r) {
    c.unit_clash(e, op, lr, rr)
  }
  true
}

/// Arithmetic on numbers where either side has a unit: `+ - %` need equal units (a literal
/// `0` fits any), `*` `/` combine them, `**` takes a literal integer exponent.
pub fn unit_operands(c: var check.Checker, e: ast.Expr, op: ast.BinOp, l: ast.Expr, r: ast.Expr, lt: types.Ty, rt: types.Ty): types.Ty {
  let lr = c.resolve(lt)
  let base = types.base(lr)
  let scale = match op {
    Mul | Div | MulWrap | Pow => true
    _ => false
  }
  if c.shallow(rt) is types.Ty.Var(_) {
    let want = if scale { base } else { lr }
    let _ = c.unify(rt, want)
  }
  let rr = c.resolve(rt)
  if lr.has_error() || rr.has_error() { return types.Ty.Error }
  if types.base(lr) != types.base(rr) {
    c.operand_with(r, base, types.base(rr), op, l)
    return types.Ty.Error
  }
  let lu = types.units_of(lr)
  let ru = types.units_of(rr)
  let zl = check_expr.is_zero_lit(l)
  let zr = check_expr.is_zero_lit(r)
  match op {
    Mul | MulWrap => types.measured(base, units.combine(lu, ru, 1))
    Div => types.measured(base, units.combine(lu, ru, -1))
    Pow => {
      match check_expr.int_exponent(r) {
        some(n) => if units.is_none(ru) { return types.measured(base, units.pow(lu, n)) }
        none => {}
      }
      let msg = if units.is_none(ru) {
        "`**` on `{c.defs.show(lr)}` needs a literal integer exponent to know the result's unit"
      } else {
        "an exponent can't have a unit (`{c.defs.show(rr)}`)"
      }
      c.err(
        diag.new("E0292", r.span, msg)
          .note("write the exponent as a literal (`d ** 2.0`), or strip the unit first with `float(x)`"),
      )
      types.Ty.Error
    }
    _ when lu == ru => lr
    _ when zl => rr
    _ when zr => lr
    _ => {
      c.unit_clash(e, op, lr, rr)
      types.Ty.Error
    }
  }
}

/// E0290: `+ - % == <` ... on numbers with different units.
pub fn unit_clash(c: var check.Checker, e: ast.Expr, op: ast.BinOp, l: types.Ty, r: types.Ty) {
  let ls = c.defs.show(l)
  let rs = c.defs.show(r)
  let verb = match op {
    Add | Sub | Rem | AddWrap | SubWrap => "combine"
    _ => "compare"
  }
  var d = diag.new("E0290", e.span, "can't {verb} `{ls}` and `{rs}` with `{op.symbol()}`: the units differ")
  let lu = types.units_of(l)
  let ru = types.units_of(r)
  if units.is_none(lu) || units.is_none(ru) {
    let u = if units.is_none(lu) { ru } else { lu }
    d = d.note("a plain number has no unit: write the literal with one (`2.0<{units.text(u)}>`), or strip a unit with `float(x)`")
  } else {
    match units.exponent_hint(lu, ru) {
      some(h) => d = d.note("{h} (`{units.text(lu)}` vs `{units.text(ru)}`)")
      none => d = d.note(
        "both sides need the same unit; convert one with a factor (a factor in `{units.text(units.combine(lu, ru, -1))}` turns `{units.text(ru)}` into `{units.text(lu)}`)",
      )
    }
  }
  c.err(d)
}

/// E0291: expected one unit, found another (the types are otherwise equal).
pub fn unit_mismatch(c: check.Checker, span: diag.Span, have: types.Ty, want: types.Ty): diag.Diag {
  let hs = c.defs.show(have)
  let ws = c.defs.show(want)
  let hu = check_expr.first_units(have)
  let wu = check_expr.first_units(want)
  let d = diag.new("E0291", span, "expected `{ws}`, found `{hs}`: the units differ")
  if units.is_none(hu) {
    d.note("a plain number has no unit; give it one (`2.0<{units.text(wu)}>`, or multiply by a value in `{units.text(wu)}`)")
  } else if units.is_none(wu) {
    d.note("`float(x)` / `int(x)` strip a unit when a plain number is meant")
  } else {
    match units.exponent_hint(hu, wu) {
      some(h) => d.note("{h} (`{units.text(hu)}` vs `{units.text(wu)}`)")
      none => d.note(
        "convert with a factor (a factor in `{units.text(units.combine(wu, hu, -1))}` turns `{units.text(hu)}` into `{units.text(wu)}`), or fix the formula",
      )
    }
  }
}

/// Check a primitive arithmetic operand already inferred as `rt` against the left's `lt`.
pub fn operand_with(c: var check.Checker, r: ast.Expr, lt: types.Ty, rt: types.Ty, op: ast.BinOp, l: ast.Expr) {
  if c.unify(rt, lt) { return }
  let lr = c.resolve(lt)
  let rr = c.resolve(rt)
  if rr.has_error() { return }
  var d = diag.new("E0260", r.span, "can't apply `{op.symbol()}` to `{c.defs.show(lr)}` and `{c.defs.show(rr)}`")
  match (lr, rr) {
    (Float, Int) => match r.kind {
      Lit(Int(n)) => d = d.note("both sides must be `float`; write a float literal").fix(r.span, "{token.uint_str(n)}.0")
      _ => d = d
        .note("there are no implicit conversions; convert with `float(x)`")
        .fix(diag.Span { end_line: r.span.line, end_col: r.span.col, ..r.span }, "float(")
        .fix(r.span.after(), ")")
    }
    (Int, Float) => match l.kind {
      Lit(Int(n)) => d = d.note("both sides must be `float`; write a float literal").fix(l.span, "{token.uint_str(n)}.0")
      _ => d = d
        .note("there are no implicit conversions; convert with `float(x)`")
        .fix(diag.Span { end_line: l.span.line, end_col: l.span.col, ..l.span }, "float(")
        .fix(l.span.after(), ")")
    }
    (Str, _) => d = d.note("`+` joins two strings; convert with `str(x)` or interpolate: `\"{{a}}{{b}}\"`")
    _ => d = d.note("both sides of an arithmetic operator have the same type")
  }
  c.err(d)
}

pub fn index_expr(c: var check.Checker, e: ast.Expr, x: ast.Expr, i: ast.Expr): types.Ty {
  let t = c.infer(x, none)
  match c.shallow(t) {
    List(et) => {
      let _ = c.check(i, types.Ty.Int)
      et
    }
    Map(k, v) => {
      let _ = c.check(i, k)
      v
    }
    Str => {
      let _ = c.check(i, types.Ty.Int)
      types.Ty.Char
    }
    Error => {
      let _ = c.infer(i, none)
      types.Ty.Error
    }
    Var(_) => c.cant_infer(x.span, "the indexed value")
    Opt(_) => {
      c.err(
        diag.new("E0270", e.span, "`{c.text(x.span)}` may be missing (`{c.show(t)}`), so it can't be indexed")
          .note("unwrap it first with `?`, `!` or `else`"),
      )
      types.Ty.Error
    }
    _ => {
      c.err(
        diag.new("E0270", e.span, "can't index a `{c.show(t)}`")
          .note("indexing works on lists (`xs[i]`), maps (`m[k]`) and strings (`s[i]`)"),
      )
      types.Ty.Error
    }
  }
}

// ---- interpolation ----

pub fn interp_part(c: var check.Checker, x: ast.Expr, spec: str?) {
  let t = c.infer(x, none)
  let r = c.resolve(t)
  if r != types.Ty.Error {
    c.defer_fit(t, c.b.show, x.span, "to interpolate it into a string")
  }
  if !check_expr.is_prim(r) && !r.has_error() {
    c.note_show(x.id, t)
  }
  match r {
    Measured(_, u) => c.cx.t.units[x.id] = units.text(u)
    _ => {}
  }
  let sp = spec else return
  match parse_format(sp) {
    err(why) => {
      c.err(
        diag.new("E0282", x.span, "malformed format spec `{sp}`: {show(why)}")
          .note("a spec is `[fill][<^>][0][width][.precision][x|X|o|b]`, e.g. `{{x:>5}}`, `{{x:.2}}`, `{{x:08.3}}`, `{{s:-^20}}`, `{{n:04x}}`"),
      )
    }
    ok(f) => {
      let rb = types.base(r)
      let num = is_int_float(rb)
      let ts = c.defs.show(r)
      let prec_ok = match rb {
        Float | Str | Error => true
        _ => false
      }
      if f.precision is some(_) && !prec_ok {
        c.err(
          diag.new("E0280", x.span, "the format spec `{sp}` has a precision, which applies to `float` and `str`, not `{ts}`")
            .note("`.N` is decimal places for a float and a maximum length for a str; remove it, or convert with `float(x)`"),
        )
      }
      match f.radix {
        some(ch) => {
          let radix_ok = match rb {
            Int | Error => true
            _ => false
          }
          if !radix_ok {
            let base = match ch {
              'b' => "binary"
              'o' => "octal"
              _ => "hex"
            }
            c.err(
              diag.new("E0283", x.span, "the format spec `{sp}` shows an `int` in {base}, but this is `{ts}`")
                .note("`x`, `X`, `o` and `b` apply to `int` only; convert first (`int(x)`), or remove it"),
            )
          }
        }
        none => {}
      }
      if f.zero && !num && r != types.Ty.Error {
        c.err(
          diag.new("E0281", x.span, "the format spec `{sp}` pads with zeros, which applies to numbers, not `{ts}`")
            .note("use a fill char instead, e.g. `{{x:0>5}}` (fill `0`, right-aligned)"),
        )
      }
      c.cx.t.formats[x.id] = f
    }
  }
}

// ---- `?`, `!`, `?.`, `else`, `await` ----

pub fn try_expr(c: var check.Checker, e: ast.Expr, x: ast.Expr, exp: check.Exp): types.Ty {
  // the operand's possible types, to steer type arguments (`json.decode(s)?`). The `?`
  // yields the operand's VALUE, which is then converted to the expected type, so the hints
  // wrap the expected value type: in a `T!` function's tail, `f()?` is `T` (then `T!`), and
  // its operand is `T!` / `T?`, never `T!!` (#524). As for `else`, a plain value comes first.
  let vals: [types.Ty] = match check.exp_ty(exp) {
    some(t) => c.value_cands(t)
    none => []
  }
  var hints = c.wrap_hints(vals) else []
  for v in vals {
    match c.shallow(v) {
      List(a) => {
        let ev = c.fresh()
        hints.push(types.list(types.res(a, ev)))
        hints.push(types.list(types.opt(a)))
      }
      _ => {}
    }
  }
  let t = c.expr(x, if hints.len() == 0 { check.Exp.None } else { check.Exp.Hints(hints) })
  let ts = c.shallow(t)
  let parts: (typed.TryKind, types.Ty, types.Ty?) = match ts {
    Res(ok, er) => (typed.TryKind.Result, ok, er)
    Opt(ok) => (typed.TryKind.Option, ok, none)
    List(el) => match c.shallow(el) {
      Res(ok, er) => (typed.TryKind.ListResult, types.list(ok), er)
      Opt(ok) => (typed.TryKind.ListOption, types.list(ok), none)
      _ => return c.bad_try(e, x, t)
    }
    Error => return types.Ty.Error
    Var(_) => return c.cant_infer(x.span, "the value before `?`")
    _ => return c.bad_try(e, x, t)
  }
  let (kind, inner, err) = parts
  let ret: types.Ty? = match c.frame_ret() {
    some(r) => c.shallow(r)
    none => none
  }
  let what = match c.top_frame() {
    some(f) => f.what
    none => "function"
  }
  let retv = ret else types.Ty.Error
  let conv = match (ret, err) {
    (none, _) => {
      c.err(
        diag.new("E0246", e.span, "`?` is not allowed in a {what}")
          .note("a guard or constant can't fail; handle the error with `else` or unwrap it with `!`"),
      )
      typed.ErrConv.None
    }
    (some(Res(_, rerr0)), some(er0)) => {
      let rerr = c.shallow(rerr0)
      let er = c.shallow(er0)
      if c.try_unify(rerr, er) {
        typed.ErrConv.None
      } else if c.defs.is_err(rerr) {
        typed.ErrConv.ToErr(er)
      } else {
        c.err(
          diag.new("E0247", e.span, "`?` can't pass a `{c.show(er)}` error up: this {what} returns `{c.show(retv)}`")
            .note("a `T!{c.show(rerr)}` function's errors must be `{c.show(rerr)}`; handle this one with `else e => fail(...)`, or make the return type `T!` (any error converts to `Err`)"),
        )
        typed.ErrConv.None
      }
    }
    (some(Opt(_)), none) => typed.ErrConv.None
    (some(Opt(_)), some(_)) => {
      c.err(
        diag.new("E0248", e.span, "`?` on `{c.show(t)}` passes an error up, but this {what} returns an optional `{c.show(retv)}`")
          .note("turn the error into a missing value with `x else none`... or make the function return `T!`"),
      )
      typed.ErrConv.None
    }
    (some(Res(_, _)), none) => {
      c.err(
        diag.new("E0249", e.span, "`?` on an optional `{c.show(t)}` in a {what} that returns `{c.show(retv)}`")
          .note("a missing value isn't an error; say what went wrong with `x else fail(\"...\")`, or unwrap with `!`"),
      )
      typed.ErrConv.None
    }
    (some(r), _) => {
      let rs = c.show(r)
      let passes = if err is some(_) { "an error" } else { "a missing value" }
      var d = diag.new("E0243", e.span, "`?` passes {passes} up, but this {what} returns `{rs}`")
      let ret_span: diag.Span? = match c.top_frame() {
        some(f) => f.ret_span
        none => none
      }
      let wrapped = if err is some(_) { "{rs}!" } else { "{rs}?" }
      match ret_span {
        some(rs_span) => d = d.note("make it return `{wrapped}`, or handle the value here with `else`").fix(rs_span, wrapped)
        none => d = d.note("declare the return type `{wrapped}`, or handle the value here with `else` or `!`")
      }
      c.err(d)
      typed.ErrConv.None
    }
  }
  c.cx.t.tries[e.id] = typed.TryInfo { kind, conv }
  inner
}

pub fn bad_try(c: var check.Checker, e: ast.Expr, x: ast.Expr, t: types.Ty): types.Ty {
  let ts = c.show(t)
  var d = diag.new("E0250", e.span, "`?` needs a `T!`, `T?` or a list of them, but `{c.text(x.span)}` is `{ts}`")
  if c.shallow(t) is types.Ty.Task(_) {
    d = d
      .note("this is an un-awaited `async fn` call: `await` it first")
      .fix(diag.Span { end_line: x.span.line, end_col: x.span.col, ..x.span }, "await ")
  } else {
    d = d.note("remove the `?`").fix(diag.Span { line: e.span.end_line, col: e.span.end_col - 1, ..e.span }, "")
  }
  c.err(d)
  t
}

/// Rust's `Ident::tuple_index`: the name as a `u32` if it is all ASCII digits.
fn tuple_index(name: ast.Ident): int? {
  let s = name.name
  if s.len() == 0 { return none }
  for ch in s.chars() {
    if ch < '0' || ch > '9' { return none }
  }
  if s.len() > 10 { return none }
  let n = int.parse(s) else return none
  if n > 4294967295 { return none }
  n
}

pub fn opt_chain(c: var check.Checker, e: ast.Expr, x: ast.Expr, name: ast.Ident, args: [ast.Expr]?, exp: check.Exp): types.Ty {
  let t = c.infer(x, none)
  let inner = match c.shallow(t) {
    Opt(i) => i
    Error => return types.Ty.Error
    Var(_) => return c.cant_infer(x.span, "the value before `?.`")
    Res(_, _) => {
      let xt = c.text(x.span)
      let full = diag.Span { end_line: name.span.line, end_col: name.span.col, ..x.span }
      c.err(
        diag.new("E0252", e.span, "`?.` works on `T?` only, but `{xt}` is `{c.show(t)}`")
          .note("to pass the error up and then use the value, write `(x?).f`")
          .fix(full, "({xt}?)."),
      )
      return types.Ty.Error
    }
    _ => {
      c.err(
        diag.new("E0253", e.span, "`?.` needs an optional `T?`, but `{c.text(x.span)}` is `{c.show(t)}`")
          .note("use `.` for a value that is always present")
          .fix(diag.Span { line: name.span.line, col: name.span.col - 2, end_line: name.span.line, end_col: name.span.col }, "."),
      )
      return types.Ty.Error
    }
  }
  let member = match args {
    none => match tuple_index(name) {
      some(index) => c.opt_tuple_elem(e, x, inner, index)
      none => c.field_of(e, x, inner, name)
    }
    some(xs) => {
      // the receiver's value is the unwrapped `inner`
      let direct = false
      var all = [check.ArgSrc.Recv(x)]
      for a in xs { all.push(check.ArgSrc.Expr(a)) }
      // the receiver's recorded type is the optional; temporarily present the inner one
      let saved = c.cx.t.types.get(x.id)
      c.cx.t.types[x.id] = inner
      let r = c.dot_call(e, x, inner, name, all, exp, direct)
      match saved {
        some(s) => c.cx.t.types[x.id] = s
        none => {}
      }
      match c.cx.t.calls.get(e.id) {
        some(call) => if call.args.len() > 0 && call.args[0].by_ref {
          c.err(diag.new("E0253", e.span, "`?.{name.name}` can't call a function that changes its receiver"))
        }
        none => {}
      }
      r
    }
  }
  let flatten = c.shallow(member) is types.Ty.Opt(_)
  c.cx.t.opt_chains[e.id] = typed.OptChainInfo { flatten }
  if flatten { member } else { types.opt(member) }
}

/// The element type of `x?.N`, `inner` being the type under `x`'s `?`.
pub fn opt_tuple_elem(c: var check.Checker, e: ast.Expr, x: ast.Expr, inner: types.Ty, index: int): types.Ty {
  match c.shallow(inner) {
    Tuple(ts) when index < ts.len() => ts[index]
    Tuple(ts) => {
      c.err(
        diag.new("E0223", e.span, "the tuple `{c.show(inner)}` has no element {index}")
          .note("it has {ts.len()} element(s), numbered from 0"),
      )
      types.Ty.Error
    }
    Error => types.Ty.Error
    Var(_) => c.cant_infer(x.span, "the tuple")
    _ => {
      let t = types.opt(inner)
      c.err(diag.new("E0223", e.span, "`?.{index}` needs an optional tuple, found `{c.show(t)}`"))
      types.Ty.Error
    }
  }
}

pub fn else_expr(c: var check.Checker, e: ast.Expr, x: ast.Expr, arm: ast.ElseArm, exp: check.Exp): types.Ty {
  let vals: [types.Ty] = match check.exp_ty(exp) {
    some(t) => c.value_cands(t)
    none => []
  }
  let hints = c.wrap_hints(vals)
  let t = c.expr(x, match hints {
    some(h) => check.Exp.Hints(h)
    none => check.Exp.None
  })
  let parts: (typed.ElseKind, types.Ty, types.Ty?) = match c.shallow(t) {
    Opt(i) => (typed.ElseKind.Option, i, none)
    Res(i, er) => (typed.ElseKind.Result, i, er)
    Error => {
      let _ = c.infer(arm.body, none)
      return types.Ty.Error
    }
    Var(_) => return c.cant_infer(x.span, "the value before `else`")
    other => {
      let s = c.defs.show(c.resolve(other))
      c.err(
        diag.new("E0255", e.span, "`else` handles a missing value or an error, but `{c.text(x.span)}` is a plain `{s}`")
          .note("remove the `else` part"),
      )
      let _ = c.infer(arm.body, none)
      return other
    }
  }
  let (kind, inner, err) = parts
  c.push_scope()
  let binder = c.else_binder(arm, err)
  match check.exp_want(exp) {
    some((_, tail)) => {
      // the result is `inner` (then converted to the expected type); the fallback must be
      // an `inner`. Pin an unsolved `inner` to the expected value type, unwrapped first.
      for v in vals {
        if c.try_unify(inner, v) { break }
      }
      c.check_mode(arm.body, inner, tail)
    }
    none => {
      let _ = c.check(arm.body, inner)
    }
  }
  c.pop_scope()
  c.cx.t.elses[e.id] = typed.ElseInfo { kind, binder }
  inner
}

/// The value types an `x else y` / `x!` may have when `want` is expected: the value is
/// converted to `want` afterwards, so for `want = T?` or `T!` a plain `T` comes first, then
/// `want` itself (`T??` handled down to `T?`).
pub fn value_cands(c: check.Checker, want: types.Ty): [types.Ty] {
  let w = c.shallow(want)
  match w {
    Var(_) => []
    Opt(i) | Res(i, _) => [i, w]
    _ => [w]
  }
}

/// Hints for the operand of `else` / `!` / `?`: `V?` or `V!` for each candidate value type `V`.
pub fn wrap_hints(c: var check.Checker, vals: [types.Ty]): [types.Ty]? {
  if vals.len() == 0 { return none }
  var hints: [types.Ty] = []
  for v in vals {
    hints.push(types.opt(v))
    let ev = c.fresh()
    hints.push(types.res(v, ev))
  }
  hints
}

pub fn else_binder(c: var check.Checker, arm: ast.ElseArm, err: types.Ty?): int? {
  let b = arm.binder else return none
  match err {
    some(et) => {
      let l = c.new_local(b.name, et, false, b.span)
      c.scope_insert(b.name, l)
      l
    }
    none => {
      c.err(
        diag.new("E0254", b.span, "`else {b.name} =>` binds an error, but the value is optional (`T?`), so there is none")
          .note("write `else fallback`")
          .fix(diag.Span { end_line: arm.body.span.line, end_col: arm.body.span.col, ..b.span }, ""),
      )
      none
    }
  }
}

pub fn await_expr(c: var check.Checker, e: ast.Expr, x: ast.Expr): types.Ty {
  let call_like = match x.kind {
    Call(_, _) | MethodCall(_, _, _) | Pipe(_, _, _) => true
    _ => false
  }
  if call_like { c.cx.direct_await = true }
  let t = c.infer(x, none)
  c.cx.direct_await = false
  match c.cx.t.awaits.get(x.id) {
    some(Direct) => {
      let _ = c.cx.t.awaits.remove(x.id)
      c.cx.t.awaits[e.id] = typed.AwaitKind.Direct
      return t
    }
    _ => {}
  }
  let parts: (typed.AwaitKind, types.Ty) = match c.shallow(t) {
    Task(r) => (typed.AwaitKind.Task, r)
    Tuple(ts) when ts.len() > 0 => {
      var outs: [types.Ty] = []
      for t2 in ts {
        match c.shallow(t2) {
          Task(r) => outs.push(r)
          _ => return c.bad_await(e, x, types.Ty.Tuple(ts))
        }
      }
      (typed.AwaitKind.Tuple, types.Ty.Tuple(outs))
    }
    List(el) => match c.shallow(el) {
      Task(r) => (typed.AwaitKind.List, types.list(r))
      _ => return c.bad_await(e, x, t)
    }
    Error => return types.Ty.Error
    _ => return c.bad_await(e, x, t)
  }
  let (kind, out) = parts
  c.cx.t.awaits[e.id] = kind
  out
}

pub fn bad_await(c: var check.Checker, e: ast.Expr, x: ast.Expr, t: types.Ty): types.Ty {
  let ts = c.show(t)
  c.err(
    diag.new("E0331", e.span, "`await` needs an `async fn` call, a task, a tuple of tasks or a list of tasks, but `{c.text(x.span)}` is `{ts}`")
      .note("only calls of `async fn`s produce tasks; remove the `await`")
      .fix(diag.Span { end_line: x.span.line, end_col: x.span.col, ..e.span }, ""),
  )
  t
}

/// `await any ts`: `(index, T!)` for a list of `Task<T>` (a `T!`/`T!E` result stays as is, as
/// `T!`); a task's panic is the `Err` instead of being raised.
pub fn await_any_expr(c: var check.Checker, e: ast.Expr, x: ast.Expr): types.Ty {
  let t = c.infer(x, none)
  let el = match c.shallow(t) {
    List(el0) => match c.shallow(el0) {
      Task(r) => r
      Error => return types.Ty.Error
      _ => return c.bad_await_any(e, x, t)
    }
    Error => return types.Ty.Error
    _ => return c.bad_await_any(e, x, t)
  }
  let errt = types.Ty.Named(c.b.err, [])
  let r = match c.shallow(el) {
    Res(ok, _) => types.res(ok, errt)
    other => types.res(other, errt)
  }
  types.Ty.Tuple([types.Ty.Int, r])
}

pub fn bad_await_any(c: var check.Checker, e: ast.Expr, x: ast.Expr, t: types.Ty): types.Ty {
  let ts = c.show(t)
  c.err(
    diag.new("E0331", e.span, "`await any` needs a list of tasks, but `{c.text(x.span)}` is `{ts}`")
      .note("build the list from `async fn` calls without `await`: `var ts = [a(), b()]`, then `await any ts`"),
  )
  types.Ty.Error
}

// ---- `catch` ----

/// `catch x`: x's value as `T!`, where a panic while evaluating it becomes an `Err`. The
/// body runs in a function of its own (the runtime's recovery point needs a frame), checked
/// like a closure `() => x` returning `T!`: `?` and `fail` inside it end the `catch` with that
/// error. It captures by reference, so it may change the variables it uses.
pub fn catch_expr(c: var check.Checker, e: ast.Expr, x: ast.Expr): types.Ty {
  let ok = c.fresh()
  let ret = types.res(ok, types.Ty.Named(c.b.err, []))
  c.push_scope()
  c.push_frame(check.Frame { is_closure: true, by_ref: true, ..check.frame("catch", ret, none) })
  let _ = c.check(x, ret)
  let fr = c.pop_frame()
  c.pop_scope()
  c.cx.t.closures[e.id] = typed.ClosureInfo { params: [], ret, captures: fr.captures, unpack: false }
  ret
}

// ---- closures ----

pub fn closure(c: var check.Checker, e: ast.Expr, params: [ast.Param], body: ast.Expr, exp: check.Exp): types.Ty {
  var expected: ([types.Ty], types.Ty)? = none
  match check.exp_ty(exp) {
    some(et) => match c.shallow(et) {
      Fn(ps, r) => expected = (ps, r)
      Var(v) => {
        var ps: [types.Ty] = []
        for p in params {
          if p.var_ { ps.push(types.Ty.Mut(c.fresh())) } else { ps.push(c.fresh()) }
        }
        let r = c.fresh()
        let _ = c.unify(types.Ty.Var(v), types.func(ps, r))
        expected = (ps, r)
      }
      _ => {}
    }
    none => {}
  }
  var unpack = false
  var elem_tys: [types.Ty]? = none
  match expected {
    some((ps, _)) => if ps.len() == 1 && params.len() > 1 {
      match c.shallow(ps[0]) {
        Tuple(ts) => if ts.len() == params.len() {
          unpack = true
          elem_tys = ts
        }
        _ => {}
      }
    }
    none => {}
  }
  let arity_mismatch = match expected {
    some((ps, _)) => !unpack && ps.len() != params.len()
    none => false
  }
  if arity_mismatch {
    match expected {
      some((ps, r)) => c.err(
        diag.new("E0204", e.span, "this closure takes {params.len()} parameter(s), but {ps.len()} are expected here")
          .note("the expected function type is `{c.show(types.func(ps, r))}`"),
      )
      none => {}
    }
  }
  let m = c.cur_module()
  var ptys: [types.Ty] = []
  // per parameter: is it `var` (from `p: var T`, or a `var T` in the expected type)?
  var vars: [bool] = []
  for i, p in params {
    let from_exp0: types.Ty? = match elem_tys {
      some(ts) => ts.get(i)
      none => match expected {
        some((ps, _)) => ps.get(i)
        none => none
      }
    }
    var exp_var = false
    var from_exp: types.Ty? = none
    match from_exp0 {
      some(t0) => match c.shallow(t0) {
        Mut(t1) => {
          exp_var = true
          from_exp = t1
        }
        t1 => from_exp = t1
      }
      none => {}
    }
    let wrong_var = p.var_ && from_exp is some(_) && !exp_var && !arity_mismatch
    if wrong_var {
      let xs = c.show(from_exp else types.Ty.Error)
      c.err(
        diag.new("E0200", p.span, "this closure parameter is `var`, but the function type here passes a plain `{xs}`")
          .note("a `var` parameter needs a function type that says so, e.g. `(var {xs}) => ...`"),
      )
    }
    // (after a wrong `var`, the closure keeps the expected type: no second error)
    vars.push((p.var_ && !wrong_var) || exp_var)
    let t = match p.ty {
      some(ann) => {
        var g = c.cx.generics
        let t1 = c.resolve_type(m, ann, &g)
        match from_exp {
          some(x) => if !c.unify(t1, x) {
            let ts = c.show(t1)
            let xs = c.show(x)
            c.err(
              diag.new("E0200", ann.span, "this closure parameter is declared `{ts}`, but `{xs}` is passed here")
                .fix(ann.span, xs),
            )
          }
          none => {}
        }
        t1
      }
      none => match from_exp {
        some(f) => f
        none => c.fresh()
      }
    }
    ptys.push(t)
  }
  let ret = match expected {
    some((_, r)) => r
    none => c.fresh()
  }
  // the frame starts before the parameters' scope: they are the closure's own, not captures
  c.push_frame(check.Frame { is_closure: true, ..check.frame("closure", ret, none) })
  c.push_scope()
  var seen: {str: diag.Span} = {}
  for i, p in params {
    c.cx.t.types[p.id] = ptys[i]
    c.pattern(p.pat, ptys[i], vars[i], &seen)
  }
  let _ = c.check(body, ret)
  c.pop_scope()
  let fr = c.pop_frame()
  // a `var` parameter is `var T` in the closure's type (passed by reference)
  var ptys2: [types.Ty] = []
  for i, t in ptys {
    if vars[i] { ptys2.push(types.Ty.Mut(t)) } else { ptys2.push(t) }
  }
  c.cx.t.closures[e.id] = typed.ClosureInfo { params: ptys2, ret, captures: fr.captures, unpack }
  // captures of a nested closure are captures of the enclosing closure too (handled by
  // lookup_local walking every frame)
  // E0204 already reported the arity mismatch: don't let the caller report it again as E0200
  if arity_mismatch { return types.Ty.Error }
  let fparams = if unpack { [types.Ty.Tuple(ptys2)] } else { ptys2 }
  types.func(fparams, ret)
}

// ---- control flow ----

pub fn block(c: var check.Checker, b: ast.Block, exp: check.Exp): types.Ty {
  c.push_scope()
  let n = b.stmts.len()
  var out = types.unit()
  if n == 0 {
    match check.exp_want(exp) {
      some((w, tail)) => {
        var cs: [typed.Coercion] = []
        if !c.coerce_ty(types.unit(), w, &cs, b.span) {
          let e = ast.Expr { id: b.id, span: b.span, kind: ast.ExprKind.Tuple([]) }
          c.mismatch(e, types.unit(), w, tail)
        }
        for co in cs { c.add_coercion(b.id, co) }
        out = w
      }
      none => {}
    }
    c.pop_scope()
    return out
  }
  for i, s in b.stmts {
    if i + 1 < n {
      // unreachable code after a diverging statement is allowed (patterns.rs may warn)
      let _ = c.stmt(s, true)
      continue
    }
    let stmt_like = match s.kind {
      Let(_, _, _, _, _) | Assign(_, _, _) | Assert(_) | While(_, _) | For(_, _, _, _) => true
      _ => false
    }
    out = match exp {
      Discard => {
        let _ = c.stmt(s, true)
        types.unit()
      }
      _ when stmt_like => {
        let _ = c.stmt(s, true)
        match check.exp_want(exp) {
          some((w, tail)) => {
            let _ = c.coerce_at(s, types.unit(), w, tail)
            w
          }
          none => types.unit()
        }
      }
      Check(w) => {
        c.check_mode(s, w, false)
        w
      }
      Tail(w) => {
        c.check_mode(s, w, true)
        w
      }
      other => c.expr(s, other)
    }
  }
  c.pop_scope()
  out
}

pub fn if_expr(c: var check.Checker, cond: ast.Expr, then: ast.Block, els: ast.Expr?, exp: check.Exp): types.Ty {
  let _ = c.check(cond, types.Ty.Bool)
  let ee = els else {
    let _ = c.block(then, check.Exp.Discard)
    match check.exp_want(exp) {
      some((w, _)) => {
        var cs: [typed.Coercion] = []
        if !c.coerce_ty(types.unit(), w, &cs, then.span) {
          let ws = c.show(w)
          c.err(
            diag.new("E0205", cond.span, "an `if` without `else` has no value, but a `{ws}` is expected here")
              .note("add an `else` branch"),
          )
          return w
        }
        // its value is `()`; the caller (`check`/`check_mode`) records the conversion to
        // `w` (auto-wrap into `()!` / `()?`) on this node
        return types.unit()
      }
      none => {}
    }
    return types.unit()
  }
  match exp {
    Discard => {
      let _ = c.block(then, check.Exp.Discard)
      let _ = c.stmt(ee, true)
      types.unit()
    }
    Check(w) | Tail(w) => {
      // a mismatch in one branch doesn't mean the return type is wrong: no `Tail`
      let _ = c.block(then, check.Exp.Check(w))
      c.check_mode(ee, w, false)
      w
    }
    _ => {
      // the runtime's dialect: a number literal in the first arm takes the other arm's type
      // (`if c.n == 0 { 8 } else { c.n * 2 }` with a `u32` `c.n`), as `1 + x` does
      if c.prog.raw_ok(c.cur_module()) && lit_arm(then) {
        let et = c.expr(ee, exp)
        if c.shallow(et) == types.Ty.Never { return c.block(then, exp) }
        let _ = c.block(then, check.Exp.Check(et))
        return et
      }
      let tt = c.block(then, exp)
      if c.shallow(tt) == types.Ty.Never { return c.expr(ee, exp) }
      let _ = c.check(ee, tt)
      tt
    }
  }
}

/// Is the block just an integer literal (`{ 8 }`, `{ -1 }`)?
fn lit_arm(b: ast.Block): bool {
  if b.stmts.len() != 1 { return false }
  match b.stmts[0].kind {
    Lit(Int(_)) => true
    Unary(Neg, x) => x.kind is ast.ExprKind.Lit(ast.Lit.Int(_))
    _ => false
  }
}

pub fn match_expr(c: var check.Checker, scrut: ast.Expr, arms: [ast.Arm], exp: check.Exp): types.Ty {
  let st = c.infer(scrut, none)
  var result: types.Ty? = match check.exp_want(exp) {
    some((w, _)) => w
    none => none
  }
  for a in arms {
    c.push_scope()
    var seen: {str: diag.Span} = {}
    c.pattern(a.pat, st, false, &seen)
    match a.guard {
      some(g) => c.guard(g)
      none => {}
    }
    match exp {
      Discard => {
        let _ = c.stmt(a.body, true)
      }
      Check(w) | Tail(w) => c.check_mode(a.body, w, false)
      _ => match result {
        some(r) => {
          let _ = c.check(a.body, r)
        }
        none => {
          let t = c.expr(a.body, exp)
          if c.shallow(t) != types.Ty.Never { result = t }
        }
      }
    }
    c.pop_scope()
  }
  match exp {
    Discard => types.unit()
    _ => result else types.Ty.Never
  }
}

pub fn push_loop(c: var check.Checker, is_loop: bool, break_ty: types.Ty) {
  let fi = c.cx.frames.len() - 1
  c.cx.frames[fi].loops.push(check.LoopCx { is_loop, break_ty, saw_break: false })
}

pub fn pop_loop(c: var check.Checker): check.LoopCx {
  let fi = c.cx.frames.len() - 1
  c.cx.frames[fi].loops.pop() else check.LoopCx { is_loop: false, break_ty: types.Ty.Error, saw_break: false }
}

pub fn in_loop(c: check.Checker): bool = match c.top_frame() {
  some(f) => f.loops.len() > 0
  none => false
}

pub fn break_expr(c: var check.Checker, e: ast.Expr, x: ast.Expr?) {
  let lopt: check.LoopCx? = match c.top_frame() {
    some(f) => f.loops.last()
    none => none
  }
  let l = lopt else {
    c.err(
      diag.new("E0244", e.span, "`break` outside a loop")
        .note("`break` ends the innermost `loop`, `while` or `for` of this function (not of an enclosing one, from inside a closure)"),
    )
    match x {
      some(y) => {
        let _ = c.infer(y, none)
      }
      none => {}
    }
    return
  }
  match x {
    some(y) when l.is_loop => {
      let _ = c.check(y, l.break_ty)
    }
    some(y) => {
      c.err(
        diag.new("E0245", y.span, "only `loop` can `break` with a value")
          .note("a `while` or `for` loop has no value; write `break`")
          .fix(diag.Span { line: e.span.line, col: e.span.col + 5, ..e.span }, ""),
      )
      let _ = c.infer(y, none)
    }
    none when l.is_loop => {
      let bt = l.break_ty
      var cs: [typed.Coercion] = []
      if !c.coerce_ty(types.unit(), bt, &cs, e.span) {
        let bs = c.show(bt)
        c.err(
          diag.new("E0245", e.span, "this `loop` has a value of type `{bs}`, so `break` needs one")
            .note("write `break value`"),
        )
      }
      // a bare `break` is `break ()`: record its auto-wrap (into `()!` / `()?`)
      for co in cs { c.add_coercion(e.id, co) }
    }
    none => {}
  }
  let fi = c.cx.frames.len() - 1
  let li = c.cx.frames[fi].loops.len() - 1
  c.cx.frames[fi].loops[li].saw_break = true
}

pub fn for_expr(c: var check.Checker, e: ast.Expr, index: ast.Pat?, pat: ast.Pat, iter: ast.Expr, body: ast.Block) {
  c.push_scope()
  var seen: {str: diag.Span} = {}
  match iter.kind {
    Range(lo, hi, inclusive) => {
      let _ = c.check(lo, types.Ty.Int)
      let _ = c.check(hi, types.Ty.Int)
      c.record(iter.id, types.list(types.Ty.Int))
      match index {
        some(ix) => c.err(diag.new("E0207", ix.span, "a range loop has no separate index").note("write `for i in a..b`"))
        none => {}
      }
      c.pattern(pat, types.Ty.Int, false, &seen)
      c.cx.t.fors[e.id] = typed.ForKind.Range(inclusive)
    }
    _ => {
      let t = c.infer(iter, none)
      match c.shallow(t) {
        List(el) => {
          match index {
            some(ix) => c.pattern(ix, types.Ty.Int, false, &seen)
            none => {}
          }
          c.pattern(pat, el, false, &seen)
          c.cx.t.fors[e.id] = typed.ForKind.List
        }
        Map(k, v) => {
          match index {
            some(ix) => {
              c.pattern(ix, k, false, &seen)
              c.pattern(pat, v, false, &seen)
            }
            none => c.pattern(pat, types.Ty.Tuple([k, v]), false, &seen)
          }
          c.cx.t.fors[e.id] = typed.ForKind.Map
        }
        Named(dd, args) when args.len() == 1 && c.defs.types[dd].name == "Chan" && c.prog.is_core(c.defs.types[dd].module) => {
          match index {
            some(ix) => c.err(diag.new("E0207", ix.span, "a channel loop has no index").note("write `for x in c`"))
            none => {}
          }
          c.pattern(pat, args[0], false, &seen)
          c.cx.t.fors[e.id] = typed.ForKind.Chan
        }
        Error => {
          match index {
            some(ix) => c.pattern(ix, types.Ty.Error, false, &seen)
            none => {}
          }
          c.pattern(pat, types.Ty.Error, false, &seen)
        }
        other => {
          let s = c.defs.show(c.resolve(other))
          var d = diag.new("E0207", iter.span, "can't loop over a `{s}`").note("`for` loops over a list, a map or a range `a..b`")
          if other == types.Ty.Str {
            let text = c.text(iter.span)
            let postfix = match iter.kind {
              Lit(_) | Interp(_) | Name(_) | Field(_, _) | TupleField(_, _) | Call(_, _) | MethodCall(_, _, _) | Index(_, _) | Slice(_, _, _, _) => true
              _ => false
            }
            let chars = if postfix { "{text}.chars()" } else { "({text}).chars()" }
            d = d.note("a `str` is not iterable; loop over its chars with `for c in {chars}`")
            d = if postfix { d.fix(iter.span.after(), ".chars()") } else { d.fix(iter.span, chars) }
            c.err(d)
            // the body checks as it will after the fix: `c` is a `char`
            match index {
              some(ix) => c.pattern(ix, types.Ty.Int, false, &seen)
              none => {}
            }
            c.pattern(pat, types.Ty.Char, false, &seen)
            c.push_loop(false, types.unit())
            let _ = c.block(body, check.Exp.Discard)
            let _ = c.pop_loop()
            c.pop_scope()
            return
          }
          match other {
            Opt(_) | Res(_, _) => d = d.note("unwrap it first with `?`").fix(iter.span.after(), "?")
            _ => {}
          }
          c.err(d)
          match index {
            some(ix) => c.pattern(ix, types.Ty.Error, false, &seen)
            none => {}
          }
          c.pattern(pat, types.Ty.Error, false, &seen)
        }
      }
    }
  }
  c.push_loop(false, types.unit())
  let _ = c.block(body, check.Exp.Discard)
  let _ = c.pop_loop()
  c.pop_scope()
}

pub fn let_stmt(c: var check.Checker, e: ast.Expr, mutable: bool, pat: ast.Pat, ann: ast.Type?, value: ast.Expr, els: ast.ElseArm?) {
  let m = c.cur_module()
  let ann_ty: types.Ty? = match ann {
    some(t) => {
      var g = c.cx.generics
      c.resolve_type(m, t, &g)
    }
    none => none
  }
  let before = c.tables[m].locals.len()
  let kw = diag.Span { end_line: e.span.line, end_col: e.span.col + 3, ..e.span }
  let arm = els else {
    let bound: str? = match (pat.kind, value.kind) {
      (Bind(n), Closure(_, _)) => n
      _ => none
    }
    match bound {
      some(n) => c.binding.push(n)
      none => {}
    }
    let t = match ann_ty {
      some(a) => c.check(value, a)
      none => c.infer(value, none)
    }
    if bound is some(_) { let _ = c.binding.pop() }
    c.check_unawaited_let(value, t)
    var seen: {str: diag.Span} = {}
    c.pattern(pat, t, mutable, &seen)
    c.mark_let_locals(before, kw, mutable)
    return
  }
  // `let pat = value else ...`: either `value` is `T?`/`T!` and the `else` handles the
  // missing value or error (the pattern then matches the `T`), or the pattern is refutable
  // and the `else` handles a non-match.
  let wrapper_pat = match pat.kind {
    Some(_) | None | Ok(_) | Err(_) => true
    _ => false
  }
  let hints: [types.Ty]? = match ann_ty {
    some(a) => {
      let ev = c.fresh()
      [types.opt(a), types.res(a, ev)]
    }
    none => none
  }
  let t = c.expr(value, match hints {
    some(h) => check.Exp.Hints(h)
    none => check.Exp.None
  })
  let ts = c.shallow(t)
  let refutable = !c.irrefutable(pat)
  var kind = typed.ElseKind.Refutable
  var inner = t
  var err: types.Ty? = none
  var unwrapped = false
  if !wrapper_pat {
    match ts {
      Opt(i) => {
        kind = if refutable { typed.ElseKind.UnwrapRefutable(true) } else { typed.ElseKind.Option }
        inner = i
        unwrapped = true
      }
      Res(i, er) => {
        kind = if refutable { typed.ElseKind.UnwrapRefutable(false) } else { typed.ElseKind.Result }
        inner = i
        err = er
        unwrapped = true
      }
      _ => {}
    }
  }
  if !unwrapped {
    if !refutable && ts != types.Ty.Error {
      let s = c.show(t)
      c.err(
        diag.new("E0255", e.span, "this `let` always succeeds: `{c.text(value.span)}` is a plain `{s}` and the pattern always matches")
          .note("remove the `else` part")
          .fix(diag.Span { line: value.span.end_line, col: value.span.end_col, ..arm.body.span }, ""),
      )
      let _ = c.infer(arm.body, none)
      var seen: {str: diag.Span} = {}
      c.pattern(pat, t, mutable, &seen)
      c.mark_let_locals(before, kw, mutable)
      return
    }
    kind = typed.ElseKind.Refutable
    inner = t
    err = none
  }
  match ann_ty {
    some(a) => if !c.unify(inner, a) {
      let is_ = c.show(inner)
      let as_ = c.show(a)
      c.err(diag.new("E0200", value.span, "expected `{as_}`, found `{is_}`"))
    }
    none => {}
  }
  // the else arm: no bindings of the pattern are visible in it
  c.push_scope()
  let binder = c.else_binder(arm, err)
  let diverge_only = match kind {
    Refutable | UnwrapRefutable(_) => true
    _ => false
  }
  if diverge_only {
    let bt = c.infer(arm.body, none)
    let b = c.shallow(bt)
    if b != types.Ty.Never && b != types.Ty.Error {
      let s = c.show(bt)
      c.err(
        diag.new("E0240", arm.body.span, "the `else` of a refutable `let` must leave the block (return, break, continue or fail), but this is a `{s}`")
          .note("when the pattern doesn't match there are no values to bind, so the `else` can't provide a fallback; write `else {{ return ... }}` or use a `match`"),
      )
    }
  } else {
    let _ = c.check(arm.body, inner)
  }
  c.pop_scope()
  var seen: {str: diag.Span} = {}
  c.pattern(pat, inner, mutable, &seen)
  c.mark_let_locals(before, kw, mutable)
  c.cx.t.elses[e.id] = typed.ElseInfo { kind, binder }
}

fn check_unawaited_let(c: var check.Checker, value: ast.Expr, t: types.Ty) {
  // storing a task in a variable is allowed ("awaited, stored or returned")
}

/// Remember how to make the locals of a `let` mutable (for the E0320 fix-it).
pub fn mark_let_locals(c: var check.Checker, before: int, kw: diag.Span, mutable: bool) {
  if mutable { return }
  let m = c.cur_module()
  let after = c.tables[m].locals.len()
  for l in before..after { c.let_fixes[(m, l)] = kw }
}

/// A pattern that matches every value of its type (no exhaustiveness needed).
pub fn irrefutable(c: check.Checker, p: ast.Pat): bool {
  let m = c.cur_module()
  match p.kind {
    Wild => true
    Bind(n) => c.variants_in_scope(m, n).len() == 0 || (c.depth > 0 && c.cx.t.binds.contains(p.id))
    Tuple(ps) => {
      for q in ps {
        if !c.irrefutable(q) { return false }
      }
      true
    }
    Struct(_, fields, _) => {
      for f in fields {
        match f.pat {
          some(q) => if !c.irrefutable(q) { return false }
          none => {}
        }
      }
      true
    }
    _ => false
  }
}

/// The type of an assignment target: a place, or a tuple of them (`(a, b) = (b, a)`).
pub fn assign_target(c: var check.Checker, target: ast.Expr): types.Ty {
  match target.kind {
    Tuple(xs) => {
      var ts: [types.Ty] = []
      for x in xs { ts.push(c.assign_target(x)) }
      let t = types.Ty.Tuple(ts)
      c.record(target.id, t)
      return t
    }
    _ => {}
  }
  c.place(target, true, check.PlaceUse.Assign)
}

pub fn assign(c: var check.Checker, e: ast.Expr, op: ast.BinOp?, target: ast.Expr, value: ast.Expr) {
  if op == none && target.kind is ast.ExprKind.Tuple(_) {
    let t = c.assign_target(target)
    let _ = c.check(value, t)
    return
  }
  let t = c.place(target, true, check.PlaceUse.Assign)
  let o = op else {
    let _ = c.check(value, t)
    return
  }
  let bits = match o {
    BitAnd | BitOr | BitXor | Shl | Shr => true
    _ => false
  }
  if bits {
    let sym = "{o.symbol()}="
    let ok = c.bit_operand(target, t, sym, false)
    if types.is_fixed_int(c.shallow(t)) {
      let rt = c.infer(value, t)
      if ok { c.operand_with(value, t, rt, o, target) }
      return
    }
    let rt = c.infer(value, types.Ty.Int)
    if ok { let _ = c.bit_operand(value, rt, sym, true) }
    return
  }
  let ts = c.shallow(t)
  if ts is types.Ty.Fixed(_) {
    // the runtime's dialect: `+= -= *= /= %=` on a fixed-width number
    match o {
      Add | Sub | Mul | Div | Rem => c.check_operand(value, t, o, target)
      _ => {
        c.err(diag.new("E0260", e.span, "can't apply `{o.symbol()}=` to `{c.show(t)}`"))
        let _ = c.infer(value, none)
      }
    }
    return
  }
  let ok = match o {
    Add => match ts {
      Int | Float | Str | List(_) => true
      _ => false
    }
    _ => is_int_float(ts)
  }
  let numeric = match ts {
    Int | Float | Measured(_, _) => true
    _ => false
  }
  if numeric {
    // units: `d += x` needs `x` in `d`'s unit, `d *= 2.0` keeps it
    let scale = match o {
      Mul | Div => true
      _ => false
    }
    let hint = if scale { types.base(ts) } else { t }
    let rt = c.infer(value, hint)
    if ts is types.Ty.Measured(_, _) || c.shallow(rt) is types.Ty.Measured(_, _) {
      let r = c.unit_operands(e, o, target, value, t, rt)
      if !r.has_error() && !c.unify(r, t) {
        c.mismatch(e, r, t, false)
      }
    } else {
      c.operand_with(value, t, rt, o, target)
    }
  } else if ok {
    c.check_operand(value, t, o, target)
  } else if ts is types.Ty.Named(_, _) {
    let fname = match o {
      Add => "add"
      Sub => "sub"
      Mul => "mul"
      Div => "div"
      _ => "mod"
    }
    let cands = c.method_cands(fname, t, 2)
    if cands.len() > 0 {
      let f = cands[0]
      let (s, targs) = c.instantiate(f)
      let info = c.fns[f]
      let _ = c.unify(info.params[0].ty.subst(s), t)
      let _ = c.check(value, info.params[1].ty.subst(s))
      let r = info.ret.subst(s)
      if !c.unify(r, t) {
        c.mismatch(e, r, t, false)
      }
      c.note_call(
        e.id,
        typed.Call {
          callee: typed.Callee.Fn(f, targs),
          args: [typed.Arg { node: target.id, by_ref: false }, typed.Arg { node: value.id, by_ref: false }],
        },
      )
    } else {
      let s = c.show(t)
      c.err(
        diag.new("E0261", e.span, "`{o.symbol()}=` isn't defined for `{s}`")
          .note("define `fn {fname}(a: {s}, b: {s}): {s}`"),
      )
      let _ = c.infer(value, none)
    }
  } else if ts != types.Ty.Error {
    let s = c.show(t)
    c.err(diag.new("E0260", e.span, "can't apply `{o.symbol()}=` to `{s}`"))
    let _ = c.infer(value, none)
  }
}

// ---- struct literals ----

pub fn struct_lit(c: var check.Checker, e: ast.Expr, path: [ast.Ident], fields: [ast.FieldInit], base: ast.Expr?, exp: check.Exp): types.Ty {
  let m = c.cur_module()
  let found = c.lookup_type_path(m, path)
  var d = -1
  match found {
    some(Def(dd)) => if c.defs.is_struct(dd) { d = dd }
    _ => {}
  }
  if d < 0 {
    let name = path.map(i => i.name).join(".")
    let msg = match found {
      some(_) => "`{name}` is not a struct"
      none => "unknown struct `{name}`"
    }
    let sp = path[0].span.to(path[path.len() - 1].span)
    var dg = diag.new("E0104", sp, msg)
    let cands = c.items[m].types.keys()
    match check.similar(name, cands) {
      some(s) => dg = dg.note("did you mean `{s}`?").fix(sp, s)
      none => {}
    }
    c.err(dg)
    for f in fields {
      match f.value {
        some(v) => {
          let _ = c.infer(v, none)
        }
        none => {}
      }
    }
    return types.Ty.Error
  }
  let (s, args) = c.instantiate_def(d)
  let ty = types.Ty.Named(d, args)
  match check.exp_ty(exp) {
    some(h) => {
      let _ = c.try_unify(ty, h)
    }
    none => {}
  }
  let defs = c.defs.fields(d)
  let foreign = c.defs.types[d].module != m
  if foreign && !c.defs.types[d].public {
    c.err(diag.new("E0120", e.span, "the struct `{c.defs.types[d].name}` is private to module `{c.prog.name(c.defs.types[d].module)}`"))
  }
  var out: [(int, typed.FieldValue)] = []
  var given = defs.map(_ => false)
  for f in fields {
    let fname = f.name.name
    let i = defs.find_index(x => x.name == fname) else {
      let names = defs.map(x => x.name)
      var dg = diag.new("E0225", f.name.span, "the struct `{c.defs.types[d].name}` has no field `{fname}`")
        .note("its fields are: {names.join(", ")}")
      match check.similar(fname, names) {
        some(sim) => dg = dg.fix(f.name.span, sim)
        none => {}
      }
      c.err(dg)
      match f.value {
        some(v) => {
          let _ = c.infer(v, none)
        }
        none => {}
      }
      continue
    }
    if given[i] {
      c.err(diag.new("E0225", f.name.span, "the field `{fname}` is given twice"))
    }
    given[i] = true
    if foreign && !defs[i].public {
      c.err(
        diag.new("E0121", f.name.span, "the field `{fname}` of `{c.defs.types[d].name}` is private")
          .note("a struct with private fields can only be built in its own module; look for a constructor function"),
      )
    }
    let ft = defs[i].ty.subst(s)
    match f.value {
      some(v) => {
        let _ = c.check(v, ft)
        out.push((i, typed.FieldValue.Expr(v.id)))
      }
      none => match c.lookup_local(fname) {
        some(l) => {
          let lt = c.local_ty(l)
          var cs: [typed.Coercion] = []
          if !c.coerce_ty(lt, ft, &cs, f.name.span) {
            let ls = c.show(lt)
            let fs = c.show(ft)
            c.err(diag.new("E0200", f.name.span, "the field `{fname}` is a `{fs}`, but the variable `{fname}` is a `{ls}`"))
          } else if cs.any(co => co is typed.Coercion.ToAny(_)) {
            // a conversion to `any S` needs a node for its vtable
            let fs = c.show(ft)
            c.err(
              diag.new("E0200", f.name.span, "the field `{fname}` is a `{fs}`; the shorthand can't convert the variable `{fname}` to it")
                .note("write the field out: `{fname}: {fname}`"),
            )
          }
          out.push((i, typed.FieldValue.Local(l, cs)))
        }
        none => {
          c.err(
            diag.new("E0102", f.name.span, "`{fname}` (shorthand for `{fname}: {fname}`) is not a variable in scope")
              .note("write `{fname}: value`"),
          )
        }
      }
    }
  }
  match base {
    some(b) => {
      let _ = c.check(b, ty)
    }
    none => {
      var missing: [str] = []
      for i, f in defs {
        if !given[i] { missing.push(f.name) }
      }
      if types.is_raw_def(c.defs, d) {
        // the runtime's dialect: the fields not given are zero (C's `{0}`); a union takes one
        if types.is_union(c.defs, d) && defs.len() - missing.len() > 1 {
          c.err(diag.new("E0224", e.span, "a `raw union` literal gives one field"))
        }
        missing = []
      }
      if missing.len() > 0 {
        let list = missing.map(x => "`{x}`").join(", ")
        c.err(
          diag.new("E0224", e.span, "the struct literal is missing field(s) {list} of `{c.defs.types[d].name}`")
            .note("give every field a value, or copy the rest from another value with `..base`"),
        )
      }
    }
  }
  c.cx.t.struct_lits[e.id] = typed.StructLit { def: d, args, fields: out }
  ty
}

fn is_align(ch: char): bool = ch == '<' || ch == '>' || ch == '^'

/// Rust's `num` closure of `parse_format`: digits at `i`, as a number (none if there are none or
/// they overflow), and the index after them.
fn format_num(cs: [char], i: int): (int?, int) {
  var j = i
  while j < cs.len() && cs[j] >= '0' && cs[j] <= '9' { j += 1 }
  if j == i { return (none, j) }
  match int.parse(str(cs[i..j])) {
    ok(n) => (n, j)
    err(_) => (none, j)
  }
}

/// Parse `[fill? align] ['0'] [width] ['.' precision] [x X o b]`; fails with the reason.
pub fn parse_format(spec: str): typed.FormatSpec! {
  let cs = spec.chars()
  var i = 0
  var fill: char? = none
  var align: char? = none
  if cs.len() >= 2 && is_align(cs[1]) {
    fill = cs[0]
    align = cs[1]
    i = 2
  } else if cs.len() > 0 && is_align(cs[0]) {
    align = cs[0]
    i = 1
  }
  var zero = false
  if i < cs.len() && cs[i] == '0' {
    zero = true
    i += 1
  }
  let (width, i2) = format_num(cs, i)
  i = i2
  var precision: int? = none
  if i < cs.len() && cs[i] == '.' {
    i += 1
    let (p, i3) = format_num(cs, i)
    precision = p
    i = i3
    if precision == none { fail("`.` must be followed by the number of digits") }
  }
  var radix: char? = none
  if i < cs.len() && (cs[i] == 'x' || cs[i] == 'X' || cs[i] == 'o' || cs[i] == 'b') {
    radix = cs[i]
    i += 1
  }
  if i != cs.len() { fail("unexpected `{str(cs[i..cs.len()])}`") }
  if spec.len() == 0 { fail("empty spec (remove the `:`)") }
  typed.FormatSpec { text: spec, fill, align, zero, width, precision, radix }
}

fn bad_format(spec: str): bool = match parse_format(spec) {
  ok(_) => false
  err(_) => true
}

test "format specs" {
  let f = parse_format("-^20.3")!
  assert f.fill == some('-') && f.align == some('^') && !f.zero && f.width == some(20) && f.precision == some(3)
  let g = parse_format("08.2")!
  assert g.fill == none && g.align == none && g.zero && g.width == some(8) && g.precision == some(2)
  let h = parse_format(">5")!
  assert h.align == some('>') && h.width == some(5)
  assert parse_format("08x")!.radix == some('x')
  assert bad_format("e")
  assert bad_format("xb")
  assert bad_format("5.")
  assert bad_format("")
}
