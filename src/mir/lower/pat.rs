//! Patterns: a pure test expression per pattern, then a binding step. Bindings own their values
//! (retained copies), except a plain name bound directly to a parameter, a loop element or a
//! closure argument, which borrows it.

use super::{Lower, Slot};
use crate::ast::{Lit, Pat, PatKind};
use crate::mir::progen::d;
use crate::mir::{BOp, Ex, MTy, RtF, Sel};
use crate::types::Ty;

impl Lower<'_, '_> {
    /// A boolean expression: does the value `v` (a place) match `p`? Pure, no bindings (map
    /// pattern keys may be declared as variables first).
    pub(super) fn pat_test(&mut self, p: &Pat, v: &Ex) -> Ex {
        let ty = self.ty(p.id);
        let mut conds: Vec<Ex> = Vec::new();
        self.test_into(p, v, &ty, &mut conds);
        Ex::and(conds)
    }

    fn sub_test(&mut self, p: &Pat, v: &Ex, conds: &mut Vec<Ex>) {
        let ty = self.ty(p.id);
        self.test_into(p, v, &ty, conds);
    }

    /// Element `i` of the list `v` (an `[T]` value).
    fn list_elem(&self, v: &Ex, i: Ex, et: &Ty) -> Ex {
        Ex::elem(v.clone(), i, d(et))
    }

    fn test_into(&mut self, p: &Pat, v: &Ex, ty: &Ty, conds: &mut Vec<Ex>) {
        match &p.kind {
            PatKind::Wild => {}
            PatKind::Bind(_) => {
                if let Some(vr) = self.t.variants.get(&p.id).cloned() {
                    conds.push(self.g.variant_tag(ty, vr.index, v));
                }
            }
            PatKind::Lit { lit, neg } => {
                let c = match lit {
                    Lit::Int(n) => {
                        let n = if *neg { (*n as i64).wrapping_neg() } else { *n as i64 };
                        Ex::bin(BOp::Eq, v.clone(), Ex::int(n))
                    }
                    Lit::Float(x) => {
                        let x = if *neg { -x } else { *x };
                        Ex::bin(BOp::Eq, v.clone(), Ex::float(x))
                    }
                    Lit::Bool(b) => {
                        if *b {
                            v.clone()
                        } else {
                            v.clone().not()
                        }
                    }
                    Lit::Char(c) => Ex::bin(BOp::Eq, v.clone(), Ex::int_as(*c as i64, MTy::D(Ty::Char))),
                    Lit::Str(s) => {
                        let l = self.g.lit(s);
                        Ex::rt("duck_str_eq", vec![v.clone(), l], MTy::D(Ty::Bool))
                    }
                };
                conds.push(c);
            }
            PatKind::Tuple(ps) => {
                for (i, q) in ps.iter().enumerate() {
                    let f = self.fld(v, Sel::F(i as u32));
                    self.sub_test(q, &f, conds);
                }
            }
            PatKind::List { head, rest, tail } => {
                let Ty::List(et) = ty else { return };
                let n = (head.len() + tail.len()) as i64;
                let len = Ex::rt("duck_arr_len", vec![v.clone()], MTy::D(Ty::Int));
                if rest.is_some() {
                    if n > 0 {
                        conds.push(Ex::bin(BOp::Ge, len, Ex::int(n)));
                    }
                } else {
                    conds.push(Ex::bin(BOp::Eq, len, Ex::int(n)));
                }
                for (i, q) in head.iter().enumerate() {
                    let e = self.list_elem(v, Ex::int(i as i64), et);
                    self.sub_test(q, &e, conds);
                }
                let tl = tail.len() as i64;
                for (j, q) in tail.iter().enumerate() {
                    let idx = Ex::bin(BOp::Sub, v.clone().rt_field(RtF::ArrLen), Ex::int(tl - j as i64));
                    let e = self.list_elem(v, idx, et);
                    self.sub_test(q, &e, conds);
                }
            }
            PatKind::Variant { args, .. } => {
                let Some(vr) = self.t.variants.get(&p.id).cloned() else { return };
                conds.push(self.g.variant_tag(ty, vr.index, v));
                if let Some(args) = args {
                    for (fi, q) in args.iter().enumerate() {
                        let f = self.g.variant_field(ty, vr.index, fi, v);
                        self.sub_test(q, &f, conds);
                    }
                }
            }
            PatKind::Struct { fields, .. } => {
                let Some(sp) = self.t.struct_pats.get(&p.id).cloned() else { return };
                for (fp, (fi, _)) in fields.iter().zip(&sp.fields) {
                    if let Some(q) = &fp.pat {
                        let f = self.g.field_get(ty, *fi, v);
                        self.sub_test(q, &f, conds);
                    }
                }
            }
            PatKind::Map(es) => {
                let value_map = self.t.value_map_pats.contains(&p.id);
                let (m, kt, vt) = if value_map {
                    let mt = Ty::Map(Box::new(Ty::Str), Box::new(ty.clone()));
                    (v.clone().field(Sel::V(6, 0), d(&mt)), Ty::Str, ty.clone())
                } else {
                    match ty {
                        Ty::Map(k, x) => (v.clone(), (**k).clone(), (**x).clone()),
                        _ => return,
                    }
                };
                if value_map {
                    conds.push(Ex::bin(BOp::Eq, self.fld(v, Sel::Tag), Ex::int_as(6, MTy::I32)));
                }
                for (k, q) in es {
                    let key = self.key_lit(k, &kt);
                    let find = Ex::rt("duck_map_find", vec![m.clone(), key], MTy::void_ptr());
                    conds.push(Ex::bin(BOp::Ne, find.clone(), Ex::null()));
                    let val = find.cast(MTy::ptr(d(&vt))).deref(d(&vt));
                    self.sub_test(q, &val, conds);
                }
            }
            PatKind::StrPrefix { prefix, .. } => {
                let l = self.g.lit(prefix);
                conds.push(Ex::rt("duck_str_starts_with", vec![v.clone(), l], MTy::D(Ty::Bool)));
            }
            PatKind::Some(q) => {
                conds.push(self.fld(v, Sel::F(0)));
                let f = self.fld(v, Sel::F(1));
                self.sub_test(q, &f, conds);
            }
            PatKind::None => conds.push(self.fld(v, Sel::F(0)).not()),
            PatKind::Ok(q) => {
                conds.push(self.fld(v, Sel::F(0)));
                let f = self.fld(v, Sel::F(1));
                self.sub_test(q, &f, conds);
            }
            PatKind::Err(q) => {
                conds.push(self.fld(v, Sel::F(0)).not());
                let err = self.fld(v, Sel::F(2));
                if let Some(pt) = self.payload_ty(p, ty) {
                    let id = self.g.type_id(&pt);
                    let pl = Ex::rt("duck_err_payload", vec![err, Ex::int_as(id as i64, MTy::U32)], MTy::void_ptr());
                    conds.push(Ex::bin(BOp::Ne, pl.clone(), Ex::null()));
                    let val = pl.cast(MTy::ptr(d(&pt))).deref(d(&pt));
                    self.sub_test(q, &val, conds);
                } else {
                    self.sub_test(q, &err, conds);
                }
            }
        }
    }

    /// For `err(q)`: the typed payload's type when `q` matches an error enum value.
    fn payload_ty(&self, p: &Pat, ty: &Ty) -> Option<Ty> {
        if let Some(t) = self.t.err_payload_pats.get(&p.id) {
            return Some(self.sub(t));
        }
        match ty {
            Ty::Res(_, e) if !self.g.is_err_ty(e) => Some((**e).clone()),
            _ => None,
        }
    }

    /// The address of a literal map-pattern key (a variable declared here, or a literal global).
    fn key_lit(&mut self, k: &Lit, kt: &Ty) -> Ex {
        let v = match k {
            Lit::Str(s) => {
                let l = self.g.lit(s);
                return l.addr().cast(MTy::void_ptr());
            }
            Lit::Int(n) => Ex::int(*n as i64),
            Lit::Char(c) => Ex::int_as(*c as i64, MTy::D(Ty::Char)),
            Lit::Bool(b) => Ex::bool(*b),
            Lit::Float(x) => Ex::float(*x),
        };
        let _ = kt;
        let var = self.f.b.decl(v);
        var.addr().cast(MTy::void_ptr())
    }

    /// Bind a parameter / loop element / closure argument: a plain name borrows it.
    pub(super) fn bind_top(&mut self, p: &Pat, v: &Ex, ty: &Ty) {
        if let PatKind::Bind(_) = &p.kind
            && !self.t.variants.contains_key(&p.id)
        {
            if let Some(&l) = self.t.binds.get(&p.id) {
                self.f.locals.insert(l, Slot { c: v.clone(), ty: ty.clone() });
            }
            return;
        }
        self.bind_pat(p, v, ty);
    }

    /// Bind the names of `p` (which matched `v`) to owned copies.
    pub(super) fn bind_pat(&mut self, p: &Pat, v: &Ex, _ty: &Ty) {
        let ty = self.ty(p.id);
        match &p.kind {
            PatKind::Wild | PatKind::Lit { .. } | PatKind::None => {}
            PatKind::Bind(_) => {
                if self.t.variants.contains_key(&p.id) {
                    return;
                }
                if let Some(&l) = self.t.binds.get(&p.id) {
                    let lt = self.local_ty(l);
                    self.bind_local(l, v, &lt);
                }
            }
            PatKind::Tuple(ps) => {
                for (i, q) in ps.iter().enumerate() {
                    let f = self.fld(v, Sel::F(i as u32));
                    self.bind_sub(q, &f);
                }
            }
            PatKind::List { head, rest, tail } => {
                let Ty::List(et) = &ty else { return };
                for (i, q) in head.iter().enumerate() {
                    let e = self.list_elem(v, Ex::int(i as i64), et);
                    self.bind_sub(q, &e);
                }
                let tl = tail.len() as i64;
                for (j, q) in tail.iter().enumerate() {
                    let idx = Ex::bin(BOp::Sub, v.clone().rt_field(RtF::ArrLen), Ex::int(tl - j as i64));
                    let e = self.list_elem(v, idx, et);
                    self.bind_sub(q, &e);
                }
                if let Some(r) = rest
                    && let Some(rp) = &r.pat
                {
                    if let PatKind::Wild = rp.kind {
                        return;
                    }
                    let hi = Ex::bin(BOp::Sub, v.clone().rt_field(RtF::ArrLen), Ex::int(tl));
                    let slice = Ex::rt("duck_arr_slice", vec![v.clone(), Ex::int(head.len() as i64), hi, Ex::cstr("")], d(&ty));
                    let n = self.decl(&ty, slice);
                    self.register_local(&n, &ty);
                    if let PatKind::Bind(_) = &rp.kind
                        && let Some(&l) = self.t.binds.get(&rp.id)
                    {
                        self.f.locals.insert(l, Slot { c: n, ty: ty.clone() });
                        return;
                    }
                    self.bind_sub(rp, &n);
                }
            }
            PatKind::Variant { args, .. } => {
                let Some(vr) = self.t.variants.get(&p.id).cloned() else { return };
                if let Some(args) = args {
                    for (fi, q) in args.iter().enumerate() {
                        let f = self.g.variant_field(&ty, vr.index, fi, v);
                        self.bind_sub(q, &f);
                    }
                }
            }
            PatKind::Struct { fields, .. } => {
                let Some(sp) = self.t.struct_pats.get(&p.id).cloned() else { return };
                let Ty::Named(dd, args) = &ty else { return };
                let s = self.tp.defs.subst_of(*dd, args);
                let defs = self.tp.defs.fields(*dd).to_vec();
                for (fp, (fi, short)) in fields.iter().zip(&sp.fields) {
                    let f = self.g.field_get(&ty, *fi, v);
                    match (&fp.pat, short) {
                        (Some(q), _) => self.bind_sub(q, &f),
                        (None, Some(l)) => {
                            let ft = defs[*fi].ty.subst(&s).subst(&self.subst);
                            self.bind_local(*l, &f, &ft);
                        }
                        _ => {}
                    }
                }
            }
            PatKind::Map(es) => {
                let value_map = self.t.value_map_pats.contains(&p.id);
                let (m, kt, vt) = if value_map {
                    let mt = Ty::Map(Box::new(Ty::Str), Box::new(ty.clone()));
                    (v.clone().field(Sel::V(6, 0), d(&mt)), Ty::Str, ty.clone())
                } else {
                    match &ty {
                        Ty::Map(k, x) => (v.clone(), (**k).clone(), (**x).clone()),
                        _ => return,
                    }
                };
                for (k, q) in es {
                    let key = self.key_lit(k, &kt);
                    let val = Ex::rt("duck_map_find", vec![m.clone(), key], MTy::void_ptr()).cast(MTy::ptr(d(&vt))).deref(d(&vt));
                    self.bind_sub(q, &val);
                }
            }
            PatKind::StrPrefix { prefix, rest } => {
                if let PatKind::Bind(_) = &rest.kind
                    && let Some(&l) = self.t.binds.get(&rest.id)
                {
                    let nchars = prefix.chars().count() as i64;
                    let len = Ex::rt("duck_str_len", vec![v.clone()], MTy::D(Ty::Int));
                    let s = Ex::rt("duck_str_slice", vec![v.clone(), Ex::int(nchars), len, Ex::cstr("")], MTy::D(Ty::Str));
                    let n = self.decl(&Ty::Str, s);
                    self.register_local(&n, &Ty::Str);
                    self.f.locals.insert(l, Slot { c: n, ty: Ty::Str });
                }
            }
            PatKind::Some(q) | PatKind::Ok(q) => {
                let f = self.fld(v, Sel::F(1));
                self.bind_sub(q, &f);
            }
            PatKind::Err(q) => {
                let err = self.fld(v, Sel::F(2));
                if let Some(pt) = self.payload_ty(p, &ty) {
                    let id = self.g.type_id(&pt);
                    let val = Ex::rt("duck_err_payload", vec![err, Ex::int_as(id as i64, MTy::U32)], MTy::void_ptr()).cast(MTy::ptr(d(&pt))).deref(d(&pt));
                    self.bind_sub(q, &val);
                } else {
                    self.bind_sub(q, &err);
                }
            }
        }
    }

    fn bind_sub(&mut self, q: &Pat, v: &Ex) {
        let t = self.ty(q.id);
        self.bind_pat(q, v, &t);
    }

    /// Declare local `l` as an owned (retained) copy of `v`.
    fn bind_local(&mut self, l: usize, v: &Ex, ty: &Ty) {
        let n = self.decl(ty, v.clone());
        if let Some(r) = self.g.retain(ty, &n) {
            self.emit(r);
        }
        self.register_local(&n, ty);
        self.f.locals.insert(l, Slot { c: n, ty: ty.clone() });
    }
}
