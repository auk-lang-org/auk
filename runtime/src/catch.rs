//! Recovering from panics: `catch e` and task threads. A thread may have recovery points
//! (`catch.c`, a stack of `sigsetjmp` buffers); a panic on such a thread records its message
//! here and jumps to the innermost one instead of ending the process. The aborted code is not
//! cleaned up: objects it owned leak, and `var` state it was changing stays half-changed.

use std::cell::RefCell;
use std::ffi::{c_int, c_void};
use std::ptr::null_mut;

use crate::task::DuckThunk;
use crate::*;

unsafe extern "C" {
    fn duck__catch_run(f: DuckThunk, env: *mut c_void, out: *mut c_void) -> c_int;
    fn duck__catch_active() -> c_int;
    fn duck__catch_throw() -> !;
}

/// A recovered panic: its message and where it happened.
#[derive(Clone)]
pub struct Panic {
    pub msg: String,
    pub loc: String,
}

impl Panic {
    /// The text of the `Err` a recovered panic becomes.
    pub fn err_text(&self) -> String {
        format!("panic: {} at {}", self.msg, self.loc)
    }
}

thread_local! {
    static CAUGHT: RefCell<Option<Panic>> = const { RefCell::new(None) };
}

/// Does this thread have a recovery point?
pub fn recoverable() -> bool {
    unsafe { duck__catch_active() != 0 }
}

/// Record the panic and jump to this thread's innermost recovery point (`recoverable()` must
/// hold).
pub fn throw(loc: &str, msg: &str) -> ! {
    let p = Panic { msg: msg.to_string(), loc: loc.to_string() };
    CAUGHT.with(|c| *c.borrow_mut() = Some(p));
    unsafe { duck__catch_throw() }
}

/// Run `f(env, out)` under a recovery point: None if it finished, the panic if one jumped back.
pub unsafe fn run(f: DuckThunk, env: *mut c_void, out: *mut c_void) -> Option<Panic> {
    let saved = crate::trace::save_state();
    let dbg = crate::dbg::save_state();
    if unsafe { duck__catch_run(f, env, out) } == 0 {
        return None;
    }
    crate::trace::restore_state(saved);
    crate::dbg::restore_state(dbg);
    Some(CAUGHT.with(|c| c.borrow_mut().take()).unwrap_or(Panic { msg: "panic".into(), loc: "<unknown>".into() }))
}

/// `catch e`: run the thunk (it writes e's value to `out`); NULL when it finished, else the
/// panic as a new (owned) Err and `out` untouched.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_catch(f: DuckThunk, env: *mut c_void, out: *mut c_void) -> *mut DuckErr {
    match unsafe { run(f, env, out) } {
        None => null_mut(),
        // a cancelled task must end: pass the panic on to the next recovery point out (the
        // task's own, at the latest)
        Some(p) if crate::task::cancelled() => throw(&p.loc, &p.msg),
        Some(p) => crate::err::err_msg(&p.err_text()),
    }
}
