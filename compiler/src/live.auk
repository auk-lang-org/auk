/// `auk run --live <file> [args...]` (src/live.rs): run a program and swap in new code as its
/// source changes. See the Rust module for the design; this is a line-by-line port.
///
/// A parent process compiles the program and forks a child to run it. The program is compiled
/// in live mode: every call to a user function loads its target from the live table, one slot
/// per function, keyed by module, name and signature (`Generated.live_keys`). In the child, a
/// watcher polls the source files; on a change it re-checks and recompiles the whole program into
/// a new JIT module, runs that module's `dk_init` and stores its functions into the table. A
/// type error leaves the running code as it is; a changed struct or enum layout cancels the
/// tasks that can hold one (their supervisors start them again on the new code), or restarts
/// the program (exit `RESTART`) when `main`'s side can. Old modules are never freed.
///
/// Differences from Rust:
/// - The watcher is an Auk task (Rust: a thread), started with copies of what it needs (the
///   slots, files, layouts and `Seen`); it compiles on its own heap. The program's `main` runs on
///   the child's main thread, as in Rust.
/// - C can't call back into Auk, so the runtime got four small entry points for this driver
///   (runtime/c/task.c): `auk__live_running` (the running tasks' thunk and closure hint) and
///   `auk__live_cancel` (cancel the tasks with the chosen pairs) split Rust's
///   `rt::cancel_running(pick)`; `auk__live_install` runs a module's `dk_init` off the task's
///   heap and stores the slots with release stores (Rust's `install`); `auk__live_reloaded`
///   bumps the `reloads()` counter (Rust's `LIVE_RELOADS.fetch_add`).
/// - A file's modification time is C `stat`'s (seconds, nanoseconds) through `ffi` (core has no
///   `mtime`): `st_mtimespec` at offset 48 on macOS (arm64), `st_mtim` at 88 on Linux.
/// - Rust's `HashSet`/`HashMap`s are `{K: bool}`/`{K: V}` maps; `sig_key` (Rust: the `Debug`
///   text of the signature) is the signature itself as a map key. A closure body that can't be
///   narrowed (Rust's `None`) is -1, and `Seen.closures` names its graph by index in
///   `Seen.graphs` (Rust: an `Arc<Graph>`).
/// - Rust iterates its `HashMap` of layouts in an arbitrary order, so when several types change
///   shape at once which one its restart message names, and the order of the names in the
///   "stopped" message, vary from run to run; the port takes them sorted by `file::Name`.

/// The child's exit code that asks the parent for a fresh start.
let RESTART = 75

/// Live table slots (one per user function instance ever compiled in this run).
let TABLE_LEN = 65536

/// How often the files are polled, in milliseconds.
let POLL = 200

let USAGE = "usage: auk run --live <file.auk> [args...]"

extern fn c_stat(path: str, buf: ffi.Ptr): int = "int stat(const char *, void *)"
extern fn c_fork(): int = "int fork(void)"
extern fn c__exit(code: int) = "void _exit(int)"
extern fn c_getppid(): int = "int getppid(void)"
extern fn c_isatty(fd: int): int = "int isatty(int)"
extern fn c_setenv(k: str, v: str, overwrite: int): int = "int setenv(const char *, const char *, int)"
extern fn c_gui_shutdown() = "void auk_gui_shutdown(void)"
extern fn c_live_running(out: ffi.Ptr, cap: int): int = "int64_t auk__live_running(void *, int64_t)"
extern fn c_live_cancel(pairs: ffi.Ptr, n: int): int = "int64_t auk__live_cancel(void *, int64_t)"
extern fn c_live_install(init: ffi.Ptr, table: ffi.Ptr, pairs: ffi.Ptr, n: int) =
  "void auk__live_install(void *, void *, void *, int64_t)"
extern fn c_live_reloaded() = "void auk__live_reloaded(void)"

/// When a file last changed: C `stat`'s modification time (seconds, nanoseconds), none if it
/// can't be read.
fn mtime(p: str): (int, int)? uses ffi {
  let buf = ffi.alloc(256)
  let at = if paths.os() == "macos" { 48 } else { 88 }
  let t = if c_stat(p, buf) == 0 {
    some((ffi.read_i64(buf, at), ffi.read_i64(buf, at + 8)))
  } else {
    none
  }
  ffi.free(buf)
  t
}

/// The source files of a program and when each last changed (Rust's `Files`).
fn files_of(tp: typed.TypedProgram): [(str, (int, int)?)] uses ffi {
  var out: [(str, (int, int)?)] = []
  for m in tp.program.mods {
    if !m.file.starts_with("<prelude>") { out.push((m.file, mtime(m.file))) }
  }
  out
}

fn changed(files: [(str, (int, int)?)]): bool uses ffi {
  for f in files {
    if mtime(f.0) != f.1 { return true }
  }
  false
}

/// The same files, with their times now.
fn snapshot(files: [(str, (int, int)?)]): [(str, (int, int)?)] uses ffi {
  var out: [(str, (int, int)?)] = []
  for f in files { out.push((f.0, mtime(f.0))) }
  out
}

/// Every struct and enum's layout as text, by `file::Name`: a change means data already in
/// memory no longer fits the code.
fn layouts(tp: typed.TypedProgram): {str: str} {
  var out: {str: str} = {}
  for t in tp.defs.types {
    let shape = match t.kind {
      Struct(fields) => some(fields.map(f => "{f.name}: {types.show(tp.defs, f.ty)}").join(", "))
      Enum(variants) =>
        some(variants.map(v => "{v.name}({v.fields.map(p => types.show(tp.defs, p.1)).join(", ")})").join(" | "))
      Opaque(_) => none
    }
    match shape {
      some(s) => out["{tp.program.mods[t.module].file}::{t.name}"] = s
      none => {}
    }
  }
  out
}

// ---- which types code can touch ----

/// The user types (`file::Name`, as in `layouts`) that code can hold: what is reachable from
/// `main` without starting a task, and from each task entry (thunk) by name.
struct Uses {
  main: {str: bool},
  /// Per thunk: what it can reach (`wide`: an indirect call may be any closure of its
  /// signature), and what it reaches on its own (`narrow`: indirect calls not followed).
  thunks: {str: ({str: bool}, {str: bool})},
  /// The call graph, to work out on demand what a closure can reach (only for closures that
  /// running tasks were started with: there are many closures, few such tasks).
  graph: Graph,
}

/// A compiled program's call graph, with the user types each function itself holds.
struct Graph {
  own: [{str: bool}],
  /// Functions called directly, or whose address is taken (a closure made, a helper passed).
  refs: [[int]],
  /// The functions called directly (a closure's body is reached by calling it, not making it).
  calls: [{int: bool}],
  /// The closures each function's indirect calls might call (any of the same signature).
  indirect: [[int]],
  names: [str],
  /// Closure bodies by name: -1 when the closure's environment holds closures (then a task
  /// started with it gets its thunk's `wide` set).
  closures: {str: int},
}

/// The user types reachable from `start` without entering another task's thunk. `wide`:
/// indirect calls may reach any closure of their signature; else only the closures the reached
/// code makes.
fn reach(g: Graph, start: int, wide: bool): {str: bool} {
  var seen: {int: bool} = {}
  var stack = [start]
  var keys: {str: bool} = {}
  loop {
    let f = stack.pop() else break
    if seen.contains(f) { continue }
    seen[f] = true
    for k, _ in g.own[f] { keys[k] = true }
    if wide {
      for x in g.indirect[f] { stack.push(x) }
    }
    for x in g.refs[f] {
      let n = g.names[x]
      let addr_only = is_thunk(n) || (wide && is_closure(n))
      if !addr_only || g.calls[f].contains(x) { stack.push(x) }
    }
  }
  keys
}

/// The functions an expression calls or takes the address of, and its indirect calls'
/// signatures.
fn refs_ex(e: mir.Ex, out: var [int], ind: var [([mir.MTy], mir.MTy)]) {
  match e.k {
    FnAddr(r) => match r {
      Fn(f) => out.push(f)
      Rt(_) => {}
    }
    Call(c, args) => {
      match c {
        Fn(f) => out.push(f)
        Indirect(code, ps) => {
          ind.push((ps, e.ty))
          refs_ex(code, &out, &ind)
        }
        CPtr(code) => refs_ex(code, &out, &ind)
        Rt(_) => {}
      }
      for a in args { refs_ex(a, &out, &ind) }
    }
    Field(x, _) | Deref(x) | Addr(x) | Un(_, x) | Cast(x) | RtField(x, _) => refs_ex(x, &out, &ind)
    Bin(_, a, b) | Elem(a, b) => {
      refs_ex(a, &out, &ind)
      refs_ex(b, &out, &ind)
    }
    And(xs) => for x in xs { refs_ex(x, &out, &ind) }
    Agg(ms) => for m in ms { refs_ex(m.1, &out, &ind) }
    Cond(a, b, c) => {
      refs_ex(a, &out, &ind)
      refs_ex(b, &out, &ind)
      refs_ex(c, &out, &ind)
    }
    _ => {}
  }
}

fn refs_stmts(ss: [mir.Stmt], out: var [int], ind: var [([mir.MTy], mir.MTy)]) {
  for s in ss {
    match s {
      Let(_, e) | Do(e) => refs_ex(e, &out, &ind)
      Set(a, b) => {
        refs_ex(a, &out, &ind)
        refs_ex(b, &out, &ind)
      }
      If(c, a, b) => {
        refs_ex(c, &out, &ind)
        refs_stmts(a, &out, &ind)
        refs_stmts(b, &out, &ind)
      }
      Loop(a, b) => {
        refs_stmts(a, &out, &ind)
        refs_stmts(b, &out, &ind)
      }
      Ret(r) => match r {
        some(e) => refs_ex(e, &out, &ind)
        none => {}
      }
      _ => {}
    }
  }
}

/// The functions `ss` calls directly (not just takes the address of).
fn direct_calls(ss: [mir.Stmt]): {int: bool} {
  var out: {int: bool} = {}
  calls_st(ss, &out)
  out
}

fn calls_ex(e: mir.Ex, out: var {int: bool}) {
  match e.k {
    Call(c, args) => {
      match c {
        Fn(f) => out[f] = true
        _ => {}
      }
      for a in args { calls_ex(a, &out) }
    }
    Field(x, _) | Deref(x) | Addr(x) | Un(_, x) | Cast(x) | RtField(x, _) => calls_ex(x, &out)
    Bin(_, a, b) | Elem(a, b) => {
      calls_ex(a, &out)
      calls_ex(b, &out)
    }
    And(xs) => for x in xs { calls_ex(x, &out) }
    Agg(ms) => for m in ms { calls_ex(m.1, &out) }
    Cond(a, b, c) => {
      calls_ex(a, &out)
      calls_ex(b, &out)
      calls_ex(c, &out)
    }
    _ => {}
  }
}

fn calls_st(ss: [mir.Stmt], out: var {int: bool}) {
  for s in ss {
    match s {
      Let(_, e) | Do(e) => calls_ex(e, &out)
      Ret(r) => match r {
        some(e) => calls_ex(e, &out)
        none => {}
      }
      Set(a, b) => {
        calls_ex(a, &out)
        calls_ex(b, &out)
      }
      If(c, a, b) => {
        calls_ex(c, &out)
        calls_st(a, &out)
        calls_st(b, &out)
      }
      Loop(a, b) => {
        calls_st(a, &out)
        calls_st(b, &out)
      }
      _ => {}
    }
  }
}

fn is_thunk(name: str): bool = name.starts_with("dk_thunk") && !name.ends_with("_drop")

fn is_closure(name: str): bool = name.starts_with("dk_clo") || name.starts_with("dk_fv")

/// The user types a type mentions, through struct fields and enum variants.
fn ty_keys(tp: typed.TypedProgram, t: types.Ty, out: var {str: bool}) {
  match t {
    Named(d, args) => {
      let def = tp.defs.types[d]
      let key = "{tp.program.mods[def.module].file}::{def.name}"
      if !out.contains(key) {
        out[key] = true
        match def.kind {
          Struct(fields) => for f in fields { ty_keys(tp, f.ty, &out) }
          Enum(variants) => for v in variants {
            for p in v.fields { ty_keys(tp, p.1, &out) }
          }
          Opaque(_) => {}
        }
      }
      for a in args { ty_keys(tp, a, &out) }
    }
    List(x) | Opt(x) | Task(x) | Measured(x, _) | Mut(x) => ty_keys(tp, x, &out)
    Map(a, b) | Res(a, b) => {
      ty_keys(tp, a, &out)
      ty_keys(tp, b, &out)
    }
    Tuple(ts) => for x in ts { ty_keys(tp, x, &out) }
    Fn(ps, r) => {
      for x in ps { ty_keys(tp, x, &out) }
      ty_keys(tp, r, &out)
    }
    _ => {}
  }
}

/// Does a type mention a closure or an `any` value (Rust's `t.walk(..)` in `holds_fn`)?
fn has_fn(t: types.Ty): bool = match t {
  Fn(_, _) | Any(_) => true
  List(x) | Opt(x) | Task(x) | Measured(x, _) | Mut(x) => has_fn(x)
  Map(a, b) | Res(a, b) => has_fn(a) || has_fn(b)
  Tuple(ts) | Named(_, ts) => ts.any(x => has_fn(x))
  _ => false
}

fn holds_fn(m: mir.MTy): bool = match m {
  D(t) => has_fn(t)
  _ => false
}

fn mty_keys(prog: mir.Program, tp: typed.TypedProgram, m: mir.MTy, out: var {str: bool}, aggs: var {int: bool}) {
  match m {
    D(t) => ty_keys(tp, t, &out)
    Ptr(x) => mty_keys(prog, tp, x, &out, &aggs)
    Agg(a) => if !aggs.contains(a) {
      aggs[a] = true
      for f in prog.aggs[a].fields { mty_keys(prog, tp, f, &out, &aggs) }
    }
    _ => {}
  }
}

fn uses_of(prog: mir.Program, tp: typed.TypedProgram): Uses {
  // closures by signature, for indirect calls
  var callables: {([mir.MTy], mir.MTy): [int]} = {}
  for i, f in prog.funcs {
    if is_closure(f.name) {
      let key = (f.params.map(v => f.vars[v]), f.ret)
      var l = callables.get(key) else []
      l.push(i)
      callables[key] = l
    }
  }
  var own: [{str: bool}] = []
  var refs: [[int]] = []
  var calls: [{int: bool}] = []
  var indirect: [[int]] = []
  for f in prog.funcs {
    var keys: {str: bool} = {}
    var aggs: {int: bool} = {}
    for t in f.vars { mty_keys(prog, tp, t, &keys, &aggs) }
    mty_keys(prog, tp, f.ret, &keys, &aggs)
    own.push(keys)
    var out: [int] = []
    var ind: [([mir.MTy], mir.MTy)] = []
    refs_stmts(f.body, &out, &ind)
    refs.push(out)
    calls.push(direct_calls(f.body))
    var targets: [int] = []
    for s in ind {
      for c in (callables.get(s) else []) { targets.push(c) }
    }
    indirect.push(targets)
  }
  // a closure `dk_clo{k}` keeps its captures in the aggregate `DkEnv{k}`
  var envs: {str: mir.AggDef} = {}
  for a in prog.aggs { envs[a.name] = a }
  var closures: {str: int} = {}
  for i, f in prog.funcs {
    if is_closure(f.name) {
      var safe = true
      match f.name.strip_prefix("dk_clo") {
        some(k) => match envs.get("DkEnv{k}") {
          some(a) => safe = !a.fields.any(x => holds_fn(x))
          none => {}
        }
        none => {}
      }
      closures[f.name] = if safe { i } else { -1 }
    }
  }
  let graph = Graph { own, refs, calls, indirect, names: prog.funcs.map(f => f.name), closures }
  let main = match prog.entry {
    some(e) => reach(graph, e, true)
    none => {}
  }
  var thunks: {str: ({str: bool}, {str: bool})} = {}
  for i, f in prog.funcs {
    if is_thunk(f.name) { thunks[f.name] = (reach(graph, i, true), reach(graph, i, false)) }
  }
  Uses { main, thunks, graph }
}

/// One compile of the program in live mode.
struct Build {
  jit: backend.LiveCode,
  files: [(str, (int, int)?)],
  layouts: {str: str},
  reach: Uses,
}

/// What every compile so far says code can touch: `main`'s side, and each task entry by code
/// address (old modules' tasks may still be running).
struct Seen {
  main: {str: bool},
  thunks: {int: ({str: bool}, {str: bool})},
  /// Every compile's call graph (Rust shares them with `Arc`).
  graphs: [Graph],
  /// Closure code addresses: the graph they're in (an index in `graphs`) and their body (-1:
  /// not narrowable).
  closures: {int: (int, int)},
}

fn add(s: var Seen, b: Build) {
  for k, _ in b.reach.main { s.main[k] = true }
  for name, keys in b.reach.thunks {
    match b.jit.addrs.get(name) {
      some(a) => s.thunks[ffi.addr(a)] = keys
      none => {}
    }
  }
  let gi = s.graphs.len()
  s.graphs.push(b.reach.graph)
  for name, f in b.reach.graph.closures {
    match b.jit.addrs.get(name) {
      some(a) => s.closures[ffi.addr(a)] = (gi, f)
      none => {}
    }
  }
}

fn hit(set: {str: bool}, keys: [str]): bool = keys.any(k => set.contains(k))

/// Can the task that started at thunk `entry` (with closure `hint`, 0 if none) hold one of the
/// types `keys`? Narrowed to its closure when it was started with exactly one (`sup`
/// children), else everything its thunk can reach.
fn task_uses(s: Seen, entry: int, hint: int, keys: [str]): bool {
  let t = s.thunks.get(entry) else return false
  match s.closures.get(hint) {
    some(c) => if hint != 0 && c.1 >= 0 {
      hit(t.1, keys) || hit(reach(s.graphs[c.0], c.1, true), keys)
    } else {
      hit(t.0, keys)
    }
    none => hit(t.0, keys)
  }
}

/// Cancel each running task that `task_uses` picks; returns how many (Rust's
/// `rt::cancel_running`).
fn cancel_running(s: Seen, keys: [str]): int uses ffi {
  var cap = 64
  loop {
    let buf = ffi.alloc(16 * cap)
    let n = c_live_running(buf, cap)
    if n > cap {
      ffi.free(buf)
      cap = n * 2
      continue
    }
    var picked: [(int, int)] = []
    var decided: {(int, int): bool} = {}
    for i in 0..n {
      let pair = (ffi.read_i64(buf, 16 * i), ffi.read_i64(buf, 16 * i + 8))
      if !decided.contains(pair) {
        let yes = task_uses(s, pair.0, pair.1, keys)
        decided[pair] = yes
        if yes { picked.push(pair) }
      }
    }
    ffi.free(buf)
    let pairs = ffi.alloc(16 * picked.len() + 16)
    for i, p in picked {
      ffi.write_i64(pairs, 16 * i, p.0)
      ffi.write_i64(pairs, 16 * i + 8, p.1)
    }
    let k = c_live_cancel(pairs, picked.len())
    ffi.free(pairs)
    return k
  }
  0
}

/// The result of `build` (Rust's `Result<Build, (String, Option<Files>)>`).
enum Outcome {
  Done(b: Build),
  /// The error text, and the files to watch for a fix.
  Failed(msg: str, files: [(str, (int, int)?)]?),
}

/// Check and compile `path`, giving new functions slots in `slots`.
fn build(cx: resolve.Sources, path: str, slots: var {str: int}, table: int): Outcome uses fs, env, proc, ffi {
  let tp = match drive.check_program(cx, path) {
    ok(t) => t
    err(e) => return Outcome.Failed("{e}", none)
  }
  let files = files_of(tp)
  let g = match drive.generate(tp, mir.progen.Mode.Run, mir.progen.no_trace()) {
    ok(g) => g
    err(e) => return Outcome.Failed("{e}", some(files_of(tp)))
  }
  var fslots: {int: int} = {}
  for f, key in g.live_keys {
    let n = slots.len()
    let slot = match slots.get(key) {
      some(s) => s
      none => {
        slots[key] = n
        n
      }
    }
    if slot >= TABLE_LEN {
      return Outcome.Failed("error: --live: too many functions compiled in this run; restart it\n", some(files_of(tp)))
    }
    fslots[f] = slot
  }
  let jit = match backend.jit_live(g.prog, g.info, table, fslots) {
    ok(j) => j
    err(e) =>
      return Outcome.Failed("error: code generation failed (this is an auk compiler bug): {e}\n", some(files_of(tp)))
  }
  let u = uses_of(g.prog, tp)
  Outcome.Done(Build { jit, files, layouts: layouts(tp), reach: u })
}

/// Make `b`'s code the current code: initialize its module, then point the table at it.
fn install(b: Build, table: int) uses ffi {
  let n = b.jit.entries.len()
  let pairs = ffi.alloc(16 * n + 16)
  for i, e in b.jit.entries {
    ffi.write_i64(pairs, 16 * i, e.0)
    ffi.write_ptr(pairs, 16 * i + 8, e.1)
  }
  c_live_install(b.jit.init, ffi.ptr(table), pairs, n)
  ffi.free(pairs)
}

/// Block until one of `files` changes.
fn wait_change(files: [(str, (int, int)?)]) uses time, ffi {
  while changed(files) == false { time.sleep(POLL) }
}

fn note(msg: str) uses ffi {
  if c_isatty(2) == 1 {
    eprint("\u{1b}[2m[live]\u{1b}[0m {msg}")
  } else {
    eprint("[live] {msg}")
  }
}

/// `file::Name` → `Name`.
fn short(k: str): str = k.split("::").last() else k

/// The child's watcher: reload on every change, or exit for a restart.
async fn watch(
  cx: resolve.Sources,
  path: str,
  slots0: {str: int},
  files0: [(str, (int, int)?)],
  lay0: {str: str},
  seen0: Seen,
  parent: int,
  table: int,
): int uses fs, env, proc, time, ffi {
  var slots = slots0
  var files = files0
  var lay = lay0
  var seen = seen0
  loop {
    time.sleep(POLL)
    // the parent is gone (killed): don't outlive it
    if c_getppid() != parent { c__exit(1) }
    if !changed(files) { continue }
    let t0 = time.now()
    match build(cx, path, &slots, table) {
      Failed(e, fs) => {
        posix.eprint_raw(e)
        note("not reloaded: the program keeps running the previous code")
        files = match fs {
          some(f) => f
          none => snapshot(files)
        }
      }
      Done(b) => {
        var moved: [str] = []
        for k in b.layouts.keys().sort() {
          match lay.get(k) {
            some(old) => if old != b.layouts[k] { moved.push(k) }
            none => {}
          }
        }
        add(&seen, b)
        for k in moved {
          if seen.main.contains(k) {
            note("`{short(k)}` changed shape and `main`'s side of the program uses it: restarting the program")
            posix.flush()
            c__exit(RESTART)
          }
        }
        install(b, table)
        c_live_reloaded()
        if moved.len() > 0 {
          // only tasks can hold the old shape: stop those (their supervisors restart them)
          let n = cancel_running(seen, moved)
          note("`{moved.map(k => short(k)).join("`, `")}` changed shape: stopped {n} task(s) that use it")
        }
        for k, v in b.layouts { lay[k] = v }
        files = b.files
        note("reloaded in {time.now() - t0} ms")
      }
    }
  }
  0
}

/// `auk run --live <file> [args...]`.
pub fn cli(cx: resolve.Sources, args: [str]): int uses fs, env, proc, time, ffi {
  if args.len() == 0 {
    eprint(USAGE)
    return 2
  }
  let path = args[0]
  var last: [(str, (int, int)?)] = [(path, mtime(path))]
  // every run of the program shares one window process (gui.rs), so a restart keeps its windows
  let session = paths.join(env.get("TMPDIR") else "/tmp", "auk-gui-{posix.pid()}.sock")
  let _ = c_setenv("AUK_GUI_SESSION", session, 1)
  let table = ffi.addr(ffi.alloc(8 * TABLE_LEN))
  loop {
    var slots: {str: int} = {}
    let b = match build(cx, path, &slots, table) {
      Done(b) => b
      Failed(e, fs) => {
        posix.eprint_raw(e)
        match fs {
          some(f) => last = f
          none => {}
        }
        note("waiting for a fix")
        wait_change(snapshot(last))
        continue
      }
    }
    install(b, table)
    last = b.files
    posix.flush()
    let me = posix.pid()
    let pid = c_fork()
    if pid < 0 {
      eprint("error: fork failed")
      return 1
    }
    if pid == 0 {
      var seen = Seen { main: {}, thunks: {}, graphs: [], closures: {} }
      add(&seen, b)
      let watcher = watch(cx, path, slots, b.files, b.layouts, seen, me, table)
      let code = orcjit.run(b.jit.entry, args)
      // a normal end: its windows close now instead of waiting for the next run
      c_gui_shutdown()
      posix.flush()
      c__exit(code)
      watcher.cancel()
    }
    // the parent: the child has the program now (its code stays in memory)
    let code = match posix.wait(pid) {
      ok(c) => c
      err(_) => none
    }
    if code == some(RESTART) { continue }
    note(match code {
      some(c) => "the program exited with {c}; waiting for a change to start it again"
      none => "the program was killed; waiting for a change to start it again"
    })
    wait_change(snapshot(last))
  }
  0
}
