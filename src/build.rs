//! The back end driver: TypedProgram → MIR (`mir/`) → machine code with LLVM; and the
//! `run`, `build`, `ir` and `test` commands.
//!
//! `run` and `test` compile in memory (the JIT) and run the program in this process (tests and
//! imprints in forked children); the runtime (`runtime/c`) is linked into the compiler.
//! Debug builds (`run`, `test`, `ir`) check `ensures`; `build` is a release build (optimized, no
//! `ensures`) that refuses a program with holes: it writes an object file and links it with the
//! embedded runtime library (`libauk_rt.a`) using the system linker (`cc`; `AUK_LINKER`
//! overrides it).

use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::{env, fs};

use super::mir::progen::{CVal, Gen, Mode, Trace};
use super::mir::types::TyInfo;
use super::mir::{self, Abi, Body, Ex, MTy, Program, Sel, Stmt};
use super::types::Ty;
use super::diag::Diag;
use super::resolve::ModId;
use super::typed::{BodyRef, ConstId, TypedProgram};

/// The runtime (`runtime/c`) as a static library, built by the cargo build script and linked
/// into every program.
pub const RUNTIME_LIB: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/libauk_rt.a"));

/// Libraries the runtime needs besides libc and libm: the system TLS (tls.c), and dlopen.
pub const LINK_LIBS: &[&str] = if cfg!(target_os = "macos") {
    &["-framework", "CoreFoundation", "-framework", "Security", "-framework", "Network"]
} else {
    &["-ldl", "-lpthread"]
};

/// Export the executable's symbols (the runtime's `auk_*` among them) to `dlsym`, so
/// `ffi.symbol("auk_str_len")` finds them: a compiler written in Auk hands them to the code it
/// JIT-compiles.
pub const EXPORT_DYNAMIC: &str = if cfg!(target_os = "macos") { "-Wl,-export_dynamic" } else { "-rdynamic" };

/// Linker arguments for the C libraries of `[link] libs`: `-l<name>` (a name with a `/` is a
/// path to the library), plus Homebrew's library directories on macOS.
fn user_libs(links: &[String]) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    if links.is_empty() {
        return Ok(out);
    }
    if cfg!(target_os = "macos") {
        for d in ["/opt/homebrew/lib", "/usr/local/lib"] {
            if Path::new(d).is_dir() {
                out.push(format!("-L{d}"));
            }
        }
    }
    for l in links {
        let l = super::resolve::expand_link(l)?;
        out.push(if l.contains('/') { l.clone() } else { format!("-l{l}") });
    }
    Ok(out)
}

/// A generated program (MIR), plus the holes found in it.
pub struct Generated {
    pub prog: Program,
    /// The debug info (`--debug`).
    pub dbg: mir::progen::DbgInfo,
    pub holes: Vec<String>,
    /// The number of tests registered (test mode).
    pub tests: usize,
}

/// The program as MIR. In `Mode::Test` the entry point runs the root package's tests.
pub fn generate(tp: &TypedProgram, mode: Mode, trace: Trace) -> Result<Generated, String> {
    let imprints = eval_imprints(tp)?;
    let mut g = Gen::new(tp, mode);
    g.imprints = imprints;
    g.trace = Trace { debug: false, lines: false, ..trace };
    g.lines = trace.lines;
    g.dbg = mir::progen::Debug { on: trace.debug, core: false };
    let mut tests = Vec::new();
    for (i, inst) in tp.instances.iter().enumerate() {
        // an imprint's initializer ran at compile time; only its value is emitted
        if let BodyRef::Const(c) = inst.body
            && g.imprints.contains_key(&c)
        {
            continue;
        }
        if let BodyRef::Test(t) = inst.body {
            if mode != Mode::Test || !g.in_root_pkg(tp.tests[t].module) {
                continue;
            }
            tests.push((t, i));
        }
        emit(&mut g, i);
        drain(&mut g);
    }
    let i32 = MTy::I32;
    let argv = MTy::void_ptr();
    let entry = g.declare("dk_entry".into(), vec![i32.clone(), argv.clone()], i32.clone(), Abi::C);
    let (mut b, ps) = g.body_for(entry);
    // the tracer starts before the constants are initialized (their initializers are traced too)
    let trace_init = |b: &mut Body, tests: bool| {
        if trace.on {
            b.do_(Ex::rt("auk_trace_init", vec![Ex::new(mir::K::Int(tests as i64), MTy::Bool)], MTy::Void));
        }
    };
    let ntests = tests.len();
    let mut tail: Vec<Stmt> = Vec::new();
    match mode {
        Mode::Test => {
            trace_init(&mut b, true);
            for (t, i) in &tests {
                let f = g.inst_fn(*i);
                tail.push(Stmt::Do(Ex::rt("auk_test_register", vec![Ex::cstr(&tp.tests[*t].name), Ex::fn_addr(f)], MTy::Void)));
            }
            tail.push(Stmt::Ret(Some(Ex::rt("auk_test_main", vec![ps[0].clone(), ps[1].clone()], i32.clone()))));
        }
        _ => {
            let Some(mi) = &tp.main else {
                return Err(format!("error: no `main` function found in `{}` (add `fn main()`; `auk test` runs its tests)\n", tp.program.mods[tp.program.root].file));
            };
            let inst = tp
                .instances
                .iter()
                .position(|x| x.body == BodyRef::Fn(mi.func) && x.type_args.is_empty())
                .ok_or_else(|| "error: main has no instance (compiler bug)\n".to_string())?;
            let f = g.inst_fn(inst);
            let rint = Ty::res(Ty::Int, g.err_ty());
            let shim = g.declare("dk_main_shim".into(), vec![MTy::D(Ty::list(Ty::Str))], MTy::D(rint.clone()), Abi::C);
            let (mut sb, sp) = g.body_for(shim);
            let call = g.call(f, if mi.takes_args { vec![sp[0].clone()] } else { vec![] });
            let ok = |e: Ex| Ex::agg(MTy::D(rint.clone()), vec![(Sel::F(0), Ex::new(mir::K::Int(1), MTy::Bool)), (Sel::F(1), e)]);
            match &mi.ret {
                Ty::Int => sb.emit(Stmt::Ret(Some(ok(call)))),
                Ty::Res(t, _) if t.is_unit() => {
                    let r = sb.decl(call);
                    sb.open_if(g.fld(&r, Sel::F(0)).not());
                    sb.emit(Stmt::Ret(Some(Ex::agg(MTy::D(rint.clone()), vec![(Sel::F(2), g.fld(&r, Sel::F(2)))]))));
                    sb.close();
                    sb.emit(Stmt::Ret(Some(ok(Ex::int(0)))));
                }
                Ty::Res(..) => sb.emit(Stmt::Ret(Some(call))),
                _ => {
                    sb.do_(call);
                    sb.emit(Stmt::Ret(Some(ok(Ex::int(0)))));
                }
            }
            g.define(shim, sb);
            trace_init(&mut b, false);
            tail.push(Stmt::Ret(Some(Ex::rt("auk_main_wrapper", vec![ps[0].clone(), ps[1].clone(), Ex::fn_addr(shim)], i32.clone()))));
        }
    }
    drain(&mut g);
    if g.dbg.on {
        let (info, shows, kids) = dbg_tables(&mut g);
        let addr = |gl| Ex::new(mir::K::GlobalAddr(gl), MTy::void_ptr());
        b.do_(Ex::rt("auk_dbg_init", vec![Ex::cstr(&info), addr(shows), addr(kids)], MTy::Void));
    }
    let (init, cleanup) = g.init_and_cleanup();
    b.do_(g.call(init, vec![]));
    b.do_(Ex::rt("auk_set_cleanup", vec![Ex::fn_addr(cleanup)], MTy::Void));
    for s in tail {
        b.emit(s);
    }
    g.define(entry, b);
    g.prog.entry = Some(entry);
    let holes = g.holes.clone();
    let dbg = std::mem::take(&mut g.dbg_info);
    Ok(Generated { prog: g.prog, dbg, holes, tests: ntests })
}

fn emit(g: &mut Gen, i: usize) {
    if g.emitted.contains(&i) {
        return;
    }
    g.emitted.insert(i);
    mir::lower::emit_instance(g, i);
}

/// The debugger's tables (`--debug`): the debug info as text for `auk_dbg_init` (runtime/c/dbg.c
/// parses it), and a constant array of show functions, one per type of a named local
/// (`AukStr *show(void *value)`). Showing a type can instantiate more (instrumented) code, so
/// this runs to a fixpoint.
fn dbg_tables(g: &mut Gen) -> (String, mir::GlobalId, mir::GlobalId) {
    let mut fns = Vec::new();
    let mut kids = Vec::new();
    while fns.len() < g.dbg_info.types.len() {
        let t = g.dbg_info.types[fns.len()].clone();
        let f = g.declare(format!("dk_dbgshow{}", fns.len()), vec![MTy::void_ptr()], MTy::D(Ty::Str), Abi::C);
        let (mut b, ps) = g.body_for(f);
        let v = ps[0].clone().cast(MTy::ptr(MTy::D(t.clone()))).deref(MTy::D(t.clone()));
        let s = match g.dshow_fn(&t) {
            Some(sf) => g.call_ref(&sf, vec![v], MTy::D(Ty::Str)),
            None => {
                let text = format!("<{}>", g.show_ty(&t));
                Ex::rt("auk_str_from_bytes", vec![Ex::cstr(&text), Ex::int(text.len() as i64)], MTy::D(Ty::Str))
            }
        };
        b.emit(Stmt::Ret(Some(s)));
        g.define(f, b);
        let k = g.dbg_kids_fn(&t, fns.len());
        fns.push(f);
        kids.push(k);
        drain(g);
    }
    let a = g.agg("DkDbgShows".into(), vec![MTy::Code; fns.len().max(1)]);
    let init = Ex::agg(MTy::Agg(a), fns.iter().enumerate().map(|(i, &f)| (Sel::F(i as u32), Ex::fn_addr(f))).collect());
    let shows = g.global("dk_dbgshows".into(), MTy::Agg(a), Some(init), true);
    let a = g.agg("DkDbgKids".into(), vec![MTy::Code; kids.len().max(1)]);
    let init = Ex::agg(MTy::Agg(a), kids.iter().enumerate().map(|(i, k)| (Sel::F(i as u32), k.map_or(Ex::zero(MTy::Code), Ex::fn_addr))).collect());
    let kids_g = g.global("dk_dbgkids".into(), MTy::Agg(a), Some(init), true);
    // the text: `p <file>`, `t <type>`, `f <function>` followed by `v <type> <local>` per
    // frame slot, then `s <fn> <file> <line> <col> <slot,...>` per site (ids in order)
    let info = &g.dbg_info;
    let mut out = String::new();
    let mut files: Vec<&str> = Vec::new();
    for s in &info.sites {
        if !files.contains(&s.file.as_str()) {
            files.push(&s.file);
        }
    }
    for f in &files {
        let abs = fs::canonicalize(f).map(|p| p.display().to_string()).unwrap_or_else(|_| f.to_string());
        let _ = writeln!(out, "p {abs}");
    }
    for t in &info.types {
        let _ = writeln!(out, "t {}", g.show_ty(t).replace('\n', " "));
    }
    for f in &info.fns {
        let _ = writeln!(out, "f {}", f.name);
        for (n, t) in &f.locals {
            let _ = writeln!(out, "v {t} {n}");
        }
    }
    for s in &info.sites {
        let file = files.iter().position(|f| *f == s.file).unwrap_or(0);
        let vis: Vec<String> = s.vis.iter().map(|v| v.to_string()).collect();
        let _ = writeln!(out, "s {} {file} {} {} {}", s.func, s.line, s.col, vis.join(","));
    }
    (out, shows, kids_g)
}

pub(crate) fn drain(g: &mut Gen) {
    while let Some(j) = g.queue.pop() {
        emit(g, j);
    }
}

// ---- compile-time imprints ----
//
// `imprint X = e` is computed at compile time. Every imprint initializer is pure (effects.rs)
// and its type fits `Data` (check.rs), so the compiler builds a helper program from the same
// typed program, in which:
// - each imprint is evaluated through its ordinary lazy constant getter (so imprints may use
//   other imprints and top-level `let`s, in any order); getters write `B<c>` / `E<c>` records
//   when they start and finish computing constant `c`, and `C<c>` (then exit 3) when one is
//   needed while it is being computed: a cycle through function calls (direct cycles are
//   E0115 in the checker);
// - the entry point writes `V<c> <value>` for each imprint: its derived (structural) `to_value`.
// Records go to the file named by argv[1], not stdout (an imprint may `print`); the runtime
// (runtime/c/compiler.c) writes them. A panic (exit 101) is blamed on the innermost imprint
// being computed (E0420). Nothing is cached.

/// Evaluate every imprint of the program at compile time: their values, by constant id.
pub fn eval_imprints(tp: &TypedProgram) -> Result<HashMap<ConstId, CVal>, String> {
    let ids: Vec<ConstId> = (0..tp.consts.len()).filter(|&c| tp.consts[c].imprint).collect();
    if ids.is_empty() {
        return Ok(HashMap::new());
    }
    let mut g = Gen::new(tp, Mode::Run);
    g.imprint_eval = true;
    let entry = g.declare("dk_entry".into(), vec![MTy::I32, MTy::void_ptr()], MTy::I32, Abi::C);
    let (mut b, ps) = g.body_for(entry);
    let mut values = Vec::new();
    for &c in &ids {
        let getter = g.const_getter(c);
        let tov = g.tov_fn(&tp.consts[c].ty);
        values.push((c, getter, tov));
    }
    drain(&mut g);
    let (init, _) = g.init_and_cleanup();
    let bad = Ex::rt("auk__imprint_open", vec![ps[0].clone(), ps[1].clone()], MTy::Bool).not();
    b.open_if(bad);
    b.emit(Stmt::Ret(Some(Ex::int_as(2, MTy::I32))));
    b.close();
    b.do_(g.call(init, vec![]));
    let vt = MTy::D(g.value_ty());
    for (c, getter, tov) in values {
        let v = g.call(getter, vec![]);
        let tv = b.decl(g.call_ref(&tov, vec![v], vt.clone()));
        b.do_(Ex::rt("auk__imprint_value", vec![Ex::i64(c as i64), tv.clone().addr()], MTy::Void));
        b.do_(Ex::rt("auk_value_release", vec![tv], MTy::Void));
    }
    b.do_(Ex::rt("auk__imprint_close", vec![], MTy::Void));
    b.emit(Stmt::Ret(Some(Ex::int_as(0, MTy::I32))));
    g.define(entry, b);
    g.prog.entry = Some(entry);
    let info = TyInfo::new(tp);
    // for the self-hosted port's diffs (scripts/diff_ir.sh): the helper program's MIR text
    if let Ok(p) = env::var("AUK_IMPRINT_EVAL_IR") {
        let _ = fs::write(p, mir::print::print(&g.prog, &info));
    }
    let dir = scratch()?;
    let records = dir.join("imprints.out");
    let errs = dir.join("imprints.err");
    // in a forked child: an imprint may panic (or loop; that is the program's own bug)
    let run = || -> Result<(Option<i32>, String), String> {
        let j = mir::backend::jit(&g.prog, &info, mir::backend::Opt::None)?;
        let args = vec!["imprints".to_string(), records.display().to_string()];
        let code = j.run_forked(&args, mir::backend::Redirect { stdout: Some(Path::new("/dev/null")), stderr: Some(&errs), ..Default::default() })?;
        Ok((code, fs::read_to_string(&errs).unwrap_or_default()))
    };
    let res = run().and_then(|(code, stderr)| imprint_results(tp, &records, code, &stderr));
    // ... and its records, which the port reads instead of running the helper itself
    if let Ok(p) = env::var("AUK_IMPRINT_RECORDS") {
        let _ = fs::copy(&records, p);
    }
    let _ = fs::remove_dir_all(&dir);
    res
}

/// The imprint values from the helper's records (`code`: its exit code, None if killed).
fn imprint_results(tp: &TypedProgram, records: &Path, code: Option<i32>, stderr: &str) -> Result<HashMap<ConstId, CVal>, String> {
    let data = fs::read(records).unwrap_or_default();
    let mut p = Records { b: &data, i: 0 };
    let mut values = HashMap::new();
    let mut stack: Vec<ConstId> = Vec::new();
    let mut cycle = None;
    while p.i < data.len() {
        let tag = p.byte();
        let end = if tag == b'V' { b' ' } else { b'\n' };
        let Some(c) = p.int(end).and_then(|c| usize::try_from(c).ok()).filter(|&c| c < tp.consts.len()) else { break };
        match tag {
            b'B' => stack.push(c),
            b'E' => {
                stack.pop();
            }
            b'C' => cycle = Some(c),
            b'V' => {
                let Some(v) = p.value() else { break };
                values.insert(c, v);
                p.byte();
            }
            _ => break,
        }
    }
    if let Some(c) = cycle {
        let k = &tp.consts[c];
        let d = Diag::new("E0115", k.span, format!("the constant `{}` depends on itself", k.name))
            .note(format!("computing `{}` at compile time needs its own value (through a function call)", k.name))
            .note("break the cycle: give one of the constants a value that doesn't read the other");
        return Err(render_at(tp, k.module, &d));
    }
    if code == Some(101) {
        let (msg, at) = panic_message(stderr);
        // blame the innermost imprint being computed; a `let` it was computing goes in a note
        let Some(c) = stack.iter().rev().copied().find(|&c| tp.consts[c].imprint) else {
            return Err(format!("error: computing the imprints panicked: {msg}\n  at {at}\n"));
        };
        let k = &tp.consts[c];
        let mut d = Diag::new("E0420", k.span, format!("computing `imprint {}` at compile time panicked: {msg}", k.name))
            .note(format!("the panic happened at {at}"));
        if let Some(&top) = stack.last()
            && top != c
        {
            d = d.note(format!("while computing the constant `{}`", tp.consts[top].name));
        }
        return Err(render_at(tp, k.module, &d));
    }
    if code != Some(0) || (0..tp.consts.len()).any(|c| tp.consts[c].imprint && !values.contains_key(&c)) {
        let status = code.map_or("killed by a signal".to_string(), |c| format!("exit status {c}"));
        return Err(format!("error: computing the imprints failed ({status}); this is an auk compiler bug:\n{stderr}"));
    }
    Ok(values)
}

/// The message and location of the last `panic: <msg>\n  at <loc>` in a program's stderr.
fn panic_message(stderr: &str) -> (String, String) {
    let Some(i) = stderr.rfind("panic: ") else { return ("(no message)".into(), "<unknown>".into()) };
    let mut lines = stderr[i + 7..].lines();
    let msg = lines.next().unwrap_or("").to_string();
    let at = lines.next().and_then(|l| l.trim().strip_prefix("at ")).unwrap_or("<unknown>").to_string();
    (msg, at)
}

fn render_at(tp: &TypedProgram, m: ModId, d: &Diag) -> String {
    let md = &tp.program.mods[m];
    d.render(&md.file, &md.src)
}

/// A reader of the imprint helper's records.
struct Records<'b> {
    b: &'b [u8],
    i: usize,
}

impl Records<'_> {
    fn byte(&mut self) -> u8 {
        let c = self.b.get(self.i).copied().unwrap_or(0);
        self.i += 1;
        c
    }

    /// A decimal integer up to (and past) the terminator `end`.
    fn int(&mut self, end: u8) -> Option<i64> {
        let start = self.i;
        while self.i < self.b.len() && self.b[self.i] != end {
            self.i += 1;
        }
        let n = std::str::from_utf8(&self.b[start..self.i]).ok()?.parse().ok()?;
        self.i += 1;
        Some(n)
    }

    fn value(&mut self) -> Option<CVal> {
        Some(match self.byte() {
            b'N' => CVal::Null,
            b'T' => CVal::Bool(true),
            b'F' => CVal::Bool(false),
            b'I' => CVal::Int(self.int(b';')?),
            b'D' => {
                let hex = std::str::from_utf8(self.b.get(self.i..self.i + 16)?).ok()?;
                let bits = u64::from_str_radix(hex, 16).ok()?;
                self.i += 16;
                if self.byte() != b';' {
                    return None;
                }
                CVal::Float(f64::from_bits(bits))
            }
            b'S' => CVal::Str(self.str_body()?),
            b'L' => {
                let n = self.int(b';')?;
                let mut xs = Vec::new();
                for _ in 0..n {
                    xs.push(self.value()?);
                }
                CVal::List(xs)
            }
            b'M' => {
                let n = self.int(b';')?;
                let mut es = Vec::new();
                for _ in 0..n {
                    if self.byte() != b'S' {
                        return None;
                    }
                    let k = self.str_body()?;
                    es.push((k, self.value()?));
                }
                CVal::Map(es)
            }
            _ => return None,
        })
    }

    fn str_body(&mut self) -> Option<String> {
        let n = usize::try_from(self.int(b':')?).ok()?;
        let bytes = self.b.get(self.i..self.i + n)?;
        self.i += n;
        Some(String::from_utf8_lossy(bytes).into_owned())
    }
}

static BUILD_N: AtomicUsize = AtomicUsize::new(0);

/// A fresh scratch directory for one build.
fn scratch() -> Result<PathBuf, String> {
    let n = BUILD_N.fetch_add(1, Ordering::Relaxed);
    let d = env::temp_dir().join(format!("auk-build-{}-{n}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).map_err(|e| format!("error: cannot create {}: {e}\n", d.display()))?;
    Ok(d)
}

/// The exit status of `auk __jit` when the program doesn't compile.
pub const JIT_BUILD_FAILED: i32 = 125;

/// `auk __jit run|test [--trace-core] <file> [args...]`: compile and run in this process (the
/// trace destination comes from the environment). For drivers that need the program in a
/// child process of its own: flat test directories, `auk hatch`, `auk dive`.
pub fn jit_cli(args: &[String]) -> i32 {
    let (mode, rest) = match args.split_first() {
        Some((m, rest)) if m == "run" => (Mode::Run, rest),
        Some((m, rest)) if m == "test" => (Mode::Test, rest),
        _ => {
            eprintln!("usage: auk __jit run|test [--trace-core] <file> [args...]");
            return 2;
        }
    };
    let (core, rest) = match rest.split_first() {
        Some((f, r)) if f == "--trace-core" => (true, r),
        _ => (false, rest),
    };
    let Some((file, args)) = rest.split_first() else { return 2 };
    let on = env::var_os("AUK_TRACE").is_some();
    let debug = env::var_os("AUK_DEBUG").is_some();
    match jit_run(Path::new(file), args, mode, Trace { on, core, debug, lines: false }, false) {
        Ok(code) => exit_now(code),
        Err(e) => {
            eprint!("{e}");
            JIT_BUILD_FAILED
        }
    }
}

/// `auk build`: compile `path` (a release build: optimized, no `ensures`, no holes allowed)
/// to an object file with LLVM and link it with the runtime library into `out`. The
/// linker is the system C compiler driver (`cc`; `AUK_LINKER` overrides it).
/// `auk build`: `debuginfo` (`-g`) adds DWARF line tables (on macOS, in `<out>.dSYM`).
pub fn build_native(path: &Path, out: &Path, debuginfo: bool) -> Result<(), String> {
    let tp = check(path)?;
    let g = generate(&tp, Mode::Release, Trace { lines: debuginfo, ..Trace::default() })?;
    if !g.holes.is_empty() {
        let mut s = format!("error: `{}` still has {} unfilled hole(s); `auk build` needs a complete program\n", path.display(), g.holes.len());
        for h in &g.holes {
            let _ = writeln!(s, "  {h}");
        }
        s.push_str("  (fill them in, or use `auk run` / `auk test`, which allow holes)\n");
        return Err(s);
    }
    let info = TyInfo::new(&tp);
    let obj = mir::backend::object(&g.prog, &info, true).map_err(|e| format!("error: code generation failed (this is an auk compiler bug): {e}\n"))?;
    let dir = scratch()?;
    let res = (|| {
        let o = dir.join("prog.o");
        fs::write(&o, obj).map_err(|e| format!("error: cannot write {}: {e}\n", o.display()))?;
        let lib = dir.join("libauk_rt.a");
        fs::write(&lib, RUNTIME_LIB).map_err(|e| format!("error: cannot write the runtime library: {e}\n"))?;
        let linker = env::var("AUK_LINKER").unwrap_or_else(|_| "cc".into());
        let output = Command::new(&linker)
            .arg(&o)
            .arg(&lib)
            .args(user_libs(&g.prog.links)?)
            .args(LINK_LIBS)
            .args(["-lm", "-lpthread"])
            .arg(EXPORT_DYNAMIC)
            .arg("-o")
            .arg(out)
            .output()
            .map_err(|e| format!("error: cannot run the linker `{linker}`: {e}\n"))?;
        if !output.status.success() {
            return Err(format!("error: linking failed:\n{}", String::from_utf8_lossy(&output.stderr)));
        }
        // the macOS linker leaves DWARF in the object file (deleted below): gather it first
        if debuginfo && cfg!(target_os = "macos") {
            let r = Command::new("dsymutil").arg(out).output().map_err(|e| format!("error: cannot run dsymutil (for -g): {e}\n"))?;
            if !r.status.success() {
                return Err(format!("error: dsymutil failed:\n{}", String::from_utf8_lossy(&r.stderr)));
            }
        }
        Ok(())
    })();
    let _ = fs::remove_dir_all(&dir);
    res
}

/// Compile `path` in memory and run it in this process with `args` (`argv[0]` is the file);
/// returns its exit code. `full_opt`: `auk run -O` (a run otherwise gets light optimizations;
/// tests and debugger builds none).
pub fn jit_run(path: &Path, args: &[String], mode: Mode, trace: Trace, full_opt: bool) -> Result<i32, String> {
    let tp = check(path)?;
    let mut g = generate(&tp, mode, trace)?;
    if trace.debug {
        // a debugger may evaluate expressions at its stops
        super::dbg_eval::install(path, &tp, std::mem::take(&mut g.dbg));
    }
    if mode == Mode::Test && g.tests == 0 {
        eprintln!("note: {} has no `test` blocks", path.display());
    }
    let info = TyInfo::new(&tp);
    let opt = match mode {
        Mode::Run if trace.debug => mir::backend::Opt::None,
        Mode::Run if full_opt => mir::backend::Opt::Full,
        Mode::Run => mir::backend::Opt::Light,
        _ => mir::backend::Opt::None,
    };
    let j = mir::backend::jit(&g.prog, &info, opt)?;
    let mut argv = vec![path.display().to_string()];
    argv.extend(args.iter().cloned());
    Ok(j.run(&argv))
}

/// End the process as a C program returning from `main` would: flush C stdio, run `atexit`
/// handlers (the tracer's), exit with `code`.
pub fn exit_now(code: i32) -> ! {
    unsafe { libc::exit(code) }
}

/// Load and type-check a program.
pub fn check(path: &Path) -> Result<TypedProgram, String> {
    let r = super::resolve::load(path).and_then(super::check::check);
    r.map_err(|ds| {
        let mut s = String::new();
        for d in &ds {
            let src = super::resolve::source_of(&d.file).unwrap_or_default();
            s += &d.diag.render(&d.file, &src);
        }
        s
    })
}

/// The root file `auk test <dir>` builds: the project's `src/lib.auk` or `src/main.auk`.
fn project_root(dir: &Path) -> Result<PathBuf, String> {
    let proj = super::resolve::find_project(dir).ok_or_else(|| format!("error: {} is not inside a project (no raft.toml)\n", dir.display()))?;
    for f in ["src/lib.auk", "src/main.auk"] {
        if proj.join(f).is_file() {
            return Ok(proj.join(f));
        }
    }
    Err(format!("error: the project {} has no src/lib.auk or src/main.auk\n", proj.display()))
}

/// The top-level `.auk` files of `dir` that contain `test` blocks, sorted. A file that does not
/// parse is included when a line of it starts with `test ` (its build then reports the errors).
fn flat_test_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(rd) = fs::read_dir(dir) else { return Vec::new() };
    let mut files: Vec<PathBuf> = rd
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_file() && p.extension().is_some_and(|x| x == "auk"))
        .filter(|p| {
            let src = fs::read_to_string(p).unwrap_or_default();
            match super::parser::parse(&src) {
                Ok(m) => m.items.iter().any(|i| matches!(i, super::ast::Item::Test(_))),
                Err(_) => src.lines().any(|l| l.starts_with("test ")),
            }
        })
        .collect();
    files.sort();
    files
}

/// `auk ir`'s own options (before the file): `--llvm[=LEVEL]` (LLVM IR at a level of
/// `mir::backend::llvm_ir_at`, default `o0`), `--dump` (`auk dump mir`), `--release` (the MIR
/// `auk build` compiles: no `ensures`) and `-g` (with source locations, as `auk build -g`).
#[derive(Debug, Default)]
struct IrOpts {
    llvm: Option<String>,
    dump: bool,
    release: bool,
    lines: bool,
}

impl IrOpts {
    fn parse(&mut self, args: &[String]) -> Result<Vec<String>, String> {
        let mut rest = Vec::new();
        for (i, a) in args.iter().enumerate() {
            match a.as_str() {
                "--llvm" => self.llvm = Some("o0".into()),
                "--dump" => self.dump = true,
                "--release" => self.release = true,
                "-g" => self.lines = true,
                _ if a.starts_with("--llvm=") => self.llvm = Some(a["--llvm=".len()..].to_string()),
                _ if !a.starts_with('-') => {
                    rest.extend(args[i..].iter().cloned());
                    break;
                }
                _ => rest.push(a.clone()),
            }
        }
        if self.dump && self.llvm.is_some() {
            return Err("--llvm and --dump don't go together".into());
        }
        Ok(rest)
    }
}

/// `auk dump mir [ir options] <file>`: the program's MIR, machine-readable (`mir/dump.rs`).
pub fn dump_mir(args: &[String]) -> i32 {
    let mut a = vec!["--dump".to_string()];
    a.extend(args.iter().cloned());
    cli("ir", &a)
}

/// Execution-trace options of `auk run|test|ir` (`--trace=json|<path>`, `--trace-limit N`,
/// `--trace-core`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TraceOpts {
    /// Where events go: `-` (stderr; `json` on the command line) or a path (`run`: a file;
    /// `test`: a directory with one `<test>.jsonl` per test). None: not tracing.
    pub dest: Option<String>,
    /// The most events written (the runtime default, 10,000, when None).
    pub limit: Option<u64>,
    /// Trace core library functions too.
    pub core: bool,
    /// `--debug`: instrument the program for the debugger (runtime/c/dbg.c).
    pub debug: bool,
    /// `-O` (`auk run`): the full optimizer.
    pub opt: bool,
}

impl TraceOpts {
    /// The codegen flag.
    pub fn codegen(&self) -> Trace {
        Trace { on: self.dest.is_some(), core: self.core, debug: self.debug, lines: false }
    }

    /// Configure the environment of a traced program (`dest` overrides `self.dest`).
    /// Configure the tracer of a program run in this process (the JIT).
    pub fn apply_here(&self, dest: Option<&str>) {
        let Some(d) = dest.or(self.dest.as_deref()) else { return };
        // SAFETY: the compiler is single-threaded when it starts the program
        unsafe {
            env::set_var("AUK_TRACE", d);
            match self.limit {
                Some(n) => env::set_var("AUK_TRACE_LIMIT", n.to_string()),
                None => env::remove_var("AUK_TRACE_LIMIT"),
            }
        }
    }

    pub fn apply(&self, cmd: &mut Command, dest: Option<&str>) {
        let Some(d) = dest.or(self.dest.as_deref()) else { return };
        cmd.env("AUK_TRACE", d);
        match self.limit {
            Some(n) => cmd.env("AUK_TRACE_LIMIT", n.to_string()),
            None => cmd.env_remove("AUK_TRACE_LIMIT"),
        };
    }
}

/// Split the trace flags off `args`: anywhere in them, or (`leading`) only before the first
/// other argument (`auk run`'s program arguments may look like flags).
pub fn trace_flags(args: &[String], leading: bool) -> Result<(TraceOpts, Vec<String>), String> {
    let mut o = TraceOpts::default();
    let mut rest = Vec::new();
    let mut limit_seen = false;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if leading && !rest.is_empty() {
            rest.push(a.clone());
            continue;
        }
        if a == "--trace" || a == "--trace=json" || a == "--trace=-" {
            o.dest = Some("-".into());
        } else if let Some(p) = a.strip_prefix("--trace=") {
            if p.is_empty() {
                return Err("--trace= needs `json` or a path".into());
            }
            o.dest = Some(p.into());
        } else if a == "--trace-limit" || a.starts_with("--trace-limit=") {
            let v = match a.strip_prefix("--trace-limit=") {
                Some(v) => Some(v.to_string()),
                None => it.next().cloned(),
            };
            o.limit = Some(v.and_then(|v| v.parse::<u64>().ok()).filter(|&n| n > 0).ok_or("--trace-limit needs a positive number")?);
            limit_seen = true;
        } else if a == "--trace-core" {
            o.core = true;
        } else if a == "--debug" {
            o.debug = true;
        } else if a == "-O" {
            o.opt = true;
        } else {
            rest.push(a.clone());
        }
    }
    if o.dest.is_none() && (limit_seen || o.core) {
        return Err("--trace-limit and --trace-core need --trace=json or --trace=<path>".into());
    }
    Ok((o, rest))
}

/// The trace directory of `auk test --trace=<dir>` (created), or `-`.
fn test_trace_dest(trace: &TraceOpts, sub: Option<&str>) -> Result<Option<String>, String> {
    match trace.dest.as_deref() {
        None => Ok(None),
        Some("-") => Ok(Some("-".into())),
        Some(d) => {
            let dir = match sub {
                Some(s) => Path::new(d).join(s),
                None => PathBuf::from(d),
            };
            fs::create_dir_all(&dir).map_err(|e| format!("error: cannot create the trace directory {}: {e}\n", dir.display()))?;
            Ok(Some(dir.display().to_string()))
        }
    }
}

/// `auk test <dir>` on a flat directory: run each file's tests under a header, then print the
/// combined counts. Fails if any test fails or any file does not build. With `--trace=<dir>`,
/// each file's tests write their traces to `<dir>/<file stem>/`.
fn test_files(files: &[PathBuf], filter: Option<&str>, trace: &TraceOpts) -> i32 {
    let (mut passed, mut failed, mut broken) = (0u64, 0u64, 0usize);
    for f in files {
        let name = f.file_name().map_or_else(|| f.display().to_string(), |n| n.to_string_lossy().into_owned());
        println!("== {name}");
        let _ = std::io::Write::flush(&mut std::io::stdout());
        let stem = f.file_stem().map(|s| s.to_string_lossy().into_owned());
        let dest = match test_trace_dest(trace, stem.as_deref()) {
            Ok(d) => d,
            Err(e) => {
                eprint!("{e}");
                return 1;
            }
        };
        // each file is its own program, in a process of its own
        let mut cmd = Command::new(env::current_exe().unwrap_or_else(|_| "auk".into()));
        cmd.arg("__jit").arg("test").args(trace.core.then_some("--trace-core")).arg(f);
        cmd.args(filter).stderr(std::process::Stdio::inherit());
        trace.apply(&mut cmd, dest.as_deref());
        let out = cmd.output();
        let Ok(out) = out else {
            println!("could not run the tests");
            broken += 1;
            continue;
        };
        let text = String::from_utf8_lossy(&out.stdout);
        print!("{text}");
        // the runner's last line: "<n> passed, <m> failed"
        let counts = text.lines().last().and_then(|l| {
            let (p, rest) = l.split_once(" passed, ")?;
            Some((p.parse::<u64>().ok()?, rest.strip_suffix(" failed")?.parse::<u64>().ok()?))
        });
        match counts {
            Some((p, m)) => {
                passed += p;
                failed += m;
                // the runner itself failed (e.g. a leak) although every test passed
                if m == 0 && !out.status.success() {
                    broken += 1;
                }
            }
            None => {
                if out.status.code() == Some(JIT_BUILD_FAILED) {
                    println!("did not build");
                }
                broken += 1
            }
        }
    }
    let files_n = files.len();
    let plural = if files_n == 1 { "" } else { "s" };
    let broken_note = if broken > 0 { format!(", {broken} did not build or run") } else { String::new() };
    println!("== {files_n} file{plural}{broken_note}: {passed} passed, {failed} failed");
    if failed > 0 || broken > 0 { 1 } else { 0 }
}

/// `auk run|build|ir|test ...`. Returns the exit code.
pub fn cli(cmd: &str, args: &[String]) -> i32 {
    if cmd == "run" && args.first().is_some_and(|a| a == "--live") {
        return crate::live::cli(&args[1..]);
    }
    let fail = |msg: String| {
        eprint!("{msg}");
        1
    };
    // trace flags: anywhere for `test`, before the file for `run`/`ir` (not for `build`, which
    // takes `-g`: debug info)
    let mut debuginfo = false;
    // `auk ir`'s own options (`--llvm[=LEVEL]`: the LLVM IR instead of the MIR; `--dump`: the
    // MIR as `auk dump mir` writes it), mixed with the trace flags before the file
    let mut ir_opts = IrOpts::default();
    let ir_args;
    let args = if cmd == "ir" {
        ir_args = match ir_opts.parse(args) {
            Ok(rest) => rest,
            Err(e) => {
                eprintln!("error: {e}");
                return 2;
            }
        };
        &ir_args[..]
    } else {
        args
    };
    let (trace, args) = if cmd == "build" {
        debuginfo = args.iter().any(|a| a == "-g");
        (TraceOpts::default(), args.iter().filter(|a| *a != "-g").cloned().collect())
    } else {
        match trace_flags(args, cmd != "test") {
            Ok(x) => x,
            Err(e) => {
                eprintln!("error: {e}");
                return 2;
            }
        }
    };
    match cmd {
        "test" => {
            let (path, filter) = match args.as_slice() {
                [] => (PathBuf::from("."), None),
                [p] => (PathBuf::from(p), None),
                [p, f] => (PathBuf::from(p), Some(f.clone())),
                _ => {
                    eprintln!("usage: auk test [--trace=json|<dir>] [--trace-limit N] [--trace-core] [file|dir] [filter]");
                    return 2;
                }
            };
            let root = if path.is_dir() {
                match project_root(&path) {
                    Ok(r) => r,
                    Err(e) => {
                        // a flat directory of programs: each file with tests is its own root
                        let files = flat_test_files(&path);
                        if files.is_empty() {
                            return fail(e);
                        }
                        return test_files(&files, filter.as_deref(), &trace);
                    }
                }
            } else {
                path
            };
            let dest = match test_trace_dest(&trace, None) {
                Ok(d) => d,
                Err(e) => return fail(e),
            };
            trace.apply_here(dest.as_deref());
            match jit_run(&root, filter.as_slice(), Mode::Test, trace.codegen(), false) {
                Ok(code) => exit_now(code),
                Err(e) => fail(e),
            }
        }
        "run" | "build" | "ir" => {
            let args = &args[..];
            let [file, rest @ ..] = args else {
                let flags = match cmd {
                    "build" => "",
                    "ir" => "[--llvm[=LEVEL]|--dump] [--release] [-g] [--trace=json|<file>] [--trace-core] [--debug] ",
                    _ => "[--trace=json|<file>] [--trace-limit N] [--trace-core] ",
                };
                eprintln!("usage: auk {cmd} {flags}<file.auk>");
                return 2;
            };
            let path = Path::new(file);
            match cmd {
                "ir" => {
                    let tp = match check(path) {
                        Ok(t) => t,
                        Err(e) => return fail(e),
                    };
                    let mode = if ir_opts.release { Mode::Release } else { Mode::Run };
                    let g = match generate(&tp, mode, Trace { lines: ir_opts.lines, ..trace.codegen() }) {
                        Ok(g) => g,
                        Err(e) => return fail(e),
                    };
                    let info = TyInfo::new(&tp);
                    if ir_opts.dump {
                        print!("{}", mir::dump::dump(&g.prog, &tp));
                    } else if let Some(level) = &ir_opts.llvm {
                        match mir::backend::llvm_ir_at(&g.prog, &info, level) {
                            Ok(t) => print!("{t}"),
                            Err(e) => return fail(format!("error: {e}\n")),
                        }
                    } else {
                        print!("{}", mir::print::print(&g.prog, &info));
                    }
                    0
                }
                "build" => {
                    let out = match rest {
                        [] => path.with_extension(""),
                        [flag, out] if flag == "-o" => PathBuf::from(out),
                        _ => {
                            eprintln!("usage: auk build [-g] <file.auk> [-o out]");
                            return 2;
                        }
                    };
                    match build_native(path, &out, debuginfo) {
                        Ok(()) => 0,
                        Err(e) => fail(e),
                    }
                }
                _ => {
                    trace.apply_here(None);
                    match jit_run(path, rest, Mode::Run, trace.codegen(), trace.opt) {
                        Ok(code) => exit_now(code),
                        Err(e) => fail(e),
                    }
                }
            }
        }
        _ => unreachable!("auk {cmd} is not a build command"),
    }
}
