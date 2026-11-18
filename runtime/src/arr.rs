//! Arrays: now in C (`runtime/c/arr.c`). These declarations keep the Rust modules not yet
//! ported compiling.

use std::ffi::{c_char, c_int, c_void};

use crate::*;

/// `int (*cmp)(const void *a, const void *b, void *ctx)`
pub type SortCmpFn = unsafe extern "C" fn(*const c_void, *const c_void, *mut c_void) -> c_int;

unsafe extern "C" {
    pub unsafe fn auk_arr_len(a: *const AukArr) -> i64;
    pub unsafe fn auk_arr_data(a: *const AukArr) -> *const c_void;
    pub unsafe fn auk_arr_new(ops: *const AukElemOps, cap: i64) -> *mut AukArr;
    pub unsafe fn auk_arr_from(ops: *const AukElemOps, elems: *const c_void, n: i64) -> *mut AukArr;
    pub unsafe fn auk__arr_free(a: *mut AukArr);
    pub unsafe fn auk_arr_at(a: *const AukArr, i: i64, loc: *const c_char) -> *mut c_void;
    pub unsafe fn auk_arr_get_opt(a: *const AukArr, i: i64, out: *mut c_void) -> bool;
    pub unsafe fn auk_arr_make_unique(pa: *mut *mut AukArr) -> *mut c_void;
    pub unsafe fn auk_arr_set(pa: *mut *mut AukArr, i: i64, e: *const c_void, loc: *const c_char);
    pub unsafe fn auk_arr_push(pa: *mut *mut AukArr, e: *const c_void);
    pub unsafe fn auk_arr_pop(pa: *mut *mut AukArr, out: *mut c_void) -> bool;
    pub unsafe fn auk_arr_insert(pa: *mut *mut AukArr, i: i64, e: *const c_void, loc: *const c_char);
    pub unsafe fn auk_arr_remove(pa: *mut *mut AukArr, i: i64, out: *mut c_void, loc: *const c_char);
    pub unsafe fn auk_arr_clear(pa: *mut *mut AukArr);
    pub unsafe fn auk_arr_slice(a: *mut AukArr, lo: i64, hi: i64, loc: *const c_char) -> *mut AukArr;
    pub unsafe fn auk_arr_take(a: *mut AukArr, n: i64) -> *mut AukArr;
    pub unsafe fn auk_arr_skip(a: *mut AukArr, n: i64) -> *mut AukArr;
    pub unsafe fn auk_arr_copy(a: *const AukArr) -> *mut AukArr;
    pub unsafe fn auk_arr_concat(a: *const AukArr, b: *const AukArr) -> *mut AukArr;
    pub unsafe fn auk_arr_extend(pa: *mut *mut AukArr, b: *const AukArr);
    pub unsafe fn auk_arr_reversed(a: *const AukArr) -> *mut AukArr;
    pub unsafe fn auk_arr_reverse(pa: *mut *mut AukArr);
    pub unsafe fn auk_arr_sort_with(pa: *mut *mut AukArr, cmp: SortCmpFn, ctx: *mut c_void);
    pub unsafe fn auk_arr_sort(pa: *mut *mut AukArr);
    pub unsafe fn auk_arr_sorted(a: *const AukArr) -> *mut AukArr;
    pub unsafe fn auk_arr_index_of(a: *const AukArr, e: *const c_void) -> AukOpt_int;
    pub unsafe fn auk_arr_contains(a: *const AukArr, e: *const c_void) -> bool;
    pub unsafe fn auk_arr_eq(a: *const AukArr, b: *const AukArr) -> bool;
    pub unsafe fn auk_arr_cmp(a: *const AukArr, b: *const AukArr) -> c_int;
    pub unsafe fn auk_arr_hash(a: *const AukArr) -> u64;
    pub unsafe fn auk_arr_show(a: *const AukArr) -> *mut AukStr;
    pub unsafe fn auk_arr_join(a: *const AukArr, sep: *const AukStr) -> *mut AukStr;
    pub unsafe fn auk_arr_sum_int(a: *const AukArr, loc: *const c_char) -> i64;
    pub unsafe fn auk_arr_sum_float(a: *const AukArr) -> f64;
}
