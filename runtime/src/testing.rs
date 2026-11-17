//! Contracts, holes, assert, peek, the test registry/runner and program entry.

use crate::{DuckArr, DuckErr, DuckRes_int, DuckStr, c_stderr, c_stdout, cstr, fwrite_bytes, rt_panic, sstr};
use std::ffi::{CString, c_char, c_int, c_void};
use std::sync::Mutex;

unsafe extern "C" {
    fn flockfile(f: *mut libc::FILE);
    fn funlockfile(f: *mut libc::FILE);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_requires_fail(loc: *const c_char, cond_text: *const c_char) -> ! {
    rt_panic!(loc, "requires failed: {}", unsafe { cstr(cond_text) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_ensures_fail(loc: *const c_char, cond_text: *const c_char) -> ! {
    rt_panic!(loc, "ensures failed: {}", unsafe { cstr(cond_text) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_hole(loc: *const c_char, expected: *const c_char) -> ! {
    rt_panic!(loc, "unfilled hole (expected {})", unsafe { cstr(expected) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_assert_fail(loc: *const c_char, cond_text: *const c_char) -> ! {
    rt_panic!(loc, "assertion failed: {}", unsafe { cstr(cond_text) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_assert_fail_cmp(
    loc: *const c_char,
    cond_text: *const c_char,
    left: *const DuckStr,
    right: *const DuckStr,
) -> ! {
    rt_panic!(loc, "assertion failed: {}\n  left: {}\n  right: {}", unsafe { cstr(cond_text) }, unsafe { sstr(left) }, unsafe {
        sstr(right)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_peek(loc: *const c_char, src_text: *const c_char, shown: *const DuckStr) {
    unsafe {
        libc::fflush(c_stdout());
        let line = format!("[{}] {} = {}\n", cstr(loc), cstr(src_text), sstr(shown));
        flockfile(c_stderr());
        fwrite_bytes(c_stderr(), line.as_bytes());
        funlockfile(c_stderr());
        if crate::trace::duck_trace_live.load(std::sync::atomic::Ordering::Relaxed) {
            crate::trace::duck__trace_peek(loc, src_text, shown);
        }
    }
}

// ---- tests --------------------------------------------------------------------------------

pub type DuckTestFn = unsafe extern "C" fn() -> *mut DuckErr;
pub type DuckMainFn = unsafe extern "C" fn(*mut DuckArr) -> DuckRes_int;

#[derive(Clone, Copy)]
struct TestEntry {
    name: *const c_char,
    fn_: DuckTestFn,
}
// The names are static strings of the generated program.
unsafe impl Send for TestEntry {}

static TESTS: Mutex<Vec<TestEntry>> = Mutex::new(Vec::new());

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_test_register(name: *const c_char, fn_: DuckTestFn) {
    TESTS.lock().unwrap_or_else(|e| e.into_inner()).push(TestEntry { name, fn_ });
}

fn out(b: &[u8]) {
    fwrite_bytes(c_stdout(), b);
}

/// Each line of p as `    <line>\n` (C printed it with `%.*s`, which stops at a NUL byte).
fn print_indented(p: &[u8]) {
    let mut s = Vec::with_capacity(p.len() + 16);
    let mut i = 0;
    while i < p.len() {
        let mut j = i;
        while j < p.len() && p[j] != b'\n' {
            j += 1;
        }
        let line = &p[i..j];
        let line = &line[..line.iter().position(|&b| b == 0).unwrap_or(line.len())];
        s.extend_from_slice(b"    ");
        s.extend_from_slice(line);
        s.push(b'\n');
        i = j + 1;
    }
    out(&s);
}

/// Print a test's trace tail (tail mode) under its FAIL line.
fn print_trace(path: &CString) {
    use std::os::unix::ffi::OsStrExt;
    let Ok(b) = std::fs::read(std::ffi::OsStr::from_bytes(path.as_bytes())) else { return };
    if !b.is_empty() {
        out(b"    trace (last events, oldest first):\n");
        print_indented(&b);
    }
}

fn errno() -> c_int {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

fn strerror(e: c_int) -> String {
    unsafe { cstr(libc::strerror(e)).into_owned() }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_test_main(argc: c_int, argv: *mut *mut c_char) -> c_int {
    unsafe {
        crate::core::duck_env_set_args(argc, argv);
        let filter: Option<&[u8]> = if argc > 1 { Some(crate::cbytes(*argv.add(1))) } else { None };
        let (mut passed, mut failed) = (0i64, 0i64);
        let tail = crate::trace::duck__trace_tail_mode();
        let traced = tail || !crate::trace::duck__trace_dir().is_null();
        let mut tail_path = CString::default();
        if tail {
            let tmp = libc::getenv(c"TMPDIR".as_ptr());
            let tmp = if !tmp.is_null() && *tmp != 0 { crate::cbytes(tmp) } else { b"/tmp" };
            let mut p = tmp.to_vec();
            p.extend_from_slice(format!("/duck-trace-{}.jsonl", libc::getpid()).as_bytes());
            p.truncate(1023); // C's char[1024]
            tail_path = CString::new(p).expect("no NUL in a C string");
        }
        let tail_ptr = if tail { tail_path.as_ptr() } else { std::ptr::null() };
        let tests: Vec<TestEntry> = TESTS.lock().unwrap_or_else(|e| e.into_inner()).clone();
        for t in &tests {
            let name = crate::cbytes(t.name);
            if let Some(f) = filter
                && !(f.is_empty() || name.windows(f.len()).any(|w| w == f))
            {
                continue;
            }
            libc::fflush(c_stdout());
            libc::fflush(c_stderr());
            let mut fds = [0 as c_int; 2];
            if libc::pipe(fds.as_mut_ptr()) < 0 {
                rt_panic!(c"duck test".as_ptr(), "pipe: {}", strerror(errno()));
            }
            let pid = libc::fork();
            if pid < 0 {
                rt_panic!(c"duck test".as_ptr(), "fork: {}", strerror(errno()));
            }
            if pid == 0 {
                libc::close(fds[0]);
                libc::dup2(fds[1], 1);
                libc::dup2(fds[1], 2);
                libc::close(fds[1]);
                if traced {
                    crate::trace::duck__trace_test_begin(t.name, tail_ptr);
                }
                let e = (t.fn_)();
                if !e.is_null() {
                    let s = crate::err::duck_err_show(e);
                    libc::fflush(c_stdout());
                    fwrite_bytes(c_stderr(), format!("error: {}\n", sstr(s)).as_bytes());
                    libc::fflush(c_stderr());
                    crate::trace::duck__trace_flush();
                    libc::_exit(1);
                }
                crate::trace::duck__trace_flush();
                if crate::rc::duck_leak_check() != 0 {
                    libc::_exit(1);
                }
                libc::fflush(c_stdout());
                libc::fflush(c_stderr());
                libc::_exit(0);
            }
            libc::close(fds[1]);
            let mut output: Vec<u8> = Vec::new();
            let mut buf = [0u8; 4096];
            loop {
                let r = libc::read(fds[0], buf.as_mut_ptr().cast::<c_void>(), buf.len());
                if r < 0 && errno() == libc::EINTR {
                    continue;
                }
                if r <= 0 {
                    break;
                }
                output.extend_from_slice(&buf[..r as usize]);
            }
            libc::close(fds[0]);
            let mut status: c_int = 0;
            while libc::waitpid(pid, &mut status, 0) < 0 && errno() == libc::EINTR {}
            let ok = libc::WIFEXITED(status) && libc::WEXITSTATUS(status) == 0;
            if traced {
                crate::trace::duck__trace_test_end(t.name, ok, tail_ptr);
            }
            let name_s = String::from_utf8_lossy(name);
            if ok {
                passed += 1;
                out(format!("ok {name_s}\n").as_bytes());
            } else {
                failed += 1;
                out(format!("FAIL {name_s}\n").as_bytes());
                if !output.is_empty() {
                    print_indented(&output);
                }
                if libc::WIFSIGNALED(status) {
                    out(format!("    (killed by signal {})\n", libc::WTERMSIG(status)).as_bytes());
                }
                if tail {
                    print_trace(&tail_path);
                }
            }
            if tail {
                libc::unlink(tail_ptr);
            }
        }
        out(format!("{passed} passed, {failed} failed\n").as_bytes());
        libc::fflush(c_stdout());
        if failed != 0 { 1 } else { 0 }
    }
}

// ---- program entry ------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_main_wrapper(argc: c_int, argv: *mut *mut c_char, user_main: DuckMainFn) -> c_int {
    // started by a `gui.open` of this same program to own its windows (gui.rs)
    if std::env::var_os("DUCK_GUI_HOST").is_some() {
        return crate::gui_host::host_main();
    }
    unsafe {
        crate::core::duck_env_set_args(argc, argv);
        let r = user_main(crate::core::duck_env_args());
        libc::fflush(c_stdout());
        if !r.ok {
            let s = crate::err::duck_err_show(r.err);
            fwrite_bytes(c_stderr(), format!("error: {}\n", sstr(s)).as_bytes());
            crate::rc::duck_release(s.cast::<c_void>());
            crate::rc::duck_release(r.err.cast::<c_void>());
            libc::fflush(c_stderr());
            if crate::rc::duck_leak_check() != 0 {
                return 102;
            }
            return 1;
        }
        if crate::rc::duck_leak_check() != 0 {
            return 102;
        }
        r.val as c_int
    }
}
