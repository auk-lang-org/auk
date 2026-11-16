//! Async tasks: one pthread per spawned task; await joins (was task.c).
//!
//! A task is linked to whoever awaits it: a panic on the task's thread ends only the task
//! (catch.rs), and `await` raises it again in the awaiter, where a `catch` can recover it. A
//! task that panicked and is dropped without being awaited ends the process, so no panic goes
//! unreported.
//!
//! Cancelling a task is cooperative: `t.cancel()` sets a flag that the task checks at loop
//! back-edges (generated code reads `duck_cancel_pending` first, so loops pay one load while no
//! task is cancelled) and in blocking calls (sleep, await, net I/O wait in short slices). The
//! check panics "cancelled", and once a task is cancelled no `catch` inside it can keep it alive.
//!
//! Tasks are linked to the tasks they start, as Erlang processes are: when a task ends with a
//! panic (a crash, or its own cancellation), every task it started that is still running is
//! cancelled, so a failed supervisor takes its whole subtree down. A normal end cancels nothing.

use std::cell::Cell;
use std::ffi::{c_char, c_void, CStr};
use std::ptr::{self, null_mut};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::Duration;

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
    /// Set (a `Box<Panic>`) when the task's code panicked.
    pub panic: *mut crate::catch::Panic,
    /// An awaiter has seen the panic.
    pub observed: bool,
    /// `cancel()` was called before the task finished.
    pub cancel: AtomicBool,
    /// The task's code has finished (its result or panic is set).
    pub done: AtomicBool,
    /// The tasks this task started (retained; a `Box<Vec<_>>`, null until the first), for the
    /// link: cancelled when this task ends with a panic.
    pub kids: *mut Vec<*mut DuckTask>,
    /// The task's own heap (heap.rs): its arguments were copied into it, everything it
    /// allocates goes there, and it is swept when the task crashes or is freed.
    pub heap: *mut crate::heap::Heap,
    /// Releases the arguments (what the thunk does after the call), for a task that crashed.
    pub args_drop: Option<unsafe extern "C" fn(*mut c_void)>,
}

/// How many tasks are cancelled but still running: generated loops check a task's flag only
/// while this is non-zero.
#[unsafe(no_mangle)]
pub static duck_cancel_pending: AtomicI64 = AtomicI64::new(0);

/// Guards the cancel/done transitions; `DONE` is signalled whenever a task finishes.
static STATE: Mutex<()> = Mutex::new(());
static DONE: Condvar = Condvar::new();
/// How long a blocking wait sleeps between cancel checks.
const SLICE: Duration = Duration::from_millis(50);

thread_local! {
    /// The task this thread runs (null on the main thread).
    static CURRENT: Cell<*mut DuckTask> = const { Cell::new(null_mut()) };
}

/// Has the task running on this thread been cancelled?
pub fn cancelled() -> bool {
    let t = CURRENT.with(|c| c.get());
    !t.is_null() && unsafe { (*t).cancel.load(Ordering::SeqCst) }
}

/// Is this thread a task's (so blocking calls must wake up to check for cancellation)?
pub fn on_task() -> bool {
    !CURRENT.with(|c| c.get()).is_null()
}

/// Panic "cancelled" if this thread's task was cancelled.
pub fn check_cancel(loc: *const c_char) {
    if cancelled() {
        crate::rc::panic_msg(loc, "cancelled");
    }
}

/// The loop back-edge check (called only while `duck_cancel_pending` is non-zero).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_cancel_check(loc: *const c_char) {
    check_cancel(loc);
}

/// Wait until `fd` is readable (or writable), waking every SLICE to check for cancellation.
/// Off a task thread it returns at once (the blocking call itself then waits).
pub fn wait_fd(fd: i32, write: bool) {
    if !on_task() {
        return;
    }
    loop {
        check_cancel(c"a blocking call".as_ptr());
        let mut p = libc::pollfd { fd, events: if write { libc::POLLOUT } else { libc::POLLIN }, revents: 0 };
        if unsafe { libc::poll(&mut p, 1, SLICE.as_millis() as i32) } != 0 {
            return;
        }
    }
}

/// Sleep `ms`, in slices on a task thread so a cancel ends it early.
pub fn sleep_ms(ms: i64) {
    let mut left = ms;
    while left > 0 {
        let step = if on_task() { left.min(SLICE.as_millis() as i64) } else { left };
        let mut ts = libc::timespec { tv_sec: (step / 1000) as libc::time_t, tv_nsec: ((step % 1000) * 1_000_000) as _ };
        while unsafe { libc::nanosleep(&ts, &mut ts) } < 0 && crate::core::errno() == libc::EINTR {}
        left -= step;
        check_cancel(c"a blocking call".as_ptr());
    }
}

extern "C" fn task_entry(p: *mut c_void) -> *mut c_void {
    let t = p as *mut DuckTask;
    unsafe {
        CURRENT.with(|c| c.set(t));
        crate::heap::switch((*t).heap);
        if let Some(p) = crate::catch::run((*t).fn_, (*t).args, (*t).result) {
            (*t).panic = Box::into_raw(Box::new(p));
            // the arguments' references (handles among them), then everything else the aborted
            // code left in the heap (nothing outside the heap points into it)
            if let Some(d) = (*t).args_drop {
                d((*t).args);
            }
            crate::heap::switch(null_mut());
            crate::heap::sweep((*t).heap);
            (*t).heap = null_mut();
        }
        crate::heap::switch(null_mut());
        libc::free((*t).args);
        (*t).args = null_mut();
        if !(*t).kids.is_null() {
            let kids = Box::from_raw((*t).kids);
            (*t).kids = null_mut();
            for &k in kids.iter() {
                if !(*t).panic.is_null() {
                    duck_task_cancel(k);
                }
                crate::rc::duck_release(k.cast());
            }
        }
        let g = STATE.lock().unwrap_or_else(|e| e.into_inner());
        (*t).done.store(true, Ordering::SeqCst);
        if (*t).cancel.load(Ordering::SeqCst) {
            duck_cancel_pending.fetch_sub(1, Ordering::SeqCst);
        }
        drop(g);
        DONE.notify_all();
        CURRENT.with(|c| c.set(null_mut()));
    }
    null_mut()
}

/// `t.cancel()`: see the module docs. No effect on a finished task.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_task_cancel(t: *mut DuckTask) {
    if t.is_null() {
        return;
    }
    let _g = STATE.lock().unwrap_or_else(|e| e.into_inner());
    unsafe {
        if !(*t).done.load(Ordering::SeqCst) && !(*t).cancel.swap(true, Ordering::SeqCst) {
            duck_cancel_pending.fetch_add(1, Ordering::SeqCst);
        }
    }
}

/// Block until one of `ts` is done (the lowest index wins); cancellable.
unsafe fn wait_any(ts: &[*mut DuckTask]) -> usize {
    let mut g = STATE.lock().unwrap_or_else(|e| e.into_inner());
    loop {
        if let Some(i) = ts.iter().position(|&t| unsafe { (*t).done.load(Ordering::SeqCst) }) {
            return i;
        }
        if cancelled() {
            drop(g);
            check_cancel(c"a blocking call".as_ptr());
            g = STATE.lock().unwrap_or_else(|e| e.into_inner());
            continue;
        }
        g = DONE.wait_timeout(g, SLICE).unwrap_or_else(|e| e.into_inner()).0;
    }
}

/// `await any ts`: wait for the first task of `ts` to finish and return its index. Its result
/// goes to `out` (as `duck_task_await` writes it), or, when it panicked, the panic goes to
/// `*err` as an owned `Err` (the panic counts as seen).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_task_await_any(ts: *mut *mut DuckTask, n: i64, out: *mut c_void, err: *mut *mut DuckErr, loc: *const c_char) -> i64 {
    unsafe {
        if n <= 0 {
            rt_panic!(loc, "`await any` of an empty list");
        }
        let ts = std::slice::from_raw_parts(ts, n as usize);
        let i = wait_any(ts);
        let t = ts[i];
        task_join(t);
        if !(*t).panic.is_null() {
            (*t).observed = true;
            *err = crate::err::err_msg(&(*(*t).panic).err_text());
        } else {
            duck_task_await(t, out);
        }
        i as i64
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_task_spawn(
    fn_: DuckThunk,
    args: *const c_void,
    args_size: usize,
    result_size: usize,
    result_ops: *const DuckElemOps,
    heap: *mut c_void,
    args_drop: Option<unsafe extern "C" fn(*mut c_void)>,
) -> *mut DuckTask {
    unsafe {
        let t = duck__alloc(size_of::<DuckTask>(), DUCK_K_TASK) as *mut DuckTask;
        (*t).heap = heap.cast();
        (*t).args_drop = args_drop;
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
        // the link to the task that starts it (pruning the ones already finished)
        let parent = CURRENT.with(|c| c.get());
        if !parent.is_null() {
            // the runtime's own references: not the task's (not on its heap's ledger)
            let old = crate::heap::switch(null_mut());
            if (*parent).kids.is_null() {
                (*parent).kids = Box::into_raw(Box::new(Vec::new()));
            }
            let kids = &mut *(*parent).kids;
            kids.retain(|&k| {
                let keep = !(*k).done.load(Ordering::SeqCst);
                if !keep {
                    crate::rc::duck_release(k.cast());
                }
                keep
            });
            kids.push(crate::rc::retain(t));
            crate::heap::switch(old);
        }
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
        if on_task() {
            wait_any(&[t]);
        }
        task_join(t);
        if !(*t).panic.is_null() {
            // the link: the task's panic is raised again here, at its original location
            (*t).observed = true;
            let p = (*(*t).panic).clone();
            let loc = std::ffi::CString::new(p.loc).unwrap_or_default();
            crate::rc::panic_msg(loc.as_ptr(), &p.msg);
        }
        if !out.is_null() && (*t).result_size != 0 {
            // a deep copy into the awaiter's heap: the result stays in the task's
            if (*t).ops.is_null() {
                ptr::copy_nonoverlapping((*t).result as *const u8, out as *mut u8, (*t).result_size);
            } else {
                crate::copy::copy_elem((*t).ops, (*t).result as *const u8, out.cast());
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
        if !(*t).panic.is_null() {
            let p = Box::from_raw((*t).panic);
            (*t).panic = null_mut();
            // a cancelled task's "cancelled" panic was asked for: not a crash to report
            if !(*t).observed && !(*t).cancel.load(Ordering::SeqCst) {
                // nobody awaited it: report it as an uncaught panic would be, and end the process
                libc::fflush(crate::c_stdout());
                let text = format!("panic: {}\n  at {}\n  (in a task that was never awaited)\n", p.msg, p.loc);
                crate::fwrite_bytes(crate::c_stderr(), text.as_bytes());
                libc::fflush(crate::c_stderr());
                libc::_exit(101);
            }
            // the result was never written: don't release it
            libc::free((*t).result);
            libc::pthread_mutex_destroy(&raw mut (*t).mu);
            duck__free_obj(t.cast());
            return;
        }
        if !(*t).ops.is_null()
            && let Some(r) = (*(*t).ops).release
        {
            // as the task: the result's handle references are on its ledger
            let old = crate::heap::switch((*t).heap);
            r((*t).result);
            crate::heap::switch(old);
        }
        // what is left of the task's heap: objects a `catch` inside it gave up on
        crate::heap::sweep((*t).heap);
        (*t).heap = null_mut();
        libc::free((*t).result);
        libc::pthread_mutex_destroy(&raw mut (*t).mu);
        duck__free_obj(t.cast());
    }
}
