//! `duck run --live <file> [args...]`: run a program and swap in new code as its source changes.
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
//! - A changed struct or enum layout can't be applied to data already in memory: the child exits
//!   with `RESTART` and the parent starts the program again from scratch. So does a crash or a
//!   normal exit, at the next change.
//!
//! Old modules are never freed: a frame may still be running their code.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant, SystemTime};

use crate::build::check;
use crate::mir::clif::{LiveJit, jit_live};
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

/// One compile of the program in live mode.
struct Build {
    jit: LiveJit,
    files: Files,
    layouts: HashMap<String, String>,
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
    let jit = jit_live(&g.prog, &info, table().as_ptr() as usize, &fs).map_err(|e| fail(format!("error: code generation failed (this is a duck compiler bug): {e}\n")))?;
    Ok(Build { jit, files, layouts: layouts(&tp) })
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
fn watch(path: PathBuf, mut slots: HashMap<String, usize>, mut files: Files, mut lay: HashMap<String, String>, parent: i32) {
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
                let moved: Vec<&String> = b.layouts.iter().filter(|(k, v)| lay.get(*k).is_some_and(|old| old != *v)).map(|(k, _)| k).collect();
                if let Some(k) = moved.first() {
                    let name = k.rsplit("::").next().unwrap_or(k);
                    note(&format!("`{name}` changed shape: restarting the program"));
                    unsafe {
                        libc::fflush(std::ptr::null_mut());
                        libc::_exit(RESTART);
                    }
                }
                install(&b);
                lay.extend(b.layouts.clone());
                files = b.files.clone();
                note(&format!("reloaded in {} ms", t0.elapsed().as_millis()));
                b.jit.jit.leak();
            }
        }
    }
}

/// `duck run --live <file> [args...]`.
pub fn cli(args: &[String]) -> i32 {
    let Some((file, rest)) = args.split_first() else {
        eprintln!("usage: duck run --live <file.duck> [args...]");
        return 2;
    };
    let path = PathBuf::from(file);
    let mut argv = vec![file.clone()];
    argv.extend(rest.iter().cloned());
    let mut last: Files = vec![(path.clone(), mtime(&path))];
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
            let p = path.clone();
            std::thread::spawn(move || watch(p, slots, files, lay, me));
            let code = b.jit.jit.run(&argv);
            unsafe {
                libc::fflush(std::ptr::null_mut());
                libc::_exit(code);
            }
        }
        // the parent: the child has the program now
        b.jit.jit.leak();
        let code = match crate::mir::clif::wait_child(pid, None) {
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
