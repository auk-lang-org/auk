//! Async tasks: one pthread per spawned task; await joins (was task.c).

use std::ffi::{c_void, CStr};
use std::ptr::{self, null_mut};

use crate::rc::{duck__alloc, duck__free_obj, duck__xcalloc, duck__xmalloc};
use crate::*;

/// `typedef void (*DuckThunk)(void *args, void *result);`
pub type DuckThunk = unsafe extern "C" fn(*mut c_void, *mut c_void);

#[repr(C)]
pub struct DuckTask {
    pub h: DuckHeader,
    pub th: libc::pthread_t,
    pub mu: libc::pthread_mutex_t,
    pub fn_: DuckThunk,
    pub args: *mut c_void,
    pub result: *mut c_void,
    pub result_size: usize,
    pub ops: *const DuckElemOps,
    pub joined: bool,
}

extern "C" fn task_entry(p: *mut c_void) -> *mut c_void {
    let t = p as *mut DuckTask;
    unsafe {
        ((*t).fn_)((*t).args, (*t).result);
        libc::free((*t).args);
        (*t).args = null_mut();
    }
    null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_task_spawn(
    fn_: DuckThunk,
    args: *const c_void,
    args_size: usize,
    result_size: usize,
    result_ops: *const DuckElemOps,
) -> *mut DuckTask {
    unsafe {
        let t = duck__alloc(size_of::<DuckTask>(), DUCK_K_TASK) as *mut DuckTask;
        libc::pthread_mutex_init(&raw mut (*t).mu, ptr::null());
        // The object is calloc'd; write the fn pointer without reading the zeroed field.
        ptr::write(&raw mut (*t).fn_, fn_);
        (*t).args = duck__xmalloc(args_size);
        if args_size != 0 {
            ptr::copy_nonoverlapping(args as *const u8, (*t).args as *mut u8, args_size);
        }
        (*t).result = duck__xcalloc(1, if result_size != 0 { result_size } else { 1 });
        (*t).result_size = result_size;
        (*t).ops = result_ops;
        let mut attr: libc::pthread_attr_t = std::mem::zeroed();
        libc::pthread_attr_init(&mut attr);
        libc::pthread_attr_setstacksize(&mut attr, 8usize << 20);
        let rc = libc::pthread_create(&raw mut (*t).th, &attr, task_entry, t.cast());
        libc::pthread_attr_destroy(&mut attr);
        if rc != 0 {
            let why = CStr::from_ptr(libc::strerror(rc)).to_string_lossy();
            rt_panic!(c"runtime".as_ptr(), "could not start a task thread: {}", why);
        }
        t
    }
}

unsafe fn task_join(t: *mut DuckTask) {
    unsafe {
        libc::pthread_mutex_lock(&raw mut (*t).mu);
        if !(*t).joined {
            libc::pthread_join((*t).th, null_mut());
            (*t).joined = true;
        }
        libc::pthread_mutex_unlock(&raw mut (*t).mu);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_task_await(t: *mut DuckTask, out: *mut c_void) {
    unsafe {
        task_join(t);
        if !out.is_null() && (*t).result_size != 0 {
            ptr::copy_nonoverlapping((*t).result as *const u8, out as *mut u8, (*t).result_size);
            if !(*t).ops.is_null()
                && let Some(r) = (*(*t).ops).retain
            {
                r(out);
            }
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_task_join_all(ts: *mut *mut DuckTask, n: i64) {
    unsafe {
        for i in 0..n {
            task_join(*ts.add(i as usize));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_task_await_all(ts: *mut *mut DuckTask, n: i64, outs: *mut c_void) {
    unsafe {
        duck_task_join_all(ts, n);
        for i in 0..n {
            let t = *ts.add(i as usize);
            let out = if outs.is_null() {
                null_mut()
            } else {
                (outs as *mut u8).add(i as usize * (*t).result_size).cast()
            };
            duck_task_await(t, out);
        }
    }
}

pub unsafe fn duck__task_free(t: *mut DuckTask) {
    unsafe {
        task_join(t);
        if !(*t).ops.is_null()
            && let Some(r) = (*(*t).ops).release
        {
            r((*t).result);
        }
        libc::free((*t).result);
        libc::pthread_mutex_destroy(&raw mut (*t).mu);
        duck__free_obj(t.cast());
    }
}
