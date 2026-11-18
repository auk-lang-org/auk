//! Async tasks: now in C (`runtime/c/task.c`, which explains them). These declarations keep the
//! Rust modules not yet ported, and the compiler's `--live` driver, compiling.

use std::ffi::{c_char, c_void};
use std::sync::atomic::AtomicI64;

use crate::*;

/// `typedef void (*AukThunk)(void *args, void *result);`
pub type AukThunk = unsafe extern "C" fn(*mut c_void, *mut c_void);

/// A task (opaque; task.c).
pub enum AukTask {}

unsafe extern "C" {
    /// How many times `auk run --live` has swapped new code into this program.
    #[link_name = "auk__live_reloads"]
    pub safe static LIVE_RELOADS: AtomicI64;
    pub safe static auk_cancel_pending: AtomicI64;
    #[link_name = "auk__task_cancelled"]
    pub safe fn cancelled() -> bool;
    #[link_name = "auk__on_task"]
    pub safe fn on_task() -> bool;
    #[link_name = "auk__check_cancel"]
    pub safe fn check_cancel(loc: *const c_char);
    #[link_name = "auk__wait_fd"]
    pub safe fn wait_fd(fd: i32, write: bool);
    #[link_name = "auk__sleep_ms"]
    pub safe fn sleep_ms(ms: i64);
    fn auk__cancel_running(pick: unsafe extern "C" fn(*mut c_void, usize, usize) -> bool, ctx: *mut c_void) -> i64;
    pub unsafe fn auk_cancel_check(loc: *const c_char);
    pub unsafe fn auk_task_done(t: *mut AukTask) -> bool;
    pub safe fn auk_live_reloads() -> i64;
    pub unsafe fn auk_task_cancel(t: *mut AukTask);
    pub unsafe fn auk_task_await_any(ts: *mut *mut AukTask, n: i64, out: *mut c_void, err: *mut *mut AukErr, loc: *const c_char) -> i64;
    pub unsafe fn auk_task_spawn(
        fn_: AukThunk,
        args: *const c_void,
        args_size: usize,
        result_size: usize,
        result_ops: *const AukElemOps,
        heap: *mut c_void,
        args_drop: Option<unsafe extern "C" fn(*mut c_void)>,
        hint: *const c_void,
    ) -> *mut AukTask;
    pub unsafe fn auk_task_await(t: *mut AukTask, out: *mut c_void);
    pub unsafe fn auk_task_join_all(ts: *mut *mut AukTask, n: i64);
    pub unsafe fn auk_task_await_all(ts: *mut *mut AukTask, n: i64, outs: *mut c_void);
}

/// Cancel each running task that `pick(entry, hint)` selects (its thunk's address and its
/// closure hint); returns how many.
pub fn cancel_running(pick: impl Fn(usize, usize) -> bool) -> usize {
    unsafe extern "C" fn tramp<F: Fn(usize, usize) -> bool>(ctx: *mut c_void, entry: usize, hint: usize) -> bool {
        unsafe { (*(ctx as *const F))(entry, hint) }
    }
    fn go<F: Fn(usize, usize) -> bool>(pick: &F) -> usize {
        unsafe { auk__cancel_running(tramp::<F>, (pick as *const F).cast_mut().cast()) as usize }
    }
    go(&pick)
}
