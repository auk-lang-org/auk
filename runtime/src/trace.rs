//! Execution traces (`auk run --trace`, `auk test --trace`): a JSON Lines log of every traced
//! function call and return, error, `peek` and panic.
//!
//! Only programs compiled with tracing call into this module (the compiler wraps each traced
//! function in a `auk_trace_begin`/`auk_trace_call`/`auk_trace_exit`/`auk_trace_ret` shim and
//! makes `main` call `auk_trace_init`); every other program only pays for the `auk_trace_live`
//! test in `auk_peek` and `auk_panic`.
//!
//! Configuration (environment, read by `auk_trace_init`):
//!   AUK_TRACE=<file> | -    run: the event stream's file, `-` = stderr.
//!                            test: a directory (one `<test name>.jsonl` per test), or `-`:
//!                            each test keeps its last AUK_TRACE_TAIL events in memory and the
//!                            runner prints them under the test's FAIL line.
//!   AUK_TRACE_LIMIT=<n>     events written before a final {"ev":"truncated"} (default 10000).
//!   AUK_TRACE_TAIL=<n>      events kept for a failing test in `-` mode (default 20).
//!
//! Output is buffered here (not in a FILE) so a crash handler can still write it out with
//! write(2): a SIGSEGV from a stack overflow ends the trace with {"ev":"signal"}.
//!
//! The process-wide state lives in `static mut`s guarded by `LOCK` (a pthread mutex, as in C) so
//! the signal handler can read it without locking, best effort, exactly like the C version.

use crate::{AukErr, AukStr, c_stderr, cbytes, cstr, fwrite_bytes};
use std::cell::{Cell, RefCell};
use std::ffi::{CString, c_char, c_int, c_void};
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};

/// Is tracing on? Read by generated code and by `auk_peek`/`auk_panic` (same layout as C `bool`).
#[unsafe(no_mangle)]
pub static auk_trace_live: AtomicBool = AtomicBool::new(false);

thread_local! {
    /// The call site of the next traced call (C: `_Thread_local const char *auk_trace_site`).
    static TRACE_SITE: Cell<*const c_char> = const { Cell::new(std::ptr::null()) };
    static DEPTH: Cell<i64> = const { Cell::new(0) };
    /// > 0 while the tracer itself runs Auk code (a user `show`): nothing is traced.
    static MUTE: Cell<c_int> = const { Cell::new(0) };
    /// The call site of the call being traced (taken from auk_trace_site by auk_trace_begin).
    static SITE: Cell<*const c_char> = const { Cell::new(std::ptr::null()) };
    /// Each thread's event buffer: taken by new_line, given back by emit.
    static SCRATCH: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
}

/// The storage of this thread's trace site (the call site of the next traced call): generated
/// code stores the location through this pointer.
#[unsafe(no_mangle)]
pub extern "C" fn auk__trace_site_slot() -> *mut *const c_char {
    TRACE_SITE.with(|c| c.as_ptr())
}

fn live() -> bool {
    auk_trace_live.load(Relaxed)
}

unsafe extern "C" {
    #[link_name = "auk__show_exhausted"]
    pub safe fn show_exhausted() -> bool;
    #[link_name = "auk__show_left"]
    pub safe fn show_left() -> i64;
    /// -1: no budget.
    #[link_name = "auk__set_show_left"]
    pub safe fn set_show_left(v: i64);
}

/// The show budget of one traced value: enough for its first VALUE_MAX chars.
const SHOW_BUDGET: i64 = 256;
/// A shown value: at most 200 chars.
const VALUE_MAX: usize = 200;

const T_OFF: c_int = 0;
const T_STREAM: c_int = 1;
const T_TAIL: c_int = 2;

static mut MODE: c_int = T_OFF;
static mut CONFIGURED: bool = false;
static mut TEST_BINARY: bool = false;
static mut CFG: *const c_char = std::ptr::null();
static mut LIMIT: i64 = 10000;
static mut TAIL_N: i64 = 20;
static mut COUNT: i64 = 0;
static mut LOCK: libc::pthread_mutex_t = libc::PTHREAD_MUTEX_INITIALIZER;

/* T_STREAM: buffered output to fd */
static mut OUT_FD: c_int = -1;
static mut OUT_UNBUFFERED: bool = false;
const OBUF_SIZE: usize = 1 << 16;
static mut OBUF: [u8; OBUF_SIZE] = [0; OBUF_SIZE];
static mut OLEN: usize = 0;

/* T_TAIL: a ring of the last tail_n events, dumped to fd on exit */
static mut RING: *mut *mut u8 = std::ptr::null_mut();
static mut RING_LEN: *mut usize = std::ptr::null_mut();
static mut RING_CAP: *mut usize = std::ptr::null_mut();

fn lock() {
    unsafe { libc::pthread_mutex_lock(&raw mut LOCK) };
}
fn unlock() {
    unsafe { libc::pthread_mutex_unlock(&raw mut LOCK) };
}

// ---- line building ------------------------------------------------------------------------

type Line = Vec<u8>;

fn new_line() -> Line {
    let mut l = SCRATCH.try_with(|s| std::mem::take(&mut *s.borrow_mut())).unwrap_or_default();
    l.clear();
    l
}

fn put(l: &mut Line, s: &[u8]) {
    l.extend_from_slice(s);
}

fn put_int(l: &mut Line, v: i64) {
    let mut b = [0u8; 24];
    put(l, fmt_i64(&mut b, v));
}

/// Decimal text of v into b (no allocation: used by the signal handler).
fn fmt_i64(b: &mut [u8; 24], v: i64) -> &[u8] {
    let mut i = b.len();
    let neg = v < 0;
    let mut u = v.unsigned_abs();
    loop {
        i -= 1;
        b[i] = b'0' + (u % 10) as u8;
        u /= 10;
        if u == 0 {
            break;
        }
    }
    if neg {
        i -= 1;
        b[i] = b'-';
    }
    &b[i..]
}

/// A JSON string of s (UTF-8), cut after `max` chars (0 = no limit) with `...` (or always, with `cut`).
fn put_json(l: &mut Line, s: &[u8], max: usize, mut cut: bool) {
    put(l, b"\"");
    let mut chars = 0usize;
    for &c in s {
        if (c & 0xC0) != 0x80 {
            if max != 0 && chars == max {
                cut = true;
                break;
            }
            chars += 1;
        }
        match c {
            b'"' => put(l, b"\\\""),
            b'\\' => put(l, b"\\\\"),
            b'\n' => put(l, b"\\n"),
            b'\r' => put(l, b"\\r"),
            b'\t' => put(l, b"\\t"),
            _ => {
                if c < 0x20 || c == 0x7f {
                    const HEX: &[u8; 16] = b"0123456789abcdef";
                    put(l, &[b'\\', b'u', b'0', b'0', HEX[(c >> 4) as usize], HEX[(c & 15) as usize]]);
                } else {
                    l.push(c);
                }
            }
        }
    }
    if cut {
        put(l, b"...");
    }
    put(l, b"\"");
}

/// A JSON string of a C string (NULL → "").
unsafe fn put_cjson(l: &mut Line, s: *const c_char) {
    put_json(l, unsafe { cbytes(s) }, 0, false);
}

unsafe fn put_value(l: &mut Line, s: *const AukStr) {
    let b = unsafe { crate::sbytes(s) };
    // a show that used up its budget was cut short even if it is under VALUE_MAX chars
    put_json(l, b, VALUE_MAX, b.len() as i64 >= SHOW_BUDGET);
}

// ---- output -------------------------------------------------------------------------------

fn write_all(fd: c_int, mut p: &[u8]) {
    while !p.is_empty() {
        let w = unsafe { libc::write(fd, p.as_ptr().cast(), p.len()) };
        if w < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        if w <= 0 {
            return;
        }
        p = &p[w as usize..];
    }
}

unsafe fn out_flush_locked() {
    unsafe {
        if OUT_FD >= 0 && OLEN != 0 {
            write_all(OUT_FD, std::slice::from_raw_parts((&raw const OBUF).cast::<u8>(), OLEN));
        }
        OLEN = 0;
    }
}

unsafe fn out_bytes_locked(p: &[u8]) {
    unsafe {
        let n = p.len();
        if OLEN + n > OBUF_SIZE {
            out_flush_locked();
        }
        if n > OBUF_SIZE {
            write_all(OUT_FD, p);
            return;
        }
        std::ptr::copy_nonoverlapping(p.as_ptr(), (&raw mut OBUF).cast::<u8>().add(OLEN), n);
        OLEN += n;
    }
}

/// Record one event line (without its newline); `last`: the final event (a panic), recorded
/// even past the limit.
fn emit_ev(mut l: Line, last: bool) {
    l.push(b'\n');
    lock();
    unsafe {
        if MODE == T_STREAM && last {
            out_bytes_locked(&l);
        } else if MODE == T_STREAM && live() {
            out_bytes_locked(&l);
            COUNT += 1;
            if COUNT >= LIMIT {
                let lim = LIMIT;
                let b = format!("{{\"ev\":\"truncated\",\"limit\":{lim}}}\n");
                out_bytes_locked(b.as_bytes());
                auk_trace_live.store(false, Relaxed);
            }
            if OUT_UNBUFFERED {
                out_flush_locked();
            }
        } else if MODE == T_TAIL {
            let k = (COUNT % TAIL_N) as usize;
            let n = l.len();
            if *RING_CAP.add(k) < n {
                *RING.add(k) = crate::rc::auk__xrealloc((*RING.add(k)).cast(), n).cast();
                *RING_CAP.add(k) = n;
            }
            std::ptr::copy_nonoverlapping(l.as_ptr(), *RING.add(k), n);
            *RING_LEN.add(k) = n;
            COUNT += 1;
        }
    }
    unlock();
    // the line's buffer is reused by this thread's next event
    l.clear();
    let _ = SCRATCH.try_with(move |s| *s.borrow_mut() = l);
}

fn emit(l: Line) {
    emit_ev(l, false);
}

fn head(l: &mut Line, ev: &str) {
    put(l, b"{\"ev\":\"");
    put(l, ev.as_bytes());
    put(l, b"\"");
}

fn field(l: &mut Line, name: &str) {
    put(l, b",\"");
    put(l, name.as_bytes());
    put(l, b"\":");
}

fn end_depth(l: &mut Line, d: i64) {
    field(l, "depth");
    put_int(l, d);
    put(l, b"}");
}

/// Write everything recorded so far (T_TAIL: the ring, oldest first). Async-signal-safe enough
/// for the crash handler: it only uses write(2) on memory that already exists.
unsafe fn dump_locked() {
    unsafe {
        if MODE == T_STREAM {
            out_flush_locked();
        } else if MODE == T_TAIL && OUT_FD >= 0 {
            let n = if COUNT < TAIL_N { COUNT } else { TAIL_N };
            if COUNT > n {
                let mut b = [0u8; 24];
                write_all(OUT_FD, b"{\"ev\":\"truncated\",\"skipped\":");
                write_all(OUT_FD, fmt_i64(&mut b, COUNT - n));
                write_all(OUT_FD, b"}\n");
            }
            for i in COUNT - n..COUNT {
                let k = (i % TAIL_N) as usize;
                let p = *RING.add(k);
                if !p.is_null() {
                    write_all(OUT_FD, std::slice::from_raw_parts(p, *RING_LEN.add(k)));
                }
            }
            COUNT = 0;
        }
    }
}

// ---- crash handler ------------------------------------------------------------------------

extern "C" fn on_signal(sig: c_int) {
    // no lock: the crashing thread may hold it; this is best effort
    unsafe {
        dump_locked();
        if OUT_FD >= 0 {
            let mut b = [0u8; 24];
            write_all(OUT_FD, b"{\"ev\":\"signal\",\"signal\":");
            write_all(OUT_FD, fmt_i64(&mut b, sig as i64));
            write_all(OUT_FD, b"}\n");
        }
        libc::signal(sig, libc::SIG_DFL);
        libc::raise(sig);
    }
}

fn install_handlers() {
    static mut DONE: bool = false;
    unsafe {
        if DONE {
            return;
        }
        DONE = true;
        let mut ss: libc::stack_t = std::mem::zeroed();
        ss.ss_size = 1 << 16;
        ss.ss_sp = libc::malloc(ss.ss_size);
        ss.ss_flags = 0;
        if !ss.ss_sp.is_null() {
            libc::sigaltstack(&ss, std::ptr::null_mut());
        }
        let mut sa: libc::sigaction = std::mem::zeroed();
        sa.sa_sigaction = on_signal as extern "C" fn(c_int) as libc::sighandler_t;
        sa.sa_flags = libc::SA_ONSTACK | libc::SA_RESETHAND;
        libc::sigemptyset(&mut sa.sa_mask);
        for sig in [libc::SIGSEGV, libc::SIGBUS, libc::SIGFPE, libc::SIGILL, libc::SIGABRT] {
            libc::sigaction(sig, &sa, std::ptr::null_mut());
        }
    }
}

// ---- configuration ------------------------------------------------------------------------

fn env_int(name: &std::ffi::CStr, dflt: i64) -> i64 {
    unsafe {
        let v = libc::getenv(name.as_ptr());
        if v.is_null() || *v == 0 {
            return dflt;
        }
        let mut end: *mut c_char = std::ptr::null_mut();
        let n = libc::strtoll(v, &mut end, 10);
        if *end != 0 || n <= 0 { dflt } else { n }
    }
}

extern "C" fn flush_at_exit() {
    unsafe { auk__trace_flush() };
}

fn errno() -> c_int {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

fn strerror(e: c_int) -> String {
    unsafe { cstr(libc::strerror(e)).into_owned() }
}

fn start_stream(fd: c_int, unbuffered: bool) {
    static mut REGISTERED: bool = false;
    unsafe {
        if !REGISTERED {
            libc::atexit(flush_at_exit);
        }
        REGISTERED = true;
        OUT_FD = fd;
        OUT_UNBUFFERED = unbuffered;
        MODE = T_STREAM;
        COUNT = 0;
    }
    auk_trace_live.store(true, Relaxed);
    install_handlers();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_trace_init(tests: bool) {
    unsafe {
        CONFIGURED = true;
        TEST_BINARY = tests;
        CFG = libc::getenv(c"AUK_TRACE".as_ptr());
        if !CFG.is_null() && *CFG == 0 {
            CFG = std::ptr::null();
        }
        LIMIT = env_int(c"AUK_TRACE_LIMIT", 10000);
        TAIL_N = env_int(c"AUK_TRACE_TAIL", 20);
        if tests || CFG.is_null() {
            return;
        }
        if cbytes(CFG) == b"-" {
            start_stream(2, true);
            return;
        }
        let fd = libc::open(CFG, libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC | libc::O_CLOEXEC, 0o644 as libc::c_uint);
        if fd < 0 {
            let e = errno();
            fwrite_bytes(c_stderr(), format!("auk: cannot write the trace to {}: {}\n", cstr(CFG), strerror(e)).as_bytes());
            return;
        }
        start_stream(fd, false);
    }
}

pub unsafe fn auk__trace_tail_mode() -> bool {
    unsafe { CONFIGURED && TEST_BINARY && !CFG.is_null() && cbytes(CFG) == b"-" }
}

pub unsafe fn auk__trace_dir() -> *const c_char {
    unsafe {
        if CONFIGURED && TEST_BINARY && !CFG.is_null() && cbytes(CFG) != b"-" { CFG } else { std::ptr::null() }
    }
}

/// The trace file of a test in directory mode: <dir>/<name with [^A-Za-z0-9_-] as _>.jsonl
unsafe fn test_file(dir: *const c_char, name: *const c_char) -> CString {
    let mut p: Vec<u8> = unsafe { cbytes(dir) }.to_vec();
    p.push(b'/');
    for &c in unsafe { cbytes(name) } {
        let keep = c.is_ascii_alphanumeric() || c == b'-' || c == b'_';
        p.push(if keep { c } else { b'_' });
    }
    p.extend_from_slice(b".jsonl");
    CString::new(p).expect("no NUL in a C string")
}

pub unsafe fn auk__trace_test_begin(name: *const c_char, tail_path: *const c_char) {
    unsafe {
        if !CONFIGURED || !TEST_BINARY || CFG.is_null() {
            return;
        }
        if !tail_path.is_null() {
            let fd = libc::open(tail_path, libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC | libc::O_CLOEXEC, 0o600 as libc::c_uint);
            if fd < 0 {
                return;
            }
            OUT_FD = fd;
            let n = TAIL_N as usize;
            RING = crate::rc::auk__xcalloc(n, size_of::<*mut u8>()).cast();
            RING_LEN = crate::rc::auk__xcalloc(n, size_of::<usize>()).cast();
            RING_CAP = crate::rc::auk__xcalloc(n, size_of::<usize>()).cast();
            MODE = T_TAIL;
            COUNT = 0;
            auk_trace_live.store(true, Relaxed);
            install_handlers();
            return;
        }
        libc::mkdir(CFG, 0o755);
        let path = test_file(CFG, name);
        let fd = libc::open(path.as_ptr(), libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC | libc::O_CLOEXEC, 0o644 as libc::c_uint);
        if fd < 0 {
            let e = errno();
            fwrite_bytes(
                c_stderr(),
                format!("auk: cannot write the trace to {}: {}\n", String::from_utf8_lossy(path.as_bytes()), strerror(e)).as_bytes(),
            );
        }
        drop(path);
        if fd >= 0 {
            start_stream(fd, false);
        }
    }
}

/// After the test's child exited: its outcome as the trace's last event. In directory mode it is
/// appended to the test's file; in tail mode the caller prints the file (when the test failed).
pub unsafe fn auk__trace_test_end(name: *const c_char, ok: bool, tail_path: *const c_char) {
    unsafe {
        let path = if tail_path.is_null() { Some(test_file(CFG, name)) } else { None };
        let p = match &path {
            Some(p) => p.as_ptr(),
            None => tail_path,
        };
        let fd = libc::open(p, libc::O_WRONLY | libc::O_APPEND | libc::O_CREAT | libc::O_CLOEXEC, 0o644 as libc::c_uint);
        drop(path);
        if fd < 0 {
            return;
        }
        let mut l = Line::new();
        head(&mut l, "test");
        field(&mut l, "name");
        put_cjson(&mut l, name);
        field(&mut l, "result");
        put(&mut l, if ok { b"\"ok\"}\n" } else { b"\"FAIL\"}\n" });
        write_all(fd, &l);
        libc::close(fd);
    }
}

pub unsafe fn auk__trace_flush() {
    unsafe {
        if MODE == T_OFF {
            return;
        }
        lock();
        dump_locked();
        unlock();
    }
}

// ---- events -------------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_trace_begin() -> bool {
    if !live() || MUTE.with(|m| m.get()) != 0 {
        return false;
    }
    MUTE.with(|m| m.set(m.get() + 1));
    SITE.with(|s| s.set(TRACE_SITE.with(|t| t.replace(std::ptr::null()))));
    set_show_left(SHOW_BUDGET);
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_trace_call(fn_: *const c_char, loc: *const c_char, n: c_int, args: *mut *mut AukStr) {
    set_show_left(-1);
    let mut l = new_line();
    head(&mut l, "call");
    field(&mut l, "fn");
    unsafe { put_cjson(&mut l, fn_) };
    field(&mut l, "loc");
    let site = SITE.with(|s| s.get());
    unsafe { put_cjson(&mut l, if site.is_null() { loc } else { site }) };
    field(&mut l, "args");
    put(&mut l, b"[");
    for i in 0..n.max(0) as usize {
        if i != 0 {
            put(&mut l, b",");
        }
        unsafe {
            let a = *args.add(i);
            put_value(&mut l, a);
            crate::rc::auk_release(a.cast::<c_void>());
        }
    }
    put(&mut l, b"]");
    let d = DEPTH.with(|d| d.get());
    end_depth(&mut l, d);
    emit(l);
    DEPTH.with(|d| d.set(d.get() + 1));
    MUTE.with(|m| m.set(m.get() - 1));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_trace_exit() -> bool {
    DEPTH.with(|d| d.set(d.get() - 1));
    if !live() || MUTE.with(|m| m.get()) != 0 {
        return false;
    }
    MUTE.with(|m| m.set(m.get() + 1));
    set_show_left(SHOW_BUDGET);
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_trace_ret(fn_: *const c_char, shown: *mut AukStr) {
    set_show_left(-1);
    let mut l = new_line();
    head(&mut l, "ret");
    field(&mut l, "fn");
    unsafe { put_cjson(&mut l, fn_) };
    field(&mut l, "value");
    if !shown.is_null() {
        unsafe {
            put_value(&mut l, shown);
            crate::rc::auk_release(shown.cast::<c_void>());
        }
    } else {
        put(&mut l, b"\"()\"");
    }
    end_depth(&mut l, DEPTH.with(|d| d.get()));
    emit(l);
    MUTE.with(|m| m.set(m.get() - 1));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_trace_err(fn_: *const c_char, e: *const AukErr) {
    let s = unsafe { crate::err::auk_err_show(e as *mut AukErr) };
    set_show_left(-1);
    let mut l = new_line();
    head(&mut l, "err");
    field(&mut l, "fn");
    unsafe { put_cjson(&mut l, fn_) };
    field(&mut l, "error");
    unsafe {
        put_value(&mut l, s);
        crate::rc::auk_release(s.cast::<c_void>());
    }
    end_depth(&mut l, DEPTH.with(|d| d.get()));
    emit(l);
    MUTE.with(|m| m.set(m.get() - 1));
}

pub unsafe fn auk__trace_peek(loc: *const c_char, src_text: *const c_char, shown: *const AukStr) {
    if !live() || MUTE.with(|m| m.get()) != 0 {
        return;
    }
    let mut l = new_line();
    head(&mut l, "peek");
    field(&mut l, "loc");
    unsafe { put_cjson(&mut l, loc) };
    field(&mut l, "expr");
    unsafe { put_cjson(&mut l, src_text) };
    field(&mut l, "value");
    unsafe { put_value(&mut l, shown) };
    end_depth(&mut l, DEPTH.with(|d| d.get()));
    emit(l);
}

/// A panic: records it and writes out the trace (the process is about to _exit).
#[allow(clippy::not_unsafe_ptr_arg_deref)]
/// `caught`: the panic jumps to a recovery point (`catch`, a task thread) instead of ending the
/// process; the event gets `"caught":true`.
pub fn auk__trace_panic(loc: *const c_char, msg: &str, caught: bool) {
    if unsafe { MODE } == T_OFF {
        return;
    }
    {
        // C took the message as a C string: it ends at the first NUL.
        let m = msg.as_bytes();
        let m = &m[..m.iter().position(|&b| b == 0).unwrap_or(m.len())];
        let mut l = new_line();
        head(&mut l, "panic");
        field(&mut l, "msg");
        put_json(&mut l, m, 0, false);
        field(&mut l, "loc");
        if loc.is_null() {
            put(&mut l, b"\"<unknown>\"");
        } else {
            unsafe { put_cjson(&mut l, loc) };
        }
        if caught {
            put(&mut l, b",\"caught\":true");
        }
        end_depth(&mut l, DEPTH.with(|d| d.get()));
        emit_ev(l, true);
    }
    unsafe { auk__trace_flush() };
}

/// rc.c's panic path calls this.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk__trace_on_panic(loc: *const c_char, msg: *const u8, n: usize, caught: bool) {
    let msg = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(msg, n) });
    auk__trace_panic(loc, &msg, caught)
}

/// This thread's call depth and mute count, saved at a recovery point (`catch`, a task) and put
/// back when a panic jumps past traced frames that never got to exit.
pub fn save_state() -> (i64, c_int) {
    (DEPTH.with(|d| d.get()), MUTE.with(|m| m.get()))
}

pub fn restore_state(s: (i64, c_int)) {
    DEPTH.with(|d| d.set(s.0));
    MUTE.with(|m| m.set(s.1));
}
