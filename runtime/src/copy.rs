//! Deep copies, for values crossing a task boundary (heap.rs): spawn arguments, `await` results
//! and channel messages. A copy is allocated in the current heap and shares nothing with the
//! original, except immortal objects (literals, imprints: never freed) and handles (tasks,
//! connections, listeners, channels: shared by reference count, never tracked).

use std::ffi::c_void;
use std::ptr::null_mut;
use std::sync::atomic::Ordering;

use crate::rc::{auk__alloc, auk_retain};
use crate::*;

fn immortal(p: *const c_void) -> bool {
    unsafe { (*(p as *const AukHeader)).rc.load(Ordering::Relaxed) < 0 }
}

/// A closure env or box: `size` bytes with its drop and copy functions.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_obj_alloc(size: usize, drop: Option<DropFn>, copy: Option<ObjCopyFn>) -> *mut c_void {
    let size = size.max(size_of::<AukObj>());
    let o = unsafe { auk__alloc(size, AUK_K_OBJ) } as *mut AukObj;
    unsafe {
        (*o).drop = drop;
        (*o).copy = copy;
    }
    o.cast()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_obj_copy(o: *mut AukObj) -> *mut AukObj {
    if o.is_null() || immortal(o.cast()) {
        return o;
    }
    unsafe {
        match (*o).copy {
            Some(c) => c(o),
            None => auk_retain(o.cast()).cast(),
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_copy(s: *mut AukStr) -> *mut AukStr {
    if s.is_null() || immortal(s.cast()) {
        return s;
    }
    unsafe { crate::str::auk_str_from_bytes((*s).data.as_ptr().cast(), (*s).len_bytes) }
}

/// Copy one element of `ops` from `src` to `dst` (a byte copy plus a retain without a `copy`).
pub unsafe fn copy_elem(ops: *const AukElemOps, src: *const u8, dst: *mut u8) {
    unsafe {
        match (*ops).copy {
            Some(c) => c(src.cast(), dst.cast()),
            None => {
                std::ptr::copy_nonoverlapping(src, dst, (*ops).size);
                if let Some(r) = (*ops).retain {
                    r(dst.cast());
                }
            }
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_arr_copy_deep(a: *mut AukArr) -> *mut AukArr {
    if a.is_null() || immortal(a.cast()) {
        return a;
    }
    unsafe {
        let ops = (*a).ops;
        let n = (*a).len;
        let b = crate::arr::auk_arr_new(ops, n);
        let size = (*ops).size;
        for i in 0..n {
            let src = crate::arr::auk_arr_at(a, i, std::ptr::null()) as *const u8;
            copy_elem(ops, src, (*b).data.add(i as usize * size));
        }
        (*b).len = n;
        b
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_map_copy_deep(m: *mut AukMap) -> *mut AukMap {
    if m.is_null() || immortal(m.cast()) {
        return m;
    }
    unsafe {
        let (kops, vops) = ((*m).kops, (*m).vops);
        let mut out = crate::map::auk_map_new(kops, vops);
        let mut kb = vec![0u8; (*kops).size.max(1)];
        let mut vb = vec![0u8; (*vops).size.max(1)];
        for i in 0..(*m).n {
            if *(*m).dead.add(i as usize) {
                continue;
            }
            copy_elem(kops, crate::map::key(m, i), kb.as_mut_ptr());
            copy_elem(vops, crate::map::val(m, i), vb.as_mut_ptr());
            // the map retains its own copies of borrowed elements
            crate::map::auk_map_set(&mut out, kb.as_ptr().cast(), vb.as_ptr().cast());
            if let Some(r) = (*kops).release {
                r(kb.as_mut_ptr().cast());
            }
            if let Some(r) = (*vops).release {
                r(vb.as_mut_ptr().cast());
            }
        }
        out
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_err_copy_deep(e: *mut AukErr) -> *mut AukErr {
    if e.is_null() || immortal(e.cast()) {
        return e;
    }
    unsafe {
        let msg = auk_str_copy((*e).msg);
        let c = crate::err::auk_err_new(msg);
        crate::rc::auk_release(msg.cast());
        (*c).code = (*e).code;
        (*c).cause = auk_err_copy_deep((*e).cause);
        let p = &(*e).payload;
        if !p.data.is_null() {
            (*c).payload.type_id = p.type_id;
            (*c).payload.ops = p.ops;
            (*c).payload.data = crate::rc::auk__xmalloc((*p.ops).size);
            copy_elem(p.ops, p.data as *const u8, (*c).payload.data.cast());
        }
        c
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_copy(v: AukValue) -> AukValue {
    unsafe {
        let mut out = AukValue { tag: v.tag, u: v.u };
        match v.tag {
            AUK_V_STR => out.u.s = auk_str_copy(v.u.s),
            AUK_V_LIST => out.u.list = auk_arr_copy_deep(v.u.list),
            AUK_V_MAP => out.u.map = auk_map_copy_deep(v.u.map),
            _ => {}
        }
        out
    }
}

// ---- `copy` entries of the built-in element ops ----

pub unsafe extern "C" fn str_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut *mut AukStr) = auk_str_copy(*(src as *const *mut AukStr)) }
}
pub unsafe extern "C" fn arr_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut *mut AukArr) = auk_arr_copy_deep(*(src as *const *mut AukArr)) }
}
pub unsafe extern "C" fn map_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut *mut AukMap) = auk_map_copy_deep(*(src as *const *mut AukMap)) }
}
pub unsafe extern "C" fn err_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut *mut AukErr) = auk_err_copy_deep(*(src as *const *mut AukErr)) }
}
pub unsafe extern "C" fn obj_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut *mut AukObj) = auk_obj_copy(*(src as *const *mut AukObj)) }
}
/// A handle (a task): shared, not copied.
pub unsafe extern "C" fn handle_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut *mut c_void) = auk_retain(*(src as *const *mut c_void)) }
}
/// A closure `{code, env}`: the same code with a copy of the env.
pub unsafe extern "C" fn closure_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe {
        let s = src as *const [*mut c_void; 2];
        let d = dst as *mut [*mut c_void; 2];
        (*d)[0] = (*s)[0];
        (*d)[1] = if (*s)[1].is_null() { null_mut() } else { auk_obj_copy((*s)[1].cast()).cast() };
    }
}
pub unsafe extern "C" fn value_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut AukValue) = auk_value_copy(std::ptr::read(src as *const AukValue)) }
}
