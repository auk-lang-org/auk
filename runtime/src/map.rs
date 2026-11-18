//! Maps: now in C (`runtime/c/map.c`). These declarations keep the Rust modules not yet ported
//! compiling.

use std::ffi::{c_char, c_void};

use crate::*;

unsafe extern "C" {
    pub unsafe fn auk_map_len(m: *const AukMap) -> i64;
    pub unsafe fn auk_map_new(kops: *const AukElemOps, vops: *const AukElemOps) -> *mut AukMap;
    pub unsafe fn auk__map_free(m: *mut AukMap);
    pub unsafe fn auk_map_find(m: *const AukMap, k: *const c_void) -> *mut c_void;
    pub unsafe fn auk_map_at(m: *const AukMap, k: *const c_void, loc: *const c_char) -> *mut c_void;
    pub unsafe fn auk_map_get_opt(m: *const AukMap, k: *const c_void, out: *mut c_void) -> bool;
    pub unsafe fn auk_map_contains(m: *const AukMap, k: *const c_void) -> bool;
    pub unsafe fn auk_map_copy(m: *const AukMap) -> *mut AukMap;
    pub unsafe fn auk_map_make_unique(pm: *mut *mut AukMap) -> *mut c_void;
    pub unsafe fn auk_map_set(pm: *mut *mut AukMap, k: *const c_void, v: *const c_void);
    pub unsafe fn auk_map_remove(pm: *mut *mut AukMap, k: *const c_void, out: *mut c_void) -> bool;
    pub unsafe fn auk_map_next(m: *const AukMap, it: *mut i64, k: *mut *mut c_void, v: *mut *mut c_void) -> bool;
    pub unsafe fn auk_map_keys(m: *const AukMap) -> *mut AukArr;
    pub unsafe fn auk_map_values(m: *const AukMap) -> *mut AukArr;
    pub unsafe fn auk_map_eq(a: *const AukMap, b: *const AukMap) -> bool;
    pub unsafe fn auk_map_show(m: *const AukMap) -> *mut AukStr;
}
