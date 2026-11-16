//! Err: message, code, cause chain and an optional typed payload (was err.c).

use std::ffi::{c_char, c_int, c_void};
use std::sync::atomic::Ordering;

use crate::rc::{duck__alloc, duck__free_obj, duck__xmalloc, duck_release, duck_retain};
use crate::str::{duck_sb_finish, duck_sb_str, duck_str_lit, sb_bytes};
use crate::*;

/// New error; msg is borrowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_err_new(msg: *const DuckStr) -> *mut DuckErr {
    unsafe {
        let e = duck__alloc(size_of::<DuckErr>(), DUCK_K_ERR) as *mut DuckErr;
        (*e).msg = if msg.is_null() { duck_str_lit(c"".as_ptr()) } else { duck_retain(msg as *mut c_void).cast() };
        e
    }
}

/// What C's `duck_err_fmt` did with its formatted text: push it through a string builder
/// (so it counts against a trace's show budget and invalid UTF-8 is repaired), then wrap it.
fn err_bytes(msg: &[u8]) -> *mut DuckErr {
    unsafe {
        let mut b = DuckStrBuf::INIT;
        sb_bytes(&mut b, msg);
        let s = duck_sb_finish(&mut b);
        let e = duck_err_new(s);
        duck_release(s.cast());
        e
    }
}

/// New error from Rust text (the replacement for C's variadic `duck_err_fmt`).
pub fn err_msg(msg: &str) -> *mut DuckErr {
    err_bytes(msg.as_bytes())
}

/// A new error with a NUL-terminated message.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_err_new_cstr(msg: *const c_char) -> *mut DuckErr {
    err_bytes(unsafe { cbytes(msg) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_err_wrap(msg: *const DuckStr, cause: *mut DuckErr) -> *mut DuckErr {
    unsafe {
        let e = duck_err_new(msg);
        (*e).cause = duck_retain(cause.cast()).cast();
        e
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_err_typed(
    type_id: u32,
    value: *const c_void,
    ops: *const DuckElemOps,
    msg: *const DuckStr,
) -> *mut DuckErr {
    unsafe {
        let ops_r = &*ops;
        let m: *mut DuckStr = if !msg.is_null() {
            duck_retain(msg as *mut c_void).cast()
        } else if let Some(show) = ops_r.show {
            show(value)
        } else {
            duck_str_lit(c"error".as_ptr())
        };
        let e = duck_err_new(m);
        duck_release(m.cast());
        (*e).payload.type_id = type_id;
        (*e).payload.ops = ops;
        (*e).payload.data = duck__xmalloc(ops_r.size);
        std::ptr::copy_nonoverlapping(value as *const u8, (*e).payload.data as *mut u8, ops_r.size);
        if let Some(r) = ops_r.retain {
            r((*e).payload.data);
        }
        e
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_err_payload(e: *const DuckErr, type_id: u32) -> *const c_void {
    unsafe {
        if e.is_null() || (*e).payload.data.is_null() || (*e).payload.type_id != type_id {
            return std::ptr::null();
        }
        (*e).payload.data
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_err_show(e: *const DuckErr) -> *mut DuckStr {
    unsafe {
        let mut b = DuckStrBuf::INIT;
        let mut c = e;
        while !c.is_null() {
            if c != e {
                sb_bytes(&mut b, b": ");
            }
            duck_sb_str(&mut b, (*c).msg);
            c = (*c).cause;
        }
        duck_sb_finish(&mut b)
    }
}

pub unsafe fn duck__err_free(mut e: *mut DuckErr) {
    // iterative over the cause chain to avoid deep recursion
    unsafe {
        while !e.is_null() {
            let next = (*e).cause;
            duck_release((*e).msg.cast());
            if !(*e).payload.data.is_null() {
                if let Some(r) = (*(*e).payload.ops).release {
                    r((*e).payload.data);
                }
                libc::free((*e).payload.data);
            }
            duck__free_obj(e.cast());
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
pub unsafe fn duck__err_errno(what: *const c_char, subject: *const DuckStr, err: c_int) -> *mut DuckErr {
    unsafe {
        let se = cbytes(libc::strerror(err));
        let mut m: Vec<u8> = cbytes(what).to_vec();
        if !subject.is_null() {
            m.push(b' ');
            // `%s` of the subject's C string: stops at an embedded NUL.
            let sb = cbytes(crate::str::duck_str_cstr(subject));
            m.extend_from_slice(sb);
        }
        m.extend_from_slice(b": ");
        m.extend_from_slice(se);
        let e = err_bytes(&m);
        (*e).code = err as i64;
        e
    }
}
