//! Value: the core data-tree enum (was value.c).

use std::ffi::{c_char, c_void};
use std::ptr::null_mut;

use crate::rc::{auk_hash_int, auk_ops_float, auk_ops_str, auk_release, auk_retain};
use crate::str::{auk_str_eq, auk_str_from_bool, auk_str_from_float, auk_str_from_int, auk_str_hash, auk_str_lit, auk_str_quote};
use crate::*;

#[unsafe(no_mangle)]
pub extern "C" fn auk_value_null() -> AukValue {
    AukValue { tag: AUK_V_NULL, u: AukValueU { i: 0 } }
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_value_bool(b: bool) -> AukValue {
    // Zero the whole union first, as C's compound literal does.
    let mut u = AukValueU { i: 0 };
    u.b = b;
    AukValue { tag: AUK_V_BOOL, u }
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_value_int(i: i64) -> AukValue {
    AukValue { tag: AUK_V_INT, u: AukValueU { i } }
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_value_float(f: f64) -> AukValue {
    AukValue { tag: AUK_V_FLOAT, u: AukValueU { f } }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_str(s: *mut AukStr) -> AukValue {
    let s = if s.is_null() { unsafe { auk_str_lit(c"".as_ptr()) } } else { unsafe { auk_retain(s.cast()).cast() } };
    AukValue { tag: AUK_V_STR, u: AukValueU { s } }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_list(xs: *mut AukArr) -> AukValue {
    let list = if xs.is_null() { unsafe { auk_value_list_new() } } else { unsafe { auk_retain(xs.cast()).cast() } };
    AukValue { tag: AUK_V_LIST, u: AukValueU { list } }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_map(m: *mut AukMap) -> AukValue {
    let map = if m.is_null() { unsafe { auk_value_map_new() } } else { unsafe { auk_retain(m.cast()).cast() } };
    AukValue { tag: AUK_V_MAP, u: AukValueU { map } }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_list_new() -> *mut AukArr {
    unsafe { crate::arr::auk_arr_new(&auk_ops_value, 0) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_map_new() -> *mut AukMap {
    unsafe { crate::map::auk_map_new(&auk_ops_str, &auk_ops_value) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_map_put(pm: *mut *mut AukMap, key: *const c_char, val: AukValue) {
    unsafe {
        let k = auk_str_lit(key);
        crate::map::auk_map_set(pm, (&k as *const *mut AukStr).cast(), (&val as *const AukValue).cast());
        auk_release(k.cast());
    }
}

fn value_ptr(v: AukValue) -> *mut c_void {
    unsafe {
        match v.tag {
            AUK_V_STR => v.u.s.cast(),
            AUK_V_LIST => v.u.list.cast(),
            AUK_V_MAP => v.u.map.cast(),
            _ => null_mut(),
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_retain(v: AukValue) {
    unsafe { auk_retain(value_ptr(v)) };
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_release(v: AukValue) {
    unsafe { auk_release(value_ptr(v)) }
}

fn tag_name(t: u32) -> &'static std::ffi::CStr {
    match t {
        AUK_V_NULL => c"Null",
        AUK_V_BOOL => c"Bool",
        AUK_V_INT => c"Int",
        AUK_V_FLOAT => c"Float",
        AUK_V_STR => c"Str",
        AUK_V_LIST => c"List",
        AUK_V_MAP => c"Map",
        _ => c"?",
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_value_tag_name(t: u32) -> *const c_char {
    tag_name(t).as_ptr()
}

fn mismatch(loc: *const c_char, want: &str, v: AukValue) -> ! {
    rt_panic!(loc, "expected {}, got {}", want, tag_name(v.tag).to_str().unwrap_or("?"))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_as_bool(v: AukValue, loc: *const c_char) -> bool {
    if v.tag != AUK_V_BOOL {
        mismatch(loc, "Bool", v);
    }
    unsafe { v.u.b }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_as_int(v: AukValue, loc: *const c_char) -> i64 {
    if v.tag != AUK_V_INT {
        mismatch(loc, "Int", v);
    }
    unsafe { v.u.i }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_as_float(v: AukValue, loc: *const c_char) -> f64 {
    if v.tag == AUK_V_INT {
        return unsafe { v.u.i } as f64;
    }
    if v.tag != AUK_V_FLOAT {
        mismatch(loc, "Float", v);
    }
    unsafe { v.u.f }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_as_str(v: AukValue, loc: *const c_char) -> *mut AukStr {
    if v.tag != AUK_V_STR {
        mismatch(loc, "Str", v);
    }
    unsafe { v.u.s }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_as_list(v: AukValue, loc: *const c_char) -> *mut AukArr {
    if v.tag != AUK_V_LIST {
        mismatch(loc, "List", v);
    }
    unsafe { v.u.list }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_as_map(v: AukValue, loc: *const c_char) -> *mut AukMap {
    if v.tag != AUK_V_MAP {
        mismatch(loc, "Map", v);
    }
    unsafe { v.u.map }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_eq(a: AukValue, b: AukValue) -> bool {
    if a.tag != b.tag {
        return false;
    }
    unsafe {
        match a.tag {
            AUK_V_NULL => true,
            AUK_V_BOOL => a.u.b == b.u.b,
            AUK_V_INT => a.u.i == b.u.i,
            AUK_V_FLOAT => a.u.f == b.u.f,
            AUK_V_STR => auk_str_eq(a.u.s, b.u.s),
            AUK_V_LIST => crate::arr::auk_arr_eq(a.u.list, b.u.list),
            AUK_V_MAP => crate::map::auk_map_eq(a.u.map, b.u.map),
            _ => false,
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_show(v: AukValue) -> *mut AukStr {
    unsafe {
        match v.tag {
            AUK_V_NULL => auk_str_lit(c"Null".as_ptr()),
            AUK_V_BOOL => auk_str_from_bool(v.u.b),
            AUK_V_INT => auk_str_from_int(v.u.i),
            AUK_V_FLOAT => auk_str_from_float(v.u.f),
            AUK_V_STR => auk_str_quote(v.u.s),
            AUK_V_LIST => crate::arr::auk_arr_show(v.u.list),
            AUK_V_MAP => crate::map::auk_map_show(v.u.map),
            _ => auk_str_lit(c"?".as_ptr()),
        }
    }
}

unsafe extern "C" fn v_retain(p: *mut c_void) {
    unsafe { auk_value_retain(*(p as *const AukValue)) }
}
unsafe extern "C" fn v_release(p: *mut c_void) {
    unsafe { auk_value_release(*(p as *const AukValue)) }
}
unsafe extern "C" fn v_eq(a: *const c_void, b: *const c_void) -> bool {
    unsafe { auk_value_eq(*(a as *const AukValue), *(b as *const AukValue)) }
}
unsafe extern "C" fn v_hash(p: *const c_void) -> u64 {
    unsafe {
        let v = &*(p as *const AukValue);
        match v.tag {
            AUK_V_STR => auk_str_hash(v.u.s),
            AUK_V_LIST => crate::arr::auk_arr_hash(v.u.list),
            AUK_V_FLOAT => (auk_ops_float.hash.unwrap())((&v.u.f as *const f64).cast()),
            AUK_V_INT => auk_hash_int(v.u.i),
            AUK_V_BOOL => auk_hash_int(v.u.b as i64 + 2),
            _ => (v.tag as u64).wrapping_mul(7919),
        }
    }
}
unsafe extern "C" fn v_show(p: *const c_void) -> *mut AukStr {
    unsafe { auk_value_show(*(p as *const AukValue)) }
}

#[unsafe(no_mangle)]
pub static auk_ops_value: AukElemOps = AukElemOps {
    size: size_of::<AukValue>(),
    retain: Some(v_retain),
    release: Some(v_release),
    eq: Some(v_eq),
    cmp: None,
    hash: Some(v_hash),
    show: Some(v_show),    copy: Some(crate::copy::value_copy_elem),
};
