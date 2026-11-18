//! Deep copies across task boundaries: now in C (`runtime/c/copy.c`). These declarations keep
//! the Rust modules not yet ported compiling.

use std::ffi::c_void;

use crate::*;

unsafe extern "C" {
    pub unsafe fn auk_obj_alloc(size: usize, drop: Option<DropFn>, copy: Option<ObjCopyFn>) -> *mut c_void;
    pub unsafe fn auk_obj_copy(o: *mut AukObj) -> *mut AukObj;
    pub unsafe fn auk_str_copy(s: *mut AukStr) -> *mut AukStr;
    pub unsafe fn auk_arr_copy_deep(a: *mut AukArr) -> *mut AukArr;
    pub unsafe fn auk_map_copy_deep(m: *mut AukMap) -> *mut AukMap;
    pub unsafe fn auk_err_copy_deep(e: *mut AukErr) -> *mut AukErr;
    pub unsafe fn auk_value_copy(v: AukValue) -> AukValue;
    #[link_name = "auk__copy_elem"]
    pub unsafe fn copy_elem(ops: *const AukElemOps, src: *const u8, dst: *mut u8);
}
