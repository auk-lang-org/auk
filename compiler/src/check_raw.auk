/// The runtime's dialect (docs/lowlevel.md) in the checker: explicit type arguments
/// (`raw.size_of<T>()`), field selectors (`.f`), fields through pointers (`p.f`), the
/// intrinsics that aren't plain generic functions (`field_addr`, `offset_of`, `fn_of`), and the
/// checks on intrinsic calls done when a body is finished (integer arguments, constant memory
/// orders). Fixed-width numbers and conversions are in check_expr/check_ops; the E0419 type
/// rule in check.auk.

/// `raw.f<T, U>(args)`: the call `x` with explicit type arguments.
pub fn type_args(c: var check.Checker, x: ast.Expr, tys: [ast.Type], exp: check.Exp): types.Ty {
  let m = c.cur_module()
  if !c.prog.raw_ok(m) {
    c.err(effect_check.raw_only(x.span, "explicit type arguments are the runtime's dialect"))
  }
  var g = c.cx.generics
  var ts: [types.Ty] = []
  for t in tys { ts.push(c.resolve_type(m, t, &g)) }
  c.cx.explicit = some(ts)
  let t = c.expr(x, exp)
  c.cx.explicit = none
  t
}

/// The explicit type arguments of the call being checked, if any (taken once).
pub fn take_explicit(c: var check.Checker): [types.Ty]? {
  let ex = c.cx.explicit
  c.cx.explicit = none
  ex
}

/// `.f` outside `raw.field_addr` / `raw.offset_of`.
pub fn field_sel(c: var check.Checker, e: ast.Expr): types.Ty {
  c.err(
    diag.new("E0021", e.span, "a field selector `.f` is only an argument of `raw.field_addr(p, .f)` or `raw.offset_of<T>(.f)`"),
  )
  types.Ty.Error
}

/// The field `name` of the raw struct `t` (index and type), or an error (E0221).
fn raw_field(c: var check.Checker, t: types.Ty, name: ast.Ident): (int, int, types.Ty)? {
  let (d, args) = match c.shallow(t) {
    Named(d, args) when types.is_raw_def(c.defs, d) => (d, args)
    Error => return none
    other => {
      c.err(diag.new("E0221", name.span, "`{c.show(other)}` is not a raw struct, so it has no field `{name.name}`"))
      return none
    }
  }
  let fields = c.defs.fields(d)
  let i = fields.find_index(f => f.name == name.name) else {
    c.err(
      diag.new("E0221", name.span, "the raw struct `{c.defs.types[d].name}` has no field `{name.name}`")
        .note("its fields are: {fields.map(f => f.name).join(", ")}"),
    )
    return none
  }
  (d, i, fields[i].ty.subst(c.defs.subst_of(d, args)))
}

/// The value of field `t` read through a pointer: an array is the address of its first element.
fn through_ptr(t: types.Ty): types.Ty = match t {
  Array(x, _) => types.Ty.Ptr(x)
  t => t
}

/// `p.f` with `p: raw.Ptr<S>` of a raw struct `S`, or none when `t` isn't such a pointer.
pub fn ptr_field(c: var check.Checker, e: ast.Expr, t: types.Ty, name: ast.Ident): types.Ty? {
  let inner = match c.shallow(t) {
    Ptr(x) => x
    _ => return none
  }
  match raw_field(&c, inner, name) {
    some((d, i, ft)) => {
      c.cx.t.fields[e.id] = (d, i)
      through_ptr(ft)
    }
    none => types.Ty.Error
  }
}

/// The intrinsics of core's `raw` module that need more than a generic signature.
pub fn is_special(name: str): bool = name == "field_addr" || name == "offset_of" || name == "fn_of"

pub fn special(c: var check.Checker, e: ast.Expr, target: int, name: ast.Ident, args: [check.ArgSrc]): types.Ty {
  let m = c.cur_module()
  let f = c.fns_in(m, target, name.name)[0]
  let xs = args.map(a => check.arg_expr(a))
  let explicit = take_explicit(&c)
  let want = if name.name == "offset_of" { 1 } else if name.name == "fn_of" { 1 } else { 2 }
  if xs.len() != want {
    c.err(diag.new("E0300", name.span, "`raw.{name.name}` takes {want} argument(s), but {xs.len()} were given"))
    for x in xs { c.infer_quiet(x) }
    return types.Ty.Error
  }
  let arg = (x: ast.Expr) => typed.Arg { node: x.id, by_ref: false }
  match name.name {
    "field_addr" => {
      let pt = c.infer(xs[0], none)
      let sel = xs[1]
      let fname = match sel.kind {
        FieldSel(n) => n
        _ => {
          c.err(diag.new("E0021", sel.span, "`raw.field_addr(p, .f)` names the field with `.f`"))
          return types.Ty.Error
        }
      }
      c.record(sel.id, types.unit())
      let inner = match c.shallow(pt) {
        Ptr(x) => x
        Error => return types.Ty.Error
        other => {
          c.err(diag.new("E0202", xs[0].span, "`raw.field_addr` takes a `raw.Ptr` to a raw struct, not `{c.show(other)}`"))
          return types.Ty.Error
        }
      }
      let (d, i, ft) = raw_field(&c, inner, fname) else return types.Ty.Error
      c.note_call(e.id, typed.Call { callee: typed.Callee.Fn(f, [inner, ft]), args: [arg(xs[0]), arg(sel)] })
      c.cx.t.raw[e.id] = typed.RawNode.Field(d, i)
      types.Ty.Ptr(through_ptr(ft))
    }
    "offset_of" => {
      let sel = xs[0]
      let fname = match sel.kind {
        FieldSel(n) => n
        _ => {
          c.err(diag.new("E0021", sel.span, "`raw.offset_of<T>(.f)` names the field with `.f`"))
          return types.Ty.Error
        }
      }
      c.record(sel.id, types.unit())
      let t = match explicit {
        some(ts) when ts.len() == 1 => ts[0]
        _ => {
          c.err(diag.new("E0360", name.span, "`raw.offset_of` needs the struct as a type argument: `raw.offset_of<T>(.f)`"))
          return types.Ty.Error
        }
      }
      let (d, i, ft) = raw_field(&c, t, fname) else return types.Ty.Error
      c.note_call(e.id, typed.Call { callee: typed.Callee.Fn(f, [t, ft]), args: [arg(sel)] })
      c.cx.t.raw[e.id] = typed.RawNode.Field(d, i)
      types.Ty.Fixed(types.Fx.Usize)
    }
    _ => {
      // `raw.fn_of(f)`: a function's C address
      let x = xs[0]
      let ft = c.infer(x, none)
      let func = match c.cx.t.names.get(x.id) {
        some(Fn(func, _)) => func
        _ => {
          if !c.resolve(ft).has_error() {
            c.err(diag.new("E0202", x.span, "`raw.fn_of` takes the name of a function"))
          }
          return types.Ty.Error
        }
      }
      let (ps, r) = match c.resolve(ft) {
        Fn(ps, r) => (ps, r)
        _ => return types.Ty.Error
      }
      let info = c.fns[func]
      let scalar = (t: types.Ty) => match t {
        Int | Float | Bool | Char | Fixed(_) | Ptr(_) | CFn(_, _) => true
        t => types.is_unit(t)
      }
      if !c.is_export(func) && !(ps.all(scalar) && scalar(r)) {
        c.err(
          diag.new("E0202", x.span, "`raw.fn_of({info.name})`: only an `export fn`, or a function of numbers and raw pointers, has a C address")
            .note("declare it `export fn` (C's calling convention for every type)"),
        )
      }
      let cf = types.Ty.CFn(ps, r)
      // the argument names the function; it isn't a closure value
      c.record(x.id, cf)
      c.note_call(e.id, typed.Call { callee: typed.Callee.Fn(f, [ft]), args: [arg(x)] })
      c.cx.t.raw[e.id] = typed.RawNode.FnOf
      cf
    }
  }
}

/// The integer type parameters of the intrinsics (`p.at(i)`, `raw.copy(d, s, n)`, ...).
fn int_param(name: str): bool = name == "I" || name == "N"

/// The memory-order arguments of the atomics, by intrinsic.
fn order_args(name: str): [int] = match name {
  "atomic_load" => [1]
  "fence" => [0]
  "atomic_cas" => [3, 4]
  "atomic_store" | "atomic_swap" | "atomic_add" | "atomic_sub" | "atomic_and" | "atomic_or" => [2]
  _ => []
}

/// A memory order's variant index (`raw.Order`: Relaxed Acquire Release AcqRel SeqCst).
pub fn order_index(t: typed.Tables, node: int): int? = match t.names.get(node) {
  some(Variant(v)) => v.index
  _ => none
}

/// Checks on the raw intrinsic calls of a finished body (types resolved): integer arguments,
/// pointer casts, atomics on integers and pointers with constant, valid memory orders (E0421).
pub fn validate(c: var check.Checker, t: typed.Tables, m: int) {
  for n in t.calls.keys().sort() {
    let call = t.calls[n]
    let (f, targs) = match call.callee {
      Fn(f, targs) => (f, targs)
      _ => continue
    }
    let name = match c.fns[f].kind {
      Intrinsic(Raw(name), _) => name
      _ => continue
    }
    let span = c.first_span(m, [n]) else diag.NONE
    let gens = c.fns[f].generics
    for k, g in gens {
      let ta = targs.get(k) else continue
      let pname = c.defs.params[g].name
      if int_param(pname) && !(ta == types.Ty.Int || types.is_fixed_int(ta) || ta.has_error()) {
        c.err_in(m, diag.new("E0202", span, "`raw.{name}` takes an integer here, not `{c.defs.show(ta)}`"))
      }
    }
    let t0 = targs.get(0) else types.unit()
    if name == "cast" {
      let from = targs.get(1) else types.unit()
      let ok = match from {
        Ptr(_) | CFn(_, _) | Param(_) | Error => true
        Named(d, _) => match c.defs.types[d].kind {
          Opaque(cty) => !cty.starts_with("Auk")
          _ => false
        }
        _ => false
      }
      if !ok { c.err_in(m, diag.new("E0202", span, "`raw.cast` takes a pointer (`raw.Ptr`, `raw.Fn`, `ffi.Ptr`, an `extern type`), not `{c.defs.show(from)}`")) }
    }
    if name.starts_with("atomic_") {
      let ok = match t0 {
        Int | Bool | Ptr(_) | CFn(_, _) | Error => true
        x => types.is_fixed_int(x)
      }
      if !ok { c.err_in(m, diag.new("E0202", span, "atomics work on integers and pointers, not `{c.defs.show(t0)}`")) }
    }
    for k, pos in order_args(name) {
      let node = match call.args.get(pos) {
        some(a) => a.node
        none => continue
      }
      let at = c.first_span(m, [node]) else span
      match order_index(t, node) {
        none => c.err_in(
          m,
          diag.new("E0421", at, "the memory order of `raw.{name}` must be a constant")
            .note("write it out: `raw.Order.SeqCst`, `raw.Order.Acquire`, ..."),
        )
        some(o) => {
          let bad = (name == "atomic_load" && (o == 2 || o == 3)) ||
            (name == "atomic_store" && (o == 1 || o == 3)) ||
            (name == "atomic_cas" && k == 1 && (o == 2 || o == 3)) ||
            (name == "fence" && o == 0)
          if bad { c.err_in(m, diag.new("E0421", at, "this memory order isn't valid for `raw.{name}`")) }
        }
      }
    }
  }
}
