//! Core library (print, fs, net, time, rand, env, proc): now in C (`runtime/c/core.c`). These
//! declarations keep the runtime's Rust tests compiling.

use std::ffi::{c_char, c_int};

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
