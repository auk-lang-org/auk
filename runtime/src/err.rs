//! Err: message, code, cause chain and an optional typed payload (was err.c).

use std::ffi::{c_char, c_int, c_void};
use std::sync::atomic::Ordering;

use crate::rc::{auk__alloc, auk__free_obj, auk__xmalloc, auk_release, auk_retain};
use crate::str::{auk_sb_finish, auk_sb_str, auk_str_lit, sb_bytes};
use crate::*;

/// New error; msg is borrowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_err_new(msg: *const AukStr) -> *mut AukErr {
    unsafe {
        let e = auk__alloc(size_of::<AukErr>(), AUK_K_ERR) as *mut AukErr;
        (*e).msg = if msg.is_null() { auk_str_lit(c"".as_ptr()) } else { auk_retain(msg as *mut c_void).cast() };
        e
    }
}

/// What C's `auk_err_fmt` did with its formatted text: push it through a string builder
/// (so it counts against a trace's show budget and invalid UTF-8 is repaired), then wrap it.
fn err_bytes(msg: &[u8]) -> *mut AukErr {
    unsafe {
        let mut b = AukStrBuf::INIT;
        sb_bytes(&mut b, msg);
        let s = auk_sb_finish(&mut b);
        let e = auk_err_new(s);
        auk_release(s.cast());
        e
    }
}

/// New error from Rust text (the replacement for C's variadic `auk_err_fmt`).
pub fn err_msg(msg: &str) -> *mut AukErr {
    err_bytes(msg.as_bytes())
}

/// A new error with a NUL-terminated message.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_err_new_cstr(msg: *const c_char) -> *mut AukErr {
    err_bytes(unsafe { cbytes(msg) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_err_wrap(msg: *const AukStr, cause: *mut AukErr) -> *mut AukErr {
    unsafe {
        let e = auk_err_new(msg);
        (*e).cause = auk_retain(cause.cast()).cast();
        e
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_err_typed(
    type_id: u32,
    value: *const c_void,
    ops: *const AukElemOps,
    msg: *const AukStr,
) -> *mut AukErr {
    unsafe {
        let ops_r = &*ops;
        let m: *mut AukStr = if !msg.is_null() {
            auk_retain(msg as *mut c_void).cast()
        } else if let Some(show) = ops_r.show {
            show(value)
        } else {
            auk_str_lit(c"error".as_ptr())
        };
        let e = auk_err_new(m);
        auk_release(m.cast());
        (*e).payload.type_id = type_id;
        (*e).payload.ops = ops;
        (*e).payload.data = auk__xmalloc(ops_r.size);
        std::ptr::copy_nonoverlapping(value as *const u8, (*e).payload.data as *mut u8, ops_r.size);
        if let Some(r) = ops_r.retain {
            r((*e).payload.data);
        }
        e
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_err_payload(e: *const AukErr, type_id: u32) -> *const c_void {
    unsafe {
        if e.is_null() || (*e).payload.data.is_null() || (*e).payload.type_id != type_id {
            return std::ptr::null();
        }
        (*e).payload.data
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_err_show(e: *const AukErr) -> *mut AukStr {
    unsafe {
        let mut b = AukStrBuf::INIT;
        let mut c = e;
        while !c.is_null() {
            if c != e {
                sb_bytes(&mut b, b": ");
            }
            auk_sb_str(&mut b, (*c).msg);
            c = (*c).cause;
        }
        auk_sb_finish(&mut b)
    }
}

pub unsafe fn auk__err_free(mut e: *mut AukErr) {
    // iterative over the cause chain to avoid deep recursion
    unsafe {
        while !e.is_null() {
            let next = (*e).cause;
            auk_release((*e).msg.cast());
            if !(*e).payload.data.is_null() {
                if let Some(r) = (*(*e).payload.ops).release {
                    r((*e).payload.data);
                }
                libc::free((*e).payload.data);
            }
            auk__free_obj(e.cast());
            if next.is_null() {
                break;
            }
            if (*next).h.rc.fetch_sub(1, Ordering::AcqRel) != 1 {
                break;
            }
            e = next;
        }
    }
}

/// Errors from errno: "<what> <subject>: <strerror>" (or "<what>: <strerror>") with code errno.
pub unsafe fn auk__err_errno(what: *const c_char, subject: *const AukStr, err: c_int) -> *mut AukErr {
    unsafe {
        let se = cbytes(libc::strerror(err));
        let mut m: Vec<u8> = cbytes(what).to_vec();
        if !subject.is_null() {
            m.push(b' ');
            // `%s` of the subject's C string: stops at an embedded NUL.
            let sb = cbytes(crate::str::auk_str_cstr(subject));
            m.extend_from_slice(sb);
        }
        m.extend_from_slice(b": ");
        m.extend_from_slice(se);
        let e = err_bytes(&m);
        (*e).code = err as i64;
        e
    }
}
