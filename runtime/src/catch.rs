//! Recovering from panics (`catch e` and task threads): now in C (`runtime/c/catch.c`). This
//! keeps the Rust modules not yet ported compiling.

use std::ffi::{c_char, c_void};

use crate::task::AukThunk;
use crate::*;

#[repr(C)]
struct AukPanic {
    msg: *mut c_char,
    loc: *mut c_char,
}

unsafe extern "C" {
    fn auk__catch_call(f: AukThunk, env: *mut c_void, out: *mut c_void) -> *mut AukPanic;
    fn auk__panic_free(p: *mut AukPanic);
    pub unsafe fn auk_catch(f: AukThunk, env: *mut c_void, out: *mut c_void) -> *mut AukErr;
}

/// A recovered panic: its message and where it happened.
#[derive(Clone)]
pub struct Panic {
    pub msg: String,
    pub loc: String,
}

/// Run `f(env, out)` under a recovery point: None if it finished, the panic if one jumped back.
pub unsafe fn run(f: AukThunk, env: *mut c_void, out: *mut c_void) -> Option<Panic> {
    unsafe {
        let p = auk__catch_call(f, env, out);
        if p.is_null() {
            return None;
        }
        let r = Panic { msg: cstr((*p).msg).into_owned(), loc: cstr((*p).loc).into_owned() };
        auk__panic_free(p);
        Some(r)
    }
}
