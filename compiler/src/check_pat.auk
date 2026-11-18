/// Patterns (src/check/pat.rs): type-check a pattern against the matched type and bind its
/// names. (Exhaustiveness and decision trees are patterns.rs's job.)
///
/// `seen` (Rust's `&mut HashMap<String, Span>`) is a `var {str: diag.Span}`.

/// Check `p` against `ty`, binding names in the current scope (`mutable` for `var`).
/// `seen` collects the names bound so far in this pattern (or parameter list) to catch
/// duplicates.
pub fn pattern(c: var check.Checker, p: ast.Pat, ty: types.Ty, mutable: bool, seen: var {str: diag.Span}) {
  c.pat(p, ty, mutable, &seen, true)
}

/// The pattern of `x is pat`: it may not bind names.
pub fn is_pattern(c: var check.Checker, p: ast.Pat, ty: types.Ty) {
  var seen: {str: diag.Span} = {}
  c.pat(p, ty, false, &seen, false)
}

/// The local a pattern binds `n` to: a new one in the current scope, or, in a later
/// alternative of an or-pattern, the one the first alternative bound (same type).
pub fn bind_name(c: var check.Checker, n: str, ty: types.Ty, mutable: bool, span: diag.Span): int {
  match c.or_binds {
    some(first) => match first.get(n) {
      some(l) => {
        let lt = c.local_ty(l)
        if !c.unify(lt, ty) {
          let a = c.show(ty)
          let b = c.show(lt)
          c.err(
            diag.new("E0267", span, "`{n}` is a `{b}` in the first alternative but a `{a}` here")
              .note("every alternative of an or-pattern must bind the same names with the same types"),
          )
        }
        return l
      }
      none => {
        c.err(
          diag.new("E0267", span, "`{n}` is bound here but not in the first alternative")
            .note("every alternative of an or-pattern must bind the same names with the same types; use `_` here or split the arm"),
        )
        return c.new_local(n, ty, mutable, span)
      }
    }
    none => {}
  }
  let l = c.new_local(n, ty, mutable, span)
  c.scope_insert(n, l)
  l
}

/// `A | B`: the first alternative binds the names, the others must bind the same ones.
pub fn or_pat(c: var check.Checker, alts: [ast.Pat], ty: types.Ty, mutable: bool, seen: var {str: diag.Span}, bind: bool) {
  let before = seen.keys()
  c.pat(alts[0], ty, mutable, &seen, bind)
  let scope: {str: int} = if c.cx.scopes.len() > 0 { c.cx.scopes[c.cx.scopes.len() - 1] } else { {} }
  var first: {str: int} = {}
  for k in seen.keys() {
    if before.contains(k) { continue }
    match scope.get(k) {
      some(l) => first[k] = l
      none => {}
    }
  }
  let outer = c.or_binds
  c.or_binds = none
  for alt in alts.skip(1) {
    var s2: {str: diag.Span} = {}
    for k, v in seen {
      if before.contains(k) { s2[k] = v }
    }
    c.or_binds = first
    let n0 = c.errs.len()
    c.pat(alt, ty, mutable, &s2, bind)
    c.or_binds = none
    // a name bound here but not in the first alternative was already reported
    var reported = false
    for d in c.errs.skip(n0) {
      if d.diag.code == "E0267" { reported = true }
    }
    var missing: [str] = []
    for k in first.keys() {
      if !s2.contains(k) { missing.push("`{k}`") }
    }
    if missing.len() > 0 && !reported {
      missing = missing.sort()
      c.err(
        diag.new("E0267", alt.span, "this alternative doesn't bind {missing.join(", ")}, which the first one binds")
          .note("every alternative of an or-pattern must bind the same names with the same types"),
      )
    }
  }
  c.or_binds = outer
}

pub fn pat_mismatch(c: var check.Checker, p: ast.Pat, what: str, ty: types.Ty) {
  let r = c.resolve(ty)
  if r.has_error() { return }
  let ts = c.defs.show(r)
  c.err(diag.new("E0262", p.span, "this pattern matches {what}, but the value is a `{ts}`"))
}

/// The type of a literal.
fn lit_ty(l: ast.Lit): types.Ty = match l {
  Int(_) => types.Ty.Int
  Float(_) => types.Ty.Float
  Bool(_) => types.Ty.Bool
  Char(_) => types.Ty.Char
  Str(_) => types.Ty.Str
}

/// The variants in `vs` whose enum can be the matched `ty` (Rust's `fitting` filter: each
/// candidate gets fresh type arguments, in order), first; else the first of `vs`.
fn pick_variant(c: var check.Checker, vs: [(int, int)], ty: types.Ty): (int, int)? {
  var fitting: [(int, int)] = []
  for v in vs {
    let et = c.fresh_def_cx(v.0)
    if c.can_unify(et, ty) { fitting.push(v) }
  }
  if fitting.len() > 0 { return fitting[0] }
  if vs.len() > 0 { return vs[0] }
  none
}

/// The index of variant `name` of enum `d`, when `t` is that enum.
fn enum_variant(c: check.Checker, t: types.Ty, name: str): (int, int)? = match t {
  Named(d, _) => {
    if !c.defs.is_enum(d) { return none }
    let i = c.defs.variants(d).find_index(v => v.name == name) else return none
    (d, i)
  }
  _ => none
}

pub fn pat(c: var check.Checker, p: ast.Pat, ty: types.Ty, mutable: bool, seen: var {str: diag.Span}, bind: bool) {
  c.cx.t.types[p.id] = ty
  let m = c.cur_module()
  match p.kind {
    Wild => {}
    Bind(n) => {
      // a bare name is the variant of that name when one is in scope (or the matched
      // type is an enum with that variant)
      let st = c.shallow(ty)
      var variant = enum_variant(c, st, n)
      if variant == none {
        let vs = c.variants_in_scope(m, n)
        variant = pick_variant(&c, vs, ty)
      }
      match variant {
        some((d, i)) => {
          c.variant_pat(p, d, i, none, ty, mutable, &seen, bind)
          return
        }
        none => {}
      }
      if !bind {
        c.err(
          diag.new("E0263", p.span, "an `is` pattern can't bind names, but `{n}` would bind one")
            .note("use `_` to match anything, or a `match` / `let ... else` to bind values")
            .fix(p.span, "_"),
        )
        return
      }
      match seen.get(n) {
        some(prev) => {
          c.err(
            diag.new("E0265", p.span, "`{n}` is bound twice in this pattern")
              .note("the first binding is at {diag.show_at(prev)}"),
          )
          return
        }
        none => {}
      }
      seen[n] = p.span
      let l = c.bind_name(n, ty, mutable, p.span)
      c.cx.t.binds[p.id] = l
    }
    Lit(l, neg) => {
      let lt = match l {
        Int(n) => {
          // `n` holds the bits of a u64: over `i64::MAX` is negative here
          let too_big = if neg { n < 0 && n != -9223372036854775807 - 1 } else { n < 0 }
          if too_big {
            c.err(diag.new("E0210", p.span, "the integer literal {token.uint_str(n)} doesn't fit in an `int`"))
          }
          types.Ty.Int
        }
        x => lit_ty(x)
      }
      // zero is zero in every unit of measure
      let zero = match l {
        Int(n) => n == 0
        Float(x) => x == 0.0
        _ => false
      }
      let lt2 = match c.resolve(ty) {
        Measured(b, u) when zero && b == lt => types.Ty.Measured(b, u)
        _ => lt
      }
      if !c.unify(lt2, ty) {
        let what = "a `{c.defs.show(lt2)}`"
        c.pat_mismatch(p, what, ty)
      }
    }
    Tuple(ps) => {
      var ts: [types.Ty] = []
      match c.shallow(ty) {
        Tuple(xs) when xs.len() == ps.len() => ts = xs
        Var(_) => {
          for _ in ps { ts.push(c.fresh()) }
          let _ = c.unify(ty, types.Ty.Tuple(ts))
        }
        Error => for _ in ps { ts.push(types.Ty.Error) }
        _ => {
          c.pat_mismatch(p, "a tuple of {ps.len()} elements", ty)
          for _ in ps { ts.push(types.Ty.Error) }
        }
      }
      for i, q in ps { c.pat(q, ts[i], mutable, &seen, bind) }
    }
    List(head, rest, tail) => {
      let et = match c.shallow(ty) {
        List(e) => e
        Var(_) => {
          let e = c.fresh()
          let _ = c.unify(ty, types.list(e))
          e
        }
        Error => types.Ty.Error
        _ => {
          c.pat_mismatch(p, "a list", ty)
          types.Ty.Error
        }
      }
      for q in head + tail { c.pat(q, et, mutable, &seen, bind) }
      match rest {
        some(r) => match r.pat {
          some(rp) => {
            let lt = if et == types.Ty.Error { types.Ty.Error } else { types.list(et) }
            c.pat(rp, lt, mutable, &seen, bind)
          }
          none => {}
        }
        none => {}
      }
    }
    Variant(path, args) => {
      let st = c.shallow(ty)
      let last = path[path.len() - 1].name
      var found: (int, int)? = none
      if path.len() == 1 { found = enum_variant(c, st, last) }
      if found == none && path.len() == 1 {
        let vs = c.variants_in_scope(m, last)
        found = pick_variant(&c, vs, ty)
      }
      if found == none { found = c.variant_path(m, path) }
      match found {
        some((d, i)) => c.variant_pat(p, d, i, args, ty, mutable, &seen, bind)
        none => {
          let name = path.map(x => x.name).join(".")
          var dg = diag.new("E0102", p.span, "unknown variant `{name}`")
          var is_enum = false
          match st {
            Named(d, _) when c.defs.is_enum(d) => {
              is_enum = true
              let names = c.defs.variants(d).map(v => v.name)
              dg = dg.note("`{c.defs.types[d].name}` has the variants {names.join(", ")}")
              match check.similar(last, names) {
                some(s) => dg = dg.fix(path[path.len() - 1].span, s)
                none => {}
              }
            }
            _ => {}
          }
          if !is_enum {
            dg = dg.note("a variant of another module's enum is written with its path, e.g. `json.Eof(l, c)`")
          }
          c.err(dg)
          match args {
            some(a) => for q in a { c.pat(q, types.Ty.Error, mutable, &seen, bind) }
            none => {}
          }
        }
      }
    }
    Struct(path, fields, rest) => {
      let d = match c.lookup_type_path(m, path) {
        some(check.TypeItem.Def(d)) when c.defs.is_struct(d) => d
        _ => {
          let name = path.map(x => x.name).join(".")
          c.err(diag.new("E0104", p.span, "unknown struct `{name}` in pattern"))
          return
        }
      }
      let (s, args) = c.instantiate_def(d)
      let st = types.Ty.Named(d, args)
      if !c.unify(st, ty) {
        let what = "a `{c.defs.types[d].name}`"
        c.pat_mismatch(p, what, ty)
      }
      let defs = c.defs.fields(d)
      let foreign = c.defs.types[d].module != m
      var out: [(int, int?)] = []
      var given = defs.map(_ => false)
      for f in fields {
        let i = defs.find_index(x => x.name == f.name.name) else {
          let names = defs.map(x => x.name)
          c.err(
            diag.new("E0225", f.name.span, "the struct `{c.defs.types[d].name}` has no field `{f.name.name}`")
              .note("its fields are: {names.join(", ")}"),
          )
          continue
        }
        given[i] = true
        if foreign && !defs[i].public {
          c.err(diag.new("E0121", f.name.span, "the field `{f.name.name}` of `{c.defs.types[d].name}` is private"))
        }
        let ft = defs[i].ty.subst(s)
        match f.pat {
          some(q) => {
            c.pat(q, ft, mutable, &seen, bind)
            out.push((i, none))
          }
          none => {
            if !bind {
              c.err(diag.new("E0263", f.name.span, "an `is` pattern can't bind names; write `{f.name.name}: _`"))
              out.push((i, none))
              continue
            }
            let l = c.bind_name(f.name.name, ft, mutable, f.name.span)
            seen[f.name.name] = f.name.span
            out.push((i, l))
          }
        }
      }
      if !rest {
        var missing: [str] = []
        for i, f in defs {
          if !given[i] { missing.push("`{f.name}`") }
        }
        if missing.len() > 0 {
          let end = diag.Span { line: p.span.end_line, col: p.span.end_col - 1, end_line: p.span.end_line, end_col: p.span.end_col - 1 }
          c.err(
            diag.new("E0266", p.span, "this pattern doesn't mention the field(s) {missing.join(", ")} of `{c.defs.types[d].name}`")
              .note("add `..` to ignore the other fields")
              .fix(end, if fields.len() == 0 { ".." } else { ", .." }),
          )
        }
      }
      c.cx.t.struct_pats[p.id] = typed.StructPat { def: d, fields: out }
    }
    Map(es) => {
      let st = c.shallow(ty)
      let value = types.Ty.Named(c.b.value, [])
      var kt = types.Ty.Error
      var vt = types.Ty.Error
      match st {
        Map(k, v) => {
          kt = k
          vt = v
        }
        Named(d, _) when d == c.b.value => {
          c.cx.t.value_map_pats[p.id] = true
          kt = types.Ty.Str
          vt = value
        }
        Var(_) => {
          kt = c.fresh()
          vt = c.fresh()
          let _ = c.unify(ty, types.map(kt, vt))
        }
        Error => {}
        _ => c.pat_mismatch(p, "a map (or a `Value.Map`)", ty)
      }
      for (k, q) in es {
        let lt = lit_ty(k)
        if !c.unify(lt, kt) {
          let ls = c.defs.show(lt)
          let ks = c.show(kt)
          c.err(diag.new("E0262", q.span, "this map pattern's key is a `{ls}`, but the map's keys are `{ks}`"))
        }
        c.pat(q, vt, mutable, &seen, bind)
      }
    }
    StrPrefix(_, rest) => {
      if !c.unify(types.Ty.Str, ty) { c.pat_mismatch(p, "a `str` (by prefix)", ty) }
      c.pat(rest, types.Ty.Str, mutable, &seen, bind)
    }
    Some(q) => {
      let inner = match c.shallow(ty) {
        Opt(i) => i
        Var(_) => {
          let i = c.fresh()
          let _ = c.unify(ty, types.opt(i))
          i
        }
        Error => types.Ty.Error
        _ => {
          c.pat_mismatch(p, "an optional (`T?`)", ty)
          types.Ty.Error
        }
      }
      c.pat(q, inner, mutable, &seen, bind)
    }
    None => match c.shallow(ty) {
      Opt(_) | Error => {}
      Var(_) => {
        let i = c.fresh()
        let _ = c.unify(ty, types.opt(i))
      }
      _ => c.pat_mismatch(p, "an optional (`T?`)", ty)
    }
    Ok(q) | Err(q) => {
      let is_ok = p.kind is ast.PatKind.Ok(_)
      var ok = types.Ty.Error
      var er = types.Ty.Error
      match c.shallow(ty) {
        Res(o, e) => {
          ok = o
          er = e
        }
        Var(_) => {
          ok = c.fresh()
          er = c.fresh()
          let _ = c.unify(ty, types.res(ok, er))
        }
        Error => {}
        _ => c.pat_mismatch(p, "a result (`T!`)", ty)
      }
      if is_ok {
        c.pat(q, ok, mutable, &seen, bind)
        return
      }
      // `err(BadUrl(w))` on a plain `T!` matches a typed error payload
      let er_s = c.shallow(er)
      if c.defs.is_err(er_s) {
        match c.payload_variant(q) {
          some((d, _)) => {
            let pt = c.fresh_def_cx(d)
            c.cx.t.err_payload_pats[p.id] = pt
            c.pat(q, pt, mutable, &seen, bind)
            return
          }
          none => {}
        }
      }
      c.pat(q, er, mutable, &seen, bind)
    }
    Or(alts) => c.or_pat(alts, ty, mutable, &seen, bind)
  }
}

/// The variant a pattern names, if it is a variant pattern (for typed error payloads).
pub fn payload_variant(c: var check.Checker, q: ast.Pat): (int, int)? {
  let m = c.cur_module()
  match q.kind {
    Variant(path, _) => c.variant_path(m, path)
    Bind(n) => {
      let vs = c.variants_in_scope(m, n)
      if vs.len() > 0 { vs[0] } else { none }
    }
    _ => none
  }
}

pub fn fresh_def_cx(c: var check.Checker, d: int): types.Ty {
  let n = c.defs.types[d].params.len()
  var args: [types.Ty] = []
  for _ in 0..n { args.push(c.fresh()) }
  types.Ty.Named(d, args)
}

pub fn variant_pat(c: var check.Checker, p: ast.Pat, d: int, i: int, args: [ast.Pat]?, ty: types.Ty, mutable: bool, seen: var {str: diag.Span}, bind: bool) {
  let (s, targs) = c.instantiate_def(d)
  let et = types.Ty.Named(d, targs)
  if !c.unify(et, ty) {
    let what = "a `{c.defs.types[d].name}` (variant `{c.defs.variants(d)[i].name}`)"
    c.pat_mismatch(p, what, ty)
  }
  let v = c.defs.variants(d)[i]
  c.cx.t.variants[p.id] = typed.VariantRef { def: d, index: i, args: targs }
  let given = args else []
  if given.len() != v.fields.len() {
    var dg = diag.new("E0264", p.span, "the variant `{v.name}` has {v.fields.len()} field(s), but the pattern has {given.len()}")
    if given.len() == 0 {
      let fill = v.fields.map(_ => "_").join(", ")
      dg = dg.note("write `{v.name}({fill})` to match it whatever its fields").fix(diag.after(p.span), "({fill})")
    }
    c.err(dg)
    for q in given { c.pat(q, types.Ty.Error, mutable, &seen, bind) }
    return
  }
  for k, q in given {
    let ft = v.fields[k].1.subst(s)
    c.pat(q, ft, mutable, &seen, bind)
  }
}
