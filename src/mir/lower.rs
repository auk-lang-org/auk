//! Lowering of function bodies to MIR: expressions, statements, patterns, control flow and
//! reference counting. One `Lower` emits one instance (plus the closures, thunks and wrappers it
//! needs) into the `Gen`'s program.
//!
//! # How a body is lowered
//! Expressions are lowered in evaluation order to statements; each returns a `Val`: an
//! expression of a Duck type that is either **owned** (a temporary variable the current scope
//! will release unless it is moved out with `own`) or **borrowed** (a local, a field of a value
//! that outlives the statement, a global). Locals own their values; parameters are borrowed (or,
//! in a function whose self tail calls became a loop, owned copies).
//!
//! Scopes mirror Duck's: a statement scope holds that statement's temporaries, block scopes hold
//! locals, a loop marks where `break`/`continue` stop releasing. An early exit (`return`, `?`,
//! `fail`, `break`, `continue`, a self tail call) releases every scope it leaves.
//!
//! Patterns (clauses, `match`, `let`, `for`, closure parameters, `is`) compile to a pure test
//! expression plus a binding step; clauses and arms are tried top to bottom.

mod pat;

use std::collections::{HashMap, HashSet};

use super::progen::{Gen, d};
use super::{Abi, BOp, Callee, Ex, FuncId, K, LabelId, MTy, Rt, RtF, Sel, Stmt, UOp};
use crate::ast::{BinOp, Block, ElseArm, Expr, ExprKind as EK, FnBody, InterpPart, Item, Lit, Pat, PatKind, UnOp};
use crate::resolve::ModId;
use crate::typed::{
    AwaitKind, BodyRef, Callee as TCallee, Coercion, ElseKind, FailKind, FieldValue, FnId, FnKind, ForKind, InstId, Intrinsic, LocalId, NameRef, Tables,
    Target, TryKind, TypedProgram,
};
use crate::types::{Builtin, ParamId, Ty};

/// A lowered value of Duck type `ty`.
#[derive(Debug, Clone)]
pub struct Val {
    pub c: Ex,
    pub ty: Ty,
    pub owned: bool,
}

impl Val {
    fn unit() -> Val {
        Val { c: Ex::unit(), ty: Ty::unit(), owned: false }
    }
    fn never() -> Val {
        Val { c: Ex::int_as(0, MTy::D(Ty::Never)), ty: Ty::Never, owned: false }
    }
    fn plain(c: Ex, ty: Ty) -> Val {
        Val { c, ty, owned: false }
    }
    fn is_never(&self) -> bool {
        self.ty == Ty::Never
    }
}

/// An argument: a value, or (for `var` parameters) the address of a place.
enum ArgV {
    Val(Val),
    Addr(Ex, Ty),
}

#[derive(Clone)]
struct Slot {
    c: Ex,
    ty: Ty,
}

#[derive(Clone, Copy, PartialEq)]
enum ScopeKind {
    Block,
    Stmt,
}

struct Scope {
    kind: ScopeKind,
    owned: Vec<(Ex, Ty)>,
}

/// The debugger state of an instrumented function (`progen::Debug`): its frame record (a
/// variable of a generated aggregate `{fn, parent, site, slot...}` whose slots are filled as
/// named locals are bound) and the locals in scope.
struct FnDbg {
    frame: Ex,
    agg: super::AggId,
    func: u32,
    slots: HashMap<LocalId, u32>,
    /// The locals in scope: (slot, index of the scope that ends it).
    vis: Vec<(u32, usize)>,
    /// Binding a `let`'s names: they last until the end of the enclosing block, not the `let`
    /// statement's scope.
    in_let: bool,
}

struct LoopCx {
    /// Index of the loop body's scope.
    depth: usize,
    result: Option<(Ex, Ty)>,
}

struct TailCx {
    /// The parameters (owned copies, or pointer parameters for `var` ones).
    params: Vec<(Ex, Ty, bool)>,
    label: LabelId,
}

/// The state of one function being emitted.
struct FnState {
    b: super::Body,
    scopes: Vec<Scope>,
    loops: Vec<LoopCx>,
    locals: HashMap<LocalId, Slot>,
    ret: Ty,
    tail: Option<TailCx>,
    olds: HashMap<u32, Ex>,
    var_params: HashSet<LocalId>,
    dbg: Option<FnDbg>,
}

impl FnState {
    fn new(ret: Ty) -> FnState {
        FnState {
            b: super::Body::new(),
            scopes: Vec::new(),
            loops: Vec::new(),
            locals: HashMap::new(),
            ret,
            tail: None,
            olds: HashMap::new(),
            var_params: HashSet::new(),
            dbg: None,
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

/// `ss` with `leave` (popping the debugger frame) before every return; a returned value is
/// computed first, so a call in return position runs with the frame still pushed.
fn dbg_rets(ss: Vec<Stmt>, vars: &mut Vec<MTy>, leave: &Stmt) -> Vec<Stmt> {
    let mut out = Vec::with_capacity(ss.len());
    for s in ss {
        match s {
            Stmt::Ret(Some(e)) => {
                vars.push(e.ty.clone());
                let v = vars.len() as super::VarId - 1;
                let ty = e.ty.clone();
                out.push(Stmt::Let(v, e));
                out.push(leave.clone());
                out.push(Stmt::Ret(Some(Ex::var(v, ty))));
            }
            Stmt::Ret(None) => {
                out.push(leave.clone());
                out.push(Stmt::Ret(None));
            }
            Stmt::If(c, a, b) => out.push(Stmt::If(c, dbg_rets(a, vars, leave), dbg_rets(b, vars, leave))),
            Stmt::Loop(a, b) => out.push(Stmt::Loop(dbg_rets(a, vars, leave), dbg_rets(b, vars, leave))),
            s => out.push(s),
        }
    }
    out
}

/// The direct sub-expressions that can be call arguments of `e` (receiver first).
fn arg_exprs(e: &Expr) -> Vec<&Expr> {
    match &e.kind {
        EK::Call { args, .. } => args.iter().collect(),
        EK::MethodCall { recv, args, .. } => std::iter::once(&**recv).chain(args).collect(),
        EK::Pipe { lhs, args, .. } => std::iter::once(&**lhs).chain(args).collect(),
        EK::OptChain { expr, args, .. } => std::iter::once(&**expr).chain(args.iter().flatten()).collect(),
        EK::Binary { lhs, rhs, .. } => vec![lhs, rhs],
        EK::Assign { target, value, .. } => vec![target, value],
        _ => Vec::new(),
    }
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

    fn loc(&self, span: crate::diag::Span) -> Ex {
        Ex::cstr(&format!("{}:{}:{}", self.file, span.line, span.col))
    }

    /// A cancellation point at the top of every iteration of a user loop: one load of
    /// `duck_cancel_pending` while no task is cancelled (runtime/src/task.rs).
    fn cancel_point(&mut self, span: crate::diag::Span) {
        let pending = Ex::rt_global("duck_cancel_pending", MTy::D(Ty::Int)).deref(MTy::D(Ty::Int));
        self.open_if(Ex::bin(BOp::Ne, pending, Ex::int(0)));
        let loc = self.loc(span);
        self.do_(Ex::rt("duck_cancel_check", vec![loc], MTy::Void));
        self.close();
    }

    fn emit(&mut self, s: Stmt) {
        self.f.b.emit(s);
    }

    fn do_(&mut self, e: Ex) {
        self.f.b.do_(e);
    }

    fn set(&mut self, place: Ex, v: Ex) {
        self.f.b.set(place, v);
    }

    fn open_if(&mut self, c: Ex) {
        self.f.b.open_if(c);
    }

    fn else_(&mut self) {
        self.f.b.else_();
    }

    fn close(&mut self) {
        self.f.b.close();
    }

    /// Declare a variable (not registered for release).
    fn decl(&mut self, ty: &Ty, init: Ex) -> Ex {
        self.f.b.decl_as(d(ty), init)
    }

    /// An owned temporary (registered for release in the current scope).
    fn tmp(&mut self, ty: &Ty, init: Ex) -> Val {
        let n = self.decl(ty, init);
        self.register(&n, ty);
        Val { c: n, ty: ty.clone(), owned: true }
    }

    fn register(&mut self, c: &Ex, ty: &Ty) {
        if self.g.needs_rc(ty) {
            self.f.scopes.last_mut().expect("scope").owned.push((c.clone(), ty.clone()));
        }
    }

    /// Register an owned local in the innermost block scope.
    fn register_local(&mut self, c: &Ex, ty: &Ty) {
        if !self.g.needs_rc(ty) {
            return;
        }
        let i = self.f.scopes.iter().rposition(|s| s.kind == ScopeKind::Block).unwrap_or(0);
        self.f.scopes[i].owned.push((c.clone(), ty.clone()));
    }

    fn unregister(&mut self, c: &Ex) {
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
        if let Some(d) = &mut self.f.dbg {
            let k = self.f.scopes.len();
            d.vis.retain(|&(_, sc)| sc < k);
        }
        for (c, ty) in s.owned.iter().rev() {
            if let Some(r) = self.g.release(ty, c) {
                self.emit(r);
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
                self.emit(r);
            }
        }
    }

    /// Take ownership of a value: moves an owned temporary, retains a borrowed value.
    fn own(&mut self, v: Val) -> Ex {
        if v.owned {
            self.unregister(&v.c);
            return v.c;
        }
        if let Some(r) = self.g.retain(&v.ty, &v.c) {
            self.emit(r);
        }
        v.c
    }

    /// `own`, giving a zero of `ty` for a `never` value.
    fn own_as(&mut self, v: Val, ty: &Ty) -> Ex {
        if v.is_never() {
            return self.g.zero(ty);
        }
        self.own(v)
    }

    /// Like `own`, but materialized in a fresh (unregistered) variable.
    fn hold(&mut self, v: Val) -> Ex {
        if v.owned && v.c.is_var() {
            self.unregister(&v.c);
            return v.c;
        }
        let ty = v.ty.clone();
        let o = self.own(v);
        self.decl(&ty, o)
    }

    /// A borrowed value as an expression of type `ty` (zero for `never`).
    fn val_as(&mut self, v: &Val, ty: &Ty) -> Ex {
        if v.is_never() { self.g.zero(ty) } else { v.c.clone() }
    }

    /// An addressable variable holding the value (borrowed copy when needed).
    fn lvalue(&mut self, v: &Val, ty: &Ty) -> Ex {
        if v.c.is_place() && !v.is_never() {
            return v.c.clone();
        }
        let c = self.val_as(v, ty);
        self.decl(ty, c)
    }

    /// An owned temporary for `e`, which is an owned value of `ty`.
    fn adopt(&mut self, ty: &Ty, e: Ex) -> Val {
        self.tmp(ty, e)
    }

    /// Re-register an owned held variable as a temporary in the current scope.
    fn reown(&mut self, c: Ex, ty: Ty) -> Val {
        self.register(&c, &ty);
        Val { c, ty, owned: true }
    }

    fn zero_decl(&mut self, ty: &Ty) -> Ex {
        let z = self.g.zero(ty);
        self.decl(ty, z)
    }

    /// The index of struct field `name` in type `t`.
    fn field_index(&self, t: &Ty, name: &str) -> Option<usize> {
        match t {
            Ty::Named(dd, _) if self.tp.defs.is_struct(*dd) => self.tp.defs.fields(*dd).iter().position(|f| f.name == name),
            _ => None,
        }
    }

    fn has_value(ty: &Ty) -> bool {
        !ty.is_unit() && *ty != Ty::Never
    }

    fn some(&mut self, ty: &Ty, v: Ex) -> Ex {
        let Ty::Opt(inner) = ty else { panic!("some of a non-optional") };
        Ex::agg(d(ty), vec![(Sel::F(0), Ex::new(K::Int(1), MTy::Bool)), (Sel::F(1), super::retype(v, &d(inner)))])
    }

    fn ok(&mut self, ty: &Ty, v: Ex) -> Ex {
        let Ty::Res(inner, _) = ty else { panic!("ok of a non-result") };
        Ex::agg(d(ty), vec![(Sel::F(0), Ex::new(K::Int(1), MTy::Bool)), (Sel::F(1), super::retype(v, &d(inner)))])
    }

    fn fld(&self, v: &Ex, s: Sel) -> Ex {
        self.g.fld(v, s)
    }

    /// The `DuckStr *` show of a non-primitive value for a message, or `<T>`.
    fn trace_site(&mut self, loc: Ex) {
        let slot = Ex::rt("duck__trace_site_slot", vec![], MTy::ptr(MTy::CStr));
        self.set(slot.deref(MTy::CStr), loc);
    }

    // ---- function bodies ----

    fn begin(&mut self, ret: Ty) {
        let f = std::mem::replace(&mut self.f, FnState::new(ret));
        self.saved.push(f);
    }

    /// Finish the current body into function `f`.
    fn end(&mut self, f: FuncId) {
        let prev = self.saved.pop().expect("fn state");
        let st = std::mem::replace(&mut self.f, prev);
        let Some(dbg) = st.dbg else {
            self.g.define(f, st.b);
            return;
        };
        // instrumented: push the frame record first, pop it before every return
        let (body, mut vars) = st.b.finish();
        let fp = dbg.frame.clone().addr().cast(MTy::void_ptr());
        let leave = Stmt::Do(Ex::rt("duck_dbg_leave", vec![fp.clone()], MTy::Void));
        let mut out = vec![
            Stmt::Let(dbg.frame.as_var().expect("frame var"), Ex::agg(MTy::Agg(dbg.agg), vec![(Sel::F(0), Ex::int_as(dbg.func as i64, MTy::I64))])),
            Stmt::Do(Ex::rt("duck_dbg_enter", vec![fp], MTy::Void)),
        ];
        out.extend(dbg_rets(body, &mut vars, &leave));
        let func = &mut self.g.prog.funcs[f as usize];
        func.body = out;
        func.vars = vars;
    }

    /// Record the Duck name of a generated function (for debug info).
    fn name_fn(&mut self, f: FuncId, name: &str) {
        if self.g.lines {
            self.g.prog.names.insert(f, name.to_string());
        }
    }

    /// Instrument the function being lowered for the debugger (when its module is), under the
    /// name the debugger shows.
    fn dbg_begin(&mut self, name: String) {
        if !self.g.dbg_on(self.m) {
            return;
        }
        let k = self.g.fresh();
        let agg = self.g.agg(format!("DkDbgFrame{k}"), vec![MTy::I64, MTy::void_ptr(), MTy::I64]);
        let frame = self.f.b.new_var(MTy::Agg(agg));
        self.g.dbg_info.fns.push(super::progen::DbgFn { name, locals: Vec::new() });
        let func = self.g.dbg_info.fns.len() as u32 - 1;
        self.f.dbg = Some(FnDbg { frame, agg, func, slots: HashMap::new(), vis: Vec::new(), in_let: false });
    }

    /// Bind a local name; in an instrumented function, also record its address in the frame.
    fn bind_name(&mut self, l: LocalId, s: Slot) {
        if self.f.dbg.is_some() {
            let place = if s.c.is_place() { s.c.clone() } else { self.decl(&s.ty, s.c.clone()) };
            let d = self.f.dbg.as_mut().expect("dbg");
            let i = match d.slots.get(&l) {
                Some(&i) => i,
                None => {
                    let i = d.slots.len() as u32;
                    d.slots.insert(l, i);
                    let (agg, func) = (d.agg, d.func as usize);
                    self.g.prog.aggs[agg as usize].fields.push(MTy::void_ptr());
                    let name = self.t.locals[l].name.clone();
                    let tid = self.g.dbg_info.type_id(&s.ty);
                    self.g.dbg_info.fns[func].locals.push((name, tid));
                    i
                }
            };
            let scope = if self.f.dbg.as_ref().is_some_and(|d| d.in_let) {
                self.f.scopes.iter().rposition(|s| s.kind == ScopeKind::Block).unwrap_or(0)
            } else {
                self.f.scopes.len().saturating_sub(1)
            };
            let d = self.f.dbg.as_mut().expect("dbg");
            if !d.vis.iter().any(|&(x, _)| x == i) {
                d.vis.push((i, scope));
            }
            let slot = d.frame.clone().field(Sel::F(3 + i), MTy::void_ptr());
            self.set(slot, place.addr().cast(MTy::void_ptr()));
        }
        self.f.locals.insert(l, s);
    }

    /// A debugger stop point: record the statement's site in the frame and call the debugger
    /// while it is armed (one load otherwise).
    fn dbg_hook(&mut self, span: crate::diag::Span) {
        if self.g.lines {
            self.g.prog.locs.push((self.file.clone(), span.line, span.col));
            let i = self.g.prog.locs.len() as u32 - 1;
            self.emit(Stmt::Loc(i));
        }
        let Some(d) = &self.f.dbg else { return };
        let vis = d.vis.iter().map(|&(x, _)| x).collect();
        let site = super::progen::DbgSite { func: d.func, file: self.file.clone(), line: span.line, col: span.col, vis };
        let frame = d.frame.clone();
        self.g.dbg_info.sites.push(site);
        let id = self.g.dbg_info.sites.len() as i64 - 1;
        self.set(frame.clone().field(Sel::F(2), MTy::I64), Ex::int_as(id, MTy::I64));
        let armed = Ex::rt_global("duck_dbg_armed", MTy::D(Ty::Int)).deref(MTy::D(Ty::Int));
        self.open_if(Ex::bin(BOp::Ne, armed, Ex::int(0)));
        self.do_(Ex::rt("duck_dbg_hook", vec![frame.addr().cast(MTy::void_ptr())], MTy::Void));
        self.close();
    }

    /// Start the body of a declared function: its parameters.
    fn begin_fn(&mut self, f: FuncId, ret: Ty) -> Vec<Ex> {
        self.begin(ret);
        let ps = self.g.prog.funcs[f as usize].vars.clone();
        ps.into_iter().map(|t| self.f.b.new_var(t)).collect()
    }

    fn emit_fn(&mut self, fid: FnId, group: &'a crate::ast::FnGroup) {
        let tp = self.tp;
        let info = &tp.fns[fid];
        let FnKind::Duck { clauses, header, .. } = &info.kind else { unreachable!() };
        let outer = self.g.inst_fn(self.inst);
        let base = self.g.prog.funcs[outer as usize].name.clone();
        let sig = self.g.prog.funcs[outer as usize].vars.clone();
        let rty = self.g.func_ret(outer);
        // traced: `outer` becomes the tracing wrapper around the function, `_untraced`
        let traced = self.g.traced(info.module);
        let name = if traced { self.g.declare(format!("{base}_untraced"), sig.clone(), rty.clone(), Abi::Duck) } else { outer };
        let params: Vec<(Ty, bool)> = info.params.iter().map(|p| (self.sub(&p.ty), p.var)).collect();
        let ret = self.sub(&info.ret);
        let hdr = if *header { group.header.as_deref() } else { None };
        let cls: Vec<&crate::ast::FnClause> = clauses.iter().map(|&c| &group.clauses[c]).collect();
        let ensures = self.g.debug() && (hdr.is_some_and(|h| !h.ensures.is_empty()) || cls.iter().any(|c| !c.ensures.is_empty()));
        let body_name = if ensures {
            let n = self.g.prog.funcs[name as usize].name.clone();
            self.g.declare(format!("{n}_body"), sig.clone(), rty.clone(), Abi::Duck)
        } else {
            name
        };

        let args = self.begin_fn(body_name, ret.clone());
        let dname = format!("{}.{}", self.trace_mod_name(info.module), info.name);
        self.name_fn(body_name, &dname);
        self.dbg_begin(dname);
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
        let mut tparams = Vec::new();
        for (k, (t, var)) in params.iter().enumerate() {
            if *var {
                pnames.push((args[k].clone().deref(d(t)), t.clone(), true));
                tparams.push((args[k].clone(), t.clone(), true));
                continue;
            }
            let p = self.decl(t, args[k].clone());
            if tail {
                if let Some(r) = self.g.retain(t, &p) {
                    self.emit(r);
                }
                self.register(&p, t);
            }
            pnames.push((p.clone(), t.clone(), false));
            tparams.push((p, t.clone(), false));
        }
        if tail {
            // label 0 is the self-tail-call loop's (`Body::label` starts at 1)
            let label = 0;
            self.f.tail = Some(TailCx { params: tparams, label });
            self.emit(Stmt::Label(label));
        }
        // header contracts
        if let Some(h) = hdr {
            for (k, p) in h.params.iter().enumerate() {
                if let Some(&l) = self.t.binds.get(&p.pat.id) {
                    self.bind_name(l, Slot { c: pnames[k].0.clone(), ty: pnames[k].1.clone() });
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
        let msg = format!("no clause of `{}` matches the arguments", info.name);
        self.do_(Ex::rt("duck_panic_str", vec![loc, Ex::cstr(&msg)], MTy::Void));
        self.emit(Stmt::Unreachable);
        self.f.scopes.clear();
        self.end(body_name);
        if ensures {
            self.ensures_wrapper(fid, name, body_name, &params, &ret, hdr, &cls);
        }
        if traced {
            self.trace_wrapper(fid, outer, name, &params, &ret);
        }
    }

    /// The tracing wrapper `outer` of the function `inner` (`duck run/test --trace`): records a
    /// call event with the shown arguments, and a return (or error) event with the shown result.
    fn trace_wrapper(&mut self, fid: FnId, outer: FuncId, inner: FuncId, params: &[(Ty, bool)], ret: &Ty) {
        let info = &self.tp.fns[fid];
        let fname = Ex::cstr(&format!("{}.{}", self.trace_mod_name(info.module), info.name));
        let loc = self.loc(info.span);
        let ps = self.begin_fn(outer, ret.clone());
        let call = self.g.call(inner, ps.clone());
        self.open_if(Ex::rt("duck_trace_begin", vec![], MTy::Bool).not());
        self.emit(Stmt::Ret(Some(call.clone())));
        self.close();
        let mut shows = Vec::new();
        for (k, (t, var)) in params.iter().enumerate() {
            let v = if *var { ps[k].clone().deref(d(t)) } else { ps[k].clone() };
            shows.push(self.trace_show(t, v));
        }
        let n = shows.len();
        let args = if n == 0 {
            Ex::zero(MTy::ptr(MTy::D(Ty::Str)))
        } else {
            let a = self.shows_agg(n);
            let arr = self.f.b.decl(Ex::agg(MTy::Agg(a), shows.into_iter().enumerate().map(|(i, s)| (Sel::F(i as u32), s)).collect()));
            arr.addr().cast(MTy::ptr(MTy::D(Ty::Str)))
        };
        self.do_(Ex::rt("duck_trace_call", vec![fname.clone(), loc, Ex::int_as(n as i64, MTy::I32), args], MTy::Void));
        let r = self.decl(ret, call);
        let unitish = |t: &Ty| t.is_unit() || *t == Ty::Never;
        self.open_if(Ex::rt("duck_trace_exit", vec![], MTy::Bool));
        match ret {
            Ty::Res(t, _) => {
                self.open_if(self.fld(&r, Sel::F(0)));
                let ok = if unitish(t) { Ex::zero(MTy::D(Ty::Str)) } else { self.trace_show(t, self.fld(&r, Sel::F(1))) };
                self.do_(Ex::rt("duck_trace_ret", vec![fname.clone(), ok], MTy::Void));
                self.else_();
                self.do_(Ex::rt("duck_trace_err", vec![fname, self.fld(&r, Sel::F(2))], MTy::Void));
                self.close();
            }
            t if unitish(t) => self.do_(Ex::rt("duck_trace_ret", vec![fname, Ex::zero(MTy::D(Ty::Str))], MTy::Void)),
            t => {
                let s = self.trace_show(t, r.clone());
                self.do_(Ex::rt("duck_trace_ret", vec![fname, s], MTy::Void));
            }
        }
        self.close();
        self.emit(Stmt::Ret(Some(r)));
        self.end(outer);
    }

    /// An aggregate of `n` strings (an array of shown values).
    fn shows_agg(&mut self, n: usize) -> super::AggId {
        let key = format!("shows{n}");
        if let Some(&a) = self.g.memo2.get(&key) {
            return a;
        }
        let a = self.g.agg(format!("DkStrs{n}"), vec![MTy::D(Ty::Str); n]);
        self.g.memo2.insert(key, a);
        a
    }

    /// A module's name in trace events: its path (`json`, `http.uri`), but the root file of a
    /// program that isn't a project's `src/lib.duck`/`src/main.duck` goes by its file name.
    fn trace_mod_name(&self, m: ModId) -> String {
        let p = &self.tp.program;
        let stem = std::path::Path::new(&p.mods[m].file).file_stem().map(|s| s.to_string_lossy().into_owned());
        match stem {
            Some(stem) if m == p.root && stem != "lib" && stem != "main" => stem,
            _ => p.name(m),
        }
    }

    /// The shown value of `e` (type `t`) in a trace event: an owned `DuckStr *`.
    fn trace_show(&mut self, t: &Ty, e: Ex) -> Ex {
        match self.g.dshow_fn(t) {
            Some(f) => self.g.call_ref(&f, vec![e], MTy::D(Ty::Str)),
            None => {
                let text = format!("<{}>", self.g.show_ty(t));
                Ex::rt("duck_str_from_bytes", vec![Ex::cstr(&text), Ex::int(text.len() as i64)], MTy::D(Ty::Str))
            }
        }
    }

    fn requires(&mut self, r: &Expr) {
        self.push(ScopeKind::Stmt);
        let v = self.expr(r);
        let c = self.val_as(&v, &Ty::Bool);
        let cv = self.decl(&Ty::Bool, c);
        self.pop();
        let loc = self.loc(r.span);
        let text = Ex::cstr(&self.g.span_text(self.m, r.span));
        self.open_if(cv.not());
        self.do_(Ex::rt("duck_requires_fail", vec![loc, text], MTy::Void));
        self.close();
    }

    fn clause(&mut self, c: &'a crate::ast::FnClause, pnames: &[(Ex, Ty, bool)], ret: &Ty) {
        let mut conds = Vec::new();
        for (k, p) in c.params.iter().enumerate() {
            conds.push(self.pat_test(&p.pat, &pnames[k].0));
        }
        self.open_if(Ex::and(conds.into_iter().filter(|c| *c != Ex::bool(true)).collect()));
        self.push(ScopeKind::Block);
        for (k, p) in c.params.iter().enumerate() {
            self.bind_top(&p.pat, &pnames[k].0, &pnames[k].1);
        }
        let guarded = if let Some(gx) = &c.guard {
            self.push(ScopeKind::Stmt);
            let v = self.expr(gx);
            let gc = self.val_as(&v, &Ty::Bool);
            let gv = self.decl(&Ty::Bool, gc);
            self.pop();
            self.open_if(gv);
            true
        } else {
            false
        };
        for r in &c.requires {
            self.requires(r);
        }
        self.push(ScopeKind::Block);
        let v = match &c.body {
            Some(FnBody::Expr(e)) => {
                self.dbg_hook(e.span);
                self.expr_t(e, true)
            }
            Some(FnBody::Block(b)) => self.block(b, true),
            _ => Val::unit(),
        };
        self.ret_val(v, ret);
        self.pop();
        if guarded {
            self.close();
        }
        self.pop();
        self.close();
    }

    /// Return a value from the current function (releasing every scope).
    fn ret_val(&mut self, v: Val, ret: &Ty) {
        if v.is_never() {
            return;
        }
        let o = self.own_as(v, ret);
        let rv = self.decl(ret, o);
        self.cleanup_from(0);
        self.emit(Stmt::Ret(Some(rv)));
    }

    /// The function `name` that checks `ensures` around the clause group's body `body_name`.
    #[allow(clippy::too_many_arguments)]
    fn ensures_wrapper(
        &mut self,
        fid: FnId,
        name: FuncId,
        body_name: FuncId,
        params: &[(Ty, bool)],
        ret: &Ty,
        hdr: Option<&'a crate::ast::FnClause>,
        cls: &[&'a crate::ast::FnClause],
    ) {
        let ps = self.begin_fn(name, ret.clone());
        self.push(ScopeKind::Block);
        let pnames: Vec<(Ex, Ty, bool)> =
            params.iter().enumerate().map(|(k, (t, var))| (if *var { ps[k].clone().deref(d(t)) } else { ps[k].clone() }, t.clone(), *var)).collect();
        if let Some(h) = hdr {
            for (k, p) in h.params.iter().enumerate() {
                if let PatKind::Bind(_) = &p.pat.kind
                    && let Some(&l) = self.t.binds.get(&p.pat.id)
                {
                    self.bind_name(l, Slot { c: pnames[k].0.clone(), ty: params[k].0.clone() });
                }
            }
            self.capture_olds(fid, h);
        }
        // with clause `ensures`, find the clause that will run (tried in order, like the body)
        let dispatch = cls.iter().any(|c| !c.ensures.is_empty());
        for c in cls.iter().filter(|_| dispatch) {
            let mut conds = Vec::new();
            for (k, p) in c.params.iter().enumerate() {
                conds.push(self.pat_test(&p.pat, &pnames[k].0));
            }
            self.open_if(Ex::and(conds.into_iter().filter(|c| *c != Ex::bool(true)).collect()));
            self.push(ScopeKind::Block);
            for (k, p) in c.params.iter().enumerate() {
                self.bind_top(&p.pat, &pnames[k].0, &pnames[k].1);
            }
            let guarded = if let Some(gx) = &c.guard {
                self.push(ScopeKind::Stmt);
                let v = self.expr(gx);
                let gc = self.val_as(&v, &Ty::Bool);
                let gv = self.decl(&Ty::Bool, gc);
                self.pop();
                self.open_if(gv);
                true
            } else {
                false
            };
            self.capture_olds(fid, c);
            self.call_and_check(fid, body_name, &ps, ret, hdr, Some(c));
            if guarded {
                self.close();
            }
            self.pop();
            self.close();
        }
        self.call_and_check(fid, body_name, &ps, ret, hdr, None);
        self.end(name);
    }

    /// Capture (as owned locals of the current scope) the `old(e)` values in `c`'s `ensures`.
    fn capture_olds(&mut self, fid: FnId, c: &'a crate::ast::FnClause) {
        let tp = self.tp;
        let mut old_exprs: Vec<&'a Expr> = Vec::new();
        for e in &c.ensures {
            collect_olds(e, &tp.fns[fid].olds, &mut old_exprs);
        }
        for e in old_exprs {
            let v = self.expr(e);
            let ty = v.ty.clone();
            let o = self.own_as(v, &ty);
            let n = self.decl(&ty, o);
            self.register(&n, &ty);
            self.f.olds.insert(e.id, n);
        }
    }

    /// In the `ensures` wrapper: call the body, check the header's and `clause`'s `ensures` on
    /// its result, release everything and return it.
    fn call_and_check(&mut self, fid: FnId, body_name: FuncId, ps: &[Ex], ret: &Ty, hdr: Option<&'a crate::ast::FnClause>, clause: Option<&'a crate::ast::FnClause>) {
        let call = self.g.call(body_name, ps.to_vec());
        let r = self.decl(ret, call);
        let is_res = matches!(ret, Ty::Res(..));
        if let Some(l) = self.tp.fns[fid].result_local {
            let (c, t) = match ret {
                Ty::Res(t, _) => (self.fld(&r, Sel::F(1)), (**t).clone()),
                t => (r.clone(), t.clone()),
            };
            self.bind_name(l, Slot { c, ty: t });
        }
        if is_res {
            self.open_if(self.fld(&r, Sel::F(0)));
        }
        for e in hdr.into_iter().chain(clause).flat_map(|c| &c.ensures) {
            self.push(ScopeKind::Stmt);
            let v = self.expr(e);
            let cv = self.val_as(&v, &Ty::Bool);
            let b = self.decl(&Ty::Bool, cv);
            self.pop();
            let loc = self.loc(e.span);
            let text = Ex::cstr(&self.g.span_text(self.m, e.span));
            self.open_if(b.not());
            self.do_(Ex::rt("duck_ensures_fail", vec![loc, text], MTy::Void));
            self.close();
        }
        if is_res {
            self.close();
        }
        self.cleanup_from(0);
        self.emit(Stmt::Ret(Some(r)));
    }

    fn emit_test(&mut self, body: &'a Block) {
        let outer = self.g.inst_fn(self.inst);
        let base = self.g.prog.funcs[outer as usize].name.clone();
        let ret = Ty::res(Ty::unit(), self.g.err_ty());
        let inner = self.g.declare(format!("{base}_body"), Vec::new(), d(&ret), Abi::Duck);
        self.begin_fn(inner, ret.clone());
        if let BodyRef::Test(t) = self.tp.instances[self.inst].body {
            let n = format!("test \"{}\"", self.tp.tests[t].name);
            self.name_fn(inner, &n);
            self.dbg_begin(n);
        }
        self.push(ScopeKind::Block);
        for s in &body.stmts {
            self.stmt(s);
        }
        self.cleanup_from(0);
        let ok = self.ok(&ret, Ex::unit());
        self.emit(Stmt::Ret(Some(ok)));
        self.f.scopes.clear();
        self.end(inner);
        // the registered test: NULL on success, else the owned error
        self.begin_fn(outer, Ty::unit());
        let r = self.f.b.decl(self.g.call(inner, vec![]));
        let et = d(&self.g.err_ty());
        let e = Ex::cond(self.fld(&r, Sel::F(0)), Ex::zero(et), self.fld(&r, Sel::F(2)));
        self.emit(Stmt::Ret(Some(e)));
        self.end(outer);
    }

    fn emit_const(&mut self, value: &'a Expr) {
        let f = self.g.inst_fn(self.inst);
        let BodyRef::Const(c) = self.tp.instances[self.inst].body else { unreachable!() };
        let ty = self.tp.consts[c].ty.clone();
        self.begin_fn(f, ty.clone());
        self.push(ScopeKind::Block);
        let v = self.expr(value);
        self.ret_val(v, &ty);
        self.f.scopes.clear();
        let z = self.g.zero(&ty);
        self.emit(Stmt::Ret(Some(z)));
        self.end(f);
    }

    // ---- tail calls ----

    /// Is `c`'s body (in tail position) a self call that can become a jump?
    fn body_has_tail_call(&self, c: &crate::ast::FnClause) -> bool {
        match &c.body {
            Some(FnBody::Expr(e)) => self.tail_scan(e),
            Some(FnBody::Block(b)) => b.stmts.iter().any(|s| self.any_return_tail(s)) || b.stmts.last().is_some_and(|s| self.tail_scan(s)),
            _ => false,
        }
    }

    fn any_return_tail(&self, e: &Expr) -> bool {
        let mut found = false;
        crate::check::visit_expr(e, &mut |x| {
            if let EK::Return(Some(v)) = &x.kind
                && self.tail_scan(v)
            {
                found = true;
            }
        });
        found
    }

    fn tail_scan(&self, e: &Expr) -> bool {
        match &e.kind {
            EK::Block(b) => b.stmts.last().is_some_and(|s| self.tail_scan(s)),
            EK::If { then, els, .. } => then.stmts.last().is_some_and(|s| self.tail_scan(s)) || els.as_ref().is_some_and(|x| self.tail_scan(x)),
            EK::Match { arms, .. } => arms.iter().any(|a| self.tail_scan(&a.body)),
            EK::Return(Some(x)) => self.tail_scan(x),
            EK::Call { .. } | EK::MethodCall { .. } | EK::Pipe { .. } => self.is_self_tail_call(e),
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
            let inner = if let EK::Ref(i) = &x.kind { &**i } else { *x };
            match self.t.names.get(&inner.id) {
                Some(NameRef::Local(l)) if matches!(inner.kind, EK::Name(_)) && self.f.var_params.contains(l) => {}
                _ => return false,
            }
        }
        true
    }

    fn tail_call(&mut self, e: &Expr) -> Val {
        let call = &self.t.calls[&e.id];
        let exprs = arg_exprs(e);
        let (params, label) = {
            let t = self.f.tail.as_ref().unwrap();
            (t.params.clone(), t.label)
        };
        let mut news = Vec::new();
        for (k, a) in call.args.iter().enumerate() {
            let x = exprs.iter().find(|x| x.id == a.node).copied().expect("argument");
            if a.by_ref {
                let inner = if let EK::Ref(i) = &x.kind { &**i } else { x };
                let EK::Name(_) = &inner.kind else { unreachable!() };
                let Some(NameRef::Local(l)) = self.t.names.get(&inner.id) else { unreachable!() };
                let slot = self.f.locals[l].clone();
                news.push(slot.c.addr());
            } else {
                let v = self.expr(x);
                let o = self.own_as(v, &params[k].1);
                let n = self.decl(&params[k].1, o);
                news.push(n);
            }
        }
        self.cleanup_from(1);
        for (k, (p, ty, var)) in params.iter().enumerate() {
            if !*var
                && let Some(r) = self.g.release(ty, p)
            {
                self.emit(r);
            }
            self.set(p.clone(), news[k].clone());
        }
        self.emit(Stmt::Goto(label));
        Val::never()
    }

    // ---- statements and blocks ----

    fn stmt(&mut self, e: &Expr) {
        self.dbg_hook(e.span);
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
            self.dbg_hook(s.span);
            let v = self.expr_t(s, tail);
            if v.is_never() {
                out = v;
            } else if Self::has_value(&v.ty) || self.g.needs_rc(&v.ty) {
                let ty = v.ty.clone();
                let h = self.hold(v);
                out = Val { c: h, ty, owned: true };
            } else {
                out = v;
                if !out.c.is_simple() {
                    let ty = out.ty.clone();
                    let c = out.c.clone();
                    out.c = self.decl(&ty, c);
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
                    let o = self.own(v);
                    let e = self.some(&ty, o);
                    v = self.tmp(&ty, e);
                }
                Coercion::WrapOk => {
                    let ty = Ty::res(v.ty.clone(), self.g.err_ty());
                    let o = self.own(v);
                    let e = self.ok(&ty, o);
                    v = self.tmp(&ty, e);
                }
                Coercion::ToAny(s) => {
                    let vid = self.tp.instances[self.inst].vtables.get(&node).copied();
                    let ty = Ty::Any(*s);
                    let vt = match vid {
                        Some(vid) => self.vtable(vid),
                        None => Ex::null(),
                    };
                    let src = v.ty.clone();
                    let o = self.own(v);
                    let b = self.g.box_new(&src, o);
                    let e = Ex::agg(d(&ty), vec![(Sel::F(0), b), (Sel::F(1), vt.cast(MTy::void_ptr()))]);
                    v = self.tmp(&ty, e);
                }
            }
        }
        v
    }

    fn expr_inner(&mut self, e: &Expr, tail: bool) -> Val {
        match &e.kind {
            EK::Lit(l) => self.lit(l, false),
            // units are erased: the literal's value
            EK::Measured { expr, .. } => self.expr_inner(expr, tail),
            EK::Interp(parts) => self.interp(parts),
            EK::Name(_) => self.name_ref(e),
            EK::Hole => {
                let ty = self.ty(e.id);
                let loc = self.loc(e.span);
                let exp = self.g.show_ty(&ty);
                self.g.note_hole(format!("{}:{}:{}", self.file, e.span.line, e.span.col), exp.clone());
                self.do_(Ex::rt("duck_hole", vec![loc, Ex::cstr(&exp)], MTy::Void));
                Val::never()
            }
            EK::Field { expr, name } => {
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
            EK::TupleField { expr, index } => {
                let b = self.expr(expr);
                if b.is_never() {
                    return Val::never();
                }
                let ty = self.ty(e.id);
                Val { c: self.fld(&b.c, Sel::F(*index)), ty, owned: false }
            }
            EK::Call { .. } | EK::MethodCall { .. } | EK::Pipe { .. } => self.call(e, None, tail),
            EK::Index { expr, index } => self.index(e, expr, index),
            EK::Slice { expr, lo, hi, inclusive } => {
                let x = self.expr(expr);
                let l = self.expr(lo);
                let h = self.expr(hi);
                let loc = self.loc(e.span);
                let hc = if *inclusive { Ex::rt("duck_add", vec![h.c.clone(), Ex::int(1), loc.clone()], MTy::D(Ty::Int)) } else { h.c.clone() };
                let ty = x.ty.clone();
                let f = if ty == Ty::Str { "duck_str_slice" } else { "duck_arr_slice" };
                let call = Ex::rt(f, vec![x.c, l.c, hc, loc], d(&ty));
                self.tmp(&ty, call)
            }
            EK::Unary { op, expr } => match op {
                UnOp::Not => {
                    let v = self.expr(expr);
                    let c = v.c.not();
                    self.tmp(&Ty::Bool, c)
                }
                UnOp::BitNot => {
                    let v = self.expr(expr);
                    let c = Ex::new(K::Un(UOp::BitNot, Box::new(v.c)), MTy::D(Ty::Int));
                    self.tmp(&Ty::Int, c)
                }
                UnOp::Neg => {
                    if let EK::Lit(l @ (Lit::Int(_) | Lit::Float(_))) = &expr.kind {
                        return self.lit(l, true);
                    }
                    let v = self.expr(expr);
                    if v.ty == Ty::Int {
                        let loc = self.loc(e.span);
                        let c = Ex::rt("duck_neg", vec![v.c, loc], MTy::D(Ty::Int));
                        self.tmp(&Ty::Int, c)
                    } else {
                        let c = Ex::new(K::Un(UOp::Neg, Box::new(v.c)), MTy::D(Ty::Float));
                        self.tmp(&Ty::Float, c)
                    }
                }
            },
            EK::Binary { op, lhs, rhs } => self.binary(e, *op, lhs, rhs),
            EK::Range { lo, hi, inclusive } => {
                let l = self.expr(lo);
                let h = self.expr(hi);
                let new = Ex::rt("duck_arr_new", vec![Ex::rt_global("duck_ops_int", MTy::Rt(Rt::ElemOps)), Ex::int(0)], d(&Ty::list(Ty::Int)));
                let xs = self.tmp(&Ty::list(Ty::Int), new);
                let i = self.decl(&Ty::Int, l.c);
                let hv = self.decl(&Ty::Int, h.c);
                self.f.b.open_loop(vec![Stmt::Set(i.clone(), Ex::bin(BOp::Add, i.clone(), Ex::int(1)))]);
                let op = if *inclusive { BOp::Le } else { BOp::Lt };
                self.open_if(Ex::bin(op, i.clone(), hv).not());
                self.emit(Stmt::Break);
                self.close();
                self.do_(Ex::rt("duck_arr_push", vec![xs.c.clone().addr(), i.addr()], MTy::Void));
                self.emit(Stmt::Continue);
                self.close();
                xs
            }
            EK::Is { expr, pat } => {
                let v = self.expr(expr);
                let vc = self.lvalue(&v, &v.ty.clone());
                let c = self.pat_test(pat, &vc);
                self.tmp(&Ty::Bool, c)
            }
            EK::Try(x) => self.try_(e, x),
            EK::Unwrap(x) => {
                let v = self.expr(x);
                if v.is_never() {
                    return v;
                }
                let loc = self.loc(e.span);
                let w = self.hold(v.clone());
                let ty = self.ty(e.id);
                self.open_if(self.fld(&w, Sel::F(0)).not());
                match v.ty {
                    Ty::Opt(_) => self.do_(Ex::rt("duck_unwrap_none", vec![loc], MTy::Void)),
                    _ => self.do_(Ex::rt("duck_unwrap_err", vec![loc, self.fld(&w, Sel::F(2))], MTy::Void)),
                }
                self.emit(Stmt::Unreachable);
                self.close();
                let val = self.fld(&w, Sel::F(1));
                self.adopt(&ty, val)
            }
            EK::OptChain { expr, name, args } => self.opt_chain(e, expr, name, args.is_some()),
            EK::Else { expr, arm } => self.else_expr(e, expr, arm),
            EK::Await(x) => self.await_(e, x),
            EK::Catch(x) => self.catch_(e, x),
            EK::AwaitAny(x) => self.await_any(e, x),
            EK::Ref(x) => self.expr(x),
            EK::Closure { params, body } => self.closure(e, params, body),
            EK::If { cond, then, els } => self.if_(e, cond, then, els.as_deref(), tail),
            EK::Match { scrut, arms } => self.match_(e, scrut, arms, tail),
            EK::Loop(b) => {
                let ty = self.ty(e.id);
                let r = if Self::has_value(&ty) { Some(self.zero_decl(&ty)) } else { None };
                self.f.b.open_loop(vec![]);
                self.cancel_point(e.span);
                self.push(ScopeKind::Block);
                let depth = self.f.scopes.len() - 1;
                self.f.loops.push(LoopCx { depth, result: r.clone().map(|r| (r, ty.clone())) });
                for s in &b.stmts {
                    self.stmt(s);
                }
                self.f.loops.pop();
                self.pop();
                self.close();
                match r {
                    Some(r) => self.reown(r, ty),
                    None if ty == Ty::Never => Val::never(),
                    None => Val::unit(),
                }
            }
            EK::While { cond, body } => {
                self.f.b.open_loop(vec![]);
                self.cancel_point(e.span);
                self.push(ScopeKind::Stmt);
                let c = self.expr(cond);
                let cc = self.val_as(&c, &Ty::Bool);
                let cv = self.decl(&Ty::Bool, cc);
                self.pop();
                self.open_if(cv.not());
                self.emit(Stmt::Break);
                self.close();
                self.push(ScopeKind::Block);
                let depth = self.f.scopes.len() - 1;
                self.f.loops.push(LoopCx { depth, result: None });
                for s in &body.stmts {
                    self.stmt(s);
                }
                self.f.loops.pop();
                self.pop();
                self.close();
                Val::unit()
            }
            EK::For { index, pat, iter, body } => {
                self.for_(e, index.as_ref(), pat, iter, body);
                Val::unit()
            }
            EK::Block(b) => self.block(b, tail),
            EK::Let { pat, value, els, .. } => {
                self.let_(e, pat, value, els.as_ref());
                Val::unit()
            }
            EK::Assign { op, target, value } => {
                self.assign(e, *op, target, value);
                Val::unit()
            }
            EK::Assert(x) => {
                self.assert_(x);
                Val::unit()
            }
            EK::Return(x) => {
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
            EK::Break(x) => {
                let lp = self.f.loops.last().map(|l| (l.depth, l.result.clone()));
                let Some((depth, result)) = lp else { return Val::never() };
                match x {
                    Some(x) => {
                        let v = self.expr(x);
                        if let Some((r, ty)) = &result {
                            let o = self.own_as(v, ty);
                            self.set(r.clone(), o);
                        }
                    }
                    // a bare `break` out of a `loop` whose value is `()!` / `()?`: the checker
                    // recorded the auto-wrap of `()` on this node
                    None => {
                        if let (Some((r, ty)), Some(cs)) = (&result, self.t.coercions.get(&e.id)) {
                            let cs = cs.clone();
                            let v = self.coerce(Val::unit(), &cs, e.id);
                            let o = self.own_as(v, ty);
                            self.set(r.clone(), o);
                        }
                    }
                }
                self.cleanup_from(depth);
                self.emit(Stmt::Break);
                Val::never()
            }
            EK::Continue => {
                if let Some(depth) = self.f.loops.last().map(|l| l.depth) {
                    self.cleanup_from(depth);
                    self.emit(Stmt::Continue);
                }
                Val::never()
            }
            EK::Peek(x) => {
                let v = self.expr(x);
                let shown = self.show_of(x.id, &v);
                let s = self.decl(&Ty::Str, shown);
                let loc = Ex::cstr(&format!("{}:{}", self.file, e.span.line));
                let text = Ex::cstr(&self.g.span_text(self.m, x.span));
                self.do_(Ex::rt("duck_peek", vec![loc, text, s.clone()], MTy::Void));
                self.do_(Ex::rt("duck_release", vec![s], MTy::Void));
                v
            }
            EK::Struct { .. } => self.struct_lit(e),
            EK::List(xs) => {
                let ty = self.ty(e.id);
                let Ty::List(et) = &ty else { return Val::never() };
                let et = (**et).clone();
                let ops = self.g.ops(&et);
                let new = Ex::rt("duck_arr_new", vec![ops, Ex::int(xs.len() as i64)], d(&ty));
                if xs.is_empty() {
                    return self.tmp(&ty, new);
                }
                let mut parts = Vec::new();
                for x in xs {
                    let v = self.expr(x);
                    let c = self.val_as(&v, &et);
                    parts.push(c);
                }
                // the array is built after its elements are evaluated (like a C array literal)
                let a = self.tmp(&ty, new);
                for c in parts {
                    let el = if c.is_place() { c } else { self.decl(&et, c) };
                    self.do_(Ex::rt("duck_arr_push", vec![a.c.clone().addr(), el.addr()], MTy::Void));
                }
                a
            }
            EK::Map(es) => {
                let ty = self.ty(e.id);
                let Ty::Map(kt, vt) = &ty else { return Val::unit() };
                let (kt, vt) = ((**kt).clone(), (**vt).clone());
                let (ko, vo) = (self.g.ops(&kt), self.g.ops(&vt));
                let new = Ex::rt("duck_map_new", vec![ko, vo], d(&ty));
                let m = self.tmp(&ty, new);
                for (k, v) in es {
                    let kv = self.expr(k);
                    let kc = self.lvalue(&kv, &kt);
                    let vv = self.expr(v);
                    let vc = self.lvalue(&vv, &vt);
                    self.do_(Ex::rt("duck_map_set", vec![m.c.clone().addr(), kc.addr(), vc.addr()], MTy::Void));
                }
                m
            }
            EK::Tuple(xs) => {
                if xs.is_empty() {
                    return Val::unit();
                }
                let ty = self.ty(e.id);
                let Ty::Tuple(ts) = &ty else { return Val::never() };
                let ts = ts.clone();
                let vals: Vec<Val> = xs.iter().map(|x| self.expr(x)).collect();
                let mut parts = Vec::new();
                for (i, (v, t)) in vals.into_iter().zip(&ts).enumerate() {
                    parts.push((Sel::F(i as u32), self.own_as(v, t)));
                }
                self.tmp(&ty, Ex::agg(d(&ty), parts))
            }
        }
    }

    fn lit(&mut self, l: &Lit, neg: bool) -> Val {
        match l {
            Lit::Int(n) => {
                let v = if neg { (*n as i64).wrapping_neg() } else { *n as i64 };
                Val::plain(Ex::int(v), Ty::Int)
            }
            Lit::Float(x) => {
                let x = if neg { -x } else { *x };
                Val::plain(Ex::float(x), Ty::Float)
            }
            Lit::Bool(b) => Val::plain(Ex::bool(*b), Ty::Bool),
            Lit::Char(c) => Val::plain(Ex::int_as(*c as i64, MTy::D(Ty::Char)), Ty::Char),
            Lit::Str(s) => {
                let g = self.g.lit(s);
                Val::plain(g, Ty::Str)
            }
        }
    }

    fn closure_val(&self, f: FuncId, fnty: &Ty, env: Ex) -> Ex {
        Ex::agg(d(fnty), vec![(Sel::F(0), Ex::fn_addr(f)), (Sel::F(1), env)])
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
                Val::plain(self.g.call(g, vec![]), ty)
            }
            NameRef::Fn { func, .. } => {
                let ty = self.ty(e.id);
                let target = self.tp.instances[self.inst].resolved.get(&e.id).cloned();
                let Some(target) = target else { return Val::never() };
                let w = self.fn_value(&target, Some(func), &ty);
                Val::plain(self.closure_val(w, &ty, Ex::zero(MTy::obj_ptr())), ty)
            }
            NameRef::Variant(v) => {
                let ty = self.ty(e.id);
                match &ty {
                    Ty::Fn(..) => {
                        let target = Target::Variant { def: v.def, index: v.index };
                        let w = self.fn_value(&target, None, &ty);
                        Val::plain(self.closure_val(w, &ty, Ex::zero(MTy::obj_ptr())), ty)
                    }
                    _ => {
                        let c = self.g.variant_new(&ty, v.index, vec![]);
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
        if let EK::Call { callee, args } = &e.kind
            && let EK::Name(n) = &callee.kind
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
                EK::Call { callee, .. } | EK::Pipe { callee, .. } => Some(&**callee),
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
                let inner = if let EK::Ref(i) = &x.kind { &**i } else { x };
                let (lv, ty) = self.place(inner);
                args.push(ArgV::Addr(lv.addr(), ty));
            } else {
                let mut v = self.expr(x);
                if any_ref && !v.owned && !v.c.is_var() {
                    let ty = v.ty.clone();
                    let c = self.val_as(&v, &ty);
                    let n = self.decl(&ty, c);
                    v = Val { c: n, ty, owned: false };
                }
                args.push(ArgV::Val(v));
            }
        }
        let func = match &call.callee {
            TCallee::Fn { func, .. } => Some(*func),
            _ => None,
        };
        let mut ret = self.ty(e.id);
        // `x?.m()`: the node's type is the chain's `T?`; the call itself returns the member
        if let EK::OptChain { .. } = e.kind
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
        self.call_target(&target, func, args, &ret, loc, callee_val)
    }

    /// Call a resolved target with evaluated arguments; returns the (owned) result.
    fn call_target(&mut self, target: &Target, func: Option<FnId>, args: Vec<ArgV>, ret: &Ty, loc: Ex, callee: Option<Val>) -> Val {
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
                let call = self.g.call(f, cs);
                if let BodyRef::Fn(fid) = tp.instances[*i].body
                    && self.g.traced(tp.fns[fid].module)
                {
                    self.trace_site(loc);
                }
                self.result(&rt, call)
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
                                p.clone().deref(d(ty))
                            }
                        }
                        ArgV::Val(v) => {
                            let ty = v.ty.clone();
                            if generic {
                                let lv = self.lvalue(v, &ty);
                                lv.addr().cast(MTy::void_ptr())
                            } else {
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
                        let out = self.zero_decl(&ot);
                        cs.push(out.clone().addr().cast(MTy::void_ptr()));
                        if *wants_loc {
                            cs.push(loc);
                        }
                        if let Ty::Opt(_) = ret {
                            let call = Ex::rt(symbol, cs, MTy::Bool);
                            let ok = self.decl(&Ty::Bool, call);
                            let e = Ex::agg(d(ret), vec![(Sel::F(0), ok.cast(MTy::Bool)), (Sel::F(1), out)]);
                            self.tmp(ret, e)
                        } else {
                            self.do_(Ex::rt(symbol, cs, MTy::Void));
                            self.reown(out, ot)
                        }
                    }
                    None => {
                        if *wants_loc {
                            cs.push(loc);
                        }
                        if *ret == Ty::Never {
                            // `proc.exit` doesn't return: release what this function owns first,
                            // as a `return` would, so the leak check it runs is exact.
                            self.cleanup_from(0);
                        }
                        if ret.is_unit() && gret.is_unit() {
                            self.do_(Ex::rt(symbol, cs, MTy::Void));
                            Val::unit()
                        } else if *ret == Ty::Never {
                            self.do_(Ex::rt(symbol, cs, MTy::Void));
                            Val::never()
                        } else {
                            self.result(ret, Ex::rt(symbol, cs, d(ret)))
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
                let mut cs = vec![self.fld(&recv.c, Sel::F(0))];
                let mut pts = vec![MTy::obj_ptr()];
                for (a, pt) in it.zip(m.params.iter().skip(1)) {
                    let pt = self.g.method_ty(pt, *shape);
                    pts.push(d(&pt));
                    cs.push(match a {
                        ArgV::Val(v) => self.val_as(&v, &pt),
                        ArgV::Addr(p, _) => p,
                    });
                }
                let code = self.fld(&recv.c, Sel::F(1)).cast(MTy::ptr(MTy::Agg(vt))).deref(MTy::Agg(vt)).field(Sel::F(*method as u32), MTy::Code);
                let rt = self.g.method_ty(&m.ret, *shape);
                let call = Ex::new(K::Call(Callee::Indirect(Box::new(code), pts), cs), d(&rt));
                self.result(&rt, call)
            }
            Target::Variant { index, .. } => {
                let mut fields = Vec::new();
                let layout = self.g.info.enum_layout(ret);
                for (k, a) in args.into_iter().enumerate() {
                    let ft = if self.g.is_value(ret) {
                        a_ty(&a)
                    } else {
                        layout.get(*index).and_then(|l| l.get(k)).map(|x| x.0.clone()).unwrap_or_else(|| a_ty(&a))
                    };
                    match a {
                        ArgV::Val(v) => fields.push(self.own_as(v, &ft)),
                        ArgV::Addr(p, t) => fields.push(p.deref(d(&t))),
                    }
                }
                let c = self.g.variant_new(ret, *index, fields);
                self.tmp(ret, c)
            }
            Target::Closure => {
                let Some(c) = callee else { return Val::never() };
                let Ty::Fn(ps, r) = c.ty.clone() else { return Val::never() };
                let mut pts = vec![MTy::obj_ptr()];
                let mut cs = vec![self.fld(&c.c, Sel::F(1))];
                for (a, pt) in args.iter().zip(&ps) {
                    pts.push(d(pt));
                    cs.push(match a {
                        ArgV::Val(v) => self.val_as(v, pt),
                        ArgV::Addr(p, _) => p.clone(),
                    });
                }
                let code = self.fld(&c.c, Sel::F(0));
                let call = Ex::new(K::Call(Callee::Indirect(Box::new(code), pts), cs), d(&r));
                self.result(&r, call)
            }
        }
    }

    /// The owned result of a call expression of Duck type `ty`.
    fn result(&mut self, ty: &Ty, call: Ex) -> Val {
        if ty.is_unit() {
            self.do_(call);
            return Val::unit();
        }
        if *ty == Ty::Never {
            self.do_(call);
            return Val::never();
        }
        self.tmp(ty, call)
    }

    fn intrinsic(&mut self, which: Intrinsic, ty: &Ty, args: Vec<ArgV>, ret: &Ty) -> Val {
        let vals: Vec<Val> = args
            .into_iter()
            .map(|a| match a {
                ArgV::Val(v) => v,
                ArgV::Addr(p, t) => Val::plain(p.deref(d(&t)), t),
            })
            .collect();
        match which {
            Intrinsic::Show => {
                let v = &vals[0];
                let s = self.show_value(ty, v);
                self.adopt(&Ty::Str, s)
            }
            Intrinsic::Eq => {
                let (a, b) = (self.val_as(&vals[0], ty), self.val_as(&vals[1], ty));
                let c = self.g.eq_expr(ty, a, b);
                self.tmp(&Ty::Bool, c)
            }
            Intrinsic::Cmp => {
                let (a, b) = (self.val_as(&vals[0], ty), self.val_as(&vals[1], ty));
                let c = self.g.cmp_expr(ty, a, b);
                self.tmp(&Ty::Int, c)
            }
            Intrinsic::ToValue => {
                let f = self.g.tov_fn(ty);
                let a = self.val_as(&vals[0], ty);
                let c = self.g.call_ref(&f, vec![a], d(ret));
                self.adopt(ret, c)
            }
            Intrinsic::FromValue => {
                let t = match ret {
                    Ty::Res(t, _) => (**t).clone(),
                    t => t.clone(),
                };
                let f = self.g.fromv_fn(&t);
                let c = self.g.call_ref(&f, vec![vals[0].c.clone()], d(ret));
                self.adopt(ret, c)
            }
            Intrinsic::Some => {
                let it = match ret {
                    Ty::Opt(t) => (**t).clone(),
                    t => t.clone(),
                };
                let o = self.own_as(vals[0].clone(), &it);
                let e = self.some(ret, o);
                self.tmp(ret, e)
            }
            Intrinsic::IntToFloat => {
                let c = vals[0].c.clone().cast(MTy::D(Ty::Float));
                self.tmp(&Ty::Float, c)
            }
            Intrinsic::CharToInt => {
                let c = vals[0].c.clone().cast(MTy::D(Ty::Int));
                self.tmp(&Ty::Int, c)
            }
            Intrinsic::Fail => Val::never(),
        }
    }

    /// `Show` text (an owned `str` expression) of a value of type `ty`, top-level form.
    fn show_value(&mut self, ty: &Ty, v: &Val) -> Ex {
        let a = self.val_as(v, ty);
        match self.g.show_fn(ty) {
            Some(f) => self.g.call_ref(&f, vec![a], MTy::D(Ty::Str)),
            None => Ex::rt("duck_str_lit", vec![Ex::cstr(&format!("<{}>", self.g.show_ty(ty)))], MTy::D(Ty::Str)),
        }
    }

    /// The show of an interpolation part / peek operand (via `Instance::shows`).
    fn show_of(&mut self, node: u32, v: &Val) -> Ex {
        let target = self.tp.instances[self.inst].shows.get(&node).cloned();
        let a = v.c.clone();
        match target {
            Some(Target::Instance(i)) => {
                let f = self.g.inst_fn(i);
                self.g.call(f, vec![a])
            }
            Some(Target::Extern { symbol, .. }) => Ex::rt(&symbol, vec![a], MTy::D(Ty::Str)),
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
        let args_drop = self.g.memo2[&format!("thunkdrop{i}")];
        // the task's heap, with deep copies of the arguments in it (it shares nothing with us)
        let heap = self.f.b.decl(Ex::rt("duck_heap_new", vec![], MTy::void_ptr()));
        let vals: Vec<Ex> = args
            .into_iter()
            .map(|a| match a {
                ArgV::Val(v) => self.f.b.decl(v.c),
                ArgV::Addr(p, _) => p,
            })
            .collect();
        let old = self.f.b.decl(Ex::rt("duck_heap_switch", vec![heap.clone()], MTy::void_ptr()));
        let mut fields = Vec::new();
        for (k, (v, (pt, var))) in vals.into_iter().zip(&ps).enumerate() {
            let c = if *var { v } else { self.g.copy_ex(pt, v) };
            fields.push((Sel::F(k as u32), c));
        }
        let a = self.f.b.decl(Ex::agg(MTy::Agg(argty), fields));
        self.do_(Ex::rt("duck_heap_switch", vec![old], MTy::void_ptr()));
        // `duck run --live` narrows what the task can reach to its closure, when it gets exactly
        // one and nothing else that could hold a closure (sup children: `go(f)`)
        let closures: Vec<usize> = ps.iter().enumerate().filter(|(_, (t, var))| !*var && matches!(t, Ty::Fn(..))).map(|(k, _)| k).collect();
        let others_plain = ps.iter().all(|(t, var)| matches!(t, Ty::Fn(..)) || (!*var && !self.g.holds_fn(t)));
        let hint = match closures.as_slice() {
            [k] if others_plain => {
                let clo = self.g.fld(&a, Sel::F(*k as u32));
                self.g.fld(&clo, Sel::F(0)).cast(MTy::void_ptr())
            }
            _ => Ex::zero(MTy::void_ptr()),
        };
        let ops = if self.g.needs_rc(&rt) { self.g.ops(&rt) } else { Ex::zero(MTy::ptr(MTy::Rt(Rt::ElemOps))) };
        let call = Ex::rt(
            "duck_task_spawn",
            vec![Ex::fn_addr(thunk), a.addr().cast(MTy::void_ptr()), Ex::size_of(MTy::Agg(argty)), Ex::size_of(d(&rt)), ops, heap, Ex::fn_addr(args_drop), hint],
            d(ret),
        );
        self.tmp(ret, call)
    }

    /// The thunk that runs instance `i` on a task thread: (thunk, argument aggregate).
    fn thunk(&mut self, i: InstId) -> (FuncId, super::AggId) {
        let key = format!("thunk{i}");
        if let Some(&n) = self.g.memo2.get(&key) {
            return (n, self.g.memo2[&format!("thunkargs{i}")]);
        }
        let ps = self.g.inst_params(i);
        let rt = self.g.inst_ret(i);
        let f = self.g.inst_fn(i);
        let fields: Vec<MTy> = ps.iter().map(|(pt, var)| if *var { MTy::ptr(d(pt)) } else { d(pt) }).collect();
        let argty = self.g.agg(format!("dk_thunk{i}_args"), fields);
        let n = self.g.declare(format!("dk_thunk{i}"), vec![MTy::void_ptr(), MTy::void_ptr()], MTy::Void, Abi::C);
        self.g.memo2.insert(key, n);
        self.g.memo2.insert(format!("thunkargs{i}"), argty);
        let (mut b, pv) = self.g.body_for(n);
        let x = pv[0].clone().cast(MTy::ptr(MTy::Agg(argty))).deref(MTy::Agg(argty));
        let mut call = Vec::new();
        let mut rels = Vec::new();
        for (k, (pt, var)) in ps.iter().enumerate() {
            let a = self.g.fld(&x, Sel::F(k as u32));
            if !*var
                && let Some(r) = self.g.release(pt, &a)
            {
                rels.push(r);
            }
            call.push(a);
        }
        let c = self.g.call(f, call);
        b.set(pv[1].clone().cast(MTy::ptr(d(&rt))).deref(d(&rt)), c);
        for r in rels {
            b.emit(r);
        }
        self.g.define(n, b);
        // what the thunk releases after the call, for a task that crashes before that: its
        // arguments' handles (a channel, a connection) aren't in its heap
        let drop = self.g.declare(format!("dk_thunk{i}_drop"), vec![MTy::void_ptr()], MTy::Void, Abi::C);
        self.g.memo2.insert(format!("thunkdrop{i}"), drop);
        let (mut b, pv) = self.g.body_for(drop);
        let x = pv[0].clone().cast(MTy::ptr(MTy::Agg(argty))).deref(MTy::Agg(argty));
        for (k, (pt, var)) in ps.iter().enumerate() {
            let a = self.g.fld(&x, Sel::F(k as u32));
            if !*var
                && let Some(r) = self.g.release(pt, &a)
            {
                b.emit(r);
            }
        }
        self.g.define(drop, b);
        (n, argty)
    }

    /// A function usable as a closure (`R f(DuckEnv *, args...)`) that calls `target`.
    fn fn_value(&mut self, target: &Target, func: Option<FnId>, fty: &Ty) -> FuncId {
        let key = format!("fv{target:?}/{fty:?}");
        if let Some(&n) = self.g.memo2.get(&key) {
            return n;
        }
        let Ty::Fn(ps, r) = fty.clone() else { panic!("fn_value of a non-function") };
        let r = *r;
        let k = self.g.fresh();
        let mut pts = vec![MTy::obj_ptr()];
        pts.extend(ps.iter().map(d));
        let n = self.g.declare(format!("dk_fv{k}"), pts, d(&r), Abi::Duck);
        self.g.memo2.insert(key, n);
        let pv = self.begin_fn(n, r.clone());
        self.push(ScopeKind::Block);
        let args = ps.iter().enumerate().map(|(k, p)| ArgV::Val(Val::plain(pv[k + 1].clone(), p.clone()))).collect();
        let v = self.call_target(target, func, args, &r, Ex::cstr("<fn>"), None);
        if r.is_unit() || r == Ty::Never {
            self.cleanup_from(0);
            self.emit(Stmt::Ret(Some(Ex::zero(d(&r)))));
        } else {
            self.ret_val(v, &r);
        }
        self.end(n);
        n
    }

    /// The vtable of a conversion to `any S` (by vtable id); returns its address.
    fn vtable(&mut self, vid: usize) -> Ex {
        let key = format!("vt{vid}");
        if let Some(&g) = self.g.memo2.get(&key) {
            return Ex::new(K::GlobalAddr(g), MTy::void_ptr());
        }
        let vt = self.tp.vtables[vid].clone();
        let st = self.g.vt_struct(vt.shape);
        let g = self.g.global(format!("dk_vt{vid}"), MTy::Agg(st), None, true);
        self.g.memo2.insert(key, g);
        let sh = self.tp.defs.shapes[vt.shape].clone();
        let mut ms = Vec::new();
        for (k, (m, target)) in sh.methods.iter().zip(&vt.methods).enumerate() {
            let r = self.g.method_ty(&m.ret, vt.shape);
            let mut pts = vec![MTy::obj_ptr()];
            for p in m.params.iter().skip(1) {
                let pt = self.g.method_ty(p, vt.shape);
                pts.push(d(&pt));
            }
            let mn = self.g.declare(format!("dk_vt{vid}_m{k}"), pts, d(&r), Abi::Duck);
            let pv = self.begin_fn(mn, r.clone());
            self.push(ScopeKind::Block);
            let recv = self.g.unbox(&vt.ty, pv[0].clone());
            let mut args = vec![ArgV::Val(Val::plain(recv, vt.ty.clone()))];
            for (j, p) in m.params.iter().enumerate().skip(1) {
                let pt = self.g.method_ty(p, vt.shape);
                args.push(ArgV::Val(Val::plain(pv[j].clone(), pt)));
            }
            let func = match target {
                Target::Instance(i) => match self.tp.instances[*i].body {
                    BodyRef::Fn(f) => Some(f),
                    _ => None,
                },
                _ => None,
            };
            let v = self.call_target(target, func, args, &r, Ex::cstr("<vtable>"), None);
            if r.is_unit() {
                self.cleanup_from(0);
                self.emit(Stmt::Ret(Some(Ex::zero(d(&r)))));
            } else {
                self.ret_val(v, &r);
            }
            self.end(mn);
            ms.push((Sel::F(k as u32), Ex::fn_addr(mn)));
        }
        self.g.prog.globals[g as usize].init = Some(Ex::agg(MTy::Agg(st), ms));
        Ex::new(K::GlobalAddr(g), MTy::void_ptr())
    }

    fn fail(&mut self, e: &Expr, kind: &FailKind) -> Val {
        let x = match &e.kind {
            EK::Call { args, .. } => args.first(),
            EK::MethodCall { recv, .. } => Some(&**recv),
            EK::Pipe { lhs, .. } => Some(&**lhs),
            _ => None,
        };
        let Some(x) = x else { return Val::never() };
        let v = self.expr(x);
        let et = d(&self.g.err_ty());
        let err = match kind {
            FailKind::Message => Ex::rt("duck_err_new", vec![v.c], et),
            FailKind::Err => self.own(v),
            FailKind::Typed | FailKind::TypedToErr(_) => {
                let ty = v.ty.clone();
                let lv = self.lvalue(&v, &ty);
                let id = self.g.type_id(&ty);
                let ops = self.g.ops(&ty);
                Ex::rt("duck_err_typed", vec![Ex::int_as(id as i64, MTy::U32), lv.addr().cast(MTy::void_ptr()), ops, Ex::zero(MTy::D(Ty::Str))], et)
            }
        };
        let ety = self.g.err_ty();
        let en = self.decl(&ety, err);
        self.return_err(en);
        Val::never()
    }

    /// Return an owned `DuckErr *` from the current (fallible) function.
    fn return_err(&mut self, err: Ex) {
        let ret = self.f.ret.clone();
        self.cleanup_from(0);
        match ret {
            Ty::Res(..) => {
                let e = Ex::agg(d(&ret), vec![(Sel::F(2), err)]);
                self.emit(Stmt::Ret(Some(e)));
            }
            _ => {
                self.do_(Ex::rt("duck_release", vec![err], MTy::Void));
                let z = self.g.zero(&ret);
                self.emit(Stmt::Ret(Some(z)));
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
                let res = self.decl(&Ty::Bool, lc);
                self.open_if(if op == And { res.clone() } else { res.clone().not() });
                self.push(ScopeKind::Block);
                let rv = self.expr(r);
                let rc = self.val_as(&rv, &Ty::Bool);
                self.set(res.clone(), rc);
                self.pop();
                self.close();
                return Val::plain(res, Ty::Bool);
            }
            Eq | Ne | Lt | Le | Gt | Ge => {
                let lv = self.expr(l);
                let rv = self.expr(r);
                let c = self.compare(e, op, &lv, &rv);
                return self.tmp(&Ty::Bool, c);
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
            Ty::Int => {
                let c = int_op(op, a, b, loc);
                self.tmp(&Ty::Int, c)
            }
            Ty::Float => {
                let c = match op {
                    Add => Ex::bin(BOp::Add, a, b),
                    Sub => Ex::bin(BOp::Sub, a, b),
                    Mul => Ex::bin(BOp::Mul, a, b),
                    Div => Ex::bin(BOp::Div, a, b),
                    Rem => Ex::rt("duck_fmod", vec![a, b], MTy::D(Ty::Float)),
                    Pow => Ex::rt("duck_fpow", vec![a, b], MTy::D(Ty::Float)),
                    _ => Ex::float(0.0),
                };
                self.tmp(&Ty::Float, c)
            }
            Ty::Str => {
                let c = Ex::rt("duck_str_concat", vec![a, b], MTy::D(Ty::Str));
                self.tmp(&Ty::Str, c)
            }
            t @ Ty::List(_) => {
                let c = Ex::rt("duck_arr_concat", vec![a, b], d(&t));
                self.tmp(&t, c)
            }
            _ => Val::never(),
        }
    }

    /// A boolean expression for a comparison of two lowered operands.
    fn compare(&mut self, e: &Expr, op: BinOp, l: &Val, r: &Val) -> Ex {
        use BinOp::*;
        let rel = |raw: Ex| match op {
            Eq => raw,
            Ne => raw.not(),
            Lt => Ex::bin(BOp::Lt, raw, Ex::int(0)),
            Le => Ex::bin(BOp::Le, raw, Ex::int(0)),
            Gt => Ex::bin(BOp::Gt, raw, Ex::int(0)),
            _ => Ex::bin(BOp::Ge, raw, Ex::int(0)),
        };
        let is_eq = matches!(op, Eq | Ne);
        if self.t.calls.contains_key(&e.id) {
            let target = self.tp.instances[self.inst].resolved.get(&e.id).cloned();
            let ty = l.ty.clone();
            let (a, b) = (self.val_as(l, &ty), self.val_as(r, &ty));
            let rty = if is_eq { MTy::D(Ty::Bool) } else { MTy::D(Ty::Int) };
            let raw = match target {
                Some(Target::Instance(i)) => {
                    let f = self.g.inst_fn(i);
                    self.g.call(f, vec![a, b])
                }
                Some(Target::Extern { symbol, .. }) => Ex::rt(&symbol, vec![a, b], rty),
                Some(Target::Intrinsic { ty, .. }) | Some(Target::Derived { ty, .. }) => {
                    if is_eq {
                        self.g.eq_expr(&ty, a, b)
                    } else {
                        self.g.cmp_expr(&ty, a, b)
                    }
                }
                _ => {
                    if is_eq {
                        self.g.eq_expr(&ty, a, b)
                    } else {
                        self.g.cmp_expr(&ty, a, b)
                    }
                }
            };
            return rel(raw);
        }
        let ty = if l.is_never() { r.ty.clone() } else { l.ty.clone() };
        let (a, b) = (self.val_as(l, &ty), self.val_as(r, &ty));
        let bop = match op {
            Eq => BOp::Eq,
            Ne => BOp::Ne,
            Lt => BOp::Lt,
            Le => BOp::Le,
            Gt => BOp::Gt,
            _ => BOp::Ge,
        };
        match ty {
            Ty::Int | Ty::Float | Ty::Char | Ty::Bool => Ex::bin(bop, a, b),
            Ty::Str => match op {
                Eq => Ex::rt("duck_str_eq", vec![a, b], MTy::D(Ty::Bool)),
                Ne => Ex::rt("duck_str_eq", vec![a, b], MTy::D(Ty::Bool)).not(),
                _ => Ex::bin(bop, Ex::rt("duck_str_cmp", vec![a, b], MTy::I32), Ex::int_as(0, MTy::I32)),
            },
            Ty::Never => Ex::bool(false),
            Ty::Tuple(ts) if ts.is_empty() => Ex::bool(matches!(op, Eq | Le | Ge)),
            t => {
                let raw = if is_eq { self.g.eq_expr(&t, a, b) } else { self.g.cmp_expr(&t, a, b) };
                rel(raw)
            }
        }
    }

    fn index(&mut self, e: &Expr, x: &Expr, i: &Expr) -> Val {
        let xv = self.expr(x);
        let iv = self.expr(i);
        let loc = self.loc(e.span);
        match xv.ty.clone() {
            Ty::List(et) => {
                let el = Ex::rt("duck_arr_at", vec![xv.c, iv.c, loc], MTy::void_ptr()).cast(MTy::ptr(d(&et))).deref(d(&et));
                let el = self.f.b.decl(el);
                let v = Val::plain(el, (*et).clone());
                let o = self.own(v);
                self.adopt(&et, o)
            }
            Ty::Map(kt, vt) => {
                let k = self.lvalue(&iv, &kt);
                let p = Ex::rt("duck_map_at", vec![xv.c, k.addr().cast(MTy::void_ptr()), loc], MTy::void_ptr()).cast(MTy::ptr(d(&vt))).deref(d(&vt));
                let p = self.f.b.decl(p);
                let v = Val::plain(p, (*vt).clone());
                let o = self.own(v);
                self.adopt(&vt, o)
            }
            Ty::Str => {
                let c = Ex::rt("duck_str_char_at", vec![xv.c, iv.c, loc], MTy::D(Ty::Char));
                self.tmp(&Ty::Char, c)
            }
            _ => Val::never(),
        }
    }

    // ---- places ----

    /// The place of a place expression (making containers on the path unique), and its type.
    fn place(&mut self, e: &Expr) -> (Ex, Ty) {
        match &e.kind {
            EK::Name(_) => {
                if let Some(NameRef::Local(l)) = self.t.names.get(&e.id)
                    && let Some(s) = self.f.locals.get(l)
                {
                    return (s.c.clone(), s.ty.clone());
                }
                self.place_tmp(e)
            }
            EK::Field { expr, name } => {
                let (b, bt) = self.place(expr);
                self.place_field(e, &b, &bt, &name.name)
            }
            EK::TupleField { expr, index } => {
                let (b, bt) = self.place(expr);
                let ft = match &bt {
                    Ty::Tuple(ts) => ts.get(*index as usize).cloned().unwrap_or(Ty::unit()),
                    _ => self.ty(e.id),
                };
                (b.field(Sel::F(*index), d(&ft)), ft)
            }
            EK::Index { expr, index } => {
                let (b, bt) = self.place(expr);
                let loc = self.loc(e.span);
                match bt {
                    Ty::List(et) => {
                        let iv = self.expr(index);
                        let ic = self.val_as(&iv, &Ty::Int);
                        let i = self.decl(&Ty::Int, ic);
                        self.do_(Ex::rt("duck_arr_make_unique", vec![b.clone().addr()], MTy::void_ptr()));
                        let p = Ex::rt("duck_arr_at", vec![b, i, loc], MTy::void_ptr()).cast(MTy::ptr(d(&et)));
                        let p = self.f.b.decl(p);
                        (p.deref(d(&et)), *et)
                    }
                    Ty::Map(kt, vt) => {
                        let kv = self.expr(index);
                        let k = self.lvalue(&kv, &kt);
                        self.do_(Ex::rt("duck_map_make_unique", vec![b.clone().addr()], MTy::void_ptr()));
                        let p = Ex::rt("duck_map_at", vec![b, k.addr().cast(MTy::void_ptr()), loc], MTy::void_ptr()).cast(MTy::ptr(d(&vt)));
                        let p = self.f.b.decl(p);
                        (p.deref(d(&vt)), *vt)
                    }
                    _ => self.place_tmp(e),
                }
            }
            _ => self.place_tmp(e),
        }
    }

    /// The place of field `name` of the struct place `b` (of type `bt`), for writing.
    fn place_field(&mut self, e: &Expr, b: &Ex, bt: &Ty, name: &str) -> (Ex, Ty) {
        let ft = match bt {
            Ty::Named(dd, args) if self.tp.defs.is_struct(*dd) => {
                let s = self.tp.defs.subst_of(*dd, args);
                self.tp.defs.fields(*dd).iter().find(|f| f.name == name).map(|f| f.ty.subst(&s)).unwrap_or(Ty::unit())
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
                    let c = self.g.call(f, vec![raw.addr()]);
                    self.do_(c);
                }
                (self.g.field_get(bt, i, b), ft)
            }
            None => (self.g.zero(&ft), ft),
        }
    }

    fn place_tmp(&mut self, e: &Expr) -> (Ex, Ty) {
        let v = self.expr(e);
        let ty = v.ty.clone();
        let o = self.own_as(v, &ty);
        let n = self.decl(&ty, o);
        self.register(&n, &ty);
        (n, ty)
    }

    fn assign(&mut self, e: &Expr, op: Option<BinOp>, target: &Expr, value: &Expr) {
        if op.is_some() && self.t.calls.contains_key(&e.id) {
            // a user operator: target = op(target, value)
            let v = self.call(e, None, false);
            let (lv, ty) = self.place(target);
            let o = self.own_as(v, &ty);
            let old = self.decl(&ty, lv.clone());
            self.set(lv, o);
            if let Some(r) = self.g.release(&ty, &old) {
                self.emit(r);
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
                if let EK::Index { expr, index } = &target.kind {
                    let (b, bt) = self.place(expr);
                    if let Ty::Map(kt, vt) = bt {
                        let kv = self.expr(index);
                        let k = self.lvalue(&kv, &kt);
                        let vc = self.lvalue(&v, &vt);
                        self.do_(Ex::rt("duck_map_set", vec![b.addr(), k.addr().cast(MTy::void_ptr()), vc.addr().cast(MTy::void_ptr())], MTy::Void));
                        return;
                    }
                    if let Ty::List(et) = bt {
                        let iv = self.expr(index);
                        let vc = self.lvalue(&v, &et);
                        let loc = self.loc(target.span);
                        self.do_(Ex::rt("duck_arr_set", vec![b.addr(), iv.c, vc.addr().cast(MTy::void_ptr()), loc], MTy::Void));
                        return;
                    }
                }
                let (lv, lty) = match &target.kind {
                    EK::Field { expr, name } if !self.t.names.contains_key(&target.id) => {
                        let (b, bt) = self.place(expr);
                        // a boxed (recursive) struct field gets a fresh box
                        if let Some(i) = self.field_index(&bt, &name.name)
                            && self.g.field_raw(&bt, i, &b).1
                        {
                            let ft = self.g.info.struct_layout(&bt)[i].0.clone();
                            let o = self.own_as(v, &ft);
                            let put = self.g.field_put(&bt, i, o);
                            let (raw, _) = self.g.field_raw(&bt, i, &b);
                            let old = self.f.b.decl(raw.clone());
                            self.set(raw, put);
                            self.do_(Ex::rt("duck_release", vec![old], MTy::Void));
                            return;
                        }
                        self.place_field(target, &b, &bt, &name.name)
                    }
                    _ => self.place(target),
                };
                let ty = v.ty.clone();
                let o = self.own_as(v, &ty);
                let nv = self.decl(&ty, o);
                if self.g.needs_rc(&lty) {
                    let old = self.decl(&lty, lv.clone());
                    self.set(lv, nv);
                    if let Some(r) = self.g.release(&lty, &old) {
                        self.emit(r);
                    }
                } else {
                    self.set(lv, nv);
                }
            }
            Some(op) => {
                let rc = v.c.clone();
                let (lv, lty) = self.place(target);
                let loc = self.loc(e.span);
                match lty {
                    Ty::Int => {
                        let c = int_op(op, lv.clone(), rc, loc);
                        self.set(lv, c);
                    }
                    Ty::Float => {
                        let c = match op {
                            BinOp::Add => Ex::bin(BOp::Add, lv.clone(), rc),
                            BinOp::Sub => Ex::bin(BOp::Sub, lv.clone(), rc),
                            BinOp::Mul => Ex::bin(BOp::Mul, lv.clone(), rc),
                            BinOp::Div => Ex::bin(BOp::Div, lv.clone(), rc),
                            _ => Ex::rt("duck_fmod", vec![lv.clone(), rc], MTy::D(Ty::Float)),
                        };
                        self.set(lv, c);
                    }
                    Ty::Str => {
                        let n = self.decl(&Ty::Str, Ex::rt("duck_str_concat", vec![lv.clone(), rc], MTy::D(Ty::Str)));
                        self.do_(Ex::rt("duck_release", vec![lv.clone()], MTy::Void));
                        self.set(lv, n);
                    }
                    Ty::List(_) => self.do_(Ex::rt("duck_arr_extend", vec![lv.addr(), rc], MTy::Void)),
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
                self.open_if(self.fld(&w, Sel::F(0)).not());
                self.return_err(self.fld(&w, Sel::F(2)));
                self.close();
                let val = self.fld(&w, Sel::F(1));
                self.adopt(&ty, val)
            }
            TryKind::Option => {
                let w = self.hold(v);
                self.open_if(self.fld(&w, Sel::F(0)).not());
                self.return_none();
                self.close();
                let val = self.fld(&w, Sel::F(1));
                self.adopt(&ty, val)
            }
            TryKind::ListResult | TryKind::ListOption => {
                let Ty::List(el) = v.ty.clone() else { return Val::never() };
                let Ty::List(inner) = ty.clone() else { return Val::never() };
                let xs = self.hold(v);
                let ops = self.g.ops(&inner);
                let len = Ex::rt("duck_arr_len", vec![xs.clone()], MTy::D(Ty::Int));
                let out = self.decl(&ty, Ex::rt("duck_arr_new", vec![ops, len.clone()], d(&ty)));
                let k = self.decl(&Ty::Int, Ex::int(0));
                self.f.b.open_loop(vec![Stmt::Set(k.clone(), Ex::bin(BOp::Add, k.clone(), Ex::int(1)))]);
                self.open_if(Ex::bin(BOp::Lt, k.clone(), len).not());
                self.emit(Stmt::Break);
                self.close();
                let r = Ex::elem(xs.clone(), k.clone(), d(&el));
                self.open_if(self.fld(&r, Sel::F(0)).not());
                if info.kind == TryKind::ListResult {
                    let ety = self.g.err_ty();
                    let en = self.decl(&ety, Ex::rt("duck_retain", vec![self.fld(&r, Sel::F(2))], d(&ety)));
                    self.do_(Ex::rt("duck_release", vec![out.clone()], MTy::Void));
                    self.do_(Ex::rt("duck_release", vec![xs.clone()], MTy::Void));
                    self.return_err(en);
                } else {
                    self.do_(Ex::rt("duck_release", vec![out.clone()], MTy::Void));
                    self.do_(Ex::rt("duck_release", vec![xs.clone()], MTy::Void));
                    self.return_none();
                }
                self.close();
                self.do_(Ex::rt("duck_arr_push", vec![out.clone().addr(), self.fld(&r, Sel::F(1)).addr().cast(MTy::void_ptr())], MTy::Void));
                self.emit(Stmt::Continue);
                self.close();
                self.do_(Ex::rt("duck_release", vec![xs], MTy::Void));
                self.reown(out, ty)
            }
        }
    }

    fn return_none(&mut self) {
        let ret = self.f.ret.clone();
        self.cleanup_from(0);
        let z = self.g.zero(&ret);
        self.emit(Stmt::Ret(Some(z)));
    }

    fn else_expr(&mut self, e: &Expr, x: &Expr, arm: &ElseArm) -> Val {
        let info = self.t.elses[&e.id].clone();
        let v = self.expr(x);
        let ty = self.ty(e.id);
        if v.is_never() {
            return v;
        }
        let wt = v.ty.clone();
        let w = self.hold(v);
        let r = self.zero_decl(&ty);
        self.open_if(self.fld(&w, Sel::F(0)));
        self.set(r.clone(), self.fld(&w, Sel::F(1)));
        self.else_();
        self.push(ScopeKind::Block);
        if info.kind != ElseKind::Option {
            self.bind_err(info.binder, &w, &wt);
        }
        let fb = self.expr(&arm.body);
        let o = self.own_as(fb, &ty);
        self.set(r.clone(), o);
        self.pop();
        self.close();
        self.reown(r, ty)
    }

    /// In the error branch of `w` (a held `T!`): bind `else e =>`'s binder or drop the error.
    fn bind_err(&mut self, binder: Option<LocalId>, w: &Ex, _wt: &Ty) {
        let err = self.fld(w, Sel::F(2));
        match binder {
            Some(l) => {
                let lt = self.local_ty(l);
                let n = if self.g.is_err_ty(&lt) {
                    self.decl(&lt, err)
                } else {
                    let id = self.g.type_id(&lt);
                    let n = self.zero_decl(&lt);
                    let pl = self.f.b.decl(Ex::rt("duck_err_payload", vec![err.clone(), Ex::int_as(id as i64, MTy::U32)], MTy::void_ptr()));
                    self.open_if(Ex::bin(BOp::Ne, pl.clone(), Ex::null()));
                    self.set(n.clone(), pl.cast(MTy::ptr(d(&lt))).deref(d(&lt)));
                    self.close();
                    if let Some(r) = self.g.retain(&lt, &n) {
                        self.emit(r);
                    }
                    self.do_(Ex::rt("duck_release", vec![err], MTy::Void));
                    n
                };
                self.register_local(&n, &lt);
                self.bind_name(l, Slot { c: n, ty: lt });
            }
            None => self.do_(Ex::rt("duck_release", vec![err], MTy::Void)),
        }
    }

    fn opt_chain(&mut self, e: &Expr, x: &Expr, name: &crate::ast::Ident, call: bool) -> Val {
        let flatten = self.t.opt_chains.get(&e.id).is_some_and(|o| o.flatten);
        let v = self.expr(x);
        if v.is_never() {
            return v;
        }
        let ty = self.ty(e.id);
        let Ty::Opt(inner) = v.ty.clone() else { return Val::never() };
        let xv = self.lvalue(&v, &v.ty.clone());
        let r = self.zero_decl(&ty);
        self.open_if(self.fld(&xv, Sel::F(0)));
        self.push(ScopeKind::Block);
        let val = self.fld(&xv, Sel::F(1));
        let iv = Val::plain(val.clone(), (*inner).clone());
        let member = if call {
            self.call(e, Some(iv), false)
        } else {
            let ft = match &ty {
                Ty::Opt(t) if !flatten => (**t).clone(),
                t => t.clone(),
            };
            let c = match (name.tuple_index(), self.field_index(&inner, &name.name)) {
                (Some(index), _) => self.fld(&val, Sel::F(index)),
                (None, Some(i)) => self.g.field_get(&inner, i, &val),
                (None, None) => self.g.zero(&ft),
            };
            Val::plain(c, ft)
        };
        if flatten {
            let o = self.own_as(member, &ty);
            self.set(r.clone(), o);
        } else if let Ty::Opt(mt) = &ty {
            let mt = (**mt).clone();
            let o = self.own_as(member, &mt);
            let s = self.some(&ty, o);
            self.set(r.clone(), s);
        }
        self.pop();
        self.close();
        self.reown(r, ty)
    }

    fn tasks_agg(&mut self, n: usize) -> super::AggId {
        let key = format!("tasks{n}");
        if let Some(&a) = self.g.memo2.get(&key) {
            return a;
        }
        let a = self.g.agg(format!("DkTasks{n}"), vec![MTy::ptr(MTy::Rt(Rt::Task)); n]);
        self.g.memo2.insert(key, a);
        a
    }

    fn await_(&mut self, e: &Expr, x: &Expr) -> Val {
        let kind = self.t.awaits.get(&e.id).copied().unwrap_or(AwaitKind::Direct);
        let ty = self.ty(e.id);
        match kind {
            AwaitKind::Direct => self.expr(x),
            AwaitKind::Task => {
                let t = self.expr(x);
                let r = self.zero_decl(&ty);
                self.do_(Ex::rt("duck_task_await", vec![t.c, r.clone().addr().cast(MTy::void_ptr())], MTy::Void));
                self.reown(r, ty)
            }
            AwaitKind::Tuple => {
                let tv = self.expr(x);
                let Ty::Tuple(ts) = tv.ty.clone() else { return Val::never() };
                let fields: Vec<Ex> = (0..ts.len()).map(|i| self.fld(&tv.c, Sel::F(i as u32))).collect();
                let a = self.tasks_agg(ts.len());
                let arr = self.f.b.decl(Ex::agg(MTy::Agg(a), fields.iter().enumerate().map(|(i, f)| (Sel::F(i as u32), f.clone().cast(MTy::ptr(MTy::Rt(Rt::Task))))).collect()));
                self.do_(Ex::rt("duck_task_join_all", vec![arr.addr().cast(MTy::ptr(MTy::ptr(MTy::Rt(Rt::Task)))), Ex::int(ts.len() as i64)], MTy::Void));
                let r = self.zero_decl(&ty);
                for (i, f) in fields.into_iter().enumerate() {
                    let slot = self.fld(&r, Sel::F(i as u32)).addr().cast(MTy::void_ptr());
                    self.do_(Ex::rt("duck_task_await", vec![f, slot], MTy::Void));
                }
                self.reown(r, ty)
            }
            AwaitKind::List => {
                let tv = self.expr(x);
                let Ty::List(inner) = ty.clone() else { return Val::never() };
                let ops = self.g.ops(&inner);
                let n = self.decl(&Ty::Int, Ex::rt("duck_arr_len", vec![tv.c.clone()], MTy::D(Ty::Int)));
                let out = self.decl(&ty, Ex::rt("duck_arr_new", vec![ops, n.clone()], d(&ty)));
                self.open_if(Ex::bin(BOp::Gt, n.clone(), Ex::int(0)));
                let tasks = tv.c.rt_field(RtF::ArrData).cast(MTy::ptr(MTy::ptr(MTy::Rt(Rt::Task))));
                self.do_(Ex::rt("duck_task_await_all", vec![tasks, n.clone(), out.clone().rt_field(RtF::ArrData)], MTy::Void));
                self.set(out.clone().rt_field(RtF::ArrLen), n);
                self.close();
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
        self.open_if(cc);
        let v = self.block(then, tail);
        if let Some(r) = &r {
            if !v.is_never() {
                let o = self.own_as(v, &ty);
                self.set(r.clone(), o);
            }
        } else {
            self.own_drop(v);
        }
        if let Some(x) = els {
            self.else_();
            self.push(ScopeKind::Block);
            let v = self.expr_t(x, tail);
            if let Some(r) = &r
                && !v.is_never()
            {
                let o = self.own_as(v, &ty);
                self.set(r.clone(), o);
            }
            self.pop();
        }
        self.close();
        match r {
            Some(r) => self.reown(r, ty),
            None if ty == Ty::Never => Val::never(),
            None => Val::unit(),
        }
    }

    /// Drop a value produced in a branch whose result is unused.
    fn own_drop(&mut self, v: Val) {
        if v.owned && !v.is_never() {
            self.unregister(&v.c);
            if let Some(r) = self.g.release(&v.ty, &v.c) {
                self.emit(r);
            }
        }
    }

    fn match_(&mut self, e: &Expr, scrut: &Expr, arms: &[crate::ast::Arm], tail: bool) -> Val {
        let ty = self.ty(e.id);
        let sv = self.expr(scrut);
        if sv.is_never() {
            return sv;
        }
        let st = sv.ty.clone();
        let s = self.lvalue(&sv, &st);
        let has = Self::has_value(&ty);
        let r = if has { Some(self.zero_decl(&ty)) } else { None };
        let end = self.f.b.label();
        for a in arms {
            let test = self.pat_test(&a.pat, &s);
            self.open_if(test);
            self.push(ScopeKind::Block);
            let arm_depth = self.f.scopes.len() - 1;
            self.bind_pat(&a.pat, &s, &st);
            let guarded = if let Some(gx) = &a.guard {
                self.push(ScopeKind::Stmt);
                let v = self.expr(gx);
                let gc = self.val_as(&v, &Ty::Bool);
                let gv = self.decl(&Ty::Bool, gc);
                self.pop();
                self.open_if(gv);
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
                    self.set(r.clone(), o);
                }
            } else {
                self.own_drop(v);
            }
            self.pop();
            if !never {
                self.cleanup_from(arm_depth);
                self.emit(Stmt::Goto(end));
            }
            if guarded {
                self.close();
            }
            self.pop();
            self.close();
        }
        let loc = self.loc(e.span);
        self.do_(Ex::rt("duck_panic_str", vec![loc, Ex::cstr("no match arm matches the value")], MTy::Void));
        self.emit(Stmt::Unreachable);
        self.emit(Stmt::Label(end));
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
                let EK::Range { lo, hi, .. } = &iter.kind else { return };
                let l = self.expr(lo);
                let h = self.expr(hi);
                let lc = self.val_as(&l, &Ty::Int);
                let hc = self.val_as(&h, &Ty::Int);
                let hv = self.decl(&Ty::Int, hc);
                let i = self.decl(&Ty::Int, lc);
                self.f.b.open_loop(vec![Stmt::Set(i.clone(), Ex::bin(BOp::Add, i.clone(), Ex::int(1)))]);
                self.cancel_point(e.span);
                let op = if inclusive { BOp::Le } else { BOp::Lt };
                self.open_if(Ex::bin(op, i.clone(), hv).not());
                self.emit(Stmt::Break);
                self.close();
                self.push(ScopeKind::Block);
                let depth = self.f.scopes.len() - 1;
                self.bind_top(pat, &i, &Ty::Int);
                self.loop_body(depth, body);
                self.pop();
                self.emit(Stmt::Continue);
                self.close();
            }
            Some(ForKind::List) => {
                let v = self.expr(iter);
                let Ty::List(et) = v.ty.clone() else { return };
                let it = self.hold(v);
                self.register(&it, &Ty::list((*et).clone()));
                let k = self.decl(&Ty::Int, Ex::int(0));
                self.f.b.open_loop(vec![Stmt::Set(k.clone(), Ex::bin(BOp::Add, k.clone(), Ex::int(1)))]);
                self.cancel_point(e.span);
                let len = Ex::rt("duck_arr_len", vec![it.clone()], MTy::D(Ty::Int));
                self.open_if(Ex::bin(BOp::Lt, k.clone(), len).not());
                self.emit(Stmt::Break);
                self.close();
                self.push(ScopeKind::Block);
                let depth = self.f.scopes.len() - 1;
                if let Some(ix) = index {
                    self.bind_top(ix, &k, &Ty::Int);
                }
                let ev = self.decl(&et, Ex::elem(it.clone(), k.clone(), d(&et)));
                self.bind_top(pat, &ev, &et);
                self.loop_body(depth, body);
                self.pop();
                self.emit(Stmt::Continue);
                self.close();
            }
            Some(ForKind::Map) => {
                let v = self.expr(iter);
                let Ty::Map(kt, vt) = v.ty.clone() else { return };
                let mt = v.ty.clone();
                let m = self.hold(v);
                self.register(&m, &mt);
                let it = self.f.b.decl(Ex::int(0));
                let kp = self.f.b.decl(Ex::null());
                let vp = self.f.b.decl(Ex::null());
                self.f.b.open_loop(vec![]);
                self.cancel_point(e.span);
                let next = Ex::rt("duck_map_next", vec![m.clone(), it.addr(), kp.clone().addr(), vp.clone().addr()], MTy::Bool);
                self.open_if(next.not());
                self.emit(Stmt::Break);
                self.close();
                self.push(ScopeKind::Block);
                let depth = self.f.scopes.len() - 1;
                let kv = self.decl(&kt, kp.cast(MTy::ptr(d(&kt))).deref(d(&kt)));
                let vv = self.decl(&vt, vp.cast(MTy::ptr(d(&vt))).deref(d(&vt)));
                match index {
                    Some(ix) => {
                        self.bind_top(ix, &kv, &kt);
                        self.bind_top(pat, &vv, &vt);
                    }
                    None => {
                        let tt = Ty::Tuple(vec![(*kt).clone(), (*vt).clone()]);
                        let tv = self.decl(&tt, Ex::agg(d(&tt), vec![(Sel::F(0), kv), (Sel::F(1), vv)]));
                        self.bind_top(pat, &tv, &tt);
                    }
                }
                self.loop_body(depth, body);
                self.pop();
                self.close();
            }
            Some(ForKind::Chan) => {
                let v = self.expr(iter);
                let Ty::Named(_, args) = v.ty.clone() else { return };
                let et = args[0].clone();
                let ct = v.ty.clone();
                let c = self.hold(v);
                self.register(&c, &ct);
                let r = self.fld(&c, Sel::F(0));
                self.f.b.open_loop(vec![]);
                self.cancel_point(e.span);
                self.push(ScopeKind::Block);
                let depth = self.f.scopes.len() - 1;
                let x = self.zero_decl(&et);
                let got = Ex::rt("duck_chan_recv", vec![r, x.clone().addr().cast(MTy::void_ptr())], MTy::Bool);
                self.open_if(got.not());
                self.emit(Stmt::Break);
                self.close();
                self.register(&x, &et);
                self.bind_top(pat, &x, &et);
                self.loop_body(depth, body);
                self.pop();
                self.close();
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
        let saved = self.f.dbg.as_mut().map(|d| std::mem::replace(&mut d.in_let, false));
        self.let_body(e, pat, value, els);
        if let (Some(d), Some(s)) = (&mut self.f.dbg, saved) {
            d.in_let = s;
        }
    }

    /// The names a `let` binds from here on last until the end of the block (debugger scopes).
    fn let_binds(&mut self) {
        if let Some(d) = &mut self.f.dbg {
            d.in_let = true;
        }
    }

    fn let_body(&mut self, e: &Expr, pat: &Pat, value: &Expr, els: Option<&ElseArm>) {
        let Some(arm) = els else {
            let v = self.expr(value);
            if v.is_never() {
                return;
            }
            self.let_binds();
            self.bind_value(pat, v);
            return;
        };
        let info = self.t.elses.get(&e.id).cloned();
        let Some(info) = info else {
            let v = self.expr(value);
            self.let_binds();
            self.bind_value(pat, v);
            return;
        };
        let v = self.expr(value);
        self.let_binds();
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
                let ok = self.fld(&w, Sel::F(0));
                if let ElseKind::UnwrapRefutable { .. } = info.kind {
                    // unwrap, then the pattern must match; otherwise the else (which diverges)
                    self.open_if(ok.clone());
                    self.set(r.clone(), self.fld(&w, Sel::F(1)));
                    self.close();
                    let test = self.pat_test(pat, &r);
                    let okv = self.f.b.decl(ok.clone());
                    let matched = self.f.b.decl(Ex::bool(false));
                    self.open_if(okv.clone());
                    self.set(matched.clone(), test);
                    self.close();
                    self.open_if(matched.not());
                    self.push(ScopeKind::Block);
                    if let Some(rr) = self.g.release(&inner, &r) {
                        self.open_if(okv.clone());
                        self.emit(rr);
                        self.close();
                    }
                    if !is_opt {
                        self.open_if(okv.not());
                        self.do_(Ex::rt("duck_release", vec![self.fld(&w, Sel::F(2))], MTy::Void));
                        self.close();
                    }
                    let fb = self.expr(&arm.body);
                    self.own_drop(fb);
                    self.pop();
                    self.close();
                    self.register_local(&r, &inner);
                    self.bind_pat(pat, &r, &inner);
                    return;
                }
                self.open_if(ok);
                self.set(r.clone(), self.fld(&w, Sel::F(1)));
                self.else_();
                self.push(ScopeKind::Block);
                if !is_opt {
                    self.bind_err(info.binder, &w, &wt);
                }
                let fb = self.expr(&arm.body);
                let o = self.own_as(fb, &inner);
                self.set(r.clone(), o);
                self.pop();
                self.close();
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
                    let n = self.decl(&ty, c);
                    self.register_local(&n, &ty);
                    n
                };
                let test = self.pat_test(pat, &s);
                self.open_if(test.not());
                self.push(ScopeKind::Block);
                let fb = self.expr(&arm.body);
                self.own_drop(fb);
                self.pop();
                self.close();
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
                let n = self.decl(&ty, o);
                self.register_local(&n, &ty);
                self.bind_name(l, Slot { c: n, ty });
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
        let text = Ex::cstr(&self.g.span_text(self.m, x.span));
        if let EK::Binary { op, lhs, rhs } = &x.kind
            && matches!(op, BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge)
        {
            let l = self.expr(lhs);
            let r = self.expr(rhs);
            let c = self.compare(x, *op, &l, &r);
            let cv = self.decl(&Ty::Bool, c);
            self.open_if(cv.not());
            let ls = self.dshow(&l);
            let rs = self.dshow(&r);
            self.do_(Ex::rt("duck_assert_fail_cmp", vec![loc, text, ls, rs], MTy::Void));
            self.emit(Stmt::Unreachable);
            self.close();
            return;
        }
        let v = self.expr(x);
        let c = self.val_as(&v, &Ty::Bool);
        self.open_if(c.not());
        self.do_(Ex::rt("duck_assert_fail", vec![loc, text], MTy::Void));
        self.emit(Stmt::Unreachable);
        self.close();
    }

    /// Debug-form show of a value (strings quoted), as an owned `str` expression.
    fn dshow(&mut self, v: &Val) -> Ex {
        if v.is_never() {
            return Ex::zero(MTy::D(Ty::Str));
        }
        match self.g.dshow_fn(&v.ty) {
            Some(f) => self.g.call_ref(&f, vec![v.c.clone()], MTy::D(Ty::Str)),
            None => Ex::rt("duck_str_lit", vec![Ex::cstr(&format!("<{}>", self.g.show_ty(&v.ty)))], MTy::D(Ty::Str)),
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
        let sb = self.f.b.decl(Ex::zero(MTy::Rt(Rt::StrBuf)));
        let sbp = sb.clone().addr();
        let mut k = 0;
        for p in parts {
            match p {
                InterpPart::Lit(s) => {
                    if !s.is_empty() {
                        self.do_(Ex::rt("duck_sb_bytes", vec![sbp.clone(), Ex::cstr(s), Ex::int(s.len() as i64)], MTy::Void));
                    }
                }
                InterpPart::Expr { expr, .. } => {
                    let v = vals[k].clone();
                    k += 1;
                    let spec = self.t.formats.get(&expr.id).map(|f| Ex::cstr(&f.text));
                    let c = v.c.clone();
                    if v.is_never() {
                        continue;
                    }
                    let st = MTy::D(Ty::Str);
                    let own = |s: Ex| Ex::rt("duck_sb_str_own", vec![sbp.clone(), s], MTy::Void);
                    let e = match (&v.ty, spec) {
                        (Ty::Int, Some(s)) => own(Ex::rt("duck_fmt_int", vec![c, s], st)),
                        (Ty::Int, None) => own(Ex::rt("duck_str_from_int", vec![c], st)),
                        (Ty::Float, Some(s)) => own(Ex::rt("duck_fmt_float", vec![c, s], st)),
                        (Ty::Float, None) => own(Ex::rt("duck_str_from_float", vec![c], st)),
                        (Ty::Str, Some(s)) => own(Ex::rt("duck_fmt_str", vec![c, s], st)),
                        (Ty::Str, None) => Ex::rt("duck_sb_str", vec![sbp.clone(), c], MTy::Void),
                        (Ty::Char, Some(s)) => own(Ex::rt("duck_fmt_char", vec![c, s], st)),
                        (Ty::Char, None) => Ex::rt("duck_sb_char", vec![sbp.clone(), c], MTy::Void),
                        (Ty::Bool, Some(s)) => own(Ex::rt("duck_fmt_bool", vec![c, s], st)),
                        (Ty::Bool, None) => Ex::rt("duck_sb_lit", vec![sbp.clone(), Ex::cond(c, Ex::cstr("true"), Ex::cstr("false"))], MTy::Void),
                        (_, spec) => {
                            let shown = self.show_of(expr.id, &v);
                            match spec {
                                Some(s) => {
                                    let t = self.decl(&Ty::Str, shown);
                                    self.do_(own(Ex::rt("duck_fmt_str", vec![t.clone(), s], st)));
                                    Ex::rt("duck_release", vec![t], MTy::Void)
                                }
                                None => own(shown),
                            }
                        }
                    };
                    self.do_(e);
                    if let Some(u) = self.t.units.get(&expr.id) {
                        let u = format!(" {u}");
                        self.do_(Ex::rt("duck_sb_bytes", vec![sbp.clone(), Ex::cstr(&u), Ex::int(u.len() as i64)], MTy::Void));
                    }
                }
            }
        }
        self.tmp(&Ty::Str, Ex::rt("duck_sb_finish", vec![sbp], MTy::D(Ty::Str)))
    }

    fn struct_lit(&mut self, e: &Expr) -> Val {
        let EK::Struct { fields, base, .. } = &e.kind else { unreachable!() };
        let ty = self.ty(e.id);
        let Some(sl) = self.t.struct_lits.get(&e.id).cloned() else { return Val::never() };
        let Ty::Named(dd, args) = &ty else { return Val::never() };
        let s = self.tp.defs.subst_of(*dd, args);
        let defs = self.tp.defs.fields(*dd).to_vec();
        let mut given: Vec<(usize, Ex)> = Vec::new();
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
            let n = self.decl(&ft, o);
            self.register(&n, &ft);
            given.push((*fi, n));
        }
        match base {
            Some(b) => {
                let bv = self.expr(b);
                for (_, n) in &given {
                    self.unregister(n);
                }
                let o = self.own_as(bv, &ty);
                let r = self.decl(&ty, o);
                for (fi, n) in given {
                    let ft = defs[fi].ty.subst(&s);
                    let (f, boxed) = self.g.field_raw(&ty, fi, &r);
                    if boxed {
                        self.do_(Ex::rt("duck_release", vec![f.clone()], MTy::Void));
                    } else if let Some(rel) = self.g.release(&ft, &f) {
                        self.emit(rel);
                    }
                    let put = self.g.field_put(&ty, fi, n);
                    self.set(f, put);
                }
                self.reown(r, ty)
            }
            None => {
                for (_, n) in &given {
                    self.unregister(n);
                }
                let mut parts = Vec::new();
                for (fi, n) in given {
                    let put = self.g.field_put(&ty, fi, n);
                    parts.push((Sel::F(fi as u32), put));
                }
                self.tmp(&ty, Ex::agg(d(&ty), parts))
            }
        }
    }

    /// `await any ts` → `duck_task_await_any(data, n, &out, &err, loc)`: the index, and the
    /// result (`T!` as is; a plain `T` wrapped) or the panic as the `Err`.
    fn await_any(&mut self, e: &Expr, x: &Expr) -> Val {
        let ty = self.ty(e.id);
        let Ty::Tuple(parts) = ty.clone() else { return Val::never() };
        let res = parts[1].clone();
        let Ty::Res(ok, _) = res.clone() else { return Val::never() };
        let tv = self.expr(x);
        let Ty::List(tt) = tv.ty.clone() else { return Val::never() };
        let Ty::Task(inner) = *tt else { return Val::never() };
        let wrapped = matches!(*inner, Ty::Res(..));
        let n = self.decl(&Ty::Int, Ex::rt("duck_arr_len", vec![tv.c.clone()], MTy::D(Ty::Int)));
        let data = tv.c.rt_field(RtF::ArrData).cast(MTy::ptr(MTy::ptr(MTy::Rt(Rt::Task))));
        let et = self.g.err_ty();
        let err = self.zero_decl(&et);
        let r = self.zero_decl(&res);
        let (out, v) = if wrapped {
            (r.clone().addr().cast(MTy::void_ptr()), None)
        } else if Self::has_value(&ok) {
            let v = self.zero_decl(&ok);
            (v.clone().addr().cast(MTy::void_ptr()), Some(v))
        } else {
            (Ex::zero(MTy::void_ptr()), None)
        };
        let loc = self.loc(e.span);
        let idx = self.decl(&Ty::Int, Ex::rt("duck_task_await_any", vec![data, n, out, err.clone().addr().cast(MTy::void_ptr()), loc], MTy::D(Ty::Int)));
        self.open_if(Ex::bin(BOp::Ne, err.clone().cast(MTy::void_ptr()), Ex::zero(MTy::void_ptr())));
        self.set(r.clone(), Ex::agg(d(&res), vec![(Sel::F(2), err)]));
        if !wrapped {
            self.else_();
            let mut fs = vec![(Sel::F(0), Ex::bool(true))];
            if let Some(v) = v {
                fs.push((Sel::F(1), v));
            }
            self.set(r.clone(), Ex::agg(d(&res), fs));
        }
        self.close();
        self.tmp(&ty, Ex::agg(d(&ty), vec![(Sel::F(0), idx), (Sel::F(1), r)]))
    }

    // ---- `catch` ----

    /// `catch body`: lift the body into `R dk_catch{k}(env)` (R = `T!`; env points at the
    /// captured variables, captured by reference) and a C thunk `dk_catcht{k}(env, out)` that
    /// stores its value; `duck_catch` runs the thunk under a recovery point and returns the panic
    /// as an `Err` (NULL when the body finished).
    fn catch_(&mut self, e: &Expr, body: &Expr) -> Val {
        let Some(info) = self.t.closures.get(&e.id).cloned() else { return Val::never() };
        let ret = self.sub(&info.ret);
        let k = self.g.fresh();
        // the captured variables' places in this function
        let mut caps = Vec::new();
        for &l in &info.captures {
            let (c, ty) = match self.f.locals.get(&l) {
                Some(s) => (s.c.clone(), s.ty.clone()),
                None => {
                    let ty = self.local_ty(l);
                    (self.zero_decl(&ty), ty)
                }
            };
            caps.push((l, c, ty));
        }
        let env = self.g.agg(format!("DkCatchEnv{k}"), caps.iter().map(|(_, _, t)| MTy::ptr(d(t))).chain([MTy::void_ptr()]).collect());
        // the body
        let fname = self.g.declare(format!("dk_catch{k}"), vec![MTy::void_ptr()], d(&ret), Abi::Duck);
        let pv = self.begin_fn(fname, ret.clone());
        self.push(ScopeKind::Block);
        let ev = pv[0].clone().cast(MTy::ptr(MTy::Agg(env))).deref(MTy::Agg(env));
        for (i, (l, _, ty)) in caps.iter().enumerate() {
            let p = self.g.fld(&ev, Sel::F(i as u32));
            self.bind_name(*l, Slot { c: p.deref(d(ty)), ty: ty.clone() });
        }
        let v = self.expr(body);
        self.ret_val(v, &ret);
        let z = self.g.zero(&ret);
        self.emit(Stmt::Ret(Some(z)));
        self.end(fname);
        // the thunk: *out = dk_catch{k}(env)
        let thunk = self.g.declare(format!("dk_catcht{k}"), vec![MTy::void_ptr(), MTy::void_ptr()], MTy::Void, Abi::C);
        let (mut b, tv) = self.g.body_for(thunk);
        let c = self.g.call(fname, vec![tv[0].clone()]);
        b.set(tv[1].clone().cast(MTy::ptr(d(&ret))).deref(d(&ret)), c);
        self.g.define(thunk, b);
        // run it
        let mut fields: Vec<(Sel, Ex)> = caps.into_iter().enumerate().map(|(i, (_, c, _))| (Sel::F(i as u32), c.addr())).collect();
        let n = fields.len() as u32;
        fields.push((Sel::F(n), Ex::zero(MTy::void_ptr())));
        let envv = self.f.b.decl(Ex::agg(MTy::Agg(env), fields));
        let r = self.zero_decl(&ret);
        let et = self.g.err_ty();
        let err = self.decl(
            &et,
            Ex::rt("duck_catch", vec![Ex::fn_addr(thunk), envv.addr().cast(MTy::void_ptr()), r.clone().addr().cast(MTy::void_ptr())], d(&et)),
        );
        self.open_if(Ex::bin(BOp::Ne, err.clone().cast(MTy::void_ptr()), Ex::zero(MTy::void_ptr())));
        self.set(r.clone(), Ex::agg(d(&ret), vec![(Sel::F(2), err)]));
        self.close();
        self.reown(r, ret)
    }

    // ---- closures ----

    fn closure(&mut self, e: &Expr, params: &[crate::ast::Param], body: &Expr) -> Val {
        let Some(info) = self.t.closures.get(&e.id).cloned() else { return Val::never() };
        let ptys: Vec<Ty> = info.params.iter().map(|t| self.sub(t)).collect();
        let ret = self.sub(&info.ret);
        let k = self.g.fresh();
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
        let env = if caps.is_empty() {
            None
        } else {
            let mut fs = vec![MTy::Rt(Rt::Obj)];
            fs.extend(caps.iter().map(|(_, _, t)| d(t)));
            let a = self.g.agg(format!("DkEnv{k}"), fs);
            let drop = self.g.declare(format!("DkEnv{k}_drop"), vec![MTy::obj_ptr()], MTy::Void, Abi::C);
            let (mut b, pv) = self.g.body_for(drop);
            let ev = pv[0].clone().cast(MTy::ptr(MTy::Agg(a))).deref(MTy::Agg(a));
            for (i, (_, _, ty)) in caps.iter().enumerate() {
                let f = self.g.fld(&ev, Sel::F(i as u32 + 1));
                if let Some(r) = self.g.release(ty, &f) {
                    b.emit(r);
                }
            }
            self.g.define(drop, b);
            // the copy (a task's argument): a new env with deep copies of the captures
            let copy = self.g.declare(format!("DkEnv{k}_copy"), vec![MTy::obj_ptr()], MTy::obj_ptr(), Abi::C);
            let (mut b, pv) = self.g.body_for(copy);
            let ev = pv[0].clone().cast(MTy::ptr(MTy::Agg(a))).deref(MTy::Agg(a));
            let nv = b.decl(Ex::rt("duck_obj_alloc", vec![Ex::size_of(MTy::Agg(a)), Ex::fn_addr(drop), Ex::fn_addr(copy)], MTy::ptr(MTy::Agg(a))));
            for (i, (_, _, ty)) in caps.iter().enumerate() {
                let f = self.g.fld(&ev, Sel::F(i as u32 + 1));
                let c = self.g.copy_ex(ty, f);
                let place = self.g.fld(&nv.clone().deref(MTy::Agg(a)), Sel::F(i as u32 + 1));
                b.set(place, c);
            }
            b.emit(Stmt::Ret(Some(nv.cast(MTy::obj_ptr()))));
            self.g.define(copy, b);
            Some((a, (drop, copy)))
        };
        // the lifted function
        let fty = if info.unpack { vec![Ty::Tuple(ptys.clone())] } else { ptys.clone() };
        let mut pts = vec![MTy::obj_ptr()];
        pts.extend(fty.iter().map(d));
        let fname = self.g.declare(format!("dk_clo{k}"), pts, d(&ret), Abi::Duck);
        let pv = self.begin_fn(fname, ret.clone());
        let owner = match self.tp.instances[self.inst].body {
            BodyRef::Fn(f) => format!("{}.{}", self.trace_mod_name(self.tp.fns[f].module), self.tp.fns[f].name),
            _ => self.trace_mod_name(self.m),
        };
        let n = format!("{owner}.<fn:{}>", e.span.line);
        self.name_fn(fname, &n);
        self.dbg_begin(n);
        self.push(ScopeKind::Block);
        if let Some((a, _)) = env {
            let ev = pv[0].clone().cast(MTy::ptr(MTy::Agg(a))).deref(MTy::Agg(a));
            for (i, (l, _, ty)) in caps.iter().enumerate() {
                let c = self.g.fld(&ev, Sel::F(i as u32 + 1));
                self.bind_name(*l, Slot { c, ty: ty.clone() });
            }
        }
        if info.unpack {
            for (i, (p, t)) in params.iter().zip(&ptys).enumerate() {
                let c = self.fld(&pv[1], Sel::F(i as u32));
                self.bind_top(&p.pat, &c, t);
            }
        } else {
            for (i, (p, t)) in params.iter().zip(&ptys).enumerate() {
                self.bind_top(&p.pat, &pv[i + 1].clone(), t);
            }
        }
        if !matches!(body.kind, EK::Block(_)) {
            self.dbg_hook(body.span);
        }
        let v = self.expr(body);
        if ret.is_unit() {
            if !v.is_never() {
                self.cleanup_from(0);
                self.emit(Stmt::Ret(Some(Ex::zero(d(&ret)))));
            }
        } else {
            self.ret_val(v, &ret);
        }
        let z = self.g.zero(&ret);
        self.emit(Stmt::Ret(Some(z)));
        self.end(fname);
        // build the value
        let fnty = Ty::func(fty, ret);
        let Some((a, (drop, copy))) = env else {
            return Val::plain(self.closure_val(fname, &fnty, Ex::zero(MTy::obj_ptr())), fnty);
        };
        let ev = self.f.b.decl(Ex::rt("duck_obj_alloc", vec![Ex::size_of(MTy::Agg(a)), Ex::fn_addr(drop), Ex::fn_addr(copy)], MTy::ptr(MTy::Agg(a))));
        for (i, (_, c, ty)) in caps.into_iter().enumerate() {
            let o = self.own(Val::plain(c, ty));
            let f = self.fld(&ev.clone().deref(MTy::Agg(a)), Sel::F(i as u32 + 1));
            self.set(f, o);
        }
        let v = self.closure_val(fname, &fnty, ev.cast(MTy::obj_ptr()));
        self.tmp(&fnty, v)
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
        if let EK::Call { callee, args } = &e.kind
            && let EK::Name(n) = &callee.kind
            && n == "old"
            && args.len() == 1
            && olds.contains(&args[0].id)
        {
            out.push(&args[0]);
            return;
        }
        match &e.kind {
            EK::Call { callee, args } => {
                walk(callee, olds, out);
                args.iter().for_each(|a| walk(a, olds, out));
            }
            EK::MethodCall { recv, args, .. } => {
                walk(recv, olds, out);
                args.iter().for_each(|a| walk(a, olds, out));
            }
            EK::Binary { lhs, rhs, .. } => {
                walk(lhs, olds, out);
                walk(rhs, olds, out);
            }
            EK::Unary { expr, .. } | EK::Field { expr, .. } | EK::TupleField { expr, .. } => walk(expr, olds, out),
            EK::Index { expr, index } => {
                walk(expr, olds, out);
                walk(index, olds, out);
            }
            EK::Tuple(xs) | EK::List(xs) => xs.iter().for_each(|x| walk(x, olds, out)),
            EK::Pipe { lhs, args, .. } => {
                walk(lhs, olds, out);
                args.iter().for_each(|a| walk(a, olds, out));
            }
            _ => {}
        }
    }
    walk(e, olds, out);
}

/// `a op b` on `int`: checked arithmetic and shifts go through runtime helpers that panic at
/// `loc`; the wrapping and bitwise ones can't fail.
fn int_op(op: BinOp, a: Ex, b: Ex, loc: Ex) -> Ex {
    use BinOp::*;
    let int = MTy::D(Ty::Int);
    let rt = |s: &str, args: Vec<Ex>| Ex::rt(s, args, int.clone());
    match op {
        Add => rt("duck_add", vec![a, b, loc]),
        Sub => rt("duck_sub", vec![a, b, loc]),
        Mul => rt("duck_mul", vec![a, b, loc]),
        Div => rt("duck_div", vec![a, b, loc]),
        Rem => rt("duck_mod", vec![a, b, loc]),
        Pow => rt("duck_pow", vec![a, b, loc]),
        AddWrap => Ex::bin(BOp::Add, a, b),
        SubWrap => Ex::bin(BOp::Sub, a, b),
        MulWrap => Ex::bin(BOp::Mul, a, b),
        BitAnd => Ex::bin(BOp::BitAnd, a, b),
        BitOr => Ex::bin(BOp::BitOr, a, b),
        BitXor => Ex::bin(BOp::BitXor, a, b),
        Shl => rt("duck_shl", vec![a, b, loc]),
        Shr => rt("duck_shr", vec![a, b, loc]),
        _ => Ex::int(0),
    }
}
