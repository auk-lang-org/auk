//! Shared helpers for the runtime's unit tests (the port of the old C harness).
//!
//! Every test body runs through [`run`], which serializes the tests of one binary (the live
//! object counter is process-global) and checks that `auk_live_objects()` is back to its
//! starting value afterwards. [`child`] / [`expect_panic`] fork to observe panics and output.
#![allow(dead_code)]

use std::ffi::{CString, c_char, c_void};
use std::sync::Mutex;

use auk_rt::rc::{auk_live_objects, auk_release, auk_retain};
use auk_rt::str::auk_str_lit;
use auk_rt::*;

static SERIAL: Mutex<()> = Mutex::new(());

/// Runs a test body serially and checks it leaked no runtime objects.
pub fn run(f: impl FnOnce()) {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let live0 = auk_live_objects();
    f();
    let live1 = auk_live_objects();
    assert_eq!(live1, live0, "leak check: {live0} live objects before, {live1} after");
}

/// An owned str from text (C's `S(lit)`, i.e. `auk_str_lit`).
pub fn s(text: &str) -> *mut AukStr {
    let c = CString::new(text).expect("no NUL");
    unsafe { auk_str_lit(c.as_ptr()) }
}

/// Release any runtime object.
pub fn rel<T>(p: *mut T) {
    unsafe { auk_release(p.cast()) }
}

/// Retain any runtime object (returns it).
pub fn ret<T>(p: *mut T) -> *mut T {
    unsafe { auk_retain(p.cast()).cast() }
}

/// The text of a (borrowed) str.
pub fn text(p: *const AukStr) -> String {
    String::from_utf8_lossy(unsafe { sbytes(p) }).into_owned()
}

/// Compare an OWNED str with `want` (bytes and byte length), then release it.
#[track_caller]
pub fn check_str(p: *mut AukStr, want: &str) {
    let got = unsafe { sbytes(p) }.to_vec();
    let blen = unsafe { auk_rt::str::auk_str_byte_len(p) };
    rel(p);
    assert!(
        got == want.as_bytes() && blen as usize == want.len(),
        "got {:?}, want {:?}",
        String::from_utf8_lossy(&got),
        want
    );
}

/// The shown text of an owned error, releasing the error.
pub fn err_text(e: *mut AukErr) -> String {
    let m = unsafe { auk_rt::err::auk_err_show(e) };
    let t = text(m);
    rel(m);
    rel(e);
    t
}

/// Typed element read (C's `AUK_ARR_AT`).
pub fn at<T: Copy>(a: *const AukArr, i: i64) -> T {
    unsafe { *(auk_rt::arr::auk_arr_at(a, i, c"t".as_ptr()) as *const T) }
}

/// Push an rvalue (C's `AUK_ARR_PUSH`).
pub fn push<T>(a: &mut *mut AukArr, v: T) {
    unsafe { auk_rt::arr::auk_arr_push(a, (&raw const v).cast::<c_void>()) }
}

/// An int array from values.
pub fn ints(xs: &[i64]) -> *mut AukArr {
    let mut a = unsafe { auk_rt::arr::auk_arr_new(&auk_rt::rc::auk_ops_int, 0) };
    for &x in xs {
        push(&mut a, x);
    }
    a
}

/// Write to the C library's stdout (what the runtime's own output goes through).
pub fn cprint(t: &str) {
    fwrite_bytes(c_stdout(), t.as_bytes());
}

/// An argv for C entry points (leaked: the runtime may keep pointers into it).
pub fn argv(args: &[&str]) -> *mut *mut c_char {
    let mut v: Vec<*mut c_char> = args.iter().map(|a| CString::new(*a).unwrap().into_raw()).collect();
    v.push(std::ptr::null_mut());
    Box::leak(v.into_boxed_slice()).as_mut_ptr()
}

fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

/// Runs `f` in a forked child with stdout and stderr both going into one pipe; returns the
/// exit code (or 128+signal) and the captured output. The child `_exit(0)`s after `f`
/// (a Rust panic in the child exits 98).
pub fn child(f: impl FnOnce()) -> (i32, String) {
    unsafe {
        libc::fflush(std::ptr::null_mut());
        let mut fds = [0i32; 2];
        assert!(libc::pipe(fds.as_mut_ptr()) == 0);
        let pid = libc::fork();
        assert!(pid >= 0, "fork failed");
        if pid == 0 {
            libc::close(fds[0]);
            libc::dup2(fds[1], 1);
            libc::dup2(fds[1], 2);
            libc::close(fds[1]);
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
            libc::fflush(c_stdout());
            libc::fflush(c_stderr());
            libc::_exit(if r.is_ok() { 0 } else { 98 });
        }
        libc::close(fds[1]);
        let mut out = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            let r = libc::read(fds[0], buf.as_mut_ptr().cast(), buf.len());
            if r < 0 && errno() == libc::EINTR {
                continue;
            }
            if r <= 0 {
                break;
            }
            out.extend_from_slice(&buf[..r as usize]);
        }
        libc::close(fds[0]);
        let mut status = 0;
        while libc::waitpid(pid, &mut status, 0) < 0 && errno() == libc::EINTR {}
        let code = if libc::WIFEXITED(status) { libc::WEXITSTATUS(status) } else { 128 + libc::WTERMSIG(status) };
        (code, String::from_utf8_lossy(&out).into_owned())
    }
}

/// Asserts that `f` panics (exit 101, `panic: ` in the output) with output containing `needle`.
#[track_caller]
pub fn expect_panic(f: impl FnOnce(), needle: &str) {
    let (code, out) = child(f);
    assert_eq!(code, 101, "expected exit 101 (panic), got {code}; output:\n{out}");
    assert!(out.contains("panic: "), "no 'panic:' in output:\n{out}");
    assert!(out.contains(needle), "panic output lacks {needle:?}:\n{out}");
}

/// A fresh scratch directory, removed when dropped.
pub struct TempDir(pub String);

impl TempDir {
    pub fn new() -> TempDir {
        let base = std::env::temp_dir();
        let mut tmpl = format!("{}/aukrt-XXXXXX", base.to_string_lossy().trim_end_matches('/')).into_bytes();
        tmpl.push(0);
        let p = unsafe { libc::mkdtemp(tmpl.as_mut_ptr().cast()) };
        assert!(!p.is_null(), "mkdtemp failed");
        tmpl.pop();
        TempDir(String::from_utf8(tmpl).unwrap())
    }
    /// An owned str naming `name` inside the directory.
    pub fn path(&self, name: &str) -> *mut AukStr {
        s(&format!("{}/{}", self.0, name))
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Should tests reach real hosts? `AUK_NET_TESTS=1`/`0` decides; unset, probe example.com:443
/// with a 3s connect timeout.
pub fn net_tests() -> bool {
    use std::net::{TcpStream, ToSocketAddrs};
    use std::time::Duration;
    match std::env::var("AUK_NET_TESTS").as_deref() {
        Ok("1") => true,
        Ok(_) => false,
        Err(_) => ("example.com", 443)
            .to_socket_addrs()
            .is_ok_and(|mut a| a.any(|a| TcpStream::connect_timeout(&a, Duration::from_secs(3)).is_ok())),
    }
}

/// The elements of an int array (copied; safe for an empty array with no buffer).
pub fn int_elems(a: *const AukArr) -> Vec<i64> {
    unsafe {
        let n = auk_rt::arr::auk_arr_len(a) as usize;
        if n == 0 {
            return Vec::new();
        }
        std::slice::from_raw_parts(auk_rt::arr::auk_arr_data(a) as *const i64, n).to_vec()
    }
}
