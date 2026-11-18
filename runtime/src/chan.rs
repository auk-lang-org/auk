//! Channels: now in C (`runtime/c/chan.c`). These declarations keep the Rust modules not yet
//! ported compiling.

use std::ffi::{c_char, c_void};

use crate::*;

/// A channel (opaque; chan.c).
pub enum AukChan {}

unsafe extern "C" {
    pub unsafe fn auk_chan_new(proto: *mut AukArr) -> *mut AukChan;
    pub unsafe fn auk_chan_send(c: *mut AukChan, x: *const c_void, loc: *const c_char);
    pub unsafe fn auk_chan_recv(c: *mut AukChan, out: *mut c_void) -> bool;
    pub unsafe fn auk_chan_recv_for(c: *mut AukChan, ms: i64, out: *mut c_void) -> bool;
    pub unsafe fn auk_chan_close(c: *mut AukChan);
}
