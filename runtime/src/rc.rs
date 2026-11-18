//! Refcounting, allocation, panics, arithmetic, hashing and scalar element ops: now in C
//! (`runtime/c/rc.c`). These declarations keep the Rust modules not yet ported compiling.

use std::ffi::{c_char, c_int, c_void};

use crate::*;

unsafe extern "C" {
    pub safe fn auk_live_objects() -> i64;
    pub unsafe fn auk__xmalloc(n: usize) -> *mut c_void;
    pub unsafe fn auk__xcalloc(n: usize, sz: usize) -> *mut c_void;
    pub unsafe fn auk__xrealloc(p: *mut c_void, n: usize) -> *mut c_void;
    pub unsafe fn auk__alloc(size: usize, kind: u32) -> *mut c_void;
    pub unsafe fn auk__free_obj(p: *mut c_void);
    pub unsafe fn auk__make_immortal(p: *mut c_void);
    pub unsafe fn auk_make_immortal(p: *mut c_void);
    pub safe fn auk_set_cleanup(f: Option<unsafe extern "C" fn()>);
    pub safe fn auk_leak_check() -> i64;
    pub unsafe fn auk_retain(p: *mut c_void) -> *mut c_void;
    pub unsafe fn auk_release(p: *mut c_void);
    #[link_name = "auk__free_now"]
    pub unsafe fn free_now(p: *mut c_void);
    pub unsafe fn auk_refcount(p: *const c_void) -> i64;
    fn auk__panic(loc: *const c_char, msg: *const u8, n: usize) -> !;
    pub unsafe fn auk_panic_str(loc: *const c_char, msg: *const c_char) -> !;
    pub unsafe fn auk_panic_overflow(loc: *const c_char, op: *const c_char) -> !;
    pub safe fn auk_panic_div_zero(loc: *const c_char) -> !;
    pub safe fn auk_unwrap_none(loc: *const c_char) -> !;
    pub unsafe fn auk_unwrap_err(loc: *const c_char, e: *mut AukErr) -> !;
    pub safe fn auk_add(a: i64, b: i64, loc: *const c_char) -> i64;
    pub safe fn auk_sub(a: i64, b: i64, loc: *const c_char) -> i64;
    pub safe fn auk_mul(a: i64, b: i64, loc: *const c_char) -> i64;
    pub safe fn auk_div(a: i64, b: i64, loc: *const c_char) -> i64;
    pub safe fn auk_mod(a: i64, b: i64, loc: *const c_char) -> i64;
    pub safe fn auk_neg(a: i64, loc: *const c_char) -> i64;
    pub safe fn auk_wadd(a: i64, b: i64) -> i64;
    pub safe fn auk_wsub(a: i64, b: i64) -> i64;
    pub safe fn auk_wmul(a: i64, b: i64) -> i64;
    pub safe fn auk_shl(a: i64, n: i64, loc: *const c_char) -> i64;
    pub safe fn auk_shr(a: i64, n: i64, loc: *const c_char) -> i64;
    pub safe fn auk_int_cmp(a: i64, b: i64) -> c_int;
    pub safe fn auk_pow(a: i64, b: i64, loc: *const c_char) -> i64;
    pub unsafe fn auk_int_abs(a: i64, loc: *const c_char) -> i64;
    pub safe fn auk_fpow(a: f64, b: f64) -> f64;
    pub safe fn auk_fmod(a: f64, b: f64) -> f64;
    pub safe fn auk_fsqrt(a: f64) -> f64;
    pub safe fn auk_fabs(a: f64) -> f64;
    pub safe fn auk_ffloor(a: f64) -> f64;
    pub safe fn auk_fceil(a: f64) -> f64;
    pub safe fn auk_fround(a: f64) -> f64;
    pub safe fn auk_fsin(a: f64) -> f64;
    pub safe fn auk_fcos(a: f64) -> f64;
    pub safe fn auk_ftan(a: f64) -> f64;
    pub safe fn auk_fasin(a: f64) -> f64;
    pub safe fn auk_facos(a: f64) -> f64;
    pub safe fn auk_fatan(a: f64) -> f64;
    pub safe fn auk_fexp(a: f64) -> f64;
    pub safe fn auk_fln(a: f64) -> f64;
    pub safe fn auk_flog10(a: f64) -> f64;
    pub safe fn auk_flog2(a: f64) -> f64;
    pub safe fn auk_fatan2(y: f64, x: f64) -> f64;
    pub safe fn auk_fbits(a: f64) -> i64;
    pub safe fn auk_ffrom_bits(n: i64) -> f64;
    pub safe fn auk_fbits32(a: f64) -> i64;
    pub safe fn auk_ffrom_bits32(n: i64) -> f64;
    pub safe fn auk_float_to_int(x: f64, loc: *const c_char) -> i64;
    pub unsafe fn auk_closure_retain(c: AukClosure);
    pub unsafe fn auk_closure_release(c: AukClosure);
    pub safe fn auk_float_cmp(a: f64, b: f64) -> c_int;
    pub unsafe fn auk_hash_bytes(p: *const c_void, n: usize) -> u64;
    pub safe fn auk_hash_int(x: i64) -> u64;
    pub safe fn auk_hash_combine(h: u64, x: u64) -> u64;
    #[link_name = "auk__ptr_retain"]
    pub unsafe fn ptr_retain(p: *mut c_void);
    #[link_name = "auk__ptr_release"]
    pub unsafe fn ptr_release(p: *mut c_void);
    pub safe static auk_ops_int: AukElemOps;
    pub safe static auk_ops_float: AukElemOps;
    pub safe static auk_ops_bool: AukElemOps;
    pub safe static auk_ops_char: AukElemOps;
    pub safe static auk_ops_unit: AukElemOps;
    pub safe static auk_ops_str: AukElemOps;
    pub safe static auk_ops_arr: AukElemOps;
    pub safe static auk_ops_map: AukElemOps;
    pub safe static auk_ops_err: AukElemOps;
    pub safe static auk_ops_obj: AukElemOps;
    pub safe static auk_ops_task: AukElemOps;
    pub safe static auk_ops_closure: AukElemOps;
}

/// Typed conveniences for Rust callers.
pub unsafe fn retain<T>(p: *mut T) -> *mut T {
    unsafe { auk_retain(p.cast()).cast() }
}
pub unsafe fn release<T>(p: *mut T) {
    unsafe { auk_release(p.cast()) }
}

/// Panic with a Rust message (rc.c `auk__panic`).
pub fn panic_msg(loc: *const c_char, msg: &str) -> ! {
    unsafe { auk__panic(loc, msg.as_ptr(), msg.len()) }
}

/// C's `%g` (6 significant digits, shortest of %e/%f, trailing zeros stripped).
pub fn fmt_g(x: f64) -> String {
    let mut buf = [0u8; 64];
    let n = unsafe { libc::snprintf(buf.as_mut_ptr().cast(), buf.len(), c"%g".as_ptr(), x) };
    String::from_utf8_lossy(&buf[..(n.max(0) as usize).min(63)]).into_owned()
}

// `AukElemOps` holds only fn pointers and a size; sharing it across threads is fine.
unsafe impl Sync for AukElemOps {}
