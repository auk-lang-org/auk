/// The back end driver and the `run`, `build`, `ir` and `test` commands (src/build.rs):
/// TypedProgram → MIR (`mir.build.generate`) → machine code (`backend`).
///
/// `run` and `test` compile in memory (ORC) and run the program in this process (the runtime is
/// linked into the compiler; the test runner forks a child per test); imprints run a helper
/// program in a forked child. Debug builds (`run`, `test`, `ir`) check `ensures`; `build` is a
/// release build (optimized, no `ensures`) that refuses a program with holes: an object file
/// linked with the embedded runtime library by the system linker (`native`).

/// The exit status of `auk __jit` (and of a flat directory's test child) when the program
/// doesn't compile.
let JIT_BUILD_FAILED = 125

/// Execution-trace options of `auk run|test|ir` (`--trace=json|<path>`, `--trace-limit N`,
/// `--trace-core`), plus `--debug` and `-O`.
pub struct TraceOpts {
  /// Where events go: `-` (stderr; `json` on the command line) or a path (`run`: a file;
  /// `test`: a directory with one `<test>.jsonl` per test). None: not tracing.
  dest: str?,
  /// The most events written (the runtime default, 10,000, when none).
  limit: int?,
  /// Trace core library functions too.
  core: bool,
  /// `--debug`: instrument the program for the debugger.
  debug: bool,
  /// `-O` (`auk run`): the full optimizer.
  opt: bool,
}

fn no_trace_opts(): TraceOpts = TraceOpts { dest: none, limit: none, core: false, debug: false, opt: false }

/// The code generator's flags.
fn codegen(o: TraceOpts): mir.progen.Trace =
  mir.progen.Trace { on: o.dest != none, core: o.core, debug: o.debug, lines: false }

extern fn c_setenv(k: str, v: str, overwrite: int): int = "int setenv(const char *, const char *, int)"
extern fn c_unsetenv(k: str): int = "int unsetenv(const char *)"

/// Configure the tracer of a program run in this process (`dest` overrides `o.dest`).
fn apply_here(o: TraceOpts, dest: str?) uses ffi {
  let d = dest else (o.dest else return)
  let _ = c_setenv("AUK_TRACE", d, 1)
  match o.limit {
    some(n) => { let _ = c_setenv("AUK_TRACE_LIMIT", "{n}", 1) }
    none => { let _ = c_unsetenv("AUK_TRACE_LIMIT") }
  }
}

/// Split the trace flags off `args`: anywhere in them, or (`leading`) only before the first
/// other argument (`auk run`'s program arguments may look like flags).
fn trace_flags(args: [str], leading: bool): (TraceOpts, [str])! {
  var o = no_trace_opts()
  var rest: [str] = []
  var limit_seen = false
  var i = 0
  while i < args.len() {
    let a = args[i]
    i += 1
    if leading && rest.len() > 0 {
      rest.push(a)
      continue
    }
    if a == "--trace" || a == "--trace=json" || a == "--trace=-" {
      o.dest = some("-")
    } else if a.starts_with("--trace=") && !a.starts_with("--trace-") {
      let p = a.strip_prefix("--trace=")!
      if p == "" { return fail("--trace= needs `json` or a path") }
      o.dest = some(p)
    } else if a == "--trace-limit" || a.starts_with("--trace-limit=") {
      let v = match a.strip_prefix("--trace-limit=") {
        some(v) => some(v)
        none => {
          let n = args.get(i)
          i += 1
          n
        }
      }
      let n = match v {
        some(s) => match int.parse(s) {
          ok(n) => n
          err(_) => -1
        }
        none => -1
      }
      if n <= 0 { return fail("--trace-limit needs a positive number") }
      o.limit = some(n)
      limit_seen = true
    } else if a == "--trace-core" {
      o.core = true
    } else if a == "--debug" {
      o.debug = true
    } else if a == "-O" {
      o.opt = true
    } else {
      rest.push(a)
    }
  }
  if o.dest == none && (limit_seen || o.core) {
    return fail("--trace-limit and --trace-core need --trace=json or --trace=<path>")
  }
  (o, rest)
}

/// Load and type-check a program; the error is the rendered diagnostics.
pub fn check_program(cx: resolve.Sources, path: str): typed.TypedProgram! uses fs, ffi {
  let ds = match resolve.load(cx, path) {
    ok(prog) => match check.check_all(prog) {
      (some(tp), _) => {
        var t = tp
        units.erase(&t)
        return t
      }
      (none, ds) => ds
    }
    err(Many(ds)) => ds
  }
  var s: [str] = []
  for d in ds { s.push(d.diag.render(d.file, resolve.source_of(cx, d.file) else "")) }
  fail(s.join(""))
}

/// The program as MIR, its imprints computed first. In `Mode.Test` the entry point runs the
/// root package's tests.
pub fn generate(
  tp: typed.TypedProgram,
  mode: mir.progen.Mode,
  trace: mir.progen.Trace,
): mir.build.Generated! uses fs, env, proc, ffi {
  let emb = mir.build.embeds(tp)
  let imprints = eval_imprints(tp, emb)?
  mir.build.generate(tp, mode, trace, imprints, emb)
}

// ---- compile-time imprints (see src/build.rs) ----

/// Evaluate every imprint of the program at compile time: their values, by constant id. The
/// helper program (`mir.build.imprint_program`) runs JIT-compiled in a forked child (an
/// imprint may panic), writing its records to a file.
pub fn eval_imprints(tp: typed.TypedProgram, emb: {str: [int]}): {int: mir.progen.CVal}! uses fs, env, proc, ffi {
  let (prog, info) = mir.build.imprint_program(tp, emb) else return {}
  // for the port's diffs (scripts/diff_ir.sh): the helper program's MIR text
  match env.get("AUK_IMPRINT_EVAL_IR") {
    some(p) => { let _ = fs.write(p, mir.printer.print_program(prog, info)) }
    none => {}
  }
  let dir = fs.temp_dir()?
  let records = paths.join(dir, "imprints.out")
  let errs = paths.join(dir, "imprints.err")
  let res = imprint_values(tp, prog, info, records, errs)
  let _ = fs.remove(records)
  let _ = fs.remove(errs)
  let _ = fs.remove(dir)
  res
}

/// Run the helper and read its records.
fn imprint_values(
  tp: typed.TypedProgram,
  prog: mir.Program,
  info: mir.types.TyInfo,
  records: str,
  errs: str,
): {int: mir.progen.CVal}! uses fs, env, proc, ffi {
  let code = run_helper(prog, info, records, errs)?
  let data = fs.read_bytes(records) else []
  let stderr = fs.read(errs) else ""
  match mir.build.imprint_results(tp, data, code, stderr) {
    (vals, none) => vals
    (_, some(e)) => fail(e)
  }
}

/// Compile the imprint helper and run it in a forked child: its exit code (none: killed).
fn run_helper(prog: mir.Program, info: mir.types.TyInfo, records: str, errs: str): int?! uses fs, env, proc, ffi {
  let code = backend.jit(prog, info, backend.Level.O0)?
  let entry = orcjit.lookup(code, "dk_entry")?
  let r = posix.run_forked(posix.Redirect { stdout: "/dev/null", stderr: errs }, false, () => orcjit.run(entry, ["imprints", records]))
  orcjit.close(code)
  r
}

/// `auk __jit run|test [--trace-core] <file> [args...]`: compile and run in this process (the
/// trace destination comes from the environment).
pub fn jit_cli(cx: resolve.Sources, args: [str]): int uses fs, env, proc, ffi {
  let mode = match args.get(0) {
    some("run") => mir.progen.Mode.Run
    some("test") => mir.progen.Mode.Test
    _ => {
      eprint("usage: auk __jit run|test [--trace-core] <file> [args...]")
      return 2
    }
  }
  var rest = args.skip(1)
  let core = rest.get(0) == some("--trace-core")
  if core { rest = rest.skip(1) }
  if rest.len() == 0 { return 2 }
  // AUK_SOURCES=<file>: file texts to build instead of the files on disk (`auk hatch`'s
  // candidates; see parse_sources)
  var cx = cx
  match env.get("AUK_SOURCES") {
    some(p) => {
      let m = parse_sources(fs.read_bytes(p) else []) else {
        eprint("error: cannot read the sources in {p}")
        return JIT_BUILD_FAILED
      }
      cx.overrides = m
    }
    none => {}
  }
  jit_child(cx, mode, core, rest[0], rest.skip(1))
}

/// Parse an `AUK_SOURCES` file: records of `<file name>\n<byte length>\n<text>`.
pub fn parse_sources(data: [int]): {str: str}? {
  var m: {str: str} = {}
  var i = 0
  while i < data.len() {
    let (name, a) = sources_line(data, i) else return none
    let (n, b) = sources_line(data, a) else return none
    let len = int.parse(n) else return none
    if len < 0 || b + len > data.len() { return none }
    m[name] = str.from_utf8(data[b..b + len]) else return none
    i = b + len
  }
  some(m)
}

/// The line of `data` starting at `i` and the index after its `\n`.
fn sources_line(data: [int], i: int): (str, int)? {
  var j = i
  while j < data.len() && data[j] != 10 { j += 1 }
  if j >= data.len() { return none }
  let l = str.from_utf8(data[i..j]) else return none
  some((l, j + 1))
}

/// Compile and run `file` with the tracer and debugger as the environment says; exits.
fn jit_child(cx: resolve.Sources, mode: mir.progen.Mode, core: bool, file: str, args: [str]): int uses fs, env, proc, ffi {
  let on = env.get("AUK_TRACE") != none
  let debug = env.get("AUK_DEBUG") != none
  match jit_run(cx, file, args, mode, mir.progen.Trace { on, core, debug, lines: false }, false) {
    ok(code) => {
      posix.exit(code)
      code
    }
    err(e) => {
      posix.eprint_raw("{e}")
      JIT_BUILD_FAILED
    }
  }
}

/// `auk build`: compile `path` (a release build: optimized, no `ensures`, no holes allowed) to
/// an object file and link it with the runtime library into `out`. `debuginfo` (`-g`) adds
/// DWARF line tables (on macOS, in `<out>.dSYM`).
pub fn build_native(cx: resolve.Sources, path: str, out: str, debuginfo: bool): ()! uses fs, env, proc, ffi {
  let tp = check_program(cx, path)?
  var tr = mir.progen.no_trace()
  tr.lines = debuginfo
  let g = generate(tp, mir.progen.Mode.Release, tr)?
  if g.holes.len() > 0 {
    var s = "error: `{path}` still has {g.holes.len()} unfilled hole(s); `auk build` needs a complete program\n"
    for h in g.holes { s = s + "  {h}\n" }
    s = s + "  (fill them in, or use `auk run` / `auk test`, which allow holes)\n"
    return fail(s)
  }
  native.build(g.prog, g.info, out)
}

/// Compile `path` in memory and run it in this process with `args` (`argv[0]` is the file);
/// returns its exit code. `full_opt`: `auk run -O` (a run otherwise gets light optimizations;
/// tests and debugger builds none).
pub fn jit_run(
  cx: resolve.Sources,
  path: str,
  args: [str],
  mode: mir.progen.Mode,
  trace: mir.progen.Trace,
  full_opt: bool,
): int! uses fs, env, proc, ffi {
  let tp = check_program(cx, path)?
  let g = generate(tp, mode, trace)?
  if mode == mir.progen.Mode.Test && g.tests == 0 { eprint("note: {path} has no `test` blocks") }
  let level = if mode != mir.progen.Mode.Run || trace.debug {
    backend.Level.O0
  } else if full_opt {
    backend.Level.O2
  } else {
    backend.Level.Light
  }
  let code = backend.jit(g.prog, g.info, level)?
  let entry = orcjit.lookup(code, "dk_entry")?
  orcjit.run(entry, [path] + args)
}

/// The root file `auk test <dir>` builds: the project's `src/lib.auk` or `src/main.auk`.
fn project_root(dir: str): str! uses fs {
  let proj = resolve.find_project(dir) else return fail("error: {dir} is not inside a project (no raft.toml)\n")
  for f in ["src/lib.auk", "src/main.auk"] {
    if paths.is_file(paths.join(proj, f)) { return paths.join(proj, f) }
  }
  fail("error: the project {proj} has no src/lib.auk or src/main.auk\n")
}

/// The top-level `.auk` files of `dir` that contain `test` blocks, sorted. A file that does not
/// parse is included when a line of it starts with `test ` (its build then reports the errors).
fn flat_test_files(dir: str): [str] uses fs {
  let names = fs.list(dir) else return []
  var files: [str] = []
  for n in names {
    let p = paths.join(dir, n)
    if !paths.is_file(p) || paths.extension(p) != some("auk") { continue }
    let src = fs.read(p) else ""
    let has = match parser.parse(src, false) {
      ok(m) => m.items.any(it => it is Test(_))
      err(_) => mir.progen.rust_lines(src).any(l => l.starts_with("test "))
    }
    if has { files.push(p) }
  }
  files.sort()
}

/// The trace directory of `auk test --trace=<dir>` (created), or `-`.
fn test_trace_dest(trace: TraceOpts, sub: str?): str?! uses fs {
  let d = trace.dest else return none
  if d == "-" { return some("-") }
  let dir = match sub {
    some(s) => paths.join(d, s)
    none => d
  }
  match mkdir_all(dir) {
    ok(_) => some(dir)
    err(e) => fail("error: cannot create the trace directory {dir}: {paths.io_error("{e}")}\n")
  }
}

/// `fs::create_dir_all`.
fn mkdir_all(dir: str): ()! uses fs {
  if dir == "" || fs.is_dir(dir) { return }
  match paths.parent(dir) {
    some(p) => mkdir_all(p)?
    none => {}
  }
  fs.mkdir(dir)?
}

/// `auk test <dir>` on a flat directory: run each file's tests under a header, then print the
/// combined counts. Fails if any test fails or any file does not build. Each file is its own
/// program, compiled and run in a forked child; with `--trace=<dir>`, each file's tests write
/// their traces to `<dir>/<file stem>/`.
fn test_files(cx: resolve.Sources, files: [str], filter: str?, trace: TraceOpts): int uses fs, env, proc, ffi {
  var passed = 0
  var failed = 0
  var broken = 0
  for f in files {
    print("== {paths.file_name(f)}")
    let dest = match test_trace_dest(trace, some(paths.file_stem(f))) {
      ok(d) => d
      err(e) => {
        posix.eprint_raw("{e}")
        return 1
      }
    }
    let out = match fs.temp_dir() {
      ok(d) => d
      err(e) => {
        posix.eprint_raw("error: {e}\n")
        return 1
      }
    }
    let out_file = paths.join(out, "stdout")
    let ran = posix.run_forked(posix.Redirect { stdout: out_file, stderr: none }, true, () => {
      match dest {
        some(d) => apply_here(trace, some(d))
        none => {}
      }
      let args = match filter {
        some(x) => [x]
        none => []
      }
      jit_child(cx, mir.progen.Mode.Test, trace.core, f, args)
    })
    let text = fs.read(out_file) else ""
    let _ = fs.remove(out_file)
    let _ = fs.remove(out)
    let status = match ran {
      ok(s) => s
      err(_) => {
        print("could not run the tests")
        broken += 1
        continue
      }
    }
    posix.print_raw(text)
    // the runner's last line: "<n> passed, <m> failed"
    match counts(text) {
      some((p, m)) => {
        passed += p
        failed += m
        // the runner itself failed (e.g. a leak) although every test passed
        if m == 0 && status != some(0) { broken += 1 }
      }
      none => {
        if status == some(JIT_BUILD_FAILED) { print("did not build") }
        broken += 1
      }
    }
  }
  let n = files.len()
  let plural = if n == 1 { "" } else { "s" }
  let note = if broken > 0 { ", {broken} did not build or run" } else { "" }
  print("== {n} file{plural}{note}: {passed} passed, {failed} failed")
  if failed > 0 || broken > 0 { 1 } else { 0 }
}

/// The counts of the runner's last line, `<n> passed, <m> failed`.
fn counts(text: str): (int, int)? {
  let ls = mir.progen.rust_lines(text)
  let last = ls.last()?
  let parts = last.split(" passed, ")
  if parts.len() != 2 { return none }
  let p = int.parse(parts[0]) else return none
  let m = int.parse(parts[1].strip_suffix(" failed")?) else return none
  if p < 0 || m < 0 { return none }
  (p, m)
}

/// `auk ir`'s own options (before the file): `--llvm[=LEVEL]` (the LLVM IR at a level of
/// `backend.ir_text`, default `o0`), `--dump` (`auk dump mir`; not in the port), `--release` and
/// `-g`; for the port's diffs and timing also `--imprint-eval` (the imprint helper's MIR),
/// `--time` (lowering's time to stderr), `--quiet` and `--repeat N`.
struct IrOpts {
  llvm: str?,
  dump: bool,
  release: bool,
  lines: bool,
  imprint_eval: bool,
  time: bool,
  quiet: bool,
  repeat: int,
}

fn ir_opts(args: [str]): (IrOpts, [str])! {
  var o = IrOpts { llvm: none, dump: false, release: false, lines: false, imprint_eval: false, time: false, quiet: false, repeat: 1 }
  var rest: [str] = []
  var i = 0
  while i < args.len() {
    let a = args[i]
    if a == "--llvm" {
      o.llvm = some("o0")
    } else if a == "--dump" {
      o.dump = true
    } else if a == "--release" {
      o.release = true
    } else if a == "-g" {
      o.lines = true
    } else if a == "--imprint-eval" {
      o.imprint_eval = true
    } else if a == "--time" {
      o.time = true
    } else if a == "--quiet" {
      o.quiet = true
    } else if a == "--repeat" {
      i += 1
      o.repeat = int.parse(args.get(i) else "1") else 1
    } else if a.starts_with("--llvm=") {
      o.llvm = a.strip_prefix("--llvm=")
    } else if !a.starts_with("-") {
      rest = rest + args.skip(i)
      break
    } else {
      rest.push(a)
    }
    i += 1
  }
  if o.dump && o.llvm != none { return fail("--llvm and --dump don't go together") }
  (o, rest)
}

/// `auk run|build|ir|test ...`. Returns the exit code (`run` and `test` exit themselves when
/// the program ran).
pub fn cli(cx: resolve.Sources, cmd: str, args0: [str]): int uses fs, env, proc, time, ffi {
  if cmd == "run" && args0.get(0) == some("--live") {
    eprint("error: `auk run --live` is not in the self-hosted compiler yet")
    return 2
  }
  // `auk ir`'s own options, mixed with the trace flags before the file
  var io = IrOpts { llvm: none, dump: false, release: false, lines: false, imprint_eval: false, time: false, quiet: false, repeat: 1 }
  var args = args0
  if cmd == "ir" {
    match ir_opts(args0) {
      ok((o, rest)) => {
        io = o
        args = rest
      }
      err(e) => {
        eprint("error: {e}")
        return 2
      }
    }
  }
  // trace flags: anywhere for `test`, before the file for `run`/`ir` (not for `build`, which
  // takes `-g`: debug info)
  var debuginfo = false
  var trace = no_trace_opts()
  if cmd == "build" {
    debuginfo = args.contains("-g")
    args = args.filter(a => a != "-g")
  } else {
    match trace_flags(args, cmd != "test") {
      ok((t, rest)) => {
        trace = t
        args = rest
      }
      err(e) => {
        eprint("error: {e}")
        return 2
      }
    }
  }
  if cmd == "test" { return test_cmd(cx, args, trace) }
  if args.len() == 0 {
    let flags = match cmd {
      "build" => ""
      "ir" => "[--llvm[=LEVEL]|--dump] [--release] [-g] [--trace=json|<file>] [--trace-core] [--debug] "
      _ => "[--trace=json|<file>] [--trace-limit N] [--trace-core] "
    }
    eprint("usage: auk {cmd} {flags}<file.auk>")
    return 2
  }
  let path = args[0]
  let rest = args.skip(1)
  if cmd == "ir" { return ir_cmd(cx, path, io, trace) }
  if cmd == "build" {
    let out = if rest.len() == 0 {
      without_extension(path)
    } else if rest.len() == 2 && rest[0] == "-o" {
      rest[1]
    } else {
      eprint("usage: auk build [-g] <file.auk> [-o out]")
      return 2
    }
    return match build_native(cx, path, out, debuginfo) {
      ok(_) => 0
      err(e) => {
        posix.eprint_raw("{e}")
        1
      }
    }
  }
  apply_here(trace, none)
  match jit_run(cx, path, rest, mir.progen.Mode.Run, codegen(trace), trace.opt) {
    ok(code) => {
      posix.exit(code)
      code
    }
    err(e) => {
      posix.eprint_raw("{e}")
      1
    }
  }
}

/// `Path::with_extension("")`: `path` without its last extension.
fn without_extension(path: str): str {
  match paths.extension(path) {
    some(x) => path[0..path.len() - x.len() - 1]
    none => path
  }
}

fn test_cmd(cx: resolve.Sources, args: [str], trace: TraceOpts): int uses fs, env, proc, ffi {
  if args.len() > 2 {
    eprint("usage: auk test [--trace=json|<dir>] [--trace-limit N] [--trace-core] [file|dir] [filter]")
    return 2
  }
  let path = args.get(0) else "."
  let filter = args.get(1)
  var root = path
  if fs.is_dir(path) {
    match project_root(path) {
      ok(r) => root = r
      err(e) => {
        // a flat directory of programs: each file with tests is its own root
        let files = flat_test_files(path)
        if files.len() == 0 {
          posix.eprint_raw("{e}")
          return 1
        }
        return test_files(cx, files, filter, trace)
      }
    }
  }
  let dest = match test_trace_dest(trace, none) {
    ok(d) => d
    err(e) => {
      posix.eprint_raw("{e}")
      return 1
    }
  }
  apply_here(trace, dest)
  let fargs = match filter {
    some(x) => [x]
    none => []
  }
  match jit_run(cx, root, fargs, mir.progen.Mode.Test, codegen(trace), false) {
    ok(code) => {
      posix.exit(code)
      code
    }
    err(e) => {
      posix.eprint_raw("{e}")
      1
    }
  }
}

/// `auk ir`: the MIR as text (or the LLVM IR with `--llvm`).
fn ir_cmd(cx: resolve.Sources, path: str, io: IrOpts, trace: TraceOpts): int uses fs, env, proc, time, ffi {
  if io.dump {
    eprint("error: `auk ir --dump` (`auk dump mir`) is not in the self-hosted compiler")
    return 2
  }
  let tp = match check_program(cx, path) {
    ok(t) => t
    err(e) => {
      posix.eprint_raw("{e}")
      return 1
    }
  }
  let emb = mir.build.embeds(tp)
  if io.imprint_eval {
    match mir.build.imprint_program(tp, emb) {
      some((p, info)) => posix.print_raw(mir.printer.print_program(p, info))
      none => {}
    }
    return 0
  }
  let imprints = match eval_imprints(tp, emb) {
    ok(v) => v
    err(e) => {
      posix.eprint_raw("{e}")
      return 1
    }
  }
  let mode = if io.release { mir.progen.Mode.Release } else { mir.progen.Mode.Run }
  var tr = codegen(trace)
  tr.lines = io.lines
  let t0 = time.now()
  var out = ""
  for _ in 0..io.repeat {
    let g = match mir.build.generate(tp, mode, tr, imprints, emb) {
      ok(g) => g
      err(e) => {
        posix.eprint_raw("{e}")
        return 1
      }
    }
    if io.quiet { continue }
    out = match io.llvm {
      some(level) => match backend.ir_text(g.prog, g.info, level) {
        ok(t) => t
        err(e) => {
          eprint("error: {e}")
          return 1
        }
      }
      none => mir.printer.print_program(g.prog, g.info)
    }
  }
  if io.time { eprint("time: {(time.now() - t0) * 1000 / io.repeat} us") }
  posix.print_raw(out)
  0
}
