/// Expressions (src/check/expr.rs, up to `place`): bidirectional inference, calls and
/// overloading, names, fields and variants. The rest of expr.rs (places, operators, `?`,
/// `else`, `await`, closures, blocks, loops, `let`, assignment, struct literals) is
/// check_ops.auk; the "inference helpers" (`fresh`, `resolve`, `record`, `note_call`, ...) and
/// `Exp`/`ArgSrc`/`PlaceUse` are in check.auk.
///
/// Every `impl Checker` method is a function taking `c: var check.Checker` (or `c:
/// check.Checker` for `&self`), forwarded from check.auk so that `c.f(..)` reaches it from every
/// check_*.auk file. Rust's `as_path` is `visit.as_path`.

/// Rust's `matches!(t.base(), Int | Float | Bool | Char | Str)`.
pub fn is_prim(t: types.Ty): bool = match types.base(t) {
  Int | Float | Bool | Char | Str => true
  _ => false
}

/// A `0` or `0.0` literal.
pub fn is_zero_lit(e: ast.Expr): bool = match e.kind {
  Lit(Int(n)) => n == 0
  Lit(Float(x)) => x == 0.0
  _ => false
}

/// The integer value of a literal exponent (`2`, `2.0`, `-1`), for `**` on a unit value.
pub fn int_exponent(e: ast.Expr): int? = match e.kind {
  // `i32::try_from(n)` of the literal's u64 bits
  Lit(Int(n)) => if n >= 0 && n <= 2147483647 { n } else { none }
  Lit(Float(x)) => if abs(x) < 1000000.0 && floor(x) == x { int(x) } else { none }
  Unary(Neg, x) => match int_exponent(x) {
    some(n) => -n
    none => none
  }
  _ => none
}

/// How a core function treats the unit of its first argument (`sum([float<m>])` is a
/// `float<m>`): see `unit_rule`.
pub enum UnitRule {
  /// `float(x)`, `int(x)`: the explicit way to drop a unit.
  Strip,
  /// `sum abs floor ceil round`: the result has the argument's unit.
  Keep,
  /// `sqrt`: the result has half of each exponent.
  Root,
}

/// `t` with every plain `int`/`float` in it given unit `u` (`[float]` -> `[float<m>]`).
pub fn put_units(t: types.Ty, u: [(str, int)]): types.Ty = types.map_ty(t, x => match x {
  Int | Float => types.measured(x, u)
  x2 => x2
})

/// The first unit inside `t` (`[float<m>]` -> `m`), or dimensionless (pre-order, like Rust's
/// `walk`).
pub fn first_units(t: types.Ty): [(str, int)] {
  match t {
    Measured(_, v) => return v
    _ => {}
  }
  for ch in types.children(t) {
    let u = first_units(ch)
    if u.len() > 0 { return u }
  }
  []
}

/// Rust's `{:?}` of a string: in double quotes, with `\\ \" \n \t \r \0` escaped and other
/// control chars as `\u{hex}`.
pub fn debug_str(s: str): str {
  var out: [str] = ["\""]
  for ch in s.chars() {
    match ch {
      '\\' => out.push("\\\\")
      '"' => out.push("\\\"")
      '\n' => out.push("\\n")
      '\t' => out.push("\\t")
      '\r' => out.push("\\r")
      _ => {
        let k = int(ch)
        if k == 0 {
          out.push("\\0")
        } else if k < 0x20 || k == 0x7f {
          out.push("\\u{{{k:x}}}")
        } else {
          out.push(str(ch))
        }
      }
    }
  }
  out.push("\"")
  out.join("")
}

/// The `sig_text` of the first `n` functions of `fs`.
fn sigs_of(c: check.Checker, fs: [int], n: int): [str] {
  var out: [str] = []
  for f in fs.take(n) { out.push(c.sig_text(f)) }
  out
}

/// Is `f` core's `fail` intrinsic?
fn is_fail_fn(c: check.Checker, f: int): bool = match c.fns[f].kind {
  Intrinsic(Fail, _) => true
  _ => false
}

/// The empty span at the start of `s` (where a prefix is inserted).
fn start_of(s: diag.Span): diag.Span = diag.Span { end_line: s.line, end_col: s.col, ..s }

// ---- entry points ----

pub fn infer(c: var check.Checker, e: ast.Expr, hint: types.Ty?): types.Ty {
  let exp = match hint {
    some(t) => check.Exp.Hint(t)
    none => check.Exp.None
  }
  c.expr(e, exp)
}

pub fn check(c: var check.Checker, e: ast.Expr, want: types.Ty): types.Ty {
  let have = c.expr(e, check.Exp.Check(want))
  let _ = c.coerce_at(e, have, want, false)
  want
}

/// Check a function body's value against its return type.
pub fn check_tail(c: var check.Checker, e: ast.Expr, want: types.Ty) {
  let have = c.expr(e, check.Exp.Tail(want))
  let _ = c.coerce_at(e, have, want, true)
}

pub fn check_mode(c: var check.Checker, e: ast.Expr, want: types.Ty, tail: bool) {
  let exp = if tail { check.Exp.Tail(want) } else { check.Exp.Check(want) }
  let have = c.expr(e, exp)
  let _ = c.coerce_at(e, have, want, tail)
}

/// A statement whose value is discarded (when `discard`) or used.
pub fn stmt(c: var check.Checker, e: ast.Expr, discard: bool): types.Ty {
  let t = c.expr(e, if discard { check.Exp.Discard } else { check.Exp.None })
  if discard { c.check_unawaited(e, t) }
  t
}

pub fn check_unawaited(c: var check.Checker, e: ast.Expr, t: types.Ty) {
  let st = c.shallow(t)
  let compound = match e.kind {
    Block(_) | If(_, _, _) | Match(_, _) | Loop(_) => true
    _ => false
  }
  if st is types.Ty.Res(_, _) && !compound {
    let ts = c.show(t)
    let ret = match c.frame_ret() {
      some(r) => some(c.shallow(r))
      none => none
    }
    var d = diag.new("E0334", e.span, "the result of `{c.text(e.span)}` is a `{ts}`, and its error is ignored")
    if ret is some(types.Ty.Res(_, _)) {
      d = d.note("add `?` to pass the error up, handle it with `else`, or discard it explicitly with `let _ = ...`")
        .fix(diag.after(e.span), "?")
    } else {
      d = d.note("handle the error with `else` (or unwrap with `!`), or discard it explicitly with `let _ = ...`")
    }
    c.err(d)
    return
  }
  if st is types.Ty.Task(_) {
    c.err(
      diag.new("E0332", e.span, "this `async fn` call is never awaited")
        .note("an `async fn` call must be awaited, stored or returned; `await` it to wait for the result")
        .fix(start_of(e.span), "await "),
    )
  }
}

pub fn expr(c: var check.Checker, e: ast.Expr, exp: check.Exp): types.Ty {
  let t = c.expr_inner(e, exp)
  c.record(e.id, t)
  t
}

// ---- conversions ----

/// Convert `have` to `want` at `e`: unify, or auto-wrap into `T?`/`T!`, or convert to
/// `any S`. Reports a mismatch.
pub fn coerce_at(c: var check.Checker, e: ast.Expr, have: types.Ty, want: types.Ty, tail: bool): bool {
  var cs: [typed.Coercion] = []
  if c.coerce_ty(have, want, &cs, e.span) {
    for co in cs { c.add_coercion(e.id, co) }
    return true
  }
  c.mismatch(e, have, want, tail)
  false
}

pub fn coerce_ty(c: var check.Checker, have: types.Ty, want: types.Ty, out: var [typed.Coercion], span: diag.Span): bool {
  if c.try_unify(have, want) { return true }
  let h = c.shallow(have)
  if h is types.Ty.Var(_) { return false }
  match c.shallow(want) {
    Opt(inner) => if c.coerce_ty(have, inner, &out, span) {
      out.push(typed.Coercion.WrapSome)
      return true
    }
    Res(inner, _) => if c.coerce_ty(have, inner, &out, span) {
      out.push(typed.Coercion.WrapOk)
      return true
    }
    Any(s) => {
      let h2 = c.resolve(h)
      if !(h2 is types.Ty.Any(_)) {
        let name = c.defs.shapes[s].name
        c.defer_fit(h2, s, span, "to convert it to `any {name}`")
        out.push(typed.Coercion.ToAny(s))
        return true
      }
    }
    _ => {}
  }
  false
}

/// Report "expected X, found Y" with the most useful notes and fixes.
pub fn mismatch(c: var check.Checker, e: ast.Expr, have: types.Ty, want: types.Ty, tail: bool) {
  let hs = c.show(have)
  let ws = c.show(want)
  let h = c.resolve(have)
  let w = c.resolve(want)
  if h.has_error() || w.has_error() { return }
  // a missing `?`
  match h {
    Res(inner, _) | Opt(inner) => if c.can_unify(inner, w) {
      let opt = h is types.Ty.Opt(_)
      let ret = match c.frame_ret() {
        some(r) => some(c.shallow(r))
        none => none
      }
      let can_pass = (ret is some(types.Ty.Res(_, _)) && !opt) || (ret is some(types.Ty.Opt(_)) && opt)
      let may = if opt { "missing" } else { "an error" }
      var d = diag.new("E0201", e.span, "expected `{ws}`, found `{hs}`: the value may be {may}")
      if can_pass {
        let what = if opt { "missing value" } else { "error" }
        d = d.note("add `?` to pass the {what} up to the caller").fix(diag.after(e.span), "?")
      } else {
        let need = if opt { "T?" } else { "T!" }
        d = d.note(
          "handle it with `else` (`{c.text(e.span)} else fallback`) or unwrap it with `!`; `?` needs the function to return `{need}`",
        )
      }
      c.err(d)
      return
    }
    _ => {}
  }
  // a missing `await`
  match h {
    Task(inner) => if c.can_unify(inner, w) {
      c.err(
        diag.new("E0333", e.span, "expected `{ws}`, found an un-awaited `async fn` call")
          .note("`await` the call to get its result")
          .fix(start_of(e.span), "await "),
      )
      return
    }
    _ => {}
  }
  var d = diag.new("E0200", e.span, "expected `{ws}`, found `{hs}`")
  let units_only = h != w && types.erase_units(h) == types.erase_units(w)
  if units_only { d = c.unit_mismatch(e.span, h, w) }
  match (h, w) {
    (Int, Float) => match e.kind {
      Lit(Int(n)) => d = d.note("an integer literal is an `int`; write a float literal").fix(e.span, "{token.uint_str(n)}.0")
      _ => d = d.note("there are no implicit conversions; convert with `float(x)`")
        .fix(start_of(e.span), "float(")
        .fix(diag.after(e.span), ")")
    }
    (Float, Int) => d = d.note("there are no implicit conversions; convert with `int(x)` (truncates toward zero)")
    (Char, Str) => match e.kind {
      Lit(Char(ch)) => d = d.note("a char literal uses single quotes; a one-char string uses double quotes")
        .fix(e.span, debug_str(str(ch)))
      _ => d = d.note("convert with `str(c)`")
    }
    (_, Str) => if !(h is types.Ty.Var(_)) { d = d.note("convert with `str(x)` or interpolate: `\"{{x}}\"`") }
    _ => {}
  }
  if tail && units_only {
    d = d.note("the function's return type says `{ws}`")
  } else if tail {
    let fr = c.top_frame()
    let ret_span = match fr {
      some(f) => f.ret_span
      none => none
    }
    let ret_insert = match fr {
      some(f) => f.ret_insert
      none => none
    }
    let open = match h {
      Var(_) | Never => false
      _ => true
    }
    if open && !h.has_vars() {
      match ret_span {
        some(rs) => d = d.note("the function's return type says `{ws}`").fix(rs, hs)
        none => match ret_insert {
          some(at) => if w.is_unit() {
            d = diag.new("E0200", e.span, "this function has no return type, so it returns `()`, but its body is a `{hs}`")
              .note("declare the return type: `: {hs}`")
              .fix(at, ": {hs}")
          }
          none => {}
        }
      }
    }
  }
  c.err(d)
}

// ---- the expression forms ----

pub fn expr_inner(c: var check.Checker, e: ast.Expr, exp: check.Exp): types.Ty {
  match e.kind {
    TypeArgs(x, tys) => check_raw.type_args(&c, x, tys, exp)
    FieldSel(_) => check_raw.field_sel(&c, e)
    Lit(l) => {
      match raw_lit(&c, e, l, false, check.exp_ty(exp)) {
        some(t) => return t
        none => {}
      }
      let t = c.lit(e, l, false)
      c.zero_takes_unit(e, t, check.exp_ty(exp))
    }
    Measured(x, us) => {
      let t = c.infer(x, none)
      types.measured(t, us)
    }
    Interp(parts) => {
      for p in parts {
        match p {
          Expr(x, spec) => c.interp_part(x, spec)
          _ => {}
        }
      }
      types.Ty.Str
    }
    Name(n) => c.name_expr(e, n, exp)
    Hole => match check.exp_ty(exp) {
      some(t) => t
      none => c.fresh()
    }
    Field(x, name) => c.field_expr(e, x, name, exp)
    TupleField(x, index) => {
      let t = c.infer(x, none)
      match c.shallow(t) {
        Tuple(ts) => if index < ts.len() {
          ts[index]
        } else {
          c.err(
            diag.new("E0223", e.span, "the tuple `{c.show(t)}` has no element {index}")
              .note("it has {ts.len()} element(s), numbered from 0"),
          )
          types.Ty.Error
        }
        Error => types.Ty.Error
        Var(_) => c.cant_infer(x.span, "the tuple")
        Opt(i) => if c.shallow(i) is types.Ty.Tuple(_) {
          var d = diag.new("E0223", e.span, "`{c.text(x.span)}` may be missing (`{c.show(t)}`), so it has no element {index}")
            .note("use `?.{index}` to get the element when present (`x?.{index}` is `T?`), or unwrap first with `?`, `!` or `else`")
          let l = x.span.end_line
          let col = x.span.end_col
          if e.span.end_line == l && e.span.end_col == col + 1 + "{index}".len() {
            d = d.fix(diag.Span { line: l, col, end_line: l, end_col: col + 1 }, "?.")
          }
          c.err(d)
          types.Ty.Error
        } else {
          c.err(diag.new("E0223", e.span, "`.{index}` needs a tuple, found `{c.show(t)}`"))
          types.Ty.Error
        }
        _ => {
          c.err(diag.new("E0223", e.span, "`.{index}` needs a tuple, found `{c.show(t)}`"))
          types.Ty.Error
        }
      }
    }
    Call(callee, args) => c.call_expr(e, callee, args, exp)
    MethodCall(recv, name, args) => c.method_call(e, recv, name, args, exp)
    Pipe(lhs, callee, args) => c.pipe_call(e, lhs, callee, args, exp)
    Index(x, index) => c.index_expr(e, x, index)
    Slice(x, lo, hi, _) => {
      let t = c.infer(x, check.exp_ty(exp))
      let _ = c.check(lo, types.Ty.Int)
      let _ = c.check(hi, types.Ty.Int)
      match c.shallow(t) {
        List(_) | Str | Error => t
        Var(_) => c.cant_infer(x.span, "the sliced value")
        _ => {
          c.err(
            diag.new("E0270", e.span, "can't slice a `{c.show(t)}`")
              .note("slices work on lists and strings: `xs[a..b]`, `s[a..b]`"),
          )
          types.Ty.Error
        }
      }
    }
    Unary(op, x) => c.unary(e, op, x, exp)
    Binary(op, lhs, rhs) => c.binary(e, op, lhs, rhs, exp)
    Range(lo, hi, _) => {
      let _ = c.check(lo, types.Ty.Int)
      let _ = c.check(hi, types.Ty.Int)
      types.list(types.Ty.Int)
    }
    Is(x, pat) => {
      let t = c.infer(x, none)
      c.is_pattern(pat, t)
      types.Ty.Bool
    }
    Try(x) => c.try_expr(e, x, exp)
    Unwrap(x) => {
      let vals = match check.exp_ty(exp) {
        some(t) => c.value_cands(t)
        none => []
      }
      let hint = c.wrap_hints(vals)
      let t = c.expr(x, match hint {
        some(hs) => check.Exp.Hints(hs)
        none => check.Exp.None
      })
      match c.shallow(t) {
        Opt(inner) | Res(inner, _) => inner
        Error => types.Ty.Error
        Var(_) => c.cant_infer(x.span, "the unwrapped value")
        _ => {
          c.err(
            diag.new("E0251", e.span, "`!` unwraps a `T?` or `T!`, but this is `{c.show(t)}`")
              .note("remove the `!`")
              .fix(diag.Span { line: e.span.end_line, col: e.span.end_col - 1, ..e.span }, ""),
          )
          t
        }
      }
    }
    OptChain(x, name, args) => c.opt_chain(e, x, name, args, exp)
    Else(x, arm) => c.else_expr(e, x, arm, exp)
    Await(x) => c.await_expr(e, x)
    Catch(x) => c.catch_expr(e, x)
    AwaitAny(x) => c.await_any_expr(e, x)
    Ref(x) => {
      c.err(diag.new("E0311", e.span, "`&` is only for an argument passed to a `var` parameter"))
      c.infer(x, none)
    }
    Closure(params, body) => c.closure(e, params, body, exp)
    If(cond, then, els) => c.if_expr(cond, then, els, exp)
    Match(scrut, arms) => c.match_expr(scrut, arms, exp)
    Loop(b) => {
      let bt = match check.exp_ty(exp) {
        some(t) => if exp is check.Exp.Hint(_) { c.fresh() } else { t }
        none => c.fresh()
      }
      c.push_loop(true, bt)
      let _ = c.block(b, check.Exp.Discard)
      let l = c.pop_loop()
      if l.saw_break { bt } else { types.Ty.Never }
    }
    While(cond, body) => {
      let _ = c.check(cond, types.Ty.Bool)
      c.push_loop(false, types.unit())
      let _ = c.block(body, check.Exp.Discard)
      let _ = c.pop_loop()
      types.unit()
    }
    For(index, pat, iter, body) => {
      c.for_expr(e, index, pat, iter, body)
      types.unit()
    }
    Block(b) => c.block(b, exp)
    Let(mutable, pat, ty, value, els) => {
      c.let_stmt(e, mutable, pat, ty, value, els)
      types.unit()
    }
    Assign(op, target, value) => {
      c.assign(e, op, target, value)
      types.unit()
    }
    Assert(x) => {
      let _ = c.check(x, types.Ty.Bool)
      types.unit()
    }
    Return(x) => {
      let in_catch = match c.top_frame() {
        some(f) => f.what == "catch"
        none => false
      }
      if in_catch {
        c.err(
          diag.new("E0335", e.span, "`return` can't leave a `catch`")
            .note("`catch e` is an expression: its value is `e`'s value; compute it, then `return` after the `catch`"),
        )
        return types.Ty.Never
      }
      match c.frame_ret() {
        none => {
          let what = match c.top_frame() {
            some(f) => f.what
            none => "constant"
          }
          c.err(diag.new("E0246", e.span, "`return` is not allowed in a {what}"))
        }
        some(r) => match x {
          some(v) => c.check_mode(v, r, true)
          none => {
            var cs: [typed.Coercion] = []
            if !c.coerce_ty(types.unit(), r, &cs, e.span) {
              let rs = c.show(r)
              c.err(
                diag.new("E0200", e.span, "`return` without a value, but the function returns `{rs}`")
                  .note("write `return value`"),
              )
            }
            for co in cs { c.add_coercion(e.id, co) }
          }
        }
      }
      types.Ty.Never
    }
    Break(x) => {
      c.break_expr(e, x)
      types.Ty.Never
    }
    Continue => {
      if !c.in_loop() { c.err(diag.new("E0244", e.span, "`continue` outside a loop")) }
      types.Ty.Never
    }
    Peek(x) => {
      let t = c.infer(x, check.exp_ty(exp))
      let r = c.resolve(t)
      c.defer_fit(t, c.b.show, x.span, "to `peek` it")
      if !is_prim(r) { c.note_show(x.id, t) }
      t
    }
    Struct(path, fields, base) => c.struct_lit(e, path, fields, base, exp)
    List(xs) => {
      let et = match check.exp_ty(exp) {
        some(t) => match c.shallow(t) {
          List(t2) => t2
          _ => c.fresh()
        }
        none => c.fresh()
      }
      var first = true
      for x in xs {
        if first && c.shallow(et) is types.Ty.Var(_) {
          let t = c.infer(x, none)
          let _ = c.unify(et, t)
        } else {
          let _ = c.check(x, et)
        }
        first = false
      }
      types.list(et)
    }
    Map(es) => {
      if es.len() == 0 && c.wants_unit(exp) {
        // `{}` is parsed as an empty map; where nothing (`()`) is expected it is an empty
        // block (`_ => {}` in a match). Codegen: a `Map` node of type `()` is a no-op.
        return types.unit()
      }
      let kv = match check.exp_ty(exp) {
        some(t) => match c.shallow(t) {
          Map(k, v) => some((k, v))
          _ => none
        }
        none => none
      }
      let (kt, vt) = match kv {
        some(p) => p
        none => (c.fresh(), c.fresh())
      }
      for (k, v) in es {
        let _ = c.check(k, kt)
        let _ = c.check(v, vt)
      }
      types.map(kt, vt)
    }
    Tuple(xs) => {
      let hint = match check.exp_ty(exp) {
        some(t) => match c.shallow(t) {
          Tuple(ts) => if ts.len() == xs.len() { some(ts) } else { none }
          _ => none
        }
        none => none
      }
      let checking = match exp {
        Check(_) | Tail(_) => true
        _ => false
      }
      var out: [types.Ty] = []
      for i, x in xs {
        out.push(match hint {
          some(ts) => if checking { c.check(x, ts[i]) } else { c.infer(x, ts[i]) }
          none => c.infer(x, none)
        })
      }
      types.Ty.Tuple(out)
    }
  }
}

/// Is the expression's value discarded or expected to be `()` (or `()!`, `()?`)?
pub fn wants_unit(c: check.Checker, exp: check.Exp): bool = match exp {
  Discard => true
  Check(t) | Tail(t) => match c.shallow(t) {
    Opt(i) | Res(i, _) => c.shallow(i).is_unit()
    t2 => t2.is_unit()
  }
  _ => false
}

/// Infer an expression after an error was already reported for its context (arguments of
/// an unknown function, ...): no "can't infer" follow-up errors.
pub fn infer_quiet(c: var check.Checker, e: ast.Expr) {
  c.cx.quiet += 1
  let _ = c.infer(e, none)
  c.cx.quiet -= 1
}

pub fn cant_infer(c: var check.Checker, span: diag.Span, what: str): types.Ty {
  if c.depth > 0 && c.cx.quiet > 0 { return types.Ty.Error }
  c.err(
    diag.new("E0360", span, "can't infer the type of {what} here")
      .note("add a type annotation where it is declared, e.g. `let xs: [int] = []`"),
  )
  types.Ty.Error
}

pub fn lit(c: var check.Checker, e: ast.Expr, l: ast.Lit, negated: bool): types.Ty = match l {
  Int(n) => {
    // `n` holds a u64's bits: above i64::MAX it is negative; 2^63 is i64's minimum
    let too_big = if negated { n < 0 && n != -9223372036854775807 - 1 } else { n < 0 }
    if too_big {
      c.err(
        diag.new("E0210", e.span, "the integer literal {token.uint_str(n)} doesn't fit in an `int`")
          .note("an `int` is 64-bit: -9223372036854775808 to 9223372036854775807"),
      )
    }
    types.Ty.Int
  }
  Float(_) => types.Ty.Float
  Bool(_) => types.Ty.Bool
  Char(_) => types.Ty.Char
  Str(_) => types.Ty.Str
}

/// The runtime's dialect: an integer literal where a fixed-width integer is expected has that
/// type (it must fit), a float literal where `f32` is expected is an `f32`.
pub fn raw_lit(c: var check.Checker, e: ast.Expr, l: ast.Lit, negated: bool, want: types.Ty?): types.Ty? {
  let w = want else return none
  let k = match c.shallow(w) {
    Fixed(k) => k
    _ => return none
  }
  match l {
    Int(n) => if k == types.Fx.F32 { return none } else {
      let bits = types.fx_bits(k)
      let min = -9223372036854775807 - 1
      // `n` holds a u64's bits
      let fits = if types.fx_signed(k) {
        if negated {
          (n >= 0 && (bits == 64 || n <= 1 << (bits - 1))) || n == min
        } else {
          n >= 0 && (bits == 64 || n < 1 << (bits - 1))
        }
      } else {
        (!negated || n == 0) && (bits == 64 || (n >= 0 && n < 1 << bits))
      }
      if !fits {
        let sign = if negated { "-" } else { "" }
        c.err(diag.new("E0210", e.span, "the integer literal {sign}{token.uint_str(n)} doesn't fit in a `{types.fx_name(k)}`"))
      }
      types.Ty.Fixed(k)
    }
    Float(_) => if k == types.Fx.F32 { types.Ty.Fixed(k) } else { none }
    _ => none
  }
}

/// `u8(x)`, `i64(x)`, ... and `int(x)`, `float(x)`, `bool(x)` of a fixed-width number (in the
/// runtime package): a conversion (truncating or extending, by the source's sign). `none`
/// when the call isn't one (then its argument has been inferred: pass it as `ArgSrc.Recv`).
pub fn raw_conv(c: var check.Checker, e: ast.Expr, n: str, arg: ast.Expr): types.Ty? {
  let to = match types.fx_of(n) {
    some(k) => types.Ty.Fixed(k)
    none => match n {
      "int" => types.Ty.Int
      "float" => types.Ty.Float
      "bool" => types.Ty.Bool
      _ => return none
    }
  }
  let t = c.infer(arg, none)
  let from = c.resolve(t)
  if !(to is types.Ty.Fixed(_)) && !(from is types.Ty.Fixed(_)) { return none }
  let ok = match from {
    Int | Float | Bool | Char | Fixed(_) | Error | Never => true
    _ => false
  }
  if !ok {
    c.err(
      diag.new("E0260", arg.span, "can't convert `{c.show(t)}` to `{c.show(to)}`")
        .note("conversions are between numbers (`int`, `float`, the fixed-width types), `bool` and `char`"),
    )
  }
  c.cx.t.raw[e.id] = typed.RawNode.Conv(to)
  to
}

/// A literal `0` / `0.0` where a number with a unit is expected takes that unit (zero is
/// zero in every unit); any other plain literal is dimensionless.
pub fn zero_takes_unit(c: var check.Checker, e: ast.Expr, t: types.Ty, want: types.Ty?): types.Ty {
  if is_zero_lit(e) {
    match want {
      some(w) => match c.resolve(w) {
        Measured(b, u) => if b == t { return types.Ty.Measured(b, u) }
        _ => {}
      }
      none => {}
    }
  }
  t
}

// ---- names ----

pub fn name_expr(c: var check.Checker, e: ast.Expr, n: str, exp: check.Exp): types.Ty {
  match c.lookup_local(n) {
    some(l) => {
      c.cx.t.names[e.id] = typed.NameRef.Local(l)
      return c.local_ty(l)
    }
    none => {}
  }
  let m = c.cur_module()
  match c.item_value(e, m, m, n, exp) {
    some(t) => return t
    none => {}
  }
  let core = c.prog.core_root
  if n == "none" {
    c.cx.t.names[e.id] = typed.NameRef.None
    let t = c.fresh()
    return types.opt(t)
  }
  if m != core {
    let hint = c.variant_hint(exp)
    if c.value_variant_clash(e.span, n, hint) { return types.Ty.Error }
  }
  match c.item_value(e, m, core, n, exp) {
    some(t) => return t
    none => {}
  }
  // `regex` alone means `regex.regex`
  match c.prog.first_segment(m, n) {
    some(target) => match c.item_value(e, m, target, n, exp) {
      some(t) => return t
      none => {}
    }
    none => {}
  }
  c.unknown_name(e.span, n, false)
}

/// A constant, function value or variant named `n` in module `target`, seen from `m`.
pub fn item_value(c: var check.Checker, e: ast.Expr, m: int, target: int, n: str, exp: check.Exp): types.Ty? {
  match c.items[target].globals.get(n) {
    some(g) => if target == m || c.globals[g].public {
      c.cx.t.names[e.id] = typed.NameRef.Global(g)
      return c.globals[g].ty
    }
    none => {}
  }
  match c.items[target].consts.get(n) {
    some(k) => if target == m || c.consts[k].public {
      c.ensure_const(k)
      c.cx.t.names[e.id] = typed.NameRef.Const(k)
      return c.consts[k].ty
    }
    none => {}
  }
  let fs = c.fns_in(m, target, n)
  if fs.len() > 0 {
    let want = match check.exp_ty(exp) {
      some(t) => some(c.shallow(t))
      none => none
    }
    var f = fs[0]
    var fn_wanted = false
    match want {
      some(Fn(ps, _)) => {
        fn_wanted = true
        for g in fs {
          if c.fns[g].params.len() == ps.len() {
            f = g
            break
          }
        }
      }
      _ => {}
    }
    if fs.len() > 1 && !fn_wanted {
      c.err(
        diag.new("E0301", e.span, "`{n}` is overloaded, so it can't be used as a value here")
          .note("wrap it in a closure, e.g. `x => {n}(x)`"),
      )
      return types.Ty.Error
    }
    let (s, args) = c.instantiate(f)
    let info = c.fns[f]
    // a `var` parameter stays one in the function's type: `(var P) => R`
    var ps: [types.Ty] = []
    for p in info.params {
      ps.push(if p.var_ { types.Ty.Mut(p.ty.subst(s)) } else { p.ty.subst(s) })
    }
    let r = info.ret.subst(s)
    c.cx.t.names[e.id] = typed.NameRef.Fn(f, args)
    c.cx.callees[f] = true
    c.note_fn_ref(e.id, m)
    return types.func(ps, r)
  }
  let hint = c.variant_hint(exp)
  match c.variant_candidates(target, n, hint, target != m) {
    some((d, i)) => return c.variant_value(e, d, i, hint)
    none => {}
  }
  none
}

/// The type that picks a bare variant name: the expected type, looking through `T?`, `T!`
/// and `T!E` (a plain value converts to them), so `fn f(): tok.Tok? = Eof` finds `Tok.Eof`.
pub fn variant_hint(c: check.Checker, exp: check.Exp): types.Ty? {
  let t0 = check.exp_ty(exp)?
  var t = c.shallow(t0)
  loop {
    match t {
      Opt(inner) | Res(inner, _) => t = c.shallow(inner)
      _ => return t
    }
  }
}

/// A bare `n` that would resolve to core's `Value.n` (`Int`, `Float`, `Str`, ...) while the
/// expected type is another enum, or while nothing is expected and an enum of this package
/// has a variant `n` too: report it (E0117) instead of silently building a `Value`. Returns
/// whether it reported.
pub fn value_variant_clash(c: var check.Checker, span: diag.Span, n: str, hint: types.Ty?): bool {
  let core = c.prog.core_root
  let value = c.b.value
  let vs = c.items[core].variants.get(n) else []
  var is_value_variant = false
  for v in vs {
    if v.0 == value { is_value_variant = true }
  }
  if !is_value_variant { return false }
  match hint {
    some(Named(d, _)) => {
      if d == value || !c.defs.is_enum(d) { return false }
      let tn = c.defs.types[d].name
      let names = c.defs.variants(d).map(v => v.name)
      var dg = diag.new("E0117", span, "`{tn}` has no variant `{n}`")
        .note("a bare `{n}` is core's `Value.{n}` only where a `Value` is expected; write `Value.{n}` for that")
      match check.similar(n, names) {
        some(s) => dg = dg.note("did you mean `{s}`?").fix(span, s)
        none => {}
      }
      c.err(dg)
      true
    }
    none | some(Var(_)) => {
      let m = c.cur_module()
      let pkg = c.prog.mods[m].pkg
      let root = c.prog.pkgs[pkg].root
      var found: (int, str)? = none
      for o, md in c.prog.mods {
        if md.pkg != pkg || o == m { continue }
        match c.items[o].variants.get(n) {
          some(ovs) => {
            var hit: int? = none
            for v in ovs {
              if c.defs.types[v.0].public {
                hit = v.0
                break
              }
            }
            match hit {
              some(d) => {
                found = (o, c.defs.types[d].name)
                break
              }
              none => {}
            }
          }
          none => {}
        }
      }
      let (o, tn) = found else return false
      let rp = c.prog.mods[root].path
      let op = c.prog.mods[o].path
      let prefixed = op.len() > rp.len() && op.take(rp.len()) == rp
      let rel = if prefixed { op.skip(rp.len()).join(".") } else { op.join(".") }
      c.err(
        diag.new("E0117", span, "`{n}` could be `{rel}.{n}` (a `{tn}`) or core's `Value.{n}`")
          .note("nothing here says which type is expected; write `{rel}.{n}`, or `Value.{n}` for core's `Value`")
          .fix(span, "{rel}.{n}"),
      )
      true
    }
    _ => false
  }
}

/// Variants named `n` in module `target` (or core's when `target` is core), preferring one
/// of the hinted enum type.
pub fn variant_candidates(c: check.Checker, target: int, n: str, hint: types.Ty?, need_pub: bool): (int, int)? {
  // the expected type picks the variant, even one of another module's (pub) enum
  let cur = c.cur_module()
  match hint {
    some(Named(d, _)) => if c.defs.is_enum(d) {
      match c.defs.variants(d).find_index(v => v.name == n) {
        some(i) => {
          let td = c.defs.types[d]
          if (td.public || td.module == cur) && (target == cur || td.module == target) { return (d, i) }
        }
        none => {}
      }
    }
    _ => {}
  }
  let vs = c.items[target].variants.get(n) else []
  for v in vs {
    if !need_pub || c.defs.types[v.0].public { return v }
  }
  none
}

pub fn variant_value(c: var check.Checker, e: ast.Expr, d: int, i: int, hint: types.Ty?): types.Ty {
  let (s, args) = c.instantiate_def(d)
  let ty = types.Ty.Named(d, args)
  match hint {
    some(h) => {
      let _ = c.try_unify(ty, h)
    }
    none => {}
  }
  c.cx.t.names[e.id] = typed.NameRef.Variant(typed.VariantRef { def: d, index: i, args })
  let fields = c.defs.variants(d)[i].fields.map(f => f.1.subst(s))
  if fields.len() == 0 { ty } else { types.func(fields, ty) }
}

pub fn instantiate_def(c: var check.Checker, d: int): ({int: types.Ty}, [types.Ty]) {
  let params = c.defs.types[d].params
  var s: {int: types.Ty} = {}
  var args: [types.Ty] = []
  for p in params {
    let v = c.fresh()
    args.push(v)
    s[p] = v
  }
  (s, args)
}

/// Fresh type arguments for a function's generics.
pub fn instantiate(c: var check.Checker, f: int): ({int: types.Ty}, [types.Ty]) {
  let gens = c.fns[f].generics
  var s: {int: types.Ty} = {}
  var args: [types.Ty] = []
  for g in gens {
    let v = c.fresh()
    args.push(v)
    s[g] = v
  }
  (s, args)
}

pub fn unknown_name(c: var check.Checker, span: diag.Span, n: str, call: bool): types.Ty {
  let m = c.cur_module()
  var cands: [str] = []
  if c.depth > 0 {
    for s in c.cx.scopes {
      for k, _ in s { cands.push(k) }
    }
  }
  for k, _ in c.items[m].fns { cands.push(k) }
  for k, _ in c.items[m].consts { cands.push(k) }
  let core = c.prog.core_root
  for k, v in c.items[core].fns {
    var public = false
    for f in v {
      if c.fns[f].public { public = true }
    }
    if public { cands.push(k) }
  }
  let what = if call { "function" } else { "name" }
  var d = diag.new("E0102", span, "unknown {what} `{n}`")
  let is_type = c.items[m].types.get(n) is some(check.TypeItem.Def(_))
  if is_type {
    d = d.note("`{n}` is a type; build a value with `{n} {{ ... }}`")
  } else if c.binding.contains(n) {
    d = d.note("a closure can't refer to `{n}`, the name it is being bound to; write a top-level `fn {n}` to recurse")
  } else if n == "old" {
    d = d.note("`old(e)` is only available in `ensures`")
  } else if n == "result" {
    d = d.note("`result` is only available in `ensures`")
  } else {
    match check.similar(n, cands) {
      some(s) => d = d.note("did you mean `{s}`?").fix(span, s)
      none => if c.prog.first_segment(m, n) is none && call {
        d = d.note("functions of other modules and packages are called by path, e.g. `json.parse(s)`; dependencies are listed in raft.toml")
      }
    }
  }
  c.err(d)
  types.Ty.Error
}

// ---- fields and paths ----

pub fn field_expr(c: var check.Checker, e: ast.Expr, base: ast.Expr, name: ast.Ident, exp: check.Exp): types.Ty {
  let m = c.cur_module()
  match visit.as_path(base) {
    some(path) => {
      let target = match c.expr_path(m, path) {
        Module(t) => some(t)
        Value => none
        Ambiguous => return types.Ty.Error
      }
      match target {
        some(tg) => {
          match c.item_value(e, m, tg, name.name, exp) {
            some(t) => return t
            none => {}
          }
          var d = diag.new("E0102", name.span, "module `{c.prog.name(tg)}` has no public item `{name.name}`")
          var cands: [str] = []
          for k, _ in c.items[tg].fns { cands.push(k) }
          for k, _ in c.items[tg].consts { cands.push(k) }
          match check.similar(name.name, cands) {
            some(s) => d = d.note("did you mean `{s}`?").fix(name.span, s)
            none => {}
          }
          c.err(d)
          return types.Ty.Error
        }
        none => {}
      }
      // `Shape.Circle`
      let not_local = path.len() > 1 || c.lookup_local(path[0].name) is none
      if not_local {
        match c.lookup_type_path(m, path) {
          some(Def(d)) => if c.defs.is_enum(d) {
            match c.defs.variants(d).find_index(v => v.name == name.name) {
              some(i) => {
                let hint = match check.exp_ty(exp) {
                  some(t) => some(c.shallow(t))
                  none => none
                }
                return c.variant_value(e, d, i, hint)
              }
              none => {}
            }
            c.err(diag.new("E0102", name.span, "the enum `{c.defs.types[d].name}` has no variant `{name.name}`"))
            return types.Ty.Error
          }
          _ => {}
        }
      }
    }
    none => {}
  }
  let t = c.infer(base, none)
  c.field_of(e, base, t, name)
}

/// The type of field `name` of a value of type `t` (`e` is the field expression).
pub fn field_of(c: var check.Checker, e: ast.Expr, base: ast.Expr, t: types.Ty, name: ast.Ident): types.Ty {
  let st = c.shallow(t)
  match st {
    Named(d, args) => if c.defs.is_struct(d) {
      let fields = c.defs.fields(d)
      let i = fields.find_index(f => f.name == name.name) else {
        let names = fields.map(f => f.name)
        var dg = diag.new("E0221", name.span, "the struct `{c.defs.types[d].name}` has no field `{name.name}`")
          .note("its fields are: {names.join(", ")}")
        match check.similar(name.name, names) {
          some(s) => dg = dg.fix(name.span, s)
          none => {}
        }
        c.err(dg)
        return types.Ty.Error
      }
      let dm = c.defs.types[d].module
      if dm != c.cur_module() && !fields[i].public {
        let why = if c.defs.types[d].public { "its type is private to that module" } else { "the struct is not `pub`" }
        c.err(
          diag.new(
            "E0121",
            name.span,
            "the field `{name.name}` of `{c.defs.types[d].name}` is private to module `{c.prog.name(dm)}`",
          ).note("fields of another module's struct are readable when the struct is `pub`; here {why}"),
        )
      }
      c.cx.t.fields[e.id] = (d, i)
      let s = c.defs.subst_of(d, args)
      return fields[i].ty.subst(s)
    }
    Opt(_) => {
      var d = diag.new(
        "E0222",
        e.span,
        "`{c.text(base.span)}` may be missing (`{c.show(t)}`), so it has no field `{name.name}`",
      ).note("use `?.` to get the field when present (`x?.f` is `T?`), or unwrap first with `?`, `!` or `else`")
      if name.span.line == base.span.end_line && name.span.col == base.span.end_col + 1 {
        d = d.fix(
          diag.Span { line: base.span.end_line, col: base.span.end_col, end_line: base.span.end_line, end_col: base.span.end_col + 1 },
          "?.",
        )
      }
      c.err(d)
      return types.Ty.Error
    }
    Res(_, _) => {
      c.err(
        diag.new(
          "E0201",
          e.span,
          "`{c.text(base.span)}` may be an error (`{c.show(t)}`), so it has no field `{name.name}`",
        )
          .note("pass the error up with `?` first: `(x?).f`... or `x?.f` is only for optionals")
          .fix(diag.after(base.span), "?"),
      )
      return types.Ty.Error
    }
    Error => return types.Ty.Error
    Var(_) => return c.cant_infer(base.span, "`{c.text(base.span)}`")
    Ptr(_) => match check_raw.ptr_field(&c, e, st, name) {
      some(t) => return t
      none => {}
    }
    _ => {}
  }
  let s = c.defs.show(c.resolve(st))
  c.err(
    diag.new("E0221", name.span, "`{s}` has no field `{name.name}`")
      .note("only structs have named fields; to call a function write `x.f()`"),
  )
  types.Ty.Error
}

// ---- calls ----

pub fn call_expr(c: var check.Checker, e: ast.Expr, callee: ast.Expr, args: [ast.Expr], exp: check.Exp): types.Ty {
  let direct = c.cx.direct_await
  c.cx.direct_await = false
  let srcs = args.map(a => check.ArgSrc.Expr(a))
  match callee.kind {
    Name(n) => {
      match c.lookup_local(n) {
        some(l) => {
          c.cx.t.names[callee.id] = typed.NameRef.Local(l)
          let ft = c.local_ty(l)
          c.record(callee.id, ft)
          return c.closure_call(e, callee, ft, srcs)
        }
        none => {}
      }
      if c.cx.in_ensures && n == "old" && args.len() == 1 {
        let t = c.infer(args[0], check.exp_ty(exp))
        c.cx.olds.push(args[0].id)
        return t
      }
      let m = c.cur_module()
      if args.len() == 1 && c.prog.raw_ok(m) && c.fns_in(m, m, n).len() == 0 {
        let is_conv = types.fx_of(n) != none || n == "int" || n == "float" || n == "bool"
        if is_conv {
          match raw_conv(&c, e, n, args[0]) {
            some(t) => return t
            none => return c.named_call(e, callee, n, [check.ArgSrc.Recv(args[0])], exp, direct)
          }
        }
      }
      return c.named_call(e, callee, n, srcs, exp, direct)
    }
    Field(_, _) => match visit.as_path(callee) {
      some(path) => {
        let m = c.cur_module()
        let last = path[path.len() - 1]
        let prefix = path.take(path.len() - 1)
        match c.expr_path(m, prefix) {
          Module(target) => return c.path_call(e, target, last, srcs, exp, direct)
          Ambiguous => return c.quiet_args(srcs)
          Value => {}
        }
      }
      none => {}
    }
    _ => {}
  }
  let ft = c.infer(callee, none)
  c.closure_call(e, callee, ft, srcs)
}

/// `f(args)` with a bare name: module functions, then variants, then core, then the
/// `regex(p)` = `regex.regex(p)` rule.
pub fn named_call(c: var check.Checker, e: ast.Expr, callee: ast.Expr, n: str, args: [check.ArgSrc], exp: check.Exp, direct: bool): types.Ty {
  let m = c.cur_module()
  let core = c.prog.core_root
  let hint = c.variant_hint(exp)
  var local_fns = c.fns_in(m, m, n)
  if local_fns.len() > 0 {
    // A module function overloads a same-named core function instead of hiding it (spec:
    // overloading is by parameter count or first-parameter type): with `fn to_value(d: D):
    // Value` defined, `to_value(w)` of another type still reaches core's generic `to_value`.
    // `call_fns` prefers the module's own overloads whenever one takes the arguments, so a
    // same-signature module function still wins: a module `fn from_value(v: Value): D!` takes
    // every `from_value(v)` there (core's has the same first parameter, `Value`), and other
    // types need `core.from_value(v)`.
    if m != core {
      let core_fns = c.fns_in(m, core, n)
      var has_fail = false
      for f in core_fns {
        if is_fail_fn(c, f) { has_fail = true }
      }
      if !has_fail { local_fns = local_fns + core_fns }
    }
    return c.call_fns(e, callee.span, n, local_fns, args, exp, direct)
  }
  match c.variant_candidates(m, n, hint, false) {
    some((d, i)) => return c.variant_call(e, d, i, args, hint)
    none => {}
  }
  match c.items[m].consts.get(n) {
    some(k) => {
      c.ensure_const(k)
      let ft = c.consts[k].ty
      c.cx.t.names[callee.id] = typed.NameRef.Const(k)
      c.record(callee.id, ft)
      return c.closure_call(e, callee, ft, args)
    }
    none => {}
  }
  let core_fns = c.fns_in(m, core, n)
  if core_fns.len() > 0 {
    for f in core_fns {
      if is_fail_fn(c, f) { return c.fail_call(e, args) }
    }
    return c.call_fns(e, callee.span, n, core_fns, args, exp, direct)
  }
  if m != core && c.value_variant_clash(callee.span, n, hint) { return c.quiet_args(args) }
  match c.variant_candidates(core, n, hint, m != core) {
    some((d, i)) => return c.variant_call(e, d, i, args, hint)
    none => {}
  }
  match c.prog.first_segment(m, n) {
    some(target) => {
      let fs = c.fns_in(m, target, n)
      if fs.len() > 0 { return c.call_fns(e, callee.span, n, fs, args, exp, direct) }
    }
    none => {}
  }
  let _ = c.unknown_name(callee.span, n, true)
  for a in args {
    match a {
      Expr(x) => c.infer_quiet(x)
      _ => {}
    }
  }
  types.Ty.Error
}

/// After an error that stops a call from resolving: infer the arguments without reporting
/// anything more about the call.
pub fn quiet_args(c: var check.Checker, args: [check.ArgSrc]): types.Ty {
  for a in args {
    match a {
      Expr(x) => c.infer_quiet(x)
      _ => {}
    }
  }
  types.Ty.Error
}

/// `module.f(args)`: functions and variant constructors of that module.
pub fn path_call(c: var check.Checker, e: ast.Expr, target: int, name: ast.Ident, args: [check.ArgSrc], exp: check.Exp, direct: bool): types.Ty {
  let m = c.cur_module()
  if some(target) == c.prog.raw_module() && check_raw.is_special(name.name) {
    return check_raw.special(&c, e, target, name, args)
  }
  let fs = c.fns_in(m, target, name.name)
  if fs.len() > 0 { return c.call_fns(e, name.span, name.name, fs, args, exp, direct) }
  let hint = c.variant_hint(exp)
  match c.variant_candidates(target, name.name, hint, target != m) {
    some((d, i)) => return c.variant_call(e, d, i, args, hint)
    none => {}
  }
  let private = c.items[target].fns.get(name.name) is some(_)
  var d = if private {
    diag.new("E0120", name.span, "`{name.name}` is private to module `{c.prog.name(target)}`")
      .note("mark it `pub` to call it from other modules")
  } else {
    diag.new("E0102", name.span, "module `{c.prog.name(target)}` has no function `{name.name}`")
  }
  if !private {
    var cands: [str] = []
    for k, v in c.items[target].fns {
      var ok = false
      for f in v {
        if c.fns[f].public || target == m { ok = true }
      }
      if ok { cands.push(k) }
    }
    match check.similar(name.name, cands) {
      some(s) => d = d.note("did you mean `{s}`?").fix(name.span, s)
      none => {}
    }
  }
  c.err(d)
  for a in args {
    match a {
      Expr(x) => c.infer_quiet(x)
      _ => {}
    }
  }
  types.Ty.Error
}

pub fn method_call(c: var check.Checker, e: ast.Expr, recv: ast.Expr, name: ast.Ident, args: [ast.Expr], exp: check.Exp): types.Ty {
  let direct = c.cx.direct_await
  c.cx.direct_await = false
  let m = c.cur_module()
  let srcs = args.map(a => check.ArgSrc.Expr(a))
  match visit.as_path(recv) {
    some(path) => {
      match c.expr_path(m, path) {
        Module(target) => return c.path_call(e, target, name, srcs, exp, direct)
        Ambiguous => return c.quiet_args(srcs)
        Value => {}
      }
      let not_local = path.len() > 1 || c.lookup_local(path[0].name) is none
      if not_local {
        match c.lookup_type_path(m, path) {
          some(Def(d)) => if c.defs.is_enum(d) {
            match c.defs.variants(d).find_index(v => v.name == name.name) {
              some(i) => {
                let hint = match check.exp_ty(exp) {
                  some(t) => some(c.shallow(t))
                  none => none
                }
                return c.variant_call(e, d, i, srcs, hint)
              }
              none => {}
            }
          }
          _ => {}
        }
      }
    }
    none => {}
  }
  let rt = c.infer(recv, none)
  let all = [check.ArgSrc.Recv(recv)] + srcs
  c.dot_call(e, recv, rt, name, all, exp, direct)
}

/// `recv.name(args)` once the receiver's type is known: a shape method on a type parameter
/// or `any S`, else UFCS lookup by type.
pub fn dot_call(c: var check.Checker, e: ast.Expr, recv: ast.Expr, rt: types.Ty, name: ast.Ident, args: [check.ArgSrc], exp: check.Exp, direct: bool): types.Ty {
  let r = c.shallow(rt)
  match r {
    Error => {
      for a in args.skip(1) { c.infer_quiet(check.arg_expr(a)) }
      return types.Ty.Error
    }
    Var(_) => {
      for a in args.skip(1) { c.infer_quiet(check.arg_expr(a)) }
      return c.cant_infer(recv.span, "`{c.text(recv.span)}` before calling `.{name.name}()`")
    }
    Param(p) => {
      let bounds = c.defs.params[p].bounds
      for s in bounds {
        match c.defs.shapes[s].methods.find_index(x => x.name == name.name) {
          some(i) => return c.shape_call(e, s, i, r, typed.Callee.Shape(s, i, r), args)
          none => {}
        }
      }
    }
    Any(s) => match c.defs.shapes[s].methods.find_index(x => x.name == name.name) {
      some(i) => return c.shape_call(e, s, i, r, typed.Callee.Vtable(s, i), args)
      none => {}
    }
    _ => {}
  }
  var cands = c.method_cands(name.name, rt, args.len())
  // a tier whose candidates can't take the other arguments (a closure for an `int`, ...)
  // doesn't hide the next tier: `fn find(xs: [User], id: int)` calling `xs.find(u => ..)`
  // reaches core's `find`
  if cands.len() > 0 {
    let rest = args.skip(1)
    var none_plausible = true
    for f in cands {
      if c.args_plausible(f, rest) { none_plausible = false }
    }
    if none_plausible {
      let first = cands
      cands = c.method_cands_after(name.name, rt, args.len(), first, rest)
      if cands.len() == 0 { cands = first }
    }
  }
  if cands.len() == 0 {
    let m = c.cur_module()
    let ts = c.show(rt)
    var d = diag.new("E0103", name.span, "no function `{name.name}` takes a `{ts}` first ({args.len()} argument(s))")
    var any_named: [int] = []
    for t in c.method_tiers(rt) { any_named = any_named + c.fns_in(m, t, name.name) }
    let inner = match r {
      Opt(i) | Res(i, _) => some(i)
      _ => none
    }
    let inner_fits = match inner {
      some(i) => c.method_cands(name.name, i, args.len()).len() > 0
      none => false
    }
    if inner_fits {
      let rs = c.text(recv.span)
      if r is types.Ty.Opt(_) {
        d = d.note("`{rs}` may be missing (`{ts}`); `?.{name.name}(..)` calls it when present")
        if name.span.line == recv.span.end_line && name.span.col == recv.span.end_col + 1 {
          d = d.fix(
            diag.Span { line: recv.span.end_line, col: recv.span.end_col, end_line: recv.span.end_line, end_col: recv.span.end_col + 1 },
            "?.",
          )
        }
      } else {
        d = d.note("`{rs}` may be an error (`{ts}`); pass it up with `?` first").fix(diag.after(recv.span), "?")
      }
    } else if any_named.len() > 0 {
      let sigs = sigs_of(c, any_named, 4)
      d = d.note("`{name.name}` exists, but for other types or arities: {sigs.join("; ")}")
    } else {
      var names: [str] = []
      for t in c.method_tiers(rt) {
        let entries = c.items[t].fns
        for k, v in entries {
          var ok = false
          for f in v {
            if ok { break }
            if !(c.fns[f].public || t == m) || c.fns[f].params.len() == 0 { continue }
            let p0 = c.fns[f].params[0].ty
            if c.cx_can_unify_param(f, p0, rt) { ok = true }
          }
          if ok { names.push(k) }
        }
      }
      match check.similar(name.name, names) {
        some(s) => d = d.note("did you mean `{s}`?").fix(name.span, s)
        none => match r {
          Named(dd, _) => if c.defs.is_struct(dd) && c.defs.fields(dd).any(f => f.name == name.name) {
            d = d.note("`{name.name}` is a field; read it without parentheses: `x.{name.name}`")
          }
          _ => {}
        }
      }
    }
    c.err(d)
    for a in args.skip(1) { c.infer_quiet(check.arg_expr(a)) }
    return types.Ty.Error
  }
  c.call_fns(e, name.span, name.name, cands, args, exp, direct)
}

/// Like `cx_can_unify_param`, ignoring units (`abs(d)` for a `float<m>` finds
/// `abs(x: float)`; a unit mismatch is reported once the call is chosen).
pub fn cx_can_unify_param_loose(c: var check.Checker, f: int, p: types.Ty, t: types.Ty): bool {
  let rt = c.resolve(t)
  rt.has_units() && c.cx_can_unify_param(f, types.erase_units(p), types.erase_units(rt))
}

/// How core function `f` treats a unit on its first argument, if it is unit-aware.
pub fn unit_rule(c: check.Checker, f: int): UnitRule? {
  let info = c.fns[f]
  if info.module != c.prog.core_root { return none }
  match info.name {
    "float" | "int" => if info.params.len() == 1 { UnitRule.Strip } else { none }
    "sum" | "abs" | "floor" | "ceil" | "round" => UnitRule.Keep
    "sqrt" => UnitRule.Root
    _ => none
  }
}

pub fn cx_can_unify_param(c: var check.Checker, f: int, p: types.Ty, t: types.Ty): bool {
  let snap = types.snapshot(c.cx.inf)
  let (s, _) = c.instantiate(f)
  let ok = c.unify(p.subst(s), t)
  types.rollback(&c.cx.inf, snap)
  ok
}

/// The modules searched for a dot call on a value of type `t`: the current module, the
/// module that defines `t`, then core.
pub fn method_tiers(c: check.Checker, t: types.Ty): [int] {
  let m = c.cur_module()
  var tiers = [m]
  match c.resolve(t) {
    Named(d, _) => {
      let home = c.defs.types[d].module
      if !tiers.contains(home) { tiers.push(home) }
    }
    Ptr(_) | CFn(_, _) | Fixed(_) => match c.prog.raw_module() {
      some(r) => if !tiers.contains(r) { tiers.push(r) }
      none => {}
    }
    _ => {}
  }
  let core = c.prog.core_root
  if !tiers.contains(core) { tiers.push(core) }
  tiers
}

/// Functions `name` with `nargs` parameters whose first parameter accepts `t`, from the
/// first tier that has any.
pub fn method_cands(c: var check.Checker, name: str, t: types.Ty, nargs: int): [int] {
  let m = c.cur_module()
  for tier in c.method_tiers(t) {
    var named: [int] = []
    for f in c.fns_in(m, tier, name) {
      if c.fns[f].params.len() == nargs { named.push(f) }
    }
    var cands: [int] = []
    for f in named {
      let p0 = c.fns[f].params[0].ty
      if c.cx_can_unify_param(f, p0, t) { cands.push(f) }
    }
    if cands.len() == 0 {
      for f in named {
        let p0 = c.fns[f].params[0].ty
        if c.cx_can_unify_param_loose(f, p0, t) { cands.push(f) }
      }
    }
    if cands.len() > 0 { return cands }
  }
  []
}

/// Can `f`'s parameters 1.. plausibly take these arguments? (A cheap syntactic test: a
/// closure needs a function parameter; a literal needs its own primitive type.)
pub fn args_plausible(c: check.Checker, f: int, rest: [check.ArgSrc]): bool {
  let ps = c.fns[f].params
  for k, a in rest {
    if k + 1 >= ps.len() { break }
    let p = ps[k + 1]
    let e = check.arg_expr(a)
    let generic = p.ty is types.Ty.Param(_)
    let ok = match e.kind {
      Closure(_, _) => generic || p.ty is types.Ty.Fn(_, _)
      Lit(l) => {
        let lt = match l {
          Int(_) => types.Ty.Int
          Float(_) => types.Ty.Float
          Bool(_) => types.Ty.Bool
          Char(_) => types.Ty.Char
          Str(_) => types.Ty.Str
        }
        match p.ty {
          Opt(t) | Res(t, _) => t == lt || t is types.Ty.Param(_)
          t => t == lt || generic || !is_prim(t)
        }
      }
      _ => true
    }
    if !ok { return false }
  }
  true
}

/// Like `method_cands`, from the tiers after the one that produced `skip`, keeping only
/// candidates whose arguments are plausible.
pub fn method_cands_after(c: var check.Checker, name: str, t: types.Ty, nargs: int, skip: [int], rest: [check.ArgSrc]): [int] {
  let m = c.cur_module()
  let tiers = c.method_tiers(t)
  var start = tiers.len()
  for i, tier in tiers {
    var hit = false
    for f in skip {
      if c.fns[f].module == tier { hit = true }
    }
    if hit {
      start = i + 1
      break
    }
  }
  for tier in tiers.skip(start) {
    var named: [int] = []
    for f in c.fns_in(m, tier, name) {
      if c.fns[f].params.len() == nargs { named.push(f) }
    }
    var cands: [int] = []
    for f in named {
      let p0 = c.fns[f].params[0].ty
      if c.cx_can_unify_param(f, p0, t) && c.args_plausible(f, rest) { cands.push(f) }
    }
    if cands.len() > 0 { return cands }
  }
  []
}

pub fn sig_text(c: check.Checker, f: int): str {
  let i = c.fns[f]
  var ps: [str] = []
  for p in i.params {
    let v = if p.var_ { "var " } else { "" }
    ps.push("{v}{c.defs.show(p.ty)}")
  }
  let r = if i.ret.is_unit() { "" } else { ": {c.defs.show(i.ret)}" }
  "{i.name}({ps.join(", ")}){r}"
}

pub fn pipe_call(c: var check.Checker, e: ast.Expr, lhs: ast.Expr, callee: ast.Expr, args: [ast.Expr], exp: check.Exp): types.Ty {
  let direct = c.cx.direct_await
  c.cx.direct_await = false
  let m = c.cur_module()
  let all = [check.ArgSrc.Recv(lhs)] + args.map(a => check.ArgSrc.Expr(a))
  let _ = c.infer(lhs, none)
  match callee.kind {
    Name(n) => {
      match c.lookup_local(n) {
        some(l) => {
          c.cx.t.names[callee.id] = typed.NameRef.Local(l)
          let ft = c.local_ty(l)
          c.record(callee.id, ft)
          return c.closure_call(e, callee, ft, all)
        }
        none => {}
      }
      return c.named_call(e, callee, n, all, exp, direct)
    }
    _ => {}
  }
  match visit.as_path(callee) {
    some(path) => {
      let last = path[path.len() - 1]
      let prefix = path.take(path.len() - 1)
      match c.expr_path(m, prefix) {
        Module(target) => return c.path_call(e, target, last, all, exp, direct)
        Ambiguous => return c.quiet_args(all.skip(1))
        Value => {}
      }
    }
    none => {}
  }
  c.err(diag.new("E0030", callee.span, "a `|>` step must name a function").note("`x |> f(a)` means `f(x, a)`"))
  types.Ty.Error
}

/// The (already inferred) type of a receiver argument.
pub fn recv_ty(c: var check.Checker, e: ast.Expr): types.Ty = c.cx.t.types.get(e.id) else types.Ty.Error

/// Type of an argument for choosing an overload: receivers are known; other arguments are
/// inferred (once; `pre` caches it).
pub fn arg_ty_for_choice(c: var check.Checker, a: check.ArgSrc): types.Ty = match a {
  Recv(e) => c.recv_ty(e)
  Expr(e) => match e.kind {
    Ref(x) => {
      let t = c.infer(x, none)
      c.record(e.id, t)
      t
    }
    _ => c.infer(e, none)
  }
}

/// Resolve an overloaded call among `cands`, check the arguments, record the call.
pub fn call_fns(c: var check.Checker, e: ast.Expr, span: diag.Span, name: str, cands: [int], args: [check.ArgSrc], exp: check.Exp, direct: bool): types.Ty {
  let n = args.len()
  var by_arity: [int] = []
  for f in cands {
    if c.fns[f].params.len() == n { by_arity.push(f) }
  }
  if by_arity.len() == 0 {
    let sigs = sigs_of(c, cands, 4)
    let recv_first = args.len() > 0 && args[0] is check.ArgSrc.Recv(_)
    let given = if recv_first { "{n} (counting the receiver)" } else { "{n}" }
    c.err(
      diag.new("E0300", span, "`{name}` takes {c.fns[cands[0]].params.len()} argument(s), but {given} were given")
        .note("signature(s): {sigs.join("; ")}"),
    )
    for a in args {
      match a {
        Expr(x) => c.infer_quiet(x)
        _ => {}
      }
    }
    return types.Ty.Error
  }
  var pre: types.Ty? = none
  var f = 0
  if by_arity.len() == 1 {
    f = by_arity[0]
  } else {
    let t0 = c.arg_ty_for_choice(args[0])
    pre = t0
    var fits: [int] = []
    for g in by_arity {
      let p0 = c.fns[g].params[0].ty
      if c.cx_can_unify_param(g, p0, t0) || c.can_coerce_param(g, p0, t0) { fits.push(g) }
    }
    if fits.len() == 0 {
      for g in by_arity {
        let p0 = c.fns[g].params[0].ty
        if c.cx_can_unify_param_loose(g, p0, t0) { fits.push(g) }
      }
    }
    // the current module's own overloads come before core's (see `named_call`)
    let m = c.cur_module()
    var own: [int] = []
    for g in fits {
      if c.fns[g].module == m { own.push(g) }
    }
    if own.len() > 0 { fits = own }
    var specific: [int] = []
    for g in fits {
      if !(c.fns[g].params[0].ty is types.Ty.Param(_)) { specific.push(g) }
    }
    var exact: [int] = []
    for g in specific {
      let p0 = c.fns[g].params[0].ty
      if c.cx_can_unify_param(g, p0, t0) { exact.push(g) }
    }
    if fits.len() == 1 {
      f = fits[0]
    } else if exact.len() == 1 {
      f = exact[0]
    } else if specific.len() == 1 {
      f = specific[0]
    } else if fits.len() == 0 {
      let r0 = c.resolve(t0)
      if !r0.has_error() {
        let sigs = sigs_of(c, by_arity, 6)
        c.err(
          diag.new("E0202", check.arg_expr(args[0]).span, "no `{name}` takes a first argument of type `{c.show(t0)}`")
            .note("the overloads are: {sigs.join("; ")}"),
        )
      }
      for a in args.skip(1) {
        match a {
          Expr(x) => c.infer_quiet(x)
          _ => {}
        }
      }
      return types.Ty.Error
    } else {
      let r0 = c.resolve(t0)
      if r0.has_error() {
        // the argument's own error was reported; any overload could be meant
      } else if r0.has_vars() {
        let _ = c.cant_infer(check.arg_expr(args[0]).span, "the first argument (needed to choose an overload)")
      } else {
        let sigs = sigs_of(c, fits, 6)
        c.err(
          diag.new(
            "E0301",
            span,
            "the call to `{name}` is ambiguous: {fits.len()} overloads take a `{c.show(t0)}` first",
          )
            .note("candidates: {sigs.join("; ")}")
            .note("call it by path (`module.f(x)`) to pick one"),
        )
      }
      for a in args.skip(1) {
        match a {
          Expr(x) => c.infer_quiet(x)
          _ => {}
        }
      }
      return types.Ty.Error
    }
  }
  if is_fail_fn(c, f) { return c.fail_call(e, args) }
  let (s, targs) = c.instantiate(f)
  match check_raw.take_explicit(&c) {
    some(ex) => {
      if ex.len() > targs.len() {
        c.err(diag.new("E0106", span, "`{name}` takes {targs.len()} type argument(s), found {ex.len()}"))
      }
      for (a, x) in targs.zip(ex) { let _ = c.unify(a, x) }
    }
    none => {}
  }
  let info = c.fns[f]
  var ps = info.params.map(p => p.ty.subst(s))
  var ret = info.ret.subst(s)
  match unit_rule(c, f) {
    some(rule) => {
      let pt = match pre {
        some(t) => t
        none => {
          let t = c.arg_ty_for_choice(args[0])
          pre = t
          t
        }
      }
      let u = first_units(c.resolve(pt))
      if !units.is_none(u) {
        ps[0] = put_units(ps[0], u)
        ret = match rule {
          Strip => ret
          Keep => put_units(ret, u)
          Root => match units.root(u, 2) {
            some(h) => put_units(ret, h)
            none => {
              c.err(
                diag.new("E0292", check.arg_expr(args[0]).span, "`{name}` of a `float<{units.text(u)}>` has no unit: an exponent is odd")
                  .note("a square root needs even exponents (`m^2` gives `m`); strip the unit first with `float(x)`"),
              )
              types.Ty.Error
            }
          }
        }
      }
    }
    none => {}
  }
  // the value of an `async fn` call is a task unless it is awaited right away
  let result = if info.is_async && !direct { types.Ty.Task(ret) } else { ret }
  // let the expected type guide the type arguments (`let t: Todo = json.decode(s)?`)
  // A hint is taken only together with the receiver's (already known) type, so a hint that
  // contradicts the receiver is skipped instead of binding a wrong type argument.
  if !(info.ret is types.Ty.Param(_)) || info.generics.len() == 0 {
    let hints: [types.Ty] = match exp {
      Hint(t) | Check(t) | Tail(t) => if c.shallow(t) is types.Ty.Var(_) { [] } else { [t] }
      Hints(ts) => ts
      _ => []
    }
    if hints.len() > 0 {
      var have = [result]
      var want = [types.Ty.Error]
      for k, a in args {
        if k >= ps.len() { break }
        match a {
          Recv(x) => {
            have.push(c.recv_ty(x))
            want.push(ps[k])
          }
          _ => {}
        }
      }
      let have_t = types.Ty.Tuple(have)
      for t in hints {
        want[0] = t
        if c.try_unify(have_t, types.Ty.Tuple(want)) { break }
      }
    }
  }
  var out_args: [typed.Arg] = []
  for i, a in args {
    let var_ = info.params[i].var_
    let p = ps[i]
    match a {
      Recv(x) => {
        let t = c.recv_ty(x)
        if var_ {
          if !c.unify(t, p) { c.mismatch(x, t, p, false) }
          let _ = c.place(x, true, check.PlaceUse.Receiver(name))
        } else {
          let _ = c.coerce_at(x, t, p, false)
        }
        out_args.push(typed.Arg { node: x.id, by_ref: var_ })
      }
      Expr(x) => {
        var is_ref = false
        match x.kind {
          Ref(inner) => {
            is_ref = true
            let t = match pre {
              some(pt) => if i == 0 { pt } else { c.infer(inner, p) }
              none => c.infer(inner, p)
            }
            c.record(x.id, t)
            if !var_ {
              c.err(
                diag.new("E0311", x.span, "parameter {i + 1} of `{name}` is not a `var` parameter, so its argument takes no `&`")
                  .note("`&` marks an argument the callee may change; remove it")
                  .fix(diag.Span { end_line: x.span.line, end_col: x.span.col + 1, ..x.span }, ""),
              )
              let _ = c.coerce_at(inner, t, p, false)
            } else {
              if !c.unify(t, p) { c.mismatch(inner, t, p, false) }
              let _ = c.place(inner, true, check.PlaceUse.Ref)
            }
          }
          _ => {
            if var_ {
              let pname = match info.params[i].name {
                some(pn) => "`{pn}`"
                none => "{i + 1}"
              }
              c.err(
                diag.new("E0310", x.span, "parameter {pname} of `{name}` is `var`, so the argument needs `&`")
                  .note("`{name}` may change it; write `&{c.text(x.span)}` to let it change the caller's variable")
                  .fix(start_of(x.span), "&"),
              )
            }
            match pre {
              some(pt) => if i == 0 {
                let _ = c.coerce_at(x, pt, p, false)
              } else {
                let _ = c.check(x, p)
              }
              none => {
                let _ = c.check(x, p)
              }
            }
          }
        }
        out_args.push(typed.Arg { node: x.id, by_ref: var_ && is_ref })
      }
    }
  }
  for k, g in info.generics {
    for b in c.defs.params[g].bounds {
      let shape = c.defs.shapes[b].name
      let tn = c.defs.params[g].name
      let why = if c.defs.params[g].implicit {
        "which `{name}` needs (it takes `{shape}` values)"
      } else {
        "which `{name}` needs for its type parameter `{tn}`"
      }
      c.defer_fit(targs[k], b, span, why)
    }
  }
  c.note_call(e.id, typed.Call { callee: typed.Callee.Fn(f, targs), args: out_args })
  if info.is_async && direct {
    c.cx.t.awaits[e.id] = typed.AwaitKind.Direct
  } else if info.is_async {
    match info.params.find(p => p.var_) {
      some(p) => {
        // a task shares nothing with its caller (its arguments are copied into its own heap)
        let what = match p.name {
          some(pn) => "`{pn}`"
          none => "an argument"
        }
        c.err(
          diag.new("E0336", e.span, "`{name}` takes {what} by `var`, so it can't run as a task")
            .note("a task gets copies of its arguments and shares nothing with its caller; `await` the call right away to run it here, or pass the value and return the new one")
            .fix(start_of(e.span), "await "),
        )
      }
      none => {}
    }
  }
  result
}

/// Could `t` convert to the parameter type (auto-wrap) for overload choice?
pub fn can_coerce_param(c: var check.Checker, f: int, p: types.Ty, t: types.Ty): bool {
  let snap = types.snapshot(c.cx.inf)
  let (s, _) = c.instantiate(f)
  let p2 = p.subst(s)
  let ok = match c.shallow(p2) {
    Opt(inner) | Res(inner, _) => c.unify(inner, t)
    _ => false
  }
  types.rollback(&c.cx.inf, snap)
  ok
}

pub fn shape_call(c: var check.Checker, e: ast.Expr, s: int, i: int, self_ty: types.Ty, callee: typed.Callee, args: [check.ArgSrc]): types.Ty {
  let meth = c.defs.shapes[s].methods[i]
  var sub: {int: types.Ty} = {}
  sub[c.defs.shapes[s].self_param] = self_ty
  if meth.params.len() != args.len() {
    c.err(
      diag.new(
        "E0300",
        e.span,
        "`{meth.name}` takes {meth.params.len() - 1} argument(s), but {args.len() - 1} were given",
      ),
    )
    return types.Ty.Error
  }
  var out: [typed.Arg] = []
  for k, a in args {
    let p = meth.params[k].subst(sub)
    match a {
      Recv(x) => {
        let t = c.recv_ty(x)
        let _ = c.coerce_at(x, t, p, false)
        out.push(typed.Arg { node: x.id, by_ref: false })
      }
      Expr(x) => {
        let _ = c.check(x, p)
        out.push(typed.Arg { node: x.id, by_ref: false })
      }
    }
  }
  c.note_call(e.id, typed.Call { callee, args: out })
  meth.ret.subst(sub)
}

pub fn variant_call(c: var check.Checker, e: ast.Expr, d: int, i: int, args: [check.ArgSrc], hint: types.Ty?): types.Ty {
  let (s, targs) = c.instantiate_def(d)
  let ty = types.Ty.Named(d, targs)
  match hint {
    some(h) => {
      let _ = c.try_unify(ty, h)
    }
    none => {}
  }
  let v = c.defs.variants(d)[i]
  if v.fields.len() != args.len() {
    let what = if v.fields.len() == 0 {
      "`{v.name}` has no fields; write it without parentheses"
    } else {
      "`{v.name}` has {v.fields.len()} field(s)"
    }
    c.err(
      diag.new("E0302", e.span, "the variant `{v.name}` takes {v.fields.len()} value(s), but {args.len()} were given")
        .note(what),
    )
    for a in args {
      match a {
        Expr(x) => c.infer_quiet(x)
        _ => {}
      }
    }
    return ty
  }
  var out: [typed.Arg] = []
  for k, a in args {
    let ft = v.fields[k].1.subst(s)
    match a {
      Recv(x) => {
        let t = c.recv_ty(x)
        let _ = c.coerce_at(x, t, ft, false)
        out.push(typed.Arg { node: x.id, by_ref: false })
      }
      Expr(x) => {
        let _ = c.check(x, ft)
        out.push(typed.Arg { node: x.id, by_ref: false })
      }
    }
  }
  c.note_call(e.id, typed.Call { callee: typed.Callee.Variant(typed.VariantRef { def: d, index: i, args: targs }), args: out })
  ty
}

pub fn closure_call(c: var check.Checker, e: ast.Expr, callee: ast.Expr, ft: types.Ty, args: [check.ArgSrc]): types.Ty {
  let ft2 = match c.shallow(ft) {
    Var(_) => {
      var ps: [types.Ty] = []
      for a in args {
        let is_ref = match a {
          Expr(x) => x.kind is ast.ExprKind.Ref(_)
          _ => false
        }
        ps.push(if is_ref { types.Ty.Mut(c.fresh()) } else { c.fresh() })
      }
      let r = c.fresh()
      let f = types.func(ps, r)
      let _ = c.unify(ft, f)
      f
    }
    t => t
  }
  match ft2 {
    Fn(ps, r) => {
      if ps.len() != args.len() {
        c.err(diag.new("E0300", e.span, "this closure takes {ps.len()} argument(s), but {args.len()} were given"))
        return r
      }
      var out: [typed.Arg] = []
      let what = c.text(callee.span)
      for i, a in args {
        // a `var T` parameter takes the caller's variable, marked `&`
        let (var_, p) = match c.shallow(ps[i]) {
          Mut(t) => (true, t)
          _ => (false, ps[i])
        }
        match a {
          Recv(x) => {
            let t = c.recv_ty(x)
            if var_ {
              if !c.unify(t, p) { c.mismatch(x, t, p, false) }
              let _ = c.place(x, true, check.PlaceUse.Receiver(what))
            } else {
              let _ = c.coerce_at(x, t, p, false)
            }
            out.push(typed.Arg { node: x.id, by_ref: var_ })
          }
          Expr(x) => match x.kind {
            Ref(inner) => if var_ {
              let t = c.infer(inner, p)
              c.record(x.id, t)
              if !c.unify(t, p) { c.mismatch(inner, t, p, false) }
              let _ = c.place(inner, true, check.PlaceUse.Ref)
              out.push(typed.Arg { node: x.id, by_ref: true })
            } else {
              c.err(
                diag.new("E0311", x.span, "parameter {i + 1} of `{what}` is not a `var` parameter, so its argument takes no `&`")
                  .note("`&` marks an argument the callee may change; remove it")
                  .fix(diag.Span { end_line: x.span.line, end_col: x.span.col + 1, ..x.span }, ""),
              )
              let t = c.infer(inner, p)
              c.record(x.id, t)
              let _ = c.coerce_at(inner, t, p, false)
              out.push(typed.Arg { node: x.id, by_ref: false })
            }
            _ => if var_ {
              c.err(
                diag.new("E0310", x.span, "parameter {i + 1} of `{what}` is `var`, so the argument needs `&`")
                  .note("`{what}` may change it; write `&{c.text(x.span)}` to let it change the caller's variable")
                  .fix(start_of(x.span), "&"),
              )
              let _ = c.check(x, p)
              out.push(typed.Arg { node: x.id, by_ref: false })
            } else {
              let _ = c.check(x, p)
              out.push(typed.Arg { node: x.id, by_ref: false })
            }
          }
        }
      }
      c.note_call(e.id, typed.Call { callee: typed.Callee.Closure, args: out })
      r
    }
    Error => types.Ty.Error
    other => {
      let s = c.defs.show(c.resolve(other))
      c.err(diag.new("E0203", callee.span, "`{c.text(callee.span)}` is a `{s}`, not a function"))
      types.Ty.Error
    }
  }
}

/// `fail(e)`: never returns; `e` is a message, an `Err` or the function's error enum.
pub fn fail_call(c: var check.Checker, e: ast.Expr, args: [check.ArgSrc]): types.Ty {
  if args.len() != 1 {
    c.err(diag.new("E0300", e.span, "`fail` takes 1 argument, but {args.len()} were given"))
    return types.Ty.Never
  }
  let x = check.arg_expr(args[0])
  let ret = match c.frame_ret() {
    some(r) => some(c.shallow(r))
    none => none
  }
  let et0 = match ret {
    some(Res(_, et)) => some(c.shallow(et))
    _ => none
  }
  let hint = match et0 {
    some(t) => if c.defs.is_err(t) { none } else { some(t) }
    none => none
  }
  let t0 = c.infer(x, hint)
  let t = c.resolve(t0)
  let fr = c.top_frame()
  let what = match fr {
    some(f) => f.what
    none => "function"
  }
  if ret is none && (what == "guard" || what == "constant") {
    c.err(diag.new("E0246", e.span, "`fail` is not allowed in a {what}").note("guards and constants can't fail"))
    return types.Ty.Never
  }
  let et = et0 else {
    var d = diag.new("E0242", e.span, "`fail` can only be used in a function that returns `T!` or `T!E` (or in a test)")
    let rs = match fr {
      some(f) => f.ret_span
      none => none
    }
    match (rs, ret) {
      (some(sp), some(r)) => {
        let rt = c.show(r)
        d = d.note("change the return type to `{rt}!`").fix(sp, "{rt}!")
      }
      _ => d = d.note("declare the return type as `T!` (e.g. `fn f(): int!`) to report errors")
    }
    c.err(d)
    return types.Ty.Never
  }
  var kind = typed.FailKind.Message
  match t {
    Str | Error => kind = typed.FailKind.Message
    _ => if c.defs.is_err(t) {
      if !c.defs.is_err(et) {
        c.err(
          diag.new("E0241", x.span, "this function's errors are `{c.show(et)}`, so it can't fail with an `Err`")
            .note("fail with one of its variants, or make the return type `T!`"),
        )
      }
      kind = typed.FailKind.Err
    } else {
      let enum_val = match t {
        Named(d, _) => c.defs.is_enum(d)
        _ => false
      }
      if enum_val {
        if c.unify(t, et) {
          kind = typed.FailKind.Typed
        } else if c.defs.is_err(et) {
          kind = typed.FailKind.TypedToErr(t)
        } else {
          c.err(
            diag.new("E0241", x.span, "this function's errors are `{c.show(et)}`, but this is a `{c.show(t)}`")
              .note("fail with a variant of the declared error enum"),
          )
          kind = typed.FailKind.Message
        }
      } else {
        let need = if c.defs.is_err(et) {
          "a `str` message, an `Err` or an error enum value"
        } else {
          "a `str` message or a `{c.show(et)}`"
        }
        c.err(
          diag.new("E0241", x.span, "`fail` needs {need}, found `{c.show(t)}`").note("e.g. `fail(\"bad input: {{x}}\")`"),
        )
        kind = typed.FailKind.Message
      }
    }
  }
  if t == types.Ty.Str {
    // a message: make a plain `Err` even in a `T!E` function? No: a `T!E` function's errors
    // are its enum, so a message only fits a `T!` function.
    if !c.defs.is_err(et) {
      c.err(
        diag.new("E0241", x.span, "this function's errors are `{c.show(et)}`, so it can't fail with a message")
          .note("fail with one of its variants, or make the return type `T!` to use messages"),
      )
    }
  }
  c.cx.t.fails[e.id] = kind
  types.Ty.Never
}
