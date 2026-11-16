//! The back end driver: TypedProgram → one C file → clang (with the embedded C runtime) →
//! a native executable; and the `run`, `build`, `ir` and `test` commands.
//!
//! The runtime sources are compiled into the compiler (`include_str!`) and written to a fresh
//! temporary directory for each build together with the generated `prog.c` (nothing is cached).
//! `CLANG` overrides the C compiler. Debug builds (`run`, `test`, `ir`) check `ensures` and use
//! `-O1`; `build` is a release build (`-O2`, no `ensures`) and refuses a program with holes.
//! `DUCK_CFLAGS` adds C compiler flags (e.g. sanitizers); `DUCK_KEEP_C=<path>` saves the
//! generated C of each build.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::{env, fs};

use super::cgen::{CVal, Gen, Mode, Trace, c_str};
use super::lower;
use super::diag::Diag;
use super::resolve::ModId;
use super::typed::{BodyRef, ConstId, TypedProgram};

/// The C runtime, embedded: (file name, contents).
pub const RUNTIME: &[(&str, &str)] = &[
    ("duck.h", include_str!("../runtime/duck.h")),
    ("duck_internal.h", include_str!("../runtime/duck_internal.h")),
    ("arr.c", include_str!("../runtime/arr.c")),
    ("core.c", include_str!("../runtime/core.c")),
    ("err.c", include_str!("../runtime/err.c")),
    ("map.c", include_str!("../runtime/map.c")),
    ("rc.c", include_str!("../runtime/rc.c")),
    ("str.c", include_str!("../runtime/str.c")),
    ("task.c", include_str!("../runtime/task.c")),
    ("testing.c", include_str!("../runtime/testing.c")),
    ("tls.c", include_str!("../runtime/tls.c")),
    ("trace.c", include_str!("../runtime/trace.c")),
    ("value.c", include_str!("../runtime/value.c")),
];

/// Libraries the runtime links besides libc and libm: the platform TLS stack on macOS
/// (runtime/tls.c; always part of the SDK); elsewhere `-ldl`, since tls.c loads OpenSSL with
/// `dlopen` at run time, so a build never needs it installed.
pub const LINK_LIBS: &[&str] = if cfg!(target_os = "macos") {
    &["-framework", "Network", "-framework", "Security", "-framework", "CoreFoundation"]
} else {
    &["-ldl"]
};

/// The generated C for a type-checked program, plus the holes found in it.
pub struct Output {
    pub c: String,
    pub holes: Vec<String>,
    /// The number of tests registered (test mode).
    pub tests: usize,
}

/// Generate the C program. In `Mode::Test` the entry point runs the root package's tests.
pub fn generate(tp: &TypedProgram, mode: Mode) -> Result<Output, String> {
    generate_traced(tp, mode, Trace::default())
}

/// `generate`, with execution-trace instrumentation when `trace.on`.
pub fn generate_traced(tp: &TypedProgram, mode: Mode, trace: Trace) -> Result<Output, String> {
    let imprints = eval_imprints(tp)?;
    let mut g = Gen::new(tp, mode);
    g.imprints = imprints;
    g.trace = trace;
    // the tracer starts before the constants are initialized (their initializers are traced too)
    let trace_init = |tests: bool| if trace.on { format!("    duck_trace_init({});
", u8::from(tests)) } else { String::new() };
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
        while let Some(j) = g.queue.pop() {
            emit(&mut g, j);
        }
    }
    let entry = match mode {
        Mode::Test => {
            let mut s = format!("int main(int argc, char **argv) {{\n{}    dk_init();\n    duck_set_cleanup(dk_cleanup);\n", trace_init(true));
            for (t, i) in &tests {
                let f = g.inst_fn(*i);
                let _ = writeln!(s, "    duck_test_register({}, {f});", c_str(&tp.tests[*t].name));
            }
            s.push_str("    return duck_test_main(argc, argv);\n}\n");
            s
        }
        _ => {
            let Some(mi) = &tp.main else {
                return Err(format!("error: no `main` function found in `{}` (add `fn main()`; `duck test` runs its tests)\n", tp.program.mods[tp.program.root].file));
            };
            let inst = tp
                .instances
                .iter()
                .position(|x| x.body == BodyRef::Fn(mi.func) && x.type_args.is_empty())
                .ok_or_else(|| "error: main has no instance (compiler bug)\n".to_string())?;
            let f = g.inst_fn(inst);
            let call = if mi.takes_args { format!("{f}(args)") } else { format!("{f}()") };
            let body = match &mi.ret {
                Ty::Int => format!("    return DUCK_OK(DuckRes_int, {call});"),
                Ty::Res(t, _) if t.is_unit() => {
                    format!("    DuckRes_unit r = {call};\n    if (!r.ok) return DUCK_ERR(DuckRes_int, r.err);\n    return DUCK_OK(DuckRes_int, 0);")
                }
                Ty::Res(..) => format!("    return {call};"),
                _ => format!("    {call};\n    return DUCK_OK(DuckRes_int, 0);"),
            };
            let init = trace_init(false);
            format!(
                "static DuckRes_int dk_main_shim(DuckArr *args) {{\n    (void)args;\n{body}\n}}\nint main(int argc, char **argv) {{\n{init}    dk_init();\n    duck_set_cleanup(dk_cleanup);\n    return duck_main_wrapper(argc, argv, dk_main_shim);\n}}\n"
            )
        }
    };
    while let Some(j) = g.queue.pop() {
        emit(&mut g, j);
    }
    let holes = g.holes.clone();
    let ntests = tests.len();
    Ok(Output { c: g.finish(&entry), holes, tests: ntests })
}

use super::types::Ty;

fn emit(g: &mut Gen, i: usize) {
    if g.emitted.contains(&i) {
        return;
    }
    g.emitted.insert(i);
    lower::emit_instance(g, i);
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
// - `main` writes `V<c> <value>` for each imprint: its derived (structural) `to_value`.
// Records go to the file named by argv[1], not stdout (an imprint may `print`). A value is
// `N`, `T`, `F`, `I<int>;`, `D<16 hex digits: the f64 bits>;`, `S<n>:<n bytes>`,
// `L<n>;<n values>` or `M<n>;<n (S-key, value) pairs>`. A panic (exit 101) is blamed on the
// innermost imprint being computed (E0420). Nothing is cached.

/// The helper's writer of a `Value` tree.
const DUMP_C: &str = r#"static void dk_dump(DuckValue v) {
    switch (v.tag) {
    case DUCK_V_NULL: fputc('N', dk_out); break;
    case DUCK_V_BOOL: fputc(v.u.b ? 'T' : 'F', dk_out); break;
    case DUCK_V_INT: fprintf(dk_out, "I%lld;", (long long)v.u.i); break;
    case DUCK_V_FLOAT: {
        uint64_t bits;
        memcpy(&bits, &v.u.f, sizeof bits);
        fprintf(dk_out, "D%016llx;", (unsigned long long)bits);
        break;
    }
    case DUCK_V_STR: {
        int64_t n = v.u.s ? v.u.s->len_bytes : 0;
        fprintf(dk_out, "S%lld:", (long long)n);
        if (n) fwrite(v.u.s->data, 1, (size_t)n, dk_out);
        break;
    }
    case DUCK_V_LIST:
        fprintf(dk_out, "L%lld;", (long long)duck_arr_len(v.u.list));
        for (int64_t i = 0; i < duck_arr_len(v.u.list); i++) dk_dump(*(DuckValue *)duck_arr_at(v.u.list, i, NULL));
        break;
    case DUCK_V_MAP: {
        fprintf(dk_out, "M%lld;", (long long)duck_map_len(v.u.map));
        int64_t it = 0;
        void *kp, *vp;
        while (duck_map_next(v.u.map, &it, &kp, &vp)) {
            DuckStr *k = *(DuckStr **)kp;
            int64_t n = k ? k->len_bytes : 0;
            fprintf(dk_out, "S%lld:", (long long)n);
            if (n) fwrite(k->data, 1, (size_t)n, dk_out);
            dk_dump(*(DuckValue *)vp);
        }
        break;
    }
    }
}
"#;

/// Evaluate every imprint of the program at compile time: their values, by constant id.
pub fn eval_imprints(tp: &TypedProgram) -> Result<HashMap<ConstId, CVal>, String> {
    let ids: Vec<ConstId> = (0..tp.consts.len()).filter(|&c| tp.consts[c].imprint).collect();
    if ids.is_empty() {
        return Ok(HashMap::new());
    }
    let mut g = Gen::new(tp, Mode::Run);
    g.imprint_eval = true;
    g.ops_defs.push_str("static FILE *dk_out;\n");
    let mut body = String::new();
    for &c in &ids {
        let getter = g.const_getter(c);
        let tov = g.tov_fn(&tp.consts[c].ty);
        let _ = writeln!(
            body,
            "    {{\n        DuckValue v = {tov}({getter}());\n        fputs(\"V{c} \", dk_out);\n        dk_dump(v);\n        fputs(\"\\n\", dk_out);\n        fflush(dk_out);\n        duck_value_release(v);\n    }}"
        );
    }
    while let Some(j) = g.queue.pop() {
        emit(&mut g, j);
    }
    let entry = format!(
        "{DUMP_C}int main(int argc, char **argv) {{\n    if (argc < 2 || !(dk_out = fopen(argv[1], \"wb\"))) return 2;\n    dk_init();\n{body}    fclose(dk_out);\n    return 0;\n}}\n"
    );
    let c = g.finish(&entry);
    let dir = scratch()?;
    let res = run_imprint_helper(tp, &dir, &c);
    let _ = fs::remove_dir_all(&dir);
    res
}

fn run_imprint_helper(tp: &TypedProgram, dir: &Path, c: &str) -> Result<HashMap<ConstId, CVal>, String> {
    let exe = dir.join("imprints");
    cc_in(dir, c, &exe, Mode::Run, &[], false)?;
    let records = dir.join("imprints.out");
    let out = Command::new(&exe).arg(&records).output().map_err(|e| format!("error: cannot run the imprint helper: {e}\n"))?;
    let data = fs::read(&records).unwrap_or_default();
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
    let stderr = String::from_utf8_lossy(&out.stderr);
    if out.status.code() == Some(101) {
        let (msg, at) = panic_message(&stderr);
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
    if !out.status.success() || (0..tp.consts.len()).any(|c| tp.consts[c].imprint && !values.contains_key(&c)) {
        let status = out.status.code().map_or("killed by a signal".to_string(), |c| format!("exit status {c}"));
        return Err(format!("error: computing the imprints failed ({status}); this is a duck compiler bug:\n{stderr}"));
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
    let d = env::temp_dir().join(format!("duck-build-{}-{n}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).map_err(|e| format!("error: cannot create {}: {e}\n", d.display()))?;
    Ok(d)
}

/// Compile generated C with the runtime into `out`.
pub fn cc(c: &str, out: &Path, mode: Mode, extra: &[String]) -> Result<(), String> {
    let dir = scratch()?;
    let res = cc_in(&dir, c, out, mode, extra, true);
    let _ = fs::remove_dir_all(&dir);
    res
}

/// Compile C into `out` in the scratch directory `dir` (`keep`: honor `DUCK_KEEP_C`).
fn cc_in(dir: &Path, c: &str, out: &Path, mode: Mode, extra: &[String], keep: bool) -> Result<(), String> {
    let w = |name: &str, text: &str| fs::write(dir.join(name), text).map_err(|e| format!("error: cannot write {name}: {e}\n"));
    for (name, text) in RUNTIME {
        w(name, text)?;
    }
    w("prog.c", c)?;
    if keep && let Ok(keep) = env::var("DUCK_KEEP_C") {
        let _ = fs::write(keep, c);
    }
    let clang = env::var("CLANG").unwrap_or_else(|_| "clang".into());
    let mut cmd = Command::new(&clang);
    cmd.args(["-std=c11", "-pthread", "-Wall", "-Wno-unused"]);
    cmd.arg(if mode == Mode::Release { "-O2" } else { "-O1" });
    cmd.args(extra);
    if let Ok(flags) = env::var("DUCK_CFLAGS") {
        cmd.args(flags.split_whitespace());
    }
    cmd.arg("-I").arg(dir);
    cmd.arg(dir.join("prog.c"));
    for (name, _) in RUNTIME {
        if name.ends_with(".c") {
            cmd.arg(dir.join(name));
        }
    }
    cmd.args(LINK_LIBS).arg("-lm").arg("-o").arg(out);
    let output = cmd.output().map_err(|e| format!("error: failed to run `{clang}`: {e}\n"))?;
    if !output.status.success() {
        return Err(format!(
            "error: the C compiler rejected the generated code (this is a duck compiler bug):\n{}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(())
}

/// The runtime compiled once into object files, for drivers that build many small programs
/// (`duck pond` builds one per input): each build then compiles only the generated C and links
/// these objects, which keeps a build to one small clang invocation.
pub struct PrebuiltRuntime {
    dir: PathBuf,
    objs: Vec<PathBuf>,
}

impl PrebuiltRuntime {
    /// Write the runtime sources into `dir` and compile them (`-O1`) to object files there.
    pub fn build(dir: &Path) -> Result<PrebuiltRuntime, String> {
        fs::create_dir_all(dir).map_err(|e| format!("error: cannot create {}: {e}\n", dir.display()))?;
        for (name, text) in RUNTIME {
            fs::write(dir.join(name), text).map_err(|e| format!("error: cannot write {name}: {e}\n"))?;
        }
        let clang = env::var("CLANG").unwrap_or_else(|_| "clang".into());
        let mut cmd = Command::new(&clang);
        cmd.current_dir(dir).args(["-std=c11", "-pthread", "-Wall", "-Wno-unused", "-O1", "-c"]);
        if let Ok(flags) = env::var("DUCK_CFLAGS") {
            cmd.args(flags.split_whitespace());
        }
        let mut objs = Vec::new();
        for (name, _) in RUNTIME {
            if let Some(stem) = name.strip_suffix(".c") {
                cmd.arg(name);
                objs.push(dir.join(format!("{stem}.o")));
            }
        }
        let output = cmd.output().map_err(|e| format!("error: failed to run `{clang}`: {e}\n"))?;
        if !output.status.success() {
            return Err(format!("error: the C compiler rejected the runtime:\n{}", String::from_utf8_lossy(&output.stderr)));
        }
        Ok(PrebuiltRuntime { dir: dir.to_path_buf(), objs })
    }

    /// Compile generated C (written to `c_file`) at `-O0` and link it with the prebuilt runtime.
    pub fn cc(&self, c: &str, c_file: &Path, out: &Path) -> Result<(), String> {
        fs::write(c_file, c).map_err(|e| format!("error: cannot write {}: {e}\n", c_file.display()))?;
        if let Ok(keep) = env::var("DUCK_KEEP_C") {
            let _ = fs::write(keep, c);
        }
        let clang = env::var("CLANG").unwrap_or_else(|_| "clang".into());
        let mut cmd = Command::new(&clang);
        cmd.args(["-std=c11", "-pthread", "-w", "-O0"]);
        if let Ok(flags) = env::var("DUCK_CFLAGS") {
            cmd.args(flags.split_whitespace());
        }
        cmd.arg("-I").arg(&self.dir).arg(c_file).args(&self.objs).args(LINK_LIBS).arg("-lm").arg("-o").arg(out);
        let output = cmd.output().map_err(|e| format!("error: failed to run `{clang}`: {e}\n"))?;
        if !output.status.success() {
            return Err(format!(
                "error: the C compiler rejected the generated code (this is a duck compiler bug):\n{}",
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        Ok(())
    }
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

/// Type-check, generate and compile `path` into `out`. Returns the generated program info.
pub fn build_exe(path: &Path, out: &Path, mode: Mode, extra: &[String], trace: Trace) -> Result<Output, String> {
    let tp = check(path)?;
    let o = generate_traced(&tp, mode, trace)?;
    if mode == Mode::Release && !o.holes.is_empty() {
        let mut s = format!("error: `{}` still has {} unfilled hole(s); `duck build` needs a complete program\n", path.display(), o.holes.len());
        for h in &o.holes {
            let _ = writeln!(s, "  {h}");
        }
        s.push_str("  (fill them in, or use `duck run` / `duck test`, which allow holes)\n");
        return Err(s);
    }
    cc(&o.c, out, mode, extra)?;
    Ok(o)
}

/// The root file `duck test <dir>` builds: the project's `src/lib.duck` or `src/main.duck`.
fn project_root(dir: &Path) -> Result<PathBuf, String> {
    let proj = super::resolve::find_project(dir).ok_or_else(|| format!("error: {} is not inside a project (no quack.toml)\n", dir.display()))?;
    for f in ["src/lib.duck", "src/main.duck"] {
        if proj.join(f).is_file() {
            return Ok(proj.join(f));
        }
    }
    Err(format!("error: the project {} has no src/lib.duck or src/main.duck\n", proj.display()))
}

/// The top-level `.duck` files of `dir` that contain `test` blocks, sorted. A file that does not
/// parse is included when a line of it starts with `test ` (its build then reports the errors).
fn flat_test_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(rd) = fs::read_dir(dir) else { return Vec::new() };
    let mut files: Vec<PathBuf> = rd
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_file() && p.extension().is_some_and(|x| x == "duck"))
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

/// Execution-trace options of `duck run|test|ir` (`--trace=json|<path>`, `--trace-limit N`,
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
}

impl TraceOpts {
    /// The codegen flag.
    pub fn codegen(&self) -> Trace {
        Trace { on: self.dest.is_some(), core: self.core }
    }

    /// Configure the environment of a traced program (`dest` overrides `self.dest`).
    pub fn apply(&self, cmd: &mut Command, dest: Option<&str>) {
        let Some(d) = dest.or(self.dest.as_deref()) else { return };
        cmd.env("DUCK_TRACE", d);
        match self.limit {
            Some(n) => cmd.env("DUCK_TRACE_LIMIT", n.to_string()),
            None => cmd.env_remove("DUCK_TRACE_LIMIT"),
        };
    }
}

/// Split the trace flags off `args`: anywhere in them, or (`leading`) only before the first
/// other argument (`duck run`'s program arguments may look like flags).
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
        } else {
            rest.push(a.clone());
        }
    }
    if o.dest.is_none() && (limit_seen || o.core) {
        return Err("--trace-limit and --trace-core need --trace=json or --trace=<path>".into());
    }
    Ok((o, rest))
}

/// Build the test executable of `root` (a temporary file the caller removes).
fn build_tests(root: &Path, trace: &TraceOpts) -> Result<PathBuf, String> {
    let exe = temp_exe("test");
    let o = build_exe(root, &exe, Mode::Test, &[], trace.codegen())?;
    if o.tests == 0 {
        eprintln!("note: {} has no `test` blocks", root.display());
    }
    Ok(exe)
}

/// The trace directory of `duck test --trace=<dir>` (created), or `-`.
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

/// `duck test <dir>` on a flat directory: run each file's tests under a header, then print the
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
        let exe = match build_tests(f, trace) {
            Ok(exe) => exe,
            Err(e) => {
                eprint!("{e}");
                println!("did not build");
                broken += 1;
                continue;
            }
        };
        let mut cmd = Command::new(&exe);
        cmd.args(filter).stderr(std::process::Stdio::inherit());
        trace.apply(&mut cmd, dest.as_deref());
        let out = cmd.output();
        let _ = fs::remove_file(&exe);
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
            None => broken += 1,
        }
    }
    let files_n = files.len();
    let plural = if files_n == 1 { "" } else { "s" };
    let broken_note = if broken > 0 { format!(", {broken} did not build or run") } else { String::new() };
    println!("== {files_n} file{plural}{broken_note}: {passed} passed, {failed} failed");
    if failed > 0 || broken > 0 { 1 } else { 0 }
}

fn temp_exe(tag: &str) -> PathBuf {
    let n = BUILD_N.fetch_add(1, Ordering::Relaxed);
    env::temp_dir().join(format!("duck-{tag}-{}-{n}", std::process::id()))
}

/// `duck run|build|ir|test ...`. Returns the exit code.
pub fn cli(cmd: &str, args: &[String]) -> i32 {
    let fail = |msg: String| {
        eprint!("{msg}");
        1
    };
    // trace flags: anywhere for `test`, before the file for `run`/`ir` (not for `build`)
    let (trace, args) = if cmd == "build" {
        (TraceOpts::default(), args.to_vec())
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
                    eprintln!("usage: duck test [--trace=json|<dir>] [--trace-limit N] [--trace-core] [file|dir] [filter]");
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
            match build_tests(&root, &trace) {
                Ok(exe) => {
                    let mut c = Command::new(&exe);
                    c.args(filter.as_slice());
                    trace.apply(&mut c, dest.as_deref());
                    let status = c.status();
                    let _ = fs::remove_file(&exe);
                    status.ok().and_then(|s| s.code()).unwrap_or(1)
                }
                Err(e) => fail(e),
            }
        }
        "run" | "build" | "ir" => {
            let [file, rest @ ..] = args.as_slice() else {
                let flags = if cmd == "build" { "" } else { "[--trace=json|<file>] [--trace-limit N] [--trace-core] " };
                eprintln!("usage: duck {cmd} {flags}<file.duck>");
                return 2;
            };
            let path = Path::new(file);
            match cmd {
                "ir" => {
                    let tp = match check(path) {
                        Ok(t) => t,
                        Err(e) => return fail(e),
                    };
                    match generate_traced(&tp, Mode::Run, trace.codegen()) {
                        Ok(o) => {
                            print!("{}", o.c);
                            0
                        }
                        Err(e) => fail(e),
                    }
                }
                "build" => {
                    let out = match rest {
                        [] => path.with_extension(""),
                        [flag, out] if flag == "-o" => PathBuf::from(out),
                        _ => {
                            eprintln!("usage: duck build <file.duck> [-o out]");
                            return 2;
                        }
                    };
                    match build_exe(path, &out, Mode::Release, &[], Trace::default()) {
                        Ok(_) => 0,
                        Err(e) => fail(e),
                    }
                }
                _ => {
                    let exe = temp_exe("run");
                    if let Err(e) = build_exe(path, &exe, Mode::Run, &[], trace.codegen()) {
                        return fail(e);
                    }
                    let mut c = Command::new(&exe);
                    c.args(rest);
                    trace.apply(&mut c, None);
                    let status = c.status();
                    let _ = fs::remove_file(&exe);
                    status.ok().and_then(|s| s.code()).unwrap_or(1)
                }
            }
        }
        _ => unreachable!("duck {cmd} is not a build command"),
    }
}
