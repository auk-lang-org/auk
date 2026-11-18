/// Shapes (structural fit, derived instances of the built-in shapes) and monomorphization
/// (src/check/shapes.rs).
///
/// Differences from Rust: `fit` returns `str?` (`none`: fits; `some(note)`: what is missing)
/// for Rust's `Result<(), String>`; monomorphization's `index` and `work` are `var` parameters
/// (`{(typed.BodyRef, [types.Ty]): int}` and `[int]`); `types_used` is kept sorted by
/// `types.cmp` (`use_insert`), so iterating it is Rust's `BTreeSet` order. The pattern visitors
/// push every pattern onto a `var [ast.Pat]` (closures can't collect into a captured list).

/// Report unless `ty` fits `shape` (seen from the current module).
pub fn require_fit(c: var check.Checker, ty: types.Ty, shape: int, span: diag.Span, why: str) {
  let m = c.cur_module()
  match c.fit(ty, shape, m) {
    some(note) => {
      let ts = c.defs.show(ty)
      let ss = c.defs.shapes[shape].name
      c.err(diag.new("E0350", span, "`{ts}` doesn't fit the shape `{ss}`, {why}").note(note))
    }
    none => {}
  }
}

/// Does `ty` fit `shape`? `some` carries a note saying what is missing.
pub fn fit(c: var check.Checker, ty: types.Ty, shape: int, m: int): str? {
  var visiting: [(types.Ty, int)] = []
  fit_rec(&c, ty, shape, m, &visiting)
}

fn fit_rec(c: var check.Checker, ty0: types.Ty, shape: int, m: int, visiting: var [(types.Ty, int)]): str? {
  // a unit of measure doesn't change what a number fits
  let ty = types.erase_units(ty0)
  for v in visiting {
    if v.0 == ty && v.1 == shape { return none }
  }
  let sname = c.defs.shapes[shape].name
  match ty {
    Error | Never => return none
    Param(p) => {
      let b = c.defs.params[p].bounds
      if b.contains(shape) || (shape == c.b.eq && b.contains(c.b.ord)) { return none }
      let pn = c.defs.params[p].name
      return "the type parameter `{pn}` isn't declared to fit `{sname}`; add the bound: `<{pn}: {sname}>`"
    }
    Any(s) => {
      if s == shape { return none }
      return "an `any {c.defs.shapes[s].name}` value only fits `{c.defs.shapes[s].name}`"
    }
    _ => {}
  }
  if c.find_impl(shape, ty, m) != none { return none }
  let builtin = c.defs.shapes[shape].builtin else return c.missing_note(shape, ty)
  visiting.push((ty, shape))
  let r = derive_ok(&c, builtin, ty, shape, m, &visiting)
  let _ = visiting.pop()
  r
}

pub fn missing_note(c: check.Checker, shape: int, ty: types.Ty): str {
  let s = c.defs.shapes[shape]
  let ts = c.defs.show(ty)
  var sub: {int: types.Ty} = {}
  sub[s.self_param] = ty
  var sigs: [str] = []
  for me in s.methods {
    var ps: [str] = []
    for i, p in me.params {
      if i == 0 { ps.push("x: {ts}") } else { ps.push("p{i}: {c.defs.show(p.subst(sub))}") }
    }
    sigs.push("fn {me.name}({ps.join(", ")}): {c.defs.show(me.ret.subst(sub))}")
  }
  "`{s.name}` fits a type that has {sigs.join(" and ")}; no such function exists for `{ts}`"
}

/// `fit_rec` of each component, stopping at the first that doesn't fit (Rust's `comps`).
fn comps(c: var check.Checker, tys: [types.Ty], shape: int, m: int, v: var [(types.Ty, int)]): str? {
  for t in tys {
    match fit_rec(&c, t, shape, m, &v) {
      some(e) => return e
      none => {}
    }
  }
  none
}

/// Whether the compiler can derive built-in shape `b` for `ty` (its components must fit).
fn derive_ok(c: var check.Checker, b: types.Builtin, ty: types.Ty, shape: int, m: int, v: var [(types.Ty, int)]): str? {
  let ts = c.defs.show(ty)
  match (b, ty) {
    (_, Int) | (_, Float) | (_, Bool) | (_, Char) | (_, Str) => none
    (Ord, List(t)) => comps(&c, [t], shape, m, &v)
    (Ord, Tuple(xs)) => comps(&c, xs, shape, m, &v)
    (Ord, _) =>
      "`Ord` is automatic only for numbers, chars, strings, bools, and lists and tuples of them; define `fn cmp(a: {ts}, b: {ts}): int` (negative, 0 or positive)"
    (Data, Tuple(_)) => "tuples don't convert to `Value`; use a struct"
    (Data, Map(k, val)) => {
      if k != types.Ty.Str { return "only maps with `str` keys convert to `Value`, not `{ts}`" }
      comps(&c, [val], shape, m, &v)
    }
    (Data, Res(_, _)) => "`T!` values don't convert to `Value`"
    (_, Tuple(xs)) => comps(&c, xs, shape, m, &v)
    (_, List(t)) | (_, Opt(t)) => comps(&c, [t], shape, m, &v)
    (_, Map(k, val)) => comps(&c, [k, val], shape, m, &v)
    (_, Res(t, e)) => comps(&c, [t, e], shape, m, &v)
    (_, Named(d, args)) => {
      if d == c.b.value { return none }
      let s = c.defs.subst_of(d, args)
      var fields: [types.Ty] = []
      match c.defs.types[d].kind {
        Struct(fs) => for f in fs { fields.push(f.ty.subst(s)) }
        Enum(vs) => for vr in vs {
          for f in vr.fields { fields.push(f.1.subst(s)) }
        }
        // C pointers compare and print by address
        Opaque(c_type) => {
          if !c_type.starts_with("Auk") && (shape == c.b.show || shape == c.b.eq) { return none }
          return "`{ts}` is a runtime type without a `{c.defs.shapes[shape].name}` instance"
        }
      }
      for f in fields {
        match fit_rec(&c, f, shape, m, &v) {
          some(e) => {
            let fs = c.defs.show(f)
            return "`{ts}` has a field of type `{fs}`: {e}"
          }
          none => {}
        }
      }
      none
    }
    (_, Fn(_, _)) => "closures don't fit the built-in shapes"
    (_, Task(_)) => "tasks don't fit the built-in shapes; `await` them first"
    _ => "`{ts}` doesn't fit `{c.defs.shapes[shape].name}`"
  }
}

/// User (or core) functions implementing every method of `shape` for `ty`: for each
/// method, the function and its type arguments. Searched in `m`, then `ty`'s module, then
/// core. A function whose first parameter is a bare type parameter doesn't count (that would
/// be a generic over the shape itself).
pub fn find_impl(c: var check.Checker, shape: int, ty: types.Ty, m: int): [(int, [types.Ty])]? {
  let sh = c.defs.shapes[shape]
  var tiers = [m]
  match ty {
    Named(d, _) => {
      let home = c.defs.types[d].module
      if !tiers.contains(home) { tiers.push(home) }
    }
    _ => {}
  }
  let core = c.prog.core_root
  if !tiers.contains(core) { tiers.push(core) }
  var sub: {int: types.Ty} = {}
  sub[sh.self_param] = ty
  var out: [(int, [types.Ty])] = []
  for meth in sh.methods {
    var found = false
    for tier in tiers {
      let cands = if tier == core { c.items[core].fns.get(meth.name) else [] } else { c.fns_in(m, tier, meth.name) }
      for f in cands {
        let info = c.fns[f]
        if info.params.len() != meth.params.len() || info.params[0].ty is types.Ty.Param(_) { continue }
        var inf = types.new_infer()
        var s: {int: types.Ty} = {}
        for g in info.generics { s[g] = types.fresh(&inf) }
        var ok = types.unify(&inf, info.params[0].ty.subst(s), ty)
        for k, mp in meth.params {
          if k == 0 { continue }
          ok = ok && types.unify(&inf, info.params[k].ty.subst(s), mp.subst(sub))
        }
        ok = ok && types.unify(&inf, info.ret.subst(s), meth.ret.subst(sub))
        if ok {
          out.push((f, info.generics.map(g => types.resolve(inf, s[g]))))
          found = true
          break
        }
      }
      if found { break }
    }
    if !found { return none }
  }
  out
}

// ---- monomorphization ----

pub fn monomorphize(c: var check.Checker) {
  var index: {(typed.BodyRef, [types.Ty]): int} = {}
  var work: [int] = []
  for f in 0..c.fns.len() {
    if c.fns[f].kind is typed.FnKind.Auk(_, _, _) && c.fns[f].generics.len() == 0 {
      let _ = instance_of(&c, typed.BodyRef.Fn(f), [], &index, &work)
    }
  }
  for t in 0..c.tests.len() {
    let _ = instance_of(&c, typed.BodyRef.Test(t), [], &index, &work)
  }
  for k in 0..c.consts.len() {
    let _ = instance_of(&c, typed.BodyRef.Const(k), [], &index, &work)
  }
  var ops_done = 0
  loop {
    while work.len() > 0 {
      let i = work.pop() else 0
      process_instance(&c, i, &index, &work)
    }
    // element ops: Show/Eq/Ord of every list and map element type that has them
    let used = c.types_used
    if used.len() == ops_done { break }
    ops_done = used.len()
    for t in used {
      let elems: [types.Ty] = match t {
        List(e) => [e]
        Map(k, v) => [k, v]
        _ => []
      }
      for e in elems {
        for (b, s) in [(types.Builtin.Show, c.b.show), (types.Builtin.Eq, c.b.eq), (types.Builtin.Ord, c.b.ord)] {
          let root = c.prog.root
          if !c.shape_impls.contains((b, e)) {
            match fit_from(&c, e, s, root) {
              some(from) => {
                let _ = impl_target(&c, s, 0, e, from, &index, &work)
              }
              none => {}
            }
          }
        }
      }
    }
    if work.len() == 0 { break }
  }
}

fn process_instance(c: var check.Checker, i: int, index: var {(typed.BodyRef, [types.Ty]): int}, work: var [int]) {
  let body = c.instances[i].body
  let subst = typed.inst_subst(c.instances[i], c.fns)
  let nodes = c.body_nodes.get(body) else check.new_body_nodes()
  let m = nodes.module
  var resolved: {int: typed.Target} = {}
  for n in nodes.calls {
    let call = c.tables[m].calls.get(n) else continue
    let t = resolve_target(&c, call.callee, subst, m, &index, &work)
    resolved[n] = t
  }
  for n in nodes.fn_refs {
    match c.tables[m].names.get(n) {
      some(Fn(func, type_args)) => {
        let args = type_args.map(t => t.subst(subst))
        let t = fn_target(&c, func, args, m, &index, &work)
        resolved[n] = t
      }
      _ => {}
    }
  }
  var shows: {int: typed.Target} = {}
  for n in nodes.shows {
    let callee = c.tables[m].shows.get(n) else continue
    let t = resolve_target(&c, callee, subst, m, &index, &work)
    shows[n] = t
  }
  var vts: {int: int} = {}
  for n in nodes.anys {
    let ty0 = c.tables[m].types.get(n) else continue
    let ty = ty0.subst(subst)
    let cs = c.tables[m].coercions.get(n) else continue
    for co in cs {
      match co {
        ToAny(s) => {
          let vt = vtable(&c, s, ty, m, &index, &work)
          vts[n] = vt
        }
        _ => {}
      }
    }
  }
  c.instances[i].resolved = resolved
  c.instances[i].shows = shows
  c.instances[i].vtables = vts
  // concrete types used by this instance
  var tys: [types.Ty] = []
  body_types(c, body, &tys)
  for t in tys {
    use_type(&c, t.subst(subst))
  }
}

fn instance_of(c: var check.Checker, body: typed.BodyRef, args0: [types.Ty], index: var {(typed.BodyRef, [types.Ty]): int}, work: var [int]): int {
  // units are erased: `sum` of `[float<m>]` and of `[float]` is one instance
  let args = args0.map(t => types.erase_units(t))
  match index.get((body, args)) {
    some(i) => return i
    none => {}
  }
  let i = c.instances.len()
  c.instances.push(typed.Instance { body, type_args: args, resolved: {}, shows: {}, vtables: {} })
  index[(body, args)] = i
  work.push(i)
  i
}

fn resolve_target(c: var check.Checker, callee: typed.Callee, subst: {int: types.Ty}, m: int, index: var {(typed.BodyRef, [types.Ty]): int}, work: var [int]): typed.Target {
  match callee {
    Fn(func, type_args) => {
      let args = type_args.map(t => t.subst(subst))
      fn_target(&c, func, args, m, &index, &work)
    }
    Variant(v) => typed.Target.Variant(v.def, v.index)
    Closure => typed.Target.Closure
    Vtable(shape, method) => typed.Target.Vtable(shape, method)
    Shape(shape, method, self_ty) => {
      let t = self_ty.subst(subst)
      impl_target(&c, shape, method, t, m, &index, &work)
    }
  }
}

fn fn_target(c: var check.Checker, f: int, args0: [types.Ty], m: int, index: var {(typed.BodyRef, [types.Ty]): int}, work: var [int]): typed.Target {
  let args = args0.map(t => types.erase_units(t))
  match c.fns[f].kind {
    Auk(_, _, _) => typed.Target.Instance(instance_of(&c, typed.BodyRef.Fn(f), args, &index, &work))
    Extern(symbol, loc, _) => typed.Target.Extern(symbol, loc)
    Ffi(_, _, _) => typed.Target.Ffi(f)
    Intrinsic(which, _) => {
      let ty = if args.len() > 0 { args[0] } else { types.unit() }
      let shape: int? = match which {
        Show => c.b.show
        Eq => c.b.eq
        Cmp => c.b.ord
        ToValue => c.b.data
        _ => none
      }
      match shape {
        some(s) when !(ty is types.Ty.Param(_)) => {
          let t = impl_target(&c, s, 0, ty, m, &index, &work)
          if t is typed.Target.Derived(_, _) { typed.Target.Intrinsic(which, ty) } else { t }
        }
        _ => if which == typed.Intrinsic.FromValue && !ty.has_params() {
          // `core.from_value(v): D` uses a user `fn from_value(v: Value): D!` like
          // `core.to_value(d)` uses a user `to_value(d: D)` (#523)
          let ty2 = types.erase_units(ty)
          resolve_from_value(&c, ty2, [m], &index, &work)
          match c.from_value_impls.get(ty2) {
            some(t) => t
            none => typed.Target.Intrinsic(which, ty2)
          }
        } else {
          typed.Target.Intrinsic(which, ty)
        }
      }
    }
  }
}

/// How method `method` of `shape` is implemented for the concrete `ty`.
fn impl_target(c: var check.Checker, shape: int, method: int, ty0: types.Ty, m: int, index: var {(typed.BodyRef, [types.Ty]): int}, work: var [int]): typed.Target {
  let ty = types.erase_units(ty0)
  let builtin = c.defs.shapes[shape].builtin
  match builtin {
    some(b) => match c.shape_impls.get((b, ty)) {
      some(t) => return t
      none => {}
    }
    none => {}
  }
  // A user function in `m`'s view, else one in the type's own module even if private
  // there (`fn cmp(a: Item, b: Item)` next to `struct Item`): generic code instantiated
  // elsewhere (core's `sort`) can't name it, but it still implements the shape.
  var found: ([(int, [types.Ty])], int)? = none
  match c.find_impl(shape, ty, m) {
    some(fs) => found = (fs, m)
    none => match home_module(c, ty) {
      some(h) when h != m => match c.find_impl(shape, ty, h) {
        some(fs) => found = (fs, h)
        none => {}
      }
      _ => {}
    }
  }
  let t = match found {
    some((fns, from)) => {
      let fa = fns[method]
      fn_target(&c, fa.0, fa.1, from, &index, &work)
    }
    none => match builtin {
      some(b) => {
        c.shape_impls[(b, ty)] = typed.Target.Derived(b, ty)
        derived_components(&c, b, ty, m, &index, &work)
        typed.Target.Derived(b, ty)
      }
      none => typed.Target.Derived(types.Builtin.Show, ty)
    }
  }
  match builtin {
    some(b) => c.shape_impls[(b, ty)] = t
    none => {}
  }
  t
}

fn is_prim_ty(t: types.Ty): bool = match t {
  Int | Float | Bool | Char | Str => true
  _ => false
}

/// Record how `from_value` makes a `ty`: a user `fn from_value(v: Value): T!` (in
/// `from_value_impls`), else derived, structurally, with each field and element type
/// resolved the same way. The derived `from_value` is the inverse of the derived
/// `to_value`, which calls a user `to_value` for components, so a custom form nested in a
/// struct, list, map or optional must be read back by the matching user `from_value` (#523).
/// The user function is looked for in `mods` (the requesting module, then the modules of the
/// enclosing types) and in `ty`'s own module, private functions included there.
fn resolve_from_value(c: var check.Checker, ty: types.Ty, mods: [int], index: var {(typed.BodyRef, [types.Ty]): int}, work: var [int]) {
  if is_prim_ty(ty) || ty.has_params() || c.from_value_seen.contains(ty) { return }
  c.from_value_seen[ty] = true
  var tiers = mods
  match home_module(c, ty) {
    some(h) => if !tiers.contains(h) { tiers.push(h) }
    none => {}
  }
  match find_from_value(c, ty, tiers) {
    some((f, args, from)) => {
      let t = fn_target(&c, f, args, from, &index, &work)
      c.from_value_impls[ty] = t
      return
    }
    none => {}
  }
  for comp in components(c, ty) {
    resolve_from_value(&c, types.erase_units(comp), tiers, &index, &work)
  }
}

/// A non-core `fn from_value(v: Value): T!` that makes `ty` (generic ones included, except
/// one returning a bare type parameter, which would just be a wrapper of core's), from the
/// first of `tiers` that has one.
fn find_from_value(c: check.Checker, ty: types.Ty, tiers: [int]): (int, [types.Ty], int)? {
  let value = types.Ty.Named(c.b.value, [])
  for tier in tiers {
    if c.prog.is_core(tier) { continue }
    for f in c.fns_in(tier, tier, "from_value") {
      let info = c.fns[f]
      if info.params.len() != 1 || info.params[0].ty != value { continue }
      match info.ret {
        Res(ok, er) => {
          if ok is types.Ty.Param(_) || !c.defs.is_err(er) { continue }
          var inf = types.new_infer()
          var s: {int: types.Ty} = {}
          for g in info.generics { s[g] = types.fresh(&inf) }
          if types.unify(&inf, ok.subst(s), ty) {
            let targs = info.generics.map(g => types.resolve(inf, s[g]))
            return (f, targs, tier)
          }
        }
        _ => continue
      }
    }
  }
  none
}

/// The component types of a derived instance: element, field and variant field types.
fn components(c: check.Checker, ty: types.Ty): [types.Ty] = match ty {
  List(t) | Opt(t) => [t]
  Map(k, v) => [k, v]
  Res(t, e) => [t, e]
  Tuple(ts) => ts
  Named(d, args) => named_fields(c, d, args)
  _ => []
}

/// The field types of a struct, or every variant field type of an enum, substituted.
fn named_fields(c: check.Checker, d: int, args: [types.Ty]): [types.Ty] {
  let s = c.defs.subst_of(d, args)
  var out: [types.Ty] = []
  match c.defs.types[d].kind {
    Struct(fields) => for f in fields { out.push(f.ty.subst(s)) }
    Enum(variants) => for v in variants {
      for f in v.fields { out.push(f.1.subst(s)) }
    }
    _ => {}
  }
  out
}

/// Make sure the components of a derived instance have their own instances recorded.
fn derived_components(c: var check.Checker, b: types.Builtin, ty: types.Ty, m: int, index: var {(typed.BodyRef, [types.Ty]): int}, work: var [int]) {
  let shape = match b {
    Show => c.b.show
    Eq => c.b.eq
    Ord => c.b.ord
    Data => c.b.data
  }
  for comp in components(c, ty) {
    let t = types.erase_units(comp)
    if is_prim_ty(t) || t.has_params() { continue }
    if !c.shape_impls.contains((b, t)) {
      match fit_from(&c, t, shape, m) {
        some(from) => {
          let _ = impl_target(&c, shape, 0, t, from, &index, &work)
        }
        none => {}
      }
    }
  }
}

/// The module of a struct or enum type's definition.
fn home_module(c: check.Checker, ty: types.Ty): int? = match ty {
  Named(d, _) => c.defs.types[d].module
  _ => none
}

/// Does `ty` fit `shape` seen from `m`, or else from its own module (where its private
/// shape functions are visible)? The module to resolve the implementation from.
fn fit_from(c: var check.Checker, ty: types.Ty, shape: int, m: int): int? {
  if c.fit(ty, shape, m) == none { return m }
  let home = home_module(c, ty) else return none
  if home == m { return none }
  if c.fit(ty, shape, home) == none { home } else { none }
}

fn vtable(c: var check.Checker, shape: int, ty0: types.Ty, m: int, index: var {(typed.BodyRef, [types.Ty]): int}, work: var [int]): int {
  let ty = types.erase_units(ty0)
  for i, v in c.vtables {
    if v.shape == shape && v.ty == ty { return i }
  }
  let n = c.defs.shapes[shape].methods.len()
  var methods: [typed.Target] = []
  for k in 0..n { methods.push(impl_target(&c, shape, k, ty, m, &index, &work)) }
  c.vtables.push(typed.Vtable { shape, ty, methods })
  c.vtables.len() - 1
}

/// Insert `t` into the sorted `types_used` (Rust's `BTreeSet::insert`).
fn use_insert(c: var check.Checker, t: types.Ty) {
  c.types_used_set[t] = true
  var lo = 0
  var hi = c.types_used.len()
  while lo < hi {
    let mid = (lo + hi) / 2
    if types.cmp(c.types_used[mid], t) < 0 { lo = mid + 1 } else { hi = mid }
  }
  c.types_used.insert(lo, t)
}

/// Record a concrete type and its components in `types_used`.
fn use_type(c: var check.Checker, t: types.Ty) {
  if t.has_units() { return use_type(&c, types.erase_units(t)) }
  if t.has_params() || t.has_error() || t.has_vars() || c.types_used_set.contains(t) { return }
  if t == types.Ty.Never { return }
  use_insert(&c, t)
  for ch in types.children(t) { use_type(&c, ch) }
  match t {
    Named(d, args) => for x in named_fields(c, d, args) { use_type(&c, x) }
    _ => {}
  }
}

/// Every type recorded for the expressions, patterns and parameters of a body.
fn body_types(c: check.Checker, body: typed.BodyRef, out: var [types.Ty]) {
  var m = 0
  var item = 0
  var clauses: [int]? = none
  match body {
    Fn(f) => match c.fns[f].kind {
      Auk(it, cs, _) => {
        m = c.fns[f].module
        item = it
        clauses = cs
      }
      _ => return
    }
    Test(t) => {
      m = c.tests[t].module
      item = c.tests[t].item
    }
    Const(k) => {
      m = c.consts[k].module
      item = c.consts[k].item
    }
  }
  let tables = c.tables[m]
  let it = c.prog.mods[m].ast.items[item]
  match body {
    Fn(f) => {
      for p in c.fns[f].params { out.push(p.ty) }
      out.push(c.fns[f].ret)
    }
    _ => {}
  }
  var ids: [int] = []
  match (it, clauses) {
    (Fn(g), some(cs)) => for ci in cs {
      let cl = g.clauses[ci]
      for p in cl.params {
        var ps: [ast.Pat] = []
        visit_pat(p.pat, &ps)
        for q in ps { ids.push(q.id) }
      }
      let one = ast.Item.Fn(ast.FnGroup { name: g.name, arity: g.arity, header: none, clauses: [cl] })
      expr_ids(one, &ids)
    }
    _ => expr_ids(it, &ids)
  }
  for id in ids {
    match tables.types.get(id) {
      some(t) => out.push(t)
      none => {}
    }
  }
}

/// The ids of every expression of `item` and of the patterns directly inside each, in
/// Rust's visiting order.
fn expr_ids(item: ast.Item, ids: var [int]) {
  var es: [ast.Expr] = []
  visit.visit_item_exprs(item, &es)
  for e in es {
    ids.push(e.id)
    var ps: [ast.Pat] = []
    visit_expr_pats(e, &ps)
    for q in ps { ids.push(q.id) }
  }
}

/// The patterns directly inside an expression (let, match arms, for, closure params, is).
pub fn visit_expr_pats(e: ast.Expr, out: var [ast.Pat]) {
  match e.kind {
    Let(_, p, _, _, _) | Is(_, p) => visit_pat(p, &out)
    Match(_, arms) => for a in arms { visit_pat(a.pat, &out) }
    For(index, p, _, _) => {
      match index {
        some(i) => visit_pat(i, &out)
        none => {}
      }
      visit_pat(p, &out)
    }
    Closure(params, _) => for p in params { visit_pat(p.pat, &out) }
    _ => {}
  }
}

/// `p` and every pattern inside it, pre-order.
pub fn visit_pat(p: ast.Pat, out: var [ast.Pat]) {
  out.push(p)
  match p.kind {
    Tuple(ps) => for q in ps { visit_pat(q, &out) }
    List(head, rest, tail) => {
      for q in head + tail { visit_pat(q, &out) }
      match rest {
        some(r) => match r.pat {
          some(q) => visit_pat(q, &out)
          none => {}
        }
        none => {}
      }
    }
    Variant(_, some(a)) => for q in a { visit_pat(q, &out) }
    Struct(_, fields, _) => for x in fields {
      match x.pat {
        some(q) => visit_pat(q, &out)
        none => {}
      }
    }
    Map(es) => for (_, q) in es { visit_pat(q, &out) }
    StrPrefix(_, rest) => visit_pat(rest, &out)
    Some(q) | Ok(q) | Err(q) => visit_pat(q, &out)
    Or(ps) => for q in ps { visit_pat(q, &out) }
    _ => {}
  }
}
