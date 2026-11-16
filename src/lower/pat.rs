//! Patterns: a pure C test expression per pattern, then a binding step. Bindings own their
//! values (retained copies), except a plain name bound directly to a parameter, a loop element
//! or a closure argument, which borrows it.

use super::{Lower, Slot};
use crate::ast::{Lit, Pat, PatKind};
use crate::cgen::{c_str, sanitize};
use crate::types::Ty;

impl Lower<'_, '_> {
    /// A C boolean expression: does the value `v` (a C lvalue) match `p`? Pure, no bindings.
    pub(super) fn pat_test(&mut self, p: &Pat, v: &str) -> String {
        let ty = self.ty(p.id);
        let mut conds: Vec<String> = Vec::new();
        self.test_into(p, v, &ty, &mut conds);
        if conds.is_empty() { "1".to_string() } else { conds.join(" && ") }
    }

    fn sub_test(&mut self, p: &Pat, v: &str, conds: &mut Vec<String>) {
        let ty = self.ty(p.id);
        self.test_into(p, v, &ty, conds);
    }

    fn test_into(&mut self, p: &Pat, v: &str, ty: &Ty, conds: &mut Vec<String>) {
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
                        if *neg {
                            if *n == 1u64 << 63 { format!("{v} == INT64_MIN") } else { format!("{v} == -INT64_C({n})") }
                        } else {
                            format!("{v} == INT64_C({n})")
                        }
                    }
                    Lit::Float(x) => {
                        let x = if *neg { -x } else { *x };
                        format!("{v} == {x:?}")
                    }
                    Lit::Bool(b) => {
                        if *b {
                            format!("({v})")
                        } else {
                            format!("!({v})")
                        }
                    }
                    Lit::Char(c) => format!("{v} == UINT32_C({})", *c as u32),
                    Lit::Str(s) => {
                        let l = self.g.lit(s);
                        format!("duck_str_eq({v}, {l})")
                    }
                };
                conds.push(c);
            }
            PatKind::Tuple(ps) => {
                for (i, q) in ps.iter().enumerate() {
                    self.sub_test(q, &format!("({v}).f{i}"), conds);
                }
            }
            PatKind::List { head, rest, tail } => {
                let Ty::List(et) = ty else { return };
                let ct = self.g.ct(et);
                let n = head.len() + tail.len();
                if rest.is_some() {
                    if n > 0 {
                        conds.push(format!("duck_arr_len({v}) >= {n}"));
                    }
                } else {
                    conds.push(format!("duck_arr_len({v}) == {n}"));
                }
                for (i, q) in head.iter().enumerate() {
                    self.sub_test(q, &format!("(({ct} *)({v})->data)[{i}]"), conds);
                }
                let tl = tail.len();
                for (j, q) in tail.iter().enumerate() {
                    self.sub_test(q, &format!("(({ct} *)({v})->data)[({v})->len - {}]", tl - j), conds);
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
                    (format!("({v}).u.map"), Ty::Str, ty.clone())
                } else {
                    match ty {
                        Ty::Map(k, x) => (v.to_string(), (**k).clone(), (**x).clone()),
                        _ => return,
                    }
                };
                if value_map {
                    conds.push(format!("({v}).tag == DUCK_V_MAP"));
                }
                let vc = self.g.ct(&vt);
                for (k, q) in es {
                    let key = self.key_lit(k, &kt);
                    conds.push(format!("duck_map_find({m}, {key}) != NULL"));
                    self.sub_test(q, &format!("(*({vc} *)duck_map_find({m}, {key}))"), conds);
                }
            }
            PatKind::StrPrefix { prefix, .. } => {
                let l = self.g.lit(prefix);
                conds.push(format!("duck_str_starts_with({v}, {l})"));
            }
            PatKind::Some(q) => {
                conds.push(format!("({v}).some"));
                self.sub_test(q, &format!("({v}).val"), conds);
            }
            PatKind::None => conds.push(format!("!({v}).some")),
            PatKind::Ok(q) => {
                conds.push(format!("({v}).ok"));
                self.sub_test(q, &format!("({v}).val"), conds);
            }
            PatKind::Err(q) => {
                conds.push(format!("!({v}).ok"));
                if let Some(pt) = self.payload_ty(p, ty) {
                    let id = self.g.type_id(&pt);
                    let c = self.g.ct(&pt);
                    conds.push(format!("duck_err_payload(({v}).err, {id}) != NULL"));
                    self.sub_test(q, &format!("(*({c} *)duck_err_payload(({v}).err, {id}))"), conds);
                } else {
                    self.sub_test(q, &format!("({v}).err"), conds);
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

    /// `&key` for a literal map-pattern key.
    fn key_lit(&mut self, k: &Lit, kt: &Ty) -> String {
        match k {
            Lit::Str(s) => {
                let l = self.g.lit(s);
                format!("&{l}")
            }
            Lit::Int(n) => format!("&(int64_t){{INT64_C({n})}}"),
            Lit::Char(c) => format!("&(uint32_t){{{}}}", *c as u32),
            Lit::Bool(b) => format!("&(bool){{{b}}}"),
            Lit::Float(x) => {
                let _ = kt;
                format!("&(double){{{x:?}}}")
            }
        }
    }

    /// Bind a parameter / loop element / closure argument: a plain name borrows it.
    pub(super) fn bind_top(&mut self, p: &Pat, v: &str, ty: &Ty) {
        if let PatKind::Bind(_) = &p.kind
            && !self.t.variants.contains_key(&p.id)
        {
            if let Some(&l) = self.t.binds.get(&p.id) {
                self.f.locals.insert(l, Slot { c: v.to_string(), ty: ty.clone() });
            }
            return;
        }
        self.bind_pat(p, v, ty);
    }

    /// Bind the names of `p` (which matched `v`) to owned copies.
    pub(super) fn bind_pat(&mut self, p: &Pat, v: &str, _ty: &Ty) {
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
                    self.bind_sub(q, &format!("({v}).f{i}"));
                }
            }
            PatKind::List { head, rest, tail } => {
                let Ty::List(et) = &ty else { return };
                let ct = self.g.ct(et);
                for (i, q) in head.iter().enumerate() {
                    self.bind_sub(q, &format!("(({ct} *)({v})->data)[{i}]"));
                }
                let tl = tail.len();
                for (j, q) in tail.iter().enumerate() {
                    self.bind_sub(q, &format!("(({ct} *)({v})->data)[({v})->len - {}]", tl - j));
                }
                if let Some(r) = rest
                    && let Some(rp) = &r.pat
                {
                    if let PatKind::Wild = rp.kind {
                        return;
                    }
                    let slice = format!("duck_arr_slice({v}, {}, ({v})->len - {tl}, \"\")", head.len());
                    if let PatKind::Bind(_) = &rp.kind
                        && let Some(&l) = self.t.binds.get(&rp.id)
                    {
                        let n = self.name(&format!("{}_", sanitize(&self.t.locals[l].name)));
                        self.line(format!("DuckArr *{n} = {slice};"));
                        self.register_local(&n, &ty);
                        self.f.locals.insert(l, Slot { c: n, ty: ty.clone() });
                        return;
                    }
                    let n = self.name("rest");
                    self.line(format!("DuckArr *{n} = {slice};"));
                    self.register_local(&n, &ty);
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
                let Ty::Named(d, args) = &ty else { return };
                let s = self.tp.defs.subst_of(*d, args);
                let defs = self.tp.defs.fields(*d).to_vec();
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
                    (format!("({v}).u.map"), Ty::Str, ty.clone())
                } else {
                    match &ty {
                        Ty::Map(k, x) => (v.to_string(), (**k).clone(), (**x).clone()),
                        _ => return,
                    }
                };
                let vc = self.g.ct(&vt);
                for (k, q) in es {
                    let key = self.key_lit(k, &kt);
                    self.bind_sub(q, &format!("(*({vc} *)duck_map_find({m}, {key}))"));
                }
            }
            PatKind::StrPrefix { prefix, rest } => {
                if let PatKind::Bind(_) = &rest.kind
                    && let Some(&l) = self.t.binds.get(&rest.id)
                {
                    let nchars = prefix.chars().count();
                    let n = self.name(&format!("{}_", sanitize(&self.t.locals[l].name)));
                    self.line(format!("DuckStr *{n} = duck_str_slice({v}, {nchars}, duck_str_len({v}), {});", c_str("")));
                    self.register_local(&n, &Ty::Str);
                    self.f.locals.insert(l, Slot { c: n, ty: Ty::Str });
                }
            }
            PatKind::Some(q) | PatKind::Ok(q) => self.bind_sub(q, &format!("({v}).val")),
            PatKind::Err(q) => {
                if let Some(pt) = self.payload_ty(p, &ty) {
                    let id = self.g.type_id(&pt);
                    let c = self.g.ct(&pt);
                    self.bind_sub(q, &format!("(*({c} *)duck_err_payload(({v}).err, {id}))"));
                } else {
                    self.bind_sub(q, &format!("({v}).err"));
                }
            }
        }
    }

    fn bind_sub(&mut self, q: &Pat, v: &str) {
        let t = self.ty(q.id);
        self.bind_pat(q, v, &t);
    }

    /// Declare local `l` as an owned (retained) copy of `v`.
    fn bind_local(&mut self, l: usize, v: &str, ty: &Ty) {
        let ct = self.g.ct(ty);
        let n = self.name(&format!("{}_", sanitize(&self.t.locals[l].name)));
        self.line(format!("{ct} {n} = {v};"));
        if let Some(r) = self.g.retain(ty, &n) {
            self.line(r);
        }
        self.register_local(&n, ty);
        self.f.locals.insert(l, Slot { c: n, ty: ty.clone() });
    }
}
