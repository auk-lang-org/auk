/// Lowering of function bodies to MIR (src/mir/lower.rs): expressions, statements, patterns,
/// control flow and reference counting. One `Lower` emits one instance (plus the closures,
/// thunks and wrappers it needs) into the `Gen`'s program.
///
/// # How a body is lowered
/// Expressions are lowered in evaluation order to statements; each returns a `Val`: an
/// expression of an Auk type that is either **owned** (a temporary variable the current scope
/// will release unless it is moved out with `own`) or **borrowed** (a local, a field of a value
/// that outlives the statement, a global). Locals own their values; parameters are borrowed (or,
/// in a function whose self tail calls became a loop, owned copies).
///
/// Scopes mirror Auk's: a statement scope holds that statement's temporaries, block scopes hold
/// locals, a loop marks where `break`/`continue` stop releasing. An early exit (`return`, `?`,
/// `fail`, `break`, `continue`, a self tail call) releases every scope it leaves.
///
/// Patterns (`mir.lower.pat`) compile to a pure test expression plus a binding step; calls to
/// user C functions are `mir.lower.ffi`. Their entry points have forwards here (a dot call only
/// looks in the current module and the receiver type's).
///
/// Differences from Rust: `Lower` owns the `Gen` while it works (`emit_instance` moves it in
/// and back out, so the program's lists stay unique); methods take `lw: var Lower`. Rust's
/// `Option<&FnDbg>` updates take the value out of `f.dbg` and put it back.

pub struct Val { c: mir.Ex, ty: types.Ty, owned: bool }

pub fn val_unit(): Val = Val { c: mir.unit(), ty: types.unit(), owned: false }

pub fn val_never(): Val = Val { c: mir.int_as(0, mir.MTy.D(types.Ty.Never)), ty: types.Ty.Never, owned: false }

pub fn plain(c: mir.Ex, ty: types.Ty): Val = Val { c, ty, owned: false }

pub fn is_never(v: Val): bool = v.ty == types.Ty.Never

/// An argument: a value, or (for `var` parameters) the address of a place.
pub enum ArgV {
  Val(v: Val),
  Addr(p: mir.Ex, t: types.Ty),
}

pub struct Slot { c: mir.Ex, ty: types.Ty }

pub enum ScopeKind { Block, Stmt }

pub struct Scope { kind: ScopeKind, owned: [(mir.Ex, types.Ty)] }

/// The debugger state of an instrumented function (`progen.Debug`): its frame record and the
/// locals in scope.
pub struct FnDbg {
  frame: mir.Ex,
  agg: int,
  func: int,
  slots: {int: int},
  /// The locals in scope: (slot, index of the scope that ends it).
  vis: [(int, int)],
  /// Binding a `let`'s names: they last until the end of the enclosing block.
  in_let: bool,
}

pub struct LoopCx {
  /// Index of the loop body's scope.
  depth: int,
  result: (mir.Ex, types.Ty)?,
}

pub struct TailCx {
  /// The parameters (owned copies, or pointer parameters for `var` ones).
  params: [(mir.Ex, types.Ty, bool)],
  label: int,
}

/// The state of one function being emitted.
pub struct FnState {
  b: mir.Body,
  scopes: [Scope],
  loops: [LoopCx],
  locals: {int: Slot},
  ret: types.Ty,
  tail: TailCx?,
  olds: {int: mir.Ex},
  var_params: {int: bool},
  dbg: FnDbg?,
  /// While binding an alternative of an or-pattern: the variable each of its locals goes in.
  or_into: {int: mir.Ex},
  /// While binding a `match` arm on a stable value (`stable_root`): immutable names borrow
  /// their part of it instead of taking owned copies.
  bind_borrow: bool,
  /// In the program's `main` (`is_program_main`): the index of its body block's scope, whose
  /// end releases through `release_at_exit` (-1 otherwise).
  exit_scope: int,
  /// Lowering the body of the program's `main` itself (not a closure in it).
  main_fn: bool,
}

pub fn new_fs(ret: types.Ty): FnState = FnState {
  b: mir.new_body(),
  scopes: [],
  loops: [],
  locals: {},
  ret,
  tail: none,
  olds: {},
  var_params: {},
  dbg: none,
  or_into: {},
  bind_borrow: false,
  exit_scope: -1,
  main_fn: false,
}

pub struct Lower {
  g: mir.progen.Gen,
  tp: typed.TypedProgram,
  m: int,
  t: typed.Tables,
  inst: int,
  subst: {int: types.Ty},
  file: str,
  f: FnState,
  saved: [FnState],
}

fn d(t: types.Ty): mir.MTy = mir.MTy.D(t)

fn ty_str(): mir.MTy = mir.MTy.D(types.Ty.Str)

fn ty_int(): mir.MTy = mir.MTy.D(types.Ty.Int)

fn ty_bool(): mir.MTy = mir.MTy.D(types.Ty.Bool)

/// The machine type of a function type's parameter: a `var T` one is a pointer to the variable.
fn param_mty(t: types.Ty): mir.MTy = match t {
  Mut(inner) => mir.ptr(d(inner))
  _ => d(t)
}

/// Emit instance `i` (and whatever it needs).
pub fn emit_instance(g: var mir.progen.Gen, i: int) {
  let tp = g.tp
  let inst = tp.instances[i]
  let (m, item) = g.body_item(inst.body)
  var lw = Lower {
    g: mir.progen.take(&g),
    tp,
    m,
    t: tp.tables[m],
    inst: i,
    subst: typed.inst_subst(inst, tp.fns),
    file: tp.program.mods[m].file,
    f: new_fs(types.unit()),
    saved: [],
  }
  match (inst.body, item) {
    (Fn(f), Fn(group)) => lw.emit_fn(f, group)
    (Test(_), Test(td)) => lw.emit_test(td.body)
    (Const(_), Let(cd)) | (Const(_), Imprint(cd)) => lw.emit_const(cd.value)
    _ => { let _: int = mir.bug("codegen: instance {i} has an unexpected body") }
  }
  g = lw.g
}

/// The debugger's evaluation function for `value`, an expression inserted into the body of
/// instance `i` (`dbg_eval.auk`): `AukStr *f(void **slots)` reads each local of `binds` from
/// the address in the same position of `slots` and returns the value shown (debug `Show`).
pub fn emit_eval(g: var mir.progen.Gen, i: int, value: ast.Expr, binds: [int]): int {
  let tp = g.tp
  let (m, _) = g.body_item(tp.instances[i].body)
  let f = g.declare("dk_dbg_eval", [mir.void_ptr()], ty_str(), mir.Abi.C)
  var lw = Lower {
    g: mir.progen.take(&g),
    tp,
    m,
    t: tp.tables[m],
    inst: i,
    subst: typed.inst_subst(tp.instances[i], tp.fns),
    file: tp.program.mods[m].file,
    f: new_fs(types.unit()),
    saved: [],
  }
  let ps = lw.begin_fn(f, types.Ty.Str)
  lw.push(ScopeKind.Block)
  for k, l in binds {
    let ty = lw.local_ty(l)
    // slots[k]: the local's address in the stopped frame
    let at = mir.bin(mir.BOp.Add, ps[0].cast(mir.MTy.I64), mir.int_as(8 * k, mir.MTy.I64)).cast(mir.ptr(mir.void_ptr()))
    let place = at.deref(mir.void_ptr()).cast(mir.ptr(d(ty))).deref(d(ty))
    lw.f.locals[l] = Slot { c: place, ty }
  }
  let v = lw.expr(value)
  let shown = if v.is_never() || types.is_unit(v.ty) {
    mir.rt("auk_str_from_bytes", [mir.cstr("()"), mir.int_(2)], ty_str())
  } else {
    lw.trace_show(v.ty, v.c)
  }
  let r = lw.bdecl(shown)
  lw.cleanup_from(0)
  lw.emit(mir.Stmt.Ret(r))
  lw.f.scopes = []
  lw.end(f)
  g = lw.g
  f
}

/// `ss` with `leave` (popping the debugger frame) before every return; a returned value is
/// computed first, so a call in return position runs with the frame still pushed.
fn dbg_rets(ss: [mir.Stmt], vars: var [mir.MTy], leave: mir.Stmt): [mir.Stmt] {
  var out: [mir.Stmt] = []
  for s in ss {
    match s {
      Ret(some(e)) => {
        vars.push(e.ty)
        let v = vars.len() - 1
        out.push(mir.Stmt.Let(v, e))
        out.push(leave)
        out.push(mir.Stmt.Ret(mir.var_(v, e.ty)))
      }
      Ret(none) => {
        out.push(leave)
        out.push(mir.Stmt.Ret(none))
      }
      If(c, a, b) => out.push(mir.Stmt.If(c, dbg_rets(a, &vars, leave), dbg_rets(b, &vars, leave)))
      Loop(a, b) => out.push(mir.Stmt.Loop(dbg_rets(a, &vars, leave), dbg_rets(b, &vars, leave)))
      s => out.push(s)
    }
  }
  out
}

/// The direct sub-expressions that can be call arguments of `e` (receiver first).
pub fn arg_exprs(e: ast.Expr): [ast.Expr] = match e.kind {
  Call(_, args) => args
  MethodCall(recv, _, args) => [recv] + args
  Pipe(lhs, _, args) => [lhs] + args
  OptChain(x, _, args) => [x] + (args else [])
  Binary(_, l, r) => [l, r]
  Assign(_, t, v) => [t, v]
  _ => []
}

fn find_expr(xs: [ast.Expr], id: int): ast.Expr? {
  for x in xs {
    if x.id == id { return x }
  }
  none
}

// ---- small helpers ----

pub fn ty(lw: var Lower, id: int): types.Ty = match lw.t.types.get(id) {
  some(t) => types.subst(t, lw.subst)
  none => types.unit()
}

pub fn local_ty(lw: var Lower, l: int): types.Ty = types.subst(lw.t.locals[l].ty, lw.subst)

pub fn sub(lw: var Lower, t: types.Ty): types.Ty = types.subst(t, lw.subst)

pub fn loc(lw: var Lower, span: diag.Span): mir.Ex = mir.cstr("{lw.file}:{span.line}:{span.col}")

fn has_coercions(lw: var Lower, id: int): bool = match lw.t.coercions.get(id) {
  some(cs) => cs.len() > 0
  none => false
}

/// A cancellation point at the top of every iteration of a user loop (none in the runtime
/// package, `uses raw` or not, nor in other `uses raw` code: the runtime's own loops). The flag
/// is read with a relaxed atomic load: another thread sets it, and a plain load would let LLVM
/// hoist it out of a loop that makes no calls, which then never sees the cancel.
fn cancel_point(lw: var Lower, span: diag.Span) {
  if mir.lower.lowlevel.raw_fn(&lw) || lw.tp.program.is_runtime(lw.m) { return }
  let at = mir.rt_global("auk_cancel_pending", ty_int())
  let pending = mir.rt("@raw.atomic_load.2", [at], ty_int())
  lw.open_if(mir.bin(mir.BOp.Ne, pending, mir.int_(0)))
  let l = lw.loc(span)
  lw.do_(mir.rt("auk_cancel_check", [l], mir.MTy.Void))
  lw.close()
}

pub fn emit(lw: var Lower, s: mir.Stmt) { lw.f.b.emit(s) }

pub fn do_(lw: var Lower, e: mir.Ex) { lw.f.b.do_(e) }

pub fn set(lw: var Lower, place: mir.Ex, v: mir.Ex) { lw.f.b.set(place, v) }

pub fn open_if(lw: var Lower, c: mir.Ex) { lw.f.b.open_if(c) }

pub fn else_(lw: var Lower) { lw.f.b.else_() }

pub fn close(lw: var Lower) { lw.f.b.close() }

/// Declare a variable (not registered for release).
pub fn decl(lw: var Lower, ty: types.Ty, init: mir.Ex): mir.Ex = lw.f.b.decl_as(d(ty), init)

/// A plain `Body::decl` (the variable takes the expression's machine type).
pub fn bdecl(lw: var Lower, init: mir.Ex): mir.Ex = lw.f.b.decl(init)

/// An owned temporary (registered for release in the current scope).
pub fn tmp(lw: var Lower, ty: types.Ty, init: mir.Ex): Val {
  let n = lw.decl(ty, init)
  lw.register(n, ty)
  Val { c: n, ty, owned: true }
}

pub fn register(lw: var Lower, c: mir.Ex, ty: types.Ty) {
  if lw.g.needs_rc(ty) {
    let k = lw.f.scopes.len() - 1
    if k < 0 { let _: int = mir.bug("scope") }
    lw.f.scopes[k].owned.push((c, ty))
  }
}

/// Register an owned local in the innermost block scope.
pub fn register_local(lw: var Lower, c: mir.Ex, ty: types.Ty) {
  if !lw.g.needs_rc(ty) { return }
  var i = lw.f.scopes.len() - 1
  while i >= 0 && lw.f.scopes[i].kind != ScopeKind.Block { i -= 1 }
  if i < 0 { i = 0 }
  lw.f.scopes[i].owned.push((c, ty))
}

/// A raw struct or union (the runtime's dialect)?
pub fn is_raw_struct(lw: var Lower, ty: types.Ty): bool = match ty {
  Named(d, _) => types.is_raw_def(lw.tp.defs, d)
  _ => false
}

pub fn unregister(lw: var Lower, c: mir.Ex) {
  var si = lw.f.scopes.len() - 1
  while si >= 0 {
    var p = lw.f.scopes[si].owned.len() - 1
    while p >= 0 {
      if lw.f.scopes[si].owned[p].0 == c {
        let _ = lw.f.scopes[si].owned.remove(p)
        return
      }
      p -= 1
    }
    si -= 1
  }
}

pub fn push(lw: var Lower, kind: ScopeKind) { lw.f.scopes.push(Scope { kind, owned: [] }) }

pub fn pop(lw: var Lower) {
  let s = lw.f.scopes.pop()!
  match lw.f.dbg {
    some(_) => {
      var dd = lw.f.dbg!
      lw.f.dbg = none
      let k = lw.f.scopes.len()
      dd.vis = dd.vis.filter(p => p.1 < k)
      lw.f.dbg = some(dd)
    }
    none => {}
  }
  if lw.f.scopes.len() == lw.f.exit_scope {
    lw.release_at_exit(s.owned.reverse())
    return
  }
  for (c, ty) in s.owned.reverse() {
    match lw.g.release(ty, c) {
      some(r) => lw.emit(r)
      none => {}
    }
  }
}

/// Release everything owned by scopes `depth..` (for an early exit), without popping.
pub fn cleanup_from(lw: var Lower, depth: int) {
  var rels: [(mir.Ex, types.Ty)] = []
  var si = lw.f.scopes.len() - 1
  while si >= depth {
    let owned = lw.f.scopes[si].owned
    var p = owned.len() - 1
    while p >= 0 {
      rels.push(owned[p])
      p -= 1
    }
    si -= 1
  }
  for (c, ty) in rels {
    match lw.g.release(ty, c) {
      some(r) => lw.emit(r)
      none => {}
    }
  }
}

/// Take ownership of a value: moves an owned temporary, retains a borrowed value.
pub fn own(lw: var Lower, v: Val): mir.Ex {
  if v.owned {
    lw.unregister(v.c)
    return v.c
  }
  match lw.g.retain(v.ty, v.c) {
    some(r) => lw.emit(r)
    none => {}
  }
  v.c
}

/// `own`, giving a zero of `ty` for a `never` value.
pub fn own_as(lw: var Lower, v: Val, ty: types.Ty): mir.Ex {
  if v.is_never() { return lw.g.zero(ty) }
  lw.own(v)
}

/// Like `own`, but materialized in a fresh (unregistered) variable.
pub fn hold(lw: var Lower, v: Val): mir.Ex {
  if v.owned && v.c.is_var() {
    lw.unregister(v.c)
    return v.c
  }
  let ty = v.ty
  let o = lw.own(v)
  lw.decl(ty, o)
}

/// A borrowed value as an expression of type `ty` (zero for `never`).
pub fn val_as(lw: var Lower, v: Val, ty: types.Ty): mir.Ex = if v.is_never() { lw.g.zero(ty) } else { v.c }

/// An addressable variable holding the value (borrowed copy when needed).
pub fn lvalue(lw: var Lower, v: Val, ty: types.Ty): mir.Ex {
  if v.c.is_place() && !v.is_never() { return v.c }
  let c = lw.val_as(v, ty)
  lw.decl(ty, c)
}

/// An owned temporary for `e`, which is an owned value of `ty`.
pub fn adopt(lw: var Lower, ty: types.Ty, e: mir.Ex): Val = lw.tmp(ty, e)

/// Re-register an owned held variable as a temporary in the current scope.
pub fn reown(lw: var Lower, c: mir.Ex, ty: types.Ty): Val {
  lw.register(c, ty)
  Val { c, ty, owned: true }
}

pub fn zero_decl(lw: var Lower, ty: types.Ty): mir.Ex {
  let z = lw.g.zero(ty)
  lw.decl(ty, z)
}

/// The index of struct field `name` in type `t`.
pub fn field_index(lw: var Lower, t: types.Ty, name: str): int? = match t {
  Named(dd, _) when types.is_struct(lw.tp.defs, dd) => {
    for i, f in types.fields(lw.tp.defs, dd) {
      if f.name == name { return i }
    }
    none
  }
  _ => none
}

fn has_value(ty: types.Ty): bool = !types.is_unit(ty) && ty != types.Ty.Never

pub fn some_(lw: var Lower, ty: types.Ty, v: mir.Ex): mir.Ex = match ty {
  Opt(inner) => mir.agg(d(ty), [(mir.Sel.F(0), mir.ex(mir.K.Int(1), mir.MTy.Bool)), (mir.Sel.F(1), mir.retype(v, d(inner)))])
  _ => mir.bug("some of a non-optional")
}

pub fn ok_(lw: var Lower, ty: types.Ty, v: mir.Ex): mir.Ex = match ty {
  Res(inner, _) => mir.agg(d(ty), [(mir.Sel.F(0), mir.ex(mir.K.Int(1), mir.MTy.Bool)), (mir.Sel.F(1), mir.retype(v, d(inner)))])
  _ => mir.bug("ok of a non-result")
}

pub fn fld(lw: var Lower, v: mir.Ex, s: mir.Sel): mir.Ex = lw.g.fld(v, s)

fn trace_site(lw: var Lower, l: mir.Ex) {
  let slot = mir.rt("auk__trace_site_slot", [], mir.ptr(mir.MTy.CStr))
  lw.set(slot.deref(mir.MTy.CStr), l)
}

// ---- forwards to mir.lower.pat and mir.lower.ffi ----

pub fn pat_test(lw: var Lower, p: ast.Pat, v: mir.Ex): mir.Ex = mir.lower.pat.pat_test(&lw, p, v)

pub fn bind_top(lw: var Lower, p: ast.Pat, v: mir.Ex, ty: types.Ty) { mir.lower.pat.bind_top(&lw, p, v, ty) }

pub fn bind_pat(lw: var Lower, p: ast.Pat, v: mir.Ex, ty: types.Ty) { mir.lower.pat.bind_pat(&lw, p, v, ty) }

fn ffi_call(lw: var Lower, f: int, args: [ArgV], ret: types.Ty, l: mir.Ex): Val =
  mir.lower.ffi.ffi_call(&lw, f, args, ret, l)

// ---- function bodies ----

fn begin(lw: var Lower, ret: types.Ty) {
  lw.saved.push(lw.f)
  lw.f = new_fs(ret)
}

/// Finish the current body into function `f`.
fn end(lw: var Lower, f: int) {
  let st = lw.f
  lw.f = lw.saved.pop()!
  match st.dbg {
    none => lw.g.define(f, st.b)
    some(dbg) => {
      // instrumented: push the frame record first, pop it before every return
      var b = st.b
      let (body, vars0) = b.finish()
      var vars = vars0
      let fp = dbg.frame.addr().cast(mir.void_ptr())
      let leave = mir.Stmt.Do(mir.rt("auk_dbg_leave", [fp], mir.MTy.Void))
      var out = [
        mir.Stmt.Let(mir.as_var(dbg.frame)!, mir.agg(mir.MTy.Agg(dbg.agg), [(mir.Sel.F(0), mir.int_as(dbg.func, mir.MTy.I64))])),
        mir.Stmt.Do(mir.rt("auk_dbg_enter", [fp], mir.MTy.Void)),
      ]
      out = out + dbg_rets(body, &vars, leave)
      lw.g.prog.funcs[f].body = out
      lw.g.prog.funcs[f].vars = vars
    }
  }
}

/// Record the Auk name of a generated function (for debug info).
fn name_fn(lw: var Lower, f: int, name: str) {
  if lw.g.lines { lw.g.prog.names[f] = name }
}

/// Instrument the function being lowered for the debugger (when its module is), under the
/// name the debugger shows.
fn dbg_begin(lw: var Lower, name: str) {
  if !lw.g.dbg_on(lw.m) { return }
  let k = lw.g.fresh()
  let agg = lw.g.agg("DkDbgFrame{k}", [mir.MTy.I64, mir.void_ptr(), mir.MTy.I64])
  let frame = lw.f.b.new_var(mir.MTy.Agg(agg))
  let inst = lw.tp.instances[lw.inst]
  lw.g.dbg_info.fns.push(mir.progen.DbgFn { name, locals: [], body: inst.body, type_args: inst.type_args })
  let func = lw.g.dbg_info.fns.len() - 1
  lw.f.dbg = some(FnDbg { frame, agg, func, slots: {}, vis: [], in_let: false })
}

/// Bind a local name; in an instrumented function, also record its address in the frame.
pub fn bind_name(lw: var Lower, l: int, s: Slot) {
  // an or-pattern's alternative: move the owned value into the variable declared for it
  match lw.f.or_into.get(l) {
    some(v) => {
      lw.unregister(s.c)
      lw.set(v, s.c)
      return
    }
    none => {}
  }
  if lw.f.dbg != none {
    let place = if s.c.is_place() { s.c } else { lw.decl(s.ty, s.c) }
    var dd = lw.f.dbg!
    lw.f.dbg = none
    let i = match dd.slots.get(l) {
      some(i) => i
      none => {
        let i = dd.slots.len()
        dd.slots[l] = i
        lw.g.prog.aggs[dd.agg].fields.push(mir.void_ptr())
        let name = lw.t.locals[l].name
        let tid = mir.progen.type_id(&lw.g.dbg_info, s.ty)
        lw.g.dbg_info.fns[dd.func].locals.push((name, tid))
        i
      }
    }
    var scope = lw.f.scopes.len() - 1
    if dd.in_let {
      while scope >= 0 && lw.f.scopes[scope].kind != ScopeKind.Block { scope -= 1 }
    }
    if scope < 0 { scope = 0 }
    if !dd.vis.any(p => p.0 == i) { dd.vis.push((i, scope)) }
    let slot = dd.frame.field(mir.Sel.F(3 + i), mir.void_ptr())
    lw.f.dbg = some(dd)
    lw.set(slot, place.addr().cast(mir.void_ptr()))
  }
  lw.f.locals[l] = s
}

/// A debugger stop point: record the statement's site in the frame and call the debugger
/// while it is armed (one load otherwise).
pub fn dbg_hook(lw: var Lower, span: diag.Span, wrap: bool) {
  if lw.g.lines {
    lw.g.prog.locs.push((lw.file, span.line, span.col))
    let i = lw.g.prog.locs.len() - 1
    lw.emit(mir.Stmt.Loc(i))
  }
  let dd = lw.f.dbg else return
  let vis = dd.vis.map(p => p.0)
  let site = mir.progen.DbgSite {
    func: dd.func,
    file: lw.file,
    line: span.line,
    col: span.col,
    end_line: span.end_line,
    end_col: span.end_col,
    wrap,
    vis,
  }
  let frame = dd.frame
  lw.g.dbg_info.sites.push(site)
  let id = lw.g.dbg_info.sites.len() - 1
  lw.set(frame.field(mir.Sel.F(2), mir.MTy.I64), mir.int_as(id, mir.MTy.I64))
  let armed = mir.rt_global("auk_dbg_armed", ty_int()).deref(ty_int())
  lw.open_if(mir.bin(mir.BOp.Ne, armed, mir.int_(0)))
  lw.do_(mir.rt("auk_dbg_hook", [frame.addr().cast(mir.void_ptr())], mir.MTy.Void))
  lw.close()
}

/// Start the body of a declared function: its parameters.
fn begin_fn(lw: var Lower, f: int, ret: types.Ty): [mir.Ex] {
  lw.begin(ret)
  let ps = lw.g.prog.funcs[f].vars
  var out: [mir.Ex] = []
  for t in ps { out.push(lw.f.b.new_var(t)) }
  out
}

fn emit_fn(lw: var Lower, fid: int, group: ast.FnGroup) {
  let info = lw.tp.fns[fid]
  let (clauses, header) = match info.kind {
    Auk(_, cs, h) => (cs, h)
    _ => mir.bug("emit_fn of a non-Auk function")
  }
  let outer = lw.g.inst_fn(lw.inst)
  let base = lw.g.prog.funcs[outer].name
  let sig = lw.g.prog.funcs[outer].vars
  let rty = lw.g.func_ret(outer)
  // traced: `outer` becomes the tracing wrapper around the function, `_untraced`
  let traced = lw.g.traced(info.module)
  let name = if traced { lw.g.declare("{base}_untraced", sig, rty, mir.Abi.Auk) } else { outer }
  let params = info.params.map(p => (types.subst(p.ty, lw.subst), p.var_))
  let ret = lw.sub(info.ret)
  let hdr = if header { group.header } else { none }
  let cls = clauses.map(c => group.clauses[c])
  let hdr_ens = match hdr {
    some(h) => h.post.len() > 0
    none => false
  }
  let ensures_ = lw.g.debug() && (hdr_ens || cls.any(c => c.post.len() > 0))
  let body_name = if ensures_ {
    let n = lw.g.prog.funcs[name].name
    lw.g.declare("{n}_body", sig, rty, mir.Abi.Auk)
  } else {
    name
  }
  let args = lw.begin_fn(body_name, ret)
  let dname = "{lw.trace_mod_name(info.module)}.{info.name}"
  lw.name_fn(body_name, dname)
  lw.dbg_begin(dname)
  // var parameters bound to plain names (tail calls may pass them through)
  for c in cls {
    for k, p in c.params {
      if params[k].1 {
        match lw.t.binds.get(p.pat.id) {
          some(l) => lw.f.var_params[l] = true
          none => {}
        }
      }
    }
  }
  // with `ensures`, this is the body behind the checking wrapper: self tail calls loop here,
  // and the wrapper checks the outer call's result once
  var tail = false
  for c in cls {
    if !tail && lw.body_has_tail_call(c) { tail = true }
  }
  lw.push(ScopeKind.Block)
  var pnames: [(mir.Ex, types.Ty, bool)] = []
  var tparams: [(mir.Ex, types.Ty, bool)] = []
  for k, (t, var_) in params {
    if var_ {
      pnames.push((args[k].deref(d(t)), t, true))
      tparams.push((args[k], t, true))
      continue
    }
    let p = lw.decl(t, args[k])
    if tail {
      match lw.g.retain(t, p) {
        some(r) => lw.emit(r)
        none => {}
      }
      lw.register(p, t)
    }
    pnames.push((p, t, false))
    tparams.push((p, t, false))
  }
  if tail {
    // label 0 is the self-tail-call loop's (`Body.label` starts at 1)
    lw.f.tail = some(TailCx { params: tparams, label: 0 })
    lw.emit(mir.Stmt.Label(0))
  }
  // header contracts
  match hdr {
    some(h) => {
      for k, p in h.params {
        match lw.t.binds.get(p.pat.id) {
          some(l) => lw.bind_name(l, Slot { c: pnames[k].0, ty: pnames[k].1 })
          none => {}
        }
      }
      for r in h.pre { lw.requires_(r) }
    }
    none => {}
  }
  for c in cls { lw.clause(c, pnames, ret) }
  let l = lw.loc(info.span)
  let msg = "no clause of `{info.name}` matches the arguments"
  lw.do_(mir.rt("auk_panic_str", [l, mir.cstr(msg)], mir.MTy.Void))
  lw.emit(mir.Stmt.Unreachable)
  lw.f.scopes = []
  lw.end(body_name)
  if ensures_ { lw.ensures_wrapper(fid, name, body_name, params, ret, hdr, cls) }
  if traced { lw.trace_wrapper(fid, outer, name, params, ret) }
}

fn unitish(t: types.Ty): bool = types.is_unit(t) || t == types.Ty.Never

/// The tracing wrapper `outer` of the function `inner` (`auk run/test --trace`).
fn trace_wrapper(lw: var Lower, fid: int, outer: int, inner: int, params: [(types.Ty, bool)], ret: types.Ty) {
  let info = lw.tp.fns[fid]
  let fname = mir.cstr("{lw.trace_mod_name(info.module)}.{info.name}")
  let l = lw.loc(info.span)
  let ps = lw.begin_fn(outer, ret)
  let call = lw.g.call(inner, ps)
  lw.open_if(mir.rt("auk_trace_begin", [], mir.MTy.Bool).not())
  lw.emit(mir.Stmt.Ret(call))
  lw.close()
  var shows: [mir.Ex] = []
  for k, (t, var_) in params {
    let v = if var_ { ps[k].deref(d(t)) } else { ps[k] }
    shows.push(lw.trace_show(t, v))
  }
  let n = shows.len()
  let args = if n == 0 {
    mir.zero(mir.ptr(ty_str()))
  } else {
    let a = lw.shows_agg(n)
    var ms: [(mir.Sel, mir.Ex)] = []
    for i, s in shows { ms.push((mir.Sel.F(i), s)) }
    let arr = lw.bdecl(mir.agg(mir.MTy.Agg(a), ms))
    arr.addr().cast(mir.ptr(ty_str()))
  }
  lw.do_(mir.rt("auk_trace_call", [fname, l, mir.int_as(n, mir.MTy.I32), args], mir.MTy.Void))
  let r = lw.decl(ret, call)
  lw.open_if(mir.rt("auk_trace_exit", [], mir.MTy.Bool))
  match ret {
    Res(t, _) => {
      lw.open_if(lw.fld(r, mir.Sel.F(0)))
      let okv = if unitish(t) { mir.zero(ty_str()) } else { lw.trace_show(t, lw.fld(r, mir.Sel.F(1))) }
      lw.do_(mir.rt("auk_trace_ret", [fname, okv], mir.MTy.Void))
      lw.else_()
      lw.do_(mir.rt("auk_trace_err", [fname, lw.fld(r, mir.Sel.F(2))], mir.MTy.Void))
      lw.close()
    }
    t when unitish(t) => lw.do_(mir.rt("auk_trace_ret", [fname, mir.zero(ty_str())], mir.MTy.Void))
    t => {
      let s = lw.trace_show(t, r)
      lw.do_(mir.rt("auk_trace_ret", [fname, s], mir.MTy.Void))
    }
  }
  lw.close()
  lw.emit(mir.Stmt.Ret(r))
  lw.end(outer)
}

/// An aggregate of `n` strings (an array of shown values).
fn shows_agg(lw: var Lower, n: int): int {
  let key = "shows{n}"
  match lw.g.memo2.get(key) {
    some(a) => return a
    none => {}
  }
  let a = lw.g.agg("DkStrs{n}", (0..n).map(_ => ty_str()))
  lw.g.memo2[key] = a
  a
}

/// A module's name in trace events: its path (`json`, `http.uri`), but the root file of a
/// program that isn't a project's `src/lib.auk`/`src/main.auk` goes by its file name.
fn trace_mod_name(lw: var Lower, m: int): str {
  let p = lw.tp.program
  let stem = paths.file_stem(p.mods[m].file)
  if m == p.root && stem != "lib" && stem != "main" && stem != "" { stem } else { resolve.name(p, m) }
}

/// The shown value of `e` (type `t`) in a trace event: an owned `AukStr *`.
pub fn trace_show(lw: var Lower, t: types.Ty, e: mir.Ex): mir.Ex = match lw.g.dshow_fn(t) {
  some(f) => lw.g.call_ref(f, [e], ty_str())
  none => {
    let text = "<{lw.g.show_ty(t)}>"
    mir.rt("auk_str_from_bytes", [mir.cstr(text), mir.int_(text.byte_len())], ty_str())
  }
}

fn requires_(lw: var Lower, r: ast.Expr) {
  lw.push(ScopeKind.Stmt)
  let v = lw.expr(r)
  let c = lw.val_as(v, types.Ty.Bool)
  let cv = lw.decl(types.Ty.Bool, c)
  lw.pop()
  let l = lw.loc(r.span)
  let text = mir.cstr(lw.g.span_text(lw.m, r.span))
  lw.open_if(cv.not())
  lw.do_(mir.rt("auk_requires_fail", [l, text], mir.MTy.Void))
  lw.close()
}

fn and_tests(conds: [mir.Ex]): mir.Ex = mir.and(conds.filter(c => c != mir.bool_(true)))

/// A clause guard: evaluated in a statement scope, then an `if` around the rest.
fn guard(lw: var Lower, gx: ast.Expr?): bool = match gx {
  some(x) => {
    lw.push(ScopeKind.Stmt)
    let v = lw.expr(x)
    let gc = lw.val_as(v, types.Ty.Bool)
    let gv = lw.decl(types.Ty.Bool, gc)
    lw.pop()
    lw.open_if(gv)
    true
  }
  none => false
}

fn clause(lw: var Lower, c: ast.FnClause, pnames: [(mir.Ex, types.Ty, bool)], ret: types.Ty) {
  var conds: [mir.Ex] = []
  for k, p in c.params { conds.push(lw.pat_test(p.pat, pnames[k].0)) }
  lw.open_if(and_tests(conds))
  lw.push(ScopeKind.Block)
  for k, p in c.params { lw.bind_top(p.pat, pnames[k].0, pnames[k].1) }
  let guarded = lw.guard(c.guard)
  for r in c.pre { lw.requires_(r) }
  lw.push(ScopeKind.Block)
  // the body block's scope comes next
  lw.f.main_fn = lw.is_program_main()
  lw.f.exit_scope = if lw.f.main_fn { lw.f.scopes.len() } else { -1 }
  let v = match c.body {
    some(Expr(e)) => {
      lw.dbg_hook(e.span, true)
      lw.expr_t(e, true)
    }
    some(Block(b)) => lw.block(b, true)
    _ => val_unit()
  }
  lw.f.exit_scope = -1
  lw.ret_val(v, ret)
  lw.pop()
  if guarded { lw.close() }
  lw.pop()
  lw.close()
}

/// Return a value from the current function (releasing every scope).
fn ret_val(lw: var Lower, v: Val, ret: types.Ty) {
  if v.is_never() { return }
  let o = lw.own_as(v, ret)
  let rv = lw.decl(ret, o)
  if lw.f.main_fn { lw.cleanup_main_exit() } else { lw.cleanup_from(0) }
  lw.emit(mir.Stmt.Ret(rv))
}

/// Is this the program's `main`, in an executable (`auk build`)?
fn is_program_main(lw: var Lower): bool {
  if lw.g.mode != mir.progen.Mode.Release { return false }
  match lw.tp.main {
    some(mi) => lw.tp.instances[lw.inst].body == typed.BodyRef.Fn(mi.func)
    none => false
  }
}

/// `cleanup_from(0)` at a `return` from the program's `main`.
fn cleanup_main_exit(lw: var Lower) {
  var rels: [(mir.Ex, types.Ty)] = []
  var si = lw.f.scopes.len() - 1
  while si >= 0 {
    let owned = lw.f.scopes[si].owned
    var p = owned.len() - 1
    while p >= 0 {
      rels.push(owned[p])
      p -= 1
    }
    si -= 1
  }
  lw.release_at_exit(rels)
}

/// Release `rels` (in order) where the program's `main` ends normally: the process is about
/// to end, so values that can't reach a handle are released only when the runtime asks for it
/// (`auk_exit_fast` is 0: a program run inside the compiler, or AUK_LEAK_CHECK). Those that can
/// are always released (a task's release waits for it to finish).
fn release_at_exit(lw: var Lower, rels: [(mir.Ex, types.Ty)]) {
  var soft: [(mir.Ex, types.Ty)] = []
  for (c, ty) in rels {
    var seen: {types.Ty: bool} = {}
    if !mir.types.may_hold_handle(lw.g.info, ty, &seen) {
      soft.push((c, ty))
      continue
    }
    match lw.g.release(ty, c) {
      some(r) => lw.emit(r)
      none => {}
    }
  }
  if soft.len() == 0 { return }
  let fast = mir.rt_global("auk_exit_fast", ty_int()).deref(ty_int())
  lw.open_if(mir.bin(mir.BOp.Eq, fast, mir.int_(0)))
  for (c, ty) in soft {
    match lw.g.release(ty, c) {
      some(r) => lw.emit(r)
      none => {}
    }
  }
  lw.close()
}

/// The function `name` that checks `ensures` around the clause group's body `body_name`.
fn ensures_wrapper(
  lw: var Lower,
  fid: int,
  name: int,
  body_name: int,
  params: [(types.Ty, bool)],
  ret: types.Ty,
  hdr: ast.FnClause?,
  cls: [ast.FnClause],
) {
  let ps = lw.begin_fn(name, ret)
  lw.push(ScopeKind.Block)
  var pnames: [(mir.Ex, types.Ty, bool)] = []
  for k, (t, var_) in params { pnames.push((if var_ { ps[k].deref(d(t)) } else { ps[k] }, t, var_)) }
  match hdr {
    some(h) => {
      for k, p in h.params {
        if p.pat.kind is ast.PatKind.Bind(_) {
          match lw.t.binds.get(p.pat.id) {
            some(l) => lw.bind_name(l, Slot { c: pnames[k].0, ty: params[k].0 })
            none => {}
          }
        }
      }
      lw.capture_olds(fid, h)
    }
    none => {}
  }
  // with clause `ensures`, find the clause that will run (tried in order, like the body)
  let dispatch = cls.any(c => c.post.len() > 0)
  if dispatch {
    for c in cls {
      var conds: [mir.Ex] = []
      for k, p in c.params { conds.push(lw.pat_test(p.pat, pnames[k].0)) }
      lw.open_if(and_tests(conds))
      lw.push(ScopeKind.Block)
      for k, p in c.params { lw.bind_top(p.pat, pnames[k].0, pnames[k].1) }
      let guarded = lw.guard(c.guard)
      lw.capture_olds(fid, c)
      lw.call_and_check(fid, body_name, ps, ret, hdr, some(c))
      if guarded { lw.close() }
      lw.pop()
      lw.close()
    }
  }
  lw.call_and_check(fid, body_name, ps, ret, hdr, none)
  lw.end(name)
}

/// Capture (as owned locals of the current scope) the `old(e)` values in `c`'s `ensures`.
fn capture_olds(lw: var Lower, fid: int, c: ast.FnClause) {
  var old_exprs: [ast.Expr] = []
  let olds = lw.tp.fns[fid].olds
  for e in c.post { collect_olds(e, olds, &old_exprs) }
  for e in old_exprs {
    let v = lw.expr(e)
    let ty = v.ty
    let o = lw.own_as(v, ty)
    let n = lw.decl(ty, o)
    lw.register(n, ty)
    lw.f.olds[e.id] = n
  }
}

/// In the `ensures` wrapper: call the body, check the header's and `clause`'s `ensures` on
/// its result, release everything and return it.
fn call_and_check(lw: var Lower, fid: int, body_name: int, ps: [mir.Ex], ret: types.Ty, hdr: ast.FnClause?, clause: ast.FnClause?) {
  let call = lw.g.call(body_name, ps)
  let r = lw.decl(ret, call)
  let is_res = ret is types.Ty.Res(_, _)
  match lw.tp.fns[fid].result_local {
    some(l) => {
      let (c, t) = match ret {
        Res(t, _) => (lw.fld(r, mir.Sel.F(1)), t)
        t => (r, t)
      }
      lw.bind_name(l, Slot { c, ty: t })
    }
    none => {}
  }
  if is_res { lw.open_if(lw.fld(r, mir.Sel.F(0))) }
  var ens: [ast.Expr] = []
  match hdr {
    some(h) => ens = ens + h.post
    none => {}
  }
  match clause {
    some(c) => ens = ens + c.post
    none => {}
  }
  for e in ens {
    lw.push(ScopeKind.Stmt)
    let v = lw.expr(e)
    let cv = lw.val_as(v, types.Ty.Bool)
    let b = lw.decl(types.Ty.Bool, cv)
    lw.pop()
    let l = lw.loc(e.span)
    let text = mir.cstr(lw.g.span_text(lw.m, e.span))
    lw.open_if(b.not())
    lw.do_(mir.rt("auk_ensures_fail", [l, text], mir.MTy.Void))
    lw.close()
  }
  if is_res { lw.close() }
  lw.cleanup_from(0)
  lw.emit(mir.Stmt.Ret(r))
}

fn emit_test(lw: var Lower, body: ast.Block) {
  let outer = lw.g.inst_fn(lw.inst)
  let base = lw.g.prog.funcs[outer].name
  let ret = types.res(types.unit(), lw.g.err_ty())
  let inner = lw.g.declare("{base}_body", [], d(ret), mir.Abi.Auk)
  let _ = lw.begin_fn(inner, ret)
  match lw.tp.instances[lw.inst].body {
    Test(t) => {
      let n = "test \"{lw.tp.tests[t].name}\""
      lw.name_fn(inner, n)
      lw.dbg_begin(n)
    }
    _ => {}
  }
  lw.push(ScopeKind.Block)
  for s in body.stmts { lw.stmt(s) }
  lw.cleanup_from(0)
  let okv = lw.ok_(ret, mir.unit())
  lw.emit(mir.Stmt.Ret(okv))
  lw.f.scopes = []
  lw.end(inner)
  // the registered test: NULL on success, else the owned error
  let _ = lw.begin_fn(outer, types.unit())
  let r = lw.bdecl(lw.g.call(inner, []))
  let et = d(lw.g.err_ty())
  let e = mir.cond(lw.fld(r, mir.Sel.F(0)), mir.zero(et), lw.fld(r, mir.Sel.F(2)))
  lw.emit(mir.Stmt.Ret(e))
  lw.end(outer)
}

fn emit_const(lw: var Lower, value: ast.Expr) {
  let f = lw.g.inst_fn(lw.inst)
  let c = match lw.tp.instances[lw.inst].body {
    Const(c) => c
    _ => mir.bug("emit_const")
  }
  let ty = lw.tp.consts[c].ty
  let _ = lw.begin_fn(f, ty)
  lw.push(ScopeKind.Block)
  let v = lw.expr(value)
  lw.ret_val(v, ty)
  lw.f.scopes = []
  let z = lw.g.zero(ty)
  lw.emit(mir.Stmt.Ret(z))
  lw.end(f)
}

// ---- tail calls ----

/// Is `c`'s body (in tail position) a self call that can become a jump?
fn body_has_tail_call(lw: var Lower, c: ast.FnClause): bool = match c.body {
  some(Expr(e)) => lw.tail_scan(e)
  some(Block(b)) => {
    for s in b.stmts {
      if lw.any_return_tail(s) { return true }
    }
    match b.stmts.last() {
      some(s) => lw.tail_scan(s)
      none => false
    }
  }
  _ => false
}

fn any_return_tail(lw: var Lower, e: ast.Expr): bool {
  var xs: [ast.Expr] = []
  visit.visit_expr(e, &xs)
  var found = false
  for x in xs {
    match x.kind {
      Return(some(v)) => if lw.tail_scan(v) { found = true }
      _ => {}
    }
  }
  found
}

fn tail_scan(lw: var Lower, e: ast.Expr): bool = match e.kind {
  Block(b) => match b.stmts.last() {
    some(s) => lw.tail_scan(s)
    none => false
  }
  If(_, then, els) => {
    let a = match then.stmts.last() {
      some(s) => lw.tail_scan(s)
      none => false
    }
    a || match els {
      some(x) => lw.tail_scan(x)
      none => false
    }
  }
  Match(_, arms) => {
    for a in arms {
      if lw.tail_scan(a.body) { return true }
    }
    false
  }
  Return(some(x)) => lw.tail_scan(x)
  Call(_, _) | MethodCall(_, _, _) | Pipe(_, _, _) => lw.is_self_tail_call(e)
  _ => false
}

/// `&x`'s inner expression.
fn unref(x: ast.Expr): ast.Expr = match x.kind {
  Ref(i) => i
  _ => x
}

fn is_self_tail_call(lw: var Lower, e: ast.Expr): bool {
  let inst = lw.tp.instances[lw.inst]
  if inst.resolved.get(e.id) != some(typed.Target.Instance(lw.inst)) { return false }
  if lw.has_coercions(e.id) || (lw.ty(e.id) is types.Ty.Task(_)) { return false }
  let call = lw.t.calls.get(e.id) else return false
  let exprs = arg_exprs(e)
  for a in call.args {
    if !a.by_ref { continue }
    let x = find_expr(exprs, a.node) else return false
    let inner = unref(x)
    match lw.t.names.get(inner.id) {
      some(Local(l)) when (inner.kind is ast.ExprKind.Name(_)) && lw.f.var_params.contains(l) => {}
      _ => return false
    }
  }
  true
}

fn tail_call(lw: var Lower, e: ast.Expr): Val {
  let call = lw.t.calls[e.id]
  let exprs = arg_exprs(e)
  let tc = lw.f.tail!
  let params = tc.params
  let label = tc.label
  var news: [mir.Ex] = []
  for k, a in call.args {
    let x = find_expr(exprs, a.node)!
    if a.by_ref {
      let inner = unref(x)
      let l = match lw.t.names.get(inner.id) {
        some(Local(l)) => l
        _ => mir.bug("tail_call")
      }
      let slot = lw.f.locals[l]
      news.push(slot.c.addr())
    } else {
      let v = lw.expr(x)
      let o = lw.own_as(v, params[k].1)
      let n = lw.decl(params[k].1, o)
      news.push(n)
    }
  }
  lw.cleanup_from(1)
  for k, (p, ty, var_) in params {
    if !var_ {
      match lw.g.release(ty, p) {
        some(r) => lw.emit(r)
        none => {}
      }
    }
    lw.set(p, news[k])
  }
  lw.emit(mir.Stmt.Goto(label))
  val_never()
}

// ---- statements and blocks ----

pub fn stmt(lw: var Lower, e: ast.Expr) {
  lw.dbg_hook(e.span, false)
  lw.push(ScopeKind.Stmt)
  let _ = lw.expr(e)
  lw.pop()
}

/// Statements whose values are dropped (a loop body).
fn stmts(lw: var Lower, ss: [ast.Expr]) {
  for i, s in ss {
    if !lw.move_out(ss, i) { lw.stmt(s) }
  }
}

/// A block's value (owned when it has one).
fn block(lw: var Lower, b: ast.Block, tail: bool): Val {
  lw.push(ScopeKind.Block)
  let n = b.stmts.len()
  var out = val_unit()
  for i, s in b.stmts {
    if i + 1 < n {
      if lw.move_out(b.stmts, i) { continue }
      lw.stmt(s)
      continue
    }
    lw.dbg_hook(s.span, false)
    let v = lw.expr_t(s, tail)
    if v.is_never() {
      out = v
    } else if has_value(v.ty) || lw.g.needs_rc(v.ty) {
      let ty = v.ty
      let h = lw.hold(v)
      out = Val { c: h, ty, owned: true }
    } else {
      out = v
      if !out.c.is_simple() {
        let c = lw.decl(out.ty, out.c)
        out = Val { c, ty: out.ty, owned: out.owned }
      }
    }
  }
  lw.pop()
  if out.owned && !out.is_never() { out = lw.reown(out.c, out.ty) }
  if n == 0 {
    match lw.t.coercions.get(b.id) {
      some(cs) => out = lw.coerce(out, cs, b.id)
      none => {}
    }
  }
  out
}

/// Taking an element out of a list or map to change it and put it back,
/// ```text
/// var g = items[k]      // stmts[0]
/// g.clauses.push(c)     // anything that doesn't mention `items`
/// items[k] = g          // the same place, the same index
/// ```
/// moves the element out (see src/mir/lower.rs). `stmts[start..]` are the statements. Returns
/// whether it lowered `stmts[start]` this way.
fn move_out(lw: var Lower, stmts: [ast.Expr], start: int): bool {
  // (a debugger stopped in between would see the hole)
  if lw.f.dbg != none { return false }
  let first = stmts[start]
  let (pat, value) = match first.kind {
    Let(true, pat, _, value, none) => (pat, value)
    _ => return false
  }
  let x = match pat.kind {
    Bind(x) => x
    _ => return false
  }
  if lw.t.variants.contains(pat.id) || lw.has_coercions(value.id) { return false }
  let (cont, index) = match value.kind {
    Index(c, i) => (c, i)
    _ => return false
  }
  let cname = match cont.kind {
    Name(n) => n
    _ => return false
  }
  let cl = match lw.t.names.get(cont.id) {
    some(Local(l)) => l
    _ => return false
  }
  // a plain variable of this frame (var parameters and catch captures are pointers)
  let plain_var = match lw.f.locals.get(cl) {
    some(sl) => sl.c.is_var()
    none => false
  }
  if !plain_var || lw.f.var_params.contains(cl) { return false }
  let ty = lw.ty(value.id)
  let ct = lw.ty(cont.id)
  if !((ct is types.Ty.List(_)) || (ct is types.Ty.Map(_, _))) || !lw.g.needs_rc(ty) || !lw.pure_read(index) {
    return false
  }
  let xl = lw.t.binds.get(pat.id) else return false
  if lw.local_ty(xl) != ty { return false }
  var inames = new_scan()
  inames.scan(index)
  // find the store back
  var between = new_scan()
  var j = start + 1
  while j < stmts.len() {
    let st = stmts[j]
    var back = false
    match st.kind {
      Assign(none, target, v) => match target.kind {
        Index(c2, i2) => {
          let same_c = match lw.t.names.get(c2.id) {
            some(Local(l)) => l == cl
            _ => false
          }
          let same_x = match lw.t.names.get(v.id) {
            some(Local(l)) => l == xl
            _ => false
          }
          back = same_c && same_x && lw.same_index(index, i2)
        }
        _ => {}
      }
      _ => {}
    }
    if back {
      let _ = x
      if between.exits || between.names.contains(cname) || inames.names.keys().any(n => between.changed.contains(n)) {
        return false
      }
      lw.dbg_hook(first.span, false)
      lw.push(ScopeKind.Stmt)
      let (pl, _) = lw.place(value)
      let v = lw.bdecl(pl)
      let z = lw.g.zero(ty)
      lw.set(pl, z)
      let val = lw.reown(v, ty)
      lw.let_binds()
      lw.bind_value(pat, val)
      lw.pop()
      return true
    }
    between.scan(st)
    if between.exits || between.names.contains(cname) { return false }
    j += 1
  }
  false
}

/// Are two index expressions the same value (both evaluated with the same variables)?
fn same_index(lw: var Lower, a: ast.Expr, b: ast.Expr): bool = match (a.kind, b.kind) {
  (Lit(x), Lit(y)) => x == y
  (Name(_), Name(_)) => lw.same_operand(a, b)
  (Binary(o1, l1, r1), Binary(o2, l2, r2)) =>
    o1 == o2 && !lw.t.calls.contains(a.id) && lw.same_index(l1, l2) && lw.same_index(r1, r2)
  (Field(x, n1), Field(y, n2)) => n1.name == n2.name && lw.same_index(x, y)
  (MethodCall(r1, n1, a1), MethodCall(r2, n2, a2)) =>
    n1.name == n2.name && n1.name == "len" && a1.len() == 0 && a2.len() == 0 && lw.same_index(r1, r2)
  _ => false
}

// ---- expressions ----

pub fn expr(lw: var Lower, e: ast.Expr): Val = lw.expr_t(e, false)

pub fn expr_t(lw: var Lower, e: ast.Expr, tail: bool): Val {
  let v = lw.expr_inner(e, tail)
  match lw.t.coercions.get(e.id) {
    some(cs) when !v.is_never() && cs.len() > 0 => lw.coerce(v, cs, e.id)
    _ => v
  }
}

pub fn coerce(lw: var Lower, v0: Val, cs: [typed.Coercion], node: int): Val {
  var v = v0
  for c in cs {
    match c {
      WrapSome => {
        let ty = types.opt(v.ty)
        let o = lw.own(v)
        let e = lw.some_(ty, o)
        v = lw.tmp(ty, e)
      }
      WrapOk => {
        let ty = types.res(v.ty, lw.g.err_ty())
        let o = lw.own(v)
        let e = lw.ok_(ty, o)
        v = lw.tmp(ty, e)
      }
      ToAny(s) => {
        let vid = lw.tp.instances[lw.inst].vtables.get(node)
        let ty = types.Ty.Any(s)
        let vt = match vid {
          some(vid) => lw.vtable(vid)
          none => mir.null()
        }
        let src = v.ty
        let o = lw.own(v)
        let b = lw.g.box_new(src, o)
        let e = mir.agg(d(ty), [(mir.Sel.F(0), b), (mir.Sel.F(1), vt.cast(mir.void_ptr()))])
        v = lw.tmp(ty, e)
      }
    }
  }
  v
}

fn expr_inner(lw: var Lower, e: ast.Expr, tail: bool): Val = match e.kind {
  Lit(l) => match lw.ty(e.id) {
    Fixed(k) => mir.lower.lowlevel.fixed_lit(l, false, types.Ty.Fixed(k))
    // the runtime's dialect: a C string constant
    Ptr(p) => match l {
      Str(s) => plain(mir.cstr(s).cast(d(types.Ty.Ptr(p))), types.Ty.Ptr(p))
      _ => lw.lit(l, false)
    }
    _ => lw.lit(l, false)
  }
  // units are erased: the literal's value
  Measured(x, _) => lw.expr_inner(x, tail)
  Interp(parts) => lw.interp(parts)
  Name(_) => lw.name_ref(e)
  Hole => {
    let ty = lw.ty(e.id)
    let l = lw.loc(e.span)
    let exp = lw.g.show_ty(ty)
    lw.g.note_hole("{lw.file}:{e.span.line}:{e.span.col}", exp)
    lw.do_(mir.rt("auk_hole", [l, mir.cstr(exp)], mir.MTy.Void))
    val_never()
  }
  Field(x, name) => {
    if lw.t.names.contains(e.id) { return lw.name_ref(e) }
    // a field of an element read: retain the field, not the element
    if lw.borrowable(x) {
      let b = lw.expr_borrow(x)
      let v = lw.field_val(e, b, name.name)
      return lw.own_tmp(v)
    }
    let b = lw.expr(x)
    lw.field_val(e, b, name.name)
  }
  TupleField(x, index) => {
    let borrowed = lw.borrowable(x)
    let b = if borrowed { lw.expr_borrow(x) } else { lw.expr(x) }
    if b.is_never() { return val_never() }
    let ty = lw.ty(e.id)
    let v = Val { c: lw.fld(b.c, mir.Sel.F(index)), ty, owned: false }
    if borrowed { lw.own_tmp(v) } else { v }
  }
  Call(_, _) | MethodCall(_, _, _) | Pipe(_, _, _) => lw.call(e, none, tail)
  Index(x, index) => lw.index(e, x, index)
  Slice(x, lo, hi, inclusive) => {
    let xv = lw.expr(x)
    let l = lw.expr(lo)
    let h = lw.expr(hi)
    let lc = lw.loc(e.span)
    let hc = if inclusive { mir.rt("auk_add", [h.c, mir.int_(1), lc], ty_int()) } else { h.c }
    let ty = xv.ty
    let f = if ty == types.Ty.Str { "auk_str_slice" } else { "auk_arr_slice" }
    let call = mir.rt(f, [xv.c, l.c, hc, lc], d(ty))
    lw.tmp(ty, call)
  }
  Unary(op, x) => match op {
    Not => {
      let v = lw.expr(x)
      let c = v.c.not()
      lw.tmp(types.Ty.Bool, c)
    }
    BitNot => {
      let v = lw.expr(x)
      if v.ty is types.Ty.Fixed(_) { return lw.tmp(v.ty, mir.lower.lowlevel.fixed_un(mir.UOp.BitNot, v.c, v.ty)) }
      let c = mir.ex(mir.K.Un(mir.UOp.BitNot, v.c), ty_int())
      lw.tmp(types.Ty.Int, c)
    }
    Neg => {
      match x.kind {
        Lit(l) => match l {
          Int(_) | Float(_) => return match lw.ty(x.id) {
            Fixed(k) => mir.lower.lowlevel.fixed_lit(l, true, types.Ty.Fixed(k))
            _ => lw.lit(l, true)
          }
          _ => {}
        }
        _ => {}
      }
      let v = lw.expr(x)
      if v.ty is types.Ty.Fixed(_) { return lw.tmp(v.ty, mir.lower.lowlevel.fixed_un(mir.UOp.Neg, v.c, v.ty)) }
      if v.ty == types.Ty.Int {
        let lc = lw.loc(e.span)
        let c = mir.rt("auk_neg", [v.c, lc], ty_int())
        lw.tmp(types.Ty.Int, c)
      } else {
        let c = mir.ex(mir.K.Un(mir.UOp.Neg, v.c), d(types.Ty.Float))
        lw.tmp(types.Ty.Float, c)
      }
    }
  }
  Binary(op, l, r) => lw.binary(e, op, l, r)
  Range(lo, hi, inclusive) => {
    let l = lw.expr(lo)
    let h = lw.expr(hi)
    let new = mir.rt("auk_arr_new", [mir.rt_global("auk_ops_int", mir.MTy.Rt(mir.Rt.ElemOps)), mir.int_(0)], d(types.list(types.Ty.Int)))
    let xs = lw.tmp(types.list(types.Ty.Int), new)
    let i = lw.decl(types.Ty.Int, l.c)
    let hv = lw.decl(types.Ty.Int, h.c)
    lw.f.b.open_loop([mir.Stmt.Set(i, mir.bin(mir.BOp.Add, i, mir.int_(1)))])
    let op = if inclusive { mir.BOp.Le } else { mir.BOp.Lt }
    lw.open_if(mir.bin(op, i, hv).not())
    lw.emit(mir.Stmt.Break)
    lw.close()
    lw.do_(mir.rt("auk_arr_push", [xs.c.addr(), i.addr()], mir.MTy.Void))
    lw.emit(mir.Stmt.Continue)
    lw.close()
    xs
  }
  Is(x, pat) => {
    let v = lw.expr_borrow(x)
    let vc = lw.lvalue(v, v.ty)
    let c = lw.pat_test(pat, vc)
    lw.tmp(types.Ty.Bool, c)
  }
  Try(x) => lw.try_(e, x)
  Unwrap(x) => {
    let v = lw.expr(x)
    if v.is_never() { return v }
    let lc = lw.loc(e.span)
    let w = lw.hold(v)
    let ty = lw.ty(e.id)
    lw.open_if(lw.fld(w, mir.Sel.F(0)).not())
    match v.ty {
      Opt(_) => lw.do_(mir.rt("auk_unwrap_none", [lc], mir.MTy.Void))
      _ => lw.do_(mir.rt("auk_unwrap_err", [lc, lw.fld(w, mir.Sel.F(2))], mir.MTy.Void))
    }
    lw.emit(mir.Stmt.Unreachable)
    lw.close()
    let val = lw.fld(w, mir.Sel.F(1))
    lw.adopt(ty, val)
  }
  OptChain(x, name, args) => lw.opt_chain(e, x, name, args != none)
  TypeArgs(x, _) => lw.expr_inner(x, tail)
  FieldSel(_) => val_unit()
  Uninit => {
    let ty = lw.ty(e.id)
    plain(mir.ex(mir.K.Undef, d(ty)), ty)
  }
  Else(x, arm) => lw.else_expr(e, x, arm)
  Await(x) => lw.await_(e, x)
  Catch(x) => lw.catch_(e, x)
  AwaitAny(x) => lw.await_any(e, x)
  Ref(x) => lw.expr(x)
  Closure(params, body) => lw.closure(e, params, body)
  If(cond, then, els) => lw.if_(e, cond, then, els, tail)
  Match(scrut, arms) => lw.match_(e, scrut, arms, tail)
  Loop(b) => {
    let ty = lw.ty(e.id)
    let r = if has_value(ty) { some(lw.zero_decl(ty)) } else { none }
    lw.f.b.open_loop([])
    lw.cancel_point(e.span)
    lw.push(ScopeKind.Block)
    let depth = lw.f.scopes.len() - 1
    let result = match r {
      some(r) => some((r, ty))
      none => none
    }
    lw.f.loops.push(LoopCx { depth, result })
    lw.stmts(b.stmts)
    let _ = lw.f.loops.pop()
    lw.pop()
    lw.close()
    match r {
      some(r) => lw.reown(r, ty)
      none => if ty == types.Ty.Never { val_never() } else { val_unit() }
    }
  }
  While(cond, body) => {
    lw.f.b.open_loop([])
    lw.cancel_point(e.span)
    lw.push(ScopeKind.Stmt)
    let c = lw.expr(cond)
    let cc = lw.val_as(c, types.Ty.Bool)
    let cv = lw.decl(types.Ty.Bool, cc)
    lw.pop()
    lw.open_if(cv.not())
    lw.emit(mir.Stmt.Break)
    lw.close()
    lw.push(ScopeKind.Block)
    let depth = lw.f.scopes.len() - 1
    lw.f.loops.push(LoopCx { depth, result: none })
    for s in body.stmts { lw.stmt(s) }
    let _ = lw.f.loops.pop()
    lw.pop()
    lw.close()
    val_unit()
  }
  For(index, pat, iter, body) => {
    lw.for_(e, index, pat, iter, body)
    val_unit()
  }
  Block(b) => lw.block(b, tail)
  Let(_, pat, _, value, els) => {
    lw.let_(e, pat, value, els)
    val_unit()
  }
  Assign(op, target, value) => {
    lw.assign(e, op, target, value)
    val_unit()
  }
  Assert(x) => {
    lw.assert_(x)
    val_unit()
  }
  Return(x) => {
    let ret = lw.f.ret
    let v = match x {
      some(x) => lw.expr_t(x, true)
      none => match lw.t.coercions.get(e.id) {
        some(cs) => lw.coerce(val_unit(), cs, e.id)
        none => val_unit()
      }
    }
    lw.ret_val(v, ret)
    val_never()
  }
  Break(x) => {
    let lp = lw.f.loops.last() else return val_never()
    let depth = lp.depth
    let result = lp.result
    match x {
      some(x) => {
        let v = lw.expr(x)
        match result {
          some((r, ty)) => {
            let o = lw.own_as(v, ty)
            lw.set(r, o)
          }
          none => {}
        }
      }
      // a bare `break` out of a `loop` whose value is `()!` / `()?`: the checker recorded the
      // auto-wrap of `()` on this node
      none => match (result, lw.t.coercions.get(e.id)) {
        (some((r, ty)), some(cs)) => {
          let v = lw.coerce(val_unit(), cs, e.id)
          let o = lw.own_as(v, ty)
          lw.set(r, o)
        }
        _ => {}
      }
    }
    lw.cleanup_from(depth)
    lw.emit(mir.Stmt.Break)
    val_never()
  }
  Continue => {
    match lw.f.loops.last() {
      some(lp) => {
        lw.cleanup_from(lp.depth)
        lw.emit(mir.Stmt.Continue)
      }
      none => {}
    }
    val_never()
  }
  Peek(x) => {
    let v = lw.expr(x)
    let shown = lw.show_of(x.id, v)
    let s = lw.decl(types.Ty.Str, shown)
    let lc = mir.cstr("{lw.file}:{e.span.line}")
    let text = mir.cstr(lw.g.span_text(lw.m, x.span))
    lw.do_(mir.rt("auk_peek", [lc, text, s], mir.MTy.Void))
    lw.do_(mir.rt("auk_release", [s], mir.MTy.Void))
    v
  }
  Struct(_, _, _) => lw.struct_lit(e)
  List(xs) => {
    let ty = lw.ty(e.id)
    let et = match ty {
      List(et) => et
      _ => return val_never()
    }
    let ops = lw.g.ops(et)
    let new = mir.rt("auk_arr_new", [ops, mir.int_(xs.len())], d(ty))
    if xs.len() == 0 { return lw.tmp(ty, new) }
    var parts: [mir.Ex] = []
    for x in xs {
      let v = lw.expr(x)
      parts.push(lw.val_as(v, et))
    }
    // the array is built after its elements are evaluated (like a C array literal)
    let a = lw.tmp(ty, new)
    for c in parts {
      let el = if c.is_place() { c } else { lw.decl(et, c) }
      lw.do_(mir.rt("auk_arr_push", [a.c.addr(), el.addr()], mir.MTy.Void))
    }
    a
  }
  Map(es) => {
    let ty = lw.ty(e.id)
    let (kt, vt) = match ty {
      Map(k, v) => (k, v)
      _ => return val_unit()
    }
    let ko = lw.g.ops(kt)
    let vo = lw.g.ops(vt)
    let new = mir.rt("auk_map_new", [ko, vo], d(ty))
    let m = lw.tmp(ty, new)
    for (k, v) in es {
      let kv = lw.expr(k)
      let kc = lw.lvalue(kv, kt)
      let vv = lw.expr(v)
      let vc = lw.lvalue(vv, vt)
      lw.do_(mir.rt("auk_map_set", [m.c.addr(), kc.addr(), vc.addr()], mir.MTy.Void))
    }
    m
  }
  Tuple(xs) => {
    if xs.len() == 0 { return val_unit() }
    let ty = lw.ty(e.id)
    let ts = match ty {
      Tuple(ts) => ts
      _ => return val_never()
    }
    var vals: [Val] = []
    for x in xs { vals.push(lw.expr(x)) }
    var parts: [(mir.Sel, mir.Ex)] = []
    for i, v in vals {
      if i < ts.len() { parts.push((mir.Sel.F(i), lw.own_as(v, ts[i]))) }
    }
    lw.tmp(ty, mir.agg(d(ty), parts))
  }
}

fn lit(lw: var Lower, l: ast.Lit, neg: bool): Val = match l {
  Int(n) => plain(mir.int_(if neg { 0 -% n } else { n }), types.Ty.Int)
  Float(x) => plain(mir.float_(if neg { -x } else { x }), types.Ty.Float)
  Bool(b) => plain(mir.bool_(b), types.Ty.Bool)
  Char(c) => plain(mir.int_as(int(c), d(types.Ty.Char)), types.Ty.Char)
  Str(s) => {
    let gl = lw.g.lit(s)
    plain(gl, types.Ty.Str)
  }
}

fn closure_val(f: int, fnty: types.Ty, env: mir.Ex): mir.Ex =
  mir.agg(d(fnty), [(mir.Sel.F(0), mir.fn_addr(f)), (mir.Sel.F(1), env)])

fn name_ref(lw: var Lower, e: ast.Expr): Val {
  let n = lw.t.names.get(e.id) else return val_never()
  match n {
    Local(l) => {
      match lw.f.locals.get(l) {
        some(s) => return plain(s.c, s.ty)
        none => {}
      }
      // a local we never bound (unreachable code): a zero
      let ty = lw.local_ty(l)
      let z = lw.g.zero(ty)
      plain(z, ty)
    }
    Const(c) => {
      let gt = lw.g.const_getter(c)
      let ty = lw.tp.consts[c].ty
      plain(lw.g.call(gt, []), ty)
    }
    Fn(func, _) => {
      let ty = lw.ty(e.id)
      let target = lw.tp.instances[lw.inst].resolved.get(e.id) else return val_never()
      let w = lw.fn_value(target, some(func), ty)
      plain(closure_val(w, ty, mir.zero(mir.obj_ptr())), ty)
    }
    Variant(v) => {
      let ty = lw.ty(e.id)
      match ty {
        Fn(_, _) => {
          let target = typed.Target.Variant(v.def, v.index)
          let w = lw.fn_value(target, none, ty)
          plain(closure_val(w, ty, mir.zero(mir.obj_ptr())), ty)
        }
        _ => {
          let c = lw.g.variant_new(ty, v.index, [])
          plain(c, ty)
        }
      }
    }
    None => {
      let ty = lw.ty(e.id)
      let z = lw.g.zero(ty)
      plain(z, ty)
    }
    Global(g) => mir.lower.lowlevel.global_ref(&lw, g)
  }
}

// ---- calls ----

fn call(lw: var Lower, e: ast.Expr, first0: Val?, tail: bool): Val {
  match lw.t.fails.get(e.id) {
    some(k) => return lw.fail(e, k)
    none => {}
  }
  match lw.t.raw.get(e.id) {
    some(n) => return mir.lower.lowlevel.raw_node(&lw, e, n)
    none => {}
  }
  match e.kind {
    Call(callee, args) => match callee.kind {
      Name(n) => if n == "old" && args.len() == 1 {
        match lw.f.olds.get(args[0].id) {
          some(v) => {
            let ty = lw.ty(args[0].id)
            return plain(v, ty)
          }
          none => {}
        }
      }
      _ => {}
    }
    _ => {}
  }
  let call = lw.t.calls.get(e.id) else return val_never()
  let target = match lw.tp.instances[lw.inst].resolved.get(e.id) {
    some(t) => t
    none => mir.bug("codegen: unresolved call at {lw.file}:{e.span.line}:{e.span.col}")
  }
  if tail && lw.f.tail != none && first0 == none && lw.is_self_tail_call(e) { return lw.tail_call(e) }
  let exprs = arg_exprs(e)
  // `str(cs[a..b])`: the string straight from the char range, no slice in between
  match target {
    Extern(symbol, _) => if symbol == "auk_str_from_chars" && exprs.len() == 1 {
      let x = exprs[0]
      match x.kind {
        Slice(xe, lo, hi, inclusive) => if !lw.has_coercions(x.id) {
          let xv = lw.expr(xe)
          let l = lw.expr(lo)
          let h = lw.expr(hi)
          let lc = lw.loc(x.span)
          let hc = if inclusive { mir.rt("auk_add", [h.c, mir.int_(1), lc], ty_int()) } else { h.c }
          let c = mir.rt("auk_str_from_char_range", [xv.c, l.c, hc, lc], ty_str())
          return lw.tmp(types.Ty.Str, c)
        }
        _ => {}
      }
    }
    _ => {}
  }
  // the closure value is evaluated before its arguments
  let callee_val = match target {
    Closure => match e.kind {
      Call(callee, _) | Pipe(_, callee, _) => some(lw.expr(callee))
      _ => none
    }
    _ => none
  }
  let any_ref = call.args.any(a => a.by_ref)
  var first = first0
  var args: [ArgV] = []
  for k, a in call.args {
    if k == 0 && first != none {
      args.push(ArgV.Val(first!))
      first = none
      continue
    }
    let x = match find_expr(exprs, a.node) {
      some(x) => x
      none => mir.bug("codegen: missing argument node at {lw.file}:{e.span.line}:{e.span.col}")
    }
    if a.by_ref {
      let inner = unref(x)
      let (lv, ty) = lw.place(inner)
      args.push(ArgV.Addr(lv.addr(), ty))
    } else {
      // borrowed when the arguments after this one can't change anything
      var rest_pure = !any_ref
      if rest_pure {
        let later = call.args.skip(k + 1)
        for y in exprs {
          if rest_pure && later.any(b => b.node == y.id) && !lw.pure_read(y) { rest_pure = false }
        }
      }
      var v = lw.expr_borrow_if(x, rest_pure)
      // a value read from a variable that a `var` argument may change during the call
      // (`f(p.name, &p)`): an owned copy, so the change can't free it under the callee
      if any_ref && !v.owned && !v.is_never() && lw.g.needs_rc(v.ty) {
        let root = lw.root_local(x)
        var shared = false
        if root != none {
          for b in call.args {
            if b.by_ref && !shared {
              match find_expr(exprs, b.node) {
                some(y) => if lw.root_local(y) == root { shared = true }
                none => {}
              }
            }
          }
        }
        if shared { v = lw.own_tmp(v) }
      }
      if any_ref && !v.owned && !v.c.is_var() {
        let ty = v.ty
        let c = lw.val_as(v, ty)
        let n = lw.decl(ty, c)
        v = Val { c: n, ty, owned: false }
      }
      args.push(ArgV.Val(v))
    }
  }
  let func = match call.callee {
    Fn(f, _) => some(f)
    _ => none
  }
  var ret = lw.ty(e.id)
  // `x?.m()`: the node's type is the chain's `T?`; the call itself returns the member
  if e.kind is ast.ExprKind.OptChain(_, _, _) {
    let flatten = match lw.t.opt_chains.get(e.id) {
      some(o) => o.flatten
      none => false
    }
    if !flatten {
      match ret {
        Opt(m) => ret = m
        _ => {}
      }
    }
  }
  let lc = lw.loc(e.span)
  // an un-awaited `async fn` call: spawn a task (by the callee, not the type: a plain function
  // that returns a `Task` is called in place)
  match (target, ret) {
    (Instance(i), Task(_)) => match lw.tp.instances[i].body {
      Fn(f) => if lw.tp.fns[f].is_async { return lw.spawn(i, args, ret) }
      _ => {}
    }
    _ => {}
  }
  match target {
    Intrinsic(Raw(n), _) => {
      var targs: [types.Ty] = []
      match call.callee {
        Fn(_, ts) => for t in ts { targs.push(types.subst(t, lw.subst)) }
        _ => {}
      }
      return mir.lower.lowlevel.intrinsic(&lw, e, n, targs, args, ret)
    }
    _ => {}
  }
  lw.call_target(target, func, args, ret, lc, callee_val)
}

fn is_param(t: types.Ty): bool = t is types.Ty.Param(_)

/// Call a resolved target with evaluated arguments; returns the (owned) result.
fn call_target(lw: var Lower, target: typed.Target, func: int?, args: [ArgV], ret: types.Ty, lc: mir.Ex, callee: Val?): Val {
  match target {
    Instance(i) => {
      let f = lw.g.inst_fn(i)
      let ps = lw.g.inst_params(i)
      let rt = lw.g.inst_ret(i)
      var cs: [mir.Ex] = []
      for k, a in args {
        if k >= ps.len() { break }
        cs.push(match a {
          Val(v) => lw.val_as(v, ps[k].0)
          Addr(p, _) => p
        })
      }
      let call = lw.g.call(f, cs)
      match lw.tp.instances[i].body {
        Fn(fid) => if lw.g.traced(lw.tp.fns[fid].module) { lw.trace_site(lc) }
        _ => {}
      }
      lw.result(rt, call)
    }
    Extern(symbol, wants_loc) => lw.call_extern(symbol, wants_loc, func, args, ret, lc)
    Ffi(f) => lw.ffi_call(f, args, ret, lc)
    Intrinsic(which, ty) => lw.intrinsic(which, ty, args, ret)
    Derived(shape, ty) => {
      let which = match shape {
        Show => typed.Intrinsic.Show
        Eq => typed.Intrinsic.Eq
        Ord => typed.Intrinsic.Cmp
        Data => typed.Intrinsic.ToValue
      }
      lw.intrinsic(which, ty, args, ret)
    }
    Vtable(shape, method) => {
      let vt = lw.g.vt_struct(shape)
      if args.len() == 0 { return val_never() }
      let recv = match args[0] {
        Val(v) => v
        _ => return val_never()
      }
      let m = lw.tp.defs.shapes[shape].methods[method]
      var cs = [lw.fld(recv.c, mir.Sel.F(0))]
      var pts = [mir.obj_ptr()]
      var k = 1
      while k < args.len() && k < m.params.len() {
        let pt = lw.g.method_ty(m.params[k], shape)
        pts.push(d(pt))
        cs.push(match args[k] {
          Val(v) => lw.val_as(v, pt)
          Addr(p, _) => p
        })
        k += 1
      }
      let code = lw.fld(recv.c, mir.Sel.F(1)).cast(mir.ptr(mir.MTy.Agg(vt))).deref(mir.MTy.Agg(vt)).field(mir.Sel.F(method), mir.MTy.Code)
      let rt = lw.g.method_ty(m.ret, shape)
      let call = mir.ex(mir.K.Call(mir.Callee.Indirect(code, pts), cs), d(rt))
      lw.result(rt, call)
    }
    Variant(_, index) => {
      var fields: [(mir.Ex, bool)] = []
      let layout = mir.types.enum_layout(lw.g.info, ret)
      let isv = lw.g.is_value(ret)
      for k, a in args {
        var boxed = false
        let ft = if isv {
          a_ty(a)
        } else {
          match layout.get(index) {
            some(l) => match l.get(k) {
              some(x) => {
                boxed = x.1
                x.0
              }
              none => a_ty(a)
            }
            none => a_ty(a)
          }
        }
        match a {
          Val(v) => {
            // a borrowed read of a box's contents (a field bound from a matched value): share
            // that box instead of boxing a copy
            if boxed && !v.owned && !v.is_never() {
              match lw.g.unboxed_from(ft, v.c) {
                some(b) => {
                  lw.do_(mir.rt("auk_retain", [b], mir.void_ptr()))
                  fields.push((b, true))
                  continue
                }
                none => {}
              }
            }
            fields.push((lw.own_as(v, ft), false))
          }
          Addr(p, t) => fields.push((p.deref(d(t)), false))
        }
      }
      let c = lw.g.variant_new_pre(ret, index, fields)
      lw.tmp(ret, c)
    }
    Closure => {
      let c = callee else return val_never()
      let (ps, r) = match c.ty {
        Fn(ps, r) => (ps, r)
        _ => return val_never()
      }
      var pts = [mir.obj_ptr()]
      var cs = [lw.fld(c.c, mir.Sel.F(1))]
      for k, a in args {
        if k >= ps.len() { break }
        let pt = ps[k]
        pts.push(param_mty(pt))
        cs.push(match a {
          Val(v) => lw.val_as(v, pt)
          Addr(p, _) => p
        })
      }
      let code = lw.fld(c.c, mir.Sel.F(0))
      let call = mir.ex(mir.K.Call(mir.Callee.Indirect(code, pts), cs), d(r))
      lw.result(r, call)
    }
  }
}

fn call_extern(lw: var Lower, symbol: str, wants_loc: bool, func: int?, args: [ArgV], ret: types.Ty, lc: mir.Ex): Val {
  // `xs.push(x)` with an owned `x` (a fresh value): the list takes it, no retain
  if symbol == "auk_arr_push" && args.len() == 2 {
    match (args[0], args[1]) {
      (Addr(pa, _), Val(v)) => if v.owned && v.c.is_var() && lw.g.needs_rc(v.ty) {
        lw.unregister(v.c)
        let e = v.c.addr().cast(mir.void_ptr())
        lw.do_(mir.rt("auk_arr_push_own", [pa, e], mir.MTy.Void))
        return val_unit()
      }
      _ => {}
    }
  }
  let info = match func {
    some(f) => some(lw.tp.fns[f])
    none => none
  }
  var cs: [mir.Ex] = []
  for k, a in args {
    let generic = match info {
      some(i) => match i.params.get(k) {
        some(p) => is_param(p.ty)
        none => false
      }
      none => false
    }
    cs.push(match a {
      Addr(p, ty) => {
        // the runtime changes these in place (copying them first if shared), so it gets the
        // variable; other `var` arguments go by value
        if (ty is types.Ty.List(_)) || (ty is types.Ty.Map(_, _)) || mir.types.is_cow_opaque(lw.g.info, ty) {
          p
        } else {
          p.deref(d(ty))
        }
      }
      Val(v) => {
        let ty = v.ty
        if generic {
          let lv = lw.lvalue(v, ty)
          lv.addr().cast(mir.void_ptr())
        } else {
          lw.val_as(v, ty)
        }
      }
    })
  }
  let gret = match info {
    some(i) => i.ret
    none => ret
  }
  let out_ty = match (gret, ret) {
    (Opt(gt), Opt(c)) when is_param(gt) => some(c)
    (Param(_), c) => some(c)
    _ => none
  }
  match out_ty {
    some(ot) => {
      let out = lw.zero_decl(ot)
      cs.push(out.addr().cast(mir.void_ptr()))
      if wants_loc { cs.push(lc) }
      if ret is types.Ty.Opt(_) {
        let call = mir.rt(symbol, cs, mir.MTy.Bool)
        let okv = lw.decl(types.Ty.Bool, call)
        let e = mir.agg(d(ret), [(mir.Sel.F(0), okv.cast(mir.MTy.Bool)), (mir.Sel.F(1), out)])
        lw.tmp(ret, e)
      } else {
        lw.do_(mir.rt(symbol, cs, mir.MTy.Void))
        lw.reown(out, ot)
      }
    }
    none => {
      if wants_loc { cs.push(lc) }
      if ret == types.Ty.Never {
        // `proc.exit` doesn't return: release what this function owns first, as a `return`
        // would, so the leak check it runs is exact.
        lw.cleanup_from(0)
      }
      if types.is_unit(ret) && types.is_unit(gret) {
        lw.do_(mir.rt(symbol, cs, mir.MTy.Void))
        val_unit()
      } else if ret == types.Ty.Never {
        lw.do_(mir.rt(symbol, cs, mir.MTy.Void))
        val_never()
      } else {
        lw.result(ret, mir.rt(symbol, cs, d(ret)))
      }
    }
  }
}

/// The owned result of a call expression of Auk type `ty`.
fn result(lw: var Lower, ty: types.Ty, call: mir.Ex): Val {
  if types.is_unit(ty) {
    lw.do_(call)
    return val_unit()
  }
  if ty == types.Ty.Never {
    lw.do_(call)
    return val_never()
  }
  lw.tmp(ty, call)
}

fn intrinsic(lw: var Lower, which: typed.Intrinsic, ty: types.Ty, args: [ArgV], ret: types.Ty): Val {
  let vals = args.map(a => match a {
    Val(v) => v
    Addr(p, t) => plain(p.deref(d(t)), t)
  })
  match which {
    Show => {
      let s = lw.show_value(ty, vals[0])
      lw.adopt(types.Ty.Str, s)
    }
    Eq => {
      let a = lw.val_as(vals[0], ty)
      let b = lw.val_as(vals[1], ty)
      let c = lw.g.eq_expr(ty, a, b)
      lw.tmp(types.Ty.Bool, c)
    }
    Cmp => {
      let a = lw.val_as(vals[0], ty)
      let b = lw.val_as(vals[1], ty)
      let c = lw.g.cmp_expr(ty, a, b)
      lw.tmp(types.Ty.Int, c)
    }
    ToValue => {
      let f = lw.g.tov_fn(ty)
      let a = lw.val_as(vals[0], ty)
      let c = lw.g.call_ref(f, [a], d(ret))
      lw.adopt(ret, c)
    }
    FromValue => {
      let t = match ret {
        Res(t, _) => t
        t => t
      }
      let f = lw.g.fromv_fn(t)
      let c = lw.g.call_ref(f, [vals[0].c], d(ret))
      lw.adopt(ret, c)
    }
    Some => {
      let it = match ret {
        Opt(t) => t
        t => t
      }
      let o = lw.own_as(vals[0], it)
      let e = lw.some_(ret, o)
      lw.tmp(ret, e)
    }
    IntToFloat => {
      let c = vals[0].c.cast(d(types.Ty.Float))
      lw.tmp(types.Ty.Float, c)
    }
    CharToInt => {
      let c = vals[0].c.cast(ty_int())
      lw.tmp(types.Ty.Int, c)
    }
    Fail => val_never()
    Raw(n) => mir.bug("raw intrinsic `{n}` outside a call")
  }
}

/// `Show` text (an owned `str` expression) of a value of type `ty`, top-level form.
fn show_value(lw: var Lower, ty: types.Ty, v: Val): mir.Ex {
  let a = lw.val_as(v, ty)
  match lw.g.show_fn(ty) {
    some(f) => lw.g.call_ref(f, [a], ty_str())
    none => mir.rt("auk_str_lit", [mir.cstr("<{lw.g.show_ty(ty)}>")], ty_str())
  }
}

/// The show of an interpolation part / peek operand (via `Instance.shows`).
fn show_of(lw: var Lower, node: int, v: Val): mir.Ex {
  let target = lw.tp.instances[lw.inst].shows.get(node)
  let a = v.c
  match target {
    some(Instance(i)) => {
      let f = lw.g.inst_fn(i)
      lw.g.call(f, [a])
    }
    some(Extern(symbol, _)) => mir.rt(symbol, [a], ty_str())
    _ => lw.show_value(v.ty, v)
  }
}

fn spawn(lw: var Lower, i: int, args: [ArgV], ret: types.Ty): Val {
  let ps = lw.g.inst_params(i)
  let rt = lw.g.inst_ret(i)
  let (thunk, argty) = lw.thunk(i)
  let args_drop = lw.g.memo2["thunkdrop{i}"]
  // the task's heap, with deep copies of the arguments in it (it shares nothing with us)
  let heap = lw.bdecl(mir.rt("auk_heap_new", [], mir.void_ptr()))
  var vals: [mir.Ex] = []
  for a in args {
    vals.push(match a {
      Val(v) => lw.bdecl(v.c)
      Addr(p, _) => p
    })
  }
  let old = lw.bdecl(mir.rt("auk_heap_switch", [heap], mir.void_ptr()))
  var fields: [(mir.Sel, mir.Ex)] = []
  for k, v in vals {
    if k >= ps.len() { break }
    let (pt, var_) = ps[k]
    let c = if var_ { v } else { lw.g.copy_ex(pt, v) }
    fields.push((mir.Sel.F(k), c))
  }
  let a = lw.bdecl(mir.agg(mir.MTy.Agg(argty), fields))
  lw.do_(mir.rt("auk_heap_switch", [old], mir.void_ptr()))
  // `auk run --live` narrows what the task can reach to its closure, when it gets exactly one
  // and nothing else that could hold a closure (sup children: `go(f)`)
  var closures: [int] = []
  for k, (t, var_) in ps {
    if !var_ && (t is types.Ty.Fn(_, _)) { closures.push(k) }
  }
  var others_plain = true
  for (t, var_) in ps {
    if others_plain && !((t is types.Ty.Fn(_, _)) || (!var_ && !lw.g.holds_fn(t))) { others_plain = false }
  }
  let hint = if closures.len() == 1 && others_plain {
    let clo = lw.g.fld(a, mir.Sel.F(closures[0]))
    lw.g.fld(clo, mir.Sel.F(0)).cast(mir.void_ptr())
  } else {
    mir.zero(mir.void_ptr())
  }
  let ops = if lw.g.needs_rc(rt) { lw.g.ops(rt) } else { mir.zero(mir.ptr(mir.MTy.Rt(mir.Rt.ElemOps))) }
  let call = mir.rt(
    "auk_task_spawn",
    [
      mir.fn_addr(thunk),
      a.addr().cast(mir.void_ptr()),
      mir.size_of(mir.MTy.Agg(argty)),
      mir.size_of(d(rt)),
      ops,
      heap,
      mir.fn_addr(args_drop),
      hint,
    ],
    d(ret),
  )
  lw.tmp(ret, call)
}

/// The thunk that runs instance `i` on a task thread: (thunk, argument aggregate).
fn thunk(lw: var Lower, i: int): (int, int) {
  let key = "thunk{i}"
  match lw.g.memo2.get(key) {
    some(n) => return (n, lw.g.memo2["thunkargs{i}"])
    none => {}
  }
  let ps = lw.g.inst_params(i)
  let rt = lw.g.inst_ret(i)
  let f = lw.g.inst_fn(i)
  let fields = ps.map(p => if p.1 { mir.ptr(d(p.0)) } else { d(p.0) })
  let argty = lw.g.agg("dk_thunk{i}_args", fields)
  let n = lw.g.declare("dk_thunk{i}", [mir.void_ptr(), mir.void_ptr()], mir.MTy.Void, mir.Abi.C)
  lw.g.memo2[key] = n
  lw.g.memo2["thunkargs{i}"] = argty
  let (b0, pv) = lw.g.body_for(n)
  var b = b0
  let x = pv[0].cast(mir.ptr(mir.MTy.Agg(argty))).deref(mir.MTy.Agg(argty))
  var call: [mir.Ex] = []
  var rels: [mir.Stmt] = []
  for k, (pt, var_) in ps {
    let a = lw.g.fld(x, mir.Sel.F(k))
    if !var_ {
      match lw.g.release(pt, a) {
        some(r) => rels.push(r)
        none => {}
      }
    }
    call.push(a)
  }
  let c = lw.g.call(f, call)
  b.set(pv[1].cast(mir.ptr(d(rt))).deref(d(rt)), c)
  for r in rels { b.emit(r) }
  lw.g.define(n, b)
  // what the thunk releases after the call, for a task that crashes before that: its
  // arguments' handles (a channel, a connection) aren't in its heap
  let drop = lw.g.declare("dk_thunk{i}_drop", [mir.void_ptr()], mir.MTy.Void, mir.Abi.C)
  lw.g.memo2["thunkdrop{i}"] = drop
  let (b1, pv1) = lw.g.body_for(drop)
  var bd = b1
  let x1 = pv1[0].cast(mir.ptr(mir.MTy.Agg(argty))).deref(mir.MTy.Agg(argty))
  for k, (pt, var_) in ps {
    let a = lw.g.fld(x1, mir.Sel.F(k))
    if !var_ {
      match lw.g.release(pt, a) {
        some(r) => bd.emit(r)
        none => {}
      }
    }
  }
  lw.g.define(drop, bd)
  (n, argty)
}

/// A function usable as a closure (`R f(AukEnv *, args...)`) that calls `target`.
fn fn_value(lw: var Lower, target: typed.Target, func: int?, fty: types.Ty): int {
  let key = "fv{target}/{fty}"
  match lw.g.memo2.get(key) {
    some(n) => return n
    none => {}
  }
  let (ps, r) = match fty {
    Fn(ps, r) => (ps, r)
    _ => mir.bug("fn_value of a non-function")
  }
  let k = lw.g.fresh()
  var pts = [mir.obj_ptr()]
  for p in ps { pts.push(param_mty(p)) }
  let n = lw.g.declare("dk_fv{k}", pts, d(r), mir.Abi.Auk)
  lw.g.memo2[key] = n
  let pv = lw.begin_fn(n, r)
  lw.push(ScopeKind.Block)
  var args: [ArgV] = []
  for k2, p in ps {
    args.push(match p {
      // a `var` parameter: pass the caller's variable on
      Mut(t) => ArgV.Addr(pv[k2 + 1], t)
      _ => ArgV.Val(plain(pv[k2 + 1], p))
    })
  }
  let v = lw.call_target(target, func, args, r, mir.cstr("<fn>"), none)
  if types.is_unit(r) || r == types.Ty.Never {
    lw.cleanup_from(0)
    lw.emit(mir.Stmt.Ret(mir.zero(d(r))))
  } else {
    lw.ret_val(v, r)
  }
  lw.end(n)
  n
}

/// The vtable of a conversion to `any S` (by vtable id); returns its address.
fn vtable(lw: var Lower, vid: int): mir.Ex {
  let key = "vt{vid}"
  match lw.g.memo2.get(key) {
    some(gl) => return mir.ex(mir.K.GlobalAddr(gl), mir.void_ptr())
    none => {}
  }
  let vt = lw.tp.vtables[vid]
  let st = lw.g.vt_struct(vt.shape)
  let gl = lw.g.global("dk_vt{vid}", mir.MTy.Agg(st), none, true)
  lw.g.memo2[key] = gl
  let sh = lw.tp.defs.shapes[vt.shape]
  var ms: [(mir.Sel, mir.Ex)] = []
  for k, m in sh.methods {
    if k >= vt.methods.len() { break }
    let target = vt.methods[k]
    let r = lw.g.method_ty(m.ret, vt.shape)
    var pts = [mir.obj_ptr()]
    for p in m.params.skip(1) { pts.push(d(lw.g.method_ty(p, vt.shape))) }
    let mn = lw.g.declare("dk_vt{vid}_m{k}", pts, d(r), mir.Abi.Auk)
    let pv = lw.begin_fn(mn, r)
    lw.push(ScopeKind.Block)
    let recv = lw.g.unbox(vt.ty, pv[0])
    var args = [ArgV.Val(plain(recv, vt.ty))]
    for j, p in m.params {
      if j == 0 { continue }
      let pt = lw.g.method_ty(p, vt.shape)
      args.push(ArgV.Val(plain(pv[j], pt)))
    }
    let func = match target {
      Instance(i) => match lw.tp.instances[i].body {
        Fn(f) => some(f)
        _ => none
      }
      _ => none
    }
    let v = lw.call_target(target, func, args, r, mir.cstr("<vtable>"), none)
    if types.is_unit(r) {
      lw.cleanup_from(0)
      lw.emit(mir.Stmt.Ret(mir.zero(d(r))))
    } else {
      lw.ret_val(v, r)
    }
    lw.end(mn)
    ms.push((mir.Sel.F(k), mir.fn_addr(mn)))
  }
  lw.g.prog.globals[gl].init = some(mir.agg(mir.MTy.Agg(st), ms))
  mir.ex(mir.K.GlobalAddr(gl), mir.void_ptr())
}

fn fail(lw: var Lower, e: ast.Expr, kind: typed.FailKind): Val {
  let x = match e.kind {
    Call(_, args) => args.first()
    MethodCall(recv, _, _) => some(recv)
    Pipe(lhs, _, _) => some(lhs)
    _ => none
  }
  let x2 = x else return val_never()
  let v = lw.expr(x2)
  let et = d(lw.g.err_ty())
  let err = match kind {
    Message => mir.rt("auk_err_new", [v.c], et)
    Err => lw.own(v)
    _ => {
      let ty = v.ty
      let lv = lw.lvalue(v, ty)
      let id = lw.g.type_id(ty)
      let ops = lw.g.ops(ty)
      mir.rt("auk_err_typed", [mir.int_as(id, mir.MTy.U32), lv.addr().cast(mir.void_ptr()), ops, mir.zero(ty_str())], et)
    }
  }
  let ety = lw.g.err_ty()
  let en = lw.decl(ety, err)
  lw.return_err(en)
  val_never()
}

/// Return an owned `AukErr *` from the current (fallible) function.
fn return_err(lw: var Lower, err: mir.Ex) {
  let ret = lw.f.ret
  lw.cleanup_from(0)
  match ret {
    Res(_, _) => {
      let e = mir.agg(d(ret), [(mir.Sel.F(2), err)])
      lw.emit(mir.Stmt.Ret(e))
    }
    _ => {
      lw.do_(mir.rt("auk_release", [err], mir.MTy.Void))
      let z = lw.g.zero(ret)
      lw.emit(mir.Stmt.Ret(z))
    }
  }
}

// ---- operators ----

fn binary(lw: var Lower, e: ast.Expr, op: ast.BinOp, l: ast.Expr, r: ast.Expr): Val {
  match op {
    And | Or => {
      let lv = lw.expr(l)
      let lc = lw.val_as(lv, types.Ty.Bool)
      let res = lw.decl(types.Ty.Bool, lc)
      lw.open_if(if op == ast.BinOp.And { res } else { res.not() })
      lw.push(ScopeKind.Block)
      let rv = lw.expr(r)
      let rc = lw.val_as(rv, types.Ty.Bool)
      lw.set(res, rc)
      lw.pop()
      lw.close()
      return plain(res, types.Ty.Bool)
    }
    Eq | Ne | Lt | Le | Gt | Ge => {
      let lv = lw.expr_borrow_if(l, lw.pure_read(r))
      let rv = lw.expr_borrow(r)
      let c = lw.compare(e, op, lv, rv)
      return lw.tmp(types.Ty.Bool, c)
    }
    _ => {}
  }
  if lw.t.calls.contains(e.id) { return lw.call(e, none, false) }
  let lv = lw.expr_borrow_if(l, lw.pure_read(r))
  let rv = lw.expr_borrow(r)
  if lv.is_never() || rv.is_never() { return val_never() }
  let lc = lw.loc(e.span)
  let a = lv.c
  let b = rv.c
  match lv.ty {
    Int => {
      let c = int_op(op, a, b, lc)
      lw.tmp(types.Ty.Int, c)
    }
    Fixed(k) => {
      let t = types.Ty.Fixed(k)
      let c = mir.lower.lowlevel.fixed_bin(&lw, op, a, b, t)
      lw.tmp(t, c)
    }
    Float => {
      let c = match op {
        Add => mir.bin(mir.BOp.Add, a, b)
        Sub => mir.bin(mir.BOp.Sub, a, b)
        Mul => mir.bin(mir.BOp.Mul, a, b)
        Div => mir.bin(mir.BOp.Div, a, b)
        Rem => mir.rt("auk_fmod", [a, b], d(types.Ty.Float))
        Pow => mir.rt("auk_fpow", [a, b], d(types.Ty.Float))
        _ => mir.float_(0.0)
      }
      lw.tmp(types.Ty.Float, c)
    }
    Str => {
      let c = mir.rt("auk_str_concat", [a, b], ty_str())
      lw.tmp(types.Ty.Str, c)
    }
    List(_) => {
      let t = lv.ty
      let c = mir.rt("auk_arr_concat", [a, b], d(t))
      lw.tmp(t, c)
    }
    _ => val_never()
  }
}

fn rel(op: ast.BinOp, raw: mir.Ex): mir.Ex = match op {
  Eq => raw
  Ne => raw.not()
  Lt => mir.bin(mir.BOp.Lt, raw, mir.int_(0))
  Le => mir.bin(mir.BOp.Le, raw, mir.int_(0))
  Gt => mir.bin(mir.BOp.Gt, raw, mir.int_(0))
  _ => mir.bin(mir.BOp.Ge, raw, mir.int_(0))
}

/// A boolean expression for a comparison of two lowered operands.
fn compare(lw: var Lower, e: ast.Expr, op: ast.BinOp, l: Val, r: Val): mir.Ex {
  let is_eq = op == ast.BinOp.Eq || op == ast.BinOp.Ne
  if lw.t.calls.contains(e.id) {
    let target = lw.tp.instances[lw.inst].resolved.get(e.id)
    let ty = l.ty
    let a = lw.val_as(l, ty)
    let b = lw.val_as(r, ty)
    let rty = if is_eq { ty_bool() } else { ty_int() }
    let raw = match target {
      some(Instance(i)) => {
        let f = lw.g.inst_fn(i)
        lw.g.call(f, [a, b])
      }
      some(Extern(symbol, _)) => mir.rt(symbol, [a, b], rty)
      some(Intrinsic(_, t2)) | some(Derived(_, t2)) => if is_eq { lw.g.eq_expr(t2, a, b) } else { lw.g.cmp_expr(t2, a, b) }
      _ => if is_eq { lw.g.eq_expr(ty, a, b) } else { lw.g.cmp_expr(ty, a, b) }
    }
    return rel(op, raw)
  }
  let ty = if l.is_never() { r.ty } else { l.ty }
  let a = lw.val_as(l, ty)
  let b = lw.val_as(r, ty)
  let bop = match op {
    Eq => mir.BOp.Eq
    Ne => mir.BOp.Ne
    Lt => mir.BOp.Lt
    Le => mir.BOp.Le
    Gt => mir.BOp.Gt
    _ => mir.BOp.Ge
  }
  match ty {
    Int | Float | Char | Bool | Fixed(_) | Ptr(_) | CFn(_, _) => mir.bin(bop, a, b)
    Str => match op {
      Eq => mir.rt("auk_str_eq", [a, b], ty_bool())
      Ne => mir.rt("auk_str_eq", [a, b], ty_bool()).not()
      _ => mir.bin(bop, mir.rt("auk_str_cmp", [a, b], mir.MTy.I32), mir.int_as(0, mir.MTy.I32))
    }
    Never => mir.bool_(false)
    Tuple(ts) when ts.len() == 0 => mir.bool_(op == ast.BinOp.Eq || op == ast.BinOp.Le || op == ast.BinOp.Ge)
    t => {
      let raw = if is_eq { lw.g.eq_expr(t, a, b) } else { lw.g.cmp_expr(t, a, b) }
      rel(op, raw)
    }
  }
}

// ---- borrowed reads ----

/// Can evaluating `e` change a variable (or free anything a borrowed read points into)?
/// Conservative: only reads, operators and calls without `var` arguments are pure.
pub fn pure_read(lw: var Lower, e: ast.Expr): bool = match e.kind {
  Lit(_) | Name(_) => true
  Measured(x, _) | Field(x, _) | TupleField(x, _) | Unary(_, x) => lw.pure_read(x)
  Index(x, i) => lw.pure_read(x) && lw.pure_read(i)
  Slice(x, lo, hi, _) => lw.pure_read(x) && lw.pure_read(lo) && lw.pure_read(hi)
  Binary(_, l, r) => !lw.t.calls.contains(e.id) && lw.pure_read(l) && lw.pure_read(r)
  Interp(parts) => {
    for p in parts {
      match p {
        Expr(x, _) => if !lw.pure_read(x) { return false }
        _ => {}
      }
    }
    true
  }
  Call(_, _) | MethodCall(_, _, _) | Pipe(_, _, _) => {
    if lw.t.fails.contains(e.id) { return false }
    let call = lw.t.calls.get(e.id) else return false
    if call.args.any(a => a.by_ref) { return false }
    let callee_pure = match e.kind {
      Call(c, _) | Pipe(_, c, _) => lw.pure_read(c)
      _ => true
    }
    if !callee_pure { return false }
    for x in arg_exprs(e) {
      if !lw.pure_read(x) { return false }
    }
    true
  }
  _ => false
}

/// Is `e` an element read (or a field of one) that `expr_borrow` can read without RC?
fn borrowable(lw: var Lower, e: ast.Expr): bool {
  if lw.has_coercions(e.id) { return false }
  match e.kind {
    Index(x, i) => {
      let t = lw.ty(x.id)
      ((t is types.Ty.List(_)) || (t is types.Ty.Map(_, _))) && lw.pure_read(i)
    }
    Field(x, _) | TupleField(x, _) => !lw.t.names.contains(e.id) && lw.borrowable(x)
    _ => false
  }
}

/// `e` as a borrowed value where possible (see src/mir/lower.rs).
fn expr_borrow(lw: var Lower, e: ast.Expr): Val {
  if !lw.borrowable(e) { return lw.expr(e) }
  match e.kind {
    Index(x, i) => {
      let xv = lw.expr_borrow(x)
      let iv = lw.expr(i)
      lw.index_val(e, xv, iv, true)
    }
    Field(x, name) => {
      let b = lw.expr_borrow(x)
      lw.field_val(e, b, name.name)
    }
    TupleField(x, index) => {
      let b = lw.expr_borrow(x)
      if b.is_never() { return val_never() }
      let ty = lw.ty(e.id)
      Val { c: lw.fld(b.c, mir.Sel.F(index)), ty, owned: false }
    }
    _ => lw.expr(e)
  }
}

/// The local a place-like expression reads from (`p` for `p.a[i].b`, `&p`).
fn root_local(lw: var Lower, e: ast.Expr): int? = match e.kind {
  Name(_) => match lw.t.names.get(e.id) {
    some(Local(l)) => some(l)
    _ => none
  }
  Field(x, _) when !lw.t.names.contains(e.id) => lw.root_local(x)
  TupleField(x, _) | Index(x, _) | Slice(x, _, _, _) | Ref(x) => lw.root_local(x)
  _ => none
}

/// `expr_borrow` when everything evaluated after `e` (before its use) is pure.
fn expr_borrow_if(lw: var Lower, e: ast.Expr, rest_pure: bool): Val = if rest_pure { lw.expr_borrow(e) } else { lw.expr(e) }

/// Field `name` of the struct value `b` (borrowed from it).
fn field_val(lw: var Lower, e: ast.Expr, b: Val, name: str): Val {
  let bt = b.ty
  let ft = lw.ty(e.id)
  if bt is types.Ty.Ptr(_) { return mir.lower.lowlevel.ptr_field(&lw, b.c, bt, name, ft) }
  if bt is types.Ty.Named(_, _) {
    if b.is_never() { return val_never() }
    let i = lw.field_index(bt, name) else return val_never()
    let c = lw.g.field_get(bt, i, b.c)
    return Val { c, ty: ft, owned: false }
  }
  val_never()
}

/// An owned copy of a value borrowed from a borrowed element read.
fn own_tmp(lw: var Lower, v: Val): Val {
  if v.owned || v.is_never() { return v }
  let ty = v.ty
  let c = lw.bdecl(v.c)
  let o = lw.own(plain(c, ty))
  lw.adopt(ty, o)
}

fn index(lw: var Lower, e: ast.Expr, x: ast.Expr, i: ast.Expr): Val {
  let xv = lw.expr_borrow_if(x, lw.pure_read(i))
  let iv = lw.expr(i)
  lw.index_val(e, xv, iv, false)
}

/// Element `iv` of `xv`: an owned copy, or a borrowed snapshot when `borrow`.
fn index_val(lw: var Lower, e: ast.Expr, xv: Val, iv: Val, borrow: bool): Val {
  let lc = lw.loc(e.span)
  match xv.ty {
    List(et) => {
      let el0 = mir.rt("auk_arr_at", [xv.c, iv.c, lc], mir.void_ptr()).cast(mir.ptr(d(et))).deref(d(et))
      let el = lw.bdecl(el0)
      let v = plain(el, et)
      if borrow { return v }
      let o = lw.own(v)
      lw.adopt(et, o)
    }
    Map(kt, vt) => {
      let k = lw.lvalue(iv, kt)
      let p0 = mir.rt("auk_map_at", [xv.c, k.addr().cast(mir.void_ptr()), lc], mir.void_ptr()).cast(mir.ptr(d(vt))).deref(d(vt))
      let p = lw.bdecl(p0)
      let v = plain(p, vt)
      if borrow { return v }
      let o = lw.own(v)
      lw.adopt(vt, o)
    }
    Str => {
      let c = mir.rt("auk_str_char_at", [xv.c, iv.c, lc], d(types.Ty.Char))
      lw.tmp(types.Ty.Char, c)
    }
    _ => val_never()
  }
}

// ---- places ----

/// The place of a place expression (making containers on the path unique), and its type.
fn place(lw: var Lower, e: ast.Expr): (mir.Ex, types.Ty) = match e.kind {
  Name(_) => {
    match lw.t.names.get(e.id) {
      some(Local(l)) => match lw.f.locals.get(l) {
        some(s) => return (s.c, s.ty)
        none => {}
      }
      some(Global(g)) => if lw.tp.globals[g].kind != 2 {
        let p = mir.lower.lowlevel.global_ref(&lw, g)
        return (p.c, p.ty)
      }
      _ => {}
    }
    lw.place_tmp(e)
  }
  Field(x, name) => {
    // the runtime's dialect: another module's global by path
    match lw.t.names.get(e.id) {
      some(Global(g)) => if lw.tp.globals[g].kind != 2 {
        let p = mir.lower.lowlevel.global_ref(&lw, g)
        return (p.c, p.ty)
      }
      _ => {}
    }
    let (b, bt) = lw.place(x)
    lw.place_field(e, b, bt, name.name)
  }
  TupleField(x, index) => {
    let (b, bt) = lw.place(x)
    let ft = match bt {
      Tuple(ts) => ts.get(index) else types.unit()
      _ => lw.ty(e.id)
    }
    (b.field(mir.Sel.F(index), d(ft)), ft)
  }
  Index(x, index) => {
    let (b, bt) = lw.place(x)
    let lc = lw.loc(e.span)
    match bt {
      List(et) => {
        let iv = lw.expr(index)
        let ic = lw.val_as(iv, types.Ty.Int)
        let i = lw.decl(types.Ty.Int, ic)
        lw.do_(mir.rt("auk_arr_make_unique", [b.addr()], mir.void_ptr()))
        let p0 = mir.rt("auk_arr_at", [b, i, lc], mir.void_ptr()).cast(mir.ptr(d(et)))
        let p = lw.bdecl(p0)
        (p.deref(d(et)), et)
      }
      Map(kt, vt) => {
        let kv = lw.expr(index)
        let k = lw.lvalue(kv, kt)
        lw.do_(mir.rt("auk_map_make_unique", [b.addr()], mir.void_ptr()))
        let p0 = mir.rt("auk_map_at", [b, k.addr().cast(mir.void_ptr()), lc], mir.void_ptr()).cast(mir.ptr(d(vt)))
        let p = lw.bdecl(p0)
        (p.deref(d(vt)), vt)
      }
      _ => lw.place_tmp(e)
    }
  }
  MethodCall(_, name, _) when name.name == "at" && lw.t.calls.contains(e.id) && mir.lower.lowlevel.is_raw_call(&lw, e.id) =>
    mir.lower.lowlevel.at_place(&lw, e)
  _ => lw.place_tmp(e)
}

/// The place of field `name` of the struct place `b` (of type `bt`), for writing.
fn place_field(lw: var Lower, e: ast.Expr, b: mir.Ex, bt: types.Ty, name: str): (mir.Ex, types.Ty) {
  if bt is types.Ty.Ptr(_) { return mir.lower.lowlevel.ptr_field_place(&lw, b, bt, name) }
  let ft = match bt {
    Named(dd, args) when types.is_struct(lw.tp.defs, dd) => {
      let s = types.subst_of(lw.tp.defs, dd, args)
      match types.fields(lw.tp.defs, dd).find(f => f.name == name) {
        some(f) => types.subst(f.ty, s)
        none => types.unit()
      }
    }
    _ => lw.ty(e.id)
  }
  match lw.field_index(bt, name) {
    some(i) => {
      // a boxed (recursive) field's box may be shared with copies of this struct: make it
      // unique before writing through it (copy-on-write)
      let (raw, boxed) = lw.g.field_raw(bt, i, b)
      if boxed {
        let f = lw.g.box_unique(ft)
        let c = lw.g.call(f, [raw.addr()])
        lw.do_(c)
      }
      (lw.g.field_get(bt, i, b), ft)
    }
    none => (lw.g.zero(ft), ft)
  }
}

fn place_tmp(lw: var Lower, e: ast.Expr): (mir.Ex, types.Ty) {
  let v = lw.expr(e)
  let ty = v.ty
  let o = lw.own_as(v, ty)
  let n = lw.decl(ty, o)
  lw.register(n, ty)
  (n, ty)
}

/// `target = v` for a plain `=`; a tuple target takes the tuple's elements in turn.
fn assign_to(lw: var Lower, target: ast.Expr, v: Val) {
  match target.kind {
    Tuple(xs) => {
      let ets = match v.ty {
        Tuple(ts) => ts
        _ => return
      }
      let w = lw.lvalue(v, v.ty)
      for i, x in xs {
        if i >= ets.len() { break }
        let el = plain(lw.fld(w, mir.Sel.F(i)), ets[i])
        lw.assign_to(x, el)
      }
      return
    }
    // `m[k] = v` inserts
    Index(x, index) => {
      let (b, bt) = lw.place(x)
      match bt {
        Map(kt, vt) => {
          let kv = lw.expr(index)
          let k = lw.lvalue(kv, kt)
          let vc = lw.lvalue(v, vt)
          lw.do_(mir.rt("auk_map_set", [b.addr(), k.addr().cast(mir.void_ptr()), vc.addr().cast(mir.void_ptr())], mir.MTy.Void))
          return
        }
        List(et) => {
          let iv = lw.expr(index)
          let vc = lw.lvalue(v, et)
          let lc = lw.loc(target.span)
          lw.do_(mir.rt("auk_arr_set", [b.addr(), iv.c, vc.addr().cast(mir.void_ptr()), lc], mir.MTy.Void))
          return
        }
        _ => {}
      }
      // (Rust evaluates the container's place again below, through `place(target)`)
      lw.assign_place(target, v)
      return
    }
    _ => {}
  }
  lw.assign_place(target, v)
}

fn assign_place(lw: var Lower, target: ast.Expr, v: Val) {
  var lv = mir.unit()
  var lty = types.unit()
  match target.kind {
    Field(x, name) when !lw.t.names.contains(target.id) => {
      let (b, bt) = lw.place(x)
      // a boxed (recursive) struct field gets a fresh box
      match lw.field_index(bt, name.name) {
        some(i) => if lw.g.field_raw(bt, i, b).1 {
          let ft = mir.types.struct_layout(lw.g.info, bt)[i].0
          let o = lw.own_as(v, ft)
          let put = lw.g.field_put(bt, i, o)
          let (raw, _) = lw.g.field_raw(bt, i, b)
          let old = lw.bdecl(raw)
          lw.set(raw, put)
          lw.do_(mir.rt("auk_release", [old], mir.MTy.Void))
          return
        }
        none => {}
      }
      let (p, t) = lw.place_field(target, b, bt, name.name)
      lv = p
      lty = t
    }
    _ => {
      let (p, t) = lw.place(target)
      lv = p
      lty = t
    }
  }
  let ty = v.ty
  let o = lw.own_as(v, ty)
  let nv = lw.decl(ty, o)
  if lw.g.needs_rc(lty) {
    let old = lw.decl(lty, lv)
    lw.set(lv, nv)
    match lw.g.release(lty, old) {
      some(r) => lw.emit(r)
      none => {}
    }
  } else {
    lw.set(lv, nv)
  }
}

fn assign(lw: var Lower, e: ast.Expr, op: ast.BinOp?, target: ast.Expr, value: ast.Expr) {
  if op == none && lw.fused_map_update(target, value) { return }
  // `s = s + a + b` on a string or list is `s += a; s += b`: in place when s is unique, so
  // building one up in a loop is linear, not quadratic
  if op == none {
    let parts = lw.append_chain(target, value)
    if parts.len() > 0 {
      for p in parts { lw.assign(e, some(ast.BinOp.Add), target, p) }
      return
    }
  }
  if op != none && lw.t.calls.contains(e.id) {
    // a user operator: target = op(target, value)
    let v = lw.call(e, none, false)
    let (lv, ty) = lw.place(target)
    let o = lw.own_as(v, ty)
    let old = lw.decl(ty, lv)
    lw.set(lv, o)
    match lw.g.release(ty, old) {
      some(r) => lw.emit(r)
      none => {}
    }
    return
  }
  let v = lw.expr(value)
  if v.is_never() { return }
  match op {
    none => lw.assign_to(target, v)
    some(op) => {
      let rc = v.c
      let (lv, lty) = lw.place(target)
      let lc = lw.loc(e.span)
      match lty {
        Int => {
          let c = int_op(op, lv, rc, lc)
          lw.set(lv, c)
        }
        Fixed(_) => {
          let c = mir.lower.lowlevel.fixed_bin(&lw, op, lv, rc, lty)
          lw.set(lv, c)
        }
        Float => {
          let c = match op {
            Add => mir.bin(mir.BOp.Add, lv, rc)
            Sub => mir.bin(mir.BOp.Sub, lv, rc)
            Mul => mir.bin(mir.BOp.Mul, lv, rc)
            Div => mir.bin(mir.BOp.Div, lv, rc)
            _ => mir.rt("auk_fmod", [lv, rc], d(types.Ty.Float))
          }
          lw.set(lv, c)
        }
        // in place when the string is unique: appending in a loop is linear
        Str => lw.do_(mir.rt("auk_str_append", [lv.addr(), rc], mir.MTy.Void))
        List(_) => lw.do_(mir.rt("auk_arr_extend", [lv.addr(), rc], mir.MTy.Void))
        _ => {}
      }
    }
  }
}

/// When `value` is `target + a + b + ...` (built-in `+` on a `str` or a list, `target` a local
/// or a field or list element of one), the pieces `a, b, ...` that appending to `target` in turn
/// gives the same result with; else `[]`. Every piece must be a pure read, and none after the
/// first may read the variable being changed (it would see the earlier appends).
fn append_chain(lw: var Lower, target: ast.Expr, value: ast.Expr): [ast.Expr] {
  let is_seq = match lw.ty(target.id) {
    Str => true
    List(_) => true
    _ => false
  }
  if !is_seq { return [] }
  let root = lw.place_root(target) else return []
  var pieces: [ast.Expr] = []
  var v = value
  loop {
    match v.kind {
      Binary(Add, lhs, rhs) => {
        if lw.t.calls.contains(v.id) || lw.has_coercions(v.id) || !lw.append_piece(rhs) {
          return []
        }
        pieces.push(rhs)
        if lw.same_place(target, lhs) { break }
        v = lhs
      }
      _ => return []
    }
  }
  // pieces is last-first; all but the first appended must not read the root variable
  var out: [ast.Expr] = []
  var i = pieces.len() - 1
  while i >= 0 {
    if i < pieces.len() - 1 && lw.reads_local(pieces[i], root) { return [] }
    out.push(pieces[i])
    i -= 1
  }
  out
}

/// Can `e` be evaluated after earlier appends without changing anything: a pure read, or a
/// list literal of them.
fn append_piece(lw: var Lower, e: ast.Expr): bool = match e.kind {
  List(xs) => {
    for x in xs {
      if !lw.pure_read(x) { return false }
    }
    true
  }
  _ => lw.pure_read(e)
}

/// The local a place (`x`, `x.f`, `x.0`, `x[i]` of a list with `i` a local or literal) is in.
fn place_root(lw: var Lower, e: ast.Expr): int? = match e.kind {
  Name(_) => match lw.t.names.get(e.id) {
    some(Local(l)) => some(l)
    _ => none
  }
  Field(x, _) | TupleField(x, _) => if lw.t.names.contains(e.id) { none } else { lw.place_root(x) }
  Index(x, i) => if (lw.ty(x.id) is types.Ty.List(_)) && lw.simple_operand(i) {
    lw.place_root(x)
  } else {
    none
  }
  _ => none
}

/// Do two places name the same storage (as `place_root` allows them)?
fn same_place(lw: var Lower, a: ast.Expr, b: ast.Expr): bool = match (a.kind, b.kind) {
  (Name(_), Name(_)) => lw.same_operand(a, b)
  (Field(x, f), Field(y, g)) => f.name == g.name &&
    !lw.t.names.contains(a.id) &&
    !lw.t.names.contains(b.id) &&
    lw.same_place(x, y)
  (TupleField(x, i), TupleField(y, j)) => i == j && lw.same_place(x, y)
  (Index(x, i), Index(y, j)) => lw.simple_operand(i) && lw.same_operand(i, j) && lw.same_place(x, y)
  _ => false
}

/// Might `e` read local `l`? Conservative: anything but the expressions `pure_read` accepts
/// (and list literals) counts as reading it.
fn reads_local(lw: var Lower, e: ast.Expr, l: int): bool = match e.kind {
  Lit(_) => false
  Name(_) => match lw.t.names.get(e.id) {
    some(Local(x)) => x == l
    some(_) => false
    none => true
  }
  Measured(x, _) | Field(x, _) | TupleField(x, _) | Unary(_, x) => lw.reads_local(x, l)
  Index(x, i) => lw.reads_local(x, l) || lw.reads_local(i, l)
  Slice(x, lo, hi, _) => lw.reads_local(x, l) || lw.reads_local(lo, l) || lw.reads_local(hi, l)
  Binary(_, a, b) => lw.reads_local(a, l) || lw.reads_local(b, l)
  List(xs) => lw.any_reads_local(xs, l)
  Interp(parts) => {
    for p in parts {
      match p {
        Expr(x, _) => if lw.reads_local(x, l) { return true }
        _ => {}
      }
    }
    false
  }
  Call(c, args) => lw.reads_local(c, l) || lw.any_reads_local(args, l)
  Pipe(x, c, args) => lw.reads_local(x, l) || lw.reads_local(c, l) || lw.any_reads_local(args, l)
  MethodCall(r, _, args) => lw.reads_local(r, l) || lw.any_reads_local(args, l)
  _ => true
}

fn any_reads_local(lw: var Lower, xs: [ast.Expr], l: int): bool {
  for x in xs {
    if lw.reads_local(x, l) { return true }
  }
  false
}

/// Is `e` a local variable or a literal (cheap, pure, the same every time it's evaluated)?
fn simple_operand(lw: var Lower, e: ast.Expr): bool = match e.kind {
  Lit(_) => true
  Name(_) => match lw.t.names.get(e.id) {
    some(Local(_)) => true
    _ => false
  }
  _ => false
}

/// Do `a` and `b` denote the same value: the same local, or equal literals?
fn same_operand(lw: var Lower, a: ast.Expr, b: ast.Expr): bool = match (a.kind, b.kind) {
  (Lit(x), Lit(y)) => x == y
  (Name(_), Name(_)) => match (lw.t.names.get(a.id), lw.t.names.get(b.id)) {
    (some(Local(x)), some(Local(y))) => x == y
    _ => false
  }
  _ => false
}

fn fused_combine(float: bool, op: ast.BinOp, a: mir.Ex, b: mir.Ex, lc: mir.Ex): mir.Ex {
  if float {
    let bop = match op {
      Add => mir.BOp.Add
      Sub => mir.BOp.Sub
      Mul => mir.BOp.Mul
      _ => mir.BOp.Div
    }
    mir.bin(bop, a, b)
  } else {
    int_op(op, a, b, lc)
  }
}

/// The counting idiom `m[k] = (m.get(k) else d) op x` with one lookup when `k` is present
/// (see src/mir/lower.rs).
fn fused_map_update(lw: var Lower, target: ast.Expr, value: ast.Expr): bool {
  let (m1, k1) = match target.kind {
    Index(m, k) => (m, k)
    _ => return false
  }
  let (op, lhs, rhs) = match value.kind {
    Binary(op, l, r) => (op, l, r)
    _ => return false
  }
  let (got, arm) = match lhs.kind {
    Else(g, a) => (g, a)
    _ => return false
  }
  let (m2, name, args) = match got.kind {
    MethodCall(r, n, a) => (r, n, a)
    _ => return false
  }
  if name.name != "get" || args.len() != 1 || arm.binder != none || lw.t.calls.contains(value.id) { return false }
  let core_get = match lw.tp.instances[lw.inst].resolved.get(got.id) {
    some(Extern(symbol, _)) => symbol == "auk_map_get_opt"
    _ => false
  }
  if !core_get || !lw.same_operand(m1, m2) || !lw.same_operand(k1, args[0]) || !lw.simple_operand(k1) ||
    !lw.simple_operand(arm.body) || !lw.simple_operand(rhs) {
    return false
  }
  // no implicit conversions anywhere in it
  for id in [value.id, lhs.id, got.id, rhs.id, arm.body.id, k1.id, args[0].id] {
    if lw.t.coercions.contains(id) { return false }
  }
  let (kt, vt) = match lw.ty(m1.id) {
    Map(k, v) => (k, v)
    _ => return false
  }
  let arith = op == ast.BinOp.Add || op == ast.BinOp.Sub || op == ast.BinOp.Mul || op == ast.BinOp.Div
  let float = match vt {
    Int => false
    Float when arith => true
    _ => return false
  }
  let int_ops = arith || op == ast.BinOp.Rem || op == ast.BinOp.AddWrap || op == ast.BinOp.SubWrap ||
    op == ast.BinOp.MulWrap || op == ast.BinOp.BitAnd || op == ast.BinOp.BitOr || op == ast.BinOp.BitXor
  if !float && !int_ops { return false }
  let lc = lw.loc(value.span)
  let (b, _) = lw.place(m1)
  let kv = lw.expr(k1)
  let k = lw.lvalue(kv, kt)
  lw.do_(mir.rt("auk_map_make_unique", [b.addr()], mir.void_ptr()))
  let p = lw.bdecl(mir.rt("auk_map_find", [b, k.addr().cast(mir.void_ptr())], mir.void_ptr()).cast(mir.ptr(d(vt))))
  lw.open_if(mir.bin(mir.BOp.Ne, p, mir.null().cast(mir.ptr(d(vt)))))
  let x = lw.expr(rhs)
  let cur = p.deref(d(vt))
  let n = lw.decl(vt, fused_combine(float, op, cur, x.c, lc))
  lw.set(cur, n)
  lw.else_()
  let dv = lw.expr(arm.body)
  let x2 = lw.expr(rhs)
  let n2 = lw.decl(vt, fused_combine(float, op, dv.c, x2.c, lc))
  lw.do_(mir.rt("auk_map_set", [b.addr(), k.addr().cast(mir.void_ptr()), n2.addr().cast(mir.void_ptr())], mir.MTy.Void))
  lw.close()
  true
}

// ---- ?, else, ?., await ----

fn try_(lw: var Lower, e: ast.Expr, x: ast.Expr): Val {
  let info = lw.t.tries[e.id]
  let v = lw.expr(x)
  if v.is_never() { return v }
  let ty = lw.ty(e.id)
  match info.kind {
    Result => {
      let w = lw.hold(v)
      lw.open_if(lw.fld(w, mir.Sel.F(0)).not())
      lw.return_err(lw.fld(w, mir.Sel.F(2)))
      lw.close()
      let val = lw.fld(w, mir.Sel.F(1))
      lw.adopt(ty, val)
    }
    Option => {
      let w = lw.hold(v)
      lw.open_if(lw.fld(w, mir.Sel.F(0)).not())
      lw.return_none()
      lw.close()
      let val = lw.fld(w, mir.Sel.F(1))
      lw.adopt(ty, val)
    }
    _ => {
      let el = match v.ty {
        List(el) => el
        _ => return val_never()
      }
      let inner = match ty {
        List(i) => i
        _ => return val_never()
      }
      let xs = lw.hold(v)
      let ops = lw.g.ops(inner)
      let len = mir.rt("auk_arr_len", [xs], ty_int())
      let out = lw.decl(ty, mir.rt("auk_arr_new", [ops, len], d(ty)))
      let k = lw.decl(types.Ty.Int, mir.int_(0))
      lw.f.b.open_loop([mir.Stmt.Set(k, mir.bin(mir.BOp.Add, k, mir.int_(1)))])
      lw.open_if(mir.bin(mir.BOp.Lt, k, len).not())
      lw.emit(mir.Stmt.Break)
      lw.close()
      let r = mir.elem(xs, k, d(el))
      lw.open_if(lw.fld(r, mir.Sel.F(0)).not())
      if info.kind == typed.TryKind.ListResult {
        let ety = lw.g.err_ty()
        let en = lw.decl(ety, mir.rt("auk_retain", [lw.fld(r, mir.Sel.F(2))], d(ety)))
        lw.do_(mir.rt("auk_release", [out], mir.MTy.Void))
        lw.do_(mir.rt("auk_release", [xs], mir.MTy.Void))
        lw.return_err(en)
      } else {
        lw.do_(mir.rt("auk_release", [out], mir.MTy.Void))
        lw.do_(mir.rt("auk_release", [xs], mir.MTy.Void))
        lw.return_none()
      }
      lw.close()
      lw.do_(mir.rt("auk_arr_push", [out.addr(), lw.fld(r, mir.Sel.F(1)).addr().cast(mir.void_ptr())], mir.MTy.Void))
      lw.emit(mir.Stmt.Continue)
      lw.close()
      lw.do_(mir.rt("auk_release", [xs], mir.MTy.Void))
      lw.reown(out, ty)
    }
  }
}

fn return_none(lw: var Lower) {
  let ret = lw.f.ret
  lw.cleanup_from(0)
  let z = lw.g.zero(ret)
  lw.emit(mir.Stmt.Ret(z))
}

fn else_expr(lw: var Lower, e: ast.Expr, x: ast.Expr, arm: ast.ElseArm): Val {
  let info = lw.t.elses[e.id]
  let v = lw.expr(x)
  let ty = lw.ty(e.id)
  if v.is_never() { return v }
  let wt = v.ty
  let w = lw.hold(v)
  let r = lw.zero_decl(ty)
  lw.open_if(lw.fld(w, mir.Sel.F(0)))
  lw.set(r, lw.fld(w, mir.Sel.F(1)))
  lw.else_()
  lw.push(ScopeKind.Block)
  if info.kind != typed.ElseKind.Option { lw.bind_err(info.binder, w, wt) }
  let fb = lw.expr(arm.body)
  let o = lw.own_as(fb, ty)
  lw.set(r, o)
  lw.pop()
  lw.close()
  lw.reown(r, ty)
}

/// In the error branch of `w` (a held `T!`): bind `else e =>`'s binder or drop the error.
fn bind_err(lw: var Lower, binder: int?, w: mir.Ex, wt: types.Ty) {
  let err = lw.fld(w, mir.Sel.F(2))
  match binder {
    some(l) => {
      let lt = lw.local_ty(l)
      let n = if lw.g.is_err_ty(lt) {
        lw.decl(lt, err)
      } else {
        let id = lw.g.type_id(lt)
        let n = lw.zero_decl(lt)
        let pl = lw.bdecl(mir.rt("auk_err_payload", [err, mir.int_as(id, mir.MTy.U32)], mir.void_ptr()))
        lw.open_if(mir.bin(mir.BOp.Ne, pl, mir.null()))
        lw.set(n, pl.cast(mir.ptr(d(lt))).deref(d(lt)))
        lw.close()
        match lw.g.retain(lt, n) {
          some(r) => lw.emit(r)
          none => {}
        }
        lw.do_(mir.rt("auk_release", [err], mir.MTy.Void))
        n
      }
      lw.register_local(n, lt)
      lw.bind_name(l, Slot { c: n, ty: lt })
    }
    none => lw.do_(mir.rt("auk_release", [err], mir.MTy.Void))
  }
}

/// Rust's `Ident::tuple_index`: the number of a `.0`-like name.
fn tuple_index(name: str): int? {
  if name.len() == 0 || !name.chars().all(c => c >= '0' && c <= '9') { return none }
  match int.parse(name) {
    ok(n) => some(n)
    err(_) => none
  }
}

fn opt_chain(lw: var Lower, e: ast.Expr, x: ast.Expr, name: ast.Ident, call: bool): Val {
  let flatten = match lw.t.opt_chains.get(e.id) {
    some(o) => o.flatten
    none => false
  }
  let v = lw.expr(x)
  if v.is_never() { return v }
  let ty = lw.ty(e.id)
  let inner = match v.ty {
    Opt(i) => i
    _ => return val_never()
  }
  let xv = lw.lvalue(v, v.ty)
  let r = lw.zero_decl(ty)
  lw.open_if(lw.fld(xv, mir.Sel.F(0)))
  lw.push(ScopeKind.Block)
  let val = lw.fld(xv, mir.Sel.F(1))
  let iv = plain(val, inner)
  let member = if call {
    lw.call(e, some(iv), false)
  } else {
    let ft = match ty {
      Opt(t) when !flatten => t
      t => t
    }
    let c = match (tuple_index(name.name), lw.field_index(inner, name.name)) {
      (some(index), _) => lw.fld(val, mir.Sel.F(index))
      (none, some(i)) => lw.g.field_get(inner, i, val)
      (none, none) => lw.g.zero(ft)
    }
    plain(c, ft)
  }
  if flatten {
    let o = lw.own_as(member, ty)
    lw.set(r, o)
  } else {
    match ty {
      Opt(mt) => {
        let o = lw.own_as(member, mt)
        let s = lw.some_(ty, o)
        lw.set(r, s)
      }
      _ => {}
    }
  }
  lw.pop()
  lw.close()
  lw.reown(r, ty)
}

fn tasks_agg(lw: var Lower, n: int): int {
  let key = "tasks{n}"
  match lw.g.memo2.get(key) {
    some(a) => return a
    none => {}
  }
  let a = lw.g.agg("DkTasks{n}", (0..n).map(_ => mir.ptr(mir.MTy.Rt(mir.Rt.Task))))
  lw.g.memo2[key] = a
  a
}

fn await_(lw: var Lower, e: ast.Expr, x: ast.Expr): Val {
  let kind = lw.t.awaits.get(e.id) else typed.AwaitKind.Direct
  let ty = lw.ty(e.id)
  match kind {
    Direct => lw.expr(x)
    Task => {
      let t = lw.expr(x)
      let r = lw.zero_decl(ty)
      lw.do_(mir.rt("auk_task_await", [t.c, r.addr().cast(mir.void_ptr())], mir.MTy.Void))
      lw.reown(r, ty)
    }
    Tuple => {
      let tv = lw.expr(x)
      let ts = match tv.ty {
        Tuple(ts) => ts
        _ => return val_never()
      }
      var fields: [mir.Ex] = []
      for i in 0..ts.len() { fields.push(lw.fld(tv.c, mir.Sel.F(i))) }
      let a = lw.tasks_agg(ts.len())
      var ms: [(mir.Sel, mir.Ex)] = []
      for i, f in fields { ms.push((mir.Sel.F(i), f.cast(mir.ptr(mir.MTy.Rt(mir.Rt.Task))))) }
      let arr = lw.bdecl(mir.agg(mir.MTy.Agg(a), ms))
      lw.do_(
        mir.rt(
          "auk_task_join_all",
          [arr.addr().cast(mir.ptr(mir.ptr(mir.MTy.Rt(mir.Rt.Task)))), mir.int_(ts.len())],
          mir.MTy.Void,
        ),
      )
      let r = lw.zero_decl(ty)
      for i, f in fields {
        let slot = lw.fld(r, mir.Sel.F(i)).addr().cast(mir.void_ptr())
        lw.do_(mir.rt("auk_task_await", [f, slot], mir.MTy.Void))
      }
      lw.reown(r, ty)
    }
    List => {
      let tv = lw.expr(x)
      let inner = match ty {
        List(i) => i
        _ => return val_never()
      }
      let ops = lw.g.ops(inner)
      let n = lw.decl(types.Ty.Int, mir.rt("auk_arr_len", [tv.c], ty_int()))
      let out = lw.decl(ty, mir.rt("auk_arr_new", [ops, n], d(ty)))
      lw.open_if(mir.bin(mir.BOp.Gt, n, mir.int_(0)))
      let tasks = tv.c.rt_field(mir.RtF.ArrData).cast(mir.ptr(mir.ptr(mir.MTy.Rt(mir.Rt.Task))))
      lw.do_(mir.rt("auk_task_await_all", [tasks, n, out.rt_field(mir.RtF.ArrData)], mir.MTy.Void))
      lw.set(out.rt_field(mir.RtF.ArrLen), n)
      lw.close()
      lw.reown(out, ty)
    }
  }
}

// ---- control flow ----

fn if_(lw: var Lower, e: ast.Expr, cond: ast.Expr, then: ast.Block, els: ast.Expr?, tail: bool): Val {
  let ty = lw.ty(e.id)
  let c = lw.expr(cond)
  let cc = lw.val_as(c, types.Ty.Bool)
  let has = has_value(ty) && els != none
  let r = if has { some(lw.zero_decl(ty)) } else { none }
  lw.open_if(cc)
  let v = lw.block(then, tail)
  match r {
    some(r) => if !v.is_never() {
      let o = lw.own_as(v, ty)
      lw.set(r, o)
    }
    none => lw.own_drop(v)
  }
  match els {
    some(x) => {
      lw.else_()
      lw.push(ScopeKind.Block)
      let v2 = lw.expr_t(x, tail)
      match r {
        some(r) => if !v2.is_never() {
          let o = lw.own_as(v2, ty)
          lw.set(r, o)
        }
        none => {}
      }
      lw.pop()
    }
    none => {}
  }
  lw.close()
  match r {
    some(r) => lw.reown(r, ty)
    none => if ty == types.Ty.Never { val_never() } else { val_unit() }
  }
}

/// Drop a value produced in a branch whose result is unused.
fn own_drop(lw: var Lower, v: Val) {
  if v.owned && !v.is_never() {
    lw.unregister(v.c)
    match lw.g.release(v.ty, v.c) {
      some(r) => lw.emit(r)
      none => {}
    }
  }
}

/// Is `e` a name whose value stays put, unchanged, while it is in scope: an immutable local
/// (or parameter) that isn't a `var` parameter, in a function whose self tail calls don't
/// reassign its parameters? Its parts, boxes included, then live at least as long as anything
/// bound from them in a `match` arm, and nothing writes them (boxes are copy-on-write).
fn stable_root(lw: var Lower, e: ast.Expr): bool {
  if lw.f.tail != none || !(e.kind is ast.ExprKind.Name(_)) { return false }
  match lw.t.names.get(e.id) {
    some(Local(l)) => !lw.t.locals[l].mutable && !lw.f.var_params.contains(l) && lw.f.locals.contains(l)
    _ => false
  }
}

fn match_(lw: var Lower, e: ast.Expr, scrut: ast.Expr, arms: [ast.Arm], tail: bool): Val {
  let ty = lw.ty(e.id)
  // arms bind owned copies before their bodies run, and guards are pure
  var guards_pure = true
  for a in arms {
    match a.guard {
      some(gx) => if guards_pure && !lw.pure_read(gx) { guards_pure = false }
      none => {}
    }
  }
  let sv = lw.expr_borrow_if(scrut, guards_pure)
  if sv.is_never() { return sv }
  let st = sv.ty
  let s = lw.lvalue(sv, st)
  let stable = lw.stable_root(scrut) && s.is_place()
  let has = has_value(ty)
  let r = if has { some(lw.zero_decl(ty)) } else { none }
  let end = lw.f.b.label()
  let lit_case = lw.str_switch(arms, s, st)
  for ai, a in arms {
    let test = match lit_case {
      some((k, idx)) when idx[ai] >= 0 => mir.bin(mir.BOp.Eq, k, mir.int_(idx[ai]))
      _ => lw.pat_test(a.pat, s)
    }
    lw.open_if(test)
    lw.push(ScopeKind.Block)
    let arm_depth = lw.f.scopes.len() - 1
    lw.f.bind_borrow = stable
    lw.bind_pat(a.pat, s, st)
    lw.f.bind_borrow = false
    let guarded = lw.guard(a.guard)
    lw.push(ScopeKind.Block)
    let v = lw.expr_t(a.body, tail)
    let never = v.is_never()
    match r {
      some(r) => if !never {
        let o = lw.own_as(v, ty)
        lw.set(r, o)
      }
      none => lw.own_drop(v)
    }
    lw.pop()
    if !never {
      lw.cleanup_from(arm_depth)
      lw.emit(mir.Stmt.Goto(end))
    }
    if guarded { lw.close() }
    lw.pop()
    lw.close()
  }
  let lc = lw.loc(e.span)
  lw.do_(mir.rt("auk_panic_str", [lc, mir.cstr("no match arm matches the value")], mir.MTy.Void))
  lw.emit(mir.Stmt.Unreachable)
  lw.emit(mir.Stmt.Label(end))
  match r {
    some(r) => lw.reown(r, ty)
    none => if ty == types.Ty.Never { val_never() } else { val_unit() }
  }
}

fn arm_str_lit(a: ast.Arm): str? = match a.pat.kind {
  Lit(Str(x), _) => some(x)
  _ => none
}

/// A `match` on a `str` with many string literal arms looks the scrutinee up once in a sorted
/// table of the literals (`auk_str_switch`). Returns the lookup's result and, per arm, the
/// table index its literal must equal (-1: the arm's own pattern test).
fn str_switch(lw: var Lower, arms: [ast.Arm], s: mir.Ex, st: types.Ty): (mir.Ex, [int])? {
  if st != types.Ty.Str { return none }
  var keys0: [str] = []
  for a in arms {
    match arm_str_lit(a) {
      some(x) => keys0.push(x)
      none => {}
    }
  }
  if keys0.len() < 6 { return none }
  let sorted = keys0.sort_by(k => (k.byte_len(), k.bytes()))
  var keys: [str] = []
  for k in sorted {
    if keys.len() == 0 || keys[keys.len() - 1] != k { keys.push(k) }
  }
  var idx: [int] = []
  for a in arms {
    idx.push(match arm_str_lit(a) {
      some(x) => keys.find_index(k => k == x)!
      none => -1
    })
  }
  let n = keys.len()
  var fields: [mir.MTy] = []
  for _ in 0..n {
    fields.push(mir.MTy.CStr)
    fields.push(mir.MTy.I64)
  }
  let agg = lw.g.agg("DkStrCases{lw.g.prog.aggs.len()}", fields)
  var members: [(mir.Sel, mir.Ex)] = []
  for i, k in keys {
    members.push((mir.Sel.F(2 * i), mir.ex(mir.K.CStr(k.bytes()), mir.MTy.CStr)))
    members.push((mir.Sel.F(2 * i + 1), mir.i64(k.byte_len())))
  }
  let name = "dk_str_cases{lw.g.prog.globals.len()}"
  let gl = lw.g.global(name, mir.MTy.Agg(agg), some(mir.agg(mir.MTy.Agg(agg), members)), true)
  let table = mir.ex(mir.K.GlobalAddr(gl), mir.ptr(mir.MTy.Agg(agg))).cast(mir.void_ptr())
  let call = mir.rt("auk_str_switch", [s, table, mir.i64(n)], ty_int())
  let k = lw.decl(types.Ty.Int, call)
  some((k, idx))
}

fn for_(lw: var Lower, e: ast.Expr, index: ast.Pat?, pat: ast.Pat, iter: ast.Expr, body: ast.Block) {
  let kind = lw.t.fors.get(e.id) else return
  match kind {
    Range(inclusive) => {
      let (lo, hi) = match iter.kind {
        Range(lo, hi, _) => (lo, hi)
        _ => return
      }
      let l = lw.expr(lo)
      let h = lw.expr(hi)
      let lc = lw.val_as(l, types.Ty.Int)
      let hc = lw.val_as(h, types.Ty.Int)
      let hv = lw.decl(types.Ty.Int, hc)
      let i = lw.decl(types.Ty.Int, lc)
      let op = if inclusive { mir.BOp.Le } else { mir.BOp.Lt }
      let blocked = lw.short_body(body)
      let stop = lw.counted_open(e.span, i, hv, op, inclusive, blocked)
      lw.push(ScopeKind.Block)
      let depth = lw.f.scopes.len() - 1
      lw.bind_top(pat, i, types.Ty.Int)
      lw.loop_body(depth, body)
      lw.pop()
      lw.counted_close(i, stop, op)
    }
    List => {
      let v = lw.expr(iter)
      let et = match v.ty {
        List(et) => et
        _ => return
      }
      let it = lw.hold(v)
      lw.register(it, types.list(et))
      // `it` is the loop's own reference, so the body can't change the list under it (a change
      // copies): its length and data pointer are read once, here
      let n = lw.decl(types.Ty.Int, mir.rt("auk_arr_len", [it], ty_int()))
      let pt = d(types.Ty.Ptr(et))
      let data = lw.bdecl(mir.int_as(0, pt))
      lw.open_if(mir.bin(mir.BOp.Gt, n, mir.int_(0)))
      lw.set(data, mir.rt_field(it, mir.RtF.ArrData).cast(pt))
      lw.close()
      let k = lw.decl(types.Ty.Int, mir.int_(0))
      let blocked = lw.short_body(body)
      let stop = lw.counted_open(e.span, k, n, mir.BOp.Lt, false, blocked)
      lw.push(ScopeKind.Block)
      let depth = lw.f.scopes.len() - 1
      match index {
        some(ix) => lw.bind_top(ix, k, types.Ty.Int)
        none => {}
      }
      let off = mir.bin(mir.BOp.Mul, k, mir.size_of(d(et)).cast(ty_int()))
      let at = mir.bin(mir.BOp.Add, data, off).cast(mir.ptr(d(et))).deref(d(et))
      let ev = lw.decl(et, at)
      lw.bind_top(pat, ev, et)
      lw.loop_body(depth, body)
      lw.pop()
      lw.counted_close(k, stop, mir.BOp.Lt)
    }
    Map => {
      let v = lw.expr(iter)
      let (kt, vt) = match v.ty {
        Map(k, x) => (k, x)
        _ => return
      }
      let mt = v.ty
      let m = lw.hold(v)
      lw.register(m, mt)
      let it = lw.bdecl(mir.int_(0))
      let kp = lw.bdecl(mir.null())
      let vp = lw.bdecl(mir.null())
      lw.f.b.open_loop([])
      lw.cancel_point(e.span)
      let next = mir.rt("auk_map_next", [m, it.addr(), kp.addr(), vp.addr()], mir.MTy.Bool)
      lw.open_if(next.not())
      lw.emit(mir.Stmt.Break)
      lw.close()
      lw.push(ScopeKind.Block)
      let depth = lw.f.scopes.len() - 1
      let kv = lw.decl(kt, kp.cast(mir.ptr(d(kt))).deref(d(kt)))
      let vv = lw.decl(vt, vp.cast(mir.ptr(d(vt))).deref(d(vt)))
      match index {
        some(ix) => {
          lw.bind_top(ix, kv, kt)
          lw.bind_top(pat, vv, vt)
        }
        none => {
          let tt = types.Ty.Tuple([kt, vt])
          let tv = lw.decl(tt, mir.agg(d(tt), [(mir.Sel.F(0), kv), (mir.Sel.F(1), vv)]))
          lw.bind_top(pat, tv, tt)
        }
      }
      lw.loop_body(depth, body)
      lw.pop()
      lw.close()
    }
    Chan => {
      let v = lw.expr(iter)
      let args = match v.ty {
        Named(_, args) => args
        _ => return
      }
      let et = args[0]
      let ct = v.ty
      let c = lw.hold(v)
      lw.register(c, ct)
      let r = lw.fld(c, mir.Sel.F(0))
      lw.f.b.open_loop([])
      lw.cancel_point(e.span)
      lw.push(ScopeKind.Block)
      let depth = lw.f.scopes.len() - 1
      let x = lw.zero_decl(et)
      let got = mir.rt("auk_chan_recv", [r, x.addr().cast(mir.void_ptr())], mir.MTy.Bool)
      lw.open_if(got.not())
      lw.emit(mir.Stmt.Break)
      lw.close()
      lw.register(x, et)
      lw.bind_top(pat, x, et)
      lw.loop_body(depth, body)
      lw.pop()
      lw.close()
    }
  }
}

/// Iterations of a blocked loop between cancellation checks.
let LOOP_BLOCK = 1024

/// Opens a counted loop over `i` while `i op end` (`op` is `Lt`, or `Le` when `inclusive`),
/// stepping by 1. Returns the bound of the inner loop when it is `blocked` (else none).
/// `blocked`: the loop runs as blocks of up to LOOP_BLOCK iterations, with the cancellation check
/// once per block and an inner loop free of it, which LLVM can unroll and vectorize. Only for
/// bodies that can't run long (`short_body`), so a cancel still lands within microseconds.
fn counted_open(
  lw: var Lower,
  span: diag.Span,
  i: mir.Ex,
  end: mir.Ex,
  op: mir.BOp,
  inclusive: bool,
  blocked: bool,
): mir.Ex? {
  if !blocked {
    lw.f.b.open_loop([mir.Stmt.Set(i, mir.bin(mir.BOp.Add, i, mir.int_(1)))])
    lw.cancel_point(span)
    lw.open_if(mir.bin(op, i, end).not())
    lw.emit(mir.Stmt.Break)
    lw.close()
    return none
  }
  lw.f.b.open_loop([])
  lw.cancel_point(span)
  lw.open_if(mir.bin(op, i, end).not())
  lw.emit(mir.Stmt.Break)
  lw.close()
  // this block ends at `end`, or LOOP_BLOCK iterations on. `end - i` wraps negative only when
  // the true distance is over 2^63, far past a block, and `i + LOOP_BLOCK` is then below `end`
  let stop = lw.decl(types.Ty.Int, end)
  let room = lw.decl(types.Ty.Int, mir.bin(mir.BOp.Sub, end, i))
  let last = if inclusive { LOOP_BLOCK - 1 } else { LOOP_BLOCK }
  let near = mir.bin(mir.BOp.BitAnd, mir.bin(mir.BOp.Ge, room, mir.int_(0)), mir.bin(mir.BOp.Le, room, mir.int_(last)))
  lw.open_if(near.not())
  lw.set(stop, mir.bin(mir.BOp.Add, i, mir.int_(last)))
  lw.close()
  lw.f.b.open_loop([mir.Stmt.Set(i, mir.bin(mir.BOp.Add, i, mir.int_(1)))])
  lw.open_if(mir.bin(op, i, stop).not())
  lw.emit(mir.Stmt.Break)
  lw.close()
  some(stop)
}

/// Closes a loop `counted_open` opened (with the `stop` it returned).
fn counted_close(lw: var Lower, i: mir.Ex, stop: mir.Ex?, op: mir.BOp) {
  lw.emit(mir.Stmt.Continue)
  lw.close()
  match stop {
    // the inner loop ended early only through a `break` in the body: leave the outer one too
    some(stop) => {
      lw.open_if(mir.bin(op, i, stop))
      lw.emit(mir.Stmt.Break)
      lw.close()
      lw.close()
    }
    none => {}
  }
}

/// A loop body that can't run long: it calls nothing but the runtime's C functions, intrinsics
/// and variant constructors (no Auk function, closure, shape method or user C function, any of
/// which may recurse or block). Its own loops don't count: they check for cancellation.
fn short_body(lw: var Lower, body: ast.Block): bool {
  var es: [ast.Expr] = []
  for s in body.stmts { visit.visit_expr(s, &es) }
  for x in es {
    match x.kind {
      Call(_, _) | MethodCall(_, _, _) | Pipe(_, _, _) | OptChain(_, _, some(_)) =>
        if !lw.short_call(x.id) { return false }
      Await(_) | AwaitAny(_) => return false
      _ => {}
    }
  }
  true
}

fn short_call(lw: var Lower, id: int): bool = match lw.t.calls.get(id) {
  some(c) => match c.callee {
    Fn(f, _) => match lw.tp.fns[f].kind {
      Extern(_, _, _) | Intrinsic(_, _) => true
      _ => false
    }
    Variant(_) => true
    _ => false
  }
  none => false
}

fn loop_body(lw: var Lower, depth: int, body: ast.Block) {
  lw.f.loops.push(LoopCx { depth, result: none })
  lw.push(ScopeKind.Block)
  lw.stmts(body.stmts)
  lw.pop()
  let _ = lw.f.loops.pop()
}

fn set_in_let(lw: var Lower, v: bool): bool? {
  match lw.f.dbg {
    some(_) => {
      var dd = lw.f.dbg!
      lw.f.dbg = none
      let old = dd.in_let
      dd.in_let = v
      lw.f.dbg = some(dd)
      some(old)
    }
    none => none
  }
}

fn let_(lw: var Lower, e: ast.Expr, pat: ast.Pat, value: ast.Expr, els: ast.ElseArm?) {
  let saved = lw.set_in_let(false)
  lw.let_body(e, pat, value, els)
  match saved {
    some(s) => if lw.f.dbg != none { let _ = lw.set_in_let(s) }
    none => {}
  }
}

/// The names a `let` binds from here on last until the end of the block (debugger scopes).
fn let_binds(lw: var Lower) { let _ = lw.set_in_let(true) }

fn let_body(lw: var Lower, e: ast.Expr, pat: ast.Pat, value: ast.Expr, els: ast.ElseArm?) {
  let arm = match els {
    some(a) => a
    none => {
      let v = lw.expr(value)
      if v.is_never() { return }
      lw.let_binds()
      lw.bind_value(pat, v)
      return
    }
  }
  let info = match lw.t.elses.get(e.id) {
    some(i) => i
    none => {
      let v = lw.expr(value)
      lw.let_binds()
      lw.bind_value(pat, v)
      return
    }
  }
  let v = lw.expr(value)
  lw.let_binds()
  if v.is_never() { return }
  match info.kind {
    Refutable => {
      let ty = v.ty
      let s = if v.owned {
        v.c
      } else {
        let c = lw.own(v)
        let n = lw.decl(ty, c)
        lw.register_local(n, ty)
        n
      }
      let test = lw.pat_test(pat, s)
      lw.open_if(test.not())
      lw.push(ScopeKind.Block)
      let fb = lw.expr(arm.body)
      lw.own_drop(fb)
      lw.pop()
      lw.close()
      lw.bind_pat(pat, s, ty)
    }
    _ => {
      let wt = v.ty
      let inner = match wt {
        Opt(t) | Res(t, _) => t
        t => t
      }
      let w = lw.hold(v)
      let r = lw.zero_decl(inner)
      let is_opt = wt is types.Ty.Opt(_)
      let okc = lw.fld(w, mir.Sel.F(0))
      if info.kind is typed.ElseKind.UnwrapRefutable(_) {
        // unwrap, then the pattern must match; otherwise the else (which diverges)
        lw.open_if(okc)
        lw.set(r, lw.fld(w, mir.Sel.F(1)))
        lw.close()
        let test = lw.pat_test(pat, r)
        let okv = lw.bdecl(okc)
        let matched = lw.bdecl(mir.bool_(false))
        lw.open_if(okv)
        lw.set(matched, test)
        lw.close()
        lw.open_if(matched.not())
        lw.push(ScopeKind.Block)
        match lw.g.release(inner, r) {
          some(rr) => {
            lw.open_if(okv)
            lw.emit(rr)
            lw.close()
          }
          none => {}
        }
        if !is_opt {
          lw.open_if(okv.not())
          lw.do_(mir.rt("auk_release", [lw.fld(w, mir.Sel.F(2))], mir.MTy.Void))
          lw.close()
        }
        let fb = lw.expr(arm.body)
        lw.own_drop(fb)
        lw.pop()
        lw.close()
        lw.register_local(r, inner)
        lw.bind_pat(pat, r, inner)
        return
      }
      lw.open_if(okc)
      lw.set(r, lw.fld(w, mir.Sel.F(1)))
      lw.else_()
      lw.push(ScopeKind.Block)
      if !is_opt { lw.bind_err(info.binder, w, wt) }
      let fb = lw.expr(arm.body)
      let o = lw.own_as(fb, inner)
      lw.set(r, o)
      lw.pop()
      lw.close()
      let rv = Val { c: r, ty: inner, owned: true }
      lw.register(r, inner)
      lw.bind_value(pat, rv)
    }
  }
}

/// Bind an irrefutable pattern to a value (a plain name takes the value over).
pub fn bind_value(lw: var Lower, pat: ast.Pat, v: Val) {
  let ty = v.ty
  match pat.kind {
    Bind(_) => if !lw.t.variants.contains(pat.id) {
      match lw.t.binds.get(pat.id) {
        // a raw struct made for this binding (a literal, a call's result) is the variable
        // itself, not copied into another (unoptimized code would keep the copy)
        some(l) when v.owned && v.c.is_var() && lw.is_raw_struct(ty) => {
          lw.unregister(v.c)
          lw.register_local(v.c, ty)
          lw.bind_name(l, Slot { c: v.c, ty })
        }
        some(l) => {
          let o = lw.own_as(v, ty)
          let n = lw.decl(ty, o)
          lw.register_local(n, ty)
          lw.bind_name(l, Slot { c: n, ty })
        }
        none => {}
      }
      return
    }
    Wild => return
    _ => {}
  }
  let s = lw.lvalue(v, ty)
  lw.bind_pat(pat, s, ty)
}

fn is_cmp_op(op: ast.BinOp): bool = match op {
  Eq | Ne | Lt | Le | Gt | Ge => true
  _ => false
}

fn assert_(lw: var Lower, x: ast.Expr) {
  let lc = lw.loc(x.span)
  let text = mir.cstr(lw.g.span_text(lw.m, x.span))
  match x.kind {
    Binary(op, lhs, rhs) => if is_cmp_op(op) {
      let l = lw.expr(lhs)
      let r = lw.expr(rhs)
      let c = lw.compare(x, op, l, r)
      let cv = lw.decl(types.Ty.Bool, c)
      lw.open_if(cv.not())
      let ls = lw.dshow(l)
      let rs = lw.dshow(r)
      lw.do_(mir.rt("auk_assert_fail_cmp", [lc, text, ls, rs], mir.MTy.Void))
      lw.emit(mir.Stmt.Unreachable)
      lw.close()
      return
    }
    _ => {}
  }
  let v = lw.expr(x)
  let c = lw.val_as(v, types.Ty.Bool)
  lw.open_if(c.not())
  lw.do_(mir.rt("auk_assert_fail", [lc, text], mir.MTy.Void))
  lw.emit(mir.Stmt.Unreachable)
  lw.close()
}

/// Debug-form show of a value (strings quoted), as an owned `str` expression.
fn dshow(lw: var Lower, v: Val): mir.Ex {
  if v.is_never() { return mir.zero(ty_str()) }
  match lw.g.dshow_fn(v.ty) {
    some(f) => lw.g.call_ref(f, [v.c], ty_str())
    none => mir.rt("auk_str_lit", [mir.cstr("<{lw.g.show_ty(v.ty)}>")], ty_str())
  }
}

// ---- literals ----

fn interp(lw: var Lower, parts: [ast.InterpPart]): Val {
  var vals: [Val] = []
  for p in parts {
    match p {
      Expr(x, _) => vals.push(lw.expr(x))
      _ => {}
    }
  }
  let sb = lw.bdecl(mir.zero(mir.MTy.Rt(mir.Rt.StrBuf)))
  let sbp = sb.addr()
  var k = 0
  for p in parts {
    match p {
      Lit(s) => if s.len() > 0 {
        lw.do_(mir.rt("auk_sb_bytes", [sbp, mir.cstr(s), mir.int_(s.byte_len())], mir.MTy.Void))
      }
      Expr(x, _) => {
        let v = vals[k]
        k += 1
        let spec = match lw.t.formats.get(x.id) {
          some(f) => some(mir.cstr(f.text))
          none => none
        }
        let c = v.c
        if v.is_never() { continue }
        let st = ty_str()
        let own = (s: mir.Ex) => mir.rt("auk_sb_str_own", [sbp, s], mir.MTy.Void)
        let e = match (v.ty, spec) {
          (Int, some(s)) => own(mir.rt("auk_fmt_int", [c, s], st))
          (Int, none) => mir.rt("auk_sb_int", [sbp, c], mir.MTy.Void)
          (Float, some(s)) => own(mir.rt("auk_fmt_float", [c, s], st))
          (Float, none) => own(mir.rt("auk_str_from_float", [c], st))
          (Str, some(s)) => own(mir.rt("auk_fmt_str", [c, s], st))
          (Str, none) => mir.rt("auk_sb_str", [sbp, c], mir.MTy.Void)
          (Char, some(s)) => own(mir.rt("auk_fmt_char", [c, s], st))
          (Char, none) => mir.rt("auk_sb_char", [sbp, c], mir.MTy.Void)
          (Bool, some(s)) => own(mir.rt("auk_fmt_bool", [c, s], st))
          (Bool, none) => mir.rt("auk_sb_lit", [sbp, mir.cond(c, mir.cstr("true"), mir.cstr("false"))], mir.MTy.Void)
          (_, spec) => {
            let shown = lw.show_of(x.id, v)
            match spec {
              some(s) => {
                let t = lw.decl(types.Ty.Str, shown)
                lw.do_(own(mir.rt("auk_fmt_str", [t, s], st)))
                mir.rt("auk_release", [t], mir.MTy.Void)
              }
              none => own(shown)
            }
          }
        }
        lw.do_(e)
        match lw.t.units.get(x.id) {
          some(u) => {
            let us = " {u}"
            lw.do_(mir.rt("auk_sb_bytes", [sbp, mir.cstr(us), mir.int_(us.byte_len())], mir.MTy.Void))
          }
          none => {}
        }
      }
    }
  }
  lw.tmp(types.Ty.Str, mir.rt("auk_sb_finish", [sbp], ty_str()))
}

fn struct_lit(lw: var Lower, e: ast.Expr): Val {
  let (fields, base) = match e.kind {
    Struct(_, fields, base) => (fields, base)
    _ => mir.bug("struct_lit")
  }
  let ty = lw.ty(e.id)
  let sl = lw.t.struct_lits.get(e.id) else return val_never()
  let (dd, targs) = match ty {
    Named(dd, args) => (dd, args)
    _ => return val_never()
  }
  let s = types.subst_of(lw.tp.defs, dd, targs)
  let defs = types.fields(lw.tp.defs, dd)
  var given: [(int, mir.Ex)] = []
  for (fi, fv) in sl.fields {
    let ft = types.subst(defs[fi].ty, s)
    let v = match fv {
      Expr(id) => {
        var x: ast.Expr? = none
        for f in fields {
          match f.value {
            some(y) => if x == none && y.id == id { x = some(y) }
            none => {}
          }
        }
        match x {
          some(x) => lw.expr(x)
          none => val_never()
        }
      }
      Local(l, cs) => {
        let (c, lt) = match lw.f.locals.get(l) {
          some(sl2) => (sl2.c, sl2.ty)
          none => {
            let lt = lw.local_ty(l)
            (lw.g.zero(lt), lt)
          }
        }
        lw.coerce(plain(c, lt), cs, e.id)
      }
    }
    let o = lw.own_as(v, ft)
    let n = lw.decl(ft, o)
    lw.register(n, ft)
    given.push((fi, n))
  }
  match base {
    some(b) => {
      let bv = lw.expr(b)
      for (_, n) in given { lw.unregister(n) }
      let o = lw.own_as(bv, ty)
      let r = lw.decl(ty, o)
      for (fi, n) in given {
        let ft = types.subst(defs[fi].ty, s)
        let (f, boxed) = lw.g.field_raw(ty, fi, r)
        if boxed {
          lw.do_(mir.rt("auk_release", [f], mir.MTy.Void))
        } else {
          match lw.g.release(ft, f) {
            some(rel) => lw.emit(rel)
            none => {}
          }
        }
        let put = lw.g.field_put(ty, fi, n)
        lw.set(f, put)
      }
      lw.reown(r, ty)
    }
    none => {
      for (_, n) in given { lw.unregister(n) }
      var parts: [(mir.Sel, mir.Ex)] = []
      for (fi, n) in given {
        let put = lw.g.field_put(ty, fi, n)
        parts.push((mir.Sel.F(fi), put))
      }
      lw.tmp(ty, mir.agg(d(ty), parts))
    }
  }
}

/// `await any ts` → `auk_task_await_any(data, n, &out, &err, loc)`.
fn await_any(lw: var Lower, e: ast.Expr, x: ast.Expr): Val {
  let ty = lw.ty(e.id)
  let parts = match ty {
    Tuple(ps) => ps
    _ => return val_never()
  }
  let res = parts[1]
  let okt = match res {
    Res(o, _) => o
    _ => return val_never()
  }
  let tv = lw.expr(x)
  let tt = match tv.ty {
    List(tt) => tt
    _ => return val_never()
  }
  let inner = match tt {
    Task(i) => i
    _ => return val_never()
  }
  let wrapped = inner is types.Ty.Res(_, _)
  let n = lw.decl(types.Ty.Int, mir.rt("auk_arr_len", [tv.c], ty_int()))
  let data = tv.c.rt_field(mir.RtF.ArrData).cast(mir.ptr(mir.ptr(mir.MTy.Rt(mir.Rt.Task))))
  let et = lw.g.err_ty()
  let err = lw.zero_decl(et)
  let r = lw.zero_decl(res)
  var out = mir.zero(mir.void_ptr())
  var v: mir.Ex? = none
  if wrapped {
    out = r.addr().cast(mir.void_ptr())
  } else if has_value(okt) {
    let vv = lw.zero_decl(okt)
    out = vv.addr().cast(mir.void_ptr())
    v = some(vv)
  }
  let lc = lw.loc(e.span)
  let idx = lw.decl(types.Ty.Int, mir.rt("auk_task_await_any", [data, n, out, err.addr().cast(mir.void_ptr()), lc], ty_int()))
  lw.open_if(mir.bin(mir.BOp.Ne, err.cast(mir.void_ptr()), mir.zero(mir.void_ptr())))
  lw.set(r, mir.agg(d(res), [(mir.Sel.F(2), err)]))
  if !wrapped {
    lw.else_()
    var fs = [(mir.Sel.F(0), mir.bool_(true))]
    match v {
      some(vv) => fs.push((mir.Sel.F(1), vv))
      none => {}
    }
    lw.set(r, mir.agg(d(res), fs))
  }
  lw.close()
  lw.tmp(ty, mir.agg(d(ty), [(mir.Sel.F(0), idx), (mir.Sel.F(1), r)]))
}

// ---- `catch` ----

/// `catch body`: lift the body into `R dk_catch{k}(env)` and a C thunk `dk_catcht{k}(env, out)`
/// that stores its value; `auk_catch` runs the thunk under a recovery point and returns the
/// panic as an `Err` (NULL when the body finished).
fn catch_(lw: var Lower, e: ast.Expr, body: ast.Expr): Val {
  let info = lw.t.closures.get(e.id) else return val_never()
  let ret = lw.sub(info.ret)
  let k = lw.g.fresh()
  // the captured variables' places in this function
  var caps: [(int, mir.Ex, types.Ty)] = []
  for l in info.captures {
    match lw.f.locals.get(l) {
      some(s) => caps.push((l, s.c, s.ty))
      none => {
        let ty = lw.local_ty(l)
        caps.push((l, lw.zero_decl(ty), ty))
      }
    }
  }
  var envf = caps.map(c => mir.ptr(d(c.2)))
  envf.push(mir.void_ptr())
  let env = lw.g.agg("DkCatchEnv{k}", envf)
  // the body
  let fname = lw.g.declare("dk_catch{k}", [mir.void_ptr()], d(ret), mir.Abi.Auk)
  let pv = lw.begin_fn(fname, ret)
  lw.push(ScopeKind.Block)
  let ev = pv[0].cast(mir.ptr(mir.MTy.Agg(env))).deref(mir.MTy.Agg(env))
  for i, (l, _, ty) in caps {
    let p = lw.g.fld(ev, mir.Sel.F(i))
    lw.bind_name(l, Slot { c: p.deref(d(ty)), ty })
  }
  let v = lw.expr(body)
  lw.ret_val(v, ret)
  let z = lw.g.zero(ret)
  lw.emit(mir.Stmt.Ret(z))
  lw.end(fname)
  // the thunk: *out = dk_catch{k}(env)
  let thunk = lw.g.declare("dk_catcht{k}", [mir.void_ptr(), mir.void_ptr()], mir.MTy.Void, mir.Abi.C)
  let (b0, tv) = lw.g.body_for(thunk)
  var b = b0
  let c = lw.g.call(fname, [tv[0]])
  b.set(tv[1].cast(mir.ptr(d(ret))).deref(d(ret)), c)
  lw.g.define(thunk, b)
  // run it
  var fields: [(mir.Sel, mir.Ex)] = []
  for i, (_, cc, _) in caps { fields.push((mir.Sel.F(i), cc.addr())) }
  let n = fields.len()
  fields.push((mir.Sel.F(n), mir.zero(mir.void_ptr())))
  let envv = lw.bdecl(mir.agg(mir.MTy.Agg(env), fields))
  let r = lw.zero_decl(ret)
  let et = lw.g.err_ty()
  let err = lw.decl(
    et,
    mir.rt("auk_catch", [mir.fn_addr(thunk), envv.addr().cast(mir.void_ptr()), r.addr().cast(mir.void_ptr())], d(et)),
  )
  lw.open_if(mir.bin(mir.BOp.Ne, err.cast(mir.void_ptr()), mir.zero(mir.void_ptr())))
  lw.set(r, mir.agg(d(ret), [(mir.Sel.F(2), err)]))
  lw.close()
  lw.reown(r, ret)
}

// ---- closures ----

fn closure(lw: var Lower, e: ast.Expr, params: [ast.Param], body: ast.Expr): Val {
  let info = lw.t.closures.get(e.id) else return val_never()
  let ptys = info.params.map(t => types.subst(t, lw.subst))
  let ret = lw.sub(info.ret)
  let k = lw.g.fresh()
  // capture
  var caps: [(int, mir.Ex, types.Ty)] = []
  for l in info.captures {
    match lw.f.locals.get(l) {
      some(s) => caps.push((l, s.c, s.ty))
      none => {
        let ty = lw.local_ty(l)
        caps.push((l, lw.g.zero(ty), ty))
      }
    }
  }
  var env: (int, int, int)? = none
  if caps.len() > 0 {
    var fs = [mir.MTy.Rt(mir.Rt.Obj)]
    for c in caps { fs.push(d(c.2)) }
    let a = lw.g.agg("DkEnv{k}", fs)
    let drop = lw.g.declare("DkEnv{k}_drop", [mir.obj_ptr()], mir.MTy.Void, mir.Abi.C)
    let (b0, pv) = lw.g.body_for(drop)
    var b = b0
    let ev = pv[0].cast(mir.ptr(mir.MTy.Agg(a))).deref(mir.MTy.Agg(a))
    for i, (_, _, ty) in caps {
      let f = lw.g.fld(ev, mir.Sel.F(i + 1))
      match lw.g.release(ty, f) {
        some(r) => b.emit(r)
        none => {}
      }
    }
    lw.g.define(drop, b)
    // the copy (a task's argument): a new env with deep copies of the captures
    let copy = lw.g.declare("DkEnv{k}_copy", [mir.obj_ptr()], mir.obj_ptr(), mir.Abi.C)
    let (b1, pv1) = lw.g.body_for(copy)
    var bc = b1
    let ev1 = pv1[0].cast(mir.ptr(mir.MTy.Agg(a))).deref(mir.MTy.Agg(a))
    let nv = bc.decl(
      mir.rt("auk_obj_alloc", [mir.size_of(mir.MTy.Agg(a)), mir.fn_addr(drop), mir.fn_addr(copy)], mir.ptr(mir.MTy.Agg(a))),
    )
    for i, (_, _, ty) in caps {
      let f = lw.g.fld(ev1, mir.Sel.F(i + 1))
      let c = lw.g.copy_ex(ty, f)
      let place = lw.g.fld(nv.deref(mir.MTy.Agg(a)), mir.Sel.F(i + 1))
      bc.set(place, c)
    }
    bc.emit(mir.Stmt.Ret(nv.cast(mir.obj_ptr())))
    lw.g.define(copy, bc)
    env = some((a, drop, copy))
  }
  // the lifted function
  let fty = if info.unpack { [types.Ty.Tuple(ptys)] } else { ptys }
  var pts = [mir.obj_ptr()]
  for t in fty { pts.push(param_mty(t)) }
  let fname = lw.g.declare("dk_clo{k}", pts, d(ret), mir.Abi.Auk)
  let pv = lw.begin_fn(fname, ret)
  let owner = match lw.tp.instances[lw.inst].body {
    Fn(f) => "{lw.trace_mod_name(lw.tp.fns[f].module)}.{lw.tp.fns[f].name}"
    _ => lw.trace_mod_name(lw.m)
  }
  let n = "{owner}.<fn:{e.span.line}>"
  lw.name_fn(fname, n)
  lw.dbg_begin(n)
  lw.push(ScopeKind.Block)
  match env {
    some((a, _, _)) => {
      let ev = pv[0].cast(mir.ptr(mir.MTy.Agg(a))).deref(mir.MTy.Agg(a))
      for i, (l, _, ty) in caps {
        let c = lw.g.fld(ev, mir.Sel.F(i + 1))
        lw.bind_name(l, Slot { c, ty })
      }
    }
    none => {}
  }
  if info.unpack {
    for i, p in params {
      if i >= ptys.len() { break }
      let c = lw.fld(pv[1], mir.Sel.F(i))
      lw.bind_top(p.pat, c, ptys[i])
    }
  } else {
    for i, p in params {
      if i >= ptys.len() { break }
      match ptys[i] {
        // a `var` parameter: a pointer to the caller's variable
        Mut(inner) => {
          let place = pv[i + 1].deref(d(inner))
          lw.bind_top(p.pat, place, inner)
        }
        t => lw.bind_top(p.pat, pv[i + 1], t)
      }
    }
  }
  if !(body.kind is ast.ExprKind.Block(_)) { lw.dbg_hook(body.span, true) }
  let v = lw.expr(body)
  if types.is_unit(ret) {
    if !v.is_never() {
      lw.cleanup_from(0)
      lw.emit(mir.Stmt.Ret(mir.zero(d(ret))))
    }
  } else {
    lw.ret_val(v, ret)
  }
  let z = lw.g.zero(ret)
  lw.emit(mir.Stmt.Ret(z))
  lw.end(fname)
  // build the value
  let fnty = types.func(fty, ret)
  let (a, drop, copy) = match env {
    some(x) => x
    none => return plain(closure_val(fname, fnty, mir.zero(mir.obj_ptr())), fnty)
  }
  let ev = lw.bdecl(mir.rt("auk_obj_alloc", [mir.size_of(mir.MTy.Agg(a)), mir.fn_addr(drop), mir.fn_addr(copy)], mir.ptr(mir.MTy.Agg(a))))
  for i, (_, c, ty) in caps {
    let o = lw.own(plain(c, ty))
    let f = lw.fld(ev.deref(mir.MTy.Agg(a)), mir.Sel.F(i + 1))
    lw.set(f, o)
  }
  let cv = closure_val(fname, fnty, ev.cast(mir.obj_ptr()))
  lw.tmp(fnty, cv)
}

fn a_ty(a: ArgV): types.Ty = match a {
  Val(v) => v.ty
  Addr(_, t) => t
}

/// The argument expressions of `old(e)` calls (whose ids are in `olds`) inside `e`.
fn collect_olds(e: ast.Expr, olds: [int], out: var [ast.Expr]) {
  match e.kind {
    Call(callee, args) => match callee.kind {
      Name(n) => if n == "old" && args.len() == 1 && olds.contains(args[0].id) {
        out.push(args[0])
        return
      }
      _ => {}
    }
    _ => {}
  }
  match e.kind {
    Call(callee, args) => {
      collect_olds(callee, olds, &out)
      for a in args { collect_olds(a, olds, &out) }
    }
    MethodCall(recv, _, args) => {
      collect_olds(recv, olds, &out)
      for a in args { collect_olds(a, olds, &out) }
    }
    Binary(_, l, r) => {
      collect_olds(l, olds, &out)
      collect_olds(r, olds, &out)
    }
    Unary(_, x) | Field(x, _) | TupleField(x, _) => collect_olds(x, olds, &out)
    Index(x, i) => {
      collect_olds(x, olds, &out)
      collect_olds(i, olds, &out)
    }
    Tuple(xs) | List(xs) => for x in xs { collect_olds(x, olds, &out) }
    Pipe(lhs, _, args) => {
      collect_olds(lhs, olds, &out)
      for a in args { collect_olds(a, olds, &out) }
    }
    _ => {}
  }
}

/// `a op b` on `int`: checked arithmetic and shifts go through runtime helpers that panic at
/// `loc`; the wrapping and bitwise ones can't fail.
fn int_op(op: ast.BinOp, a: mir.Ex, b: mir.Ex, lc: mir.Ex): mir.Ex = match op {
  Add => mir.rt("auk_add", [a, b, lc], ty_int())
  Sub => mir.rt("auk_sub", [a, b, lc], ty_int())
  Mul => mir.rt("auk_mul", [a, b, lc], ty_int())
  Div => mir.rt("auk_div", [a, b, lc], ty_int())
  Rem => mir.rt("auk_mod", [a, b, lc], ty_int())
  Pow => mir.rt("auk_pow", [a, b, lc], ty_int())
  AddWrap => mir.bin(mir.BOp.Add, a, b)
  SubWrap => mir.bin(mir.BOp.Sub, a, b)
  MulWrap => mir.bin(mir.BOp.Mul, a, b)
  BitAnd => mir.bin(mir.BOp.BitAnd, a, b)
  BitOr => mir.bin(mir.BOp.BitOr, a, b)
  BitXor => mir.bin(mir.BOp.BitXor, a, b)
  Shl => mir.rt("auk_shl", [a, b, lc], ty_int())
  Shr => mir.rt("auk_shr", [a, b, lc], ty_int())
  _ => mir.int_(0)
}

/// What a run of statements does, for the move-out check (`move_out`): the names it mentions,
/// the names it may change, and whether it may leave early.
pub struct Scan { names: {str: bool}, changed: {str: bool}, exits: bool }

fn new_scan(): Scan = Scan { names: {}, changed: {}, exits: false }

/// The name a place expression is rooted at (`p` for `p.a[i].b`, `&p`).
fn root_name(e: ast.Expr): str? = match e.kind {
  Name(n) => some(n)
  Field(x, _) | TupleField(x, _) | Index(x, _) | Slice(x, _, _, _) | Ref(x) => root_name(x)
  _ => none
}

/// An assignment target (`x`, `p.a[i]`, `(a, b)`): the variables it changes.
fn assigned(sc: var Scan, t: ast.Expr) {
  match t.kind {
    Tuple(xs) => for x in xs { sc.assigned(x) }
    _ => match root_name(t) {
      some(r) => sc.changed[r] = true
      none => {}
    }
  }
}

fn scan_block(sc: var Scan, b: ast.Block) {
  for x in b.stmts { sc.scan(x) }
}

fn changes(sc: var Scan, x: ast.Expr) {
  match root_name(x) {
    some(r) => sc.changed[r] = true
    none => {}
  }
}

fn scan(sc: var Scan, e: ast.Expr) {
  match e.kind {
    Lit(_) | Hole | FieldSel(_) | Uninit => {}
    TypeArgs(x, _) => sc.scan(x)
    Name(n) => sc.names[n] = true
    Measured(x, _) | Field(x, _) | TupleField(x, _) | Unary(_, x) => sc.scan(x)
    Unwrap(x) | Await(x) | AwaitAny(x) | Catch(x) | Assert(x) | Peek(x) => sc.scan(x)
    Ref(x) => {
      sc.changes(x)
      sc.scan(x)
    }
    Interp(parts) => for p in parts {
      match p {
        Expr(x, _) => sc.scan(x)
        _ => {}
      }
    }
    Call(callee, args) => {
      match callee.kind {
        Name(n) => if n == "fail" { sc.exits = true }
        _ => {}
      }
      sc.scan(callee)
      for a in args { sc.scan(a) }
    }
    MethodCall(recv, _, args) => {
      // a dot call may pass its receiver by `var` without `&`
      sc.changes(recv)
      sc.scan(recv)
      for a in args { sc.scan(a) }
    }
    Pipe(lhs, callee, args) => {
      sc.changes(lhs)
      sc.scan(lhs)
      sc.scan(callee)
      for a in args { sc.scan(a) }
    }
    Index(x, i) => {
      sc.scan(x)
      sc.scan(i)
    }
    Slice(x, lo, hi, _) => {
      sc.scan(x)
      sc.scan(lo)
      sc.scan(hi)
    }
    Binary(_, l, r) | Range(l, r, _) => {
      sc.scan(l)
      sc.scan(r)
    }
    Is(x, _) => sc.scan(x)
    OptChain(x, _, args) => {
      sc.scan(x)
      for a in (args else []) { sc.scan(a) }
    }
    Else(x, arm) => {
      sc.scan(x)
      sc.scan(arm.body)
    }
    Closure(_, body) => sc.scan(body)
    If(cond, then, els) => {
      sc.scan(cond)
      sc.scan_block(then)
      match els {
        some(x) => sc.scan(x)
        none => {}
      }
    }
    Match(scrut, arms) => {
      sc.scan(scrut)
      for a in arms {
        match a.guard {
          some(gx) => sc.scan(gx)
          none => {}
        }
        sc.scan(a.body)
      }
    }
    Loop(b) | Block(b) => sc.scan_block(b)
    While(cond, body) => {
      sc.scan(cond)
      sc.scan_block(body)
    }
    For(_, _, iter, body) => {
      sc.scan(iter)
      sc.scan_block(body)
    }
    Let(_, _, _, value, els) => {
      sc.scan(value)
      match els {
        some(a) => sc.scan(a.body)
        none => {}
      }
    }
    Assign(_, target, value) => {
      sc.assigned(target)
      sc.scan(target)
      sc.scan(value)
    }
    Struct(_, fields, base) => {
      for f in fields {
        match f.value {
          some(v) => sc.scan(v)
          none => sc.names[f.name.name] = true
        }
      }
      match base {
        some(b) => sc.scan(b)
        none => {}
      }
    }
    List(xs) | Tuple(xs) => for x in xs { sc.scan(x) }
    Map(kvs) => for (k, v) in kvs {
      sc.scan(k)
      sc.scan(v)
    }
    Return(x) | Break(x) => {
      sc.exits = true
      match x {
        some(x) => sc.scan(x)
        none => {}
      }
    }
    Continue | Try(_) => sc.exits = true
  }
}
