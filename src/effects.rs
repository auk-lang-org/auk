//! Effects checking (spec "Effects", quack.md "Effects at the package boundary").
//!
//! A function's effects are its declared `uses` (prelude externs declare theirs). Every call's
//! callee effects must be among the caller's declared effects:
//! - a direct call (or a function used as a value, `xs.map(fetch)`) needs the callee's `uses`;
//! - a call through `any Shape` needs the shape method's declared `uses`, and converting a value
//!   to `any Shape` requires each of its methods to stay within those (E0415);
//! - a closure's calls belong to the function that defines it (the closure is part of its body);
//! - a generic function is checked by its monomorphized instances: a shape method resolved for a
//!   concrete type (`a.area()` with `T = Sq`) may use effects the generic function doesn't
//!   declare; they become the instance's *hidden* effects and are required wherever that
//!   instance is called (with the call chain in a note).
//!
//! Also: declared but unused effects (E0411, a warning), impure `let`/`imprint` initializers
//! (E0412), the package ceiling `[package] effects` of quack.toml (E0413, each package against
//! its own manifest) and unknown effect names (E0414). Tests may use any effect; `print` and
//! `peek` need none.

use std::collections::{BTreeSet, HashMap, HashSet};

use super::ast::{Expr, ExprKind, FnBody, FnClause, Ident, Item, NodeId};
use super::diag::{Diag, FileDiag, Span};
use super::patterns::children;
use super::resolve::ModId;
use super::typed::{BodyRef, Callee, FnId, FnKind, InstId, NameRef, Target, TypedProgram};
use super::types::ShapeId;

/// The effects a function may declare.
pub const EFFECTS: &[&str] = &["fs", "net", "time", "rand", "env", "proc", "audio_out", "gui", "ffi"];

type Set = BTreeSet<String>;

/// A shape method's declared `uses`, and its signature in the AST (for fix-its).
type ShapeUses<'a> = (Vec<String>, Option<&'a FnClause>);

/// Check the effects of every function, constant and conversion to `any Shape` outside core.
/// Returns errors and warnings (E0411).
pub fn check(tp: &TypedProgram) -> Vec<FileDiag> {
    let mut cx = Cx::new(tp);
    cx.run();
    cx.out
}

/// One expression node of a body, in source order.
struct Node {
    id: NodeId,
    span: Span,
    /// The span of the innermost closure containing it.
    closure: Option<Span>,
}

/// Why a node needs an effect: the callee as displayed, and the instance it continues into.
#[derive(Clone)]
struct Via {
    callee: String,
    next: Option<InstId>,
    /// The callee declares the effect itself (the chain ends here).
    declared: bool,
}

struct Cx<'a> {
    tp: &'a TypedProgram,
    out: Vec<FileDiag>,
    /// Declared `uses` of each shape method.
    shape_uses: HashMap<(ShapeId, usize), ShapeUses<'a>>,
    insts: HashMap<BodyRef, Vec<InstId>>,
    /// Effects an instance of a generic function needs beyond what the function declares.
    hidden: Vec<Set>,
    /// Every effect an instance's body needs through instance-resolved calls (before
    /// subtracting the declared ones).
    inst_needs: Vec<Set>,
    /// Per body: its expression nodes (computed lazily).
    nodes: HashMap<BodyRef, Vec<Node>>,
}

impl<'a> Cx<'a> {
    fn new(tp: &'a TypedProgram) -> Cx<'a> {
        let mut shape_uses = HashMap::new();
        for (s, sd) in tp.defs.shapes.iter().enumerate() {
            let ast = tp.program.mods[sd.module].ast.items.iter().find_map(|it| match it {
                Item::Shape(d) if d.name.name == sd.name => Some(d),
                _ => None,
            });
            for k in 0..sd.methods.len() {
                let clause = ast.and_then(|d| d.methods.get(k));
                let uses = clause.map(|c| c.uses.iter().map(|u| u.name.clone()).collect()).unwrap_or_default();
                shape_uses.insert((s, k), (uses, clause));
            }
        }
        let mut insts: HashMap<BodyRef, Vec<InstId>> = HashMap::new();
        for (i, inst) in tp.instances.iter().enumerate() {
            insts.entry(inst.body).or_default().push(i);
        }
        let n = tp.instances.len();
        Cx { tp, out: Vec::new(), shape_uses, insts, hidden: vec![Set::new(); n], inst_needs: vec![Set::new(); n], nodes: HashMap::new() }
    }

    fn uses(&self, f: FnId) -> Set {
        self.tp.fns[f].uses.iter().cloned().collect()
    }

    fn module_of(&self, b: BodyRef) -> ModId {
        match b {
            BodyRef::Fn(f) => self.tp.fns[f].module,
            BodyRef::Test(t) => self.tp.tests[t].module,
            BodyRef::Const(c) => self.tp.consts[c].module,
        }
    }

    fn is_generic(&self, b: BodyRef) -> bool {
        matches!(b, BodyRef::Fn(f) if !self.tp.fns[f].generics.is_empty())
    }

    fn emit(&mut self, m: ModId, d: Diag) {
        let file = self.tp.program.mods[m].file.clone();
        self.out.push(FileDiag { file, diag: d });
    }

    // ---- names for messages ----

    /// A function as written from module `from`: `area`, `fs.read`, `geo.area`.
    fn fn_name(&self, f: FnId, from: ModId) -> String {
        let info = &self.tp.fns[f];
        if info.module == from {
            return info.name.clone();
        }
        let path = &self.tp.program.mods[info.module].path;
        let path: &[String] = if self.tp.program.is_core(info.module) { &path[1..] } else { path };
        if path.is_empty() { info.name.clone() } else { format!("{}.{}", path.join("."), info.name) }
    }

    fn inst_name(&self, i: InstId, from: ModId) -> String {
        let inst = &self.tp.instances[i];
        match inst.body {
            BodyRef::Fn(f) => {
                let n = self.fn_name(f, from);
                if inst.type_args.is_empty() {
                    n
                } else {
                    let args: Vec<String> = inst.type_args.iter().map(|t| self.tp.defs.show(t)).collect();
                    format!("{n}<{}>", args.join(", "))
                }
            }
            BodyRef::Test(t) => format!("test {:?}", self.tp.tests[t].name),
            BodyRef::Const(c) => self.tp.consts[c].name.clone(),
        }
    }

    fn shape_method_name(&self, s: ShapeId, k: usize) -> String {
        let sd = &self.tp.defs.shapes[s];
        format!("{}.{}", sd.name, sd.methods.get(k).map(|m| m.name.as_str()).unwrap_or("?"))
    }

    // ---- bodies ----

    /// The expression roots of a body.
    fn roots(&self, b: BodyRef) -> Vec<&'a Expr> {
        let tp = self.tp;
        let mut out = Vec::new();
        match b {
            BodyRef::Fn(f) => {
                let info = &tp.fns[f];
                let FnKind::Duck { item, clauses, header } = &info.kind else { return out };
                let Item::Fn(g) = &tp.program.mods[info.module].ast.items[*item] else { return out };
                let hdr = if *header { g.header.as_deref() } else { None };
                for c in hdr.into_iter().chain(clauses.iter().map(|&i| &g.clauses[i])) {
                    out.extend(c.guard.iter().chain(&c.requires).chain(&c.ensures));
                    match &c.body {
                        Some(FnBody::Expr(e)) => out.push(&**e),
                        Some(FnBody::Block(bl)) => out.extend(bl.stmts.iter()),
                        _ => {}
                    }
                }
            }
            BodyRef::Test(t) => {
                if let Item::Test(d) = &tp.program.mods[tp.tests[t].module].ast.items[tp.tests[t].item] {
                    out.extend(d.body.stmts.iter());
                }
            }
            BodyRef::Const(c) => {
                if let Item::Let(d) | Item::Imprint(d) = &tp.program.mods[tp.consts[c].module].ast.items[tp.consts[c].item] {
                    out.push(&d.value);
                }
            }
        }
        out
    }

    fn body_nodes(&mut self, b: BodyRef) -> &Vec<Node> {
        if !self.nodes.contains_key(&b) {
            let mut nodes = Vec::new();
            for r in self.roots(b) {
                collect(r, None, &mut nodes);
            }
            self.nodes.insert(b, nodes);
        }
        &self.nodes[&b]
    }

    /// Effects node `n` of a body in module `m` needs by itself (generic view): a direct call's
    /// callee `uses`, a function value's `uses`, or a shape method's declared `uses` through
    /// `any Shape`.
    fn direct(&self, m: ModId, n: NodeId) -> Option<(Set, Via)> {
        let t = &self.tp.tables[m];
        if let Some(c) = t.calls.get(&n) {
            return match &c.callee {
                Callee::Fn { func, .. } => Some((self.uses(*func), Via { callee: self.fn_name(*func, m), next: None, declared: true })),
                Callee::Vtable { shape, method } => {
                    let uses: Set = self.shape_uses.get(&(*shape, *method)).map(|u| u.0.iter().cloned().collect()).unwrap_or_default();
                    let callee = format!("{} (through `any {}`)", self.shape_method_name(*shape, *method), self.tp.defs.shapes[*shape].name);
                    Some((uses, Via { callee, next: None, declared: true }))
                }
                _ => None,
            };
        }
        if let Some(NameRef::Fn { func, .. }) = t.names.get(&n) {
            return Some((self.uses(*func), Via { callee: self.fn_name(*func, m), next: None, declared: true }));
        }
        None
    }

    /// Effects node `n` needs in instance `i` through concrete targets: a shape method resolved
    /// for a concrete type, the hidden effects of a generic callee instance, and `Show`
    /// implementations of interpolated values.
    fn resolved(&self, i: InstId, m: ModId, n: NodeId) -> Vec<(Set, Via)> {
        let inst = &self.tp.instances[i];
        let t = &self.tp.tables[m];
        let mut out = Vec::new();
        let target = |j: InstId, out: &mut Vec<(Set, Via)>, own: bool| {
            let BodyRef::Fn(g) = self.tp.instances[j].body else { return };
            let mut s = self.hidden[j].clone();
            if own {
                s.extend(self.uses(g));
            }
            if !s.is_empty() {
                out.push((s, Via { callee: self.inst_name(j, m), next: Some(j), declared: false }));
            }
        };
        let callee = t.calls.get(&n).map(|c| &c.callee);
        match (callee, inst.resolved.get(&n)) {
            (Some(Callee::Fn { .. }), Some(Target::Instance(j))) => target(*j, &mut out, false),
            (Some(Callee::Shape { .. }), Some(Target::Instance(j))) => target(*j, &mut out, true),
            (None, Some(Target::Instance(j))) if matches!(t.names.get(&n), Some(NameRef::Fn { .. })) => target(*j, &mut out, false),
            _ => {}
        }
        if let Some(Target::Instance(j)) = inst.shows.get(&n) {
            target(*j, &mut out, true);
        }
        out
    }

    /// Everything node `n` of body `b` needs (in instance `i`, if any), with the reason.
    fn needs(&self, b: BodyRef, i: Option<InstId>, n: NodeId) -> Vec<(Set, Via)> {
        let m = self.module_of(b);
        let mut out: Vec<(Set, Via)> = self.direct(m, n).into_iter().collect();
        if let Some(i) = i {
            out.extend(self.resolved(i, m, n));
        }
        out
    }

    // ---- the analysis ----

    fn run(&mut self) {
        self.hidden_effects();
        self.names_and_ceiling();
        let bodies: Vec<BodyRef> = (0..self.tp.fns.len())
            .map(BodyRef::Fn)
            .chain((0..self.tp.consts.len()).map(BodyRef::Const))
            .chain((0..self.tp.tests.len()).map(BodyRef::Test))
            .collect();
        for b in bodies {
            let m = self.module_of(b);
            if self.tp.program.is_core(m) {
                continue;
            }
            match b {
                BodyRef::Fn(f) if matches!(self.tp.fns[f].kind, FnKind::Duck { .. }) => self.check_fn(f),
                BodyRef::Const(c) => self.check_const(c),
                _ => {}
            }
            self.check_vtables(b);
        }
    }

    /// The fixed point of `hidden` over the instances of generic functions.
    fn hidden_effects(&mut self) {
        let generic: Vec<InstId> = (0..self.tp.instances.len()).filter(|&i| self.is_generic(self.tp.instances[i].body)).collect();
        let keys: Vec<Vec<NodeId>> = generic
            .iter()
            .map(|&i| {
                let inst = &self.tp.instances[i];
                let mut ks: Vec<NodeId> = inst.resolved.keys().chain(inst.shows.keys()).copied().collect();
                ks.sort_unstable();
                ks.dedup();
                ks
            })
            .collect();
        loop {
            let mut changed = false;
            for (gi, &i) in generic.iter().enumerate() {
                let b = self.tp.instances[i].body;
                let m = self.module_of(b);
                let BodyRef::Fn(f) = b else { continue };
                let mut all = Set::new();
                for &n in &keys[gi] {
                    for (s, _) in self.resolved(i, m, n) {
                        all.extend(s);
                    }
                }
                let declared = self.uses(f);
                let h: Set = all.difference(&declared).cloned().collect();
                if h != self.hidden[i] || all != self.inst_needs[i] {
                    changed |= !h.is_subset(&self.hidden[i]) || !all.is_subset(&self.inst_needs[i]);
                    self.hidden[i].extend(h);
                    self.inst_needs[i].extend(all);
                }
            }
            if !changed {
                break;
            }
        }
    }

    /// Unknown effect names (E0414) and the package ceiling (E0413).
    fn names_and_ceiling(&mut self) {
        let tp = self.tp;
        for info in &tp.fns {
            let m = info.module;
            if tp.program.is_core(m) {
                continue;
            }
            let Some(first) = self.first_clause(info) else { continue };
            for u in &first.uses {
                self.check_name(m, u);
            }
            let pkg = &tp.program.pkgs[tp.program.mods[m].pkg];
            if pkg.dir.is_none() {
                continue;
            }
            for u in first.uses.iter().filter(|u| EFFECTS.contains(&u.name.as_str())) {
                if pkg.effects.contains(&u.name) {
                    continue;
                }
                let allowed = if pkg.effects.is_empty() {
                    "allows no effects".to_string()
                } else {
                    format!("allows only {}", pkg.effects.iter().map(|e| format!("`{e}`")).collect::<Vec<_>>().join(", "))
                };
                let toml = pkg.dir.as_ref().map(|d| d.join("quack.toml").display().to_string()).unwrap_or_else(|| "quack.toml".into());
                self.emit(
                    m,
                    Diag::new("E0413", u.span, format!("`{}` uses `{}`, but the package `{}` {allowed}", info.name, u.name, pkg.name))
                        .note("a package's quack.toml `[package] effects` is the most its code may use")
                        .note(format!("help: add \"{}\" to `effects` under [package] in {toml}", u.name)),
                );
            }
        }
        for (s, sd) in tp.defs.shapes.iter().enumerate() {
            if tp.program.is_core(sd.module) {
                continue;
            }
            for k in 0..sd.methods.len() {
                if let Some((_, Some(c))) = self.shape_uses.get(&(s, k)) {
                    for u in &c.uses {
                        self.check_name(sd.module, u);
                    }
                }
            }
        }
    }

    fn check_name(&mut self, m: ModId, u: &Ident) {
        if EFFECTS.contains(&u.name.as_str()) {
            return;
        }
        let mut d = Diag::new("E0414", u.span, format!("unknown effect `{}`", u.name)).note(format!("the effects are {}", EFFECTS.join(", ")));
        let cands: Vec<String> = EFFECTS.iter().map(|s| s.to_string()).collect();
        if let Some(s) = super::check::similar(&u.name, &cands) {
            d = d.fix(u.span, s);
        }
        self.emit(m, d);
    }

    /// The clause that carries a function's `uses` (its header line, or its first clause).
    fn first_clause(&self, info: &crate::typed::FnInfo) -> Option<&'a FnClause> {
        let tp = self.tp;
        let FnKind::Duck { item, clauses, header } = &info.kind else { return None };
        let Item::Fn(g) = &tp.program.mods[info.module].ast.items[*item] else { return None };
        if *header { g.header.as_deref() } else { clauses.first().map(|&i| &g.clauses[i]) }
    }

    fn check_fn(&mut self, f: FnId) {
        let b = BodyRef::Fn(f);
        let m = self.module_of(b);
        let generic = self.is_generic(b);
        let insts = self.insts.get(&b).cloned().unwrap_or_default();
        // a non-generic body has one instance (every concrete target resolved); a generic body is
        // checked in its generic view here, and its instances' extra needs are hidden effects
        let inst = if generic { None } else { insts.first().copied() };
        let declared = self.uses(f);
        let ids: Vec<(NodeId, Span, Option<Span>)> = self.body_nodes(b).iter().map(|n| (n.id, n.span, n.closure)).collect();
        let mut used = Set::new();
        let mut missing: Vec<(String, NodeId, Span, Option<Span>, Via)> = Vec::new();
        for &(n, span, closure) in &ids {
            for (s, via) in self.needs(b, inst, n) {
                for e in s {
                    if !declared.contains(&e) && !missing.iter().any(|x| x.0 == e) {
                        missing.push((e.clone(), n, span, closure, via.clone()));
                    }
                    used.insert(e);
                }
            }
        }
        for &i in &insts {
            used.extend(self.inst_needs[i].iter().cloned());
        }
        let name = self.tp.fns[f].name.clone();
        // declared but unused (generic functions only when instantiated, since shape methods
        // resolved per instance may use them)
        let first = self.first_clause(&self.tp.fns[f]);
        let unused: Vec<&Ident> = match first {
            Some(first) if !(generic && insts.is_empty()) => {
                first.uses.iter().filter(|u| EFFECTS.contains(&u.name.as_str()) && !used.contains(&u.name)).collect()
            }
            _ => Vec::new(),
        };
        let kept: Vec<&str> = first.map_or(Vec::new(), |c| c.uses.iter().filter(|u| !unused.iter().any(|x| x.name == u.name)).map(|u| u.name.as_str()).collect());
        if !missing.is_empty() {
            let effs: Vec<String> = missing.iter().map(|x| x.0.clone()).collect();
            let list = effs.iter().map(|e| format!("`{e}`")).collect::<Vec<_>>().join(", ");
            let msg = if effs.len() == 1 {
                format!("`{name}` uses the effect {list} but doesn't declare it")
            } else {
                format!("`{name}` uses the effects {list} but doesn't declare them")
            };
            let (_, _, span, _, _) = &missing[0];
            let mut d = Diag::new("E0410", *span, msg);
            for (e, _, _, closure, via) in &missing {
                d = d.note(format!("call chain: {}", self.chain(&name, via, e)));
                if let Some(c) = closure {
                    d = d.note(format!("the closure at {c} is part of `{name}`, so its effects are `{name}`'s"));
                }
            }
            // With unused effects too (E0411 below), both fixes would edit the same `uses` list, so
            // this one rewrites the whole clause to the right set: the kept effects in the user's
            // order, then the missing ones.
            let fix = if unused.is_empty() {
                self.add_effects_fix(f, &effs)
            } else {
                let mut all = kept.clone();
                all.extend(effs.iter().map(String::as_str));
                first.and_then(|c| self.rewrite_uses(m, c, &all))
            };
            if let Some((at, text)) = fix {
                d = d.fix(at, text);
            }
            self.emit(m, d);
        }
        if unused.is_empty() {
            return;
        }
        let list = unused.iter().map(|u| format!("`{}`", u.name)).collect::<Vec<_>>().join(", ");
        let msg = if unused.len() == 1 {
            format!("`{name}` declares the effect {list} but doesn't use it")
        } else {
            format!("`{name}` declares the effects {list} but doesn't use them")
        };
        let mut d = Diag::new("E0411", unused[0].span, msg).note("declare only the effects a function needs, so callers and quack.toml stay accurate");
        // the E0410 above carries the one combined fix
        if missing.is_empty()
            && let Some(c) = first
            && let Some((at, text)) = self.rewrite_uses(m, c, &kept)
        {
            d = d.fix(at, text);
        }
        self.emit(m, d);
    }

    /// `main → total<Sq> → area (uses fs)`.
    fn chain(&self, from: &str, via: &Via, e: &str) -> String {
        let mut parts = vec![format!("`{from}`")];
        let mut via = via.clone();
        let mut seen = HashSet::new();
        loop {
            if via.declared || via.next.is_none() {
                parts.push(format!("`{}` (uses {e})", via.callee));
                break;
            }
            let j = via.next.unwrap();
            if let BodyRef::Fn(g) = self.tp.instances[j].body
                && self.tp.fns[g].uses.iter().any(|u| u == e)
            {
                parts.push(format!("`{}` (uses {e})", via.callee));
                break;
            }
            parts.push(format!("`{}`", via.callee));
            if !seen.insert(j) || parts.len() > 8 {
                break;
            }
            // find what in instance j needs `e`
            let jb = self.tp.instances[j].body;
            let inst = &self.tp.instances[j];
            let mut ks: Vec<NodeId> = inst.resolved.keys().chain(inst.shows.keys()).copied().collect();
            ks.sort_unstable();
            let next = ks.iter().find_map(|&n| self.needs(jb, Some(j), n).into_iter().find(|(s, _)| s.contains(e)).map(|(_, v)| v));
            match next {
                Some(v) => via = v,
                None => break,
            }
        }
        parts.join(" → ")
    }

    /// Where `uses` goes in a clause: just after the return type, or after the `)` of the
    /// parameter list.
    fn uses_anchor(&self, m: ModId, c: &FnClause) -> Option<Span> {
        if let Some(r) = &c.ret {
            return Some(r.span.after());
        }
        params_close(&self.tp.program.mods[m].src, c.name.span)
    }

    /// The fix-it rewriting a clause's whole `uses` list to `keep` (none: drop the clause).
    fn rewrite_uses(&self, m: ModId, c: &FnClause, keep: &[&str]) -> Option<(Span, String)> {
        let anchor = self.uses_anchor(m, c)?;
        let end = c.uses.last()?.span;
        let text = if keep.is_empty() { String::new() } else { format!(" uses {}", keep.join(", ")) };
        Some((Span { line: anchor.line, col: anchor.col, end_line: end.end_line, end_col: end.end_col }, text))
    }

    /// The fix-it adding `effs` to a function's `uses`.
    fn add_effects_fix(&self, f: FnId, effs: &[String]) -> Option<(Span, String)> {
        let c = self.first_clause(&self.tp.fns[f])?;
        self.add_to_clause(self.tp.fns[f].module, c, effs)
    }

    fn add_to_clause(&self, m: ModId, c: &FnClause, effs: &[String]) -> Option<(Span, String)> {
        match c.uses.last() {
            Some(u) => Some((u.span.after(), effs.iter().map(|e| format!(", {e}")).collect())),
            None => Some((self.uses_anchor(m, c)?, format!(" uses {}", effs.join(", ")))),
        }
    }

    fn check_const(&mut self, c: usize) {
        let b = BodyRef::Const(c);
        let m = self.module_of(b);
        let inst = self.insts.get(&b).and_then(|v| v.first().copied());
        let ids: Vec<(NodeId, Span)> = self.body_nodes(b).iter().map(|n| (n.id, n.span)).collect();
        for (n, span) in ids {
            for (s, via) in self.needs(b, inst, n) {
                let Some(e) = s.iter().next() else { continue };
                let info = &self.tp.consts[c];
                let what = if info.imprint {
                    format!("`imprint {}` is computed at compile time and must be pure", info.name)
                } else {
                    format!("the module constant `{}` must be pure", info.name)
                };
                let d = Diag::new("E0412", span, format!("{what}, but its initializer uses the effect `{e}`"))
                    .note(format!("call chain: {}", self.chain(&info.name, &via, e)))
                    .note("compute it in a function that declares the effect (`main`, for example) and pass it where it is needed");
                self.emit(m, d);
                return;
            }
        }
    }

    /// Conversions to `any Shape` in a body: every method of the converted type must stay within
    /// the shape method's declared effects (E0415).
    fn check_vtables(&mut self, b: BodyRef) {
        let m = self.module_of(b);
        let insts = self.insts.get(&b).cloned().unwrap_or_default();
        let spans: HashMap<NodeId, Span> = self.body_nodes(b).iter().map(|n| (n.id, n.span)).collect();
        let mut done = HashSet::new();
        for i in insts {
            let mut vts: Vec<(NodeId, usize)> = self.tp.instances[i].vtables.iter().map(|(n, v)| (*n, *v)).collect();
            vts.sort_unstable();
            for (n, v) in vts {
                let vt = &self.tp.vtables[v];
                for (k, t) in vt.methods.iter().enumerate() {
                    let Target::Instance(j) = t else { continue };
                    let BodyRef::Fn(g) = self.tp.instances[*j].body else { continue };
                    let mut needs = self.uses(g);
                    needs.extend(self.hidden[*j].iter().cloned());
                    let (allowed, clause) = self.shape_uses.get(&(vt.shape, k)).cloned().unwrap_or_default();
                    let extra: Vec<String> = needs.into_iter().filter(|e| !allowed.contains(e)).collect();
                    if extra.is_empty() || !done.insert((n, k)) {
                        continue;
                    }
                    let Some(&span) = spans.get(&n) else { continue };
                    let ts = self.tp.defs.show(&vt.ty);
                    let sm = self.shape_method_name(vt.shape, k);
                    let list = extra.iter().map(|e| format!("`{e}`")).collect::<Vec<_>>().join(", ");
                    let shape = &self.tp.defs.shapes[vt.shape];
                    let mut d = Diag::new(
                        "E0415",
                        span,
                        format!("converting `{ts}` to `any {}` would let `{sm}` use {list}, which the shape doesn't declare", shape.name),
                    )
                    .note(format!("`{}` for `{ts}` (at {}) uses {list}", self.fn_name(g, m), self.tp.fns[g].span))
                    .note("a call through `any Shape` may only use the effects its shape method declares");
                    if let Some(c) = clause
                        && shape.module == m
                        && let Some((at, text)) = self.add_to_clause(m, c, &extra)
                    {
                        d = d.fix(at, text);
                    }
                    self.emit(m, d);
                }
            }
        }
    }
}

/// Collect the expression nodes under `e` in source order, noting the innermost closure.
fn collect(e: &Expr, closure: Option<Span>, out: &mut Vec<Node>) {
    out.push(Node { id: e.id, span: e.span, closure });
    let inner = if matches!(e.kind, ExprKind::Closure { .. }) { Some(e.span) } else { closure };
    for c in children(e) {
        collect(c, inner, out);
    }
}

/// The empty span just after the `)` closing the parameter list that follows `name`.
fn params_close(src: &str, name: Span) -> Option<Span> {
    let mut depth = 0i32;
    let mut in_str = false;
    for (li, line) in src.lines().enumerate().skip(name.line as usize - 1) {
        let skip = if li + 1 == name.line as usize { name.end_col as usize - 1 } else { 0 };
        for (ci, ch) in line.chars().enumerate().skip(skip) {
            match ch {
                '"' => in_str = !in_str,
                _ if in_str => {}
                '(' | '[' | '{' => depth += 1,
                ')' | ']' | '}' => {
                    depth -= 1;
                    if depth == 0 && ch == ')' {
                        let (l, c) = (li as u32 + 1, ci as u32 + 2);
                        return Some(Span { line: l, col: c, end_line: l, end_col: c });
                    }
                }
                _ => {}
            }
        }
    }
    None
}
