//! Patterns: type-check a pattern against the matched type and bind its names. (Exhaustiveness
//! and decision trees are patterns.rs's job.)

use std::collections::HashMap;

use super::*;
use crate::ast::{Lit, Pat};

impl Checker {
    /// Check `p` against `ty`, binding names in the current scope (`mutable` for `var`).
    /// `seen` collects the names bound so far in this pattern (or parameter list) to catch
    /// duplicates.
    pub fn pattern(&mut self, p: &Pat, ty: &Ty, mutable: bool, seen: &mut HashMap<String, Span>) {
        self.pat(p, ty, mutable, seen, true);
    }

    /// The pattern of `x is pat`: it may not bind names.
    pub fn is_pattern(&mut self, p: &Pat, ty: &Ty) {
        let mut seen = HashMap::new();
        self.pat(p, ty, false, &mut seen, false);
    }

    /// The local a pattern binds `n` to: a new one in the current scope, or, in a later
    /// alternative of an or-pattern, the one the first alternative bound (same type).
    fn bind_name(&mut self, n: &str, ty: &Ty, mutable: bool, span: Span) -> LocalId {
        if let Some(first) = &self.or_binds {
            match first.get(n).copied() {
                Some(l) => {
                    let lt = self.local_ty(l);
                    if !self.unify(&lt, ty) {
                        let (a, b) = (self.show(ty), self.show(&lt));
                        self.err(
                            Diag::new("E0267", span, format!("`{n}` is a `{b}` in the first alternative but a `{a}` here"))
                                .note("every alternative of an or-pattern must bind the same names with the same types"),
                        );
                    }
                    return l;
                }
                None => {
                    self.err(
                        Diag::new("E0267", span, format!("`{n}` is bound here but not in the first alternative"))
                            .note("every alternative of an or-pattern must bind the same names with the same types; use `_` here or split the arm"),
                    );
                    return self.new_local(n, ty.clone(), mutable, span);
                }
            }
        }
        let l = self.new_local(n, ty.clone(), mutable, span);
        self.scope_insert(n, l);
        l
    }

    /// `A | B`: the first alternative binds the names, the others must bind the same ones.
    fn or_pat(&mut self, alts: &[Pat], ty: &Ty, mutable: bool, seen: &mut HashMap<String, Span>, bind: bool) {
        let before: Vec<String> = seen.keys().cloned().collect();
        self.pat(&alts[0], ty, mutable, seen, bind);
        let scope = self.cx().scopes.last().cloned().unwrap_or_default();
        let first: HashMap<String, LocalId> =
            seen.keys().filter(|k| !before.contains(k)).filter_map(|k| scope.get(k).map(|&l| (k.clone(), l))).collect();
        let outer = self.or_binds.take();
        for alt in &alts[1..] {
            let mut s2: HashMap<String, Span> = seen.iter().filter(|(k, _)| before.contains(k)).map(|(k, v)| (k.clone(), *v)).collect();
            self.or_binds = Some(first.clone());
            let n0 = self.errs.len();
            self.pat(alt, ty, mutable, &mut s2, bind);
            self.or_binds = None;
            // a name bound here but not in the first alternative was already reported
            let reported = self.errs[n0..].iter().any(|d| d.diag.code == "E0267");
            let mut missing: Vec<String> = first.keys().filter(|k| !s2.contains_key(*k)).map(|k| format!("`{k}`")).collect();
            if !missing.is_empty() && !reported {
                missing.sort();
                self.err(
                    Diag::new("E0267", alt.span, format!("this alternative doesn't bind {}, which the first one binds", missing.join(", ")))
                        .note("every alternative of an or-pattern must bind the same names with the same types"),
                );
            }
        }
        self.or_binds = outer;
    }

    fn pat_mismatch(&mut self, p: &Pat, what: &str, ty: &Ty) {
        let r = self.resolve(ty);
        if r.has_error() {
            return;
        }
        let ts = self.defs.show(&r);
        self.err(Diag::new("E0262", p.span, format!("this pattern matches {what}, but the value is a `{ts}`")));
    }

    fn pat(&mut self, p: &Pat, ty: &Ty, mutable: bool, seen: &mut HashMap<String, Span>, bind: bool) {
        self.cx().t.types.insert(p.id, ty.clone());
        let m = self.cur_module();
        match &p.kind {
            PatKind::Wild => {}
            PatKind::Bind(n) => {
                // a bare name is the variant of that name when one is in scope (or the matched
                // type is an enum with that variant)
                let st = self.shallow(ty);
                let mut variant = None;
                if let Ty::Named(d, _) = &st
                    && self.defs.is_enum(*d)
                    && let Some(i) = self.defs.variants(*d).iter().position(|v| &v.name == n)
                {
                    variant = Some((*d, i));
                }
                if variant.is_none() {
                    let vs = self.variants_in_scope(m, n);
                    let fitting: Vec<(DefId, usize)> = vs
                        .iter()
                        .copied()
                        .filter(|&(d, _)| {
                            let et = self.fresh_def_cx(d);
                            self.cx().inf.can_unify(&et, ty)
                        })
                        .collect();
                    variant = fitting.first().copied().or(vs.first().copied());
                }
                if let Some((d, i)) = variant {
                    self.variant_pat(p, d, i, None, ty, mutable, seen, bind);
                    return;
                }
                if !bind {
                    self.err(
                        Diag::new("E0263", p.span, format!("an `is` pattern can't bind names, but `{n}` would bind one"))
                            .note("use `_` to match anything, or a `match` / `let ... else` to bind values")
                            .fix(p.span, "_"),
                    );
                    return;
                }
                if let Some(prev) = seen.get(n) {
                    self.err(
                        Diag::new("E0265", p.span, format!("`{n}` is bound twice in this pattern")).note(format!("the first binding is at {prev}")),
                    );
                    return;
                }
                seen.insert(n.clone(), p.span);
                let l = self.bind_name(n, ty, mutable, p.span);
                self.cx().t.binds.insert(p.id, l);
            }
            PatKind::Lit { lit, neg } => {
                let lt = match lit {
                    Lit::Int(n) => {
                        let max = if *neg { 1u64 << 63 } else { i64::MAX as u64 };
                        if *n > max {
                            self.err(Diag::new("E0210", p.span, format!("the integer literal {n} doesn't fit in an `int`")));
                        }
                        Ty::Int
                    }
                    Lit::Float(_) => Ty::Float,
                    Lit::Bool(_) => Ty::Bool,
                    Lit::Char(_) => Ty::Char,
                    Lit::Str(_) => Ty::Str,
                };
                // zero is zero in every unit of measure
                let zero = matches!(lit, Lit::Int(0)) || matches!(lit, Lit::Float(x) if *x == 0.0);
                let lt = match self.resolve(ty) {
                    Ty::Measured(b, u) if zero && *b == lt => Ty::Measured(b, u),
                    _ => lt,
                };
                if !self.unify(&lt, ty) {
                    let what = format!("a `{}`", self.defs.show(&lt));
                    self.pat_mismatch(p, &what, ty);
                }
            }
            PatKind::Tuple(ps) => {
                let ts = match self.shallow(ty) {
                    Ty::Tuple(ts) if ts.len() == ps.len() => ts,
                    Ty::Var(_) => {
                        let ts: Vec<Ty> = ps.iter().map(|_| self.fresh()).collect();
                        self.unify(ty, &Ty::Tuple(ts.clone()));
                        ts
                    }
                    Ty::Error => vec![Ty::Error; ps.len()],
                    _ => {
                        self.pat_mismatch(p, &format!("a tuple of {} elements", ps.len()), ty);
                        vec![Ty::Error; ps.len()]
                    }
                };
                for (q, t) in ps.iter().zip(&ts) {
                    self.pat(q, t, mutable, seen, bind);
                }
            }
            PatKind::List { head, rest, tail } => {
                let et = match self.shallow(ty) {
                    Ty::List(e) => *e,
                    Ty::Var(_) => {
                        let e = self.fresh();
                        self.unify(ty, &Ty::list(e.clone()));
                        e
                    }
                    Ty::Error => Ty::Error,
                    _ => {
                        self.pat_mismatch(p, "a list", ty);
                        Ty::Error
                    }
                };
                for q in head.iter().chain(tail) {
                    self.pat(q, &et, mutable, seen, bind);
                }
                if let Some(r) = rest
                    && let Some(rp) = &r.pat
                {
                    let lt = if matches!(et, Ty::Error) { Ty::Error } else { Ty::list(et.clone()) };
                    self.pat(rp, &lt, mutable, seen, bind);
                }
            }
            PatKind::Variant { path, args } => {
                let st = self.shallow(ty);
                let last = &path[path.len() - 1].name;
                let mut found = None;
                if path.len() == 1
                    && let Ty::Named(d, _) = &st
                    && self.defs.is_enum(*d)
                    && let Some(i) = self.defs.variants(*d).iter().position(|v| &v.name == last)
                {
                    found = Some((*d, i));
                }
                if found.is_none() && path.len() == 1 {
                    let vs = self.variants_in_scope(m, last);
                    let fitting: Vec<(DefId, usize)> = vs
                        .iter()
                        .copied()
                        .filter(|&(d, _)| {
                            let et = self.fresh_def_cx(d);
                            self.cx().inf.can_unify(&et, ty)
                        })
                        .collect();
                    found = fitting.first().copied().or(vs.first().copied());
                }
                if found.is_none() {
                    found = self.variant_path(m, path);
                }
                let Some((d, i)) = found else {
                    let name = path.iter().map(|x| x.name.clone()).collect::<Vec<_>>().join(".");
                    let mut dg = Diag::new("E0102", p.span, format!("unknown variant `{name}`"));
                    if let Ty::Named(d, _) = &st
                        && self.defs.is_enum(*d)
                    {
                        let names: Vec<String> = self.defs.variants(*d).iter().map(|v| v.name.clone()).collect();
                        dg = dg.note(format!("`{}` has the variants {}", self.defs.types[*d].name, names.join(", ")));
                        if let Some(s) = similar(last, &names) {
                            dg = dg.fix(path[path.len() - 1].span, s);
                        }
                    } else {
                        dg = dg.note("a variant of another module's enum is written with its path, e.g. `json.Eof(l, c)`");
                    }
                    self.err(dg);
                    if let Some(a) = args {
                        for q in a {
                            self.pat(q, &Ty::Error, mutable, seen, bind);
                        }
                    }
                    return;
                };
                self.variant_pat(p, d, i, args.as_deref(), ty, mutable, seen, bind);
            }
            PatKind::Struct { path, fields, rest } => {
                let d = match self.lookup_type_path(m, path) {
                    Some(TypeItem::Def(d)) if self.defs.is_struct(d) => d,
                    _ => {
                        let name = path.iter().map(|x| x.name.clone()).collect::<Vec<_>>().join(".");
                        self.err(Diag::new("E0104", p.span, format!("unknown struct `{name}` in pattern")));
                        return;
                    }
                };
                let (s, args) = self.instantiate_def(d);
                let st = Ty::Named(d, args);
                if !self.unify(&st, ty) {
                    let what = format!("a `{}`", self.defs.types[d].name);
                    self.pat_mismatch(p, &what, ty);
                }
                let defs = self.defs.fields(d).to_vec();
                let foreign = self.defs.types[d].module != m;
                let mut out = Vec::new();
                let mut given = vec![false; defs.len()];
                for f in fields {
                    let Some(i) = defs.iter().position(|x| x.name == f.name.name) else {
                        let names: Vec<String> = defs.iter().map(|x| x.name.clone()).collect();
                        self.err(
                            Diag::new("E0225", f.name.span, format!("the struct `{}` has no field `{}`", self.defs.types[d].name, f.name.name))
                                .note(format!("its fields are: {}", names.join(", "))),
                        );
                        continue;
                    };
                    given[i] = true;
                    if foreign && !defs[i].public {
                        self.err(Diag::new("E0121", f.name.span, format!("the field `{}` of `{}` is private", f.name.name, self.defs.types[d].name)));
                    }
                    let ft = defs[i].ty.subst(&s);
                    match &f.pat {
                        Some(q) => {
                            self.pat(q, &ft, mutable, seen, bind);
                            out.push((i, None));
                        }
                        None => {
                            if !bind {
                                self.err(Diag::new("E0263", f.name.span, format!("an `is` pattern can't bind names; write `{}: _`", f.name.name)));
                                out.push((i, None));
                                continue;
                            }
                            let l = self.bind_name(&f.name.name, &ft, mutable, f.name.span);
                            seen.insert(f.name.name.clone(), f.name.span);
                            out.push((i, Some(l)));
                        }
                    }
                }
                if !rest {
                    let missing: Vec<String> = defs.iter().zip(&given).filter(|(_, g)| !**g).map(|(f, _)| format!("`{}`", f.name)).collect();
                    if !missing.is_empty() {
                        let end = Span { line: p.span.end_line, col: p.span.end_col - 1, end_line: p.span.end_line, end_col: p.span.end_col - 1 };
                        self.err(
                            Diag::new(
                                "E0266",
                                p.span,
                                format!("this pattern doesn't mention the field(s) {} of `{}`", missing.join(", "), self.defs.types[d].name),
                            )
                            .note("add `..` to ignore the other fields")
                            .fix(end, if fields.is_empty() { "..".to_string() } else { ", ..".to_string() }),
                        );
                    }
                }
                self.cx().t.struct_pats.insert(p.id, StructPat { def: d, fields: out });
            }
            PatKind::Map(es) => {
                let st = self.shallow(ty);
                let value = Ty::Named(self.b.value, Vec::new());
                let (kt, vt) = match &st {
                    Ty::Map(k, v) => ((**k).clone(), (**v).clone()),
                    Ty::Named(d, _) if *d == self.b.value => {
                        self.cx().t.value_map_pats.insert(p.id);
                        (Ty::Str, value)
                    }
                    Ty::Var(_) => {
                        let (k, v) = (self.fresh(), self.fresh());
                        self.unify(ty, &Ty::map(k.clone(), v.clone()));
                        (k, v)
                    }
                    Ty::Error => (Ty::Error, Ty::Error),
                    _ => {
                        self.pat_mismatch(p, "a map (or a `Value.Map`)", ty);
                        (Ty::Error, Ty::Error)
                    }
                };
                for (k, q) in es {
                    let lt = match k {
                        Lit::Int(_) => Ty::Int,
                        Lit::Float(_) => Ty::Float,
                        Lit::Bool(_) => Ty::Bool,
                        Lit::Char(_) => Ty::Char,
                        Lit::Str(_) => Ty::Str,
                    };
                    if !self.unify(&lt, &kt) {
                        let (ls, ks) = (self.defs.show(&lt), self.show(&kt));
                        self.err(Diag::new("E0262", q.span, format!("this map pattern's key is a `{ls}`, but the map's keys are `{ks}`")));
                    }
                    self.pat(q, &vt, mutable, seen, bind);
                }
            }
            PatKind::StrPrefix { rest, .. } => {
                if !self.unify(&Ty::Str, ty) {
                    self.pat_mismatch(p, "a `str` (by prefix)", ty);
                }
                self.pat(rest, &Ty::Str, mutable, seen, bind);
            }
            PatKind::Some(q) => {
                let inner = match self.shallow(ty) {
                    Ty::Opt(i) => *i,
                    Ty::Var(_) => {
                        let i = self.fresh();
                        self.unify(ty, &Ty::opt(i.clone()));
                        i
                    }
                    Ty::Error => Ty::Error,
                    _ => {
                        self.pat_mismatch(p, "an optional (`T?`)", ty);
                        Ty::Error
                    }
                };
                self.pat(q, &inner, mutable, seen, bind);
            }
            PatKind::None => match self.shallow(ty) {
                Ty::Opt(_) | Ty::Error => {}
                Ty::Var(_) => {
                    let i = self.fresh();
                    self.unify(ty, &Ty::opt(i));
                }
                _ => self.pat_mismatch(p, "an optional (`T?`)", ty),
            },
            PatKind::Ok(q) | PatKind::Err(q) => {
                let is_ok = matches!(p.kind, PatKind::Ok(_));
                let (ok, er) = match self.shallow(ty) {
                    Ty::Res(o, e) => (*o, *e),
                    Ty::Var(_) => {
                        let (o, e) = (self.fresh(), self.fresh());
                        self.unify(ty, &Ty::res(o.clone(), e.clone()));
                        (o, e)
                    }
                    Ty::Error => (Ty::Error, Ty::Error),
                    _ => {
                        self.pat_mismatch(p, "a result (`T!`)", ty);
                        (Ty::Error, Ty::Error)
                    }
                };
                if is_ok {
                    self.pat(q, &ok, mutable, seen, bind);
                    return;
                }
                // `err(BadUrl(w))` on a plain `T!` matches a typed error payload
                let er_s = self.shallow(&er);
                if self.defs.is_err(&er_s)
                    && let Some((d, _)) = self.payload_variant(q)
                {
                    let pt = self.fresh_def_cx(d);
                    self.cx().t.err_payload_pats.insert(p.id, pt.clone());
                    self.pat(q, &pt, mutable, seen, bind);
                    return;
                }
                self.pat(q, &er, mutable, seen, bind);
            }
            PatKind::Or(alts) => self.or_pat(alts, ty, mutable, seen, bind),
        }
    }

    /// The variant a pattern names, if it is a variant pattern (for typed error payloads).
    fn payload_variant(&mut self, q: &Pat) -> Option<(DefId, usize)> {
        let m = self.cur_module();
        match &q.kind {
            PatKind::Variant { path, .. } => self.variant_path(m, path),
            PatKind::Bind(n) => {
                let vs = self.variants_in_scope(m, n);
                vs.first().copied()
            }
            _ => None,
        }
    }

    pub fn fresh_def_cx(&mut self, d: DefId) -> Ty {
        let n = self.defs.types[d].params.len();
        let args: Vec<Ty> = (0..n).map(|_| self.fresh()).collect();
        Ty::Named(d, args)
    }

    #[allow(clippy::too_many_arguments)]
    fn variant_pat(
        &mut self,
        p: &Pat,
        d: DefId,
        i: usize,
        args: Option<&[Pat]>,
        ty: &Ty,
        mutable: bool,
        seen: &mut HashMap<String, Span>,
        bind: bool,
    ) {
        let (s, targs) = self.instantiate_def(d);
        let et = Ty::Named(d, targs.clone());
        if !self.unify(&et, ty) {
            let what = format!("a `{}` (variant `{}`)", self.defs.types[d].name, self.defs.variants(d)[i].name);
            self.pat_mismatch(p, &what, ty);
        }
        let v = self.defs.variants(d)[i].clone();
        self.cx().t.variants.insert(p.id, VariantRef { def: d, index: i, args: targs });
        let args = args.unwrap_or(&[]);
        if args.len() != v.fields.len() {
            let mut dg =
                Diag::new("E0264", p.span, format!("the variant `{}` has {} field(s), but the pattern has {}", v.name, v.fields.len(), args.len()));
            if args.is_empty() {
                let fill = vec!["_"; v.fields.len()].join(", ");
                dg = dg.note(format!("write `{}({fill})` to match it whatever its fields", v.name)).fix(p.span.after(), format!("({fill})"));
            }
            self.err(dg);
            for q in args {
                self.pat(q, &Ty::Error, mutable, seen, bind);
            }
            return;
        }
        for (q, (_, ft)) in args.iter().zip(&v.fields) {
            let ft = ft.subst(&s);
            self.pat(q, &ft, mutable, seen, bind);
        }
    }
}
