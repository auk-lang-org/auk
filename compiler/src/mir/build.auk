/// Whole-program MIR generation (the `generate` half of src/build.rs): every instance through
/// `mir.lower`, the entry point (the `main` shim or the test runner), the debugger's tables,
/// `dk_init`/`dk_cleanup`; the imprint evaluator program and its records; and `compiler ir`,
/// which prints the MIR as `auk ir` does.
///
/// Imprints are computed at compile time by running a helper program (`imprint_program`).
/// Running it needs the back end (Phase 4); until the port has one, `compiler ir` takes the
/// helper's records from a file (`--imprints <file>`, as `AUK_IMPRINT_RECORDS=<file> auk ir`
/// writes them), and `--imprint-eval` prints the helper program itself.

/// A generated program (MIR), plus the holes found in it.
pub struct Generated {
  prog: mir.Program,
  info: mir.types.TyInfo,
  /// The debug info (`--debug`).
  dbg: mir.progen.DbgInfo,
  holes: [str],
  /// The number of tests registered (test mode).
  tests: int,
  /// `auk run --live`'s keys (Rust's `Program::live_keys`).
  live_keys: {int: str},
}

/// The bytes of every `"#embed path"` file the program's C functions name.
pub fn embeds(tp: typed.TypedProgram): {str: [int]} uses fs {
  var out: {str: [int]} = {}
  for f in tp.fns {
    match f.kind {
      Ffi(sig, _, _) => match sig.embed {
        some(p) => if !out.contains(p) {
          out[p] = match fs.read_bytes(p) {
            ok(b) => b
            err(_) => []
          }
        }
        none => {}
      }
      _ => {}
    }
  }
  out
}

fn new_gen(tp: typed.TypedProgram, mode: mir.progen.Mode, emb: {str: [int]}): mir.progen.Gen {
  var g = mir.progen.new(tp, mode)
  g.embeds = emb
  g
}

/// The program as MIR. In `Mode.Test` the entry point runs the root package's tests.
/// `imprints`: the values of the imprints (`eval_imprints`).
pub fn generate(
  tp: typed.TypedProgram,
  mode: mir.progen.Mode,
  trace: mir.progen.Trace,
  imprints: {int: mir.progen.CVal},
  emb: {str: [int]},
): Generated! uses ffi {
  var g = new_gen(tp, mode, emb)
  g.imprints = imprints
  g.trace = mir.progen.Trace { debug: false, lines: false, ..trace }
  g.lines = trace.lines
  g.dbg = mir.progen.Debug { on: trace.debug, core: false }
  var tests: [(int, int)] = []
  for i, inst in tp.instances {
    // an imprint's initializer ran at compile time; only its value is emitted
    match inst.body {
      Const(c) => if g.imprints.contains(c) { continue }
      Test(t) => {
        if mode != mir.progen.Mode.Test || !g.in_root_pkg(tp.tests[t].module) { continue }
        tests.push((t, i))
      }
      _ => {}
    }
    emit(&g, i)
    drain(&g)
  }
  let i32 = mir.MTy.I32
  let entry = g.declare("dk_entry", [i32, mir.void_ptr()], i32, mir.Abi.C)
  let (b0, ps) = g.body_for(entry)
  var b = b0
  let ntests = tests.len()
  var tail: [mir.Stmt] = []
  if mode == mir.progen.Mode.Test {
    // the tracer starts before the constants are initialized (their initializers are traced too)
    trace_init(&b, trace, true)
    for (t, i) in tests {
      let f = g.inst_fn(i)
      tail.push(mir.Stmt.Do(mir.rt("auk_test_register", [mir.cstr(tp.tests[t].name), mir.fn_addr(f)], mir.MTy.Void)))
    }
    tail.push(mir.Stmt.Ret(mir.rt("auk_test_main", [ps[0], ps[1]], i32)))
  } else {
    let mi = match tp.main {
      some(mi) => mi
      none => return fail(
        "error: no `main` function found in `{tp.program.mods[tp.program.root].file}` (add `fn main()`; `auk test` runs its tests)\n",
      )
    }
    var inst = -1
    for k, x in tp.instances {
      if inst < 0 && x.body == typed.BodyRef.Fn(mi.func) && x.type_args.len() == 0 { inst = k }
    }
    if inst < 0 { return fail("error: main has no instance (compiler bug)\n") }
    let f = g.inst_fn(inst)
    let rint = types.res(types.Ty.Int, g.err_ty())
    let shim = g.declare("dk_main_shim", [mir.MTy.D(types.list(types.Ty.Str))], mir.MTy.D(rint), mir.Abi.C)
    let (sb0, sp) = g.body_for(shim)
    var sb = sb0
    let call = g.call(f, if mi.takes_args { [sp[0]] } else { [] })
    let okv = (e: mir.Ex) => mir.agg(mir.MTy.D(rint), [(mir.Sel.F(0), mir.ex(mir.K.Int(1), mir.MTy.Bool)), (mir.Sel.F(1), e)])
    match mi.ret {
      Int => sb.emit(mir.Stmt.Ret(okv(call)))
      Res(t, _) => if types.is_unit(t) {
        let r = sb.decl(call)
        sb.open_if(g.fld(r, mir.Sel.F(0)).not())
        sb.emit(mir.Stmt.Ret(mir.agg(mir.MTy.D(rint), [(mir.Sel.F(2), g.fld(r, mir.Sel.F(2)))])))
        sb.close()
        sb.emit(mir.Stmt.Ret(okv(mir.int_(0))))
      } else {
        sb.emit(mir.Stmt.Ret(call))
      }
      _ => {
        sb.do_(call)
        sb.emit(mir.Stmt.Ret(okv(mir.int_(0))))
      }
    }
    g.define(shim, sb)
    trace_init(&b, trace, false)
    tail.push(mir.Stmt.Ret(mir.rt("auk_main_wrapper", [ps[0], ps[1], mir.fn_addr(shim)], i32)))
  }
  drain(&g)
  if g.dbg.on {
    let (info, shows, kids) = dbg_tables(&g)
    b.do_(
      mir.rt(
        "auk_dbg_init",
        [mir.cstr(info), mir.ex(mir.K.GlobalAddr(shows), mir.void_ptr()), mir.ex(mir.K.GlobalAddr(kids), mir.void_ptr())],
        mir.MTy.Void,
      ),
    )
  }
  let (init, cleanup) = g.init_and_cleanup()
  b.do_(g.call(init, []))
  b.do_(mir.rt("auk_set_cleanup", [mir.fn_addr(cleanup)], mir.MTy.Void))
  for s in tail { b.emit(s) }
  g.define(entry, b)
  g.prog.entry = some(entry)
  Generated { prog: g.prog, info: g.info, dbg: g.dbg_info, holes: g.holes, tests: ntests, live_keys: g.live_keys }
}

fn trace_init(b: var mir.Body, trace: mir.progen.Trace, tests: bool) {
  if trace.on {
    b.do_(mir.rt("auk_trace_init", [mir.ex(mir.K.Int(if tests { 1 } else { 0 }), mir.MTy.Bool)], mir.MTy.Void))
  }
}

fn emit(g: var mir.progen.Gen, i: int) {
  if g.emitted.contains(i) { return }
  g.emitted[i] = true
  mir.lower.emit_instance(&g, i)
}

pub fn drain(g: var mir.progen.Gen) {
  while g.queue.len() > 0 {
    let j = g.queue.pop()!
    emit(&g, j)
  }
}

/// The debugger's tables (`--debug`): the debug info as text for `auk_dbg_init`, and constant
/// arrays of show and children functions, one per type of a named local. Showing a type can
/// instantiate more (instrumented) code, so this runs to a fixpoint.
fn dbg_tables(g: var mir.progen.Gen): (str, int, int) uses ffi {
  var fns: [int] = []
  var kids: [int?] = []
  while fns.len() < g.dbg_info.types.len() {
    let t = g.dbg_info.types[fns.len()]
    let f = g.declare("dk_dbgshow{fns.len()}", [mir.void_ptr()], mir.MTy.D(types.Ty.Str), mir.Abi.C)
    let (b0, ps) = g.body_for(f)
    var b = b0
    let v = ps[0].cast(mir.ptr(mir.MTy.D(t))).deref(mir.MTy.D(t))
    let s = match g.dshow_fn(t) {
      some(sf) => g.call_ref(sf, [v], mir.MTy.D(types.Ty.Str))
      none => {
        let text = "<{g.show_ty(t)}>"
        mir.rt("auk_str_from_bytes", [mir.cstr(text), mir.int_(text.byte_len())], mir.MTy.D(types.Ty.Str))
      }
    }
    b.emit(mir.Stmt.Ret(s))
    g.define(f, b)
    let k = g.dbg_kids_fn(t, fns.len())
    fns.push(f)
    kids.push(k)
    drain(&g)
  }
  let a = g.agg("DkDbgShows", (0..max(fns.len(), 1)).map(_ => mir.MTy.Code))
  var ms: [(mir.Sel, mir.Ex)] = []
  for i, f in fns { ms.push((mir.Sel.F(i), mir.fn_addr(f))) }
  let shows = g.global("dk_dbgshows", mir.MTy.Agg(a), some(mir.agg(mir.MTy.Agg(a), ms)), true)
  let a2 = g.agg("DkDbgKids", (0..max(kids.len(), 1)).map(_ => mir.MTy.Code))
  var ks: [(mir.Sel, mir.Ex)] = []
  for i, k in kids {
    ks.push((mir.Sel.F(i), match k {
      some(f) => mir.fn_addr(f)
      none => mir.zero(mir.MTy.Code)
    }))
  }
  let kids_g = g.global("dk_dbgkids", mir.MTy.Agg(a2), some(mir.agg(mir.MTy.Agg(a2), ks)), true)
  // the text: `p <file>`, `t <type>`, `f <function>` followed by `v <type> <local>` per frame
  // slot, then `s <fn> <file> <line> <col> <slot,...>` per site (ids in order)
  let info = g.dbg_info
  var out: [str] = []
  var files: [str] = []
  for s in info.sites {
    if !files.contains(s.file) { files.push(s.file) }
  }
  for f in files {
    let abs = paths.canonicalize(f) else f
    out.push("p {abs}\n")
  }
  for t in info.types { out.push("t {g.show_ty(t).replace("\n", " ")}\n") }
  for f in info.fns {
    out.push("f {f.name}\n")
    for (n, t) in f.locals { out.push("v {t} {n}\n") }
  }
  for s in info.sites {
    let file = files.find_index(f => f == s.file) else 0
    let vis = s.vis.map(v => "{v}")
    out.push("s {s.func} {file} {s.line} {s.col} {vis.join(",")}\n")
  }
  (out.join(""), shows, kids_g)
}

// ---- compile-time imprints (see src/build.rs) ----

/// The helper program that computes every imprint (`auk__imprint_*` records), or none when the
/// program has no imprints.
pub fn imprint_program(tp: typed.TypedProgram, emb: {str: [int]}): (mir.Program, mir.types.TyInfo)? {
  var ids: [int] = []
  for c, k in tp.consts {
    if k.imprint { ids.push(c) }
  }
  if ids.len() == 0 { return none }
  var g = new_gen(tp, mir.progen.Mode.Run, emb)
  g.imprint_eval = true
  let entry = g.declare("dk_entry", [mir.MTy.I32, mir.void_ptr()], mir.MTy.I32, mir.Abi.C)
  let (b0, ps) = g.body_for(entry)
  var b = b0
  var values: [(int, int, mir.FRef)] = []
  for c in ids {
    let getter = g.const_getter(c)
    let tov = g.tov_fn(tp.consts[c].ty)
    values.push((c, getter, tov))
  }
  drain(&g)
  let (init, _) = g.init_and_cleanup()
  let bad = mir.rt("auk__imprint_open", [ps[0], ps[1]], mir.MTy.Bool).not()
  b.open_if(bad)
  b.emit(mir.Stmt.Ret(mir.int_as(2, mir.MTy.I32)))
  b.close()
  b.do_(g.call(init, []))
  let vt = mir.MTy.D(g.value_ty())
  for (c, getter, tov) in values {
    let v = g.call(getter, [])
    let tv = b.decl(g.call_ref(tov, [v], vt))
    b.do_(mir.rt("auk__imprint_value", [mir.i64(c), tv.addr()], mir.MTy.Void))
    b.do_(mir.rt("auk_value_release", [tv], mir.MTy.Void))
  }
  b.do_(mir.rt("auk__imprint_close", [], mir.MTy.Void))
  b.emit(mir.Stmt.Ret(mir.int_as(0, mir.MTy.I32)))
  g.define(entry, b)
  g.prog.entry = some(entry)
  some((g.prog, g.info))
}

/// A reader of the imprint helper's records.
struct Records { b: [int], i: int }

fn rbyte(p: var Records): int {
  let c = p.b.get(p.i) else 0
  p.i += 1
  c
}

/// A decimal integer up to (and past) the terminator `end`.
fn rint(p: var Records, end: int): int? {
  let start = p.i
  while p.i < p.b.len() && p.b[p.i] != end { p.i += 1 }
  let s = str(p.b[start..p.i].map(c => char(c) else ' '))
  p.i += 1
  match int.parse(s) {
    ok(n) => some(n)
    err(_) => none
  }
}

fn rvalue(p: var Records): mir.progen.CVal? {
  let tag = rbyte(&p)
  if tag == 78 { return mir.progen.CVal.Null }
  if tag == 84 { return mir.progen.CVal.Bool(true) }
  if tag == 70 { return mir.progen.CVal.Bool(false) }
  if tag == 73 { return mir.progen.CVal.Int(rint(&p, 59)?) }
  if tag == 68 {
    if p.i + 16 > p.b.len() { return none }
    // u64 bits: shifted in wrapping (int.parse would overflow past 2^63)
    var bits = 0
    for c in p.b[p.i..p.i + 16] {
      let v = if c >= 48 && c <= 57 { c - 48 } else if c >= 97 && c <= 102 { c - 87 } else if c >= 65 && c <= 70 { c - 55 } else { return none }
      bits = (bits << 4) | v
    }
    p.i += 16
    if rbyte(&p) != 59 { return none }
    return mir.progen.CVal.Float(float.from_bits(bits))
  }
  if tag == 83 { return mir.progen.CVal.Str(rstr(&p)?) }
  if tag == 76 {
    let n = rint(&p, 59)?
    var xs: [mir.progen.CVal] = []
    for _ in 0..n { xs.push(rvalue(&p)?) }
    return mir.progen.CVal.List(xs)
  }
  if tag == 77 {
    let n = rint(&p, 59)?
    var es: [(str, mir.progen.CVal)] = []
    for _ in 0..n {
      if rbyte(&p) != 83 { return none }
      let k = rstr(&p)?
      es.push((k, rvalue(&p)?))
    }
    return mir.progen.CVal.Map(es)
  }
  none
}

fn rstr(p: var Records): str? {
  let n = rint(&p, 58)?
  if n < 0 || p.i + n > p.b.len() { return none }
  let bytes = p.b[p.i..p.i + n]
  p.i += n
  match str.from_utf8(bytes) {
    ok(s) => some(s)
    err(_) => none
  }
}

/// The imprint values from the helper's records (written by a run that exited 0).
pub fn imprint_values(tp: typed.TypedProgram, data: [int]): {int: mir.progen.CVal}! {
  var p = Records { b: data, i: 0 }
  var values: {int: mir.progen.CVal} = {}
  while p.i < data.len() {
    let tag = rbyte(&p)
    let end = if tag == 86 { 32 } else { 10 }
    let c = rint(&p, end) else break
    if c < 0 || c >= tp.consts.len() { break }
    if tag == 86 {
      let v = rvalue(&p) else break
      values[c] = v
      let _ = rbyte(&p)
    } else if tag != 66 && tag != 69 && tag != 67 {
      break
    }
  }
  for c, k in tp.consts {
    if k.imprint && !values.contains(c) {
      return fail("error: computing the imprints failed: no value for `{k.name}` in the records")
    }
  }
  values
}

// ---- `compiler ir` ----

/// `compiler ir [--release] [-g] [--trace=json|<file>] [--trace-core] [--debug]
/// [--imprints <records>] [--imprint-eval] [--time] [--repeat N] <file>`: the MIR as `auk ir`
/// prints it. `--time` prints the time of lowering (checking excluded) to stderr.
pub fn cli(args: [str], prelude: str?): int! uses fs, time, ffi {
  var release = false
  var lines = false
  var trace = mir.progen.no_trace()
  var records: str? = none
  var eval_only = false
  var time_it = false
  var quiet = false
  var repeat = 1
  var file: str? = none
  var i = 2
  while i < args.len() {
    let a = args[i]
    if a == "--release" {
      release = true
    } else if a == "-g" {
      lines = true
    } else if a == "--trace" || a.starts_with("--trace=") {
      trace.on = true
    } else if a == "--trace-core" {
      trace.core = true
    } else if a == "--debug" {
      trace.debug = true
    } else if a == "--imprints" {
      i += 1
      records = args.get(i)
    } else if a == "--imprint-eval" {
      eval_only = true
    } else if a == "--time" {
      time_it = true
    } else if a == "--quiet" {
      quiet = true
    } else if a == "--repeat" {
      i += 1
      repeat = int.parse(args.get(i) else "1") else 1
    } else if file == none && !a.starts_with("-") {
      file = some(a)
    }
    i += 1
  }
  let path = file else {
    eprint("usage: compiler ir [--release] [-g] [--trace=json|<file>] [--trace-core] [--debug] [--imprints <records>] <file.auk>")
    return 2
  }
  let dir = prelude else {
    eprint("error: can't find the core prelude (src/prelude/core.auk); set AUK_PRELUDE_DIR")
    return 1
  }
  let cx = resolve.sources(dir)?
  let prog = match resolve.load(cx, path) {
    ok(p) => p
    err(Many(ds)) => {
      for x in ds { eprint("{x.file}: {x.diag.code}: {x.diag.message}") }
      return 1
    }
  }
  let (tpo, errs) = check.check_types(prog)
  if errs.len() > 0 {
    for x in errs { eprint("{x.file}:{x.diag.span.line}:{x.diag.span.col}: {x.diag.code}: {x.diag.message}") }
    return 1
  }
  var tp = tpo!
  units.erase(&tp)
  let emb = embeds(tp)
  if eval_only {
    match imprint_program(tp, emb) {
      some((p, info)) => print_raw(mir.printer.print_program(p, info))
      none => {}
    }
    return 0
  }
  var imprints: {int: mir.progen.CVal} = {}
  if tp.consts.any(k => k.imprint) {
    let rf = records else {
      eprint("error: computing imprints needs the back end; pass `--imprints <records>` (AUK_IMPRINT_RECORDS=<file> auk ir writes them)")
      return 1
    }
    imprints = imprint_values(tp, fs.read_bytes(rf)?)?
  }
  let mode = if release { mir.progen.Mode.Release } else { mir.progen.Mode.Run }
  let tr = mir.progen.Trace { lines, ..trace }
  let t0 = time.now()
  var out = ""
  for _ in 0..repeat {
    match generate(tp, mode, tr, imprints, emb) {
      ok(gen) => if !quiet { out = mir.printer.print_program(gen.prog, gen.info) }
      err(e) => {
        eprint_raw("{e}")
        return 1
      }
    }
  }
  if time_it { eprint("time: {(time.now() - t0) * 1000 / repeat} us") }
  if out != "" { print_raw(out) }
  0
}

/// Write `s` to stdout as is (`print` adds a newline).
fn print_raw(s: str) uses ffi {
  let n = c_write(1, s, s.byte_len())
  if n < 0 { eprint("error: writing the output failed") }
}

fn eprint_raw(s: str) uses ffi { let _ = c_write(2, s, s.byte_len()) }

extern fn c_write(fd: int, s: str, n: int): int = "long write(int, const char *, size_t)"
