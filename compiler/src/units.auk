/// Units of measure (src/units.rs; `erase` is the checker's): a unit is its canonical list
/// `[(str, int)]` (Rust's `Units`), base names sorted with non-zero integer exponents. Empty
/// means dimensionless.

pub fn is_none(u: [(str, int)]): bool = u.len() == 0

/// Multiply (`k = 1`) or divide (`k = -1`) by `o`.
pub fn combine(u: [(str, int)], o: [(str, int)], k: int): [(str, int)] {
  var v = u
  for (n, e) in o {
    match v.find_index(x => x.0 == n) {
      some(j) => v[j] = (n, v[j].1 + k * e)
      none => v.push((n, k * e))
    }
  }
  canon(v)
}

/// Raise to an integer power.
pub fn pow(u: [(str, int)], k: int): [(str, int)] = canon(u.map(x => (x.0, x.1 * k)))

/// The `k`-th root, when every exponent is divisible by `k`.
pub fn root(u: [(str, int)], k: int): [(str, int)]? {
  if !u.all(x => x.1 % k == 0) { return none }
  u.map(x => (x.0, x.1 / k))
}

fn canon(v: [(str, int)]): [(str, int)] = v.filter(x => x.1 != 0).sort()

/// When `u` and `o` have the same base names and differ only in exponents, a phrase
/// saying so (`m^2` vs `m`), for diagnostics.
pub fn exponent_hint(u: [(str, int)], o: [(str, int)]): str? {
  if u.map(x => x.0) == o.map(x => x.0) && u != o {
    "they differ only in an exponent"
  } else {
    none
  }
}

/// Rust's `Display`: `kg*m/s^2`: positive exponents first (joined with `*`), then each negative
/// one as `/u^n`; `1/s` when nothing is positive; `1` when dimensionless.
pub fn text(u: [(str, int)]): str {
  let pos = u.filter(x => x.1 > 0).map(x => power(x.0, x.1))
  let neg = u.filter(x => x.1 < 0).map(x => power(x.0, -x.1))
  var out = if pos.len() == 0 { "1" } else { pos.join("*") }
  for n in neg { out += "/{n}" }
  out
}

fn power(n: str, e: int): str = if e == 1 { n } else { "{n}^{e}" }

/// The text between `<` and `>` in canonical form.

/// Parse `kg*m/s^2`: names or `1`, joined by `*` and `/` (left to right), each optionally
/// raised to an integer power `^n` (`n` may be negative). Fails with the reason.
pub fn parse(src: str): [(str, int)]! {
  var toks: [str] = []
  let cs = src.chars()
  var i = 0
  while i < cs.len() {
    let c = cs[i]
    if c == ' ' {
      i += 1
    } else if lexer.is_alphanumeric(c) || c == '_' {
      let from = i
      while i < cs.len() && (lexer.is_alphanumeric(cs[i]) || cs[i] == '_') { i += 1 }
      toks.push(str(cs[from..i]))
    } else {
      toks.push(str(c))
      i += 1
    }
  }
  if toks.len() == 0 { fail("the unit is empty") }
  var v: [(str, int)] = []
  var sign = 1
  var k = 0
  loop {
    let t = toks.get(k) else fail("the unit ends after an operator")
    k += 1
    var name: str? = none
    if t != "1" {
      let c0 = t.chars()[0]
      if !lexer.is_alphabetic(c0) && c0 != '_' { fail("expected a unit name or `1`, found `{t}`") }
      name = t
    }
    var e = 1
    if toks.get(k) == some("^") {
      k += 1
      let neg = toks.get(k) == some("-")
      if neg { k += 1 }
      let n = parse_i32(
        toks.get(k) else "",
      ) else fail("`^` needs an integer exponent, like `s^2` or `s^-1`")
      k += 1
      e = if neg { -n } else { n }
    }
    match name {
      some(n) => v.push((n, sign * e))
      none => {}
    }
    match toks.get(k) {
      none => break
      some("*") => sign = 1
      some("/") => sign = -1
      some(t) => fail("unexpected `{t}` in a unit (units use names, `*`, `/` and `^n`)")
    }
    k += 1
  }
  var out: [(str, int)] = []
  for (n, e) in v {
    match out.find_index(x => x.0 == n) {
      some(j) => out[j] = (n, out[j].1 + e)
      none => out.push((n, e))
    }
  }
  out.filter(x => x.1 != 0).sort()
}

/// Rust's `str::parse::<i32>` for a token of name characters.
fn parse_i32(t: str): int? {
  let cs = t.chars()
  if cs.len() == 0 || cs.len() > 10 { return none }
  var n = 0
  for c in cs {
    if !lexer.is_ascii_digit(c) { return none }
    n = n * 10 + int(c) - int('0')
  }
  if n > 2147483647 { none } else { n }
}

// ---- erasing units (src/units.rs `erase`) ----

/// Remove every unit of measure from a checked program, so codegen only sees plain `int` and
/// `float` (units cost nothing at run time). `check.check` calls it; the language server
/// keeps the units for hovers. `types_used` stays sorted (by `types.cmp`) without duplicates.
pub fn erase(tp: var typed.TypedProgram) {
  for d in 0..tp.defs.types.len() {
    match tp.defs.types[d].kind {
      Struct(fields) => tp.defs.types[d].kind = types.TypeDefKind.Struct(fields.map(f => types.FieldDef { ty: e(f.ty), ..f }))
      Enum(variants) => tp.defs.types[d].kind = types.TypeDefKind.Enum(variants.map(v => types.VariantDef { fields: v.fields.map(f => (f.0, e(f.1))), ..v }))
      Opaque(_) => {}
    }
  }
  for s in 0..tp.defs.shapes.len() {
    tp.defs.shapes[s].methods = tp.defs.shapes[s].methods.map(m => types.ShapeMethod { name: m.name, params: all(m.params), ret: e(m.ret) })
  }
  for f in 0..tp.fns.len() {
    tp.fns[f].params = tp.fns[f].params.map(p => typed.ParamInfo { ty: e(p.ty), ..p })
    tp.fns[f].ret = e(tp.fns[f].ret)
  }
  for k in 0..tp.consts.len() { tp.consts[k].ty = e(tp.consts[k].ty) }
  for m in 0..tp.tables.len() {
    // in place: a copy of the module's tables would copy every map
    for n in tp.tables[m].types.keys() {
      if tp.tables[m].types[n].has_units() { tp.tables[m].types[n] = types.erase_units(tp.tables[m].types[n]) }
    }
    tp.tables[m].locals = tp.tables[m].locals.map(l => typed.LocalInfo { ty: e(l.ty), ..l })
    for n in tp.tables[m].variants.keys() { tp.tables[m].variants[n] = vref(tp.tables[m].variants[n]) }
    for n in tp.tables[m].calls.keys() {
      let cl = tp.tables[m].calls[n]
      tp.tables[m].calls[n] = typed.Call { callee: callee(cl.callee), args: cl.args }
    }
    for n in tp.tables[m].shows.keys() { tp.tables[m].shows[n] = callee(tp.tables[m].shows[n]) }
    for n in tp.tables[m].names.keys() {
      match tp.tables[m].names[n] {
        Fn(func, type_args) => tp.tables[m].names[n] = typed.NameRef.Fn(func, all(type_args))
        Variant(v) => tp.tables[m].names[n] = typed.NameRef.Variant(vref(v))
        _ => {}
      }
    }
    for n in tp.tables[m].struct_lits.keys() {
      let s = tp.tables[m].struct_lits[n]
      tp.tables[m].struct_lits[n] = typed.StructLit { args: all(s.args), ..s }
    }
    for n in tp.tables[m].closures.keys() {
      let c = tp.tables[m].closures[n]
      tp.tables[m].closures[n] = typed.ClosureInfo { params: all(c.params), ret: e(c.ret), ..c }
    }
    for n in tp.tables[m].fails.keys() {
      match tp.tables[m].fails[n] {
        TypedToErr(x) => tp.tables[m].fails[n] = typed.FailKind.TypedToErr(e(x))
        _ => {}
      }
    }
    for n in tp.tables[m].tries.keys() {
      let tr = tp.tables[m].tries[n]
      match tr.conv {
        ToErr(from) => tp.tables[m].tries[n] = typed.TryInfo { kind: tr.kind, conv: typed.ErrConv.ToErr(e(from)) }
        _ => {}
      }
    }
    for n in tp.tables[m].err_payload_pats.keys() { tp.tables[m].err_payload_pats[n] = e(tp.tables[m].err_payload_pats[n]) }
  }
  for i in 0..tp.instances.len() {
    var inst = tp.instances[i]
    inst.type_args = all(inst.type_args)
    for n in inst.resolved.keys() { inst.resolved[n] = target(inst.resolved[n]) }
    for n in inst.shows.keys() { inst.shows[n] = target(inst.shows[n]) }
    tp.instances[i] = inst
  }
  var used: [types.Ty] = []
  for t in tp.types_used { used.push(types.erase_units(t)) }
  used = used.sort()
  var dedup: [types.Ty] = []
  for t in used {
    if dedup.len() == 0 || dedup[dedup.len() - 1] != t { dedup.push(t) }
  }
  tp.types_used = dedup
  var impls: {(types.Builtin, types.Ty): typed.Target} = {}
  for k in tp.shape_impls.keys() { impls[(k.0, types.erase_units(k.1))] = target(tp.shape_impls[k]) }
  tp.shape_impls = impls
  var fv: {types.Ty: typed.Target} = {}
  for k in tp.from_value_impls.keys() { fv[types.erase_units(k)] = target(tp.from_value_impls[k]) }
  tp.from_value_impls = fv
  tp.vtables = tp.vtables.map(v => typed.Vtable { shape: v.shape, ty: e(v.ty), methods: v.methods.map(x => target(x)) })
  match tp.main {
    some(m) => tp.main = typed.MainInfo { ret: e(m.ret), ..m }
    none => {}
  }
}

fn e(t: types.Ty): types.Ty = if t.has_units() { types.erase_units(t) } else { t }

fn all(ts: [types.Ty]): [types.Ty] = ts.map(t => e(t))

fn vref(v: typed.VariantRef): typed.VariantRef = typed.VariantRef { args: all(v.args), ..v }

fn callee(c: typed.Callee): typed.Callee = match c {
  Fn(func, type_args) => typed.Callee.Fn(func, all(type_args))
  Variant(v) => typed.Callee.Variant(vref(v))
  Shape(shape, method, self_ty) => typed.Callee.Shape(shape, method, e(self_ty))
  x => x
}

fn target(t: typed.Target): typed.Target = match t {
  Intrinsic(which, ty) => typed.Target.Intrinsic(which, e(ty))
  Derived(shape, ty) => typed.Target.Derived(shape, e(ty))
  x => x
}
