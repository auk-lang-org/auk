//! Execution traces: now in C (`runtime/c/trace.c`, which explains them). These declarations
//! keep the Rust modules not yet ported compiling.

use std::ffi::c_char;
use std::sync::atomic::AtomicBool;

use crate::*;

unsafe extern "C" {
    pub safe static auk_trace_live: AtomicBool;
    #[link_name = "auk__show_exhausted"]
    pub safe fn show_exhausted() -> bool;
    #[link_name = "auk__show_left"]
    pub safe fn show_left() -> i64;
    /// -1: no budget.
    #[link_name = "auk__set_show_left"]
    pub safe fn set_show_left(v: i64);
    pub unsafe fn auk_trace_init(tests: bool);
    pub unsafe fn auk__trace_tail_mode() -> bool;
    pub unsafe fn auk__trace_dir() -> *const c_char;
    pub unsafe fn auk__trace_test_begin(name: *const c_char, tail_path: *const c_char);
    pub unsafe fn auk__trace_test_end(name: *const c_char, ok: bool, tail_path: *const c_char);
    pub unsafe fn auk__trace_flush();
    pub unsafe fn auk__trace_peek(loc: *const c_char, src_text: *const c_char, shown: *const AukStr);
}
