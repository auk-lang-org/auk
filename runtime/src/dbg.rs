//! The debugger engine (`duck run --debug`): breakpoints, stepping, pausing, stack and locals.
//!
//! Only programs compiled with `--debug` call into this module. Every instrumented Duck function
//! keeps a frame record (`Frame`) on its stack: `duck_dbg_enter`/`duck_dbg_leave` link it into
//! the thread's debugger stack, each named local's address is stored in its slot when the local
//! is bound, and each statement stores its site id in `site` and calls `duck_dbg_hook` while
//! `duck_dbg_armed` is set. `main` calls `duck_dbg_init` with the debug info (sites, functions,
//! locals, types) and a table of show functions, one per local type.
//!
//! A front end (`duck debug`, `duck dap`) attaches through a Unix socket named by `DUCK_DEBUG`:
//! the program connects, sends `{"ev":"ready"}` and waits for `run`. Without `DUCK_DEBUG` the
//! program runs as usual (`duck_dbg_armed` stays 0).
//!
//! # Protocol
//! Commands are text lines, optionally prefixed with `@<seq> ` (echoed as `"seq":N` in the reply):
//!   run                         start the program (after setting breakpoints)
//!   break <file>:<line>         line breakpoint (moves to the next line with code)
//!   break <function>            function breakpoint (`f`, or `mod.f`)
//!   break <place> if <cond>     only where the Duck expression `cond` is true
//!   delete [id]                 remove one breakpoint, or all
//!   catch all|uncaught|none     stop on panics (default `uncaught`: not under a recovery point)
//!   pause                       stop every thread at its next statement
//!   kill                        end the program
//! While stopped:
//!   continue | step | next | finish     resume (step into / over / out of, on the focus thread)
//!   stack [thread]              the frames, innermost first
//!   vars [frame] [thread]       the frame's locals in scope, shown
//!   threads                     every thread with its innermost frame
//!   kids <frame> <thread> <local> [i...]   the parts of a local (or of part i, j...)
//!   eval <frame> <thread> <expr>           a Duck expression's value there (an assignment
//!                               `x = v` changes a `var` local; src/dbg_eval.rs compiles it)
//! Events are JSON lines: `ready`, `ok`, `error`, `break`, `stopped`, `stack`, `vars`, `kids`,
//! `value`, `threads`, `exited`. When one thread stops, every other thread stops at its next statement
//! (all-stop); a thread blocked in a call (sleep, recv, I/O) stops when it returns.

use crate::{DuckStr, ShowFn, cstr, sbytes};
use std::cell::Cell;
use std::collections::VecDeque;
use std::ffi::{c_char, c_void};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, Ordering::*};
use std::sync::{Condvar, Mutex, MutexGuard, OnceLock};

/// Non-zero while the debugger wants to see statements: generated code calls `duck_dbg_hook`
/// only then.
#[unsafe(no_mangle)]
pub static duck_dbg_armed: AtomicI64 = AtomicI64::new(0);

/// A frame record, as generated code lays it out: `{fn, parent, site, slot...}`.
#[repr(C)]
pub struct Frame {
    func: i64,
    parent: *mut Frame,
    site: i64,
    slots: [*mut c_void; 0],
}

/// `void kids(void *value, void *ctx)`: reports each part through `duck_dbg_kid`.
type KidsFn = unsafe extern "C" fn(*mut c_void, *mut c_void);

struct Site {
    func: u32,
    file: u32,
    line: u32,
    col: u32,
    vis: Vec<u32>,
}

struct FnInfo {
    name: String,
    /// (name, type) of each frame slot.
    locals: Vec<(String, u32)>,
}

struct Info {
    files: Vec<String>,
    types: Vec<String>,
    fns: Vec<FnInfo>,
    sites: Vec<Site>,
    shows: *const ShowFn,
    /// The children function of each type (NULL: a type without parts).
    kids: *const Option<KidsFn>,
    /// Breakpoints set at each site (a count: several breakpoints may share one).
    bp: Vec<AtomicU32>,
}

unsafe impl Sync for Info {}
unsafe impl Send for Info {}

static INFO: OnceLock<Info> = OnceLock::new();
static ATTACHED: AtomicBool = AtomicBool::new(false);
static NEXT_THREAD: AtomicI64 = AtomicI64::new(1);

thread_local! {
    static TOP: Cell<*mut Frame> = const { Cell::new(std::ptr::null_mut()) };
    static DEPTH: Cell<i64> = const { Cell::new(0) };
    static TID: Cell<i64> = const { Cell::new(0) };
    /// Set while this thread runs the debugger (showing values runs Duck code: no stops).
    static BUSY: Cell<bool> = const { Cell::new(false) };
    static STEP: Cell<Step> = const { Cell::new(Step { kind: StepKind::None, epoch: 0, depth: 0, line: 0, site: 0 }) };
    static REG: Registration = const { Registration(Cell::new(false)) };
}

#[derive(Clone, Copy, PartialEq)]
enum StepKind {
    None,
    In,
    Over,
    Out,
}

/// A step in progress on this thread; it lapses at the next stop (any thread's): `epoch`.
#[derive(Clone, Copy)]
struct Step {
    kind: StepKind,
    epoch: u64,
    depth: i64,
    line: u32,
    site: i64,
}

#[derive(Clone, Copy, PartialEq)]
enum CatchMode {
    All,
    Uncaught,
    None,
}

struct Bp {
    id: i64,
    sites: Vec<u32>,
    /// Stop only where this Duck expression is true.
    cond: Option<String>,
}

/// A thread the debugger knows: its id and where its frame pointer cell lives.
struct ThreadRef {
    id: i64,
    top: *const Cell<*mut Frame>,
}

unsafe impl Send for ThreadRef {}

struct State {
    running: bool,
    stopped: bool,
    focus: i64,
    /// Bumped at every stop (steps lapse) and every resume (parked threads wake).
    epoch: u64,
    pause_req: bool,
    stepping: bool,
    catch_mode: CatchMode,
    bps: Vec<Bp>,
    next_bp: i64,
    /// Commands for the stopped focus thread: (seq, words).
    queue: VecDeque<(Option<i64>, String)>,
    threads: Vec<ThreadRef>,
}

static ST: Mutex<State> = Mutex::new(State {
    running: false,
    stopped: false,
    focus: 0,
    epoch: 0,
    pause_req: false,
    stepping: false,
    catch_mode: CatchMode::Uncaught,
    bps: Vec::new(),
    next_bp: 1,
    queue: VecDeque::new(),
    threads: Vec::new(),
});
static CV: Condvar = Condvar::new();
static OUT: Mutex<Option<UnixStream>> = Mutex::new(None);

fn st() -> MutexGuard<'static, State> {
    ST.lock().unwrap_or_else(|e| e.into_inner())
}

fn wait(g: MutexGuard<'static, State>) -> MutexGuard<'static, State> {
    CV.wait(g).unwrap_or_else(|e| e.into_inner())
}

/// Recompute `duck_dbg_armed` from the state.
fn rearm(s: &State) {
    let on = !s.running || s.stopped || s.pause_req || s.stepping || !s.bps.is_empty();
    duck_dbg_armed.store(on as i64, SeqCst);
}

/// Removes the thread from the debugger's list when it ends.
struct Registration(Cell<bool>);

impl Drop for Registration {
    fn drop(&mut self) {
        if self.0.get() {
            let id = TID.with(|t| t.get());
            st().threads.retain(|t| t.id != id);
        }
    }
}

/// This thread's debugger id (registering it on first use).
fn tid() -> i64 {
    let id = TID.with(|t| t.get());
    if id != 0 {
        return id;
    }
    let id = NEXT_THREAD.fetch_add(1, SeqCst);
    TID.with(|t| t.set(id));
    let top = TOP.with(|t| t as *const Cell<*mut Frame>);
    REG.with(|r| r.0.set(true));
    st().threads.push(ThreadRef { id, top });
    id
}

// ---- generated code's entry points --------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_dbg_enter(f: *mut Frame) {
    if TID.with(|t| t.get()) == 0 && ATTACHED.load(Relaxed) {
        tid();
    }
    unsafe { (*f).parent = TOP.with(|t| t.replace(f)) };
    DEPTH.with(|d| d.set(d.get() + 1));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_dbg_leave(f: *mut Frame) {
    TOP.with(|t| t.set(unsafe { (*f).parent }));
    DEPTH.with(|d| d.set(d.get() - 1));
}

/// A statement of an instrumented function, while armed: stop here?
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_dbg_hook(f: *mut Frame) {
    if !ATTACHED.load(Relaxed) || BUSY.with(|b| b.get()) {
        return;
    }
    let Some(info) = INFO.get() else { return };
    let site = unsafe { (*f).site };
    let me = tid();
    let mut s = st();
    // another thread has stopped: wait until it resumes
    while s.stopped {
        let g = s.epoch;
        while s.stopped && s.epoch == g {
            s = wait(s);
        }
    }
    let mut extra = None;
    let reason = if s.pause_req {
        s.pause_req = false;
        "pause"
    } else if info.bp.get(site as usize).is_some_and(|b| b.load(Relaxed) > 0) {
        // conditions: evaluated here, without the lock (they run Duck code)
        let conds: Vec<Option<String>> = s.bps.iter().filter(|b| b.sites.contains(&(site as u32))).map(|b| b.cond.clone()).collect();
        drop(s);
        let mut hit = false;
        for c in conds {
            let Some(c) = c else {
                hit = true;
                break;
            };
            let r = BUSY.with(|b| b.replace(true));
            let v = eval_at(f, &c);
            BUSY.with(|b| b.set(r));
            match v {
                Ok((v, _)) if v == "true" => {
                    hit = true;
                    break;
                }
                Ok(_) => {}
                Err(e) => {
                    let mut o = String::from(",\"cond_error\":");
                    json_str(&mut o, &format!("{c}: {e}"));
                    extra = Some(o);
                    hit = true;
                    break;
                }
            }
        }
        s = st();
        while s.stopped {
            let g = s.epoch;
            while s.stopped && s.epoch == g {
                s = wait(s);
            }
        }
        if hit {
            "breakpoint"
        } else if step_done(&s, info, site) {
            "step"
        } else {
            return;
        }
    } else if step_done(&s, info, site) {
        "step"
    } else {
        return;
    };
    stop(s, me, reason, extra);
}

// ---- evaluating Duck expressions --------------------------------------------------------

/// What the compiler hands back for an expression at a site: a function of the addresses of
/// the locals it uses (in `slots` order) that returns the value shown, and its type.
pub struct Compiled {
    pub run: unsafe extern "C" fn(*const *mut c_void) -> *mut DuckStr,
    pub slots: Vec<u32>,
    pub ty: String,
}

/// The compiler's side (src/dbg_eval.rs, in the same process for `duck run --debug`): compile
/// `expr` at `site` of debug function `func`.
pub type EvalHook = fn(func: u32, site: u32, expr: &str) -> Result<Compiled, String>;

static EVAL_HOOK: OnceLock<EvalHook> = OnceLock::new();
/// A compiled expression (or why it doesn't compile), by (site, text).
type Cached = ((u32, String), std::sync::Arc<Result<Compiled, String>>);
static EVALS: Mutex<Vec<Cached>> = Mutex::new(Vec::new());

pub fn set_eval_hook(h: EvalHook) {
    let _ = EVAL_HOOK.set(h);
}

/// Evaluate a Duck expression in frame `f`: (value shown, type).
fn eval_at(f: *mut Frame, expr: &str) -> Result<(String, String), String> {
    let hook = EVAL_HOOK.get().ok_or("this program can't evaluate expressions")?;
    let (func, site) = unsafe { ((*f).func as u32, (*f).site as u32) };
    let key = (site, expr.trim().to_string());
    let found = EVALS.lock().unwrap_or_else(|e| e.into_inner()).iter().find(|(k, _)| *k == key).map(|(_, c)| c.clone());
    let c = match found {
        Some(c) => c,
        None => {
            let c = std::sync::Arc::new(hook(func, site, &key.1));
            EVALS.lock().unwrap_or_else(|e| e.into_inner()).push((key, c.clone()));
            c
        }
    };
    let c = c.as_ref().as_ref().map_err(|e| e.clone())?;
    let mut args = Vec::new();
    for &slot in &c.slots {
        let p = unsafe { *(*f).slots.as_ptr().add(slot as usize) };
        if p.is_null() {
            return Err("a variable it uses has no value yet".into());
        }
        args.push(p);
    }
    struct Env {
        run: unsafe extern "C" fn(*const *mut c_void) -> *mut DuckStr,
        args: *const *mut c_void,
    }
    unsafe extern "C" fn tramp(env: *mut c_void, out: *mut c_void) {
        let e = unsafe { &*(env as *const Env) };
        unsafe { *(out as *mut *mut DuckStr) = (e.run)(e.args) };
    }
    let mut env = Env { run: c.run, args: args.as_ptr() };
    let mut out: *mut DuckStr = std::ptr::null_mut();
    let left = crate::trace::show_left();
    crate::trace::set_show_left(1024);
    let r = unsafe { crate::catch::run(tramp, (&mut env as *mut Env).cast(), (&mut out as *mut *mut DuckStr).cast()) };
    crate::trace::set_show_left(left);
    if let Some(p) = r {
        return Err(format!("panic: {}", p.msg));
    }
    let mut v = String::from_utf8_lossy(unsafe { sbytes(out) }).into_owned();
    unsafe { crate::rc::release(out) };
    if v.len() > 1000 {
        let mut end = 1000;
        while !v.is_char_boundary(end) {
            end -= 1;
        }
        v.truncate(end);
        v += "…";
    }
    Ok((v, c.ty.clone()))
}

/// `text` after its first `n` whitespace-separated words.
fn after_words(text: &str, n: usize) -> &str {
    let mut t = text.trim_start();
    for _ in 0..n {
        t = t.find(char::is_whitespace).map_or("", |i| &t[i..]).trim_start();
    }
    t
}

/// Has this thread's step finished at `site`?
fn step_done(s: &State, info: &Info, site: i64) -> bool {
    let st = STEP.with(|c| c.get());
    if st.kind == StepKind::None || st.epoch != s.epoch || !s.stepping {
        return false;
    }
    let depth = DEPTH.with(|d| d.get());
    let line = info.sites.get(site as usize).map_or(0, |x| x.line);
    // a new line, or the same statement again (the next loop iteration)
    let moved = line != st.line || site <= st.site;
    match st.kind {
        StepKind::In => depth != st.depth || moved,
        StepKind::Over => depth < st.depth || (depth == st.depth && moved),
        StepKind::Out => depth < st.depth,
        StepKind::None => false,
    }
}

/// A panic on this thread (rc.rs): stop first, if the debugger wants panics. `caught`: it will
/// jump to a recovery point (`catch`, a task's own).
pub fn on_panic(loc: &str, msg: &str, caught: bool) {
    if !ATTACHED.load(Relaxed) || BUSY.with(|b| b.get()) || INFO.get().is_none() {
        return;
    }
    let me = tid();
    let mut s = st();
    let want = match s.catch_mode {
        CatchMode::All => true,
        CatchMode::Uncaught => !caught,
        CatchMode::None => false,
    };
    if !want || !s.running {
        return;
    }
    while s.stopped {
        let g = s.epoch;
        while s.stopped && s.epoch == g {
            s = wait(s);
        }
    }
    let mut extra = String::from(",\"msg\":");
    json_str(&mut extra, msg);
    extra += ",\"loc\":";
    json_str(&mut extra, loc);
    if caught {
        extra += ",\"caught\":true";
    }
    stop(s, me, "panic", Some(extra));
}

/// The debugger stack of a recovery point (`catch`, a task), restored when a panic jumps back
/// past frames that never got to leave.
pub fn save_state() -> (*mut Frame, i64) {
    (TOP.with(|t| t.get()), DEPTH.with(|d| d.get()))
}

pub fn restore_state(s: (*mut Frame, i64)) {
    TOP.with(|t| t.set(s.0));
    DEPTH.with(|d| d.set(s.1));
}

/// Is the debugger showing a value on this thread (the show budget applies)?
pub fn showing() -> bool {
    BUSY.with(|b| b.get())
}

// ---- stopping ---------------------------------------------------------------------------

/// Stop the world on this thread, report it, and serve commands until a resume.
fn stop(mut s: MutexGuard<'static, State>, me: i64, reason: &str, extra: Option<String>) {
    s.stopped = true;
    s.stepping = false;
    s.focus = me;
    s.epoch += 1;
    rearm(&s);
    let mut ev = format!("{{\"ev\":\"stopped\",\"reason\":\"{reason}\",\"thread\":{me}");
    if reason == "breakpoint" {
        let site = TOP.with(|t| t.get());
        if !site.is_null() {
            let site = unsafe { (*site).site } as u32;
            let ids: Vec<String> = s.bps.iter().filter(|b| b.sites.contains(&site)).map(|b| b.id.to_string()).collect();
            ev += &format!(",\"bps\":[{}]", ids.join(","));
        }
    }
    let top = TOP.with(|t| t.get());
    if let Some(fr) = frame_json(top) {
        ev += ",\"frame\":";
        ev += &fr;
    }
    if let Some(x) = extra {
        ev += &x;
    }
    ev.push('}');
    emit(&ev);
    // serve commands until one resumes
    loop {
        while s.queue.is_empty() && s.stopped {
            s = wait(s);
        }
        if !s.stopped {
            // detached
            return;
        }
        let (seq, text) = s.queue.pop_front().expect("command");
        let words: Vec<String> = text.split_whitespace().map(String::from).collect();
        drop(s);
        let resume = BUSY.with(|b| b.replace(true));
        let r = serve(seq, &words, &text, me);
        BUSY.with(|b| b.set(resume));
        s = st();
        if let Some(kind) = r {
            if kind != StepKind::None {
                let info = INFO.get().expect("info");
                let top = TOP.with(|t| t.get());
                let site = if top.is_null() { -1 } else { unsafe { (*top).site } };
                let line = info.sites.get(site as usize).map_or(0, |x| x.line);
                s.stepping = true;
                STEP.with(|c| c.set(Step { kind, epoch: s.epoch + 1, depth: DEPTH.with(|d| d.get()), line, site }));
            }
            s.stopped = false;
            s.epoch += 1;
            rearm(&s);
            CV.notify_all();
            reply(seq, "ok", "");
            return;
        }
    }
}

/// Serve one command of the stopped focus thread: Some(step kind) for a resume.
fn serve(seq: Option<i64>, w: &[String], text: &str, me: i64) -> Option<StepKind> {
    let arg = |i: usize| w.get(i).and_then(|x| x.parse::<i64>().ok());
    match w[0].as_str() {
        "continue" | "c" => return Some(StepKind::None),
        "step" | "s" => return Some(StepKind::In),
        "next" | "n" => return Some(StepKind::Over),
        "finish" => return Some(StepKind::Out),
        "stack" | "bt" => {
            let t = arg(1).unwrap_or(me);
            match thread_top(t, me) {
                Some(top) => {
                    let mut fs = Vec::new();
                    let mut f = top;
                    while let Some(j) = frame_json(f) {
                        fs.push(j);
                        f = unsafe { (*f).parent };
                    }
                    reply(seq, "stack", &format!(",\"thread\":{t},\"frames\":[{}]", fs.join(",")));
                }
                None => reply(seq, "error", &format!(",\"msg\":\"no thread {t}\"")),
            }
        }
        "vars" | "locals" => {
            let n = arg(1).unwrap_or(0);
            let t = arg(2).unwrap_or(me);
            match frame_at(t, n, me) {
                Ok(f) => reply(seq, "vars", &format!(",\"thread\":{t},\"frame\":{n},\"vars\":[{}]", vars_json(f))),
                Err(e) => reply(seq, "error", &format!(",\"msg\":\"{}\"", esc(&e))),
            }
        }
        // `kids <frame> <thread> <local> [i...]`: the parts of a local, or of its part i, j...
        "kids" => {
            let n = arg(1).unwrap_or(0);
            let t = arg(2).unwrap_or(me);
            let path: Vec<u32> = w.iter().skip(4).filter_map(|x| x.parse().ok()).collect();
            let r = frame_at(t, n, me).and_then(|f| {
                let name = w.get(3).ok_or("kids: which local?")?;
                let (_, ty, p) = locals_of(f).into_iter().find(|(x, _, _)| x == name).ok_or(format!("no local `{name}` here"))?;
                kids_json(ty, p, path)
            });
            match r {
                Ok(items) => reply(seq, "kids", &items),
                Err(e) => reply(seq, "error", &format!(",\"msg\":\"{}\"", esc(&e))),
            }
        }
        // `eval <frame> <thread> <expression>`
        "eval" | "e" => {
            let n = arg(1).unwrap_or(0);
            let t = arg(2).unwrap_or(me);
            let expr = after_words(text, 3);
            if expr.is_empty() {
                reply(seq, "error", ",\"msg\":\"eval: which expression?\"");
                return None;
            }
            let r = frame_at(t, n, me).and_then(|f| eval_at(f, expr));
            match r {
                Ok((v, ty)) => {
                    let (mut a, mut b) = (String::new(), String::new());
                    json_str(&mut a, &v);
                    json_str(&mut b, &ty);
                    reply(seq, "value", &format!(",\"value\":{a},\"type\":{b}"));
                }
                Err(e) => reply(seq, "error", &format!(",\"msg\":\"{}\"", esc(&e))),
            }
        }
        "threads" => {
            let ts: Vec<(i64, *mut Frame)> = st().threads.iter().map(|r| (r.id, unsafe { (*r.top).get() })).collect();
            let items: Vec<String> = ts
                .iter()
                .map(|(id, top)| {
                    let fr = frame_json(*top).unwrap_or_else(|| "null".into());
                    format!("{{\"id\":{id},\"frame\":{fr}}}")
                })
                .collect();
            reply(seq, "threads", &format!(",\"threads\":[{}]", items.join(",")));
        }
        other => reply(seq, "error", &format!(",\"msg\":\"unknown command `{}`\"", esc(other))),
    }
    None
}

/// Frame `n` (0 = innermost) of thread `t`.
fn frame_at(t: i64, n: i64, me: i64) -> Result<*mut Frame, String> {
    let mut f = thread_top(t, me).ok_or(format!("no thread {t}"))?;
    for _ in 0..n {
        if f.is_null() {
            break;
        }
        f = unsafe { (*f).parent };
    }
    if f.is_null() { Err(format!("no frame {n}")) } else { Ok(f) }
}

/// The innermost frame of thread `t` (stopped: its frames don't change).
fn thread_top(t: i64, me: i64) -> Option<*mut Frame> {
    if t == me {
        return Some(TOP.with(|c| c.get()));
    }
    let s = st();
    s.threads.iter().find(|r| r.id == t).map(|r| unsafe { (*r.top).get() })
}

/// `{"fn":..,"file":..,"line":..,"col":..}` of a frame (None for no frame).
fn frame_json(f: *mut Frame) -> Option<String> {
    if f.is_null() {
        return None;
    }
    let info = INFO.get()?;
    let (func, site) = unsafe { ((*f).func as usize, (*f).site) };
    let name = info.fns.get(func).map_or("?", |x| x.name.as_str());
    let mut o = String::from("{\"fn\":");
    json_str(&mut o, name);
    if let Some(s) = info.sites.get(site as usize) {
        o += ",\"file\":";
        json_str(&mut o, &info.files[s.file as usize]);
        o += &format!(",\"line\":{},\"col\":{}", s.line, s.col);
    }
    o.push('}');
    Some(o)
}

/// The locals in scope at a frame's current statement, in binding order: (name, type, address).
/// A shadowed name gives only its latest binding.
fn locals_of(f: *mut Frame) -> Vec<(String, u32, *mut c_void)> {
    let Some(info) = INFO.get() else { return Vec::new() };
    let (func, site) = unsafe { ((*f).func as usize, (*f).site) };
    let (Some(fi), Some(s)) = (info.fns.get(func), info.sites.get(site as usize)) else { return Vec::new() };
    let mut out: Vec<(String, u32, *mut c_void)> = Vec::new();
    for &slot in s.vis.iter().rev() {
        let Some((name, ty)) = fi.locals.get(slot as usize) else { continue };
        if name == "_" || out.iter().any(|(n, _, _)| n == name) {
            continue;
        }
        let p = unsafe { *(*f).slots.as_ptr().add(slot as usize) };
        if !p.is_null() {
            out.push((name.clone(), *ty, p));
        }
    }
    out.reverse();
    out
}

/// `{"name","type","value"[,"kids":true]}` of a value of type `ty` at `p`.
fn item_json(info: &Info, name: &str, ty: u32, p: *mut c_void) -> String {
    let value = show(info, ty, p);
    let mut o = String::from("{\"name\":");
    json_str(&mut o, name);
    o += ",\"type\":";
    json_str(&mut o, info.types.get(ty as usize).map_or("?", |s| s.as_str()));
    o += ",\"value\":";
    json_str(&mut o, &value);
    if has_parts(info, ty, p) {
        o += ",\"kids\":true";
    }
    o.push('}');
    o
}

/// The locals in scope at a frame's current statement, as JSON items.
fn vars_json(f: *mut Frame) -> String {
    let Some(info) = INFO.get() else { return String::new() };
    locals_of(f).iter().map(|(n, ty, p)| item_json(info, n, *ty, *p)).collect::<Vec<_>>().join(",")
}

/// At most this many parts of one value are listed.
const KIDS_MAX: usize = 1000;

/// The walk of a value's parts: down `path` (a part index per level), then listing the parts
/// of the value reached.
struct KidCtx {
    path: Vec<u32>,
    depth: usize,
    counter: u32,
    listing: bool,
    /// Listing only counts (in `more`).
    count_only: bool,
    found: bool,
    done: bool,
    out: Vec<String>,
    more: usize,
}

/// `,"kids":[...]` (and `"more":N`) for the parts of the value at `p` reached by `path`.
fn kids_json(ty: u32, p: *mut c_void, path: Vec<u32>) -> Result<String, String> {
    let info = INFO.get().ok_or("no debug info")?;
    let listing = path.is_empty();
    let mut c = KidCtx { path, depth: 0, counter: 0, listing, count_only: false, found: listing, done: false, out: Vec::new(), more: 0 };
    let Some(k) = (unsafe { *info.kids.add(ty as usize) }) else { return Err("the value has no parts".into()) };
    unsafe { k(p, (&mut c as *mut KidCtx).cast()) };
    if !c.found {
        return Err("no such part".into());
    }
    let more = if c.more > 0 { format!(",\"more\":{}", c.more) } else { String::new() };
    Ok(format!(",\"kids\":[{}]{more}", c.out.join(",")))
}

/// Does this value have parts (a variant with fields, a non-empty list...)?
fn has_parts(info: &Info, ty: u32, p: *mut c_void) -> bool {
    let Some(k) = (unsafe { *info.kids.add(ty as usize) }) else { return false };
    let mut c = KidCtx { path: Vec::new(), depth: 0, counter: 0, listing: true, count_only: true, found: true, done: false, out: Vec::new(), more: 0 };
    unsafe { k(p, (&mut c as *mut KidCtx).cast()) };
    c.more > 0
}

/// One part (index `counter`) of the value being walked.
unsafe fn kid(ctx: *mut c_void, name: &dyn Fn() -> String, ty: u32, p: *mut c_void) {
    let Some(info) = INFO.get() else { return };
    let c = unsafe { &mut *(ctx as *mut KidCtx) };
    if c.done {
        return;
    }
    if c.listing {
        if c.count_only || c.out.len() >= KIDS_MAX {
            c.more += 1;
            // one part is enough to know there are some
            c.done = c.count_only;
        } else {
            let item = item_json(info, &name(), ty, p);
            unsafe { (*(ctx as *mut KidCtx)).out.push(item) };
        }
        return;
    }
    let i = c.counter;
    c.counter += 1;
    if i != c.path[c.depth] {
        return;
    }
    // the part on the path: walk into it (only one path, so the walk ends after it)
    let Some(k) = (unsafe { *info.kids.add(ty as usize) }) else {
        c.done = true;
        return;
    };
    if c.depth + 1 == c.path.len() {
        c.listing = true;
        c.found = true;
    } else {
        c.depth += 1;
        c.counter = 0;
    }
    unsafe { k(p, ctx) };
    let c = unsafe { &mut *(ctx as *mut KidCtx) };
    c.listing = false;
    c.done = true;
}

/// Generated children functions report a named part.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_dbg_kid(ctx: *mut c_void, name: *const c_char, ty: i64, p: *mut c_void) {
    unsafe { kid(ctx, &|| cstr(name).to_string(), ty as u32, p) }
}

/// The elements of a list (`elem` bytes each).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_dbg_kid_arr(ctx: *mut c_void, a: *mut c_void, ty: i64, elem: i64) {
    let a = a as *const crate::DuckArr;
    if a.is_null() {
        return;
    }
    let (len, data) = unsafe { ((*a).len, (*a).data) };
    let c = unsafe { &mut *(ctx as *mut KidCtx) };
    if c.done {
        return;
    }
    let at = |i: i64| unsafe { data.add((i * elem) as usize).cast::<c_void>() };
    if !c.listing {
        // walking through: straight to the element on the path
        let i = c.path[c.depth] as i64;
        if i < len {
            c.counter = i as u32;
            unsafe { kid(ctx, &|| i.to_string(), ty as u32, at(i)) };
        } else {
            c.done = true;
        }
        return;
    }
    let shown = if c.count_only { 0 } else { (len as usize).min(KIDS_MAX.saturating_sub(c.out.len())) };
    for i in 0..shown as i64 {
        unsafe { kid(ctx, &|| i.to_string(), ty as u32, at(i)) };
    }
    unsafe { (*(ctx as *mut KidCtx)).more += len as usize - shown };
}

/// The entries of a map: each value, named by its key shown.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_dbg_kid_map(ctx: *mut c_void, m: *mut c_void, ty: i64) {
    let m = m as *const crate::DuckMap;
    if m.is_null() {
        return;
    }
    let (mut it, mut k, mut v): (i64, *mut c_void, *mut c_void) = (0, std::ptr::null_mut(), std::ptr::null_mut());
    while unsafe { crate::map::duck_map_next(m, &mut it, &mut k, &mut v) } {
        let key = k;
        let name = || unsafe {
            match (*(*m).kops).show {
                Some(show) => {
                    let s = show(key);
                    let out = String::from_utf8_lossy(sbytes(s)).into_owned();
                    crate::rc::release(s);
                    out
                }
                None => "?".into(),
            }
        };
        unsafe { kid(ctx, &name, ty as u32, v) };
    }
}

/// A value of type `ty` at `p`, shown (cut to about 1000 chars).
fn show(info: &Info, ty: u32, p: *mut c_void) -> String {
    const MAX: usize = 1000;
    let f = unsafe { *info.shows.add(ty as usize) };
    let left = crate::trace::show_left();
    crate::trace::set_show_left(MAX as i64 + 24);
    let s: *mut DuckStr = unsafe { f(p) };
    crate::trace::set_show_left(left);
    let mut out = String::from_utf8_lossy(unsafe { sbytes(s) }).into_owned();
    unsafe { crate::rc::release(s) };
    if out.len() > MAX {
        let mut end = MAX;
        while !out.is_char_boundary(end) {
            end -= 1;
        }
        out.truncate(end);
        out += "…";
    }
    out
}

// ---- the connection ---------------------------------------------------------------------

fn emit(line: &str) {
    let mut o = OUT.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(c) = o.as_mut() {
        let mut b = line.as_bytes().to_vec();
        b.push(b'\n');
        if c.write_all(&b).is_err() {
            *o = None;
        }
    }
}

fn reply(seq: Option<i64>, ev: &str, rest: &str) {
    let seq = seq.map(|n| format!(",\"seq\":{n}")).unwrap_or_default();
    emit(&format!("{{\"ev\":\"{ev}\"{seq}{rest}}}"));
}

fn esc(s: &str) -> String {
    let mut o = String::new();
    json_str(&mut o, s);
    o[1..o.len() - 1].to_string()
}

fn json_str(o: &mut String, s: &str) {
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
}

/// Parse the debug info text (see `dbg_tables` in src/build.rs).
fn parse(text: &str, shows: *const ShowFn, kids: *const Option<KidsFn>) -> Info {
    let mut info = Info { files: Vec::new(), types: Vec::new(), fns: Vec::new(), sites: Vec::new(), shows, kids, bp: Vec::new() };
    for line in text.lines() {
        let Some((k, rest)) = line.split_once(' ') else { continue };
        match k {
            "p" => info.files.push(rest.to_string()),
            "t" => info.types.push(rest.to_string()),
            "f" => info.fns.push(FnInfo { name: rest.to_string(), locals: Vec::new() }),
            "v" => {
                let (t, n) = rest.split_once(' ').unwrap_or((rest, "?"));
                if let Some(f) = info.fns.last_mut() {
                    f.locals.push((n.to_string(), t.parse().unwrap_or(0)));
                }
            }
            "s" => {
                let w: Vec<&str> = rest.split(' ').collect();
                let n = |i: usize| w.get(i).and_then(|x| x.parse::<u32>().ok()).unwrap_or(0);
                let vis = w.get(4).map(|v| v.split(',').filter_map(|x| x.parse().ok()).collect()).unwrap_or_default();
                info.sites.push(Site { func: n(0), file: n(1), line: n(2), col: n(3), vis });
            }
            _ => {}
        }
    }
    info.bp = (0..info.sites.len()).map(|_| AtomicU32::new(0)).collect();
    info
}

/// The sites of a breakpoint spec (`file:line` or a function name) and its resolved line.
fn resolve(info: &Info, spec: &str) -> Result<(Vec<u32>, String, u32), String> {
    if let Some((file, line)) = spec.rsplit_once(':')
        && let Ok(line) = line.parse::<u32>()
    {
        let want = std::fs::canonicalize(file).map(|p| p.display().to_string()).unwrap_or_else(|_| file.to_string());
        let matches = |f: &str| f == want || f.ends_with(&format!("/{file}")) || f == file;
        let files: Vec<u32> = (0..info.files.len() as u32).filter(|&i| matches(&info.files[i as usize])).collect();
        if files.is_empty() {
            return Err(format!("no code in `{file}`"));
        }
        let best = info.sites.iter().filter(|s| files.contains(&s.file) && s.line >= line).map(|s| s.line).min();
        let Some(best) = best else { return Err(format!("no code at or after {file}:{line}")) };
        // the first statement on that line in each function (instance)
        let mut sites = Vec::new();
        let mut fns = Vec::new();
        for (i, s) in info.sites.iter().enumerate() {
            if files.contains(&s.file) && s.line == best && !fns.contains(&s.func) {
                fns.push(s.func);
                sites.push(i as u32);
            }
        }
        let path = info.files[info.sites[sites[0] as usize].file as usize].clone();
        return Ok((sites, path, best));
    }
    let mut sites = Vec::new();
    for (fi, f) in info.fns.iter().enumerate() {
        if (f.name == spec || f.name.ends_with(&format!(".{spec}")))
            && let Some(i) = info.sites.iter().position(|s| s.func as usize == fi)
        {
            sites.push(i as u32);
        }
    }
    match sites.first() {
        Some(&s) => {
            let site = &info.sites[s as usize];
            Ok((sites, info.files[site.file as usize].clone(), site.line))
        }
        None => Err(format!("no function `{spec}`")),
    }
}

/// The connection's reader: commands that don't need a stopped thread run here; the others go
/// to the focus thread's queue.
fn reader(conn: UnixStream) {
    let info = INFO.get().expect("info");
    for line in BufReader::new(conn).lines() {
        let Ok(line) = line else { break };
        let mut words: Vec<String> = line.split_whitespace().map(String::from).collect();
        let mut seq = None;
        let mut text = line.trim().to_string();
        if let Some(n) = words.first().and_then(|w| w.strip_prefix('@')).and_then(|n| n.parse().ok()) {
            seq = Some(n);
            words.remove(0);
            text = after_words(&text, 1).to_string();
        }
        if words.is_empty() {
            continue;
        }
        let mut s = st();
        match words[0].as_str() {
            "run" => {
                s.running = true;
                rearm(&s);
                CV.notify_all();
                drop(s);
                reply(seq, "ok", "");
            }
            "break" | "b" => {
                // `break <spec> [if <condition>]`
                let rest = after_words(&text, 1);
                let (spec, cond) = match rest.find(" if ") {
                    Some(i) => (rest[..i].trim(), Some(rest[i + 4..].trim().to_string()).filter(|c| !c.is_empty())),
                    None => (rest.trim(), None),
                };
                match resolve(info, spec) {
                    Ok((sites, file, line)) => {
                        for &x in &sites {
                            info.bp[x as usize].fetch_add(1, SeqCst);
                        }
                        let id = s.next_bp;
                        s.next_bp += 1;
                        let c = cond.as_deref().map(|c| {
                            let mut o = String::from(",\"cond\":");
                            json_str(&mut o, c);
                            o
                        });
                        s.bps.push(Bp { id, sites, cond });
                        rearm(&s);
                        drop(s);
                        let mut f = String::new();
                        json_str(&mut f, &file);
                        reply(seq, "break", &format!(",\"id\":{id},\"file\":{f},\"line\":{line}{}", c.unwrap_or_default()));
                    }
                    Err(e) => {
                        drop(s);
                        reply(seq, "error", &format!(",\"msg\":\"{}\"", esc(&e)));
                    }
                }
            }
            "delete" | "d" => {
                let id = words.get(1).and_then(|x| x.parse::<i64>().ok());
                let (gone, keep): (Vec<Bp>, Vec<Bp>) = std::mem::take(&mut s.bps).into_iter().partition(|b| id.is_none_or(|i| i == b.id));
                s.bps = keep;
                for b in &gone {
                    for &x in &b.sites {
                        info.bp[x as usize].fetch_sub(1, SeqCst);
                    }
                }
                rearm(&s);
                drop(s);
                reply(seq, "ok", "");
            }
            "catch" => {
                s.catch_mode = match words.get(1).map(String::as_str) {
                    Some("all") => CatchMode::All,
                    Some("none") => CatchMode::None,
                    _ => CatchMode::Uncaught,
                };
                drop(s);
                reply(seq, "ok", "");
            }
            "pause" => {
                if !s.stopped {
                    s.pause_req = true;
                    rearm(&s);
                }
                drop(s);
                reply(seq, "ok", "");
            }
            "kill" => {
                drop(s);
                reply(seq, "ok", "");
                unsafe {
                    libc::fflush(crate::c_stdout());
                    libc::_exit(137)
                };
            }
            _ if s.stopped => {
                s.queue.push_back((seq, text));
                CV.notify_all();
            }
            _ => {
                drop(s);
                reply(seq, "error", ",\"msg\":\"the program is running\"");
            }
        }
    }
    // the front end went away: let the program run on
    ATTACHED.store(false, SeqCst);
    let mut s = st();
    s.running = true;
    s.stopped = false;
    s.pause_req = false;
    s.stepping = false;
    s.epoch += 1;
    duck_dbg_armed.store(0, SeqCst);
    CV.notify_all();
}

extern "C" fn at_exit() {
    if ATTACHED.load(Relaxed) {
        emit("{\"ev\":\"exited\"}");
    }
}

/// Start the debugger (generated `main`, before anything else runs): attach to the front end
/// named by `DUCK_DEBUG` and wait for `run`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_dbg_init(text: *const c_char, shows: *const ShowFn, kids: *const Option<KidsFn>) {
    let Some(path) = std::env::var_os("DUCK_DEBUG") else { return };
    let conn = match UnixStream::connect(&path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("duck: debugger at {}: {e}", path.to_string_lossy());
            return;
        }
    };
    // under a debugger, output shows up as it is written (it goes to a pipe)
    unsafe { libc::setvbuf(crate::c_stdout(), std::ptr::null_mut(), libc::_IOLBF, 0) };
    let text = unsafe { cstr(text) };
    let _ = INFO.set(parse(&text, shows, kids));
    let Ok(rd) = conn.try_clone() else { return };
    *OUT.lock().unwrap_or_else(|e| e.into_inner()) = Some(conn);
    ATTACHED.store(true, SeqCst);
    unsafe { libc::atexit(at_exit) };
    tid();
    {
        let s = st();
        rearm(&s);
    }
    std::thread::spawn(move || reader(rd));
    emit(&format!("{{\"ev\":\"ready\",\"pid\":{}}}", std::process::id()));
    let mut s = st();
    while !s.running {
        s = wait(s);
    }
}
