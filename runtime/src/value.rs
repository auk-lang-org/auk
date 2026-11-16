//! Value: the core data-tree enum (was value.c).

use std::ffi::{c_char, c_void};
use std::ptr::null_mut;

use crate::rc::{duck_hash_int, duck_ops_float, duck_ops_str, duck_release, duck_retain};
use crate::str::{duck_str_eq, duck_str_from_bool, duck_str_from_float, duck_str_from_int, duck_str_hash, duck_str_lit, duck_str_quote};
use crate::*;

#[unsafe(no_mangle)]
pub extern "C" fn duck_value_null() -> DuckValue {
    DuckValue { tag: DUCK_V_NULL, u: DuckValueU { i: 0 } }
}
#[unsafe(no_mangle)]
pub extern "C" fn duck_value_bool(b: bool) -> DuckValue {
    // Zero the whole union first, as C's compound literal does.
    let mut u = DuckValueU { i: 0 };
    u.b = b;
    DuckValue { tag: DUCK_V_BOOL, u }
}
#[unsafe(no_mangle)]
pub extern "C" fn duck_value_int(i: i64) -> DuckValue {
    DuckValue { tag: DUCK_V_INT, u: DuckValueU { i } }
}
#[unsafe(no_mangle)]
pub extern "C" fn duck_value_float(f: f64) -> DuckValue {
    DuckValue { tag: DUCK_V_FLOAT, u: DuckValueU { f } }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_str(s: *mut DuckStr) -> DuckValue {
    let s = if s.is_null() { unsafe { duck_str_lit(c"".as_ptr()) } } else { unsafe { duck_retain(s.cast()).cast() } };
    DuckValue { tag: DUCK_V_STR, u: DuckValueU { s } }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_list(xs: *mut DuckArr) -> DuckValue {
    let list = if xs.is_null() { unsafe { duck_value_list_new() } } else { unsafe { duck_retain(xs.cast()).cast() } };
    DuckValue { tag: DUCK_V_LIST, u: DuckValueU { list } }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_map(m: *mut DuckMap) -> DuckValue {
    let map = if m.is_null() { unsafe { duck_value_map_new() } } else { unsafe { duck_retain(m.cast()).cast() } };
    DuckValue { tag: DUCK_V_MAP, u: DuckValueU { map } }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_list_new() -> *mut DuckArr {
    unsafe { crate::arr::duck_arr_new(&duck_ops_value, 0) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_map_new() -> *mut DuckMap {
    unsafe { crate::map::duck_map_new(&duck_ops_str, &duck_ops_value) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_map_put(pm: *mut *mut DuckMap, key: *const c_char, val: DuckValue) {
    unsafe {
        let k = duck_str_lit(key);
        crate::map::duck_map_set(pm, (&k as *const *mut DuckStr).cast(), (&val as *const DuckValue).cast());
        duck_release(k.cast());
    }
}

fn value_ptr(v: DuckValue) -> *mut c_void {
    unsafe {
        match v.tag {
            DUCK_V_STR => v.u.s.cast(),
            DUCK_V_LIST => v.u.list.cast(),
            DUCK_V_MAP => v.u.map.cast(),
            _ => null_mut(),
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_retain(v: DuckValue) {
    unsafe { duck_retain(value_ptr(v)) };
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_release(v: DuckValue) {
    unsafe { duck_release(value_ptr(v)) }
}

fn tag_name(t: u32) -> &'static std::ffi::CStr {
    match t {
        DUCK_V_NULL => c"Null",
        DUCK_V_BOOL => c"Bool",
        DUCK_V_INT => c"Int",
        DUCK_V_FLOAT => c"Float",
        DUCK_V_STR => c"Str",
        DUCK_V_LIST => c"List",
        DUCK_V_MAP => c"Map",
        _ => c"?",
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn duck_value_tag_name(t: u32) -> *const c_char {
    tag_name(t).as_ptr()
}

fn mismatch(loc: *const c_char, want: &str, v: DuckValue) -> ! {
    rt_panic!(loc, "expected {}, got {}", want, tag_name(v.tag).to_str().unwrap_or("?"))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_as_bool(v: DuckValue, loc: *const c_char) -> bool {
    if v.tag != DUCK_V_BOOL {
        mismatch(loc, "Bool", v);
    }
    unsafe { v.u.b }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_as_int(v: DuckValue, loc: *const c_char) -> i64 {
    if v.tag != DUCK_V_INT {
        mismatch(loc, "Int", v);
    }
    unsafe { v.u.i }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_as_float(v: DuckValue, loc: *const c_char) -> f64 {
    if v.tag == DUCK_V_INT {
        return unsafe { v.u.i } as f64;
    }
    if v.tag != DUCK_V_FLOAT {
        mismatch(loc, "Float", v);
    }
    unsafe { v.u.f }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_as_str(v: DuckValue, loc: *const c_char) -> *mut DuckStr {
    if v.tag != DUCK_V_STR {
        mismatch(loc, "Str", v);
    }
    unsafe { v.u.s }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_as_list(v: DuckValue, loc: *const c_char) -> *mut DuckArr {
    if v.tag != DUCK_V_LIST {
        mismatch(loc, "List", v);
    }
    unsafe { v.u.list }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_as_map(v: DuckValue, loc: *const c_char) -> *mut DuckMap {
    if v.tag != DUCK_V_MAP {
        mismatch(loc, "Map", v);
    }
    unsafe { v.u.map }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_eq(a: DuckValue, b: DuckValue) -> bool {
    if a.tag != b.tag {
        return false;
    }
    unsafe {
        match a.tag {
            DUCK_V_NULL => true,
            DUCK_V_BOOL => a.u.b == b.u.b,
            DUCK_V_INT => a.u.i == b.u.i,
            DUCK_V_FLOAT => a.u.f == b.u.f,
            DUCK_V_STR => duck_str_eq(a.u.s, b.u.s),
            DUCK_V_LIST => crate::arr::duck_arr_eq(a.u.list, b.u.list),
            DUCK_V_MAP => crate::map::duck_map_eq(a.u.map, b.u.map),
            _ => false,
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_show(v: DuckValue) -> *mut DuckStr {
    unsafe {
        match v.tag {
            DUCK_V_NULL => duck_str_lit(c"Null".as_ptr()),
            DUCK_V_BOOL => duck_str_from_bool(v.u.b),
            DUCK_V_INT => duck_str_from_int(v.u.i),
            DUCK_V_FLOAT => duck_str_from_float(v.u.f),
            DUCK_V_STR => duck_str_quote(v.u.s),
            DUCK_V_LIST => crate::arr::duck_arr_show(v.u.list),
            DUCK_V_MAP => crate::map::duck_map_show(v.u.map),
            _ => duck_str_lit(c"?".as_ptr()),
        }
    }
}

unsafe extern "C" fn v_retain(p: *mut c_void) {
    unsafe { duck_value_retain(*(p as *const DuckValue)) }
}
unsafe extern "C" fn v_release(p: *mut c_void) {
    unsafe { duck_value_release(*(p as *const DuckValue)) }
}
unsafe extern "C" fn v_eq(a: *const c_void, b: *const c_void) -> bool {
    unsafe { duck_value_eq(*(a as *const DuckValue), *(b as *const DuckValue)) }
}
unsafe extern "C" fn v_hash(p: *const c_void) -> u64 {
    unsafe {
        let v = &*(p as *const DuckValue);
        match v.tag {
            DUCK_V_STR => duck_str_hash(v.u.s),
            DUCK_V_LIST => crate::arr::duck_arr_hash(v.u.list),
            DUCK_V_FLOAT => (duck_ops_float.hash.unwrap())((&v.u.f as *const f64).cast()),
            DUCK_V_INT => duck_hash_int(v.u.i),
            DUCK_V_BOOL => duck_hash_int(v.u.b as i64 + 2),
            _ => (v.tag as u64).wrapping_mul(7919),
        }
    }
}
unsafe extern "C" fn v_show(p: *const c_void) -> *mut DuckStr {
    unsafe { duck_value_show(*(p as *const DuckValue)) }
}

#[unsafe(no_mangle)]
pub static duck_ops_value: DuckElemOps = DuckElemOps {
    size: size_of::<DuckValue>(),
    retain: Some(v_retain),
    release: Some(v_release),
    eq: Some(v_eq),
    cmp: None,
    hash: Some(v_hash),
    show: Some(v_show),
};
