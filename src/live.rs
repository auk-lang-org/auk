//! `auk run --live <file> [args...]`: run a program and swap in new code as its source changes.
//!
//! A parent process compiles the program and forks a child to run it. The program is compiled in
//! live mode: every call to a user function loads its target from the live table, one slot per
//! function, keyed by module, name and signature (`Program::live_keys`). In the child, a watcher
//! thread polls the source files; on a change it re-checks and recompiles the whole program into
//! a new JIT module, runs that module's `dk_init` (string literals, imprints, constants) and
//! stores its functions into the table. From then on every call runs the new code, while the
//! program's data (and its threads, sockets, ...) carries on.
//!
//! - A type error leaves the running code as it is.
//! - A function whose signature changed gets a new slot: callers still running old code keep
//!   calling the old function, new code calls the new one.
//! - A frame that is already running (a loop in `main`, say) finishes its old body; only the
//!   functions it calls are new. Closures, `any` values and element ops created before a reload
//!   keep pointing at the old code they were made with (as Erlang funs do).
//! - A changed struct or enum layout can't be applied to data already in memory. Tasks share
//!   nothing (each has its own heap), so when only tasks can hold values of the changed types,
//!   just those tasks are cancelled: their supervisors (package `sup`) start them again, from
//!   scratch, on the new code, and the rest of the program keeps its state. Which types code can
//!   touch is worked out from the generated code: everything reachable from `main` on its own
//!   thread, and from each task's entry (`Uses`). When `main`'s side can hold one, the child exits
//!   with `RESTART` and the parent starts the program again from scratch. So does a crash or a
//!   normal exit, at the next change.
//!
//! Old modules are never freed: a frame may still be running their code.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant, SystemTime};

use crate::build::check;
use crate::mir::backend::{LiveJit, jit_live};
use crate::mir::{Callee, Ex, FRef, FuncId, K, MTy, Program, Stmt};
use crate::types::Ty;
use crate::mir::progen::{Mode, Trace};
use crate::mir::types::TyInfo;
use crate::typed::TypedProgram;
use crate::types::TypeDefKind;

/// The child's exit code that asks the parent for a fresh start.
const RESTART: i32 = 75;
/// Live table slots (one per user function instance ever compiled in this run).
const TABLE_LEN: usize = 1 << 16;
const POLL: Duration = Duration::from_millis(200);

fn table() -> &'static [AtomicUsize] {
    static T: OnceLock<&'static [AtomicUsize]> = OnceLock::new();
    T.get_or_init(|| Box::leak((0..TABLE_LEN).map(|_| AtomicUsize::new(0)).collect::<Vec<_>>().into_boxed_slice()))
}

/// The source files of a program and when each last changed.
type Files = Vec<(PathBuf, Option<SystemTime>)>;

fn mtime(p: &Path) -> Option<SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}

fn files_of(tp: &TypedProgram) -> Files {
    tp.program.mods.iter().filter(|m| !m.file.starts_with("<prelude>")).map(|m| PathBuf::from(&m.file)).map(|p| (p.clone(), mtime(&p))).collect()
}

fn changed(files: &Files) -> bool {
    files.iter().any(|(p, t)| mtime(p) != *t)
}

/// Every struct and enum's layout as text, by `file::Name`: a change means data already in
/// memory no longer fits the code.
fn layouts(tp: &TypedProgram) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for t in &tp.defs.types {
        let shape = match &t.kind {
            TypeDefKind::Struct { fields } => fields.iter().map(|f| format!("{}: {}", f.name, tp.defs.show(&f.ty))).collect::<Vec<_>>().join(", "),
            TypeDefKind::Enum { variants } => variants
                .iter()
                .map(|v| format!("{}({})", v.name, v.fields.iter().map(|(_, ty)| tp.defs.show(ty)).collect::<Vec<_>>().join(", ")))
                .collect::<Vec<_>>()
                .join(" | "),
            TypeDefKind::Opaque { .. } => continue,
        };
        out.insert(format!("{}::{}", tp.program.mods[t.module].file, t.name), shape);
    }
    out
}

// ---- which types code can touch ----

/// The user types (`file::Name`, as in `layouts`) that code can hold: what is reachable from
/// `main` without starting a task, and from each task entry (thunk) by name.
struct Uses {
    main: HashSet<String>,
    /// Per thunk: what it can reach (`wide`: an indirect call may be any closure of its
    /// signature), and what it reaches on its own (`narrow`: indirect calls not followed).
    thunks: HashMap<String, (HashSet<String>, HashSet<String>)>,
    /// The call graph, to work out on demand what a closure can reach (only for closures that
    /// running tasks were started with: there are many closures, few such tasks).
    graph: std::sync::Arc<Graph>,
}

/// A compiled program's call graph, with the user types each function itself holds.
struct Graph {
    own: Vec<HashSet<String>>,
    /// Functions called directly, or whose address is taken (a closure made, a helper passed).
    refs: Vec<Vec<FuncId>>,
    /// The functions called directly (a closure's body is reached by calling it, not making it).
    calls: Vec<HashSet<FuncId>>,
    /// The closures each function's indirect calls might call (any of the same signature).
    indirect: Vec<Vec<FuncId>>,
    names: Vec<String>,
    /// Closure bodies by name: none when the closure's environment holds closures (then a task
    /// started with it gets its thunk's `wide` set).
    closures: HashMap<String, Option<FuncId>>,
}

impl Graph {
    /// The user types reachable from `start` without entering another task's thunk. `wide`:
    /// indirect calls may reach any closure of their signature; else only the closures the
    /// reached code makes.
    fn reach(&self, start: FuncId, wide: bool) -> HashSet<String> {
        let mut seen = HashSet::new();
        let mut stack = vec![start];
        let mut keys = HashSet::new();
        while let Some(f) = stack.pop() {
            if !seen.insert(f) {
                continue;
            }
            let i = f as usize;
            keys.extend(self.own[i].iter().cloned());
            if wide {
                stack.extend(self.indirect[i].iter().copied());
            }
            for &g in &self.refs[i] {
                let n = &self.names[g as usize];
                let addr_only = is_thunk(n) || (wide && (n.starts_with("dk_clo") || n.starts_with("dk_fv")));
                if !addr_only || self.calls[i].contains(&g) {
                    stack.push(g);
                }
            }
        }
        keys
    }
}

/// The functions an expression calls or takes the address of, and its indirect calls'
/// signatures.
fn refs_ex(e: &Ex, out: &mut Vec<FuncId>, ind: &mut Vec<String>) {
    match &e.k {
        K::FnAddr(FRef::Fn(f)) => out.push(*f),
        K::Call(c, args) => {
            match c {
                Callee::Fn(f) => out.push(*f),
                Callee::Indirect(code, ps) => {
                    ind.push(sig_key(ps, &e.ty));
                    refs_ex(code, out, ind);
                }
                Callee::Rt(_) => {}
            }
            for a in args {
                refs_ex(a, out, ind);
            }
        }
        K::Field(x, _) | K::Deref(x) | K::Addr(x) | K::Un(_, x) | K::Cast(x) | K::RtField(x, _) => refs_ex(x, out, ind),
        K::Bin(_, a, b) | K::Elem(a, b) => {
            refs_ex(a, out, ind);
            refs_ex(b, out, ind);
        }
        K::And(xs) => xs.iter().for_each(|x| refs_ex(x, out, ind)),
        K::Agg(ms) => ms.iter().for_each(|(_, x)| refs_ex(x, out, ind)),
        K::Cond(a, b, c) => {
            refs_ex(a, out, ind);
            refs_ex(b, out, ind);
            refs_ex(c, out, ind);
        }
        _ => {}
    }
}

fn refs_stmts(ss: &[Stmt], out: &mut Vec<FuncId>, ind: &mut Vec<String>) {
    for s in ss {
        match s {
            Stmt::Let(_, e) | Stmt::Do(e) => refs_ex(e, out, ind),
            Stmt::Set(a, b) => {
                refs_ex(a, out, ind);
                refs_ex(b, out, ind);
            }
            Stmt::If(c, a, b) => {
                refs_ex(c, out, ind);
                refs_stmts(a, out, ind);
                refs_stmts(b, out, ind);
            }
            Stmt::Loop(a, b) => {
                refs_stmts(a, out, ind);
                refs_stmts(b, out, ind);
            }
            Stmt::Ret(Some(e)) => refs_ex(e, out, ind),
            _ => {}
        }
    }
}

/// The functions `ss` calls directly (not just takes the address of).
fn direct_calls(ss: &[Stmt]) -> HashSet<FuncId> {
    fn ex(e: &Ex, out: &mut HashSet<FuncId>) {
        if let K::Call(Callee::Fn(f), _) = &e.k {
            out.insert(*f);
        }
        match &e.k {
            K::Call(_, args) => args.iter().for_each(|a| ex(a, out)),
            K::Field(x, _) | K::Deref(x) | K::Addr(x) | K::Un(_, x) | K::Cast(x) | K::RtField(x, _) => ex(x, out),
            K::Bin(_, a, b) | K::Elem(a, b) => {
                ex(a, out);
                ex(b, out);
            }
            K::And(xs) => xs.iter().for_each(|x| ex(x, out)),
            K::Agg(ms) => ms.iter().for_each(|(_, x)| ex(x, out)),
            K::Cond(a, b, c) => {
                ex(a, out);
                ex(b, out);
                ex(c, out);
            }
            _ => {}
        }
    }
    fn st(ss: &[Stmt], out: &mut HashSet<FuncId>) {
        for s in ss {
            match s {
                Stmt::Let(_, e) | Stmt::Do(e) | Stmt::Ret(Some(e)) => ex(e, out),
                Stmt::Set(a, b) => {
                    ex(a, out);
                    ex(b, out);
                }
                Stmt::If(c, a, b) => {
                    ex(c, out);
                    st(a, out);
                    st(b, out);
                }
                Stmt::Loop(a, b) => {
                    st(a, out);
                    st(b, out);
                }
                _ => {}
            }
        }
    }
    let mut out = HashSet::new();
    st(ss, &mut out);
    out
}

fn sig_key(ps: &[MTy], ret: &MTy) -> String {
    format!("{ps:?}->{ret:?}")
}

fn is_thunk(name: &str) -> bool {
    name.starts_with("dk_thunk") && !name.ends_with("_drop")
}

/// The user types a type mentions, through struct fields and enum variants.
fn ty_keys(tp: &TypedProgram, t: &Ty, out: &mut HashSet<String>) {
    t.walk(&mut |x| {
        if let Ty::Named(d, _) = x {
            let def = &tp.defs.types[*d];
            let key = format!("{}::{}", tp.program.mods[def.module].file, def.name);
            if out.insert(key) {
                let inner: Vec<Ty> = match &def.kind {
                    TypeDefKind::Struct { fields } => fields.iter().map(|f| f.ty.clone()).collect(),
                    TypeDefKind::Enum { variants } => variants.iter().flat_map(|v| v.fields.iter().map(|(_, t)| t.clone())).collect(),
                    TypeDefKind::Opaque { .. } => Vec::new(),
                };
                for t in inner {
                    ty_keys(tp, &t, out);
                }
            }
        }
    });
}

fn mty_keys(prog: &Program, tp: &TypedProgram, m: &MTy, out: &mut HashSet<String>, aggs: &mut HashSet<u32>) {
    match m {
        MTy::D(t) => ty_keys(tp, t, out),
        MTy::Ptr(x) => mty_keys(prog, tp, x, out, aggs),
        MTy::Agg(a) if aggs.insert(*a) => {
            for f in &prog.aggs[*a as usize].fields {
                mty_keys(prog, tp, f, out, aggs);
            }
        }
        _ => {}
    }
}

fn uses(prog: &Program, tp: &TypedProgram) -> Uses {
    // closures by signature, for indirect calls
    let mut callables: HashMap<String, Vec<FuncId>> = HashMap::new();
    for (i, f) in prog.funcs.iter().enumerate() {
        if f.name.starts_with("dk_clo") || f.name.starts_with("dk_fv") {
            let ps: Vec<MTy> = f.params.iter().map(|&v| f.vars[v as usize].clone()).collect();
            callables.entry(sig_key(&ps, &f.ret)).or_default().push(i as FuncId);
        }
    }
    let n = prog.funcs.len();
    let (mut own, mut refs, mut calls, mut indirect) = (Vec::with_capacity(n), Vec::with_capacity(n), Vec::with_capacity(n), Vec::with_capacity(n));
    let mut aggs = HashSet::new();
    for f in &prog.funcs {
        let mut keys = HashSet::new();
        aggs.clear();
        for t in f.vars.iter().chain(std::iter::once(&f.ret)) {
            mty_keys(prog, tp, t, &mut keys, &mut aggs);
        }
        own.push(keys);
        let (mut out, mut ind) = (Vec::new(), Vec::new());
        refs_stmts(&f.body, &mut out, &mut ind);
        refs.push(out);
        calls.push(direct_calls(&f.body));
        indirect.push(ind.iter().flat_map(|s| callables.get(s).into_iter().flatten().copied()).collect());
    }
    // a closure `dk_clo{k}` keeps its captures in the aggregate `DkEnv{k}`
    let envs: HashMap<&str, &crate::mir::AggDef> = prog.aggs.iter().map(|a| (a.name.as_str(), a)).collect();
    let holds_fn = |m: &MTy| matches!(m, MTy::D(t) if { let mut f = false; t.walk(&mut |x| f |= matches!(x, Ty::Fn(..) | Ty::Any(_))); f });
    let closures = prog
        .funcs
        .iter()
        .enumerate()
        .filter(|(_, f)| f.name.starts_with("dk_clo") || f.name.starts_with("dk_fv"))
        .map(|(i, f)| {
            let env = f.name.strip_prefix("dk_clo").and_then(|k| envs.get(format!("DkEnv{k}").as_str()));
            let safe = env.is_none_or(|a| !a.fields.iter().any(holds_fn));
            (f.name.clone(), safe.then_some(i as FuncId))
        })
        .collect();
    let graph = Graph { own, refs, calls, indirect, names: prog.funcs.iter().map(|f| f.name.clone()).collect(), closures };
    let main = prog.entry.map(|e| graph.reach(e, true)).unwrap_or_default();
    let thunks = prog
        .funcs
        .iter()
        .enumerate()
        .filter(|(_, f)| is_thunk(&f.name))
        .map(|(i, f)| (f.name.clone(), (graph.reach(i as FuncId, true), graph.reach(i as FuncId, false))))
        .collect();
    Uses { main, thunks, graph: std::sync::Arc::new(graph) }
}

/// One compile of the program in live mode.
struct Build {
    jit: LiveJit,
    files: Files,
    layouts: HashMap<String, String>,
    uses: Uses,
}

/// What every compile so far says code can touch: `main`'s side, and each task entry by code
/// address (old modules' tasks may still be running).
#[derive(Default)]
struct Seen {
    main: HashSet<String>,
    thunks: HashMap<usize, (HashSet<String>, HashSet<String>)>,
    /// Closure code addresses: the graph they're in and their body (none: not narrowable).
    closures: HashMap<usize, (std::sync::Arc<Graph>, Option<FuncId>)>,
}

impl Seen {
    fn add(&mut self, b: &Build) {
        self.main.extend(b.uses.main.iter().cloned());
        for (name, keys) in &b.uses.thunks {
            if let Some(&a) = b.jit.addrs.get(name) {
                self.thunks.insert(a as usize, keys.clone());
            }
        }
        for (name, f) in &b.uses.graph.closures {
            if let Some(&a) = b.jit.addrs.get(name) {
                self.closures.insert(a as usize, (b.uses.graph.clone(), *f));
            }
        }
    }

    /// Can the task that started at thunk `entry` (with closure `hint`, 0 if none) hold one of
    /// the types `keys`? Narrowed to its closure when it was started with exactly one (`sup`
    /// children), else everything its thunk can reach.
    fn task_uses(&self, entry: usize, hint: usize, keys: &[String]) -> bool {
        let Some((wide, narrow)) = self.thunks.get(&entry) else { return false };
        let hit = |s: &HashSet<String>| keys.iter().any(|k| s.contains(k));
        match self.closures.get(&hint) {
            Some((g, Some(f))) if hint != 0 => hit(narrow) || hit(&g.reach(*f, true)),
            _ => hit(wide),
        }
    }
}

/// Check and compile `path`, giving new functions slots in `slots`. On failure, the error text
/// and the files to watch for a fix.
fn build(path: &Path, slots: &mut HashMap<String, usize>) -> Result<Build, (String, Option<Files>)> {
    let tp = check(path).map_err(|e| (e, None))?;
    let files = files_of(&tp);
    let fail = |e: String| (e, Some(files_of(&tp)));
    let g = crate::build::generate(&tp, Mode::Run, Trace::default()).map_err(fail)?;
    let info = TyInfo::new(&tp);
    let mut fs = HashMap::new();
    for (&f, key) in &g.prog.live_keys {
        let n = slots.len();
        let slot = *slots.entry(key.clone()).or_insert(n);
        if slot >= TABLE_LEN {
            return Err(fail("error: --live: too many functions compiled in this run; restart it\n".into()));
        }
        fs.insert(f, slot);
    }
    let jit = jit_live(&g.prog, &info, table().as_ptr() as usize, &fs).map_err(|e| fail(format!("error: code generation failed (this is an auk compiler bug): {e}\n")))?;
    let uses = uses(&g.prog, &tp);
    Ok(Build { jit, files, layouts: layouts(&tp), uses })
}

/// Make `b`'s code the current code: initialize its module, then point the table at it.
fn install(b: &Build) {
    let init: extern "C" fn() = unsafe { std::mem::transmute(b.jit.init) };
    init();
    for &(slot, code) in &b.jit.entries {
        table()[slot].store(code as usize, Ordering::Release);
    }
}

/// Block until one of `files` changes.
fn wait_change(files: &Files) {
    while !changed(files) {
        std::thread::sleep(POLL);
    }
}

fn note(msg: &str) {
    if unsafe { libc::isatty(2) } == 1 {
        eprintln!("\x1b[2m[live]\x1b[0m {msg}");
    } else {
        eprintln!("[live] {msg}");
    }
}

/// The child's watcher: reload on every change, or exit for a restart.
fn watch(path: PathBuf, mut slots: HashMap<String, usize>, mut files: Files, mut lay: HashMap<String, String>, mut seen: Seen, parent: i32) {
    loop {
        std::thread::sleep(POLL);
        // the parent is gone (killed): don't outlive it
        if unsafe { libc::getppid() } != parent {
            unsafe { libc::_exit(1) };
        }
        if !changed(&files) {
            continue;
        }
        let t0 = Instant::now();
        match build(&path, &mut slots) {
            Err((e, fs)) => {
                eprint!("{e}");
                note("not reloaded: the program keeps running the previous code");
                files = fs.unwrap_or_else(|| files.iter().map(|(p, _)| (p.clone(), mtime(p))).collect());
            }
            Ok(b) => {
                let moved: Vec<String> = b.layouts.iter().filter(|(k, v)| lay.get(*k).is_some_and(|old| old != *v)).map(|(k, _)| k.clone()).collect();
                let short = |k: &String| k.rsplit("::").next().unwrap_or(k).to_string();
                seen.add(&b);
                if let Some(k) = moved.iter().find(|k| seen.main.contains(*k)) {
                    note(&format!("`{}` changed shape and `main`'s side of the program uses it: restarting the program", short(k)));
                    unsafe {
                        libc::fflush(std::ptr::null_mut());
                        libc::_exit(RESTART);
                    }
                }
                install(&b);
                auk_rt::task::LIVE_RELOADS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                if !moved.is_empty() {
                    // only tasks can hold the old shape: stop those (their supervisors restart them)
                    let n = auk_rt::task::cancel_running(|entry, hint| seen.task_uses(entry, hint, &moved));
                    let names: Vec<String> = moved.iter().map(short).collect();
                    note(&format!("`{}` changed shape: stopped {n} task(s) that use it", names.join("`, `")));
                }
                lay.extend(b.layouts.clone());
                files = b.files.clone();
                note(&format!("reloaded in {} ms", t0.elapsed().as_millis()));
                b.jit.jit.leak();
            }
        }
    }
}

/// `auk run --live <file> [args...]`.
pub fn cli(args: &[String]) -> i32 {
    let Some((file, rest)) = args.split_first() else {
        eprintln!("usage: auk run --live <file.auk> [args...]");
        return 2;
    };
    let path = PathBuf::from(file);
    let mut argv = vec![file.clone()];
    argv.extend(rest.iter().cloned());
    let mut last: Files = vec![(path.clone(), mtime(&path))];
    // every run of the program shares one window process (gui.rs), so a restart keeps its windows
    let session = std::env::temp_dir().join(format!("auk-gui-{}.sock", std::process::id()));
    unsafe { std::env::set_var("AUK_GUI_SESSION", &session) };
    loop {
        let mut slots = HashMap::new();
        let b = match build(&path, &mut slots) {
            Ok(b) => b,
            Err((e, fs)) => {
                eprint!("{e}");
                if let Some(fs) = fs {
                    last = fs;
                }
                note("waiting for a fix");
                let snap: Files = last.iter().map(|(p, _)| (p.clone(), mtime(p))).collect();
                wait_change(&snap);
                continue;
            }
        };
        install(&b);
        last = b.files.clone();
        unsafe { libc::fflush(std::ptr::null_mut()) };
        let me = unsafe { libc::getpid() };
        let pid = unsafe { libc::fork() };
        if pid < 0 {
            eprintln!("error: fork failed");
            return 1;
        }
        if pid == 0 {
            let (files, lay) = (b.files.clone(), b.layouts.clone());
            let mut seen = Seen::default();
            seen.add(&b);
            let p = path.clone();
            std::thread::spawn(move || watch(p, slots, files, lay, seen, me));
            let code = b.jit.jit.run(&argv);
            // a normal end: its windows close now instead of waiting for the next run
            auk_rt::gui::shutdown();
            unsafe {
                libc::fflush(std::ptr::null_mut());
                libc::_exit(code);
            }
        }
        // the parent: the child has the program now
        b.jit.jit.leak();
        let code = match crate::mir::backend::wait_child(pid, None) {
            Ok(Some(c)) => c,
            _ => None,
        };
        if code == Some(RESTART) {
            continue;
        }
        note(&match code {
            Some(c) => format!("the program exited with {c}; waiting for a change to start it again"),
            None => "the program was killed; waiting for a change to start it again".into(),
        });
        let snap: Files = last.iter().map(|(p, _)| (p.clone(), mtime(p))).collect();
        wait_change(&snap);
    }
}
