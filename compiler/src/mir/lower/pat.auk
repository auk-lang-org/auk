/// Patterns (src/mir/lower/pat.rs): a pure test expression per pattern, then a binding step.
/// Bindings own their values (retained copies), except a plain name bound directly to a
/// parameter, a loop element or a closure argument, which borrows it.

fn d(t: types.Ty): mir.MTy = mir.MTy.D(t)

/// A boolean expression: does the value `v` (a place) match `p`? Pure, no bindings (map
/// pattern keys may be declared as variables first).
pub fn pat_test(lw: var mir.lower.Lower, p: ast.Pat, v: mir.Ex): mir.Ex {
  let ty = lw.ty(p.id)
  var conds: [mir.Ex] = []
  test_into(&lw, p, v, ty, &conds)
  mir.and(conds)
}

fn sub_test(lw: var mir.lower.Lower, p: ast.Pat, v: mir.Ex, conds: var [mir.Ex]) {
  let ty = lw.ty(p.id)
  test_into(&lw, p, v, ty, &conds)
}

/// Element `i` of the list `v` (an `[T]` value).
fn list_elem(v: mir.Ex, i: mir.Ex, et: types.Ty): mir.Ex = mir.elem(v, i, d(et))

fn test_into(lw: var mir.lower.Lower, p: ast.Pat, v: mir.Ex, ty: types.Ty, conds: var [mir.Ex]) {
  match p.kind {
    Wild => {}
    Or(ps) => {
      // a || b || c, as !(!a && !b && !c)
      var alts: [mir.Ex] = []
      for q in ps { alts.push(pat_test(&lw, q, v).not()) }
      conds.push(mir.and(alts).not())
    }
    Bind(_) => match lw.t.variants.get(p.id) {
      some(vr) => conds.push(lw.g.variant_tag(ty, vr.index, v))
      none => {}
    }
    Lit(lit, neg) => {
      let c = match lit {
        Int(n) => mir.bin(mir.BOp.Eq, v, mir.int_(if neg { 0 -% n } else { n }))
        Float(x) => mir.bin(mir.BOp.Eq, v, mir.float_(if neg { -x } else { x }))
        Bool(b) => if b { v } else { v.not() }
        Char(c) => mir.bin(mir.BOp.Eq, v, mir.int_as(int(c), d(types.Ty.Char)))
        Str(s) => {
          let l = lw.g.lit(s)
          mir.rt("auk_str_eq", [v, l], d(types.Ty.Bool))
        }
      }
      conds.push(c)
    }
    Tuple(ps) => for i, q in ps {
      let f = lw.fld(v, mir.Sel.F(i))
      sub_test(&lw, q, f, &conds)
    }
    List(head, rest, tail) => {
      let et = match ty {
        List(et) => et
        _ => return
      }
      let n = head.len() + tail.len()
      let len = mir.rt("auk_arr_len", [v], d(types.Ty.Int))
      if rest != none {
        if n > 0 { conds.push(mir.bin(mir.BOp.Ge, len, mir.int_(n))) }
      } else {
        conds.push(mir.bin(mir.BOp.Eq, len, mir.int_(n)))
      }
      for i, q in head {
        let e = list_elem(v, mir.int_(i), et)
        sub_test(&lw, q, e, &conds)
      }
      let tl = tail.len()
      for j, q in tail {
        let idx = mir.bin(mir.BOp.Sub, v.rt_field(mir.RtF.ArrLen), mir.int_(tl - j))
        let e = list_elem(v, idx, et)
        sub_test(&lw, q, e, &conds)
      }
    }
    Variant(_, args) => {
      let vr = lw.t.variants.get(p.id) else return
      conds.push(lw.g.variant_tag(ty, vr.index, v))
      match args {
        some(args) => for fi, q in args {
          let f = lw.g.variant_field(ty, vr.index, fi, v)
          sub_test(&lw, q, f, &conds)
        }
        none => {}
      }
    }
    Struct(_, fields, _) => {
      let sp = lw.t.struct_pats.get(p.id) else return
      for k, fp in fields {
        if k >= sp.fields.len() { break }
        let fi = sp.fields[k].0
        match fp.pat {
          some(q) => {
            let f = lw.g.field_get(ty, fi, v)
            sub_test(&lw, q, f, &conds)
          }
          none => {}
        }
      }
    }
    Map(es) => {
      let value_map = lw.t.value_map_pats.contains(p.id)
      var m = v
      var kt = types.Ty.Str
      var vt = ty
      if value_map {
        let mt = types.Ty.Map(types.Ty.Str, ty)
        m = v.field(mir.Sel.V(6, 0), d(mt))
      } else {
        match ty {
          Map(k, x) => {
            kt = k
            vt = x
          }
          _ => return
        }
      }
      if value_map { conds.push(mir.bin(mir.BOp.Eq, lw.fld(v, mir.Sel.Tag), mir.int_as(6, mir.MTy.I32))) }
      for (k, q) in es {
        let key = key_lit(&lw, k, kt)
        let find = mir.rt("auk_map_find", [m, key], mir.void_ptr())
        conds.push(mir.bin(mir.BOp.Ne, find, mir.null()))
        let val = find.cast(mir.ptr(d(vt))).deref(d(vt))
        sub_test(&lw, q, val, &conds)
      }
    }
    StrPrefix(prefix, _) => {
      let l = lw.g.lit(prefix)
      conds.push(mir.rt("auk_str_starts_with", [v, l], d(types.Ty.Bool)))
    }
    Some(q) => {
      conds.push(lw.fld(v, mir.Sel.F(0)))
      let f = lw.fld(v, mir.Sel.F(1))
      sub_test(&lw, q, f, &conds)
    }
    None => conds.push(lw.fld(v, mir.Sel.F(0)).not())
    Ok(q) => {
      conds.push(lw.fld(v, mir.Sel.F(0)))
      let f = lw.fld(v, mir.Sel.F(1))
      sub_test(&lw, q, f, &conds)
    }
    Err(q) => {
      conds.push(lw.fld(v, mir.Sel.F(0)).not())
      let err = lw.fld(v, mir.Sel.F(2))
      match payload_ty(&lw, p, ty) {
        some(pt) => {
          let id = lw.g.type_id(pt)
          let pl = mir.rt("auk_err_payload", [err, mir.int_as(id, mir.MTy.U32)], mir.void_ptr())
          conds.push(mir.bin(mir.BOp.Ne, pl, mir.null()))
          let val = pl.cast(mir.ptr(d(pt))).deref(d(pt))
          sub_test(&lw, q, val, &conds)
        }
        none => sub_test(&lw, q, err, &conds)
      }
    }
  }
}

/// For `err(q)`: the typed payload's type when `q` matches an error enum value.
fn payload_ty(lw: var mir.lower.Lower, p: ast.Pat, ty: types.Ty): types.Ty? {
  match lw.t.err_payload_pats.get(p.id) {
    some(t) => return lw.sub(t)
    none => {}
  }
  match ty {
    Res(_, e) when !lw.g.is_err_ty(e) => some(e)
    _ => none
  }
}

/// The address of a literal map-pattern key (a variable declared here, or a literal global).
fn key_lit(lw: var mir.lower.Lower, k: ast.Lit, kt: types.Ty): mir.Ex {
  let v = match k {
    Str(s) => {
      let l = lw.g.lit(s)
      return l.addr().cast(mir.void_ptr())
    }
    Int(n) => mir.int_(n)
    Char(c) => mir.int_as(int(c), d(types.Ty.Char))
    Bool(b) => mir.bool_(b)
    Float(x) => mir.float_(x)
  }
  let var_ = lw.bdecl(v)
  var_.addr().cast(mir.void_ptr())
}

/// Bind a parameter / loop element / closure argument: a plain name borrows it.
pub fn bind_top(lw: var mir.lower.Lower, p: ast.Pat, v: mir.Ex, ty: types.Ty) {
  if (p.kind is ast.PatKind.Bind(_)) && !lw.t.variants.contains(p.id) {
    match lw.t.binds.get(p.id) {
      some(l) => lw.bind_name(l, mir.lower.Slot { c: v, ty })
      none => {}
    }
    return
  }
  bind_pat(&lw, p, v, ty)
}

/// Bind the names of `p` (which matched `v`) to owned copies.
pub fn bind_pat(lw: var mir.lower.Lower, p: ast.Pat, v: mir.Ex, ty0: types.Ty) {
  let ty = lw.ty(p.id)
  match p.kind {
    Wild | Lit(_, _) | None => {}
    Or(ps) => bind_or(&lw, ps, v)
    Bind(_) => {
      if lw.t.variants.contains(p.id) { return }
      match lw.t.binds.get(p.id) {
        some(l) => {
          let lt = lw.local_ty(l)
          bind_local(&lw, l, v, lt)
        }
        none => {}
      }
    }
    Tuple(ps) => for i, q in ps {
      let f = lw.fld(v, mir.Sel.F(i))
      bind_sub(&lw, q, f)
    }
    List(head, rest, tail) => {
      let et = match ty {
        List(et) => et
        _ => return
      }
      for i, q in head {
        let e = list_elem(v, mir.int_(i), et)
        bind_sub(&lw, q, e)
      }
      let tl = tail.len()
      for j, q in tail {
        let idx = mir.bin(mir.BOp.Sub, v.rt_field(mir.RtF.ArrLen), mir.int_(tl - j))
        let e = list_elem(v, idx, et)
        bind_sub(&lw, q, e)
      }
      match rest {
        some(r) => match r.pat {
          some(rp) => {
            if rp.kind is ast.PatKind.Wild { return }
            let hi = mir.bin(mir.BOp.Sub, v.rt_field(mir.RtF.ArrLen), mir.int_(tl))
            let slice = mir.rt("auk_arr_slice", [v, mir.int_(head.len()), hi, mir.cstr("")], d(ty))
            let n = lw.decl(ty, slice)
            lw.register_local(n, ty)
            if rp.kind is ast.PatKind.Bind(_) {
              match lw.t.binds.get(rp.id) {
                some(l) => {
                  lw.bind_name(l, mir.lower.Slot { c: n, ty })
                  return
                }
                none => {}
              }
            }
            bind_sub(&lw, rp, n)
          }
          none => {}
        }
        none => {}
      }
    }
    Variant(_, args) => {
      let vr = lw.t.variants.get(p.id) else return
      match args {
        some(args) => for fi, q in args {
          let f = lw.g.variant_field(ty, vr.index, fi, v)
          bind_sub(&lw, q, f)
        }
        none => {}
      }
    }
    Struct(_, fields, _) => {
      let sp = lw.t.struct_pats.get(p.id) else return
      let (dd, args) = match ty {
        Named(dd, args) => (dd, args)
        _ => return
      }
      let s = types.subst_of(lw.tp.defs, dd, args)
      let defs = types.fields(lw.tp.defs, dd)
      for k, fp in fields {
        if k >= sp.fields.len() { break }
        let (fi, short) = sp.fields[k]
        let f = lw.g.field_get(ty, fi, v)
        match (fp.pat, short) {
          (some(q), _) => bind_sub(&lw, q, f)
          (none, some(l)) => {
            let ft = lw.sub(types.subst(defs[fi].ty, s))
            bind_local(&lw, l, f, ft)
          }
          _ => {}
        }
      }
    }
    Map(es) => {
      let value_map = lw.t.value_map_pats.contains(p.id)
      var m = v
      var kt = types.Ty.Str
      var vt = ty
      if value_map {
        let mt = types.Ty.Map(types.Ty.Str, ty)
        m = v.field(mir.Sel.V(6, 0), d(mt))
      } else {
        match ty {
          Map(k, x) => {
            kt = k
            vt = x
          }
          _ => return
        }
      }
      for (k, q) in es {
        let key = key_lit(&lw, k, kt)
        let val = mir.rt("auk_map_find", [m, key], mir.void_ptr()).cast(mir.ptr(d(vt))).deref(d(vt))
        bind_sub(&lw, q, val)
      }
    }
    StrPrefix(prefix, rest) => if rest.kind is ast.PatKind.Bind(_) {
      match lw.t.binds.get(rest.id) {
        some(l) => {
          let nchars = prefix.len()
          let len = mir.rt("auk_str_len", [v], d(types.Ty.Int))
          let s = mir.rt("auk_str_slice", [v, mir.int_(nchars), len, mir.cstr("")], d(types.Ty.Str))
          let n = lw.decl(types.Ty.Str, s)
          lw.register_local(n, types.Ty.Str)
          lw.bind_name(l, mir.lower.Slot { c: n, ty: types.Ty.Str })
        }
        none => {}
      }
    }
    Some(q) | Ok(q) => {
      let f = lw.fld(v, mir.Sel.F(1))
      bind_sub(&lw, q, f)
    }
    Err(q) => {
      let err = lw.fld(v, mir.Sel.F(2))
      match payload_ty(&lw, p, ty) {
        some(pt) => {
          let id = lw.g.type_id(pt)
          let val = mir.rt("auk_err_payload", [err, mir.int_as(id, mir.MTy.U32)], mir.void_ptr()).cast(mir.ptr(d(pt))).deref(d(pt))
          bind_sub(&lw, q, val)
        }
        none => bind_sub(&lw, q, err)
      }
    }
  }
}

/// Bind an or-pattern that matched `v`: every alternative binds the same locals, so declare a
/// variable per local first, then bind the alternative that matches into those variables.
fn bind_or(lw: var mir.lower.Lower, ps: [ast.Pat], v: mir.Ex) {
  let ls = pat_locals(&lw, ps[0])
  if ls.len() == 0 { return }
  var into: {int: mir.Ex} = {}
  for l in ls {
    let lt = lw.local_ty(l)
    let var_ = lw.zero_decl(lt)
    lw.register_local(var_, lt)
    lw.bind_name(l, mir.lower.Slot { c: var_, ty: lt })
    into[l] = var_
  }
  let saved = lw.f.or_into
  lw.f.or_into = into
  let last = ps.len() - 1
  for i, q in ps {
    if i < last {
      let t = pat_test(&lw, q, v)
      lw.open_if(t)
    }
    bind_sub(&lw, q, v)
    if i < last { lw.else_() }
  }
  for _ in 0..last { lw.close() }
  lw.f.or_into = saved
}

/// The locals pattern `p` binds.
fn pat_locals(lw: var mir.lower.Lower, p: ast.Pat): [int] {
  var qs: [ast.Pat] = []
  check_shapes.visit_pat(p, &qs)
  var out: [int] = []
  for q in qs {
    match lw.t.binds.get(q.id) {
      some(l) => out.push(l)
      none => {}
    }
    match lw.t.struct_pats.get(q.id) {
      some(sp) => for (_, l) in sp.fields {
        match l {
          some(l) => out.push(l)
          none => {}
        }
      }
      none => {}
    }
  }
  out
}

fn bind_sub(lw: var mir.lower.Lower, q: ast.Pat, v: mir.Ex) {
  let t = lw.ty(q.id)
  bind_pat(&lw, q, v, t)
}

/// Declare local `l` as an owned (retained) copy of `v`.
fn bind_local(lw: var mir.lower.Lower, l: int, v: mir.Ex, ty: types.Ty) {
  let n = lw.decl(ty, v)
  match lw.g.retain(ty, n) {
    some(r) => lw.emit(r)
    none => {}
  }
  lw.register_local(n, ty)
  lw.bind_name(l, mir.lower.Slot { c: n, ty })
}
