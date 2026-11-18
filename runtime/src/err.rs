//! Err: now in C (`runtime/c/err.c`). These declarations keep the Rust modules not yet ported
//! compiling.

use std::ffi::{c_char, c_int};

use crate::*;

unsafe extern "C" {
    pub unsafe fn auk_err_new(msg: *const AukStr) -> *mut AukErr;
    pub unsafe fn auk_err_new_cstr(msg: *const c_char) -> *mut AukErr;
    pub unsafe fn auk_err_wrap(msg: *const AukStr, cause: *mut AukErr) -> *mut AukErr;
    pub unsafe fn auk_err_typed(type_id: u32, value: *const std::ffi::c_void, ops: *const AukElemOps, msg: *const AukStr) -> *mut AukErr;
    pub unsafe fn auk_err_payload(e: *const AukErr, type_id: u32) -> *const std::ffi::c_void;
    pub unsafe fn auk_err_show(e: *const AukErr) -> *mut AukStr;
    pub unsafe fn auk__err_free(e: *mut AukErr);
    pub unsafe fn auk__err_errno(what: *const c_char, subject: *const AukStr, err: c_int) -> *mut AukErr;
    fn auk__err_bytes(msg: *const u8, n: usize) -> *mut AukErr;
}

/// A new error from Rust text.
pub fn err_msg(msg: &str) -> *mut AukErr {
    unsafe { auk__err_bytes(msg.as_ptr(), msg.len()) }
}
