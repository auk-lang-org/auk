//! Deep copies, for values crossing a task boundary (heap.rs): spawn arguments, `await` results
//! and channel messages. A copy is allocated in the current heap and shares nothing with the
//! original, except immortal objects (literals, imprints: never freed) and handles (tasks,
//! connections, listeners, channels: shared by reference count, never tracked).

use std::ffi::c_void;
use std::ptr::null_mut;
use std::sync::atomic::Ordering;

use crate::rc::{duck__alloc, duck_retain};
use crate::*;

fn immortal(p: *const c_void) -> bool {
    unsafe { (*(p as *const DuckHeader)).rc.load(Ordering::Relaxed) < 0 }
}

/// A closure env or box: `size` bytes with its drop and copy functions.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_obj_alloc(size: usize, drop: Option<DropFn>, copy: Option<ObjCopyFn>) -> *mut c_void {
    let size = size.max(size_of::<DuckObj>());
    let o = unsafe { duck__alloc(size, DUCK_K_OBJ) } as *mut DuckObj;
    unsafe {
        (*o).drop = drop;
        (*o).copy = copy;
    }
    o.cast()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_obj_copy(o: *mut DuckObj) -> *mut DuckObj {
    if o.is_null() || immortal(o.cast()) {
        return o;
    }
    unsafe {
        match (*o).copy {
            Some(c) => c(o),
            None => duck_retain(o.cast()).cast(),
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_str_copy(s: *mut DuckStr) -> *mut DuckStr {
    if s.is_null() || immortal(s.cast()) {
        return s;
    }
    unsafe { crate::str::duck_str_from_bytes((*s).data.as_ptr().cast(), (*s).len_bytes) }
}

/// Copy one element of `ops` from `src` to `dst` (a byte copy plus a retain without a `copy`).
pub unsafe fn copy_elem(ops: *const DuckElemOps, src: *const u8, dst: *mut u8) {
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
pub unsafe extern "C" fn duck_arr_copy_deep(a: *mut DuckArr) -> *mut DuckArr {
    if a.is_null() || immortal(a.cast()) {
        return a;
    }
    unsafe {
        let ops = (*a).ops;
        let n = (*a).len;
        let b = crate::arr::duck_arr_new(ops, n);
        let size = (*ops).size;
        for i in 0..n {
            let src = crate::arr::duck_arr_at(a, i, std::ptr::null()) as *const u8;
            copy_elem(ops, src, (*b).data.add(i as usize * size));
        }
        (*b).len = n;
        b
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_copy_deep(m: *mut DuckMap) -> *mut DuckMap {
    if m.is_null() || immortal(m.cast()) {
        return m;
    }
    unsafe {
        let (kops, vops) = ((*m).kops, (*m).vops);
        let mut out = crate::map::duck_map_new(kops, vops);
        let mut kb = vec![0u8; (*kops).size.max(1)];
        let mut vb = vec![0u8; (*vops).size.max(1)];
        for i in 0..(*m).n {
            if *(*m).dead.add(i as usize) {
                continue;
            }
            copy_elem(kops, crate::map::key(m, i), kb.as_mut_ptr());
            copy_elem(vops, crate::map::val(m, i), vb.as_mut_ptr());
            // the map retains its own copies of borrowed elements
            crate::map::duck_map_set(&mut out, kb.as_ptr().cast(), vb.as_ptr().cast());
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
pub unsafe extern "C" fn duck_err_copy_deep(e: *mut DuckErr) -> *mut DuckErr {
    if e.is_null() || immortal(e.cast()) {
        return e;
    }
    unsafe {
        let msg = duck_str_copy((*e).msg);
        let c = crate::err::duck_err_new(msg);
        crate::rc::duck_release(msg.cast());
        (*c).code = (*e).code;
        (*c).cause = duck_err_copy_deep((*e).cause);
        let p = &(*e).payload;
        if !p.data.is_null() {
            (*c).payload.type_id = p.type_id;
            (*c).payload.ops = p.ops;
            (*c).payload.data = crate::rc::duck__xmalloc((*p.ops).size);
            copy_elem(p.ops, p.data as *const u8, (*c).payload.data.cast());
        }
        c
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_value_copy(v: DuckValue) -> DuckValue {
    unsafe {
        let mut out = DuckValue { tag: v.tag, u: v.u };
        match v.tag {
            DUCK_V_STR => out.u.s = duck_str_copy(v.u.s),
            DUCK_V_LIST => out.u.list = duck_arr_copy_deep(v.u.list),
            DUCK_V_MAP => out.u.map = duck_map_copy_deep(v.u.map),
            _ => {}
        }
        out
    }
}

// ---- `copy` entries of the built-in element ops ----

pub unsafe extern "C" fn str_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut *mut DuckStr) = duck_str_copy(*(src as *const *mut DuckStr)) }
}
pub unsafe extern "C" fn arr_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut *mut DuckArr) = duck_arr_copy_deep(*(src as *const *mut DuckArr)) }
}
pub unsafe extern "C" fn map_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut *mut DuckMap) = duck_map_copy_deep(*(src as *const *mut DuckMap)) }
}
pub unsafe extern "C" fn err_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut *mut DuckErr) = duck_err_copy_deep(*(src as *const *mut DuckErr)) }
}
pub unsafe extern "C" fn obj_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut *mut DuckObj) = duck_obj_copy(*(src as *const *mut DuckObj)) }
}
/// A handle (a task): shared, not copied.
pub unsafe extern "C" fn handle_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut *mut c_void) = duck_retain(*(src as *const *mut c_void)) }
}
/// A closure `{code, env}`: the same code with a copy of the env.
pub unsafe extern "C" fn closure_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe {
        let s = src as *const [*mut c_void; 2];
        let d = dst as *mut [*mut c_void; 2];
        (*d)[0] = (*s)[0];
        (*d)[1] = if (*s)[1].is_null() { null_mut() } else { duck_obj_copy((*s)[1].cast()).cast() };
    }
}
pub unsafe extern "C" fn value_copy_elem(src: *const c_void, dst: *mut c_void) {
    unsafe { *(dst as *mut DuckValue) = duck_value_copy(std::ptr::read(src as *const DuckValue)) }
}
