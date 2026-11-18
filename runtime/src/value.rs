//! Value: now in C (`runtime/c/value.c`). These declarations keep the Rust modules not yet
//! ported compiling.

use std::ffi::c_char;

use crate::*;

unsafe extern "C" {
    pub safe fn auk_value_null() -> AukValue;
    pub safe fn auk_value_bool(b: bool) -> AukValue;
    pub safe fn auk_value_int(i: i64) -> AukValue;
    pub safe fn auk_value_float(f: f64) -> AukValue;
    pub unsafe fn auk_value_str(s: *mut AukStr) -> AukValue;
    pub unsafe fn auk_value_list(xs: *mut AukArr) -> AukValue;
    pub unsafe fn auk_value_map(m: *mut AukMap) -> AukValue;
    pub unsafe fn auk_value_list_new() -> *mut AukArr;
    pub unsafe fn auk_value_map_new() -> *mut AukMap;
    pub unsafe fn auk_value_map_put(pm: *mut *mut AukMap, key: *const c_char, val: AukValue);
    pub unsafe fn auk_value_retain(v: AukValue);
    pub unsafe fn auk_value_release(v: AukValue);
    pub safe fn auk_value_tag_name(t: u32) -> *const c_char;
    pub unsafe fn auk_value_as_bool(v: AukValue, loc: *const c_char) -> bool;
    pub unsafe fn auk_value_as_int(v: AukValue, loc: *const c_char) -> i64;
    pub unsafe fn auk_value_as_float(v: AukValue, loc: *const c_char) -> f64;
    pub unsafe fn auk_value_as_str(v: AukValue, loc: *const c_char) -> *mut AukStr;
    pub unsafe fn auk_value_as_list(v: AukValue, loc: *const c_char) -> *mut AukArr;
    pub unsafe fn auk_value_as_map(v: AukValue, loc: *const c_char) -> *mut AukMap;
    pub unsafe fn auk_value_eq(a: AukValue, b: AukValue) -> bool;
    pub unsafe fn auk_value_show(v: AukValue) -> *mut AukStr;
    pub safe static auk_ops_value: AukElemOps;
}
