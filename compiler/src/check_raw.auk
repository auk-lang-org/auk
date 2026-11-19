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
      c.cx.t.raw[e.id] = typed.RawNode.Deref
      through_ptr(ft)
    }
    none => types.Ty.Error
  }
}

/// The intrinsics of core's `raw` module that need more than a generic signature.
pub fn is_special(name: str): bool =
  name == "field_addr" || name == "offset_of" || name == "fn_of" || name == "cast" || name == "addr_of"

pub fn special(c: var check.Checker, e: ast.Expr, target: int, name: ast.Ident, args: [check.ArgSrc], exp: check.Exp): types.Ty {
  let m = c.cur_module()
  let f = c.fns_in(m, target, name.name)[0]
  let xs = args.map(a => check.arg_expr(a))
  let explicit = take_explicit(&c)
  let want = if name.name == "field_addr" { 2 } else { 1 }
  if xs.len() != want {
    c.err(diag.new("E0300", name.span, "`raw.{name.name}` takes {want} argument(s), but {xs.len()} were given"))
    for x in xs { c.infer_quiet(x) }
    return types.Ty.Error
  }
  let arg = (x: ast.Expr) => typed.Arg { node: x.id, by_ref: false }
  match name.name {
    "addr_of" => {
      // `raw.addr_of(&x)`: a local (`let` or `var`), a parameter or a global; C takes the
      // address of anything with storage (writing through it is the caller's business)
      let x = xs[0]
      let inner = match x.kind {
        Ref(i) => i
        _ => {
          c.err(diag.new("E0202", x.span, "`raw.addr_of` takes `&x`: a local, a parameter or a global"))
          c.infer_quiet(x)
          return types.Ty.Error
        }
      }
      // another module's global by path: only a place
      match module_global(&c, inner, false) {
        some(t) => {
          c.record(x.id, t)
          c.note_call(e.id, typed.Call { callee: typed.Callee.Fn(f, [t]), args: [typed.Arg { node: x.id, by_ref: true }] })
          return types.Ty.Ptr(t)
        }
        none => {}
      }
      let t = c.infer(inner, none)
      c.record(x.id, t)
      // a `raw let` is a value, not memory: `place` reports it when asked to change it
      var is_let = false
      match inner.kind {
        Name(n) => if c.lookup_local(n) == none {
          match c.items[c.cur_module()].globals.get(n) {
            some(g) => is_let = c.globals[g].kind == 2
            none => {}
          }
        }
        _ => {}
      }
      let _ = c.place(inner, is_let, check.PlaceUse.Ref)
      c.note_call(e.id, typed.Call { callee: typed.Callee.Fn(f, [t]), args: [typed.Arg { node: x.id, by_ref: true }] })
      types.Ty.Ptr(t)
    }
    "cast" => {
      // `raw.cast<U>(p)`: a `raw.Ptr<U>`, or the function pointer `U` itself when `U` is a
      // `raw.Fn` (a code pointer held as `void *`); without `<U>`, what the context expects
      let from = c.infer(xs[0], none)
      let (u, to) = match explicit {
        some(ts) when ts.len() == 1 => match c.shallow(ts[0]) {
          CFn(_, _) => (ts[0], ts[0])
          _ => (ts[0], types.Ty.Ptr(ts[0]))
        }
        some(ts) => {
          c.err(diag.new("E0360", name.span, "`raw.cast` takes one type argument, but {ts.len()} were given"))
          return types.Ty.Error
        }
        none => {
          let hint = match check.exp_ty(exp) {
            some(t) => c.shallow(t)
            none => types.Ty.Error
          }
          match hint {
            CFn(_, _) => (hint, hint)
            Ptr(x) => (x, hint)
            _ => {
              let v = c.fresh()
              (v, types.Ty.Ptr(v))
            }
          }
        }
      }
      c.note_call(e.id, typed.Call { callee: typed.Callee.Fn(f, [u, from]), args: [arg(xs[0])] })
      to
    }
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
    if name == "is_null" {
      let ok = match t0 {
        Ptr(_) | CFn(_, _) | Error => true
        _ => false
      }
      if !ok { c.err_in(m, diag.new("E0202", span, "`is_null` takes a `raw.Ptr` or a `raw.Fn`, not `{c.defs.show(t0)}`")) }
    }
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
    let bits = ["add_overflow", "sub_overflow", "mul_overflow", "ctz", "clz", "popcount", "bswap"]
    if bits.contains(name) {
      let ok = t0 == types.Ty.Int || t0.has_error() || types.is_fixed_int(t0)
      if !ok { c.err_in(m, diag.new("E0202", span, "`raw.{name}` works on integers, not `{c.defs.show(t0)}`")) }
      let narrow = match t0 {
        Fixed(k) => types.fx_bits(k) < 16
        _ => false
      }
      if name == "bswap" && narrow { c.err_in(m, diag.new("E0202", span, "`raw.bswap` needs 16 bits or more, not `{c.defs.show(t0)}`")) }
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

/// `export fn`: only in the runtime package, one clause, no type parameters (its types are
/// checked by the raw rule of `uses raw` bodies, and below for every export).
pub fn export_fn(c: var check.Checker, m: int, first: ast.FnClause, nclauses: int, generic: bool) {
  if !c.prog.raw_ok(m) {
    c.err_in(m, effect_check.raw_only(first.name.span, "`export fn {first.name.name}` is a C function"))
    return
  }
  if generic || nclauses > 1 {
    c.err_in(m, diag.new("E0419", first.name.span, "an `export fn` is one C function: no type parameters, one clause"))
  }
}

// ---- globals: `raw var`, `raw thread var`, `raw let`, `export var`, `raw assert` ----

/// Register a global (its initializer is evaluated by `check_globals`).
pub fn declare_global(c: var check.Checker, m: int, d: ast.GlobalDef) {
  if !c.prog.raw_ok(m) {
    c.err_in(m, effect_check.raw_only(d.name.span, "`{ast.global_kw(d.kind)} {d.name.name}` is a C global"))
  }
  let n = d.name.name
  if c.items[m].globals.contains(n) || c.items[m].consts.contains(n) {
    c.err_in(m, diag.new("E0107", d.name.span, "`{n}` is defined twice in this module"))
  }
  var g = check.gen_scope()
  let ty = match d.ty {
    some(t) => c.resolve_type(m, t, &g)
    none => {
      if d.kind != 2 {
        let kw = ast.global_kw(d.kind)
        c.err_in(m, diag.new("E0360", d.name.span, "`{kw} {n}` needs its type: `{kw} {n}: T = ...`"))
      }
      types.Ty.Error
    }
  }
  let flexible = match ty {
    Array(_, k) => k < 0
    _ => false
  }
  if !check.raw_allowed(c.defs, ty) || flexible {
    c.err_in(m, diag.new("E0419", d.name.span, "a global of the runtime's dialect can't be `{c.defs.show(ty)}`"))
  }
  let c_name = if d.kind == 4 {
    match d.value.kind {
      Lit(Str(s)) => s
      _ => {
        c.err_in(m, diag.new("E0020", d.value.span, "`extern var` names its C symbol as a string: `extern var {n}: T = \"symbol\"`"))
        ""
      }
    }
  } else {
    ""
  }
  let id = c.globals.len()
  c.globals.push(typed.GlobalInfo { name: n, module: m, public: d.public, kind: d.kind, c_name, ty, value: typed.ConstVal.Zero, span: d.name.span })
  c.items[m].globals[n] = id
}

/// Register a `raw type` alias (resolved on first use).
pub fn declare_alias(c: var check.Checker, m: int, d: ast.RawTypeDef) {
  if !c.prog.raw_ok(m) {
    c.err_in(m, effect_check.raw_only(d.name.span, "`raw type {d.name.name}` is an alias of a raw type"))
    return
  }
  let n = d.name.name
  if c.items[m].types.contains(n) || c.items[m].aliases.contains(n) {
    c.err_in(m, diag.new("E0107", d.name.span, "the type `{n}` is defined twice in this module"))
    return
  }
  c.items[m].aliases[n] = c.aliases.len()
  c.aliases.push(check.AliasInfo { module: m, def: d, state: 0, ty: types.Ty.Error })
}

/// The alias a type path names, seen from module `m` (`ModeT`, `cfacts.ModeT`), if any.
pub fn alias_of(c: var check.Checker, m: int, path: [ast.Ident], g: check.GenScope): int? {
  if path.len() == 1 {
    if g.names.contains(path[0].name) { return none }
    return c.items[m].aliases.get(path[0].name)
  }
  let target = c.module_of_path(m, path.take(path.len() - 1))?
  let last = path[path.len() - 1]
  let a = c.items[target].aliases.get(last.name)?
  if target != m && !c.aliases[a].def.public {
    c.err_in(m, diag.new("E0120", last.span, "the type `{last.name}` is private to module `{c.prog.name(target)}`").note("mark it `pub` to use it from other modules"))
  }
  a
}

/// The type alias `a` stands for (resolved once; a raw type).
pub fn alias_ty(c: var check.Checker, a: int): types.Ty {
  let info = c.aliases[a]
  if info.state == 2 { return info.ty }
  let d = info.def
  let m = info.module
  if info.state == 1 {
    c.err_in(m, diag.new("E0107", d.name.span, "`raw type {d.name.name}` is defined in terms of itself"))
    return types.Ty.Error
  }
  c.aliases[a].state = 1
  var g = check.gen_scope()
  let t = c.resolve_type(m, d.ty, &g)
  if !check.raw_allowed(c.defs, t) {
    c.err_in(m, diag.new("E0419", d.ty.span, "a `raw type` names a raw type, not `{c.defs.show(t)}`"))
  }
  c.aliases[a].state = 2
  c.aliases[a].ty = t
  t
}

/// A global used as a place (`counter += 1`, `raw.addr_of(&g)`), or none if `n` isn't one.
pub fn global_place(c: var check.Checker, e: ast.Expr, n: str, mutate: bool): types.Ty? {
  let m = c.cur_module()
  let g = c.items[m].globals.get(n) else return none
  c.cx.t.names[e.id] = typed.NameRef.Global(g)
  let t = c.globals[g].ty
  c.record(e.id, t)
  if mutate && c.globals[g].kind == 2 {
    c.err(diag.new("E0320", e.span, "can't change `{n}`: it is a `raw let` constant").note("declare it `raw var` to change it"))
  }
  t
}

/// `m.g` used as a place (`raw.addr_of(&facts.counter)`, `facts.counter = 1`): a global of
/// another module by path, or none if `e` isn't one.
pub fn module_global(c: var check.Checker, e: ast.Expr, mutate: bool): types.Ty? {
  let (x, name) = match e.kind {
    Field(x, name) => (x, name)
    _ => return none
  }
  let path = visit.as_path(x) else return none
  if c.lookup_local(path[0].name) != none { return none }
  let m = c.cur_module()
  let tg = c.module_of_path(m, path) else return none
  let g = c.items[tg].globals.get(name.name) else return none
  if tg != m && !c.globals[g].public {
    c.err(
      diag.new("E0120", name.span, "`{name.name}` is private to module `{c.prog.name(tg)}`").note("mark it `pub` to use it from other modules"),
    )
  }
  c.cx.t.names[e.id] = typed.NameRef.Global(g)
  let t = c.globals[g].ty
  c.record(e.id, t)
  if mutate && c.globals[g].kind == 2 {
    c.err(diag.new("E0320", e.span, "can't change `{name.name}`: it is a `raw let` constant").note("declare it `raw var` to change it"))
  }
  t
}

/// The state of compile-time evaluation: per global, 0 todo, 1 busy, 2 done; the AST of each.
struct Eval { state: [int], defs: [(int, ast.GlobalDef)] }

/// Evaluate every global's initializer and every `raw assert` (E0421 when not constant or false).
pub fn check_globals(c: var check.Checker) {
  var asserts: [(int, ast.RawAssertDef)] = []
  var ev = Eval { state: c.globals.map(_ => 0), defs: [] }
  for m, md in c.prog.mods {
    for it in md.ast.items {
      match it {
        Global(d) => ev.defs.push((m, d))
        RawAssert(a) => asserts.push((m, a))
        _ => {}
      }
    }
  }
  for g in 0..c.globals.len() { eval_global(&c, &ev, g) }
  for (m, a) in asserts {
    if !c.prog.raw_ok(m) {
      c.err_in(m, effect_check.raw_only(a.span, "`raw assert` is a compile-time layout check"))
      continue
    }
    match eval(&c, &ev, m, a.expr, some(types.Ty.Bool)) {
      some((v, t)) => if t != types.Ty.Bool {
        c.err_in(m, diag.new("E0421", a.expr.span, "`raw assert` needs a `bool`, found `{c.defs.show(t)}`"))
      } else if v == typed.ConstVal.Int(0) {
        let note = assert_note(&c, &ev, m, a.expr)
        c.err_in(m, diag.new("E0421", a.expr.span, "this `raw assert` fails").note(note))
      }
      none => {}
    }
  }
}

/// For a failed comparison: both sides' values.
fn assert_note(c: var check.Checker, ev: var Eval, m: int, e: ast.Expr): str = match e.kind {
  Binary(op, l, r) => match (eval(&c, &ev, m, l, none), eval(&c, &ev, m, r, none)) {
    (some((a, _)), some((b, _))) => "the left side is {show_cv(a)}, the right side {show_cv(b)} (`{op.symbol()}`)"
    _ => "the condition is false at compile time"
  }
  _ => "the condition is false at compile time"
}

fn show_cv(v: typed.ConstVal): str = match v {
  Int(n) => "{n}"
  Float(x) => "{x}"
  Zero => "0"
  Agg(_) => "a struct"
  GlobalAddr(_) | FnAddr(_) => "an address"
}

fn eval_global(c: var check.Checker, ev: var Eval, g: int) {
  if ev.state[g] != 0 { return }
  ev.state[g] = 1
  let (m, d) = ev.defs[g]
  if d.kind == 4 {
    // defined in C
    ev.state[g] = 2
    return
  }
  let want = c.globals[g].ty
  let w: types.Ty? = if want == types.Ty.Error { none } else { some(want) }
  match eval(&c, &ev, m, d.value, w) {
    some((v, t)) => {
      if want == types.Ty.Error && d.ty == none {
        c.globals[g].ty = t
      } else if !same(t, want) {
        c.err_in(m, diag.new("E0200", d.value.span, "expected `{c.defs.show(want)}`, found `{c.defs.show(t)}`"))
      }
      c.globals[g].value = v
    }
    none => {}
  }
  ev.state[g] = 2
}

fn not_const(c: var check.Checker, m: int, e: ast.Expr): (typed.ConstVal, types.Ty)? {
  c.err_in(
    m,
    diag.new("E0421", e.span, "this isn't a compile-time constant")
      .note("an initializer of a global and a `raw assert` use literals, `raw let`s, `raw.size_of<T>()`, `raw.align_of<T>()`, `raw.offset_of<T>(.f)`, `raw.null()`, `raw.addr_of(&g)`, `raw.fn_of(f)`, `raw.cast`, conversions, arithmetic, and raw struct and array literals"),
  )
  none
}

/// `n` as a value of the fixed-width type `t` (wrapped, sign- or zero-extended).
fn norm(n: int, t: types.Ty): int = match t {
  Fixed(k) => {
    let bits = types.fx_bits(k)
    if bits == 64 || k == types.Fx.F32 { return n }
    let mask = (1 << bits) - 1
    let v = n & mask
    if types.fx_signed(k) && v >= 1 << (bits - 1) { v - (1 << bits) } else { v }
  }
  Bool => if n != 0 { 1 } else { 0 }
  _ => n
}

fn layouts(c: check.Checker): mir.layout.Layouts {
  let info = mir.types.TyInfo { defs: c.defs, value_def: some(c.b.value), err_def: c.b.err }
  mir.layout.new(info, [], "aarch64")
}

fn ci(n: int, t: types.Ty): (typed.ConstVal, types.Ty)? = some((typed.ConstVal.Int(norm(n, t)), t))

fn is_unsigned(t: types.Ty): bool = match t {
  Fixed(k) => !types.fx_signed(k)
  _ => false
}

/// Do constants of types `a` and `b` mix? Equal types, `int` and `i64` (the same machine
/// type), and an error on either side (already reported).
fn same(a: types.Ty, b: types.Ty): bool {
  var inf = types.new_infer()
  a == b || types.can_unify(&inf, a, b)
}

/// `p < q`, unsigned when `u`.
fn less(p: int, q: int, u: bool): bool {
  let min = -9223372036854775807 - 1
  if u { (p ^ min) < (q ^ min) } else { p < q }
}

/// Evaluate a constant expression of the runtime's dialect (the checker hasn't typed it).
fn eval(c: var check.Checker, ev: var Eval, m: int, e: ast.Expr, want: types.Ty?): (typed.ConstVal, types.Ty)? {
  let fx = match want {
    some(Fixed(k)) => some(k)
    _ => none
  }
  match e.kind {
    Lit(l) => match l {
      Int(n) => match fx {
        some(k) when k != types.Fx.F32 => {
          if !check_expr.lit_fits(n, k, false) { return lit_too_big(&c, m, e, n, k, false) }
          ci(n, types.Ty.Fixed(k))
        }
        _ => ci(n, types.Ty.Int)
      }
      Float(x) => {
        let t = if fx == some(types.Fx.F32) { types.Ty.Fixed(types.Fx.F32) } else { types.Ty.Float }
        some((typed.ConstVal.Float(x), t))
      }
      Bool(b) => ci(if b { 1 } else { 0 }, types.Ty.Bool)
      Char(ch) => ci(int(ch), types.Ty.Char)
      Str(_) => not_const(&c, m, e)
    }
    Unary(op, x) => {
      // `-1` where a `u8` is expected doesn't fit (as for a local)
      match (op, x.kind, fx) {
        (Neg, Lit(Int(n)), some(k)) when k != types.Fx.F32 => {
          if !check_expr.lit_fits(n, k, true) { return lit_too_big(&c, m, x, n, k, true) }
          return ci(0 -% n, types.Ty.Fixed(k))
        }
        _ => {}
      }
      let (v, t) = eval(&c, &ev, m, x, want)?
      match v {
        Int(n) => match op {
          Neg => ci(0 -% n, t)
          Not => ci(if n == 0 { 1 } else { 0 }, types.Ty.Bool)
          BitNot => ci(-1 - n, t)
        }
        Float(f) => if op == ast.UnOp.Neg { some((typed.ConstVal.Float(-f), t)) } else { not_const(&c, m, e) }
        _ => not_const(&c, m, e)
      }
    }
    Binary(op, l, r) => {
      let cmp = match op {
        Eq | Ne | Lt | Le | Gt | Ge | And | Or => true
        _ => false
      }
      let lwant = if cmp { none } else { want }
      let (a0, at0) = eval(&c, &ev, m, l, lwant)?
      let (b, bt) = eval(&c, &ev, m, r, some(at0))?
      var a = a0
      var at = at0
      if !same(at, bt) && (l.kind is ast.ExprKind.Lit(_)) {
        let (a2, at2) = eval(&c, &ev, m, l, some(bt))?
        a = a2
        at = at2
      }
      if !same(at, bt) {
        c.err_in(m, diag.new("E0260", e.span, "can't apply `{op.symbol()}` to `{c.defs.show(at)}` and `{c.defs.show(bt)}`"))
        return none
      }
      let u = is_unsigned(at)
      match (a, b) {
        (Int(x), Int(y)) => match op {
          Add | AddWrap => ci(x +% y, at)
          Sub | SubWrap => ci(x -% y, at)
          Mul | MulWrap => ci(x *% y, at)
          Div | Rem => if y == 0 {
            c.err_in(m, diag.new("E0421", r.span, "division by zero in a constant"))
            none
          } else if op == ast.BinOp.Div {
            ci(x / y, at)
          } else {
            ci(x % y, at)
          }
          BitAnd => ci(x & y, at)
          BitOr => ci(x | y, at)
          BitXor => ci(x ^ y, at)
          Shl => ci(x << (y & 63), at)
          Shr => ci(x >> (y & 63), at)
          Eq => ci(if x == y { 1 } else { 0 }, types.Ty.Bool)
          Ne => ci(if x != y { 1 } else { 0 }, types.Ty.Bool)
          Lt => ci(if less(x, y, u) { 1 } else { 0 }, types.Ty.Bool)
          Le => ci(if !less(y, x, u) { 1 } else { 0 }, types.Ty.Bool)
          Gt => ci(if less(y, x, u) { 1 } else { 0 }, types.Ty.Bool)
          Ge => ci(if !less(x, y, u) { 1 } else { 0 }, types.Ty.Bool)
          And => ci(if x != 0 && y != 0 { 1 } else { 0 }, types.Ty.Bool)
          Or => ci(if x != 0 || y != 0 { 1 } else { 0 }, types.Ty.Bool)
          _ => not_const(&c, m, e)
        }
        (Float(x), Float(y)) => match op {
          Add => some((typed.ConstVal.Float(x + y), at))
          Sub => some((typed.ConstVal.Float(x - y), at))
          Mul => some((typed.ConstVal.Float(x * y), at))
          Div => some((typed.ConstVal.Float(x / y), at))
          Eq => ci(if x == y { 1 } else { 0 }, types.Ty.Bool)
          Ne => ci(if x != y { 1 } else { 0 }, types.Ty.Bool)
          Lt => ci(if x < y { 1 } else { 0 }, types.Ty.Bool)
          Gt => ci(if x > y { 1 } else { 0 }, types.Ty.Bool)
          _ => not_const(&c, m, e)
        }
        _ => not_const(&c, m, e)
      }
    }
    Name(n) => {
      let g = c.items[m].globals.get(n) else return not_const(&c, m, e)
      const_global(&c, &ev, m, e, g, n)
    }
    Field(_, _) => {
      // `mod.NAME`: a `pub raw let` of another module
      let (g, n) = path_global(&c, m, e) else return not_const(&c, m, e)
      const_global(&c, &ev, m, e, g, n)
    }
    TypeArgs(x, tys) => {
      var g = check.gen_scope()
      var ts: [types.Ty] = []
      for t in tys { ts.push(c.resolve_type(m, t, &g)) }
      raw_const_call(&c, &ev, m, x, ts, want)
    }
    MethodCall(_, _, _) => raw_const_call(&c, &ev, m, e, [], want)
    Call(callee, args) => match callee.kind {
      Name(n) when args.len() == 1 => {
        let to = match types.fx_of(n) {
          some(k) => types.Ty.Fixed(k)
          none => match n {
            "int" => types.Ty.Int
            "bool" => types.Ty.Bool
            _ => return not_const(&c, m, e)
          }
        }
        let (v, _) = eval(&c, &ev, m, args[0], none)?
        match v {
          Int(k) => ci(k, to)
          Float(x) => if to == types.Ty.Fixed(types.Fx.F32) { some((v, to)) } else { ci(int(x), to) }
          _ => not_const(&c, m, e)
        }
      }
      _ => not_const(&c, m, e)
    }
    Struct(path, fields, base) => {
      let d = match c.lookup_type_path(m, path) {
        some(Def(d)) => d
        _ => return not_const(&c, m, e)
      }
      if !types.is_raw_def(c.defs, d) || base != none { return not_const(&c, m, e) }
      let fs = c.defs.fields(d)
      var out: [(int, typed.ConstVal)] = []
      for fi in fields {
        let i = fs.find_index(f => f.name == fi.name.name) else {
          c.err_in(m, diag.new("E0221", fi.name.span, "the raw struct `{c.defs.types[d].name}` has no field `{fi.name.name}`"))
          return none
        }
        let x = fi.value else return not_const(&c, m, e)
        let (v, t) = eval(&c, &ev, m, x, some(fs[i].ty))?
        if !same(t, fs[i].ty) {
          c.err_in(m, diag.new("E0200", x.span, "expected `{c.defs.show(fs[i].ty)}`, found `{c.defs.show(t)}`"))
        }
        out.push((i, v))
      }
      some((typed.ConstVal.Agg(out), types.Ty.Named(d, [])))
    }
    List(xs) => {
      // a fixed array (`[T; N]`, from the type expected): elements left out are zero
      let (et, n) = match want {
        some(Array(et, n)) when n >= 0 => (et, n)
        _ => return not_const(&c, m, e)
      }
      if xs.len() > n {
        c.err_in(m, diag.new("E0200", e.span, "{xs.len()} elements for a `{c.defs.show(want!)}`"))
        return none
      }
      var out: [(int, typed.ConstVal)] = []
      for i, x in xs {
        let (v, t) = eval(&c, &ev, m, x, some(et))?
        if !same(t, et) {
          c.err_in(m, diag.new("E0200", x.span, "expected `{c.defs.show(et)}`, found `{c.defs.show(t)}`"))
        }
        out.push((i, v))
      }
      some((typed.ConstVal.Agg(out), types.Ty.Array(et, n)))
    }
    _ => not_const(&c, m, e)
  }
}

/// The value of global `g` (named `n`) used in a constant: a `raw let`, evaluated first.
fn const_global(c: var check.Checker, ev: var Eval, m: int, e: ast.Expr, g: int, n: str): (typed.ConstVal, types.Ty)? {
  if c.globals[g].kind != 2 {
    c.err_in(m, diag.new("E0421", e.span, "`{n}` is a `{ast.global_kw(c.globals[g].kind)}`, not a constant").note("only a `raw let` is a compile-time constant"))
    return none
  }
  if ev.state[g] == 1 {
    c.err_in(m, diag.new("E0421", e.span, "`{n}` is defined in terms of itself"))
    return none
  }
  eval_global(&c, &ev, g)
  some((c.globals[g].value, c.globals[g].ty))
}

/// The global named by the path `e` (`mod.NAME`, `a.b.NAME`) and its name: `pub` unless in
/// module `m` itself; none when `e` isn't such a path.
fn path_global(c: var check.Checker, m: int, e: ast.Expr): (int, str)? {
  let path = visit.as_path(e)?
  if path.len() < 2 { return none }
  let target = c.module_of_path(m, path.take(path.len() - 1))?
  let last = path[path.len() - 1]
  let g = c.items[target].globals.get(last.name)?
  if target != m && !c.globals[g].public {
    c.err_in(m, diag.new("E0120", last.span, "`{last.name}` is private to module `{c.prog.name(target)}`").note("mark it `pub` to use it from other modules"))
  }
  (g, last.name)
}

/// E0210 for a literal that doesn't fit the fixed-width type expected.
fn lit_too_big(c: var check.Checker, m: int, e: ast.Expr, n: int, k: types.Fx, neg: bool): (typed.ConstVal, types.Ty)? {
  let sign = if neg { "-" } else { "" }
  c.err_in(m, diag.new("E0210", e.span, "the integer literal {sign}{token.uint_str(n)} doesn't fit in a `{types.fx_name(k)}`"))
  none
}

/// Is `v` an address (or null), as `raw.cast` takes in a constant?
fn is_addr(v: typed.ConstVal): bool = match v {
  GlobalAddr(_) | FnAddr(_) | Zero => true
  _ => false
}

/// `raw.size_of<T>()`, `raw.align_of<T>()`, `raw.offset_of<T>(.f)`, `raw.null()`,
/// `raw.addr_of(&g)`, `raw.fn_of(f)`, `raw.cast(p)` in a constant.
fn raw_const_call(c: var check.Checker, ev: var Eval, m: int, e: ast.Expr, ts: [types.Ty], want: types.Ty?): (typed.ConstVal, types.Ty)? {
  let (recv, name, args) = match e.kind {
    MethodCall(r, n, a) => (r, n, a)
    _ => return not_const(&c, m, e)
  }
  if recv.kind != ast.ExprKind.Name("raw") { return not_const(&c, m, e) }
  let usize = types.Ty.Fixed(types.Fx.Usize)
  let n = name.name
  if (n == "size_of" || n == "align_of") && ts.len() == 1 {
    var l = layouts(c)
    let x = mir.layout.lay(&l, mir.MTy.D(ts[0]))
    return ci(if n == "size_of" { x.size } else { x.align }, usize)
  }
  if n == "offset_of" && ts.len() == 1 && args.len() == 1 {
    let f = match args[0].kind {
      FieldSel(x) => x
      _ => return not_const(&c, m, e)
    }
    let (_, i, _) = raw_field(&c, ts[0], f)?
    var l = layouts(c)
    return ci(mir.layout.offset(&l, mir.MTy.D(ts[0]), mir.Sel.F(i)), usize)
  }
  if n == "null" {
    let t = match ts.get(0) {
      some(x) => types.Ty.Ptr(x)
      none => match want {
        some(Ptr(x)) => types.Ty.Ptr(x)
        _ => {
          c.err_in(m, diag.new("E0360", e.span, "`raw.null()` needs its pointer type here: `raw.null<T>()`"))
          return none
        }
      }
    }
    return some((typed.ConstVal.Zero, t))
  }
  if n == "addr_of" && args.len() == 1 {
    let target = match args[0].kind {
      Ref(x) => x
      _ => return not_const(&c, m, e)
    }
    let (g, gname) = match target.kind {
      Name(n) => (c.items[m].globals.get(n) else return not_const(&c, m, e), n)
      _ => path_global(&c, m, target) else return not_const(&c, m, e)
    }
    let kind = c.globals[g].kind
    if kind == 1 || kind == 2 {
      let why = if kind == 1 { "each thread has its own" } else { "a `raw let` is a value, not memory" }
      c.err_in(m, diag.new("E0421", args[0].span, "the address of `{gname}` isn't a compile-time constant: {why}"))
      return none
    }
    return some((typed.ConstVal.GlobalAddr(g), types.Ty.Ptr(c.globals[g].ty)))
  }
  if n == "fn_of" && args.len() == 1 {
    let path = visit.as_path(args[0]) else return not_const(&c, m, e)
    let fname = path[path.len() - 1].name
    let fm = if path.len() == 1 { m } else { c.module_of_path(m, path.take(path.len() - 1)) else return not_const(&c, m, e) }
    let fs = c.fns_in(m, fm, fname).filter(f => c.fns[f].kind is typed.FnKind.Auk(_, _, _))
    if fs.len() != 1 || c.fns[fs[0]].generics.len() > 0 {
      c.err_in(m, diag.new("E0421", args[0].span, "`raw.fn_of` in a constant takes the name of one non-generic function"))
      return none
    }
    let f = fs[0]
    let info = c.fns[f]
    let ps = info.params.map(p => p.ty)
    let scalar = (t: types.Ty) => match t {
      Int | Float | Bool | Char | Fixed(_) | Ptr(_) | CFn(_, _) => true
      t => types.is_unit(t)
    }
    if !c.is_export(f) && !(ps.all(scalar) && scalar(info.ret)) {
      c.err_in(
        m,
        diag.new("E0202", args[0].span, "`raw.fn_of({fname})`: only an `export fn`, or a function of numbers and raw pointers, has a C address")
          .note("declare it `export fn` (C's calling convention for every type)"),
      )
      return none
    }
    return some((typed.ConstVal.FnAddr(f), types.Ty.CFn(ps, info.ret)))
  }
  if n == "cast" && args.len() == 1 {
    let to = match ts.get(0) {
      some(CFn(ps, r)) => types.Ty.CFn(ps, r)
      some(x) => types.Ty.Ptr(x)
      none => match want {
        some(Ptr(x)) => types.Ty.Ptr(x)
        some(CFn(ps, r)) => types.Ty.CFn(ps, r)
        _ => {
          c.err_in(m, diag.new("E0360", e.span, "`raw.cast` needs its pointer type here: `raw.cast<T>(p)`"))
          return none
        }
      }
    }
    let (v, _) = eval(&c, &ev, m, args[0], none)?
    if !is_addr(v) { return not_const(&c, m, args[0]) }
    return some((v, to))
  }
  not_const(&c, m, e)
}

/// The missing value of `var x: T` (the runtime's dialect): undefined contents of a raw type,
/// as C's uninitialized local.
pub fn uninit(c: var check.Checker, e: ast.Expr, exp: check.Exp): types.Ty {
  let m = c.cur_module()
  if !c.prog.raw_ok(m) {
    c.err(effect_check.raw_only(e.span, "a `var` without a value is the runtime's dialect").note("write `var x: T = value`"))
    return types.Ty.Error
  }
  let t = check.exp_ty(exp) else return types.Ty.Error
  if !check.raw_allowed(c.defs, c.shallow(t)) {
    c.err(
      diag.new("E0419", e.span, "a `var` without a value must have a raw type, not `{c.show(t)}`")
        .note("only numbers, `bool`, raw pointers, raw structs and `[T; N]` start undefined; give it a value"),
    )
  }
  t
}