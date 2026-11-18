//! Core library (print, fs, net, time, rand, env, proc): now in C (`runtime/c/core.c`). These
//! declarations, and the helpers below, keep the Rust modules not yet ported (tls.rs) compiling.

use std::ffi::{CStr, c_char, c_int};

use crate::*;

unsafe extern "C" {
    pub unsafe fn auk__bytes_to_arr(b: *const u8, n: i64) -> *mut AukArr;
    pub unsafe fn auk_print(s: *const AukStr);
    pub unsafe fn auk_print_lit(cstr: *const c_char);
    pub unsafe fn auk_eprint(s: *const AukStr);
    pub unsafe fn auk_fs_read(path: *const AukStr) -> AukRes_str;
    pub unsafe fn auk_fs_write(path: *const AukStr, content: *const AukStr) -> AukRes_unit;
    pub unsafe fn auk_fs_append(path: *const AukStr, text: *const AukStr) -> AukRes_unit;
    pub unsafe fn auk_fs_lines(path: *const AukStr) -> AukRes_arr;
    pub unsafe fn auk_fs_exists(path: *const AukStr) -> bool;
    pub unsafe fn auk_fs_is_dir(path: *const AukStr) -> bool;
    pub unsafe fn auk_fs_list(dir: *const AukStr) -> AukRes_arr;
    pub unsafe fn auk_fs_mkdir(path: *const AukStr) -> AukRes_unit;
    pub unsafe fn auk_fs_remove(path: *const AukStr) -> AukRes_unit;
    pub unsafe fn auk_fs_rename(from: *const AukStr, to: *const AukStr) -> AukRes_unit;
    pub safe fn auk_fs_temp_dir() -> AukRes_str;
    pub unsafe fn auk_fs_read_bytes(path: *const AukStr) -> AukRes_arr;
    pub unsafe fn auk_fs_write_bytes(path: *const AukStr, bytes: *const AukArr) -> AukRes_unit;
    pub unsafe fn auk__tcp_connect(host: *const c_char, port: *const c_char, why: *mut *const c_char, err: *mut c_int) -> c_int;
    pub safe fn auk__conn_new(fd: c_int) -> *mut AukConn;
    pub unsafe fn auk_net_tcp(host: *const AukStr, port: i64) -> AukRes_conn;
    pub unsafe fn auk_net_listen(host: *const AukStr, port: i64) -> AukRes_listener;
    pub unsafe fn auk_listener_accept(l: *mut AukListener) -> AukRes_conn;
    pub unsafe fn auk_listener_port(l: *const AukListener) -> i64;
    pub unsafe fn auk_listener_close(l: *mut AukListener);
    pub unsafe fn auk__listener_free(l: *mut AukListener);
    pub unsafe fn auk_conn_read(c: *mut AukConn, max: i64) -> AukRes_arr;
    pub unsafe fn auk_conn_write(c: *mut AukConn, bytes: *const AukArr) -> AukRes_unit;
    pub unsafe fn auk_conn_close(c: *mut AukConn);
    pub unsafe fn auk__conn_free(c: *mut AukConn);
    pub safe fn auk_time_now() -> i64;
    pub safe fn auk_time_sleep(ms: i64);
    pub safe fn auk_rand_int(lo: i64, hi: i64) -> i64;
    pub safe fn auk_rand_float() -> f64;
    pub safe fn auk_rand_seed(seed: i64);
    pub unsafe fn auk_rand_bytes(n: i64, loc: *const c_char) -> *mut AukArr;
    pub unsafe fn auk_env_get(key: *const AukStr) -> AukOpt_str;
    pub unsafe fn auk_env_set_args(argc: c_int, argv: *mut *mut c_char);
    pub safe fn auk_env_args() -> *mut AukArr;
    pub safe fn auk_env_is_terminal(fd: i64) -> bool;
    pub safe fn auk_env_columns() -> AukOpt_int;
    pub safe fn auk_env_read_line() -> AukOpt_str;
    pub safe fn auk_env_read_all() -> AukRes_str;
    pub safe fn auk_env_lines() -> *mut AukArr;
    pub unsafe fn auk_proc_run(cmd: *const AukStr, args: *const AukArr) -> AukRes_str;
    pub unsafe fn auk_proc_exit(code: i64, loc: *const c_char) -> !;
    #[link_name = "auk__send_flags"]
    pub safe static SEND_FLAGS: c_int;
}

/// The NUL-terminated bytes of s ("" for NULL).
pub unsafe fn cs(s: *const AukStr) -> *const c_char {
    if s.is_null() { c"".as_ptr() } else { unsafe { (&raw const (*s).data).cast() } }
}

/// The text `%s` of `cs(s)` prints (up to the first NUL).
pub unsafe fn ctext<'a>(s: *const AukStr) -> std::borrow::Cow<'a, str> {
    unsafe { cstr(cs(s)) }
}

pub fn errno() -> c_int {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

pub fn strerror(e: c_int) -> String {
    unsafe { cstr(libc::strerror(e)).into_owned() }
}

/// An Err with message `msg` and code `code`.
pub unsafe fn err_code(msg: &str, code: c_int) -> *mut AukErr {
    let e = crate::err::err_msg(msg);
    unsafe { (*e).code = code as i64 };
    e
}

/// Bytes as a fresh `[int]` (0..255).
pub unsafe fn bytes_to_arr(b: &[u8]) -> *mut AukArr {
    unsafe { auk__bytes_to_arr(b.as_ptr(), b.len() as i64) }
}

/// A new open AukConn over fd.
pub unsafe fn conn_new(fd: c_int) -> *mut AukConn {
    auk__conn_new(fd)
}

/// Resolve host:port and connect a TCP socket. On failure: the reason text and an errno (0 for
/// a DNS failure).
pub unsafe fn tcp_connect(host: *const c_char, port: &CStr) -> Result<c_int, (String, c_int)> {
    let mut why: *const c_char = std::ptr::null();
    let mut err: c_int = 0;
    let fd = unsafe { auk__tcp_connect(host, port.as_ptr(), &mut why, &mut err) };
    if fd < 0 { Err((unsafe { cstr(why) }.into_owned(), err)) } else { Ok(fd) }
}
