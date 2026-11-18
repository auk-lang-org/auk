/// Evaluating Auk expressions at a debugger stop (`eval`, conditional breakpoints): the compiler
/// side of the debug engine's eval hook (runtime/c/dbg.c), installed by `auk run --debug` in the
/// program's own process (src/dbg_eval.rs).
///
/// To check an expression with exactly the names, types and scopes of the stopped statement, it
/// is written into a copy of the program's source right there, as `let __dbg_r = (<expr>)`
/// before the statement (or, for an expression body like `= e` / `x => e`, in a block around
/// it). The copy is checked as a whole program (every module pinned to the source the running
/// program was built from), and only that expression is compiled (`mir.lower.emit_eval`): a
/// function that reads each local it uses through the stopped frame's slot addresses and returns
/// the value shown. It runs in a fresh JIT module (`backend.jit_eval`), so the functions it
/// calls are fresh copies too (without breakpoints); locals are the frame's own (an assignment
/// changes them).
///
/// Differences from Rust: C can't call Auk (no callbacks), so the hook is a mailbox in dbg.c
/// (`auk_dbg_eval_mailbox`): the stopped thread posts its request and waits, and `serve`, a task
/// started by `install` (Rust: a hook function behind a `Mutex`ed global, called on the stopped
/// thread), compiles it and answers. The answer's initializer (`dk_init`: the expression's
/// literals and constants) is run by dbg.c on the stopped thread, as Rust runs it in the hook.
/// The server ends when `uninstall` closes the mailbox. A panic while compiling (a compiler bug)
/// becomes the expression's error instead of ending the program. Byte offsets in the source are
/// char offsets (Auk strings index by char).

/// What evaluation needs of the running program.
pub struct Cx {
  /// Where the prelude comes from (the binary's own).
  sources: resolve.Sources,
  root: str,
  /// The source of every non-core module, as the program was built.
  srcs: {str: str},
  info: mir.progen.DbgInfo,
}

/// An expression compiled at a site: the address of its function of the locals' addresses (in
/// `slots` order), its initializer's, and the type shown.
pub struct Compiled { run: ffi.Ptr, init: ffi.Ptr, slots: [int], ty: str }

/// The name an evaluated expression is bound to.
let RESULT = "__dbg_r"

extern fn c_mailbox() = "void auk_dbg_eval_mailbox(void)"
extern fn c_next(): int = "int64_t auk_dbg_eval_next(void)"
extern fn c_func(): int = "int64_t auk_dbg_eval_func(void)"
extern fn c_site(): int = "int64_t auk_dbg_eval_site(void)"
extern fn c_expr(): str = "const char *auk_dbg_eval_expr(void)"
extern fn c_ok(run: ffi.Ptr, init: ffi.Ptr, slots: [int], n: int, ty: str) =
  "void auk_dbg_eval_ok(void *, void *, const int64_t *, int64_t, const char *)"
extern fn c_err(msg: str) = "void auk_dbg_eval_err(const char *)"
extern fn c_close() = "void auk_dbg_eval_close(void)"

/// Make expressions evaluable in this process's program (`auk run --debug`): the server task,
/// to `uninstall` when the program has ended.
pub fn install(cx: resolve.Sources, root: str, tp: typed.TypedProgram, info: mir.progen.DbgInfo): Task<int> uses fs, env, proc, ffi {
  var srcs: {str: str} = {}
  for m, md in tp.program.mods {
    if !resolve.is_core(tp.program, m) { srcs[md.file] = md.src }
  }
  c_mailbox()
  serve(Cx { sources: cx, root, srcs, info })
}

/// Stop serving (the program ended).
pub fn uninstall(t: Task<int>) uses ffi {
  c_close()
  let _ = await t
}

async fn serve(cx: Cx): int uses fs, env, proc, ffi {
  while c_next() == 1 {
    let func = c_func()
    let site = c_site()
    let expr = c_expr()
    match catch compile(cx, func, site, expr) {
      ok(c) => c_ok(c.run, c.init, c.slots, c.slots.len(), c.ty)
      err(e) => c_err("{e}")
    }
  }
  0
}

/// The char index (1-based line and column) as an offset into `src`.
fn offset(cs: [char], line: int, col: int): int {
  var ln = 1
  var i = 0
  while ln < line && i < cs.len() {
    if cs[i] == '\n' { ln += 1 }
    i += 1
  }
  if ln < line { return cs.len() }
  var j = i
  while j < cs.len() && cs[j] != '\n' { j += 1 }
  // the line with its line break, as Rust's `split_inclusive`
  let n = j - i + (if j < cs.len() { 1 } else { 0 })
  let c = max(col - 1, 0)
  if c < n { i + c } else { j }
}

/// `src` with `text` inserted at char offset `at`.
fn insert(src: str, at: int, text: str): str {
  let cs = src.chars()
  cs.take(at).join("") + text + cs.skip(at).join("")
}

fn compile(cx: Cx, func: int, site: int, expr: str): Compiled! uses fs, env, proc, ffi {
  // an expression; failing that, a statement such as an assignment (`x = 5`: a `var` local
  // of the frame changes), in a block whose value is `()`
  match compile_as(cx, func, site, "({expr})") {
    ok(c) => c
    err(e) => match compile_as(cx, func, site, "{{\n{expr}\n}}") {
      ok(c) => c
      err(_) => fail(e)
    }
  }
}

fn compile_as(cx: Cx, func: int, site: int, expr: str): Compiled! uses fs, env, proc, ffi {
  let s = cx.info.sites.get(site) else return fail("no such statement")
  let f = cx.info.fns.get(func) else return fail("no such function")
  var src = cx.srcs.get(s.file) else return fail("can't evaluate in {s.file}")
  // the copy with the expression in it
  let let_ = "let {RESULT} = {expr}"
  if s.wrap {
    let end = offset(src.chars(), s.end_line, s.end_col)
    src = insert(src, end, "\n}}")
    let start = offset(src.chars(), s.line, s.col)
    src = insert(src, start, "{{ {let_}\n")
  } else {
    let start = offset(src.chars(), s.line, s.col)
    src = insert(src, start, "{let_}\n{" ".repeat(max(s.col - 1, 0))}")
  }
  var srcs = cx.srcs
  srcs[s.file] = src
  var sx = cx.sources
  sx.overrides = srcs
  let ds = match resolve.load(sx, cx.root) {
    ok(prog) => match check.check_all(prog) {
      (some(tp0), _) => {
        var t = tp0
        units.erase(&t)
        return compile_in(t, s, f)
      }
      (none, ds) => ds
    }
    err(Many(ds)) => ds
  }
  // the expression's own errors (in the edited file) first
  let sorted = ds.sort_by(d => if d.file != s.file { 1 } else { 0 })
  match sorted.first() {
    some(d) => fail(d.diag.message)
    none => fail("it doesn't check")
  }
}

fn compile_in(tp: typed.TypedProgram, s: mir.progen.DbgSite, f: mir.progen.DbgFn): Compiled! uses fs, env, proc, ffi {
  let m = tp.program.mods.find_index(x => x.file == s.file) else return fail("the module is gone")
  // the inserted `let` and its value
  var value: ast.Expr? = none
  for item in tp.program.mods[m].ast.items {
    var es: [ast.Expr] = []
    visit.visit_item_exprs(item, &es)
    for e in es {
      if value != none { break }
      match e.kind {
        Let(_, pat, _, v, _) => match pat.kind {
          Bind(n) => if n == RESULT { value = some(v) }
          _ => {}
        }
        _ => {}
      }
    }
  }
  let value = value else return fail("the expression got lost (compiler bug)")
  let inst = tp.instances.find_index(x => x.body == f.body && x.type_args == f.type_args) else {
    return fail("this function isn't compiled any more")
  }
  // the stopped frame's locals that it uses: by name, the latest binding in scope
  let t = tp.tables[m]
  let vs = value.span
  let inside = (sp: diag.Span) =>
    (sp.line, sp.col) >= (vs.line, vs.col) && (sp.line, sp.col) <= (vs.end_line, vs.end_col)
  var binds: [int] = []
  var slots: [int] = []
  var missing: str? = none
  var es: [ast.Expr] = []
  visit.visit_expr(value, &es)
  for e in es {
    match e.kind {
      Name(_) => match t.names.get(e.id) {
        some(Local(l)) => if !inside(t.locals[l].span) && !binds.contains(l) {
          let name = t.locals[l].name
          match s.vis.reverse().find(v => match f.locals.get(v) {
            some((n, _)) => n == name
            none => false
          }) {
            some(slot) => {
              binds.push(l)
              slots.push(slot)
            }
            none => missing = some(name)
          }
        }
        _ => {}
      }
      _ => {}
    }
  }
  match missing {
    some(n) => return fail("`{n}` has no value here")
    none => {}
  }
  let subst = typed.inst_subst(tp.instances[inst], tp.fns)
  let ty = match t.locals.reverse().find(l => l.name == RESULT) {
    some(l) => types.show(tp.defs, types.subst(l.ty, subst))
    none => ""
  }
  // compile just the expression (and what it calls)
  let emb = mir.build.embeds(tp)
  var g = mir.progen.new(tp, mir.progen.Mode.Run)
  g.embeds = emb
  g.imprints = drive.eval_imprints(tp, emb)?
  let run = mir.lower.emit_eval(&g, inst, value, binds)
  mir.build.drain(&g)
  let _ = g.init_and_cleanup()
  g.prog.entry = some(run)
  let (entry, init) = backend.jit_eval(g.prog, g.info)?
  Compiled { run: entry, init, slots, ty }
}
