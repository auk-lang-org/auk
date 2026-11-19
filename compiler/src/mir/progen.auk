/// Program-level MIR generation (src/mir/progen.rs): refcounting helpers, element-ops tables,
/// the compiler-derived instances of the built-in shapes (`Show`, `Eq`, `Ord`, hashing,
/// `to_value` / `from_value`), boxes, string literals, constants and imprints, vtable types.
/// Function bodies are lowered by `mir.lower`; `mir.build` adds the entry point.
///
/// # Ownership
/// The runtime's rules: arguments are borrowed, results are owned (+1). `retain`/`release` give
/// the statements that copy/drop a value of any type.
///
/// Differences from Rust: `Gen`'s methods take `g: var Gen` (a pointer, so no copy of the whole
/// state per call, even for the ones that only read); `TyInfo`'s `needs_rc` memo lives here
/// (`rc`); Rust's closures that change a `Body` or the `Gen` are module functions with the
/// captured values as parameters (`rc_both`, `copy_field`, `show_field`, `kid`, ...).
/// `helper`'s `make` is a `(var Gen, int) => mir.Body`.

/// What kind of program is being built.
pub enum Mode {
  /// `auk run` / `auk ir`: debug build (ensures checked), entry point `main`.
  Run,
  /// `auk build`: release build (ensures not checked).
  Release,
  /// `auk test`: debug build, entry point is the test runner.
  Test,
}

/// Execution-trace instrumentation (`auk run --trace`, `auk test --trace`). With `on` unset
/// (every other build) the generated program is exactly what it would be without tracing.
pub struct Trace {
  /// Wrap the traced functions, set call sites, and start the tracer in `main`.
  on: bool,
  /// Trace the core library's Auk functions too (with `debug`: instrument them too).
  core: bool,
  /// Instrument for the debugger (`auk run --debug`; see `Debug`).
  debug: bool,
  /// Source locations for DWARF line tables (`auk build -g`).
  lines: bool,
}

pub fn no_trace(): Trace = Trace { on: false, core: false, debug: false, lines: false }

/// Debugger instrumentation (`auk run --debug`). With `on` unset (every other build) the
/// generated program is exactly what it would be without it.
pub struct Debug { on: bool, core: bool }

/// A statement the debugger can stop at.
pub struct DbgSite {
  func: int,
  file: str,
  line: int,
  col: int,
  end_line: int,
  end_col: int,
  /// An expression body (`= e`, `x => e`) rather than a statement of a block.
  wrap: bool,
  /// The frame slots of the locals in scope at the statement.
  vis: [int],
}

/// An instrumented function: its name, and the name and type (index into `DbgInfo.types`) of
/// each frame slot.
pub struct DbgFn {
  name: str,
  locals: [(str, int)],
  /// Its body (the enclosing function's, for a closure) and type arguments.
  body: typed.BodyRef,
  type_args: [types.Ty],
}

/// The debug info of a program built with `Debug.on`.
pub struct DbgInfo {
  sites: [DbgSite],
  fns: [DbgFn],
  types: [types.Ty],
  type_ids: {types.Ty: int},
}

pub fn type_id(di: var DbgInfo, t: types.Ty): int {
  match di.type_ids.get(t) {
    some(i) => return i
    none => {}
  }
  di.types.push(t)
  let i = di.types.len() - 1
  di.type_ids[t] = i
  i
}

/// A value computed at compile time: the `Value` tree of an evaluated imprint.
pub enum CVal {
  Null,
  Bool(b: bool),
  Int(n: int),
  Float(x: float),
  Str(s: str),
  List(xs: [CVal]),
  Map(es: [(str, CVal)]),
}

fn cval_field(v: CVal, key: str): CVal? = match v {
  Map(es) => {
    for (k, x) in es {
      if k == key { return x }
    }
    none
  }
  _ => none
}

/// A C identifier fragment from an Auk name.
pub fn sanitize(s: str): str {
  var out: [char] = []
  for c in s.chars() {
    let ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
    out.push(if ok { c } else { '_' })
  }
  str(out)
}

pub fn d(t: types.Ty): mir.MTy = mir.MTy.D(t)

fn ty_str(): mir.MTy = mir.MTy.D(types.Ty.Str)

pub struct Gen {
  tp: typed.TypedProgram,
  mode: Mode,
  info: mir.types.TyInfo,
  /// `TyInfo`'s `needs_rc` memo.
  rc: {types.Ty: bool},
  prog: mir.Program,
  /// `auk run --live`'s key of each user function instance (Rust's `Program::live_keys`).
  live_keys: {int: str},
  memo: {(str, types.Ty): int},
  /// Other memoized generated items (thunks, function values, vtables), by key.
  memo2: {str: int},
  lits: {str: int},
  lit_order: [(str, int)],
  type_ids: {types.Ty: int},
  n: int,
  /// Instances that have been emitted (or are being emitted).
  emitted: {int: bool},
  /// Instances still to emit.
  queue: [int],
  inst_fns: {int: int},
  /// The MIR global of each global of the runtime's dialect used so far.
  raw_globals: {int: int},
  /// Holes found in emitted bodies: "file:line:col: unfilled hole (expected T)".
  holes: [str],
  consts: {int: int},
  /// (getter, free function) of each lazily computed constant, in creation order.
  const_order: [(int, int)],
  /// Building the imprint evaluator: constant getters report on the imprint protocol, and
  /// `to_value` is always the derived one.
  imprint_eval: bool,
  /// The compile-time values of the imprints (final program).
  imprints: {int: CVal},
  imprint_inits: [int],
  trace: Trace,
  dbg: Debug,
  dbg_info: DbgInfo,
  /// Emit `Stmt.Loc` at every statement (DWARF line tables, `auk build -g`).
  lines: bool,
  /// The bytes of every `"#embed path"` file (read before lowering, so lowering needs no `fs`).
  embeds: {str: [int]},
}

/// Move the state out of `g` (leaving an empty one that shares only the read-only parts), so
/// whoever holds it next changes its lists in place (`mir.lower.emit_instance`).
pub fn take(g: var Gen): Gen {
  let x = g
  g = Gen {
    rc: {},
    prog: mir.Program { funcs: [], aggs: [], globals: [], entry: none, locs: [], names: {}, links: [], c_syms: [], exports: {} },
    live_keys: {},
    memo: {},
    memo2: {},
    lits: {},
    lit_order: [],
    type_ids: {},
    emitted: {},
    queue: [],
    inst_fns: {},
    raw_globals: {},
    holes: [],
    consts: {},
    const_order: [],
    imprints: {},
    imprint_inits: [],
    dbg_info: DbgInfo { sites: [], fns: [], types: [], type_ids: {} },
    ..x
  }
  x
}

pub fn new(tp: typed.TypedProgram, mode: Mode): Gen {
  var links: [str] = []
  for p in tp.program.pkgs {
    for l in p.links {
      if !links.contains(l) { links.push(l) }
    }
  }
  Gen {
    tp,
    mode,
    info: mir.types.new(tp),
    rc: {},
    prog: mir.Program {
      funcs: [],
      aggs: [],
      globals: [],
      entry: none,
      locs: [],
      names: {},
      links,
      c_syms: [],
      exports: {},
    },
    live_keys: {},
    memo: {},
    memo2: {},
    lits: {},
    lit_order: [],
    type_ids: {},
    n: 0,
    emitted: {},
    queue: [],
    inst_fns: {},
    raw_globals: {},
    holes: [],
    consts: {},
    const_order: [],
    imprint_eval: false,
    imprints: {},
    imprint_inits: [],
    trace: no_trace(),
    dbg: Debug { on: false, core: false },
    dbg_info: DbgInfo { sites: [], fns: [], types: [], type_ids: {} },
    lines: false,
    embeds: {},
  }
}

/// Is a function of module `m` traced?
pub fn traced(g: var Gen, m: int): bool =
  g.trace.on && (g.trace.core || !resolve.is_core(g.tp.program, m))

/// Are the functions of module `m` instrumented for the debugger?
pub fn dbg_on(g: var Gen, m: int): bool = g.dbg.on && (g.dbg.core || !resolve.is_core(g.tp.program, m))

pub fn debug(g: var Gen): bool = g.mode != Mode.Release

pub fn fresh(g: var Gen): int {
  g.n += 1
  g.n
}

pub fn show_ty(g: var Gen, t: types.Ty): str = types.show(g.tp.defs, t)

pub fn is_value(g: var Gen, t: types.Ty): bool = mir.types.is_value(g.info, t)

pub fn is_err_ty(g: var Gen, t: types.Ty): bool = mir.types.is_err_ty(g.info, t)

pub fn err_ty(g: var Gen): types.Ty = mir.types.err_ty(g.info)

pub fn needs_rc(g: var Gen, t: types.Ty): bool = mir.types.needs_rc(g.info, &g.rc, t)

// ---- functions, aggregates, globals ----

/// Declare a function (its body is defined later with `define`).
pub fn declare(g: var Gen, name: str, params: [mir.MTy], ret: mir.MTy, abi: mir.Abi): int {
  let n = params.len()
  g.prog.funcs.push(mir.Func { name, params: (0..n), ret, vars: params, body: [], abi })
  g.prog.funcs.len() - 1
}

/// A body whose first variables are the parameters of `f`.
pub fn body_for(g: var Gen, f: int): (mir.Body, [mir.Ex]) {
  var b = mir.new_body()
  var ps: [mir.Ex] = []
  for t in g.prog.funcs[f].vars { ps.push(b.new_var(t)) }
  (b, ps)
}

pub fn define(g: var Gen, f: int, b: mir.Body) {
  var b2 = b
  let (body, vars) = b2.finish()
  g.prog.funcs[f].body = body
  g.prog.funcs[f].vars = vars
}

pub fn func_ret(g: var Gen, f: int): mir.MTy = g.prog.funcs[f].ret

pub fn agg(g: var Gen, name: str, fields: [mir.MTy]): int {
  g.prog.aggs.push(mir.AggDef { name, fields })
  g.prog.aggs.len() - 1
}

pub fn global(g: var Gen, name: str, ty: mir.MTy, init: mir.Ex?, constant: bool): int {
  g.prog.globals.push(mir.Global { name, ty, init, constant, kind: 0 })
  g.prog.globals.len() - 1
}

pub fn global_ex(g: var Gen, gl: int): mir.Ex = mir.ex(mir.K.Global(gl), g.prog.globals[gl].ty)

/// A compile-time constant of the runtime's dialect as a MIR expression of type `t`.
pub fn raw_const(g: var Gen, v: typed.ConstVal, t: types.Ty): mir.Ex = match v {
  Int(n) => mir.int_as(n, d(t))
  Float(x) => mir.ex(mir.K.Float(x), d(types.Ty.Float)).cast(d(t))
  Zero => mir.zero(d(t))
  GlobalAddr(id) => mir.ex(mir.K.GlobalAddr(g.raw_global(id)), d(t))
  FnAddr(f) => {
    let i = g.tp.instances.find_index(x => x.body == typed.BodyRef.Fn(f) && x.type_args.len() == 0) else mir.bug("raw.fn_of: no instance of {g.tp.fns[f].name}")
    mir.fn_addr(g.inst_fn(i)).cast(d(t))
  }
  Agg(fs) => {
    let (dd, args) = match t {
      Named(dd, args) => (dd, args)
      Array(et, _) => {
        var ms: [(mir.Sel, mir.Ex)] = []
        for (i, fv) in fs { ms.push((mir.Sel.F(i), g.raw_const(fv, et))) }
        return mir.agg(d(t), ms)
      }
      _ => return mir.zero(d(t))
    }
    let defs = types.fields(g.tp.defs, dd)
    let s = types.subst_of(g.tp.defs, dd, args)
    var ms: [(mir.Sel, mir.Ex)] = []
    for (i, fv) in fs { ms.push((mir.Sel.F(i), g.raw_const(fv, types.subst(defs[i].ty, s)))) }
    mir.agg(d(t), ms)
  }
}

/// The MIR global of global `id` of the runtime's dialect (`typed.GlobalInfo`), made on first
/// use with its constant initializer (which may hold its own address).
pub fn raw_global(g: var Gen, id: int): int {
  match g.raw_globals.get(id) {
    some(x) => return x
    none => {}
  }
  let gl = g.tp.globals[id]
  let name = if gl.kind == 4 { gl.c_name } else if gl.kind == 3 { gl.name } else { "dk_raw{id}_{sanitize(gl.name)}" }
  g.prog.globals.push(mir.Global { name, ty: d(gl.ty), init: none, constant: false, kind: gl.kind + 1 })
  let x = g.prog.globals.len() - 1
  g.raw_globals[id] = x
  let init = g.raw_const(gl.value, gl.ty)
  g.prog.globals[x].init = some(init)
  x
}

pub fn member_ty(g: var Gen, t: mir.MTy, s: mir.Sel): mir.MTy = mir.types.member_ty(g.info, t, s, g.prog.aggs)

/// Member `s` of an aggregate expression.
pub fn fld(g: var Gen, v: mir.Ex, s: mir.Sel): mir.Ex {
  let ty = g.member_ty(v.ty, s)
  v.field(s, ty)
}

/// A call to a generated function.
pub fn call(g: var Gen, f: int, args: [mir.Ex]): mir.Ex {
  let ret = g.func_ret(f)
  let ps = g.prog.funcs[f].vars
  var xs: [mir.Ex] = []
  for i, a in args {
    if i < ps.len() { xs.push(mir.retype(a, ps[i])) }
  }
  mir.call(f, xs, ret)
}

/// A call through a function reference with a known result type.
pub fn call_ref(g: var Gen, f: mir.FRef, args: [mir.Ex], ret: mir.MTy): mir.Ex = match f {
  Fn(f) => g.call(f, args)
  Rt(s) => mir.rt(s, args, ret)
}

// ---- names of instances ----

/// The function of an instance (requesting its emission).
pub fn inst_fn(g: var Gen, i: int): int {
  match g.inst_fns.get(i) {
    some(f) => return f
    none => {}
  }
  let what = match g.tp.instances[i].body {
    Fn(f) => sanitize(g.tp.fns[f].name)
    Test(_) => "test"
    Const(c) => "const_{sanitize(g.tp.consts[c].name)}"
  }
  var params: [mir.MTy] = []
  var ret = mir.MTy.Void
  var abi = mir.Abi.Auk
  match g.tp.instances[i].body {
    Test(_) => {
      ret = d(g.err_ty())
      abi = mir.Abi.C
    }
    _ => {
      for (t, var_) in g.inst_params(i) { params.push(if var_ { mir.ptr(d(t)) } else { d(t) }) }
      ret = d(g.inst_ret(i))
    }
  }
  // the runtime's dialect: an `export fn` is the C function of its name
  let export = match g.tp.instances[i].body {
    Fn(fid) => g.tp.fns[fid].export
    _ => 0
  }
  // a C function returning `()` or `never` returns `void`
  if export > 0 && (types.is_unit(g.inst_ret(i)) || g.inst_ret(i) == types.Ty.Never) { ret = mir.MTy.Void }
  let f = if export > 0 {
    g.declare(g.tp.fns[match g.tp.instances[i].body {
      Fn(fid) => fid
      _ => 0
    }].name, params, ret, mir.Abi.C)
  } else {
    g.declare("dk_f{i}_{what}", params, ret, abi)
  }
  if export > 0 { g.prog.exports[f] = export }
  g.inst_fns[i] = f
  match g.tp.instances[i].body {
    Fn(fid) => {
      let info = g.tp.fns[fid]
      let ps = g.inst_params(i).map(p => "{if p.1 { "var " } else { "" }}{types.show(g.tp.defs, p.0)}")
      let key = "{g.tp.program.mods[info.module].file}::{info.name}({ps.join(", ")}): {types.show(g.tp.defs, g.inst_ret(i))}"
      g.live_keys[f] = key
    }
    _ => {}
  }
  if !g.emitted.contains(i) { g.queue.push(i) }
  f
}

/// The return type of instance `i` (its function's return type, substituted).
pub fn inst_ret(g: var Gen, i: int): types.Ty {
  let inst = g.tp.instances[i]
  match inst.body {
    Fn(f) => types.subst(g.tp.fns[f].ret, typed.inst_subst(inst, g.tp.fns))
    Test(_) => types.res(types.unit(), g.err_ty())
    Const(c) => g.tp.consts[c].ty
  }
}

/// The parameter types of instance `i` (with `var` flags).
pub fn inst_params(g: var Gen, i: int): [(types.Ty, bool)] {
  let inst = g.tp.instances[i]
  match inst.body {
    Fn(f) => {
      let s = typed.inst_subst(inst, g.tp.fns)
      g.tp.fns[f].params.map(p => (types.subst(p.ty, s), p.var_))
    }
    _ => []
  }
}

// ---- constants ----

/// The getter of a constant (returns a borrowed value).
pub fn const_getter(g: var Gen, c: int): int {
  match g.consts.get(c) {
    some(f) => return f
    none => {}
  }
  let name = "dk_const{c}_{sanitize(g.tp.consts[c].name)}"
  let ty = g.tp.consts[c].ty
  let getter = g.declare(name, [], d(ty), mir.Abi.Auk)
  g.consts[c] = getter
  let gv = g.global("{name}_v", d(ty), none, false)
  match g.imprints.get(c) {
    some(v) => {
      // computed at compile time: rebuilt from its value at startup (no initializer runs)
      var b = mir.new_body()
      b.emit(mir.Stmt.Ret(g.global_ex(gv)))
      g.define(getter, b)
      let init = g.declare("{name}_init", [], mir.MTy.Void, mir.Abi.Auk)
      var b2 = mir.new_body()
      let e = g.imprint_value(ty, v, &b2)
      b2.set(g.global_ex(gv), e)
      g.define(init, b2)
      g.imprint_inits.push(init)
      return getter
    }
    none => {}
  }
  var inst = -1
  for k, x in g.tp.instances {
    if inst < 0 && x.body == typed.BodyRef.Const(c) { inst = k }
  }
  let initf = g.inst_fn(inst)
  let gs = g.global("{name}_s", mir.MTy.I32, none, false)
  let v = g.global_ex(gv)
  let s = g.global_ex(gs)
  var b = mir.new_body()
  // the imprint evaluator reports progress (to attribute a panic) and cycles
  if g.imprint_eval {
    b.open_if(mir.bin(mir.BOp.Eq, s, mir.int_as(1, mir.MTy.I32)))
    b.do_(mir.rt("auk__imprint_mark", [mir.int_as(67, mir.MTy.I32), mir.i64(c)], mir.MTy.Void))
    b.close()
  }
  b.open_if(mir.bin(mir.BOp.Eq, s, mir.int_as(0, mir.MTy.I32)))
  b.set(s, mir.int_as(1, mir.MTy.I32))
  if g.imprint_eval {
    b.do_(mir.rt("auk__imprint_mark", [mir.int_as(66, mir.MTy.I32), mir.i64(c)], mir.MTy.Void))
  }
  // computed outside any task's heap: the value outlives the task that computes it first
  let heap = b.decl(mir.rt("auk_heap_switch", [mir.zero(mir.void_ptr())], mir.void_ptr()))
  let call = g.call(initf, [])
  b.set(v, call)
  b.do_(mir.rt("auk_heap_switch", [heap], mir.void_ptr()))
  b.set(s, mir.int_as(2, mir.MTy.I32))
  if g.imprint_eval {
    b.do_(mir.rt("auk__imprint_mark", [mir.int_as(69, mir.MTy.I32), mir.i64(c)], mir.MTy.Void))
  }
  b.close()
  b.emit(mir.Stmt.Ret(v))
  g.define(getter, b)
  let free = g.declare("{name}_free", [], mir.MTy.Void, mir.Abi.Auk)
  var fb = mir.new_body()
  match g.release(ty, v) {
    some(r) => {
      fb.open_if(mir.bin(mir.BOp.Eq, s, mir.int_as(2, mir.MTy.I32)))
      fb.emit(r)
      fb.close()
    }
    none => {}
  }
  fb.set(s, mir.int_as(0, mir.MTy.I32))
  g.define(free, fb)
  g.const_order.push((getter, free))
  getter
}

/// An expression for the compile-time value `v` of type `t`, built (by statements appended
/// to `b`) from immortal objects: literal strings, and lists, maps and boxes made immortal.
fn imprint_value(g: var Gen, t: types.Ty, v: CVal, b: var mir.Body): mir.Ex {
  match t {
    Int => return match v {
      Int(n) => mir.int_(n)
      _ => mir.int_(0)
    }
    Float => return match v {
      Float(x) => mir.float_(x)
      Int(n) => mir.float_(float(n))
      _ => mir.float_(0.0)
    }
    Bool => return mir.bool_(v == CVal.Bool(true))
    Char => return match v {
      Str(s) => mir.int_as(if s.len() > 0 { int(s.chars()[0]) } else { 0 }, d(types.Ty.Char))
      _ => mir.int_as(0, d(types.Ty.Char))
    }
    Str => return match v {
      Str(s) => g.lit(s)
      _ => g.lit("")
    }
    _ => {}
  }
  if g.is_value(t) { return g.imprint_dvalue(v, &b) }
  match t {
    List(et) => {
      let xs = match v {
        List(xs) => xs
        _ => []
      }
      let ops = g.ops(et)
      let a = b.decl(mir.rt("auk_arr_new", [ops, mir.int_(xs.len())], d(t)))
      for x in xs {
        let e = g.imprint_value(et, x, &b)
        let tmp = b.decl_as(d(et), e)
        b.do_(mir.rt("auk_arr_push", [a.addr(), tmp.addr()], mir.MTy.Void))
      }
      b.do_(mir.rt("auk_make_immortal", [a], mir.MTy.Void))
      a
    }
    Map(kt, vt) => {
      let ko = g.ops(kt)
      let vo = g.ops(vt)
      let m = b.decl(mir.rt("auk_map_new", [ko, vo], d(t)))
      match v {
        Map(es) => for (k, x) in es {
          let kc = g.lit(k)
          let kv = b.decl(kc)
          let xc = g.imprint_value(vt, x, &b)
          let xv = b.decl_as(d(vt), xc)
          b.do_(mir.rt("auk_map_set", [m.addr(), kv.addr(), xv.addr()], mir.MTy.Void))
        }
        _ => {}
      }
      // immortal only once filled (setting into an immortal map would copy it)
      b.do_(mir.rt("auk_make_immortal", [m], mir.MTy.Void))
      m
    }
    Opt(inner) => match v {
      Null => mir.zero(d(t))
      _ => {
        let e = g.imprint_value(inner, v, &b)
        mir.agg(d(t), [(mir.Sel.F(0), mir.ex(mir.K.Int(1), mir.MTy.Bool)), (mir.Sel.F(1), mir.retype(e, d(inner)))])
      }
    }
    Named(dd, _) when types.is_struct(g.tp.defs, dd) => {
      let names = types.fields(g.tp.defs, dd).map(f => f.name)
      var parts: [(mir.Sel, mir.Ex)] = []
      for i, (ft, boxed) in mir.types.struct_layout(g.info, t) {
        let fv = cval_field(v, names[i]) else CVal.Null
        let e = g.imprint_value(ft, fv, &b)
        let e2 = if boxed { g.imprint_box(ft, e, &b) } else { e }
        parts.push((mir.Sel.F(i), e2))
      }
      mir.agg(d(t), parts)
    }
    Named(dd, _) when types.is_enum(g.tp.defs, dd) => {
      let vs = types.variants(g.tp.defs, dd)
      let tag = match v {
        Str(s) => some(s)
        _ => match cval_field(v, "tag") {
          some(Str(s)) => some(s)
          _ => none
        }
      }
      var vi = 0
      match tag {
        some(n) => for k, x in vs {
          if x.name == n {
            vi = k
            break
          }
        }
        none => {}
      }
      let layout = mir.types.enum_layout(g.info, t)
      var parts = [(mir.Sel.Tag, mir.int_as(vi, mir.MTy.I32))]
      for fi, (fname, _) in vs[vi].fields {
        let key = fname else "{fi}"
        let fv = cval_field(v, key) else CVal.Null
        let (ft, boxed) = layout[vi][fi]
        let e = g.imprint_value(ft, fv, &b)
        let e2 = if boxed { g.imprint_box(ft, e, &b) } else { e }
        parts.push((mir.Sel.V(vi, fi), e2))
      }
      mir.agg(d(t), parts)
    }
    _ => mir.zero(d(t))
  }
}

/// A core `Value` built from a compile-time value.
fn imprint_dvalue(g: var Gen, v: CVal, b: var mir.Body): mir.Ex {
  let vt = d(g.value_ty())
  match v {
    Null => mir.rt("auk_value_null", [], vt)
    Bool(x) => mir.rt("auk_value_bool", [mir.bool_(x)], vt)
    Int(n) => mir.rt("auk_value_int", [mir.int_(n)], vt)
    Float(x) => mir.rt("auk_value_float", [mir.float_(x)], vt)
    Str(s) => {
      let l = g.lit(s)
      mir.rt("auk_value_str", [l], vt)
    }
    List(xs) => {
      let lt = types.list(g.value_ty())
      let a = b.decl(mir.rt("auk_value_list_new", [], d(lt)))
      for x in xs {
        let e = g.imprint_dvalue(x, &b)
        let tmp = b.decl(e)
        b.do_(mir.rt("auk_arr_push", [a.addr(), tmp.addr()], mir.MTy.Void))
      }
      b.do_(mir.rt("auk_make_immortal", [a], mir.MTy.Void))
      mir.rt("auk_value_list", [a], vt)
    }
    Map(es) => {
      let mt = types.Ty.Map(types.Ty.Str, g.value_ty())
      let m = b.decl(mir.rt("auk_value_map_new", [], d(mt)))
      for (k, x) in es {
        let kc = g.lit(k)
        let kv = b.decl(kc)
        let xc = g.imprint_dvalue(x, &b)
        let xv = b.decl(xc)
        b.do_(mir.rt("auk_map_set", [m.addr(), kv.addr(), xv.addr()], mir.MTy.Void))
      }
      b.do_(mir.rt("auk_make_immortal", [m], mir.MTy.Void))
      mir.rt("auk_value_map", [m], vt)
    }
  }
}

/// A box holding the value `e` (of type `t`), made immortal.
fn imprint_box(g: var Gen, t: types.Ty, e: mir.Ex, b: var mir.Body): mir.Ex {
  let bx = g.box_new(t, e)
  let o = b.decl(bx)
  b.do_(mir.rt("auk_make_immortal", [o], mir.MTy.Void))
  o
}

/// The core `Value` type.
pub fn value_ty(g: var Gen): types.Ty = types.Ty.Named(g.info.value_def!, [])

// ---- string literals ----

/// The global holding an immortal `AukStr` for this text (a `str` value).
pub fn lit(g: var Gen, s: str): mir.Ex {
  match g.lits.get(s) {
    some(gl) => return g.global_ex(gl)
    none => {}
  }
  let gl = g.global("dk_lit{g.lit_order.len()}", ty_str(), none, false)
  g.lits[s] = gl
  g.lit_order.push((s, gl))
  g.global_ex(gl)
}

/// A small stable id for a typed error payload type.
pub fn type_id(g: var Gen, t: types.Ty): int {
  let n = g.type_ids.len() + 1
  match g.type_ids.get(t) {
    some(x) => x
    none => {
      g.type_ids[t] = n
      n
    }
  }
}

// ---- struct fields, boxes, variants ----

/// Field `i` of the struct value `v`, unboxed (a place when `v` is one).
pub fn field_get(g: var Gen, t: types.Ty, i: int, v: mir.Ex): mir.Ex {
  let (ft, boxed) = mir.types.struct_layout(g.info, t)[i]
  let raw = g.fld(v, mir.Sel.F(i))
  if boxed { g.unbox(ft, raw) } else { raw }
}

/// The raw member of field `i` (a `AukObj *` when boxed) and whether it is boxed.
pub fn field_raw(g: var Gen, t: types.Ty, i: int, v: mir.Ex): (mir.Ex, bool) {
  let boxed = mir.types.struct_layout(g.info, t)[i].1
  (g.fld(v, mir.Sel.F(i)), boxed)
}

/// The member value to store in field `i` from an owned value (boxing it if needed).
pub fn field_put(g: var Gen, t: types.Ty, i: int, owned: mir.Ex): mir.Ex {
  let (ft, boxed) = mir.types.struct_layout(g.info, t)[i]
  if boxed { g.box_new(ft, owned) } else { mir.retype(owned, d(ft)) }
}

/// The value inside a box cell (a place).
pub fn unbox(g: var Gen, t: types.Ty, raw: mir.Ex): mir.Ex {
  let bt = g.box_ty(t)
  raw.cast(mir.ptr(mir.MTy.Agg(bt))).deref(mir.MTy.Agg(bt)).field(mir.Sel.F(1), d(t))
}

/// The box cell type for a boxed value of type `t`: `{ AukObj o; T v; }`, and its drop.
pub fn box_ty(g: var Gen, t: types.Ty): int {
  match g.memo.get(("box", t)) {
    some(n) => return n
    none => {}
  }
  let k = g.fresh()
  let a = g.agg("DkBox{k}", [mir.MTy.Rt(mir.Rt.Obj), d(t)])
  g.memo[("box", t)] = a
  let drop = g.declare("DkBox{k}_drop", [mir.obj_ptr()], mir.MTy.Void, mir.Abi.C)
  g.memo[("boxdrop", t)] = drop
  let copy = g.declare("DkBox{k}_copy", [mir.obj_ptr()], mir.obj_ptr(), mir.Abi.C)
  g.memo[("boxcopy", t)] = copy
  let (b0, ps) = g.body_for(drop)
  var b = b0
  let v = ps[0].cast(mir.ptr(mir.MTy.Agg(a))).deref(mir.MTy.Agg(a)).field(mir.Sel.F(1), d(t))
  match g.release(t, v) {
    some(r) => b.emit(r)
    none => {}
  }
  g.define(drop, b)
  // the copy: a new box holding a deep copy of the value
  let (b1, ps1) = g.body_for(copy)
  var bc = b1
  let v1 = ps1[0].cast(mir.ptr(mir.MTy.Agg(a))).deref(mir.MTy.Agg(a)).field(mir.Sel.F(1), d(t))
  let c = g.copy_ex(t, v1)
  let nb = g.box_new(t, c)
  bc.emit(mir.Stmt.Ret(nb))
  g.define(copy, bc)
  a
}

/// An expression boxing an owned value `v` of type `t` (an owned `AukObj *`).
pub fn box_new(g: var Gen, t: types.Ty, v: mir.Ex): mir.Ex {
  let f = g.helper("boxnew", t, [d(t)], mir.obj_ptr(), (g, f) => {
    let bt = g.box_ty(t)
    let drop = g.memo[("boxdrop", t)]
    let copy = g.memo[("boxcopy", t)]
    let (b0, ps) = g.body_for(f)
    var b = b0
    let x = b.decl(
      mir.rt(
        "auk_obj_alloc",
        [mir.size_of(mir.MTy.Agg(bt)), mir.fn_addr(drop), mir.fn_addr(copy)],
        mir.ptr(mir.MTy.Agg(bt)),
      ),
    )
    b.set(x.deref(mir.MTy.Agg(bt)).field(mir.Sel.F(1), d(t)), ps[0])
    b.emit(mir.Stmt.Ret(x.cast(mir.obj_ptr())))
    b
  })
  g.call(f, [v])
}

/// `void f(AukObj **p)`: make the box `*p` (holding a `t`) uniquely owned before a write
/// through it, copying it when it is shared (or immortal): copy-on-write for boxed fields.
pub fn box_unique(g: var Gen, t: types.Ty): int = g.helper("boxuniq", t, [mir.ptr(mir.obj_ptr())], mir.MTy.Void, (g, f) => {
  let (b0, ps) = g.body_for(f)
  var b = b0
  let p = ps[0].deref(mir.obj_ptr())
  b.open_if(mir.bin(mir.BOp.Eq, mir.rt("auk_refcount", [p], mir.MTy.I64), mir.i64(1)))
  b.emit(mir.Stmt.Ret(none))
  b.close()
  let inner = g.unbox(t, p)
  let v = b.decl(inner)
  match g.retain(t, v) {
    some(r) => b.emit(r)
    none => {}
  }
  let mk = g.box_new(t, v)
  let n = b.decl(mk)
  b.do_(mir.rt("auk_release", [p], mir.MTy.Void))
  b.set(p, n)
  b
})

/// Field `fi` of variant `vi` of the enum value `v` (unboxed; a place when `v` is one).
pub fn variant_field(g: var Gen, t: types.Ty, vi: int, fi: int, v: mir.Ex): mir.Ex {
  let raw = g.fld(v, mir.Sel.V(vi, fi))
  if g.is_value(t) { return raw }
  let (ft, boxed) = mir.types.enum_layout(g.info, t)[vi][fi]
  if boxed { g.unbox(ft, raw) } else { raw }
}

/// Variant `vi` of enum `t` from owned field values.
pub fn variant_new(g: var Gen, t: types.Ty, vi: int, fields: [mir.Ex]): mir.Ex {
  let layout = mir.types.enum_layout(g.info, t)
  var parts = [(mir.Sel.Tag, mir.int_as(vi, mir.MTy.I32))]
  for fi, f in fields {
    let (ft, boxed) = layout[vi][fi]
    let v = if boxed { g.box_new(ft, f) } else { mir.retype(f, d(ft)) }
    parts.push((mir.Sel.V(vi, fi), v))
  }
  mir.agg(d(t), parts)
}

/// The tag test of variant `vi` for an enum value `v`.
pub fn variant_tag(g: var Gen, t: types.Ty, vi: int, v: mir.Ex): mir.Ex =
  mir.bin(mir.BOp.Eq, g.fld(v, mir.Sel.Tag), mir.int_as(vi, mir.MTy.I32))

/// A zero value of the type.
pub fn zero(g: var Gen, t: types.Ty): mir.Ex = mir.zero(d(t))

// ---- refcounting ----

/// A statement that retains the value `v` (none if the type holds no references).
pub fn retain(g: var Gen, t: types.Ty, v: mir.Ex): mir.Stmt? {
  if !g.needs_rc(t) || holds_no_refs(v) { return none }
  let ptr = (p: mir.Ex) => mir.Stmt.Do(mir.rt("auk_retain", [p], mir.void_ptr()))
  match t {
    Str | List(_) | Map(_, _) | Task(_) => return ptr(v)
    Fn(_, _) => return ptr(g.fld(v, mir.Sel.F(1)))
    Any(_) => return ptr(g.fld(v, mir.Sel.F(0)))
    _ => {}
  }
  if mir.types.is_opaque(g.info, t) { return ptr(v) }
  if g.is_value(t) { return mir.Stmt.Do(mir.rt("auk_value_retain", [v], mir.MTy.Void)) }
  let f = g.rc_fns(t).0
  mir.Stmt.Do(g.call(f, [v]))
}

/// A statement that releases the value `v` (none if the type holds no references).
pub fn release(g: var Gen, t: types.Ty, v: mir.Ex): mir.Stmt? {
  if !g.needs_rc(t) || holds_no_refs(v) { return none }
  let ptr = (p: mir.Ex) => mir.Stmt.Do(mir.rt("auk_release", [p], mir.MTy.Void))
  match t {
    Str | List(_) | Map(_, _) | Task(_) => return ptr(v)
    Fn(_, _) => return ptr(g.fld(v, mir.Sel.F(1)))
    Any(_) => return ptr(g.fld(v, mir.Sel.F(0)))
    _ => {}
  }
  if mir.types.is_opaque(g.info, t) { return ptr(v) }
  if g.is_value(t) { return mir.Stmt.Do(mir.rt("auk_value_release", [v], mir.MTy.Void)) }
  let f = g.rc_fns(t).1
  mir.Stmt.Do(g.call(f, [v]))
}

/// Rust's `both` in `rc_fns`: retain/release member `s` (of type `ty`) in the two bodies.
fn rc_both(g: var Gen, ty: types.Ty, s: mir.Sel, vi: mir.Ex, vd: mir.Ex, bi: var mir.Body, bd: var mir.Body) {
  let ei = g.fld(vi, s)
  let ed = g.fld(vd, s)
  match g.retain(ty, ei) {
    some(x) => bi.emit(x)
    none => {}
  }
  match g.release(ty, ed) {
    some(x) => bd.emit(x)
    none => {}
  }
}

/// Rust's `obj` in `rc_fns`: a boxed member.
fn rc_obj(g: var Gen, s: mir.Sel, vi: mir.Ex, vd: mir.Ex, bi: var mir.Body, bd: var mir.Body) {
  bi.do_(mir.rt("auk_retain", [g.fld(vi, s)], mir.void_ptr()))
  bd.do_(mir.rt("auk_release", [g.fld(vd, s)], mir.MTy.Void))
}

/// Generated retain/release functions for an aggregate type.
fn rc_fns(g: var Gen, t: types.Ty): (int, int) {
  match g.memo.get(("rc", t)) {
    some(n) => return (n, n + 1)
    none => {}
  }
  let k = g.fresh()
  let inc = g.declare("dk_rc{k}_retain", [d(t)], mir.MTy.Void, mir.Abi.Auk)
  let dec = g.declare("dk_rc{k}_release", [d(t)], mir.MTy.Void, mir.Abi.Auk)
  g.memo[("rc", t)] = inc
  let (bi0, pi) = g.body_for(inc)
  let (bd0, pd) = g.body_for(dec)
  var bi = bi0
  var bd = bd0
  let vi = pi[0]
  let vd = pd[0]
  match t {
    Tuple(ts) => for i, x in ts { rc_both(&g, x, mir.Sel.F(i), vi, vd, &bi, &bd) }
    Opt(x) => {
      bi.open_if(g.fld(vi, mir.Sel.F(0)))
      bd.open_if(g.fld(vd, mir.Sel.F(0)))
      rc_both(&g, x, mir.Sel.F(1), vi, vd, &bi, &bd)
      bi.close()
      bd.close()
    }
    Res(x, _) => {
      bi.open_if(g.fld(vi, mir.Sel.F(0)))
      bd.open_if(g.fld(vd, mir.Sel.F(0)))
      rc_both(&g, x, mir.Sel.F(1), vi, vd, &bi, &bd)
      bi.else_()
      bd.else_()
      rc_obj(&g, mir.Sel.F(2), vi, vd, &bi, &bd)
      bi.close()
      bd.close()
    }
    Named(dd, _) when types.is_struct(g.tp.defs, dd) => {
      for i, (ft, boxed) in mir.types.struct_layout(g.info, t) {
        if boxed {
          rc_obj(&g, mir.Sel.F(i), vi, vd, &bi, &bd)
        } else {
          rc_both(&g, ft, mir.Sel.F(i), vi, vd, &bi, &bd)
        }
      }
    }
    Named(_, _) => {
      let layout = mir.types.enum_layout(g.info, t)
      for vix, fs in layout {
        var any = false
        for (ft, boxed) in fs {
          if !any && (boxed || g.needs_rc(ft)) { any = true }
        }
        if !any { continue }
        bi.open_if(g.variant_tag(t, vix, vi))
        bd.open_if(g.variant_tag(t, vix, vd))
        for fi, (ft, boxed) in fs {
          let s = mir.Sel.V(vix, fi)
          if boxed {
            rc_obj(&g, s, vi, vd, &bi, &bd)
          } else {
            rc_both(&g, ft, s, vi, vd, &bi, &bd)
          }
        }
        bi.close()
        bd.close()
      }
    }
    _ => {}
  }
  g.define(inc, bi)
  g.define(dec, bd)
  (inc, dec)
}

/// Can a value of type `t` hold a closure (or an `any` value, which might)?
pub fn holds_fn(g: var Gen, t: types.Ty): bool {
  var seen: [int] = []
  holds_fn_go(&g, t, &seen)
}

fn holds_fn_go(g: var Gen, t: types.Ty, seen: var [int]): bool {
  match t {
    Fn(_, _) | Any(_) | Param(_) | Var(_) => true
    Named(dd, args) => {
      for a in args {
        if holds_fn_go(&g, a, &seen) { return true }
      }
      if seen.contains(dd) { return false }
      seen.push(dd)
      match g.tp.defs.types[dd].kind {
        Struct(fields) => {
          for f in fields {
            if holds_fn_go(&g, f.ty, &seen) { return true }
          }
          false
        }
        Enum(variants) => {
          for v in variants {
            for (_, ft) in v.fields {
              if holds_fn_go(&g, ft, &seen) { return true }
            }
          }
          false
        }
        Opaque(_) => false
      }
    }
    _ => {
      for c in types.children(t) {
        if holds_fn_go(&g, c, &seen) { return true }
      }
      false
    }
  }
}

// ---- deep copies (values crossing a task boundary: runtime/c/heap.c) ----

/// An owned deep copy of the value `v` of type `t`, allocated in the current heap. Handles
/// (tasks, connections, listeners, channels) are shared instead.
pub fn copy_ex(g: var Gen, t: types.Ty, v: mir.Ex): mir.Ex {
  if !g.needs_rc(t) { return v }
  match t {
    Str => return mir.rt("auk_str_copy", [v], d(t))
    List(_) => return mir.rt("auk_arr_copy_deep", [v], d(t))
    Map(_, _) => return mir.rt("auk_map_copy_deep", [v], d(t))
    Task(_) => return mir.rt("auk_retain", [v], d(t))
    _ => {}
  }
  if mir.types.is_opaque(g.info, t) && !g.is_err_ty(t) { return mir.rt("auk_retain", [v], d(t)) }
  if g.is_value(t) { return mir.rt("auk_value_copy", [v], d(t)) }
  if g.is_err_ty(t) { return mir.rt("auk_err_copy_deep", [v], d(t)) }
  let f = g.copy_fn(t)
  g.call(f, [v])
}

/// Rust's `obj` in `copy_fn`.
fn copy_obj(g: var Gen, b: var mir.Body, src: mir.Ex, r: mir.Ex, s: mir.Sel) {
  let c = mir.rt("auk_obj_copy", [g.fld(src, s)], mir.obj_ptr())
  b.set(g.fld(r, s), c)
}

/// Rust's `field` in `copy_fn`.
fn copy_field(g: var Gen, b: var mir.Body, src: mir.Ex, r: mir.Ex, ty: types.Ty, s: mir.Sel) {
  if g.needs_rc(ty) {
    let c = g.copy_ex(ty, g.fld(src, s))
    b.set(g.fld(r, s), c)
  }
}

/// `T f(T)`: a deep copy of an aggregate (closure, `any`, tuple, optional, result, struct,
/// enum).
fn copy_fn(g: var Gen, t: types.Ty): int = g.helper("copy", t, [d(t)], d(t), (g, f) => {
  let (b0, ps) = g.body_for(f)
  var b = b0
  let src = ps[0]
  let r = b.decl(src)
  match t {
    Fn(_, _) => copy_obj(&g, &b, src, r, mir.Sel.F(1))
    Any(_) => copy_obj(&g, &b, src, r, mir.Sel.F(0))
    Tuple(ts) => for i, x in ts { copy_field(&g, &b, src, r, x, mir.Sel.F(i)) }
    Opt(x) => {
      b.open_if(g.fld(src, mir.Sel.F(0)))
      copy_field(&g, &b, src, r, x, mir.Sel.F(1))
      b.close()
    }
    Res(x, _) => {
      b.open_if(g.fld(src, mir.Sel.F(0)))
      copy_field(&g, &b, src, r, x, mir.Sel.F(1))
      b.else_()
      let c = mir.rt("auk_err_copy_deep", [g.fld(src, mir.Sel.F(2))], mir.void_ptr())
      b.set(g.fld(r, mir.Sel.F(2)), c)
      b.close()
    }
    Named(dd, _) when types.is_struct(g.tp.defs, dd) => {
      for i, (ft, boxed) in mir.types.struct_layout(g.info, t) {
        if boxed {
          copy_obj(&g, &b, src, r, mir.Sel.F(i))
        } else {
          copy_field(&g, &b, src, r, ft, mir.Sel.F(i))
        }
      }
    }
    Named(_, _) => {
      let layout = mir.types.enum_layout(g.info, t)
      for vi, fs in layout {
        var any = false
        for (ft, boxed) in fs {
          if !any && (boxed || g.needs_rc(ft)) { any = true }
        }
        if !any { continue }
        b.open_if(g.variant_tag(t, vi, src))
        for fi, (ft, boxed) in fs {
          let s = mir.Sel.V(vi, fi)
          if boxed {
            copy_obj(&g, &b, src, r, s)
          } else {
            copy_field(&g, &b, src, r, ft, s)
          }
        }
        b.close()
      }
    }
    _ => {}
  }
  b.emit(mir.Stmt.Ret(r))
  b
})

// ---- memoized helper functions ----

/// A generated helper function for (kind, type), created once: declared with `params` and
/// `ret`, then `make(gen, f)` builds its body.
pub fn helper(g: var Gen, kind: str, t: types.Ty, params: [mir.MTy], ret: mir.MTy, make: (var Gen, int) => mir.Body): int =
  g.helper_abi(kind, t, params, ret, mir.Abi.Auk, make)

pub fn helper_abi(
  g: var Gen,
  kind: str,
  t: types.Ty,
  params: [mir.MTy],
  ret: mir.MTy,
  abi: mir.Abi,
  make: (var Gen, int) => mir.Body,
): int {
  match g.memo.get((kind, t)) {
    some(f) => return f
    none => {}
  }
  let k = g.fresh()
  let f = g.declare("dk_{kind}{k}", params, ret, abi)
  g.memo[(kind, t)] = f
  let b = make(&g, f)
  g.define(f, b)
  f
}

/// The user (or core) implementation of a built-in shape for `t`, when it is a function.
pub fn user_impl(g: var Gen, b: types.Builtin, t: types.Ty): mir.FRef? {
  if b == types.Builtin.Data && g.imprint_eval { return none }
  match g.tp.shape_impls.get((b, t)) {
    some(Instance(i)) => some(mir.FRef.Fn(g.inst_fn(i)))
    some(Extern(symbol, _)) => some(mir.FRef.Rt(symbol))
    _ => none
  }
}

// ---- element ops ----

fn elem_of(p: mir.Ex, t: types.Ty): mir.Ex = p.cast(mir.ptr(d(t))).deref(d(t))

fn rt_ops(s: str): mir.Ex = mir.rt_global(s, mir.MTy.Rt(mir.Rt.ElemOps))

/// A pointer to the element ops of a container element type.
pub fn ops(g: var Gen, t: types.Ty): mir.Ex {
  match t {
    Int => return rt_ops("auk_ops_int")
    Float => return rt_ops("auk_ops_float")
    Bool => return rt_ops("auk_ops_bool")
    Char => return rt_ops("auk_ops_char")
    Str => if g.user_impl(types.Builtin.Show, t) == none { return rt_ops("auk_ops_str") }
    Never => return rt_ops("auk_ops_unit")
    Tuple(ts) => if ts.len() == 0 { return rt_ops("auk_ops_unit") }
    Task(_) => return rt_ops("auk_ops_task")
    Fn(_, _) => return rt_ops("auk_ops_closure")
    _ => {}
  }
  if !(t is types.Ty.Str) && !(t is types.Ty.Tuple(_)) {
    if g.is_value(t) { return rt_ops("auk_ops_value") }
    if g.is_err_ty(t) { return rt_ops("auk_ops_err") }
  }
  match g.memo.get(("ops", t)) {
    some(gl) => return mir.ex(mir.K.GlobalAddr(gl), mir.ptr(mir.MTy.Rt(mir.Rt.ElemOps)))
    none => {}
  }
  let k = g.fresh()
  let name = "dk_ops{k}"
  let gl = g.global(name, mir.MTy.Rt(mir.Rt.ElemOps), none, true)
  g.memo[("ops", t)] = gl
  let cv = mir.void_ptr()
  var ret = mir.zero(mir.MTy.Code)
  var rel = mir.zero(mir.MTy.Code)
  if g.needs_rc(t) {
    let rn = g.declare("{name}_retain", [cv], mir.MTy.Void, mir.Abi.C)
    let ln = g.declare("{name}_release", [cv], mir.MTy.Void, mir.Abi.C)
    for (f, inc) in [(rn, true), (ln, false)] {
      let (b0, ps) = g.body_for(f)
      var b = b0
      let s = if inc { g.retain(t, elem_of(ps[0], t)) } else { g.release(t, elem_of(ps[0], t)) }
      b.emit(s!)
      g.define(f, b)
    }
    ret = mir.fn_addr(rn)
    rel = mir.fn_addr(ln)
  }
  var eq = mir.zero(mir.MTy.Code)
  match g.eq_fn(t) {
    some(f) => {
      let n = g.declare("{name}_eq", [cv, cv], mir.MTy.Bool, mir.Abi.C)
      let (b0, ps) = g.body_for(n)
      var b = b0
      let c = g.call_ref(f, [elem_of(ps[0], t), elem_of(ps[1], t)], d(types.Ty.Bool))
      b.emit(mir.Stmt.Ret(c.cast(mir.MTy.Bool)))
      g.define(n, b)
      eq = mir.fn_addr(n)
    }
    none => {}
  }
  var cmp = mir.zero(mir.MTy.Code)
  match g.cmp_fn(t) {
    some(f) => {
      let n = g.declare("{name}_cmp", [cv, cv], mir.MTy.I32, mir.Abi.C)
      let (b0, ps) = g.body_for(n)
      var b = b0
      let r = b.decl(g.call_ref(f, [elem_of(ps[0], t), elem_of(ps[1], t)], d(types.Ty.Int)))
      let gt = mir.bin(mir.BOp.Gt, r, mir.int_(0)).cast(mir.MTy.I32)
      let lt = mir.bin(mir.BOp.Lt, r, mir.int_(0)).cast(mir.MTy.I32)
      b.emit(mir.Stmt.Ret(mir.bin(mir.BOp.Sub, gt, lt)))
      g.define(n, b)
      cmp = mir.fn_addr(n)
    }
    none => {}
  }
  var hash = mir.zero(mir.MTy.Code)
  match g.hash_fn(t) {
    some(f) => {
      let n = g.declare("{name}_hash", [cv], mir.MTy.U64, mir.Abi.C)
      let (b0, ps) = g.body_for(n)
      var b = b0
      b.emit(mir.Stmt.Ret(g.call_ref(f, [elem_of(ps[0], t)], mir.MTy.U64)))
      g.define(n, b)
      hash = mir.fn_addr(n)
    }
    none => {}
  }
  var show = mir.zero(mir.MTy.Code)
  match g.dshow_fn(t) {
    some(f) => {
      let n = g.declare("{name}_show", [cv], ty_str(), mir.Abi.C)
      let (b0, ps) = g.body_for(n)
      var b = b0
      b.emit(mir.Stmt.Ret(g.call_ref(f, [elem_of(ps[0], t)], ty_str())))
      g.define(n, b)
      show = mir.fn_addr(n)
    }
    none => {}
  }
  var copy = mir.zero(mir.MTy.Code)
  if g.needs_rc(t) {
    let n = g.declare("{name}_copy", [cv, cv], mir.MTy.Void, mir.Abi.C)
    let (b0, ps) = g.body_for(n)
    var b = b0
    let c = g.copy_ex(t, elem_of(ps[0], t))
    b.set(elem_of(ps[1], t), c)
    g.define(n, b)
    copy = mir.fn_addr(n)
  }
  let init = mir.agg(
    mir.MTy.Rt(mir.Rt.ElemOps),
    [
      (mir.Sel.F(0), mir.size_of(d(t))),
      (mir.Sel.F(1), ret),
      (mir.Sel.F(2), rel),
      (mir.Sel.F(3), eq),
      (mir.Sel.F(4), cmp),
      (mir.Sel.F(5), hash),
      (mir.Sel.F(6), show),
      (mir.Sel.F(7), copy),
    ],
  )
  g.prog.globals[gl].init = some(init)
  mir.ex(mir.K.GlobalAddr(gl), mir.ptr(mir.MTy.Rt(mir.Rt.ElemOps)))
}

// ---- Show ----

/// `AukStr *f(T)`: the top-level `Show` text of a value (owned result). none for types
/// without `Show`.
pub fn show_fn(g: var Gen, t: types.Ty): mir.FRef? {
  match g.user_impl(types.Builtin.Show, t) {
    some(f) => return f
    none => {}
  }
  let rt = (s: str) => some(mir.FRef.Rt(s))
  match t {
    Int => return rt("auk_str_from_int")
    Float => return rt("auk_str_from_float")
    Bool => return rt("auk_str_from_bool")
    Char => return rt("auk_str_from_char")
    Str => return some(
      mir.FRef.Fn(
        g.helper("showstr", t, [d(t)], d(t), (g, f) => {
          let (b0, ps) = g.body_for(f)
          var b = b0
          b.emit(mir.Stmt.Ret(mir.rt("auk_retain", [ps[0]], ty_str())))
          b
        }),
      ),
    )
    _ => {}
  }
  if g.is_value(t) { return rt("auk_value_show") }
  if g.is_err_ty(t) { return rt("auk_err_show") }
  match t {
    Fn(_, _) | Task(_) => return none
    _ => {}
  }
  if mir.types.is_foreign(g.info, t) { return rt("auk_ffi_ptr_show") }
  if mir.types.is_opaque(g.info, t) { return none }
  some(mir.FRef.Fn(g.helper("show", t, [d(t)], ty_str(), (g, f) => g.derive_show(t, f))))
}

/// The "debug" show used inside containers and derived shows: strings and chars quoted.
pub fn dshow_fn(g: var Gen, t: types.Ty): mir.FRef? = match t {
  Str when g.user_impl(types.Builtin.Show, t) == none => some(mir.FRef.Rt("auk_str_quote"))
  Char when g.user_impl(types.Builtin.Show, t) == none => some(mir.FRef.Rt("auk_char_quote"))
  _ => g.show_fn(t)
}

/// Push a static text onto a string builder.
pub fn sb_lit(g: var Gen, b: var mir.Body, sb: mir.Ex, s: str) {
  b.do_(mir.rt("auk_sb_bytes", [sb.addr(), mir.cstr(s), mir.int_(s.byte_len())], mir.MTy.Void))
}

/// Rust's `field` in `derive_show`: the debug show of a member.
fn show_field(g: var Gen, b: var mir.Body, sb: mir.Ex, ft: types.Ty, e: mir.Ex) {
  match g.dshow_fn(ft) {
    some(f) => {
      let s = g.call_ref(f, [e], ty_str())
      b.do_(mir.rt("auk_sb_str_own", [sb.addr(), s], mir.MTy.Void))
    }
    none => {
      let text = "<{g.show_ty(ft).replace("\"", "")}>"
      g.sb_lit(&b, sb, text)
    }
  }
}

fn derive_show(g: var Gen, t: types.Ty, f: int): mir.Body {
  let (b0, ps) = g.body_for(f)
  var b = b0
  let v = ps[0]
  match t {
    List(_) => {
      b.emit(mir.Stmt.Ret(mir.rt("auk_arr_show", [v], ty_str())))
      return b
    }
    Map(_, _) => {
      b.emit(mir.Stmt.Ret(mir.rt("auk_map_show", [v], ty_str())))
      return b
    }
    _ => {}
  }
  let sb = b.decl(mir.zero(mir.MTy.Rt(mir.Rt.StrBuf)))
  match t {
    Never => g.sb_lit(&b, sb, "()")
    Tuple(ts) => {
      g.sb_lit(&b, sb, "(")
      for i, x in ts {
        if i > 0 { g.sb_lit(&b, sb, ", ") }
        let e = g.fld(v, mir.Sel.F(i))
        show_field(&g, &b, sb, x, e)
      }
      g.sb_lit(&b, sb, ")")
    }
    Opt(x) => {
      b.open_if(g.fld(v, mir.Sel.F(0)).not())
      g.sb_lit(&b, sb, "none")
      b.else_()
      g.sb_lit(&b, sb, "some(")
      let e = g.fld(v, mir.Sel.F(1))
      show_field(&g, &b, sb, x, e)
      g.sb_lit(&b, sb, ")")
      b.close()
    }
    Res(x, _) => {
      b.open_if(g.fld(v, mir.Sel.F(0)).not())
      g.sb_lit(&b, sb, "err(")
      let es = mir.rt("auk_err_show", [g.fld(v, mir.Sel.F(2))], ty_str())
      b.do_(mir.rt("auk_sb_str_own", [sb.addr(), es], mir.MTy.Void))
      g.sb_lit(&b, sb, ")")
      b.else_()
      g.sb_lit(&b, sb, "ok(")
      let e = g.fld(v, mir.Sel.F(1))
      show_field(&g, &b, sb, x, e)
      g.sb_lit(&b, sb, ")")
      b.close()
    }
    Any(s) => {
      let sd = g.tp.defs.shapes[s]
      if sd.builtin == some(types.Builtin.Show) {
        let vt = g.vt_struct(s)
        let m0 = g.fld(v, mir.Sel.F(1)).cast(mir.ptr(mir.MTy.Agg(vt))).deref(mir.MTy.Agg(vt)).field(mir.Sel.F(0), mir.MTy.Code)
        let call = mir.ex(mir.K.Call(mir.Callee.Indirect(m0, [mir.obj_ptr()]), [g.fld(v, mir.Sel.F(0))]), ty_str())
        b.do_(mir.rt("auk_sb_str_own", [sb.addr(), call], mir.MTy.Void))
      } else {
        g.sb_lit(&b, sb, "<any {sd.name}>")
      }
    }
    Named(dd, args) when types.is_struct(g.tp.defs, dd) => {
      let s = types.subst_of(g.tp.defs, dd, args)
      let def = g.tp.defs.types[dd]
      let fields = types.fields(g.tp.defs, dd)
      if fields.len() == 0 {
        g.sb_lit(&b, sb, "{def.name} {{}}")
      } else {
        for i, fd in fields {
          let sep = if i == 0 { "{def.name} {{ " } else { ", " }
          g.sb_lit(&b, sb, "{sep}{fd.name}: ")
          let e = g.field_get(t, i, v)
          show_field(&g, &b, sb, types.subst(fd.ty, s), e)
        }
        g.sb_lit(&b, sb, " }}")
      }
    }
    Named(dd, _) => {
      let vs = types.variants(g.tp.defs, dd)
      let layout = mir.types.enum_layout(g.info, t)
      for vi, var_ in vs {
        b.open_if(g.variant_tag(t, vi, v))
        g.sb_lit(&b, sb, var_.name)
        if var_.fields.len() > 0 {
          g.sb_lit(&b, sb, "(")
          for fi, (ft, _) in layout[vi] {
            if fi > 0 { g.sb_lit(&b, sb, ", ") }
            let e = g.variant_field(t, vi, fi, v)
            show_field(&g, &b, sb, ft, e)
          }
          g.sb_lit(&b, sb, ")")
        }
        b.close()
      }
    }
    _ => {
      let text = "<{g.show_ty(t).replace("\"", "")}>"
      g.sb_lit(&b, sb, text)
    }
  }
  b.emit(mir.Stmt.Ret(mir.rt("auk_sb_finish", [sb.addr()], ty_str())))
  b
}

/// Rust's `kid` in `dbg_kids_fn`: report one part to the runtime.
fn kid(g: var Gen, b: var mir.Body, ctx: mir.Ex, name: str, ty: types.Ty, e: mir.Ex) {
  let tid = type_id(&g.dbg_info, ty)
  let tmp = b.decl_as(d(ty), e)
  b.do_(
    mir.rt(
      "auk_dbg_kid",
      [ctx, mir.cstr(name), mir.int_as(tid, mir.MTy.I64), tmp.addr().cast(mir.void_ptr())],
      mir.MTy.Void,
    ),
  )
}

/// The debugger's children function of type `t` (type index `idx`): `void f(void *value,
/// void *ctx)` reports each part of the value to the runtime (`auk_dbg_kid`, runtime/c/dbg.c)
/// with its type index and address. none for a type without parts.
pub fn dbg_kids_fn(g: var Gen, t: types.Ty, idx: int): int? {
  let has_parts = match t {
    Tuple(ts) => ts.len() > 0
    Opt(_) | Res(_, _) | List(_) | Map(_, _) => true
    Named(dd, _) when types.is_struct(g.tp.defs, dd) => types.fields(g.tp.defs, dd).len() > 0
    Named(dd, _) => types.variants(g.tp.defs, dd).any(v => v.fields.len() > 0)
    _ => false
  }
  if !has_parts { return none }
  let cv = mir.void_ptr()
  let f = g.declare("dk_dbgkids{idx}", [cv, cv], mir.MTy.Void, mir.Abi.C)
  let (b0, ps) = g.body_for(f)
  var b = b0
  let v = b.decl(ps[0].cast(mir.ptr(d(t))).deref(d(t)))
  let ctx = ps[1]
  match t {
    Tuple(ts) => for i, x in ts {
      let e = g.fld(v, mir.Sel.F(i))
      kid(&g, &b, ctx, "{i}", x, e)
    }
    Opt(x) | Res(x, _) => {
      b.open_if(g.fld(v, mir.Sel.F(0)))
      let e = g.fld(v, mir.Sel.F(1))
      kid(&g, &b, ctx, if t is types.Ty.Opt(_) { "some" } else { "ok" }, x, e)
      b.close()
    }
    List(x) => {
      let tid = type_id(&g.dbg_info, x)
      let size = mir.size_of(d(x)).cast(mir.MTy.I64)
      b.do_(mir.rt("auk_dbg_kid_arr", [ctx, v.cast(cv), mir.int_as(tid, mir.MTy.I64), size], mir.MTy.Void))
    }
    Map(_, x) => {
      let tid = type_id(&g.dbg_info, x)
      b.do_(mir.rt("auk_dbg_kid_map", [ctx, v.cast(cv), mir.int_as(tid, mir.MTy.I64)], mir.MTy.Void))
    }
    Named(dd, args) when types.is_struct(g.tp.defs, dd) => {
      let s = types.subst_of(g.tp.defs, dd, args)
      for i, fd in types.fields(g.tp.defs, dd) {
        let e = g.field_get(t, i, v)
        kid(&g, &b, ctx, fd.name, types.subst(fd.ty, s), e)
      }
    }
    Named(dd, _) => {
      let vs = types.variants(g.tp.defs, dd)
      let layout = mir.types.enum_layout(g.info, t)
      for vi, var_ in vs {
        if var_.fields.len() == 0 { continue }
        b.open_if(g.variant_tag(t, vi, v))
        for fi, (ft, _) in layout[vi] {
          let name = match var_.fields.get(fi) {
            some((some(n), _)) => n
            _ => "{fi}"
          }
          let e = g.variant_field(t, vi, fi, v)
          kid(&g, &b, ctx, name, ft, e)
        }
        b.close()
      }
    }
    _ => { let _: int = mir.bug("dbg_kids_fn") }
  }
  b.emit(mir.Stmt.Ret(none))
  g.define(f, b)
  some(f)
}

// ---- Eq / Ord / hash ----

/// `bool f(T a, T b)`, or none when the type has no equality.
pub fn eq_fn(g: var Gen, t: types.Ty): mir.FRef? {
  match g.user_impl(types.Builtin.Eq, t) {
    some(f) => return f
    none => {}
  }
  match t {
    Fn(_, _) | Task(_) => return none
    _ => {}
  }
  if mir.types.is_foreign(g.info, t) {
    return some(
      mir.FRef.Fn(
        g.helper("eq", t, [d(t), d(t)], d(types.Ty.Bool), (g, f) => {
          let (b0, ps) = g.body_for(f)
          var b = b0
          b.emit(mir.Stmt.Ret(mir.bin(mir.BOp.Eq, ps[0], ps[1])))
          b
        }),
      ),
    )
  }
  if mir.types.is_opaque(g.info, t) && !g.is_err_ty(t) { return none }
  if g.is_value(t) { return some(mir.FRef.Rt("auk_value_eq")) }
  match t {
    Str => return some(mir.FRef.Rt("auk_str_eq"))
    List(_) => return some(mir.FRef.Rt("auk_arr_eq"))
    Map(_, _) => return some(mir.FRef.Rt("auk_map_eq"))
    _ => {}
  }
  var seen: {types.Ty: bool} = {}
  if !g.can(t, types.Builtin.Eq, &seen) { return none }
  some(mir.FRef.Fn(g.helper("eq", t, [d(t), d(t)], d(types.Ty.Bool), (g, f) => g.derive_eq(t, f))))
}

/// Can the derived instance of `b` (Eq, Ord, hash) be built for `t`?
fn can(g: var Gen, t: types.Ty, b: types.Builtin, seen: var {types.Ty: bool}): bool {
  match g.tp.shape_impls.get((b, t)) {
    some(Instance(_)) => return true
    _ => {}
  }
  if seen.contains(t) { return true }
  seen[t] = true
  match t {
    Int | Float | Bool | Char | Str | Never => true
    Fn(_, _) | Task(_) | Any(_) => false
    Tuple(ts) => {
      for x in ts {
        if !g.can(x, b, &seen) { return false }
      }
      true
    }
    List(x) | Opt(x) => g.can(x, b, &seen)
    Map(k, v) => b != types.Builtin.Ord && g.can(k, b, &seen) && g.can(v, b, &seen)
    Res(x, _) => b == types.Builtin.Eq && g.can(x, b, &seen)
    Named(dd, args) => {
      if some(dd) == g.info.value_def { return b != types.Builtin.Ord }
      let s = types.subst_of(g.tp.defs, dd, args)
      match g.tp.defs.types[dd].kind {
        Opaque(_) => b == types.Builtin.Eq && (g.is_err_ty(t) || mir.types.is_foreign(g.info, t))
        Struct(fields) => {
          for f in fields {
            if !g.can(types.subst(f.ty, s), b, &seen) { return false }
          }
          true
        }
        Enum(variants) => {
          for v in variants {
            for (_, ft) in v.fields {
              if !g.can(types.subst(ft, s), b, &seen) { return false }
            }
          }
          true
        }
      }
    }
    _ => false
  }
}

/// The tag of an enum value expression (Rust's `tag` in `eq_expr`).
fn tag_of(g: var Gen, x: mir.Ex): mir.Ex = match x.k {
  Agg(parts) => {
    for (s, e) in parts {
      if s == mir.Sel.Tag { return e }
    }
    mir.int_as(0, mir.MTy.I32)
  }
  _ => g.fld(x, mir.Sel.Tag)
}

/// Equality of two values of type `t` (a bool expression).
pub fn eq_expr(g: var Gen, t: types.Ty, a: mir.Ex, b: mir.Ex): mir.Ex {
  // against a variant without fields (`tok == Tok.LParen`): the tags decide
  match t {
    Named(dd, _) => if types.is_enum(g.tp.defs, dd) && !g.is_value(t) &&
      (holds_no_refs(a) && !(a.k is mir.K.Zero) || holds_no_refs(b) && !(b.k is mir.K.Zero)) {
      return mir.bin(mir.BOp.Eq, g.tag_of(a), g.tag_of(b))
    }
    _ => {}
  }
  match t {
    Int | Float | Bool | Char => mir.bin(mir.BOp.Eq, a, b)
    Never => mir.bool_(true)
    Tuple(ts) when ts.len() == 0 => mir.bool_(true)
    _ => match g.eq_fn(t) {
      some(f) => g.call_ref(f, [a, b], d(types.Ty.Bool))
      none => mir.bool_(false)
    }
  }
}

/// Rust's `fail` in `derive_eq`: return false unless `c`.
fn fail_unless(b: var mir.Body, c: mir.Ex) {
  b.open_if(c.not())
  b.emit(mir.Stmt.Ret(mir.bool_(false)))
  b.close()
}

fn derive_eq(g: var Gen, t: types.Ty, f: int): mir.Body {
  let (b0, ps) = g.body_for(f)
  var b = b0
  let x = ps[0]
  let y = ps[1]
  match t {
    Tuple(ts) => {
      for i, et in ts {
        let s = mir.Sel.F(i)
        let e = g.eq_expr(et, g.fld(x, s), g.fld(y, s))
        fail_unless(&b, e)
      }
      b.emit(mir.Stmt.Ret(mir.bool_(true)))
      return b
    }
    Opt(et) => {
      let sa = g.fld(x, mir.Sel.F(0))
      let sb = g.fld(y, mir.Sel.F(0))
      fail_unless(&b, mir.bin(mir.BOp.Eq, sa, sb))
      b.open_if(sa.not())
      b.emit(mir.Stmt.Ret(mir.bool_(true)))
      b.close()
      let e = g.eq_expr(et, g.fld(x, mir.Sel.F(1)), g.fld(y, mir.Sel.F(1)))
      b.emit(mir.Stmt.Ret(e))
      return b
    }
    Res(et, _) => {
      let oa = g.fld(x, mir.Sel.F(0))
      let ob = g.fld(y, mir.Sel.F(0))
      fail_unless(&b, mir.bin(mir.BOp.Eq, oa, ob))
      b.open_if(oa)
      let e = g.eq_expr(et, g.fld(x, mir.Sel.F(1)), g.fld(y, mir.Sel.F(1)))
      b.emit(mir.Stmt.Ret(e))
      b.close()
      let ma = g.fld(x, mir.Sel.F(2)).rt_field(mir.RtF.ErrMsg)
      let mb = g.fld(y, mir.Sel.F(2)).rt_field(mir.RtF.ErrMsg)
      b.emit(mir.Stmt.Ret(mir.rt("auk_str_eq", [ma, mb], d(types.Ty.Bool))))
      return b
    }
    _ => {}
  }
  if g.is_err_ty(t) {
    let same = mir.bin(mir.BOp.Eq, x, y)
    let msg = mir.rt("auk_str_eq", [x.rt_field(mir.RtF.ErrMsg), y.rt_field(mir.RtF.ErrMsg)], d(types.Ty.Bool))
    b.emit(mir.Stmt.Ret(mir.cond(same, mir.bool_(true), msg)))
    return b
  }
  match t {
    Named(dd, args) when types.is_struct(g.tp.defs, dd) => {
      let s = types.subst_of(g.tp.defs, dd, args)
      for i, fd in types.fields(g.tp.defs, dd) {
        let fa = g.field_get(t, i, x)
        let fb = g.field_get(t, i, y)
        let e = g.eq_expr(types.subst(fd.ty, s), fa, fb)
        fail_unless(&b, e)
      }
      b.emit(mir.Stmt.Ret(mir.bool_(true)))
    }
    Named(_, _) => {
      let layout = mir.types.enum_layout(g.info, t)
      fail_unless(&b, mir.bin(mir.BOp.Eq, g.fld(x, mir.Sel.Tag), g.fld(y, mir.Sel.Tag)))
      for vi, fs in layout {
        if fs.len() == 0 { continue }
        b.open_if(g.variant_tag(t, vi, x))
        for fi, (ft, _) in fs {
          let fa = g.variant_field(t, vi, fi, x)
          let fb = g.variant_field(t, vi, fi, y)
          let e = g.eq_expr(ft, fa, fb)
          fail_unless(&b, e)
        }
        b.close()
      }
      b.emit(mir.Stmt.Ret(mir.bool_(true)))
    }
    _ => b.emit(mir.Stmt.Ret(mir.bool_(false)))
  }
  b
}

/// `int64_t f(T a, T b)` (negative, 0, positive), or none when the type has no order.
pub fn cmp_fn(g: var Gen, t: types.Ty): mir.FRef? {
  match g.user_impl(types.Builtin.Ord, t) {
    some(f) => return f
    none => {}
  }
  var seen: {types.Ty: bool} = {}
  if !g.can(t, types.Builtin.Ord, &seen) { return none }
  some(mir.FRef.Fn(g.helper("cmp", t, [d(t), d(t)], d(types.Ty.Int), (g, f) => g.derive_cmp(t, f))))
}

/// An `int` expression comparing two values of type `t`.
pub fn cmp_expr(g: var Gen, t: types.Ty, a: mir.Ex, b: mir.Ex): mir.Ex {
  let int = d(types.Ty.Int)
  match t {
    Int => mir.rt("auk_int_cmp", [a, b], mir.MTy.I32).cast(int)
    Float => mir.rt("auk_float_cmp", [a, b], mir.MTy.I32).cast(int)
    Char | Bool => {
      let gt = mir.bin(mir.BOp.Gt, a, b).cast(int)
      let lt = mir.bin(mir.BOp.Lt, a, b).cast(int)
      mir.bin(mir.BOp.Sub, gt, lt)
    }
    Str => mir.rt("auk_str_cmp", [a, b], mir.MTy.I32).cast(int)
    _ => match g.cmp_fn(t) {
      some(f) => g.call_ref(f, [a, b], int)
      none => mir.int_(0)
    }
  }
}

/// Rust's `step` in `derive_cmp`: return the comparison unless it is 0.
fn cmp_step(b: var mir.Body, e: mir.Ex) {
  let r = b.decl(e)
  b.open_if(mir.bin(mir.BOp.Ne, r, mir.int_(0)))
  b.emit(mir.Stmt.Ret(r))
  b.close()
}

fn derive_cmp(g: var Gen, t: types.Ty, f: int): mir.Body {
  let (b0, ps) = g.body_for(f)
  var b = b0
  let x = ps[0]
  let y = ps[1]
  match t {
    Int | Float | Char | Bool | Str => {
      let e = g.cmp_expr(t, x, y)
      b.emit(mir.Stmt.Ret(e))
    }
    List(_) => b.emit(mir.Stmt.Ret(mir.rt("auk_arr_cmp", [x, y], mir.MTy.I32).cast(d(types.Ty.Int))))
    Tuple(ts) => {
      for i, et in ts {
        let s = mir.Sel.F(i)
        let e = g.cmp_expr(et, g.fld(x, s), g.fld(y, s))
        cmp_step(&b, e)
      }
      b.emit(mir.Stmt.Ret(mir.int_(0)))
    }
    Opt(et) => {
      let sa = g.fld(x, mir.Sel.F(0))
      let sb = g.fld(y, mir.Sel.F(0))
      b.open_if(mir.bin(mir.BOp.Ne, sa, sb))
      b.emit(mir.Stmt.Ret(mir.cond(sa, mir.int_(1), mir.int_(-1))))
      b.close()
      b.open_if(sa.not())
      b.emit(mir.Stmt.Ret(mir.int_(0)))
      b.close()
      let e = g.cmp_expr(et, g.fld(x, mir.Sel.F(1)), g.fld(y, mir.Sel.F(1)))
      b.emit(mir.Stmt.Ret(e))
    }
    Named(dd, args) when types.is_struct(g.tp.defs, dd) => {
      let s = types.subst_of(g.tp.defs, dd, args)
      for i, fd in types.fields(g.tp.defs, dd) {
        let fa = g.field_get(t, i, x)
        let fb = g.field_get(t, i, y)
        let e = g.cmp_expr(types.subst(fd.ty, s), fa, fb)
        cmp_step(&b, e)
      }
      b.emit(mir.Stmt.Ret(mir.int_(0)))
    }
    Named(_, _) => {
      let layout = mir.types.enum_layout(g.info, t)
      let ta = g.fld(x, mir.Sel.Tag)
      let tb = g.fld(y, mir.Sel.Tag)
      b.open_if(mir.bin(mir.BOp.Ne, ta, tb))
      b.emit(mir.Stmt.Ret(mir.cond(mir.bin(mir.BOp.Lt, ta, tb), mir.int_(-1), mir.int_(1))))
      b.close()
      for vi, fs in layout {
        if fs.len() == 0 { continue }
        b.open_if(g.variant_tag(t, vi, x))
        for fi, (ft, _) in fs {
          let fa = g.variant_field(t, vi, fi, x)
          let fb = g.variant_field(t, vi, fi, y)
          let e = g.cmp_expr(ft, fa, fb)
          cmp_step(&b, e)
        }
        b.close()
      }
      b.emit(mir.Stmt.Ret(mir.int_(0)))
    }
    _ => b.emit(mir.Stmt.Ret(mir.int_(0)))
  }
  b
}

/// `uint64_t f(T)` for map keys, or none.
pub fn hash_fn(g: var Gen, t: types.Ty): mir.FRef? {
  match t {
    Str => return some(mir.FRef.Rt("auk_str_hash"))
    List(_) => return some(mir.FRef.Rt("auk_arr_hash"))
    Map(_, _) | Fn(_, _) | Task(_) | Any(_) => return none
    _ => {}
  }
  if mir.types.is_foreign(g.info, t) {
    return some(
      mir.FRef.Fn(
        g.helper("hash", t, [d(t)], mir.MTy.U64, (g, f) => {
          let (b0, ps) = g.body_for(f)
          var b = b0
          b.emit(mir.Stmt.Ret(mir.rt("auk_hash_int", [ps[0].cast(d(types.Ty.Int))], mir.MTy.U64)))
          b
        }),
      ),
    )
  }
  var seen: {types.Ty: bool} = {}
  if !g.can(t, types.Builtin.Eq, &seen) || g.is_err_ty(t) { return none }
  some(mir.FRef.Fn(g.helper("hash", t, [d(t)], mir.MTy.U64, (g, f) => g.derive_hash(t, f))))
}

fn hash_expr(g: var Gen, t: types.Ty, v: mir.Ex): mir.Ex = match t {
  Int => mir.rt("auk_hash_int", [v], mir.MTy.U64)
  Char | Bool => mir.rt("auk_hash_int", [v.cast(d(types.Ty.Int))], mir.MTy.U64)
  Float => mir.rt("auk_hash_float", [v], mir.MTy.U64)
  Never => mir.int_as(0, mir.MTy.U64)
  Tuple(ts) when ts.len() == 0 => mir.int_as(0, mir.MTy.U64)
  _ => match g.hash_fn(t) {
    some(f) => g.call_ref(f, [v], mir.MTy.U64)
    none => mir.int_as(0, mir.MTy.U64)
  }
}

/// Rust's `comb` in `derive_hash`.
fn hash_comb(b: var mir.Body, h: mir.Ex, e: mir.Ex) {
  b.set(h, mir.rt("auk_hash_combine", [h, e], mir.MTy.U64))
}

fn derive_hash(g: var Gen, t: types.Ty, f: int): mir.Body {
  let (b0, ps) = g.body_for(f)
  var b = b0
  let v = ps[0]
  let h = b.decl(mir.int_as(7, mir.MTy.U64))
  match t {
    Int | Char | Bool | Float => {
      let e = g.hash_expr(t, v)
      b.set(h, e)
    }
    _ => if g.is_value(t) {
      b.set(h, mir.rt("auk_value_hash", [v.addr()], mir.MTy.U64))
    } else {
      match t {
        Tuple(ts) => for i, et in ts {
          let e = g.hash_expr(et, g.fld(v, mir.Sel.F(i)))
          hash_comb(&b, h, e)
        }
        Opt(et) | Res(et, _) => {
          b.open_if(g.fld(v, mir.Sel.F(0)))
          let e = g.hash_expr(et, g.fld(v, mir.Sel.F(1)))
          hash_comb(&b, h, e)
          b.close()
        }
        Named(dd, args) when types.is_struct(g.tp.defs, dd) => {
          let s = types.subst_of(g.tp.defs, dd, args)
          for i, fd in types.fields(g.tp.defs, dd) {
            let x = g.field_get(t, i, v)
            let e = g.hash_expr(types.subst(fd.ty, s), x)
            hash_comb(&b, h, e)
          }
        }
        Named(_, _) => {
          let layout = mir.types.enum_layout(g.info, t)
          b.set(h, mir.rt("auk_hash_int", [g.fld(v, mir.Sel.Tag).cast(d(types.Ty.Int))], mir.MTy.U64))
          for vi, fs in layout {
            if fs.len() == 0 { continue }
            b.open_if(g.variant_tag(t, vi, v))
            for fi, (ft, _) in fs {
              let x = g.variant_field(t, vi, fi, v)
              let e = g.hash_expr(ft, x)
              hash_comb(&b, h, e)
            }
            b.close()
          }
        }
        _ => {}
      }
    }
  }
  b.emit(mir.Stmt.Ret(h))
  b
}

// ---- Data: to_value / from_value ----

/// `AukValue f(T)` (owned result).
pub fn tov_fn(g: var Gen, t: types.Ty): mir.FRef {
  match g.user_impl(types.Builtin.Data, t) {
    some(f) => return f
    none => {}
  }
  let vt = d(g.value_ty())
  mir.FRef.Fn(g.helper("tov", t, [d(t)], vt, (g, f) => g.derive_tov(t, f)))
}

fn tov_expr(g: var Gen, t: types.Ty, v: mir.Ex): mir.Ex {
  let f = g.tov_fn(t)
  let vt = d(g.value_ty())
  g.call_ref(f, [v], vt)
}

/// Put an owned `Value` under `key` into the Value map `m` (then release it).
fn map_put(g: var Gen, b: var mir.Body, m: mir.Ex, key: str, e: mir.Ex) {
  let ev = b.decl(e)
  b.do_(mir.rt("auk_value_map_put", [m.addr(), mir.cstr(key), ev], mir.MTy.Void))
  b.do_(mir.rt("auk_value_release", [ev], mir.MTy.Void))
}

/// Rust's `wrap` in `derive_tov`: wrap an owned container into a Value and release ours.
fn tov_wrap(b: var mir.Body, vt: mir.MTy, ctor: str, c: mir.Ex) {
  let r = b.decl(mir.rt(ctor, [c], vt))
  b.do_(mir.rt("auk_release", [c], mir.MTy.Void))
  b.emit(mir.Stmt.Ret(r))
}

fn derive_tov(g: var Gen, t: types.Ty, f: int): mir.Body {
  let (b0, ps) = g.body_for(f)
  var b = b0
  let v = ps[0]
  let vty = g.value_ty()
  let vt = d(vty)
  let mty = types.Ty.Map(types.Ty.Str, vty)
  let lty = types.list(vty)
  match t {
    Int => b.emit(mir.Stmt.Ret(mir.rt("auk_value_int", [v], vt)))
    Float => b.emit(mir.Stmt.Ret(mir.rt("auk_value_float", [v], vt)))
    Bool => b.emit(mir.Stmt.Ret(mir.rt("auk_value_bool", [v], vt)))
    Str => b.emit(mir.Stmt.Ret(mir.rt("auk_value_str", [v], vt)))
    Char => {
      let s = b.decl(mir.rt("auk_str_from_char", [v], ty_str()))
      tov_wrap(&b, vt, "auk_value_str", s)
    }
    _ => if g.is_value(t) {
      b.do_(mir.rt("auk_value_retain", [v], mir.MTy.Void))
      b.emit(mir.Stmt.Ret(v))
    } else {
      g.derive_tov_rest(t, v, vt, mty, lty, &b)
    }
  }
  b
}

fn derive_tov_rest(g: var Gen, t: types.Ty, v: mir.Ex, vt: mir.MTy, mty: types.Ty, lty: types.Ty, b: var mir.Body) {
  match t {
    List(x) => {
      let xs = b.decl(mir.rt("auk_value_list_new", [], d(lty)))
      let i = b.decl(mir.int_(0))
      b.open_loop([mir.Stmt.Set(i, mir.bin(mir.BOp.Add, i, mir.int_(1)))])
      b.open_if(mir.bin(mir.BOp.Ge, i, mir.rt("auk_arr_len", [v], d(types.Ty.Int))))
      b.emit(mir.Stmt.Break)
      b.close()
      let el = mir.rt("auk_arr_at", [v, i, mir.null().cast(mir.MTy.CStr)], mir.void_ptr()).cast(mir.ptr(d(x))).deref(d(x))
      let e = g.tov_expr(x, el)
      let ev = b.decl(e)
      b.do_(mir.rt("auk_arr_push", [xs.addr(), ev.addr()], mir.MTy.Void))
      b.do_(mir.rt("auk_value_release", [ev], mir.MTy.Void))
      b.emit(mir.Stmt.Continue)
      b.close()
      tov_wrap(&b, vt, "auk_value_list", xs)
    }
    Map(_, x) => {
      let m = b.decl(mir.rt("auk_value_map_new", [], d(mty)))
      let it = b.decl(mir.int_(0))
      let kp = b.decl(mir.null())
      let vp = b.decl(mir.null())
      b.open_loop([])
      let next = mir.rt("auk_map_next", [v, it.addr(), kp.addr(), vp.addr()], mir.MTy.Bool)
      b.open_if(next.not())
      b.emit(mir.Stmt.Break)
      b.close()
      let e = g.tov_expr(x, vp.cast(mir.ptr(d(x))).deref(d(x)))
      let ev = b.decl(e)
      b.do_(mir.rt("auk_map_set", [m.addr(), kp, ev.addr()], mir.MTy.Void))
      b.do_(mir.rt("auk_value_release", [ev], mir.MTy.Void))
      b.close()
      tov_wrap(&b, vt, "auk_value_map", m)
    }
    Opt(x) => {
      b.open_if(g.fld(v, mir.Sel.F(0)).not())
      b.emit(mir.Stmt.Ret(mir.rt("auk_value_null", [], vt)))
      b.close()
      let e = g.tov_expr(x, g.fld(v, mir.Sel.F(1)))
      b.emit(mir.Stmt.Ret(e))
    }
    Named(dd, args) when types.is_struct(g.tp.defs, dd) => {
      let s = types.subst_of(g.tp.defs, dd, args)
      let m = b.decl(mir.rt("auk_value_map_new", [], d(mty)))
      for i, fd in types.fields(g.tp.defs, dd) {
        let x = g.field_get(t, i, v)
        let e = g.tov_expr(types.subst(fd.ty, s), x)
        g.map_put(&b, m, fd.name, e)
      }
      tov_wrap(&b, vt, "auk_value_map", m)
    }
    Named(dd, _) when types.is_enum(g.tp.defs, dd) => {
      let vs = types.variants(g.tp.defs, dd)
      let layout = mir.types.enum_layout(g.info, t)
      for vi, var_ in vs {
        b.open_if(g.variant_tag(t, vi, v))
        if var_.fields.len() == 0 {
          let s = b.decl(mir.rt("auk_str_lit", [mir.cstr(var_.name)], ty_str()))
          tov_wrap(&b, vt, "auk_value_str", s)
          b.close()
          continue
        }
        let m = b.decl(mir.rt("auk_value_map_new", [], d(mty)))
        let s = b.decl(mir.rt("auk_str_lit", [mir.cstr(var_.name)], ty_str()))
        let tag = mir.rt("auk_value_str", [s], vt)
        let tv = b.decl(tag)
        b.do_(mir.rt("auk_release", [s], mir.MTy.Void))
        b.do_(mir.rt("auk_value_map_put", [m.addr(), mir.cstr("tag"), tv], mir.MTy.Void))
        b.do_(mir.rt("auk_value_release", [tv], mir.MTy.Void))
        for fi, (fname, _) in var_.fields {
          let key = fname else "{fi}"
          let x = g.variant_field(t, vi, fi, v)
          let e = g.tov_expr(layout[vi][fi].0, x)
          g.map_put(&b, m, key, e)
        }
        tov_wrap(&b, vt, "auk_value_map", m)
        b.close()
      }
      b.emit(mir.Stmt.Ret(mir.rt("auk_value_null", [], vt)))
    }
    _ => b.emit(mir.Stmt.Ret(mir.rt("auk_value_null", [], vt)))
  }
}

/// `T! f(Value)`: the derived `from_value` (owned result).
pub fn fromv_fn(g: var Gen, t: types.Ty): mir.FRef {
  // a user `from_value` for the type (or a field/element type), like `tov_fn`'s `to_value`
  if !g.imprint_eval {
    match g.tp.from_value_impls.get(t) {
      some(Instance(i)) => return mir.FRef.Fn(g.inst_fn(i))
      some(Extern(symbol, _)) => return mir.FRef.Rt(symbol)
      _ => {}
    }
  }
  let vt = d(g.value_ty())
  let rt = d(types.res(t, g.err_ty()))
  mir.FRef.Fn(g.helper("fromv", t, [vt], rt, (g, f) => g.derive_fromv(t, f)))
}

/// What `derive_fromv`'s closures capture.
struct FromV {
  v: mir.Ex,
  r: mir.MTy,
  t: types.Ty,
  what: str,
  et: mir.MTy,
  tag: mir.Ex,
  vlist: types.Ty,
  vmap: types.Ty,
}

fn fv_ok(c: FromV, e: mir.Ex): mir.Ex =
  mir.agg(c.r, [(mir.Sel.F(0), mir.ex(mir.K.Int(1), mir.MTy.Bool)), (mir.Sel.F(1), mir.retype(e, d(c.t)))])

fn fv_err(c: FromV, e: mir.Ex): mir.Ex = mir.agg(c.r, [(mir.Sel.F(2), e)])

fn fv_is(c: FromV, n: int): mir.Ex = mir.bin(mir.BOp.Eq, c.tag, mir.int_as(n, mir.MTy.I32))

fn fv_mism(c: FromV, want: str): mir.Ex {
  let prefix = "from_value: expected {want} for `{c.what}`, got "
  mir.rt("auk__err_with_tag", [mir.cstr(prefix), c.tag], c.et)
}

fn fv_msg(c: FromV, s: str): mir.Ex = mir.rt("auk_err_new_cstr", [mir.cstr(s)], c.et)

fn fv_check(c: FromV, b: var mir.Body, cond: mir.Ex, want: str) {
  b.open_if(cond.not())
  b.emit(mir.Stmt.Ret(fv_err(c, fv_mism(c, want))))
  b.close()
}

fn fv_pay(c: FromV, vi: int, ty: types.Ty): mir.Ex = c.v.field(mir.Sel.V(vi, 0), d(ty))

fn fv_vfield(c: FromV, vi: int): types.Ty = if vi == 5 { c.vlist } else { c.vmap }

fn derive_fromv(g: var Gen, t: types.Ty, f: int): mir.Body {
  let (b0, ps) = g.body_for(f)
  var b = b0
  let v = ps[0]
  let rty = types.res(t, g.err_ty())
  let r = d(rty)
  let what = g.show_ty(t)
  let et = d(g.err_ty())
  let vty = g.value_ty()
  let c = FromV {
    v,
    r,
    t,
    what,
    et,
    tag: g.fld(v, mir.Sel.Tag),
    vlist: types.list(vty),
    vmap: types.Ty.Map(types.Ty.Str, vty),
  }
  match t {
    Int => {
      fv_check(c, &b, fv_is(c, 2), "Int")
      b.emit(mir.Stmt.Ret(fv_ok(c, fv_pay(c, 2, types.Ty.Int))))
    }
    Float => {
      b.open_if(fv_is(c, 2))
      b.emit(mir.Stmt.Ret(fv_ok(c, fv_pay(c, 2, types.Ty.Int).cast(d(types.Ty.Float)))))
      b.close()
      fv_check(c, &b, fv_is(c, 3), "Float")
      b.emit(mir.Stmt.Ret(fv_ok(c, fv_pay(c, 3, types.Ty.Float))))
    }
    Bool => {
      fv_check(c, &b, fv_is(c, 1), "Bool")
      b.emit(mir.Stmt.Ret(fv_ok(c, fv_pay(c, 1, types.Ty.Bool))))
    }
    Str => {
      fv_check(c, &b, fv_is(c, 4), "Str")
      b.emit(mir.Stmt.Ret(fv_ok(c, mir.rt("auk_retain", [fv_pay(c, 4, types.Ty.Str)], ty_str()))))
    }
    Char => {
      let s = fv_pay(c, 4, types.Ty.Str)
      let one = mir.and([fv_is(c, 4), mir.bin(mir.BOp.Eq, mir.rt("auk_str_len", [s], d(types.Ty.Int)), mir.int_(1))])
      fv_check(c, &b, one, "a one-char Str")
      b.emit(
        mir.Stmt.Ret(fv_ok(c, mir.rt("auk_str_char_at", [s, mir.int_(0), mir.null().cast(mir.MTy.CStr)], d(types.Ty.Char)))),
      )
    }
    Tuple(ts) when ts.len() == 0 => {
      fv_check(c, &b, fv_is(c, 0), "Null")
      b.emit(mir.Stmt.Ret(fv_ok(c, mir.unit())))
    }
    _ => if g.is_value(t) {
      b.do_(mir.rt("auk_value_retain", [v], mir.MTy.Void))
      b.emit(mir.Stmt.Ret(fv_ok(c, v)))
    } else {
      g.derive_fromv_rest(c, vty, &b)
    }
  }
  b
}

fn derive_fromv_rest(g: var Gen, c: FromV, vty: types.Ty, b: var mir.Body) {
  let t = c.t
  let v = c.v
  let et = c.et
  match t {
    List(x) => {
      let conv = g.fromv_fn(x)
      let ops = g.ops(x)
      fv_check(c, &b, fv_is(c, 5), "List")
      let list = fv_pay(c, 5, fv_vfield(c, 5))
      let out = b.decl(mir.rt("auk_arr_new", [ops, mir.rt("auk_arr_len", [list], d(types.Ty.Int))], d(t)))
      let i = b.decl(mir.int_(0))
      b.open_loop([mir.Stmt.Set(i, mir.bin(mir.BOp.Add, i, mir.int_(1)))])
      b.open_if(mir.bin(mir.BOp.Ge, i, mir.rt("auk_arr_len", [list], d(types.Ty.Int))))
      b.emit(mir.Stmt.Break)
      b.close()
      let e = mir.rt("auk_arr_at", [list, i, mir.null().cast(mir.MTy.CStr)], mir.void_ptr()).cast(mir.ptr(d(vty))).deref(d(vty))
      let xr = b.decl(g.call_ref(conv, [e], d(types.res(x, g.err_ty()))))
      b.open_if(g.fld(xr, mir.Sel.F(0)).not())
      b.do_(mir.rt("auk_release", [out], mir.MTy.Void))
      b.emit(mir.Stmt.Ret(fv_err(c, g.fld(xr, mir.Sel.F(2)))))
      b.close()
      let xv = g.fld(xr, mir.Sel.F(1))
      b.do_(mir.rt("auk_arr_push", [out.addr(), xv.addr()], mir.MTy.Void))
      match g.release(x, xv) {
        some(rel) => b.emit(rel)
        none => {}
      }
      b.emit(mir.Stmt.Continue)
      b.close()
      b.emit(mir.Stmt.Ret(fv_ok(c, out)))
    }
    Map(k, x) when k == types.Ty.Str => {
      let conv = g.fromv_fn(x)
      let vops = g.ops(x)
      fv_check(c, &b, fv_is(c, 6), "Map")
      let map = fv_pay(c, 6, fv_vfield(c, 6))
      let out = b.decl(mir.rt("auk_map_new", [mir.rt_global("auk_ops_str", mir.MTy.Rt(mir.Rt.ElemOps)), vops], d(t)))
      let it = b.decl(mir.int_(0))
      let kp = b.decl(mir.null())
      let vp = b.decl(mir.null())
      b.open_loop([])
      let next = mir.rt("auk_map_next", [map, it.addr(), kp.addr(), vp.addr()], mir.MTy.Bool)
      b.open_if(next.not())
      b.emit(mir.Stmt.Break)
      b.close()
      let xr = b.decl(g.call_ref(conv, [vp.cast(mir.ptr(d(vty))).deref(d(vty))], d(types.res(x, g.err_ty()))))
      b.open_if(g.fld(xr, mir.Sel.F(0)).not())
      b.do_(mir.rt("auk_release", [out], mir.MTy.Void))
      b.emit(mir.Stmt.Ret(fv_err(c, g.fld(xr, mir.Sel.F(2)))))
      b.close()
      let xv = g.fld(xr, mir.Sel.F(1))
      b.do_(mir.rt("auk_map_set", [out.addr(), kp, xv.addr()], mir.MTy.Void))
      match g.release(x, xv) {
        some(rel) => b.emit(rel)
        none => {}
      }
      b.close()
      b.emit(mir.Stmt.Ret(fv_ok(c, out)))
    }
    Opt(x) => {
      let conv = g.fromv_fn(x)
      b.open_if(fv_is(c, 0))
      b.emit(mir.Stmt.Ret(fv_ok(c, mir.zero(d(t)))))
      b.close()
      let xr = b.decl(g.call_ref(conv, [v], d(types.res(x, g.err_ty()))))
      b.open_if(g.fld(xr, mir.Sel.F(0)).not())
      b.emit(mir.Stmt.Ret(fv_err(c, g.fld(xr, mir.Sel.F(2)))))
      b.close()
      let some_ = mir.agg(d(t), [(mir.Sel.F(0), mir.ex(mir.K.Int(1), mir.MTy.Bool)), (mir.Sel.F(1), g.fld(xr, mir.Sel.F(1)))])
      b.emit(mir.Stmt.Ret(fv_ok(c, some_)))
    }
    Named(dd, args) when types.is_struct(g.tp.defs, dd) => {
      let s = types.subst_of(g.tp.defs, dd, args)
      let fields = types.fields(g.tp.defs, dd)
      fv_check(c, &b, fv_is(c, 6), "Map")
      let map = fv_pay(c, 6, fv_vfield(c, 6))
      let out = b.decl(mir.zero(d(t)))
      let errv = b.decl(mir.zero(et))
      let done = b.decl(mir.i64(0))
      var rels: [(int, types.Ty, mir.Ex)] = []
      for i, fd in fields {
        let ft = types.subst(fd.ty, s)
        let (raw, boxed) = g.field_raw(t, i, out)
        let key = g.lit(fd.name)
        let conv = g.fromv_fn(ft)
        b.open_if(mir.bin(mir.BOp.Eq, errv, mir.zero(et)))
        let fv = b.decl(mir.rt("auk_map_find", [map, key.addr()], mir.void_ptr()).cast(mir.ptr(d(vty))))
        b.open_if(mir.bin(mir.BOp.Eq, fv, mir.zero(mir.ptr(d(vty)))))
        if ft is types.Ty.Opt(_) {
          let z = g.field_put(t, i, mir.zero(d(ft)))
          b.set(raw, z)
        } else {
          b.set(errv, fv_msg(c, "from_value: missing field `{fd.name.replace("\"", "")}` of `{c.what}`"))
        }
        b.else_()
        let xr = b.decl(g.call_ref(conv, [fv.deref(d(vty))], d(types.res(ft, g.err_ty()))))
        b.open_if(g.fld(xr, mir.Sel.F(0)).not())
        b.set(errv, mir.rt("auk_err_wrap", [key, g.fld(xr, mir.Sel.F(2))], et))
        b.do_(mir.rt("auk_release", [g.fld(xr, mir.Sel.F(2))], mir.MTy.Void))
        b.else_()
        let put = g.field_put(t, i, g.fld(xr, mir.Sel.F(1)))
        b.set(raw, put)
        b.close()
        b.close()
        b.open_if(mir.bin(mir.BOp.Eq, errv, mir.zero(et)))
        b.set(done, mir.i64(i + 1))
        b.close()
        b.close()
        rels.push((i + 1, if boxed { types.Ty.Str } else { ft }, raw))
      }
      b.open_if(mir.bin(mir.BOp.Ne, errv, mir.zero(et)))
      for (i, ft, raw) in rels {
        let raw2 = if raw.ty is mir.MTy.Ptr(_) { raw.cast(ty_str()) } else { raw }
        match g.release(ft, raw2) {
          some(rel) => {
            b.open_if(mir.bin(mir.BOp.Ge, done, mir.i64(i)))
            b.emit(rel)
            b.close()
          }
          none => {}
        }
      }
      b.emit(mir.Stmt.Ret(fv_err(c, errv)))
      b.close()
      b.emit(mir.Stmt.Ret(fv_ok(c, out)))
    }
    Named(dd, _) when types.is_enum(g.tp.defs, dd) => g.derive_fromv_enum(c, dd, vty, &b)
    _ => b.emit(mir.Stmt.Ret(fv_err(c, fv_msg(c, "from_value: `{c.what}` doesn't convert from Value"))))
  }
}

/// Rust's `cleanup` in `derive_fromv`: release the fields converted so far.
fn fv_cleanup(g: var Gen, b: var mir.Body, names: [(mir.Ex, types.Ty)]) {
  for (pa, pty) in names {
    match g.release(pty, pa) {
      some(rel) => b.emit(rel)
      none => {}
    }
  }
}

fn derive_fromv_enum(g: var Gen, c: FromV, dd: int, vty: types.Ty, b: var mir.Body) {
  let t = c.t
  let vs = types.variants(g.tp.defs, dd)
  let layout = mir.types.enum_layout(g.info, t)
  let st = ty_str()
  let tagv = b.decl(mir.zero(st))
  b.open_if(fv_is(c, 4))
  b.set(tagv, fv_pay(c, 4, types.Ty.Str))
  b.else_()
  b.open_if(fv_is(c, 6))
  let tk = g.lit("tag")
  let tvp = b.decl(mir.rt("auk_map_find", [fv_pay(c, 6, fv_vfield(c, 6)), tk.addr()], mir.void_ptr()).cast(mir.ptr(d(vty))))
  let tvd = tvp.deref(d(vty))
  let tv_is_str = mir.bin(mir.BOp.Eq, tvd.field(mir.Sel.Tag, mir.MTy.I32), mir.int_as(4, mir.MTy.I32))
  b.open_if(mir.and([mir.bin(mir.BOp.Ne, tvp, mir.zero(mir.ptr(d(vty)))), tv_is_str]))
  b.set(tagv, tvd.field(mir.Sel.V(4, 0), st))
  b.close()
  b.close()
  b.close()
  b.open_if(mir.bin(mir.BOp.Eq, tagv, mir.zero(st)))
  b.emit(mir.Stmt.Ret(fv_err(c, fv_mism(c, "a Str or a Map with a \"tag\""))))
  b.close()
  for vi, var_ in vs {
    b.open_if(mir.rt("auk_str_eq_lit", [tagv, mir.cstr(var_.name)], mir.MTy.Bool))
    if var_.fields.len() == 0 {
      let e = g.variant_new(t, vi, [])
      b.emit(mir.Stmt.Ret(fv_ok(c, e)))
      b.close()
      continue
    }
    fv_check(c, &b, fv_is(c, 6), "a Map")
    let map = fv_pay(c, 6, fv_vfield(c, 6))
    var names: [(mir.Ex, types.Ty)] = []
    for fi, (fname, _) in var_.fields {
      let ft = layout[vi][fi].0
      let key = g.lit(fname else "{fi}")
      let conv = g.fromv_fn(ft)
      let a = b.decl(mir.zero(d(ft)))
      let fv = b.decl(mir.rt("auk_map_find", [map, key.addr()], mir.void_ptr()).cast(mir.ptr(d(vty))))
      b.open_if(mir.bin(mir.BOp.Eq, fv, mir.zero(mir.ptr(d(vty)))))
      fv_cleanup(&g, &b, names)
      b.emit(mir.Stmt.Ret(fv_err(c, fv_msg(c, "from_value: missing field of variant {var_.name.replace("\"", "")}"))))
      b.close()
      let xr = b.decl(g.call_ref(conv, [fv.deref(d(vty))], d(types.res(ft, g.err_ty()))))
      b.open_if(g.fld(xr, mir.Sel.F(0)).not())
      fv_cleanup(&g, &b, names)
      b.emit(mir.Stmt.Ret(fv_err(c, g.fld(xr, mir.Sel.F(2)))))
      b.close()
      b.set(a, g.fld(xr, mir.Sel.F(1)))
      names.push((a, ft))
    }
    let args = names.map(p => p.0)
    let e = g.variant_new(t, vi, args)
    b.emit(mir.Stmt.Ret(fv_ok(c, e)))
    b.close()
  }
  let e = mir.rt(
    "auk__err_concat",
    [mir.cstr("from_value: unknown variant `"), tagv, mir.cstr("` of `{c.what}`")],
    c.et,
  )
  b.emit(mir.Stmt.Ret(fv_err(c, e)))
}

// ---- any S ----

/// The vtable aggregate of shape `s`: one code pointer per method.
pub fn vt_struct(g: var Gen, s: int): int {
  let key = types.Ty.Any(s)
  match g.memo.get(("vts", key)) {
    some(n) => return n
    none => {}
  }
  let n = max(g.tp.defs.shapes[s].methods.len(), 1)
  let fields = (0..n).map(_ => mir.MTy.Code)
  let a = g.agg("DkVt{s}_{sanitize(g.tp.defs.shapes[s].name)}", fields)
  g.memo[("vts", key)] = a
  a
}

pub fn method_ty(g: var Gen, t: types.Ty, s: int): types.Ty = mir.types.method_ty(g.info, t, s)

// ---- the program ----

/// Build `dk_init` (string literals, imprints, constants) and `dk_cleanup` (release the
/// constants); returns them.
pub fn init_and_cleanup(g: var Gen): (int, int) {
  let init = g.declare("dk_init", [], mir.MTy.Void, mir.Abi.Auk)
  var b = mir.new_body()
  for (s, gl) in g.lit_order {
    let ge = g.global_ex(gl)
    b.set(ge, mir.rt("auk_str_from_bytes", [mir.ex(mir.K.CStr(s.bytes()), mir.MTy.CStr), mir.int_(s.byte_len())], ty_str()))
    b.do_(mir.rt("auk_make_immortal", [ge], mir.MTy.Void))
  }
  for f in g.imprint_inits { b.do_(g.call(f, [])) }
  for (getter, _) in g.const_order { b.do_(g.call(getter, [])) }
  // literals created by the imprints above are initialized too (new ones were appended)
  g.define(init, b)
  let cleanup = g.declare("dk_cleanup", [], mir.MTy.Void, mir.Abi.C)
  var cb = mir.new_body()
  for (_, free) in g.const_order.reverse() { cb.do_(g.call(free, [])) }
  g.define(cleanup, cb)
  (init, cleanup)
}

/// Is module `m` part of the root package (whose tests `auk test` runs)?
pub fn in_root_pkg(g: var Gen, m: int): bool {
  let p = g.tp.program
  p.mods[m].pkg == p.mods[p.root].pkg
}

/// The source text of a span in module `m`.
pub fn span_text(g: var Gen, m: int, span: diag.Span): str {
  let src = g.tp.program.mods[m].src
  var out: [str] = []
  for i, line in rust_lines(src) {
    let ln = i + 1
    if ln < span.line || ln > span.end_line { continue }
    let chars = line.chars()
    let from = if ln == span.line { max(span.col - 1, 0) } else { 0 }
    let to = if ln == span.end_line { min(max(span.end_col - 1, 0), chars.len()) } else { chars.len() }
    if from <= to && from <= chars.len() { out.push(str(chars[from..to])) }
    if ln != span.end_line { out.push("\n") }
  }
  out.join("")
}

/// Rust's `str::lines`: split at `\n`, drop a `\r` before it, no empty last line.
pub fn rust_lines(s: str): [str] {
  var out = s.split("\n")
  if out.len() > 0 && out[out.len() - 1] == "" { let _ = out.pop() }
  out.map(l => if l.ends_with("\r") { str(l.chars()[0..l.len() - 1]) } else { l })
}

/// The AST item of a body: its module and item.
pub fn body_item(g: var Gen, b: typed.BodyRef): (int, ast.Item) {
  let tp = g.tp
  match b {
    Fn(f) => match tp.fns[f].kind {
      Auk(item, _, _) => (tp.fns[f].module, tp.program.mods[tp.fns[f].module].ast.items[item])
      _ => mir.bug("not an Auk function")
    }
    Test(t) => (tp.tests[t].module, tp.program.mods[tp.tests[t].module].ast.items[tp.tests[t].item])
    Const(c) => (tp.consts[c].module, tp.program.mods[tp.consts[c].module].ast.items[tp.consts[c].item])
  }
}

/// Record a hole for `auk build`'s refusal.
pub fn note_hole(g: var Gen, loc: str, expected: str) {
  g.holes.push("{loc}: unfilled hole (expected {expected})")
}

/// Is `v` a constant that holds no references: a zero, or an enum variant without fields
/// (`Tok.LParen`), whose retain and release do nothing?
pub fn holds_no_refs(v: mir.Ex): bool = match v.k {
  Zero => true
  Agg(parts) => (v.ty is mir.MTy.D(_)) && parts.all(p => p.0 == mir.Sel.Tag && (p.1.k is mir.K.Int(_)))
  _ => false
}
