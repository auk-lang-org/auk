//! Lowering of function bodies to C: expressions, statements, patterns, control flow and
//! reference counting. One `Lower` emits one instance (plus the closures, thunks and wrappers it
//! needs) into the `Gen`'s function section.
//!
//! # How a body is lowered
//! Expressions are lowered in evaluation order to C statements; each returns a `Val`: a C
//! expression of a Duck type that is either **owned** (a temporary the current scope will
//! release unless it is moved out with `own`) or **borrowed** (a local, a field of a value that
//! outlives the statement, a global). Locals own their values; parameters are borrowed (or, in
//! a function whose self tail calls became a loop, owned copies). Every C variable is declared
//! where it is first assigned, with a unique name, so Duck blocks need no C braces; only control
//! flow opens C blocks.
//!
//! Scopes mirror Duck's: a statement scope holds that statement's temporaries, block scopes hold
//! locals, a loop marks where `break`/`continue` stop releasing. An early exit (`return`, `?`,
//! `fail`, `break`, `continue`, a self tail call) releases every scope it leaves.
//!
//! Patterns (clauses, `match`, `let`, `for`, closure parameters, `is`) compile to a pure C test
//! expression plus a binding step; clauses and arms are tried top to bottom.

mod pat;

use std::collections::{HashMap, HashSet};
use std::fmt::Write;

use super::ast::{BinOp, Block, ElseArm, Expr, ExprKind as K, FnBody, InterpPart, Item, Lit, Pat, PatKind, UnOp};
use super::cgen::{Gen, c_str};
use super::resolve::ModId;
use super::typed::{
    AwaitKind, BodyRef, Callee, Coercion, ElseKind, FailKind, FieldValue, FnId, FnKind, ForKind, InstId, Intrinsic, LocalId, NameRef, Tables,
    Target, TryKind, TypedProgram,
};
use super::types::{Builtin, ParamId, Ty};

/// A lowered value: a C expression of Duck type `ty`.
#[derive(Debug, Clone)]
pub struct Val {
    pub c: String,
    pub ty: Ty,
    pub owned: bool,
}

impl Val {
    fn unit() -> Val {
        Val { c: "0".into(), ty: Ty::unit(), owned: false }
    }
    fn never() -> Val {
        Val { c: "0".into(), ty: Ty::Never, owned: false }
    }
    fn plain(c: impl Into<String>, ty: Ty) -> Val {
        Val { c: c.into(), ty, owned: false }
    }
    fn is_never(&self) -> bool {
        self.ty == Ty::Never
    }
}

/// An argument: a value, or (for `var` parameters) the address of a place.
enum ArgV {
    Val(Val),
    Addr(String, Ty),
}

#[derive(Clone)]
struct Slot {
    c: String,
    ty: Ty,
}

#[derive(Clone, Copy, PartialEq)]
enum ScopeKind {
    Block,
    Stmt,
}

struct Scope {
    kind: ScopeKind,
    owned: Vec<(String, Ty)>,
}

struct LoopCx {
    /// Index of the loop body's scope.
    depth: usize,
    result: Option<(String, Ty)>,
}

struct TailCx {
    /// C names of the parameters (owned copies, or pointers for `var` parameters).
    params: Vec<(String, Ty, bool)>,
}

/// The state of one C function being emitted.
struct FnState {
    out: String,
    ind: usize,
    scopes: Vec<Scope>,
    loops: Vec<LoopCx>,
    locals: HashMap<LocalId, Slot>,
    ret: Ty,
    tail: Option<TailCx>,
    olds: HashMap<u32, String>,
    var_params: HashSet<LocalId>,
}

impl FnState {
    fn new(ret: Ty) -> FnState {
        FnState {
            out: String::new(),
            ind: 1,
            scopes: Vec::new(),
            loops: Vec::new(),
            locals: HashMap::new(),
            ret,
            tail: None,
            olds: HashMap::new(),
            var_params: HashSet::new(),
        }
    }
}

pub struct Lower<'g, 'a> {
    pub g: &'g mut Gen<'a>,
    tp: &'a TypedProgram,
    m: ModId,
    t: &'a Tables,
    inst: InstId,
    subst: HashMap<ParamId, Ty>,
    file: String,
    f: FnState,
    saved: Vec<FnState>,
}

/// Emit instance `i` (and whatever it needs).
pub fn emit_instance(g: &mut Gen, i: InstId) {
    let tp = g.tp;
    let inst = &tp.instances[i];
    let (m, item) = g.body_item(inst.body);
    let mut lw = Lower {
        tp,
        m,
        t: &tp.tables[m],
        inst: i,
        subst: inst.subst(&tp.fns),
        file: tp.program.mods[m].file.clone(),
        f: FnState::new(Ty::unit()),
        saved: Vec::new(),
        g,
    };
    match (inst.body, item) {
        (BodyRef::Fn(f), Item::Fn(group)) => lw.emit_fn(f, group),
        (BodyRef::Test(_), Item::Test(td)) => lw.emit_test(&td.body),
        (BodyRef::Const(_), Item::Let(cd) | Item::Imprint(cd)) => lw.emit_const(&cd.value),
        _ => panic!("codegen: instance {i} has an unexpected body"),
    }
}

/// The direct sub-expressions that can be call arguments of `e` (receiver first).
fn arg_exprs(e: &Expr) -> Vec<&Expr> {
    match &e.kind {
        K::Call { args, .. } => args.iter().collect(),
        K::MethodCall { recv, args, .. } => std::iter::once(&**recv).chain(args).collect(),
        K::Pipe { lhs, args, .. } => std::iter::once(&**lhs).chain(args).collect(),
        K::OptChain { expr, args, .. } => std::iter::once(&**expr).chain(args.iter().flatten()).collect(),
        K::Binary { lhs, rhs, .. } => vec![lhs, rhs],
        K::Assign { target, value, .. } => vec![target, value],
        _ => Vec::new(),
    }
}

fn is_ident(s: &str) -> bool {
    !matches!(s, "true" | "false" | "NULL")
        && !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') && !s.chars().next().unwrap().is_ascii_digit()
}

impl<'g, 'a> Lower<'g, 'a> {
    // ---- small helpers ----

    fn ty(&self, id: u32) -> Ty {
        match self.t.types.get(&id) {
            Some(t) => t.subst(&self.subst),
            None => Ty::unit(),
        }
    }

    fn local_ty(&self, l: LocalId) -> Ty {
        self.t.locals[l].ty.subst(&self.subst)
    }

    fn sub(&self, t: &Ty) -> Ty {
        t.subst(&self.subst)
    }

    fn loc(&self, span: super::diag::Span) -> String {
        c_str(&format!("{}:{}:{}", self.file, span.line, span.col))
    }

    fn line(&mut self, s: impl AsRef<str>) {
        for _ in 0..self.f.ind {
            self.f.out.push_str("    ");
        }
        self.f.out.push_str(s.as_ref());
        self.f.out.push('\n');
    }

    fn open(&mut self, s: impl AsRef<str>) {
        self.line(s);
        self.f.ind += 1;
    }

    fn close(&mut self, s: impl AsRef<str>) {
        self.f.ind -= 1;
        self.line(s);
    }

    fn name(&mut self, p: &str) -> String {
        format!("{p}{}", self.g.fresh())
    }

    /// Declare a C variable (not registered for release).
    fn decl(&mut self, ty: &Ty, init: &str) -> String {
        let n = self.name("t");
        let c = self.g.ct(ty);
        self.line(format!("{c} {n} = {init};"));
        n
    }

    /// An owned temporary (registered for release in the current scope).
    fn tmp(&mut self, ty: &Ty, init: &str) -> Val {
        let n = self.decl(ty, init);
        self.register(&n, ty);
        Val { c: n, ty: ty.clone(), owned: true }
    }

    fn register(&mut self, c: &str, ty: &Ty) {
        if self.g.needs_rc(ty) {
            self.f.scopes.last_mut().expect("scope").owned.push((c.to_string(), ty.clone()));
        }
    }

    /// Register an owned local in the innermost block scope.
    fn register_local(&mut self, c: &str, ty: &Ty) {
        if !self.g.needs_rc(ty) {
            return;
        }
        let i = self.f.scopes.iter().rposition(|s| s.kind == ScopeKind::Block).unwrap_or(0);
        self.f.scopes[i].owned.push((c.to_string(), ty.clone()));
    }

    fn unregister(&mut self, c: &str) {
        for s in self.f.scopes.iter_mut().rev() {
            if let Some(p) = s.owned.iter().rposition(|(x, _)| x == c) {
                s.owned.remove(p);
                return;
            }
        }
    }

    fn push(&mut self, kind: ScopeKind) {
        self.f.scopes.push(Scope { kind, owned: Vec::new() });
    }

    fn pop(&mut self) {
        let s = self.f.scopes.pop().expect("scope");
        for (c, ty) in s.owned.iter().rev() {
            if let Some(r) = self.g.release(ty, c) {
                self.line(r);
            }
        }
    }

    /// Release everything owned by scopes `depth..` (for an early exit), without popping.
    fn cleanup_from(&mut self, depth: usize) {
        let mut rels = Vec::new();
        for s in self.f.scopes[depth..].iter().rev() {
            for (c, ty) in s.owned.iter().rev() {
                rels.push((c.clone(), ty.clone()));
            }
        }
        for (c, ty) in rels {
            if let Some(r) = self.g.release(&ty, &c) {
                self.line(r);
            }
        }
    }

    /// Take ownership of a value: moves an owned temporary, retains a borrowed value. Returns
    /// a C expression to store.
    fn own(&mut self, v: Val) -> String {
        if v.owned {
            self.unregister(&v.c);
            return v.c;
        }
        if let Some(r) = self.g.retain(&v.ty, &v.c) {
            self.line(r);
        }
        v.c
    }

    /// `own`, giving a zero of `ty` for a `never` value. (Conversions to `ty` were applied
    /// already: the checker records every auto-wrap in `coercions`.)
    fn own_as(&mut self, v: Val, ty: &Ty) -> String {
        if v.is_never() {
            return self.g.zero(ty);
        }
        self.own(v)
    }

    /// Like `own`, but materialized in a fresh (unregistered) variable.
    fn hold(&mut self, v: Val) -> String {
        if v.owned && is_ident(&v.c) {
            self.unregister(&v.c);
            return v.c;
        }
        let ty = v.ty.clone();
        let o = self.own(v);
        self.decl(&ty, &o)
    }

    /// A borrowed value as a C expression of type `ty` (zero for `never`).
    fn val_as(&mut self, v: &Val, ty: &Ty) -> String {
        if v.is_never() { self.g.zero(ty) } else { v.c.clone() }
    }

    /// An addressable C variable holding the value (borrowed copy when needed).
    fn lvalue(&mut self, v: &Val, ty: &Ty) -> String {
        if is_ident(&v.c) && !v.is_never() {
            return v.c.clone();
        }
        let c = self.val_as(v, ty);
        self.decl(ty, &c)
    }

    /// An owned temporary for `expr`, which is an owned C value of `ty`.
    fn adopt(&mut self, ty: &Ty, expr: &str) -> Val {
        self.tmp(ty, expr)
    }

    /// Re-register an owned held variable as a temporary in the current scope.
    fn reown(&mut self, c: String, ty: Ty) -> Val {
        self.register(&c, &ty);
        Val { c, ty, owned: true }
    }

    fn zero_decl(&mut self, ty: &Ty) -> String {
        let z = self.g.zero(ty);
        self.decl(ty, &z)
    }

    /// The index of struct field `name` in type `t`.
    fn field_index(&self, t: &Ty, name: &str) -> Option<usize> {
        match t {
            Ty::Named(d, _) if self.tp.defs.is_struct(*d) => self.tp.defs.fields(*d).iter().position(|f| f.name == name),
            _ => None,
        }
    }

    fn has_value(ty: &Ty) -> bool {
        !ty.is_unit() && *ty != Ty::Never
    }

    // ---- function bodies ----

    fn begin(&mut self, ret: Ty) {
        let f = std::mem::replace(&mut self.f, FnState::new(ret));
        self.saved.push(f);
    }

    fn end(&mut self) -> FnState {
        let prev = self.saved.pop().expect("fn state");
        std::mem::replace(&mut self.f, prev)
    }

    fn emit_fn(&mut self, fid: FnId, group: &'a super::ast::FnGroup) {
        let tp = self.tp;
        let info = &tp.fns[fid];
        let FnKind::Duck { clauses, header, .. } = &info.kind else { unreachable!() };
        let name = self.g.inst_fn(self.inst);
        // traced: `name` becomes the tracing wrapper around the function, renamed `_untraced`
        let traced = self.g.traced(info.module);
        let outer = name.clone();
        let name = if traced { format!("{name}_untraced") } else { name };
        let params: Vec<(Ty, bool)> = info.params.iter().map(|p| (self.sub(&p.ty), p.var)).collect();
        let ret = self.sub(&info.ret);
        let hdr = if *header { group.header.as_deref() } else { None };
        let cls: Vec<&super::ast::FnClause> = clauses.iter().map(|&c| &group.clauses[c]).collect();
        let ensures = self.g.debug() && (hdr.is_some_and(|h| !h.ensures.is_empty()) || cls.iter().any(|c| !c.ensures.is_empty()));
        let body_name = if ensures { format!("{name}_body") } else { name.clone() };
        let rc = self.g.ct(&ret);
        let pdecl: Vec<String> = params.iter().enumerate().map(|(k, (t, var))| {
            let c = self.g.ct(t);
            if *var { format!("{c} *p{k}") } else { format!("{c} a{k}") }
        }).collect();
        let sig = format!("static {rc} {body_name}({})", if pdecl.is_empty() { "void".to_string() } else { pdecl.join(", ") });

        self.begin(ret.clone());
        // var parameters bound to plain names (tail calls may pass them through)
        for c in &cls {
            for (k, p) in c.params.iter().enumerate() {
                if params[k].1
                    && let Some(&l) = self.t.binds.get(&p.pat.id)
                {
                    self.f.var_params.insert(l);
                }
            }
        }
        // with `ensures`, this is the body behind the checking wrapper: self tail calls loop here,
        // and the wrapper checks the outer call's result once
        let tail = cls.iter().any(|c| self.body_has_tail_call(c));
        self.push(ScopeKind::Block);
        let mut pnames = Vec::new();
        for (k, (t, var)) in params.iter().enumerate() {
            if *var {
                pnames.push((format!("(*p{k})"), t.clone(), true));
                continue;
            }
            let c = self.g.ct(t);
            self.line(format!("{c} p{k} = a{k};"));
            if tail {
                if let Some(r) = self.g.retain(t, &format!("p{k}")) {
                    self.line(r);
                }
                self.register(&format!("p{k}"), t);
            }
            pnames.push((format!("p{k}"), t.clone(), false));
        }
        if tail {
            self.f.tail = Some(TailCx { params: params.iter().enumerate().map(|(k, (t, var))| (format!("p{k}"), t.clone(), *var)).collect() });
            self.f.ind -= 1;
            self.line("dk_tail:;");
            self.f.ind += 1;
        }
        // header contracts
        if let Some(h) = hdr {
            for (k, p) in h.params.iter().enumerate() {
                if let Some(&l) = self.t.binds.get(&p.pat.id) {
                    self.f.locals.insert(l, Slot { c: pnames[k].0.clone(), ty: pnames[k].1.clone() });
                }
            }
            for r in &h.requires {
                self.requires(r);
            }
        }
        for c in &cls {
            self.clause(c, &pnames, &ret);
        }
        let loc = self.loc(info.span);
        self.line(format!("duck_panic({loc}, \"no clause of `{}` matches the arguments\");", info.name.replace(['"', '\\'], "")));
        self.f.scopes.clear();
        let st = self.end();
        let _ = writeln!(self.g.protos, "{sig};");
        let _ = writeln!(self.g.funcs, "{sig} {{\n{}}}\n", st.out);
        if ensures {
            self.ensures_wrapper(fid, &name, &body_name, &params, &ret, hdr, &cls);
        }
        if traced {
            self.trace_wrapper(fid, &outer, &name, &params, &ret);
        }
    }

    /// The tracing wrapper `outer` of the function `inner` (`duck run/test --trace`): records a
    /// call event with the shown arguments, and a return (or error) event with the shown result.
    /// Self tail calls are loops inside `inner`, so a tail-recursive loop is one call/ret pair.
    fn trace_wrapper(&mut self, fid: FnId, outer: &str, inner: &str, params: &[(Ty, bool)], ret: &Ty) {
        let info = &self.tp.fns[fid];
        let fname = c_str(&format!("{}.{}", self.trace_mod_name(info.module), info.name));
        let loc = self.loc(info.span);
        let rc = self.g.ct(ret);
        let mut pdecl = Vec::new();
        let mut shows = Vec::new();
        for (k, (t, var)) in params.iter().enumerate() {
            let c = self.g.ct(t);
            pdecl.push(if *var { format!("{c} *p{k}") } else { format!("{c} p{k}") });
            shows.push(self.trace_show(t, &if *var { format!("(*p{k})") } else { format!("p{k}") }));
        }
        let sig = format!("static {rc} {outer}({})", if pdecl.is_empty() { "void".to_string() } else { pdecl.join(", ") });
        let call = format!("{inner}({})", (0..params.len()).map(|k| format!("p{k}")).collect::<Vec<_>>().join(", "));
        let mut b = format!("{sig} {{
    if (!duck_trace_begin()) return {call};
");
        if shows.is_empty() {
            let _ = writeln!(b, "    duck_trace_call({fname}, {loc}, 0, NULL);");
        } else {
            let _ = writeln!(b, "    DuckStr *dk_args[{}] = {{{}}};", shows.len(), shows.join(", "));
            let _ = writeln!(b, "    duck_trace_call({fname}, {loc}, {}, dk_args);", shows.len());
        }
        let _ = writeln!(b, "    {rc} dk_r = {call};");
        let unitish = |t: &Ty| t.is_unit() || *t == Ty::Never;
        let record = match ret {
            Ty::Res(t, _) => {
                let ok = if unitish(t) { "NULL".to_string() } else { self.trace_show(t, "dk_r.val") };
                format!("if (dk_r.ok) duck_trace_ret({fname}, {ok});
        else duck_trace_err({fname}, dk_r.err);")
            }
            t if unitish(t) => format!("duck_trace_ret({fname}, NULL);"),
            t => format!("duck_trace_ret({fname}, {});", self.trace_show(t, "dk_r")),
        };
        let _ = writeln!(b, "    if (duck_trace_exit()) {{
        {record}
    }}
    return dk_r;
}}
");
        let _ = writeln!(self.g.protos, "{sig};");
        self.g.funcs.push_str(&b);
    }

    /// A module's name in trace events: its path (`json`, `http.uri`), but the root file of a
    /// program that isn't a project's `src/lib.duck`/`src/main.duck` goes by its file name
    /// (`examples/calc.duck` is `calc`, not the `examples` project).
    fn trace_mod_name(&self, m: ModId) -> String {
        let p = &self.tp.program;
        let stem = std::path::Path::new(&p.mods[m].file).file_stem().map(|s| s.to_string_lossy().into_owned());
        match stem {
            Some(stem) if m == p.root && stem != "lib" && stem != "main" => stem,
            _ => p.name(m),
        }
    }

    /// A C expression for the shown value of `e` (type `t`) in a trace event: an owned `DuckStr *`.
    fn trace_show(&mut self, t: &Ty, e: &str) -> String {
        match self.g.dshow_fn(t) {
            Some(f) => format!("{f}({e})"),
            None => {
                let text = format!("<{}>", self.g.show_ty(t));
                format!("duck_str_from_bytes({}, {})", c_str(&text), text.len())
            }
        }
    }

    fn requires(&mut self, r: &Expr) {
        self.push(ScopeKind::Stmt);
        let v = self.expr(r);
        let c = self.val_as(&v, &Ty::Bool);
        let cv = self.decl(&Ty::Bool, &c);
        self.pop();
        let loc = self.loc(r.span);
        let text = c_str(&self.g.span_text(self.m, r.span));
        self.line(format!("if (!{cv}) duck_requires_fail({loc}, {text});"));
    }

    fn clause(&mut self, c: &'a super::ast::FnClause, pnames: &[(String, Ty, bool)], ret: &Ty) {
        let mut conds = Vec::new();
        for (k, p) in c.params.iter().enumerate() {
            let t = self.pat_test(&p.pat, &pnames[k].0);
            if t != "1" {
                conds.push(t);
            }
        }
        let cond = if conds.is_empty() { "1".to_string() } else { conds.join(" && ") };
        self.open(format!("if ({cond}) {{"));
        self.push(ScopeKind::Block);
        for (k, p) in c.params.iter().enumerate() {
            self.bind_top(&p.pat, &pnames[k].0, &pnames[k].1);
        }
        let guarded = if let Some(gx) = &c.guard {
            self.push(ScopeKind::Stmt);
            let v = self.expr(gx);
            let gc = self.val_as(&v, &Ty::Bool);
            let gv = self.decl(&Ty::Bool, &gc);
            self.pop();
            self.open(format!("if ({gv}) {{"));
            true
        } else {
            false
        };
        for r in &c.requires {
            self.requires(r);
        }
        self.push(ScopeKind::Block);
        let v = match &c.body {
            Some(FnBody::Expr(e)) => self.expr_t(e, true),
            Some(FnBody::Block(b)) => self.block(b, true),
            _ => Val::unit(),
        };
        self.ret_val(v, ret);
        self.pop();
        if guarded {
            self.close("}");
        }
        self.pop();
        self.close("}");
    }

    /// Return a value from the current function (releasing every scope).
    fn ret_val(&mut self, v: Val, ret: &Ty) {
        if v.is_never() {
            return;
        }
        let o = self.own_as(v, ret);
        let rv = self.decl(ret, &o);
        self.cleanup_from(0);
        self.line(format!("return {rv};"));
    }

    /// The function `name` that checks `ensures` around the clause group's body `body_name`.
    /// It finds the clause that matches the arguments (pattern tests and guards, which are pure),
    /// binds that clause's names, captures the `old(e)` values of the header's and that clause's
    /// `ensures`, calls the body, and checks them on the result (a successful one for `T!`).
    #[allow(clippy::too_many_arguments)]
    fn ensures_wrapper(
        &mut self,
        fid: FnId,
        name: &str,
        body_name: &str,
        params: &[(Ty, bool)],
        ret: &Ty,
        hdr: Option<&'a super::ast::FnClause>,
        cls: &[&'a super::ast::FnClause],
    ) {
        let rc = self.g.ct(ret);
        let pdecl: Vec<String> = params.iter().enumerate().map(|(k, (t, var))| {
            let c = self.g.ct(t);
            if *var { format!("{c} *p{k}") } else { format!("{c} p{k}") }
        }).collect();
        let sig = format!("static {rc} {name}({})", if pdecl.is_empty() { "void".to_string() } else { pdecl.join(", ") });
        self.begin(ret.clone());
        self.push(ScopeKind::Block);
        let pnames: Vec<(String, Ty, bool)> = params
            .iter()
            .enumerate()
            .map(|(k, (t, var))| (if *var { format!("(*p{k})") } else { format!("p{k}") }, t.clone(), *var))
            .collect();
        if let Some(h) = hdr {
            for (k, p) in h.params.iter().enumerate() {
                if let PatKind::Bind(_) = &p.pat.kind
                    && let Some(&l) = self.t.binds.get(&p.pat.id)
                {
                    self.f.locals.insert(l, Slot { c: pnames[k].0.clone(), ty: params[k].0.clone() });
                }
            }
            self.capture_olds(fid, h);
        }
        // with clause `ensures`, find the clause that will run (tried in order, like the body)
        let dispatch = cls.iter().any(|c| !c.ensures.is_empty());
        for c in cls.iter().filter(|_| dispatch) {
            let mut conds = Vec::new();
            for (k, p) in c.params.iter().enumerate() {
                let t = self.pat_test(&p.pat, &pnames[k].0);
                if t != "1" {
                    conds.push(t);
                }
            }
            self.open(format!("if ({}) {{", if conds.is_empty() { "1".to_string() } else { conds.join(" && ") }));
            self.push(ScopeKind::Block);
            for (k, p) in c.params.iter().enumerate() {
                self.bind_top(&p.pat, &pnames[k].0, &pnames[k].1);
            }
            let guarded = if let Some(gx) = &c.guard {
                self.push(ScopeKind::Stmt);
                let v = self.expr(gx);
                let gc = self.val_as(&v, &Ty::Bool);
                let gv = self.decl(&Ty::Bool, &gc);
                self.pop();
                self.open(format!("if ({gv}) {{"));
                true
            } else {
                false
            };
            self.capture_olds(fid, c);
            self.call_and_check(fid, body_name, params.len(), ret, hdr, Some(c));
            if guarded {
                self.close("}");
            }
            self.pop();
            self.close("}");
        }
        self.call_and_check(fid, body_name, params.len(), ret, hdr, None);
        let st = self.end();
        let _ = writeln!(self.g.protos, "{sig};");
        let _ = writeln!(self.g.funcs, "{sig} {{\n{}}}\n", st.out);
    }

    /// Capture (as owned locals of the current scope) the `old(e)` values in `c`'s `ensures`.
    fn capture_olds(&mut self, fid: FnId, c: &'a super::ast::FnClause) {
        let tp = self.tp;
        let mut old_exprs: Vec<&'a Expr> = Vec::new();
        for e in &c.ensures {
            collect_olds(e, &tp.fns[fid].olds, &mut old_exprs);
        }
        for e in old_exprs {
            let v = self.expr(e);
            let ty = v.ty.clone();
            let o = self.own_as(v, &ty);
            let n = self.decl(&ty, &o);
            self.register(&n, &ty);
            self.f.olds.insert(e.id, n);
        }
    }

    /// In the `ensures` wrapper: call the body, check the header's and `clause`'s `ensures` on
    /// its result, release everything and return it.
    fn call_and_check(&mut self, fid: FnId, body_name: &str, nparams: usize, ret: &Ty, hdr: Option<&'a super::ast::FnClause>, clause: Option<&'a super::ast::FnClause>) {
        let args: Vec<String> = (0..nparams).map(|k| format!("p{k}")).collect();
        let r = self.decl(ret, &format!("{body_name}({})", args.join(", ")));
        let is_res = matches!(ret, Ty::Res(..));
        if let Some(l) = self.tp.fns[fid].result_local {
            let (c, t) = match ret {
                Ty::Res(t, _) => (format!("{r}.val"), (**t).clone()),
                t => (r.clone(), t.clone()),
            };
            self.f.locals.insert(l, Slot { c, ty: t });
        }
        if is_res {
            self.open(format!("if ({r}.ok) {{"));
        }
        for e in hdr.into_iter().chain(clause).flat_map(|c| &c.ensures) {
            self.push(ScopeKind::Stmt);
            let v = self.expr(e);
            let cv = self.val_as(&v, &Ty::Bool);
            let b = self.decl(&Ty::Bool, &cv);
            self.pop();
            let loc = self.loc(e.span);
            let text = c_str(&self.g.span_text(self.m, e.span));
            self.line(format!("if (!{b}) duck_ensures_fail({loc}, {text});"));
        }
        if is_res {
            self.close("}");
        }
        self.cleanup_from(0);
        self.line(format!("return {r};"));
    }

    fn emit_test(&mut self, body: &'a Block) {
        let name = self.g.inst_fn(self.inst);
        let ret = Ty::res(Ty::unit(), self.g.err_ty());
        self.begin(ret);
        self.push(ScopeKind::Block);
        for s in &body.stmts {
            self.stmt(s);
        }
        self.cleanup_from(0);
        self.line("return DUCK_OK(DuckRes_unit, 0);");
        self.f.scopes.clear();
        let st = self.end();
        let _ = writeln!(self.g.protos, "static DuckRes_unit {name}_body(void);\nstatic DuckErr *{name}(void);");
        let _ = writeln!(
            self.g.funcs,
            "static DuckRes_unit {name}_body(void) {{\n{}}}\nstatic DuckErr *{name}(void) {{\n    DuckRes_unit r = {name}_body();\n    return r.ok ? NULL : r.err;\n}}\n",
            st.out
        );
    }

    fn emit_const(&mut self, value: &'a Expr) {
        let name = self.g.inst_fn(self.inst);
        let BodyRef::Const(c) = self.tp.instances[self.inst].body else { unreachable!() };
        let ty = self.tp.consts[c].ty.clone();
        let rc = self.g.ct(&ty);
        self.begin(ty.clone());
        self.push(ScopeKind::Block);
        let v = self.expr(value);
        self.ret_val(v, &ty);
        self.f.scopes.clear();
        let st = self.end();
        let _ = writeln!(self.g.protos, "static {rc} {name}(void);");
        let z = self.g.zero(&ty);
        let _ = writeln!(self.g.funcs, "static {rc} {name}(void) {{\n{}    return {z};\n}}\n", st.out);
    }

    // ---- tail calls ----

    /// Is `c`'s body (in tail position) a self call that can become a jump?
    fn body_has_tail_call(&self, c: &super::ast::FnClause) -> bool {
        match &c.body {
            Some(FnBody::Expr(e)) => self.tail_scan(e),
            Some(FnBody::Block(b)) => b.stmts.iter().any(|s| self.any_return_tail(s)) || b.stmts.last().is_some_and(|s| self.tail_scan(s)),
            _ => false,
        }
    }

    fn any_return_tail(&self, e: &Expr) -> bool {
        let mut found = false;
        super::check::visit_expr(e, &mut |x| {
            if let K::Return(Some(v)) = &x.kind
                && self.tail_scan(v)
            {
                found = true;
            }
        });
        found
    }

    fn tail_scan(&self, e: &Expr) -> bool {
        match &e.kind {
            K::Block(b) => b.stmts.last().is_some_and(|s| self.tail_scan(s)),
            K::If { then, els, .. } => then.stmts.last().is_some_and(|s| self.tail_scan(s)) || els.as_ref().is_some_and(|x| self.tail_scan(x)),
            K::Match { arms, .. } => arms.iter().any(|a| self.tail_scan(&a.body)),
            K::Return(Some(x)) => self.tail_scan(x),
            K::Call { .. } | K::MethodCall { .. } | K::Pipe { .. } => self.is_self_tail_call(e),
            _ => false,
        }
    }

    fn is_self_tail_call(&self, e: &Expr) -> bool {
        let inst = &self.tp.instances[self.inst];
        if inst.resolved.get(&e.id) != Some(&Target::Instance(self.inst)) {
            return false;
        }
        if self.t.coercions.get(&e.id).is_some_and(|c| !c.is_empty()) || matches!(self.ty(e.id), Ty::Task(_)) {
            return false;
        }
        let Some(call) = self.t.calls.get(&e.id) else { return false };
        let exprs = arg_exprs(e);
        for a in &call.args {
            if !a.by_ref {
                continue;
            }
            let Some(x) = exprs.iter().find(|x| x.id == a.node) else { return false };
            let inner = if let K::Ref(i) = &x.kind { &**i } else { *x };
            match self.t.names.get(&inner.id) {
                Some(NameRef::Local(l)) if matches!(inner.kind, K::Name(_)) && self.f.var_params.contains(l) => {}
                _ => return false,
            }
        }
        true
    }

    fn tail_call(&mut self, e: &Expr) -> Val {
        let call = &self.t.calls[&e.id];
        let exprs = arg_exprs(e);
        let params = self.f.tail.as_ref().unwrap().params.clone();
        let mut news = Vec::new();
        for (k, a) in call.args.iter().enumerate() {
            let x = exprs.iter().find(|x| x.id == a.node).copied().expect("argument");
            if a.by_ref {
                let inner = if let K::Ref(i) = &x.kind { &**i } else { x };
                let K::Name(_) = &inner.kind else { unreachable!() };
                let Some(NameRef::Local(l)) = self.t.names.get(&inner.id) else { unreachable!() };
                let slot = self.f.locals[l].clone();
                news.push(format!("&{}", slot.c));
            } else {
                let v = self.expr(x);
                let o = self.own_as(v, &params[k].1);
                let n = self.decl(&params[k].1, &o);
                news.push(n);
            }
        }
        self.cleanup_from(1);
        for (k, (p, ty, var)) in params.iter().enumerate() {
            if *var {
                self.line(format!("p{k} = {};", news[k]));
            } else {
                if let Some(r) = self.g.release(ty, p) {
                    self.line(r);
                }
                self.line(format!("{p} = {};", news[k]));
            }
        }
        self.line("goto dk_tail;");
        Val::never()
    }

    // ---- statements and blocks ----

    fn stmt(&mut self, e: &Expr) {
        self.push(ScopeKind::Stmt);
        let _ = self.expr(e);
        self.pop();
    }

    /// A block's value (owned when it has one).
    fn block(&mut self, b: &Block, tail: bool) -> Val {
        self.push(ScopeKind::Block);
        let n = b.stmts.len();
        let mut out = Val::unit();
        for (i, s) in b.stmts.iter().enumerate() {
            if i + 1 < n {
                self.stmt(s);
                continue;
            }
            let v = self.expr_t(s, tail);
            if v.is_never() {
                out = v;
            } else if Self::has_value(&v.ty) || self.g.needs_rc(&v.ty) {
                let ty = v.ty.clone();
                let h = self.hold(v);
                out = Val { c: h, ty, owned: true };
            } else {
                out = v;
                if !is_ident(&out.c) && !out.c.starts_with('(') && out.c != "0" {
                    let ty = out.ty.clone();
                    let c = out.c.clone();
                    out.c = self.decl(&ty, &c);
                }
            }
        }
        self.pop();
        if out.owned && !out.is_never() {
            let (c, ty) = (out.c.clone(), out.ty.clone());
            out = self.reown(c, ty);
        }
        if n == 0
            && let Some(cs) = self.t.coercions.get(&b.id)
        {
            let cs = cs.clone();
            out = self.coerce(out, &cs, b.id);
        }
        out
    }

    // ---- expressions ----

    fn expr(&mut self, e: &Expr) -> Val {
        self.expr_t(e, false)
    }

    fn expr_t(&mut self, e: &Expr, tail: bool) -> Val {
        let v = self.expr_inner(e, tail);
        match self.t.coercions.get(&e.id) {
            Some(cs) if !v.is_never() && !cs.is_empty() => {
                let cs = cs.clone();
                self.coerce(v, &cs, e.id)
            }
            _ => v,
        }
    }

    fn coerce(&mut self, mut v: Val, cs: &[Coercion], node: u32) -> Val {
        for c in cs {
            match c {
                Coercion::WrapSome => {
                    let ty = Ty::opt(v.ty.clone());
                    let ct = self.g.ct(&ty);
                    let o = self.own(v);
                    v = self.tmp(&ty, &format!("(({ct}){{.some = true, .val = {o}}})"));
                }
                Coercion::WrapOk => {
                    let ty = Ty::res(v.ty.clone(), self.g.err_ty());
                    let ct = self.g.ct(&ty);
                    let o = self.own(v);
                    v = self.tmp(&ty, &format!("DUCK_OK({ct}, {o})"));
                }
                Coercion::ToAny(s) => {
                    let vid = self.tp.instances[self.inst].vtables.get(&node).copied();
                    let ty = Ty::Any(*s);
                    let ct = self.g.ct(&ty);
                    let vt = match vid {
                        Some(vid) => self.vtable(vid),
                        None => "NULL".into(),
                    };
                    let src = v.ty.clone();
                    let o = self.own(v);
                    let b = self.g.box_new(&src, &o);
                    v = self.tmp(&ty, &format!("(({ct}){{{b}, {vt}}})"));
                }
            }
        }
        v
    }

    fn expr_inner(&mut self, e: &Expr, tail: bool) -> Val {
        match &e.kind {
            K::Lit(l) => self.lit(l, false),
            // units are erased: the literal's value
            K::Measured { expr, .. } => self.expr_inner(expr, tail),
            K::Interp(parts) => self.interp(parts),
            K::Name(_) => self.name_ref(e),
            K::Hole => {
                let ty = self.ty(e.id);
                let loc = self.loc(e.span);
                let exp = self.g.show_ty(&ty);
                self.g.note_hole(format!("{}:{}:{}", self.file, e.span.line, e.span.col), exp.clone());
                self.line(format!("duck_hole({loc}, {});", c_str(&exp)));
                Val::never()
            }
            K::Field { expr, name } => {
                if self.t.names.contains_key(&e.id) {
                    return self.name_ref(e);
                }
                let b = self.expr(expr);
                let bt = b.ty.clone();
                let ft = self.ty(e.id);
                if let Ty::Named(..) = bt {
                    if b.is_never() {
                        return Val::never();
                    }
                    let Some(i) = self.field_index(&bt, &name.name) else { return Val::never() };
                    let c = self.g.field_get(&bt, i, &b.c);
                    return Val { c, ty: ft, owned: false };
                }
                Val::never()
            }
            K::TupleField { expr, index } => {
                let b = self.expr(expr);
                if b.is_never() {
                    return Val::never();
                }
                let ty = self.ty(e.id);
                Val { c: format!("({}).f{index}", b.c), ty, owned: false }
            }
            K::Call { .. } | K::MethodCall { .. } | K::Pipe { .. } => self.call(e, None, tail),
            K::Index { expr, index } => self.index(e, expr, index),
            K::Slice { expr, lo, hi, inclusive } => {
                let x = self.expr(expr);
                let l = self.expr(lo);
                let h = self.expr(hi);
                let loc = self.loc(e.span);
                let hc = if *inclusive { format!("duck_add({}, 1, {loc})", h.c) } else { h.c.clone() };
                let ty = x.ty.clone();
                let f = if ty == Ty::Str { "duck_str_slice" } else { "duck_arr_slice" };
                self.tmp(&ty, &format!("{f}({}, {}, {hc}, {loc})", x.c, l.c))
            }
            K::Unary { op, expr } => match op {
                UnOp::Not => {
                    let v = self.expr(expr);
                    self.tmp(&Ty::Bool, &format!("!({})", v.c))
                }
                UnOp::BitNot => {
                    let v = self.expr(expr);
                    self.tmp(&Ty::Int, &format!("(~({}))", v.c))
                }
                UnOp::Neg => {
                    if let K::Lit(l @ (Lit::Int(_) | Lit::Float(_))) = &expr.kind {
                        return self.lit(l, true);
                    }
                    let v = self.expr(expr);
                    if v.ty == Ty::Int {
                        let loc = self.loc(e.span);
                        self.tmp(&Ty::Int, &format!("duck_neg({}, {loc})", v.c))
                    } else {
                        self.tmp(&Ty::Float, &format!("(-({}))", v.c))
                    }
                }
            },
            K::Binary { op, lhs, rhs } => self.binary(e, *op, lhs, rhs),
            K::Range { lo, hi, inclusive } => {
                let l = self.expr(lo);
                let h = self.expr(hi);
                let xs = self.tmp(&Ty::list(Ty::Int), "duck_arr_new(&duck_ops_int, 0)");
                let i = self.name("i");
                let cmp = if *inclusive { "<=" } else { "<" };
                self.open(format!("for (int64_t {i} = {}; {i} {cmp} {}; {i}++) {{", l.c, h.c));
                self.line(format!("duck_arr_push(&{}, &{i});", xs.c));
                self.close("}");
                xs
            }
            K::Is { expr, pat } => {
                let v = self.expr(expr);
                let vc = self.lvalue(&v, &v.ty.clone());
                let c = self.pat_test(pat, &vc);
                self.tmp(&Ty::Bool, &c)
            }
            K::Try(x) => self.try_(e, x),
            K::Unwrap(x) => {
                let v = self.expr(x);
                if v.is_never() {
                    return v;
                }
                let loc = self.loc(e.span);
                let w = self.hold(v.clone());
                let ty = self.ty(e.id);
                match v.ty {
                    Ty::Opt(_) => self.line(format!("if (!{w}.some) duck_unwrap_none({loc});")),
                    _ => self.line(format!("if (!{w}.ok) duck_unwrap_err({loc}, {w}.err);")),
                }
                self.adopt(&ty, &format!("{w}.val"))
            }
            K::OptChain { expr, name, args } => self.opt_chain(e, expr, name, args.is_some()),
            K::Else { expr, arm } => self.else_(e, expr, arm),
            K::Await(x) => self.await_(e, x),
            K::Ref(x) => self.expr(x),
            K::Closure { params, body } => self.closure(e, params, body),
            K::If { cond, then, els } => self.if_(e, cond, then, els.as_deref(), tail),
            K::Match { scrut, arms } => self.match_(e, scrut, arms, tail),
            K::Loop(b) => {
                let ty = self.ty(e.id);
                let r = if Self::has_value(&ty) { Some(self.zero_decl(&ty)) } else { None };
                self.open("for (;;) {");
                self.push(ScopeKind::Block);
                let depth = self.f.scopes.len() - 1;
                self.f.loops.push(LoopCx { depth, result: r.clone().map(|r| (r, ty.clone())) });
                for s in &b.stmts {
                    self.stmt(s);
                }
                self.f.loops.pop();
                self.pop();
                self.close("}");
                match r {
                    Some(r) => self.reown(r, ty),
                    None if ty == Ty::Never => Val::never(),
                    None => Val::unit(),
                }
            }
            K::While { cond, body } => {
                self.open("while (1) {");
                self.push(ScopeKind::Stmt);
                let c = self.expr(cond);
                let cc = self.val_as(&c, &Ty::Bool);
                let cv = self.decl(&Ty::Bool, &cc);
                self.pop();
                self.line(format!("if (!{cv}) break;"));
                self.push(ScopeKind::Block);
                let depth = self.f.scopes.len() - 1;
                self.f.loops.push(LoopCx { depth, result: None });
                for s in &body.stmts {
                    self.stmt(s);
                }
                self.f.loops.pop();
                self.pop();
                self.close("}");
                Val::unit()
            }
            K::For { index, pat, iter, body } => {
                self.for_(e, index.as_ref(), pat, iter, body);
                Val::unit()
            }
            K::Block(b) => self.block(b, tail),
            K::Let { pat, value, els, .. } => {
                self.let_(e, pat, value, els.as_ref());
                Val::unit()
            }
            K::Assign { op, target, value } => {
                self.assign(e, *op, target, value);
                Val::unit()
            }
            K::Assert(x) => {
                self.assert_(x);
                Val::unit()
            }
            K::Return(x) => {
                let ret = self.f.ret.clone();
                let v = match x {
                    Some(x) => self.expr_t(x, true),
                    None => {
                        let mut v = Val::unit();
                        if let Some(cs) = self.t.coercions.get(&e.id) {
                            let cs = cs.clone();
                            v = self.coerce(v, &cs, e.id);
                        }
                        v
                    }
                };
                self.ret_val(v, &ret);
                Val::never()
            }
            K::Break(x) => {
                let lp = self.f.loops.last().map(|l| (l.depth, l.result.clone()));
                let Some((depth, result)) = lp else { return Val::never() };
                match x {
                    Some(x) => {
                        let v = self.expr(x);
                        if let Some((r, ty)) = &result {
                            let o = self.own_as(v, ty);
                            self.line(format!("{r} = {o};"));
                        }
                    }
                    // a bare `break` out of a `loop` whose value is `()!` / `()?`: the checker
                    // recorded the auto-wrap of `()` on this node
                    None => {
                        if let (Some((r, ty)), Some(cs)) = (&result, self.t.coercions.get(&e.id)) {
                            let cs = cs.clone();
                            let v = self.coerce(Val::unit(), &cs, e.id);
                            let o = self.own_as(v, ty);
                            self.line(format!("{r} = {o};"));
                        }
                    }
                }
                self.cleanup_from(depth);
                self.line("break;");
                Val::never()
            }
            K::Continue => {
                if let Some(depth) = self.f.loops.last().map(|l| l.depth) {
                    self.cleanup_from(depth);
                    self.line("continue;");
                }
                Val::never()
            }
            K::Peek(x) => {
                let v = self.expr(x);
                let shown = self.show_of(x.id, &v);
                let s = self.decl(&Ty::Str, &shown);
                let loc = c_str(&format!("{}:{}", self.file, e.span.line));
                let text = c_str(&self.g.span_text(self.m, x.span));
                self.line(format!("duck_peek({loc}, {text}, {s});"));
                self.line(format!("duck_release({s});"));
                v
            }
            K::Struct { .. } => self.struct_lit(e),
            K::List(xs) => {
                let ty = self.ty(e.id);
                let Ty::List(et) = &ty else { return Val::never() };
                let et = (**et).clone();
                let ops = self.g.ops(&et);
                if xs.is_empty() {
                    return self.tmp(&ty, &format!("duck_arr_new({ops}, 0)"));
                }
                let mut parts = Vec::new();
                for x in xs {
                    let v = self.expr(x);
                    let c = self.val_as(&v, &et);
                    parts.push(c);
                }
                let ct = self.g.ct(&et);
                self.tmp(&ty, &format!("duck_arr_from({ops}, ({ct}[]){{{}}}, {})", parts.join(", "), xs.len()))
            }
            K::Map(es) => {
                let ty = self.ty(e.id);
                let Ty::Map(kt, vt) = &ty else { return Val::unit() };
                let (kt, vt) = ((**kt).clone(), (**vt).clone());
                let (ko, vo) = (self.g.ops(&kt), self.g.ops(&vt));
                let m = self.tmp(&ty, &format!("duck_map_new({ko}, {vo})"));
                for (k, v) in es {
                    let kv = self.expr(k);
                    let kc = self.lvalue(&kv, &kt);
                    let vv = self.expr(v);
                    let vc = self.lvalue(&vv, &vt);
                    self.line(format!("duck_map_set(&{}, &{kc}, &{vc});", m.c));
                }
                m
            }
            K::Tuple(xs) => {
                if xs.is_empty() {
                    return Val::unit();
                }
                let ty = self.ty(e.id);
                let Ty::Tuple(ts) = &ty else { return Val::never() };
                let ts = ts.clone();
                let vals: Vec<Val> = xs.iter().map(|x| self.expr(x)).collect();
                let mut parts = Vec::new();
                for (v, t) in vals.into_iter().zip(&ts) {
                    parts.push(self.own_as(v, t));
                }
                let ct = self.g.ct(&ty);
                self.tmp(&ty, &format!("(({ct}){{{}}})", parts.join(", ")))
            }
        }
    }

    fn lit(&mut self, l: &Lit, neg: bool) -> Val {
        match l {
            Lit::Int(n) => {
                let c = if neg {
                    if *n == 1u64 << 63 { "INT64_MIN".to_string() } else { format!("INT64_C(-{n})") }
                } else {
                    format!("INT64_C({n})")
                };
                Val::plain(c, Ty::Int)
            }
            Lit::Float(x) => {
                let x = if neg { -x } else { *x };
                let mut s = format!("{x:?}");
                if !s.contains('.') && !s.contains('e') && !s.contains("inf") && !s.contains("NaN") {
                    s.push_str(".0");
                }
                Val::plain(format!("({s})"), Ty::Float)
            }
            Lit::Bool(b) => Val::plain(if *b { "true" } else { "false" }, Ty::Bool),
            Lit::Char(c) => Val::plain(format!("UINT32_C({})", *c as u32), Ty::Char),
            Lit::Str(s) => {
                let g = self.g.lit(s);
                Val::plain(g, Ty::Str)
            }
        }
    }

    fn name_ref(&mut self, e: &Expr) -> Val {
        let Some(n) = self.t.names.get(&e.id).cloned() else {
            return Val::never();
        };
        match n {
            NameRef::Local(l) => {
                if let Some(s) = self.f.locals.get(&l) {
                    return Val::plain(s.c.clone(), s.ty.clone());
                }
                // a local we never bound (unreachable code): a zero
                let ty = self.local_ty(l);
                let z = self.g.zero(&ty);
                Val::plain(z, ty)
            }
            NameRef::Const(c) => {
                let g = self.g.const_getter(c);
                let ty = self.tp.consts[c].ty.clone();
                Val::plain(format!("{g}()"), ty)
            }
            NameRef::Fn { func, .. } => {
                let ty = self.ty(e.id);
                let target = self.tp.instances[self.inst].resolved.get(&e.id).cloned();
                let Some(target) = target else { return Val::never() };
                let w = self.fn_value(&target, Some(func), &ty);
                Val::plain(format!("((DuckClosure){{(void *){w}, NULL}})"), ty)
            }
            NameRef::Variant(v) => {
                let ty = self.ty(e.id);
                match &ty {
                    Ty::Fn(_, r) => {
                        let target = Target::Variant { def: v.def, index: v.index };
                        let _ = r;
                        let w = self.fn_value(&target, None, &ty);
                        Val::plain(format!("((DuckClosure){{(void *){w}, NULL}})"), ty)
                    }
                    _ => {
                        let c = self.g.variant_new(&ty, v.index, &[]);
                        Val::plain(c, ty)
                    }
                }
            }
            NameRef::None => {
                let ty = self.ty(e.id);
                let z = self.g.zero(&ty);
                Val::plain(z, ty)
            }
        }
    }

    // ---- calls ----

    fn call(&mut self, e: &Expr, first: Option<Val>, tail: bool) -> Val {
        if let Some(k) = self.t.fails.get(&e.id).cloned() {
            return self.fail(e, &k);
        }
        if let K::Call { callee, args } = &e.kind
            && let K::Name(n) = &callee.kind
            && n == "old"
            && args.len() == 1
            && let Some(v) = self.f.olds.get(&args[0].id).cloned()
        {
            let ty = self.ty(args[0].id);
            return Val::plain(v, ty);
        }
        let Some(call) = self.t.calls.get(&e.id) else {
            return Val::never();
        };
        let target = self.tp.instances[self.inst].resolved.get(&e.id).cloned();
        let Some(target) = target else {
            panic!("codegen: unresolved call at {}:{}:{}", self.file, e.span.line, e.span.col);
        };
        if tail && self.f.tail.is_some() && first.is_none() && self.is_self_tail_call(e) {
            return self.tail_call(e);
        }
        let exprs = arg_exprs(e);
        // the closure value is evaluated before its arguments
        let callee_val = if let Target::Closure = target {
            let cx = match &e.kind {
                K::Call { callee, .. } | K::Pipe { callee, .. } => Some(&**callee),
                _ => None,
            };
            cx.map(|c| self.expr(c))
        } else {
            None
        };
        let any_ref = call.args.iter().any(|a| a.by_ref);
        let mut first = first;
        let mut args = Vec::new();
        for (k, a) in call.args.iter().enumerate() {
            if k == 0
                && let Some(v) = first.take()
            {
                args.push(ArgV::Val(v));
                continue;
            }
            let Some(x) = exprs.iter().find(|x| x.id == a.node).copied() else {
                panic!("codegen: missing argument node at {}:{}:{}", self.file, e.span.line, e.span.col);
            };
            if a.by_ref {
                let inner = if let K::Ref(i) = &x.kind { &**i } else { x };
                let (lv, ty) = self.place(inner);
                args.push(ArgV::Addr(format!("&{lv}"), ty));
            } else {
                let mut v = self.expr(x);
                if any_ref && !v.owned && !is_ident(&v.c) {
                    let ty = v.ty.clone();
                    let c = self.val_as(&v, &ty);
                    let n = self.decl(&ty, &c);
                    v = Val { c: n, ty, owned: false };
                }
                args.push(ArgV::Val(v));
            }
        }
        let func = match &call.callee {
            Callee::Fn { func, .. } => Some(*func),
            _ => None,
        };
        let mut ret = self.ty(e.id);
        // `x?.m()`: the node's type is the chain's `T?`; the call itself returns the member
        if let K::OptChain { .. } = e.kind
            && !self.t.opt_chains.get(&e.id).is_some_and(|o| o.flatten)
            && let Ty::Opt(m) = ret
        {
            ret = *m;
        }
        let loc = self.loc(e.span);
        // an un-awaited async call: spawn a task
        if let (Target::Instance(i), Ty::Task(_)) = (&target, &ret) {
            return self.spawn(*i, args, &ret);
        }
        self.call_target(&target, func, args, &ret, &loc, callee_val)
    }

    /// Call a resolved target with evaluated arguments; returns the (owned) result.
    fn call_target(&mut self, target: &Target, func: Option<FnId>, args: Vec<ArgV>, ret: &Ty, loc: &str, callee: Option<Val>) -> Val {
        let tp = self.tp;
        match target {
            Target::Instance(i) => {
                let f = self.g.inst_fn(*i);
                let ps = self.g.inst_params(*i);
                let rt = self.g.inst_ret(*i);
                let mut cs = Vec::new();
                for (a, (pt, _)) in args.iter().zip(&ps) {
                    cs.push(match a {
                        ArgV::Val(v) => self.val_as(v, pt),
                        ArgV::Addr(p, _) => p.clone(),
                    });
                }
                let call = format!("{f}({})", cs.join(", "));
                if let BodyRef::Fn(fid) = tp.instances[*i].body
                    && self.g.traced(tp.fns[fid].module)
                {
                    self.line(format!("duck_trace_site = {loc};"));
                }
                self.result(&rt, &call)
            }
            Target::Extern { symbol, loc: wants_loc } => {
                let info = func.map(|f| &tp.fns[f]);
                let mut cs = Vec::new();
                for (k, a) in args.iter().enumerate() {
                    let gp = info.map(|i| &i.params[k]);
                    let generic = gp.is_some_and(|p| matches!(p.ty, Ty::Param(_)));
                    cs.push(match a {
                        ArgV::Addr(p, ty) => {
                            if matches!(ty, Ty::List(_) | Ty::Map(..)) {
                                p.clone()
                            } else {
                                format!("(*{p})")
                            }
                        }
                        ArgV::Val(v) => {
                            if generic {
                                let ty = v.ty.clone();
                                let lv = self.lvalue(v, &ty);
                                format!("&{lv}")
                            } else {
                                let ty = v.ty.clone();
                                self.val_as(v, &ty)
                            }
                        }
                    });
                }
                let gret = info.map(|i| i.ret.clone()).unwrap_or_else(|| ret.clone());
                let out_ty = match (&gret, ret) {
                    (Ty::Opt(g), Ty::Opt(c)) if matches!(**g, Ty::Param(_)) => Some((**c).clone()),
                    (Ty::Param(_), c) => Some(c.clone()),
                    _ => None,
                };
                match out_ty {
                    Some(ot) => {
                        let z = self.g.zero(&ot);
                        let out = self.decl(&ot, &z);
                        cs.push(format!("&{out}"));
                        if *wants_loc {
                            cs.push(loc.to_string());
                        }
                        let call = format!("{symbol}({})", cs.join(", "));
                        if let Ty::Opt(_) = ret {
                            let ok = self.decl(&Ty::Bool, &call);
                            let ct = self.g.ct(ret);
                            self.tmp(ret, &format!("(({ct}){{.some = {ok}, .val = {out}}})"))
                        } else {
                            self.line(format!("{call};"));
                            self.reown(out, ot)
                        }
                    }
                    None => {
                        if *wants_loc {
                            cs.push(loc.to_string());
                        }
                        let call = format!("{symbol}({})", cs.join(", "));
                        if *ret == Ty::Never {
                            // `proc.exit` doesn't return: release what this function owns first,
                            // as a `return` would (its argument is an int, already evaluated), so
                            // the leak check it runs is exact when called from `main`.
                            self.cleanup_from(0);
                        }
                        if ret.is_unit() && gret.is_unit() {
                            self.line(format!("{call};"));
                            Val::unit()
                        } else {
                            self.result(ret, &call)
                        }
                    }
                }
            }
            Target::Intrinsic { which, ty } => self.intrinsic(*which, ty, args, ret),
            Target::Derived { shape, ty } => {
                let which = match shape {
                    Builtin::Show => Intrinsic::Show,
                    Builtin::Eq => Intrinsic::Eq,
                    Builtin::Ord => Intrinsic::Cmp,
                    Builtin::Data => Intrinsic::ToValue,
                };
                self.intrinsic(which, ty, args, ret)
            }
            Target::Vtable { shape, method } => {
                let vt = self.g.vt_struct(*shape);
                let mut it = args.into_iter();
                let Some(ArgV::Val(recv)) = it.next() else { return Val::never() };
                let sh = &tp.defs.shapes[*shape];
                let m = &sh.methods[*method];
                let mut cs = vec![format!("({}).obj", recv.c)];
                for (a, pt) in it.zip(m.params.iter().skip(1)) {
                    let pt = self.g.method_ty(pt, *shape);
                    cs.push(match a {
                        ArgV::Val(v) => self.val_as(&v, &pt),
                        ArgV::Addr(p, _) => p,
                    });
                }
                let call = format!("((const {vt} *)({}).vt)->m{method}({})", recv.c, cs.join(", "));
                let rt = self.g.method_ty(&m.ret, *shape);
                self.result(&rt, &call)
            }
            Target::Variant { index, .. } => {
                let mut fields = Vec::new();
                let layout = self.g.enum_layout(ret);
                for (k, a) in args.into_iter().enumerate() {
                    let ft = if self.g.is_value(ret) {
                        a_ty(&a)
                    } else {
                        layout.get(*index).and_then(|l| l.get(k)).map(|x| x.0.clone()).unwrap_or_else(|| a_ty(&a))
                    };
                    match a {
                        ArgV::Val(v) => fields.push(self.own_as(v, &ft)),
                        ArgV::Addr(p, _) => fields.push(format!("(*{p})")),
                    }
                }
                let c = self.g.variant_new(ret, *index, &fields);
                self.tmp(ret, &c)
            }
            Target::Closure => {
                let Some(c) = callee else { return Val::never() };
                let Ty::Fn(ps, r) = c.ty.clone() else { return Val::never() };
                let rc = self.g.ct(&r);
                let mut pcs = vec!["DuckEnv *".to_string()];
                let mut cs = vec![format!("({}).env", c.c)];
                for (a, pt) in args.iter().zip(&ps) {
                    pcs.push(self.g.ct(pt));
                    cs.push(match a {
                        ArgV::Val(v) => self.val_as(v, pt),
                        ArgV::Addr(p, _) => p.clone(),
                    });
                }
                let call = format!("(({rc} (*)({}))({}).fn)({})", pcs.join(", "), c.c, cs.join(", "));
                self.result(&r, &call)
            }
        }
    }

    /// The owned result of a C call expression of Duck type `ty`.
    fn result(&mut self, ty: &Ty, call: &str) -> Val {
        if ty.is_unit() {
            self.line(format!("{call};"));
            return Val::unit();
        }
        if *ty == Ty::Never {
            self.line(format!("{call};"));
            return Val::never();
        }
        self.tmp(ty, call)
    }

    fn intrinsic(&mut self, which: Intrinsic, ty: &Ty, args: Vec<ArgV>, ret: &Ty) -> Val {
        let vals: Vec<Val> = args
            .into_iter()
            .map(|a| match a {
                ArgV::Val(v) => v,
                ArgV::Addr(p, t) => Val::plain(format!("(*{p})"), t),
            })
            .collect();
        match which {
            Intrinsic::Show => {
                let v = &vals[0];
                let s = self.show_value(ty, v);
                self.adopt(&Ty::Str, &s)
            }
            Intrinsic::Eq => {
                let (a, b) = (self.val_as(&vals[0], ty), self.val_as(&vals[1], ty));
                let c = self.g.eq_expr(ty, &a, &b);
                self.tmp(&Ty::Bool, &c)
            }
            Intrinsic::Cmp => {
                let (a, b) = (self.val_as(&vals[0], ty), self.val_as(&vals[1], ty));
                let c = self.g.cmp_expr(ty, &a, &b);
                self.tmp(&Ty::Int, &c)
            }
            Intrinsic::ToValue => {
                let f = self.g.tov_fn(ty);
                let a = self.val_as(&vals[0], ty);
                self.adopt(ret, &format!("{f}({a})"))
            }
            Intrinsic::FromValue => {
                let t = match ret {
                    Ty::Res(t, _) => (**t).clone(),
                    t => t.clone(),
                };
                let f = self.g.fromv_fn(&t);
                let a = vals[0].c.clone();
                self.adopt(ret, &format!("{f}({a})"))
            }
            Intrinsic::Some => {
                let it = match ret {
                    Ty::Opt(t) => (**t).clone(),
                    t => t.clone(),
                };
                let o = self.own_as(vals[0].clone(), &it);
                let ct = self.g.ct(ret);
                self.tmp(ret, &format!("(({ct}){{.some = true, .val = {o}}})"))
            }
            Intrinsic::IntToFloat => self.tmp(&Ty::Float, &format!("(double)({})", vals[0].c)),
            Intrinsic::CharToInt => self.tmp(&Ty::Int, &format!("(int64_t)({})", vals[0].c)),
            Intrinsic::Fail => Val::never(),
        }
    }

    /// `Show` text (owned C expression) of a value of type `ty`, top-level form.
    fn show_value(&mut self, ty: &Ty, v: &Val) -> String {
        let a = self.val_as(v, ty);
        match self.g.show_fn(ty) {
            Some(f) => format!("{f}({a})"),
            None => format!("duck_str_lit({})", c_str(&format!("<{}>", self.g.show_ty(ty)))),
        }
    }

    /// The show of an interpolation part / peek operand (via `Instance::shows`).
    fn show_of(&mut self, node: u32, v: &Val) -> String {
        let target = self.tp.instances[self.inst].shows.get(&node).cloned();
        let a = v.c.clone();
        match target {
            Some(Target::Instance(i)) => {
                let f = self.g.inst_fn(i);
                format!("{f}({a})")
            }
            Some(Target::Extern { symbol, .. }) => format!("{symbol}({a})"),
            _ => {
                let ty = v.ty.clone();
                self.show_value(&ty, v)
            }
        }
    }

    fn spawn(&mut self, i: InstId, args: Vec<ArgV>, ret: &Ty) -> Val {
        let ps = self.g.inst_params(i);
        let rt = self.g.inst_ret(i);
        let (thunk, argty) = self.thunk(i);
        let mut fields = Vec::new();
        for (a, (pt, _)) in args.into_iter().zip(&ps) {
            fields.push(match a {
                ArgV::Val(v) => self.own_as(v, pt),
                ArgV::Addr(p, _) => p,
            });
        }
        let a = self.name("args");
        if fields.is_empty() {
            self.line(format!("{argty} {a} = {{0}};"));
        } else {
            self.line(format!("{argty} {a} = {{{}}};", fields.join(", ")));
        }
        let rc = self.g.ct(&rt);
        let ops = if self.g.needs_rc(&rt) { self.g.ops(&rt) } else { "NULL".into() };
        self.tmp(ret, &format!("duck_task_spawn({thunk}, &{a}, sizeof {a}, sizeof({rc}), {ops})"))
    }

    /// The thunk that runs instance `i` on a task thread: (thunk name, argument struct type).
    fn thunk(&mut self, i: InstId) -> (String, String) {
        let key = format!("thunk{i}");
        if let Some(n) = self.g.memo2.get(&key) {
            return (n.clone(), format!("{n}_args"));
        }
        let n = format!("dk_thunk{i}");
        self.g.memo2.insert(key, n.clone());
        let ps = self.g.inst_params(i);
        let rt = self.g.inst_ret(i);
        let f = self.g.inst_fn(i);
        let mut st = String::new();
        let mut call = Vec::new();
        let mut rels = String::new();
        for (k, (pt, var)) in ps.iter().enumerate() {
            let c = self.g.ct(pt);
            if *var {
                let _ = writeln!(st, "    {c} *a{k};");
            } else {
                let _ = writeln!(st, "    {c} a{k};");
                if let Some(r) = self.g.release(pt, &format!("x->a{k}")) {
                    rels.push_str("    ");
                    rels.push_str(&r);
                    rels.push('\n');
                }
            }
            call.push(format!("x->a{k}"));
        }
        if st.is_empty() {
            st.push_str("    int dummy;\n");
        }
        let rc = self.g.ct(&rt);
        let _ = writeln!(self.g.types, "typedef struct {n}_args {{\n{st}}} {n}_args;");
        let _ = writeln!(self.g.protos, "static void {n}(void *args, void *result);");
        let _ = writeln!(
            self.g.funcs,
            "static void {n}(void *args, void *result) {{\n    {n}_args *x = args;\n    (void)x;\n    *({rc} *)result = {f}({});\n{rels}}}\n",
            call.join(", ")
        );
        (n.clone(), format!("{n}_args"))
    }

    /// A C function usable as a closure (`R f(DuckEnv *, args...)`) that calls `target`.
    fn fn_value(&mut self, target: &Target, func: Option<FnId>, fty: &Ty) -> String {
        let key = format!("fv{target:?}/{fty:?}");
        if let Some(n) = self.g.memo2.get(&key) {
            return n.clone();
        }
        let n = format!("dk_fv{}", self.g.fresh());
        self.g.memo2.insert(key, n.clone());
        let Ty::Fn(ps, r) = fty.clone() else { return n };
        let r = *r;
        let rc = self.g.ct(&r);
        let mut pdecl = vec!["DuckEnv *env".to_string()];
        for (k, p) in ps.iter().enumerate() {
            let c = self.g.ct(p);
            pdecl.push(format!("{c} a{k}"));
        }
        let sig = format!("static {rc} {n}({})", pdecl.join(", "));
        self.begin(r.clone());
        self.push(ScopeKind::Block);
        self.line("(void)env;");
        let args = ps.iter().enumerate().map(|(k, p)| ArgV::Val(Val::plain(format!("a{k}"), p.clone()))).collect();
        let v = self.call_target(target, func, args, &r, "\"<fn>\"", None);
        if r.is_unit() || r == Ty::Never {
            self.cleanup_from(0);
            self.line("return 0;");
        } else {
            self.ret_val(v, &r);
        }
        let st = self.end();
        let _ = writeln!(self.g.protos, "{sig};");
        let _ = writeln!(self.g.funcs, "{sig} {{\n{}}}\n", st.out);
        n
    }

    /// The vtable of a conversion to `any S` (by vtable id); returns `&name`.
    fn vtable(&mut self, vid: usize) -> String {
        let key = format!("vt{vid}");
        if let Some(n) = self.g.memo2.get(&key) {
            return format!("&{n}");
        }
        let n = format!("dk_vt{vid}");
        self.g.memo2.insert(key, n.clone());
        let vt = self.tp.vtables[vid].clone();
        let st = self.g.vt_struct(vt.shape);
        let sh = self.tp.defs.shapes[vt.shape].clone();
        let mut ms = Vec::new();
        for (k, (m, target)) in sh.methods.iter().zip(&vt.methods).enumerate() {
            let mn = format!("{n}_m{k}");
            let r = self.g.method_ty(&m.ret, vt.shape);
            let rc = self.g.ct(&r);
            let mut pdecl = vec!["DuckObj *self".to_string()];
            let mut args = Vec::new();
            let bt = self.g.box_ty(&vt.ty);
            args.push(ArgV::Val(Val::plain(format!("(({bt} *)self)->v"), vt.ty.clone())));
            for (j, p) in m.params.iter().enumerate().skip(1) {
                let pt = self.g.method_ty(p, vt.shape);
                let c = self.g.ct(&pt);
                pdecl.push(format!("{c} a{j}"));
                args.push(ArgV::Val(Val::plain(format!("a{j}"), pt)));
            }
            let sig = format!("static {rc} {mn}({})", pdecl.join(", "));
            self.begin(r.clone());
            self.push(ScopeKind::Block);
            let func = match target {
                Target::Instance(i) => match self.tp.instances[*i].body {
                    BodyRef::Fn(f) => Some(f),
                    _ => None,
                },
                _ => None,
            };
            let v = self.call_target(target, func, args, &r, "\"<vtable>\"", None);
            if r.is_unit() {
                self.cleanup_from(0);
                self.line("return 0;");
            } else {
                self.ret_val(v, &r);
            }
            let s = self.end();
            let _ = writeln!(self.g.protos, "{sig};");
            let _ = writeln!(self.g.funcs, "{sig} {{\n{}}}\n", s.out);
            ms.push(mn);
        }
        let _ = writeln!(self.g.ops_defs, "static const {st} {n} = {{{}}};", if ms.is_empty() { "0".to_string() } else { ms.join(", ") });
        format!("&{n}")
    }

    fn fail(&mut self, e: &Expr, kind: &FailKind) -> Val {
        let x = match &e.kind {
            K::Call { args, .. } => args.first(),
            K::MethodCall { recv, .. } => Some(&**recv),
            K::Pipe { lhs, .. } => Some(&**lhs),
            _ => None,
        };
        let Some(x) = x else { return Val::never() };
        let v = self.expr(x);
        let err = match kind {
            FailKind::Message => format!("duck_err_new({})", v.c),
            FailKind::Err => self.own(v),
            FailKind::Typed | FailKind::TypedToErr(_) => {
                let ty = v.ty.clone();
                let lv = self.lvalue(&v, &ty);
                let id = self.g.type_id(&ty);
                let ops = self.g.ops(&ty);
                format!("duck_err_typed({id}, &{lv}, {ops}, NULL)")
            }
        };
        let en = self.decl(&self.g.err_ty(), &err);
        self.return_err(&en);
        Val::never()
    }

    /// Return an owned `DuckErr *` from the current (fallible) function.
    fn return_err(&mut self, err: &str) {
        let ret = self.f.ret.clone();
        let rc = self.g.ct(&ret);
        self.cleanup_from(0);
        match ret {
            Ty::Res(..) => self.line(format!("return DUCK_ERR({rc}, {err});")),
            _ => {
                self.line(format!("duck_release({err});"));
                let z = self.g.zero(&ret);
                self.line(format!("return {z};"));
            }
        }
    }

    // ---- operators ----

    fn binary(&mut self, e: &Expr, op: BinOp, l: &Expr, r: &Expr) -> Val {
        use BinOp::*;
        match op {
            And | Or => {
                let lv = self.expr(l);
                let lc = self.val_as(&lv, &Ty::Bool);
                let res = self.decl(&Ty::Bool, &lc);
                self.open(if op == And { format!("if ({res}) {{") } else { format!("if (!{res}) {{") });
                self.push(ScopeKind::Block);
                let rv = self.expr(r);
                let rc = self.val_as(&rv, &Ty::Bool);
                self.line(format!("{res} = {rc};"));
                self.pop();
                self.close("}");
                return Val::plain(res, Ty::Bool);
            }
            Eq | Ne | Lt | Le | Gt | Ge => {
                let lv = self.expr(l);
                let rv = self.expr(r);
                let c = self.compare(e, op, &lv, &rv);
                return self.tmp(&Ty::Bool, &c);
            }
            _ => {}
        }
        if self.t.calls.contains_key(&e.id) {
            return self.call(e, None, false);
        }
        let lv = self.expr(l);
        let rv = self.expr(r);
        if lv.is_never() || rv.is_never() {
            return Val::never();
        }
        let loc = self.loc(e.span);
        let (a, b) = (lv.c.clone(), rv.c.clone());
        match lv.ty.clone() {
            Ty::Int => self.tmp(&Ty::Int, &int_op(op, &a, &b, &loc)),
            Ty::Float => {
                let c = match op {
                    Add => format!("({a} + {b})"),
                    Sub => format!("({a} - {b})"),
                    Mul => format!("({a} * {b})"),
                    Div => format!("({a} / {b})"),
                    Rem => format!("duck_fmod({a}, {b})"),
                    Pow => format!("duck_fpow({a}, {b})"),
                    _ => "0.0".into(),
                };
                self.tmp(&Ty::Float, &c)
            }
            Ty::Str => self.tmp(&Ty::Str, &format!("duck_str_concat({a}, {b})")),
            t @ Ty::List(_) => self.tmp(&t, &format!("duck_arr_concat({a}, {b})")),
            _ => Val::never(),
        }
    }

    /// A C boolean expression for a comparison of two lowered operands.
    fn compare(&mut self, e: &Expr, op: BinOp, l: &Val, r: &Val) -> String {
        use BinOp::*;
        let sym = op.symbol();
        if self.t.calls.contains_key(&e.id) {
            let target = self.tp.instances[self.inst].resolved.get(&e.id).cloned();
            let ty = l.ty.clone();
            let (a, b) = (self.val_as(l, &ty), self.val_as(r, &ty));
            let is_eq = matches!(op, Eq | Ne);
            let raw = match target {
                Some(Target::Instance(i)) => {
                    let f = self.g.inst_fn(i);
                    format!("{f}({a}, {b})")
                }
                Some(Target::Extern { symbol, .. }) => format!("{symbol}({a}, {b})"),
                Some(Target::Intrinsic { ty, .. }) | Some(Target::Derived { ty, .. }) => {
                    if is_eq {
                        self.g.eq_expr(&ty, &a, &b)
                    } else {
                        self.g.cmp_expr(&ty, &a, &b)
                    }
                }
                _ => {
                    if is_eq {
                        self.g.eq_expr(&ty, &a, &b)
                    } else {
                        self.g.cmp_expr(&ty, &a, &b)
                    }
                }
            };
            return match op {
                Eq => raw,
                Ne => format!("!({raw})"),
                _ => format!("(({raw}) {sym} 0)"),
            };
        }
        let ty = if l.is_never() { r.ty.clone() } else { l.ty.clone() };
        let (a, b) = (self.val_as(l, &ty), self.val_as(r, &ty));
        match ty {
            Ty::Int | Ty::Float | Ty::Char | Ty::Bool => format!("({a} {sym} {b})"),
            Ty::Str => match op {
                Eq => format!("duck_str_eq({a}, {b})"),
                Ne => format!("!duck_str_eq({a}, {b})"),
                _ => format!("(duck_str_cmp({a}, {b}) {sym} 0)"),
            },
            Ty::Never => "false".into(),
            Ty::Tuple(ts) if ts.is_empty() => if matches!(op, Eq | Le | Ge) { "true".into() } else { "false".into() },
            t => {
                let eq = matches!(op, Eq | Ne);
                let raw = if eq { self.g.eq_expr(&t, &a, &b) } else { self.g.cmp_expr(&t, &a, &b) };
                match op {
                    Eq => raw,
                    Ne => format!("!({raw})"),
                    _ => format!("(({raw}) {sym} 0)"),
                }
            }
        }
    }

    fn index(&mut self, e: &Expr, x: &Expr, i: &Expr) -> Val {
        let xv = self.expr(x);
        let iv = self.expr(i);
        let loc = self.loc(e.span);
        let ty = self.ty(e.id);
        match xv.ty.clone() {
            Ty::List(et) => {
                let ct = self.g.ct(&et);
                let el = format!("DUCK_ARR_AT({ct}, {}, {}, {loc})", xv.c, iv.c);
                let v = Val::plain(el, (*et).clone());
                let o = self.own(v);
                self.adopt(&et, &o)
            }
            Ty::Map(kt, vt) => {
                let k = self.lvalue(&iv, &kt);
                let ct = self.g.ct(&vt);
                let v = Val::plain(format!("(*({ct} *)duck_map_at({}, &{k}, {loc}))", xv.c), (*vt).clone());
                let o = self.own(v);
                self.adopt(&vt, &o)
            }
            Ty::Str => self.tmp(&Ty::Char, &format!("duck_str_char_at({}, {}, {loc})", xv.c, iv.c)),
            _ => {
                let _ = ty;
                Val::never()
            }
        }
    }

    // ---- places ----

    /// The C lvalue of a place expression (making containers on the path unique), and its type.
    fn place(&mut self, e: &Expr) -> (String, Ty) {
        match &e.kind {
            K::Name(_) => {
                if let Some(NameRef::Local(l)) = self.t.names.get(&e.id)
                    && let Some(s) = self.f.locals.get(l)
                {
                    return (s.c.clone(), s.ty.clone());
                }
                self.place_tmp(e)
            }
            K::Field { expr, name } => {
                let (b, bt) = self.place(expr);
                self.place_field(e, &b, &bt, &name.name)
            }
            K::TupleField { expr, index } => {
                let (b, bt) = self.place(expr);
                let ft = match &bt {
                    Ty::Tuple(ts) => ts.get(*index as usize).cloned().unwrap_or(Ty::unit()),
                    _ => self.ty(e.id),
                };
                (format!("{b}.f{index}"), ft)
            }
            K::Index { expr, index } => {
                let (b, bt) = self.place(expr);
                let loc = self.loc(e.span);
                match bt {
                    Ty::List(et) => {
                        let iv = self.expr(index);
                        let ic = self.val_as(&iv, &Ty::Int);
                        let i = self.decl(&Ty::Int, &ic);
                        self.line(format!("duck_arr_make_unique(&{b});"));
                        let ct = self.g.ct(&et);
                        (format!("DUCK_ARR_AT({ct}, {b}, {i}, {loc})"), *et)
                    }
                    Ty::Map(kt, vt) => {
                        let kv = self.expr(index);
                        let k = self.lvalue(&kv, &kt);
                        self.line(format!("duck_map_make_unique(&{b});"));
                        let ct = self.g.ct(&vt);
                        (format!("(*({ct} *)duck_map_at({b}, &{k}, {loc}))"), *vt)
                    }
                    _ => self.place_tmp(e),
                }
            }
            _ => self.place_tmp(e),
        }
    }

    /// The place of field `name` of the struct place `b` (of type `bt`), for writing.
    fn place_field(&mut self, e: &Expr, b: &str, bt: &Ty, name: &str) -> (String, Ty) {
        let ft = match bt {
            Ty::Named(d, args) if self.tp.defs.is_struct(*d) => {
                let s = self.tp.defs.subst_of(*d, args);
                self.tp.defs.fields(*d).iter().find(|f| f.name == name).map(|f| f.ty.subst(&s)).unwrap_or(Ty::unit())
            }
            _ => self.ty(e.id),
        };
        match self.field_index(bt, name) {
            Some(i) => {
                // a boxed (recursive) field's box may be shared with copies of this struct:
                // make it unique before writing through it (copy-on-write)
                let (raw, boxed) = self.g.field_raw(bt, i, b);
                if boxed {
                    let f = self.g.box_unique(&ft);
                    self.line(format!("{f}(&{raw});"));
                }
                (self.g.field_get(bt, i, b), ft)
            }
            None => (format!("{b}.f_{}", super::cgen::sanitize(name)), ft),
        }
    }

    fn place_tmp(&mut self, e: &Expr) -> (String, Ty) {
        let v = self.expr(e);
        let ty = v.ty.clone();
        let o = self.own_as(v, &ty);
        let n = self.decl(&ty, &o);
        self.register(&n, &ty);
        (n, ty)
    }

    fn assign(&mut self, e: &Expr, op: Option<BinOp>, target: &Expr, value: &Expr) {
        if op.is_some() && self.t.calls.contains_key(&e.id) {
            // a user operator: target = op(target, value)
            let v = self.call(e, None, false);
            let (lv, ty) = self.place(target);
            let o = self.own_as(v, &ty);
            let old = self.decl(&ty, &lv);
            self.line(format!("{lv} = {o};"));
            if let Some(r) = self.g.release(&ty, &old) {
                self.line(r);
            }
            return;
        }
        let v = self.expr(value);
        if v.is_never() {
            return;
        }
        match op {
            None => {
                // `m[k] = v` inserts
                if let K::Index { expr, index } = &target.kind {
                    let (b, bt) = self.place(expr);
                    if let Ty::Map(kt, vt) = bt {
                        let kv = self.expr(index);
                        let k = self.lvalue(&kv, &kt);
                        let vc = self.lvalue(&v, &vt);
                        self.line(format!("duck_map_set(&{b}, &{k}, &{vc});"));
                        return;
                    }
                    if let Ty::List(et) = bt {
                        let iv = self.expr(index);
                        let vc = self.lvalue(&v, &et);
                        let loc = self.loc(target.span);
                        self.line(format!("duck_arr_set(&{b}, {}, &{vc}, {loc});", iv.c));
                        return;
                    }
                }
                let (lv, lty) = match &target.kind {
                    K::Field { expr, name } if !self.t.names.contains_key(&target.id) => {
                        let (b, bt) = self.place(expr);
                        // a boxed (recursive) struct field gets a fresh box
                        if let Some(i) = self.field_index(&bt, &name.name)
                            && self.g.field_raw(&bt, i, &b).1
                        {
                            let ft = self.g.struct_layout(&bt)[i].1.clone();
                            let o = self.own_as(v, &ft);
                            let put = self.g.field_put(&bt, i, &o);
                            let (raw, _) = self.g.field_raw(&bt, i, &b);
                            let old = self.decl(&Ty::Str, &format!("(DuckStr *){raw}"));
                            self.line(format!("{raw} = {put};"));
                            self.line(format!("duck_release({old});"));
                            return;
                        }
                        self.place_field(target, &b, &bt, &name.name)
                    }
                    _ => self.place(target),
                };
                let ty = v.ty.clone();
                let o = self.own_as(v, &ty);
                let nv = self.decl(&ty, &o);
                if self.g.needs_rc(&lty) {
                    let old = self.decl(&lty, &lv);
                    self.line(format!("{lv} = {nv};"));
                    if let Some(r) = self.g.release(&lty, &old) {
                        self.line(r);
                    }
                } else {
                    self.line(format!("{lv} = {nv};"));
                }
            }
            Some(op) => {
                let rc = v.c.clone();
                let (lv, lty) = self.place(target);
                let loc = self.loc(e.span);
                match lty {
                    Ty::Int => self.line(format!("{lv} = {};", int_op(op, &lv, &rc, &loc))),
                    Ty::Float => {
                        let c = match op {
                            BinOp::Add => format!("{lv} + {rc}"),
                            BinOp::Sub => format!("{lv} - {rc}"),
                            BinOp::Mul => format!("{lv} * {rc}"),
                            BinOp::Div => format!("{lv} / {rc}"),
                            _ => format!("duck_fmod({lv}, {rc})"),
                        };
                        self.line(format!("{lv} = {c};"));
                    }
                    Ty::Str => {
                        let n = self.decl(&Ty::Str, &format!("duck_str_concat({lv}, {rc})"));
                        self.line(format!("duck_release({lv});"));
                        self.line(format!("{lv} = {n};"));
                    }
                    Ty::List(_) => self.line(format!("duck_arr_extend(&{lv}, {rc});")),
                    _ => {}
                }
            }
        }
    }

    // ---- ?, else, ?., await ----

    fn try_(&mut self, e: &Expr, x: &Expr) -> Val {
        let info = self.t.tries[&e.id].clone();
        let v = self.expr(x);
        if v.is_never() {
            return v;
        }
        let ty = self.ty(e.id);
        match info.kind {
            TryKind::Result => {
                let w = self.hold(v);
                self.open(format!("if (!{w}.ok) {{"));
                self.return_err(&format!("{w}.err"));
                self.close("}");
                self.adopt(&ty, &format!("{w}.val"))
            }
            TryKind::Option => {
                let w = self.hold(v);
                self.open(format!("if (!{w}.some) {{"));
                self.return_none();
                self.close("}");
                self.adopt(&ty, &format!("{w}.val"))
            }
            TryKind::ListResult | TryKind::ListOption => {
                let Ty::List(el) = v.ty.clone() else { return Val::never() };
                let Ty::List(inner) = ty.clone() else { return Val::never() };
                let xs = self.hold(v);
                let ops = self.g.ops(&inner);
                let out = self.decl(&ty, &format!("duck_arr_new({ops}, duck_arr_len({xs}))"));
                let ect = self.g.ct(&el);
                let k = self.name("k");
                self.open(format!("for (int64_t {k} = 0; {k} < duck_arr_len({xs}); {k}++) {{"));
                let r = self.name("r");
                self.line(format!("{ect} *{r} = &(({ect} *){xs}->data)[{k}];"));
                if info.kind == TryKind::ListResult {
                    self.open(format!("if (!{r}->ok) {{"));
                    let en = self.decl(&self.g.err_ty(), &format!("duck_retain({r}->err)"));
                    self.line(format!("duck_release({out});"));
                    self.line(format!("duck_release({xs});"));
                    self.return_err(&en);
                    self.close("}");
                } else {
                    self.open(format!("if (!{r}->some) {{"));
                    self.line(format!("duck_release({out});"));
                    self.line(format!("duck_release({xs});"));
                    self.return_none();
                    self.close("}");
                }
                self.line(format!("duck_arr_push(&{out}, &{r}->val);"));
                self.close("}");
                self.line(format!("duck_release({xs});"));
                self.reown(out, ty)
            }
        }
    }

    fn return_none(&mut self) {
        let ret = self.f.ret.clone();
        self.cleanup_from(0);
        let z = self.g.zero(&ret);
        self.line(format!("return {z};"));
    }

    fn else_(&mut self, e: &Expr, x: &Expr, arm: &ElseArm) -> Val {
        let info = self.t.elses[&e.id].clone();
        let v = self.expr(x);
        let ty = self.ty(e.id);
        if v.is_never() {
            return v;
        }
        let wt = v.ty.clone();
        let w = self.hold(v);
        let r = self.zero_decl(&ty);
        let ok = if info.kind == ElseKind::Option { format!("{w}.some") } else { format!("{w}.ok") };
        self.open(format!("if ({ok}) {{"));
        self.line(format!("{r} = {w}.val;"));
        self.close("} else {");
        self.f.ind += 1;
        self.push(ScopeKind::Block);
        if info.kind != ElseKind::Option {
            self.bind_err(info.binder, &w, &wt);
        }
        let fb = self.expr(&arm.body);
        let o = self.own_as(fb, &ty);
        self.line(format!("{r} = {o};"));
        self.pop();
        self.close("}");
        self.reown(r, ty)
    }

    /// In the error branch of `w` (a held `T!`): bind `else e =>`'s binder or drop the error.
    fn bind_err(&mut self, binder: Option<LocalId>, w: &str, wt: &Ty) {
        match binder {
            Some(l) => {
                let lt = self.local_ty(l);
                let n = self.name("e");
                if self.g.is_err_ty(&lt) {
                    self.line(format!("DuckErr *{n} = {w}.err;"));
                } else {
                    let ct = self.g.ct(&lt);
                    let id = self.g.type_id(&lt);
                    let z = self.g.zero(&lt);
                    self.line(format!("{ct} {n} = {z};"));
                    self.line(format!("{{ const void *pl = duck_err_payload({w}.err, {id}); if (pl) {n} = *({ct} *)pl; }}"));
                    if let Some(r) = self.g.retain(&lt, &n) {
                        self.line(r);
                    }
                    self.line(format!("duck_release({w}.err);"));
                }
                self.register_local(&n, &lt);
                self.f.locals.insert(l, Slot { c: n, ty: lt });
            }
            None => {
                let _ = wt;
                self.line(format!("duck_release({w}.err);"));
            }
        }
    }

    fn opt_chain(&mut self, e: &Expr, x: &Expr, name: &super::ast::Ident, call: bool) -> Val {
        let flatten = self.t.opt_chains.get(&e.id).is_some_and(|o| o.flatten);
        let v = self.expr(x);
        if v.is_never() {
            return v;
        }
        let ty = self.ty(e.id);
        let Ty::Opt(inner) = v.ty.clone() else { return Val::never() };
        let xv = self.lvalue(&v, &v.ty.clone());
        let r = self.zero_decl(&ty);
        self.open(format!("if ({xv}.some) {{"));
        self.push(ScopeKind::Block);
        let iv = Val::plain(format!("{xv}.val"), (*inner).clone());
        let member = if call {
            self.call(e, Some(iv), false)
        } else {
            let ft = match &ty {
                Ty::Opt(t) if !flatten => (**t).clone(),
                t => t.clone(),
            };
            let c = match (name.tuple_index(), self.field_index(&inner, &name.name)) {
                (Some(index), _) => format!("{xv}.val.f{index}"),
                (None, Some(i)) => self.g.field_get(&inner, i, &format!("{xv}.val")),
                (None, None) => format!("{xv}.val.f_{}", super::cgen::sanitize(&name.name)),
            };
            Val::plain(c, ft)
        };
        if flatten {
            let o = self.own_as(member, &ty);
            self.line(format!("{r} = {o};"));
        } else if let Ty::Opt(mt) = &ty {
            let mt = (**mt).clone();
            let o = self.own_as(member, &mt);
            let ct = self.g.ct(&ty);
            self.line(format!("{r} = (({ct}){{.some = true, .val = {o}}});"));
        }
        self.pop();
        self.close("}");
        self.reown(r, ty)
    }

    fn await_(&mut self, e: &Expr, x: &Expr) -> Val {
        let kind = self.t.awaits.get(&e.id).copied().unwrap_or(AwaitKind::Direct);
        let ty = self.ty(e.id);
        match kind {
            AwaitKind::Direct => self.expr(x),
            AwaitKind::Task => {
                let t = self.expr(x);
                let r = self.zero_decl(&ty);
                self.line(format!("duck_task_await({}, &{r});", t.c));
                self.reown(r, ty)
            }
            AwaitKind::Tuple => {
                let tv = self.expr(x);
                let Ty::Tuple(ts) = tv.ty.clone() else { return Val::never() };
                let fields: Vec<String> = (0..ts.len()).map(|i| format!("({}).f{i}", tv.c)).collect();
                let arr = self.name("ts");
                self.line(format!("DuckTask *{arr}[] = {{{}}};", fields.join(", ")));
                self.line(format!("duck_task_join_all({arr}, {});", ts.len()));
                let r = self.zero_decl(&ty);
                for (i, f) in fields.iter().enumerate() {
                    self.line(format!("duck_task_await({f}, &{r}.f{i});"));
                }
                self.reown(r, ty)
            }
            AwaitKind::List => {
                let tv = self.expr(x);
                let Ty::List(inner) = ty.clone() else { return Val::never() };
                let ops = self.g.ops(&inner);
                let n = self.decl(&Ty::Int, &format!("duck_arr_len({})", tv.c));
                let out = self.decl(&ty, &format!("duck_arr_new({ops}, {n})"));
                self.open(format!("if ({n} > 0) {{"));
                self.line(format!("duck_task_await_all((DuckTask **){}->data, {n}, {out}->data);", tv.c));
                self.line(format!("{out}->len = {n};"));
                self.close("}");
                self.reown(out, ty)
            }
        }
    }

    // ---- control flow ----

    fn if_(&mut self, e: &Expr, cond: &Expr, then: &Block, els: Option<&Expr>, tail: bool) -> Val {
        let ty = self.ty(e.id);
        let c = self.expr(cond);
        let cc = self.val_as(&c, &Ty::Bool);
        let has = Self::has_value(&ty) && els.is_some();
        let r = if has { Some(self.zero_decl(&ty)) } else { None };
        self.open(format!("if ({cc}) {{"));
        let v = self.block(then, tail);
        if let Some(r) = &r {
            if !v.is_never() {
                let o = self.own_as(v, &ty);
                self.line(format!("{r} = {o};"));
            }
        } else {
            let _ = self.own_drop(v);
        }
        if let Some(x) = els {
            self.close("} else {");
            self.f.ind += 1;
            self.push(ScopeKind::Block);
            let v = self.expr_t(x, tail);
            if let Some(r) = &r
                && !v.is_never()
            {
                let o = self.own_as(v, &ty);
                self.line(format!("{r} = {o};"));
            }
            self.pop();
        }
        self.close("}");
        match r {
            Some(r) => self.reown(r, ty),
            None if ty == Ty::Never => Val::never(),
            None => Val::unit(),
        }
    }

    /// Drop a value produced in a branch whose result is unused (its temps are released by
    /// the enclosing scope already).
    fn own_drop(&mut self, v: Val) -> Option<()> {
        if v.owned && !v.is_never() {
            self.unregister(&v.c);
            if let Some(r) = self.g.release(&v.ty, &v.c) {
                self.line(r);
            }
        }
        Some(())
    }

    fn match_(&mut self, e: &Expr, scrut: &Expr, arms: &[super::ast::Arm], tail: bool) -> Val {
        let ty = self.ty(e.id);
        let sv = self.expr(scrut);
        if sv.is_never() {
            return sv;
        }
        let st = sv.ty.clone();
        let s = self.lvalue(&sv, &st);
        let has = Self::has_value(&ty);
        let r = if has { Some(self.zero_decl(&ty)) } else { None };
        let end = self.name("dk_end");
        for a in arms {
            let test = self.pat_test(&a.pat, &s);
            self.open(format!("if ({test}) {{"));
            self.push(ScopeKind::Block);
            let arm_depth = self.f.scopes.len() - 1;
            self.bind_pat(&a.pat, &s, &st);
            let guarded = if let Some(gx) = &a.guard {
                self.push(ScopeKind::Stmt);
                let v = self.expr(gx);
                let gc = self.val_as(&v, &Ty::Bool);
                let gv = self.decl(&Ty::Bool, &gc);
                self.pop();
                self.open(format!("if ({gv}) {{"));
                true
            } else {
                false
            };
            self.push(ScopeKind::Block);
            let v = self.expr_t(&a.body, tail);
            let never = v.is_never();
            if let Some(r) = &r {
                if !never {
                    let o = self.own_as(v, &ty);
                    self.line(format!("{r} = {o};"));
                }
            } else {
                let _ = self.own_drop(v);
            }
            self.pop();
            if !never {
                self.cleanup_from(arm_depth);
                self.line(format!("goto {end};"));
            }
            if guarded {
                self.close("}");
            }
            self.pop();
            self.close("}");
        }
        let loc = self.loc(e.span);
        self.line(format!("duck_panic({loc}, \"no match arm matches the value\");"));
        self.f.ind -= 1;
        self.line(format!("{end}:;"));
        self.f.ind += 1;
        match r {
            Some(r) => self.reown(r, ty),
            None if ty == Ty::Never => Val::never(),
            None => Val::unit(),
        }
    }

    fn for_(&mut self, e: &Expr, index: Option<&Pat>, pat: &Pat, iter: &Expr, body: &Block) {
        let kind = self.t.fors.get(&e.id).copied();
        match kind {
            Some(ForKind::Range { inclusive }) => {
                let K::Range { lo, hi, .. } = &iter.kind else { return };
                let l = self.expr(lo);
                let h = self.expr(hi);
                let lc = self.val_as(&l, &Ty::Int);
                let hc = self.val_as(&h, &Ty::Int);
                let hv = self.decl(&Ty::Int, &hc);
                let i = self.name("i");
                let cmp = if inclusive { "<=" } else { "<" };
                self.open(format!("for (int64_t {i} = {lc}; {i} {cmp} {hv}; {i}++) {{"));
                self.push(ScopeKind::Block);
                let depth = self.f.scopes.len() - 1;
                self.bind_top(pat, &i, &Ty::Int);
                self.loop_body(depth, body);
                self.pop();
                self.close("}");
            }
            Some(ForKind::List) => {
                let v = self.expr(iter);
                let Ty::List(et) = v.ty.clone() else { return };
                let it = self.hold(v);
                self.register(&it, &Ty::list((*et).clone()));
                let ct = self.g.ct(&et);
                let k = self.name("k");
                self.open(format!("for (int64_t {k} = 0; {k} < duck_arr_len({it}); {k}++) {{"));
                self.push(ScopeKind::Block);
                let depth = self.f.scopes.len() - 1;
                if let Some(ix) = index {
                    self.bind_top(ix, &k, &Ty::Int);
                }
                let el = format!("(({ct} *){it}->data)[{k}]");
                let ev = self.decl(&et, &el);
                self.bind_top(pat, &ev, &et);
                self.loop_body(depth, body);
                self.pop();
                self.close("}");
            }
            Some(ForKind::Map) => {
                let v = self.expr(iter);
                let Ty::Map(kt, vt) = v.ty.clone() else { return };
                let mt = v.ty.clone();
                let m = self.hold(v);
                self.register(&m, &mt);
                let (it, kp, vp) = (self.name("it"), self.name("kp"), self.name("vp"));
                self.line(format!("int64_t {it} = 0;\n{}void *{kp}, *{vp};", "    ".repeat(self.f.ind)));
                self.open(format!("while (duck_map_next({m}, &{it}, &{kp}, &{vp})) {{"));
                self.push(ScopeKind::Block);
                let depth = self.f.scopes.len() - 1;
                let (kc, vc) = (self.g.ct(&kt), self.g.ct(&vt));
                let kv = self.decl(&kt, &format!("*({kc} *){kp}"));
                let vv = self.decl(&vt, &format!("*({vc} *){vp}"));
                match index {
                    Some(ix) => {
                        self.bind_top(ix, &kv, &kt);
                        self.bind_top(pat, &vv, &vt);
                    }
                    None => {
                        let tt = Ty::Tuple(vec![(*kt).clone(), (*vt).clone()]);
                        let tc = self.g.ct(&tt);
                        let tv = self.decl(&tt, &format!("(({tc}){{{kv}, {vv}}})"));
                        self.bind_top(pat, &tv, &tt);
                    }
                }
                self.loop_body(depth, body);
                self.pop();
                self.close("}");
            }
            None => {}
        }
    }

    fn loop_body(&mut self, depth: usize, body: &Block) {
        self.f.loops.push(LoopCx { depth, result: None });
        self.push(ScopeKind::Block);
        for s in &body.stmts {
            self.stmt(s);
        }
        self.pop();
        self.f.loops.pop();
    }

    fn let_(&mut self, e: &Expr, pat: &Pat, value: &Expr, els: Option<&ElseArm>) {
        let Some(arm) = els else {
            let v = self.expr(value);
            if v.is_never() {
                return;
            }
            self.bind_value(pat, v);
            return;
        };
        let info = self.t.elses.get(&e.id).cloned();
        let Some(info) = info else {
            let v = self.expr(value);
            self.bind_value(pat, v);
            return;
        };
        let v = self.expr(value);
        if v.is_never() {
            return;
        }
        match info.kind {
            ElseKind::Option | ElseKind::Result | ElseKind::UnwrapRefutable { .. } => {
                let wt = v.ty.clone();
                let inner = match &wt {
                    Ty::Opt(t) | Ty::Res(t, _) => (**t).clone(),
                    t => t.clone(),
                };
                let w = self.hold(v);
                let r = self.zero_decl(&inner);
                let is_opt = matches!(wt, Ty::Opt(_));
                let ok = if is_opt { format!("{w}.some") } else { format!("{w}.ok") };
                if let ElseKind::UnwrapRefutable { .. } = info.kind {
                    // unwrap, then the pattern must match; otherwise the else (which diverges)
                    self.open(format!("if ({ok}) {{"));
                    self.line(format!("{r} = {w}.val;"));
                    self.close("}");
                    let test = self.pat_test(pat, &r);
                    self.open(format!("if (!({ok}) || !({test})) {{"));
                    self.push(ScopeKind::Block);
                    if let Some(rr) = self.g.release(&inner, &r) {
                        self.line(format!("if ({ok}) {{ {rr} }}"));
                    }
                    if !is_opt {
                        self.line(format!("if (!{w}.ok) duck_release({w}.err);"));
                    }
                    let fb = self.expr(&arm.body);
                    let _ = self.own_drop(fb);
                    self.pop();
                    self.close("}");
                    self.register_local(&r, &inner);
                    self.bind_pat(pat, &r, &inner);
                    return;
                }
                self.open(format!("if ({ok}) {{"));
                self.line(format!("{r} = {w}.val;"));
                self.close("} else {");
                self.f.ind += 1;
                self.push(ScopeKind::Block);
                if !is_opt {
                    self.bind_err(info.binder, &w, &wt);
                }
                let fb = self.expr(&arm.body);
                let o = self.own_as(fb, &inner);
                self.line(format!("{r} = {o};"));
                self.pop();
                self.close("}");
                let rv = Val { c: r.clone(), ty: inner.clone(), owned: true };
                self.register(&r, &inner);
                self.bind_value(pat, rv);
            }
            ElseKind::Refutable => {
                let ty = v.ty.clone();
                let s = if v.owned {
                    v.c.clone()
                } else {
                    let c = self.own(v);
                    let n = self.decl(&ty, &c);
                    self.register_local(&n, &ty);
                    n
                };
                let test = self.pat_test(pat, &s);
                self.open(format!("if (!({test})) {{"));
                self.push(ScopeKind::Block);
                let fb = self.expr(&arm.body);
                let _ = self.own_drop(fb);
                self.pop();
                self.close("}");
                self.bind_pat(pat, &s, &ty);
            }
        }
    }

    /// Bind an irrefutable pattern to a value (a plain name takes the value over).
    fn bind_value(&mut self, pat: &Pat, v: Val) {
        let ty = v.ty.clone();
        if let PatKind::Bind(_) = &pat.kind
            && !self.t.variants.contains_key(&pat.id)
        {
            if let Some(&l) = self.t.binds.get(&pat.id) {
                let o = self.own_as(v, &ty);
                let n = self.name(&format!("{}_", super::cgen::sanitize(&self.t.locals[l].name)));
                let ct = self.g.ct(&ty);
                self.line(format!("{ct} {n} = {o};"));
                self.register_local(&n, &ty);
                self.f.locals.insert(l, Slot { c: n, ty });
            }
            return;
        }
        if let PatKind::Wild = &pat.kind {
            return;
        }
        let s = self.lvalue(&v, &ty);
        self.bind_pat(pat, &s, &ty);
    }

    fn assert_(&mut self, x: &Expr) {
        let loc = self.loc(x.span);
        let text = c_str(&self.g.span_text(self.m, x.span));
        if let K::Binary { op, lhs, rhs } = &x.kind
            && matches!(op, BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge)
        {
            let l = self.expr(lhs);
            let r = self.expr(rhs);
            let c = self.compare(x, *op, &l, &r);
            let cv = self.decl(&Ty::Bool, &c);
            self.open(format!("if (!{cv}) {{"));
            let ls = self.dshow(&l);
            let rs = self.dshow(&r);
            self.line(format!("duck_assert_fail_cmp({loc}, {text}, {ls}, {rs});"));
            self.close("}");
            return;
        }
        let v = self.expr(x);
        let c = self.val_as(&v, &Ty::Bool);
        self.line(format!("if (!({c})) duck_assert_fail({loc}, {text});"));
    }

    /// Debug-form show of a value (strings quoted), as an owned C expression.
    fn dshow(&mut self, v: &Val) -> String {
        if v.is_never() {
            return "NULL".into();
        }
        match self.g.dshow_fn(&v.ty) {
            Some(f) => format!("{f}({})", v.c),
            None => format!("duck_str_lit({})", c_str(&format!("<{}>", self.g.show_ty(&v.ty)))),
        }
    }

    // ---- literals ----

    fn interp(&mut self, parts: &[InterpPart]) -> Val {
        let mut vals = Vec::new();
        for p in parts {
            if let InterpPart::Expr { expr, .. } = p {
                let v = self.expr(expr);
                vals.push(v);
            }
        }
        let sb = self.name("sb");
        self.line(format!("DuckStrBuf {sb} = DUCK_SB_INIT;"));
        let mut k = 0;
        for p in parts {
            match p {
                InterpPart::Lit(s) => {
                    if !s.is_empty() {
                        self.line(format!("duck_sb_bytes(&{sb}, {}, {});", c_str(s), s.len()));
                    }
                }
                InterpPart::Expr { expr, .. } => {
                    let v = vals[k].clone();
                    k += 1;
                    let spec = self.t.formats.get(&expr.id).map(|f| c_str(&f.text));
                    let c = v.c.clone();
                    if v.is_never() {
                        continue;
                    }
                    let line = match (&v.ty, &spec) {
                        (Ty::Int, Some(s)) => format!("duck_sb_str_own(&{sb}, duck_fmt_int({c}, {s}));"),
                        (Ty::Int, None) => format!("duck_sb_str_own(&{sb}, duck_str_from_int({c}));"),
                        (Ty::Float, Some(s)) => format!("duck_sb_str_own(&{sb}, duck_fmt_float({c}, {s}));"),
                        (Ty::Float, None) => format!("duck_sb_str_own(&{sb}, duck_str_from_float({c}));"),
                        (Ty::Str, Some(s)) => format!("duck_sb_str_own(&{sb}, duck_fmt_str({c}, {s}));"),
                        (Ty::Str, None) => format!("duck_sb_str(&{sb}, {c});"),
                        (Ty::Char, Some(s)) => format!("duck_sb_str_own(&{sb}, duck_fmt_char({c}, {s}));"),
                        (Ty::Char, None) => format!("duck_sb_char(&{sb}, {c});"),
                        (Ty::Bool, Some(s)) => format!("duck_sb_str_own(&{sb}, duck_fmt_bool({c}, {s}));"),
                        (Ty::Bool, None) => format!("duck_sb_lit(&{sb}, {c} ? \"true\" : \"false\");"),
                        (_, spec) => {
                            let shown = self.show_of(expr.id, &v);
                            match spec {
                                Some(s) => {
                                    let t = self.decl(&Ty::Str, &shown);
                                    format!("duck_sb_str_own(&{sb}, duck_fmt_str({t}, {s}));\n{}duck_release({t});", "    ".repeat(self.f.ind))
                                }
                                None => format!("duck_sb_str_own(&{sb}, {shown});"),
                            }
                        }
                    };
                    self.line(line);
                    if let Some(u) = self.t.units.get(&expr.id) {
                        let u = format!(" {u}");
                        self.line(format!("duck_sb_bytes(&{sb}, {}, {});", c_str(&u), u.len()));
                    }
                }
            }
        }
        self.tmp(&Ty::Str, &format!("duck_sb_finish(&{sb})"))
    }

    fn struct_lit(&mut self, e: &Expr) -> Val {
        let K::Struct { fields, base, .. } = &e.kind else { unreachable!() };
        let ty = self.ty(e.id);
        let Some(sl) = self.t.struct_lits.get(&e.id).cloned() else { return Val::never() };
        let Ty::Named(d, args) = &ty else { return Val::never() };
        let s = self.tp.defs.subst_of(*d, args);
        let defs = self.tp.defs.fields(*d).to_vec();
        let mut given: Vec<(usize, String)> = Vec::new();
        for (fi, fv) in &sl.fields {
            let ft = defs[*fi].ty.subst(&s);
            let v = match fv {
                FieldValue::Expr(id) => {
                    let x = fields.iter().filter_map(|f| f.value.as_ref()).find(|x| x.id == *id);
                    match x {
                        Some(x) => self.expr(x),
                        None => Val::never(),
                    }
                }
                FieldValue::Local(l, cs) => {
                    let (c, lt) = match self.f.locals.get(l) {
                        Some(s) => (s.c.clone(), s.ty.clone()),
                        None => {
                            let lt = self.local_ty(*l);
                            (self.g.zero(&lt), lt)
                        }
                    };
                    let v = Val::plain(c, lt);
                    self.coerce(v, cs, e.id)
                }
            };
            let o = self.own_as(v, &ft);
            let n = self.decl(&ft, &o);
            self.register(&n, &ft);
            given.push((*fi, n));
        }
        let ct = self.g.ct(&ty);
        match base {
            Some(b) => {
                let bv = self.expr(b);
                for (_, n) in &given {
                    self.unregister(n);
                }
                let o = self.own_as(bv, &ty);
                let r = self.decl(&ty, &o);
                for (fi, n) in given {
                    let ft = defs[fi].ty.subst(&s);
                    let (f, boxed) = self.g.field_raw(&ty, fi, &r);
                    if boxed {
                        self.line(format!("duck_release({f});"));
                    } else if let Some(rel) = self.g.release(&ft, &f) {
                        self.line(rel);
                    }
                    let put = self.g.field_put(&ty, fi, &n);
                    self.line(format!("{f} = {put};"));
                }
                self.reown(r, ty)
            }
            None => {
                for (_, n) in &given {
                    self.unregister(n);
                }
                let mut parts = Vec::new();
                for (fi, n) in given {
                    let put = self.g.field_put(&ty, fi, &n);
                    parts.push(format!(".f_{} = {put}", super::cgen::sanitize(&defs[fi].name)));
                }
                if parts.is_empty() {
                    parts.push(".dummy = 0".into());
                }
                self.tmp(&ty, &format!("(({ct}){{{}}})", parts.join(", ")))
            }
        }
    }

    // ---- closures ----

    fn closure(&mut self, e: &Expr, params: &[super::ast::Param], body: &Expr) -> Val {
        let Some(info) = self.t.closures.get(&e.id).cloned() else { return Val::never() };
        let ptys: Vec<Ty> = info.params.iter().map(|t| self.sub(t)).collect();
        let ret = self.sub(&info.ret);
        let k = self.g.fresh();
        let fname = format!("dk_clo{k}");
        let env = format!("DkEnv{k}");
        // capture
        let mut caps = Vec::new();
        for &l in &info.captures {
            let (c, ty) = match self.f.locals.get(&l) {
                Some(s) => (s.c.clone(), s.ty.clone()),
                None => {
                    let ty = self.local_ty(l);
                    (self.g.zero(&ty), ty)
                }
            };
            caps.push((l, c, ty));
        }
        if !caps.is_empty() {
            let mut st = String::from("    DuckObj o;\n");
            let mut drop = String::new();
            for (i, (_, _, ty)) in caps.iter().enumerate() {
                let c = self.g.ct(ty);
                let _ = writeln!(st, "    {c} c{i};");
                if let Some(r) = self.g.release(ty, &format!("e->c{i}")) {
                    let _ = writeln!(drop, "    {r}");
                }
            }
            let _ = writeln!(self.g.types, "typedef struct {env} {{\n{st}}} {env};");
            let _ = writeln!(self.g.protos, "static void {env}_drop(DuckObj *o);");
            let _ = writeln!(self.g.funcs, "static void {env}_drop(DuckObj *o) {{\n    {env} *e = ({env} *)o;\n    (void)e;\n{drop}}}\n");
        }
        // the lifted function
        let fty = if info.unpack { vec![Ty::Tuple(ptys.clone())] } else { ptys.clone() };
        let rc = self.g.ct(&ret);
        let mut pdecl = vec!["DuckEnv *env_".to_string()];
        for (i, t) in fty.iter().enumerate() {
            let c = self.g.ct(t);
            pdecl.push(format!("{c} a{i}"));
        }
        let sig = format!("static {rc} {fname}({})", pdecl.join(", "));
        self.begin(ret.clone());
        self.push(ScopeKind::Block);
        if caps.is_empty() {
            self.line("(void)env_;");
        } else {
            self.line(format!("{env} *env = ({env} *)env_;"));
        }
        for (i, (l, _, ty)) in caps.iter().enumerate() {
            self.f.locals.insert(*l, Slot { c: format!("env->c{i}"), ty: ty.clone() });
        }
        if info.unpack {
            for (i, (p, t)) in params.iter().zip(&ptys).enumerate() {
                self.bind_top(&p.pat, &format!("a0.f{i}"), t);
            }
        } else {
            for (i, (p, t)) in params.iter().zip(&ptys).enumerate() {
                self.bind_top(&p.pat, &format!("a{i}"), t);
            }
        }
        let v = self.expr(body);
        if ret.is_unit() {
            if !v.is_never() {
                self.cleanup_from(0);
                self.line("return 0;");
            }
        } else {
            self.ret_val(v, &ret);
        }
        let z = self.g.zero(&ret);
        self.line(format!("return {z};"));
        let st = self.end();
        let _ = writeln!(self.g.protos, "{sig};");
        let _ = writeln!(self.g.funcs, "{sig} {{\n{}}}\n", st.out);
        // build the value
        let fnty = Ty::func(fty, ret);
        if caps.is_empty() {
            return Val::plain(format!("((DuckClosure){{(void *){fname}, NULL}})"), fnty);
        }
        let en = self.decl(&Ty::Int, "0");
        let _ = en;
        let ev = self.name("env");
        self.line(format!("{env} *{ev} = duck_obj_alloc(sizeof({env}), {env}_drop);"));
        for (i, (_, c, ty)) in caps.into_iter().enumerate() {
            let o = self.own(Val::plain(c, ty));
            self.line(format!("{ev}->c{i} = {o};"));
        }
        self.tmp(&fnty, &format!("((DuckClosure){{(void *){fname}, (DuckEnv *){ev}}})"))
    }
}

fn a_ty(a: &ArgV) -> Ty {
    match a {
        ArgV::Val(v) => v.ty.clone(),
        ArgV::Addr(_, t) => t.clone(),
    }
}

/// The argument expressions of `old(e)` calls (whose ids are in `olds`) inside `e`.
fn collect_olds<'e>(e: &'e Expr, olds: &[u32], out: &mut Vec<&'e Expr>) {
    fn walk<'e>(e: &'e Expr, olds: &[u32], out: &mut Vec<&'e Expr>) {
        if let K::Call { callee, args } = &e.kind
            && let K::Name(n) = &callee.kind
            && n == "old"
            && args.len() == 1
            && olds.contains(&args[0].id)
        {
            out.push(&args[0]);
            return;
        }
        match &e.kind {
            K::Call { callee, args } => {
                walk(callee, olds, out);
                args.iter().for_each(|a| walk(a, olds, out));
            }
            K::MethodCall { recv, args, .. } => {
                walk(recv, olds, out);
                args.iter().for_each(|a| walk(a, olds, out));
            }
            K::Binary { lhs, rhs, .. } => {
                walk(lhs, olds, out);
                walk(rhs, olds, out);
            }
            K::Unary { expr, .. } | K::Field { expr, .. } | K::TupleField { expr, .. } => walk(expr, olds, out),
            K::Index { expr, index } => {
                walk(expr, olds, out);
                walk(index, olds, out);
            }
            K::Tuple(xs) | K::List(xs) => xs.iter().for_each(|x| walk(x, olds, out)),
            K::Pipe { lhs, args, .. } => {
                walk(lhs, olds, out);
                args.iter().for_each(|a| walk(a, olds, out));
            }
            _ => {}
        }
    }
    walk(e, olds, out);
}

/// The C expression for `a op b` on `int`: checked arithmetic and shifts go through runtime
/// helpers that panic at `loc`; the wrapping and bitwise ones can't fail.
fn int_op(op: BinOp, a: &str, b: &str, loc: &str) -> String {
    use BinOp::*;
    match op {
        Add => format!("duck_add({a}, {b}, {loc})"),
        Sub => format!("duck_sub({a}, {b}, {loc})"),
        Mul => format!("duck_mul({a}, {b}, {loc})"),
        Div => format!("duck_div({a}, {b}, {loc})"),
        Rem => format!("duck_mod({a}, {b}, {loc})"),
        Pow => format!("duck_pow({a}, {b}, {loc})"),
        AddWrap => format!("duck_wadd({a}, {b})"),
        SubWrap => format!("duck_wsub({a}, {b})"),
        MulWrap => format!("duck_wmul({a}, {b})"),
        BitAnd => format!("({a} & {b})"),
        BitOr => format!("({a} | {b})"),
        BitXor => format!("({a} ^ {b})"),
        Shl => format!("duck_shl({a}, {b}, {loc})"),
        Shr => format!("duck_shr({a}, {b}, {loc})"),
        _ => "0".into(),
    }
}
