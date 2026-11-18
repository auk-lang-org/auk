//! Contracts, assert, peek, the test runner and the program entry: now in C
//! (`runtime/c/testing.c`). These declarations keep the runtime's Rust tests compiling.

use std::ffi::{c_char, c_int};

use crate::*;

pub type AukTestFn = unsafe extern "C" fn() -> *mut AukErr;
pub type AukMainFn = unsafe extern "C" fn(*mut AukArr) -> AukRes_int;

unsafe extern "C" {
    pub unsafe fn auk_requires_fail(loc: *const c_char, cond_text: *const c_char) -> !;
    pub unsafe fn auk_ensures_fail(loc: *const c_char, cond_text: *const c_char) -> !;
    pub unsafe fn auk_hole(loc: *const c_char, expected: *const c_char) -> !;
    pub unsafe fn auk_assert_fail(loc: *const c_char, cond_text: *const c_char) -> !;
    pub unsafe fn auk_assert_fail_cmp(loc: *const c_char, cond_text: *const c_char, left: *const AukStr, right: *const AukStr) -> !;
    pub unsafe fn auk_peek(loc: *const c_char, src_text: *const c_char, shown: *const AukStr);
    pub unsafe fn auk_test_register(name: *const c_char, fn_: AukTestFn);
    pub unsafe fn auk_test_main(argc: c_int, argv: *mut *mut c_char) -> c_int;
    pub unsafe fn auk_main_wrapper(argc: c_int, argv: *mut *mut c_char, user_main: AukMainFn) -> c_int;
}
