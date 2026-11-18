//! Channels: `Chan<T>` (core.auk) wraps a `AukChan *`, an unbounded FIFO shared by every copy
//! of the channel (a handle: never copied, never in a task's heap). `send` stores an untracked
//! deep copy of the message; `recv` deep-copies it again into the receiver's heap and frees the
//! stored one, so sender and receiver never share an object (heap.rs).

use std::collections::VecDeque;
use std::ffi::{c_char, c_void};
use std::ptr::null_mut;
use std::sync::{Condvar, Mutex};
use std::time::Duration;

use crate::rc::auk__alloc;
use crate::*;

#[repr(C)]
pub struct AukChan {
    pub h: AukHeader,
    inner: *mut Inner,
}

struct Inner {
    state: Mutex<State>,
    cv: Condvar,
    ops: *const AukElemOps,
}

struct State {
    items: VecDeque<Box<[u8]>>,
    closed: bool,
}

/// A new channel for elements described by `proto`'s element ops (`proto` is an empty `[T]`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_chan_new(proto: *mut AukArr) -> *mut AukChan {
    unsafe {
        let c = auk__alloc(size_of::<AukChan>(), AUK_K_CHAN) as *mut AukChan;
        let inner = Inner { state: Mutex::new(State { items: VecDeque::new(), closed: false }), cv: Condvar::new(), ops: (*proto).ops };
        (*c).inner = Box::into_raw(Box::new(inner));
        c
    }
}

/// `c.send(x)`: queue a copy of `*x`. Panics on a closed channel.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_chan_send(c: *mut AukChan, x: *const c_void, loc: *const c_char) {
    unsafe {
        let inner = &*(*c).inner;
        let mut buf = vec![0u8; (*inner.ops).size.max(1)].into_boxed_slice();
        let old = crate::heap::switch(null_mut());
        crate::copy::copy_elem(inner.ops, x.cast(), buf.as_mut_ptr());
        crate::heap::switch(old);
        let mut st = inner.state.lock().unwrap_or_else(|e| e.into_inner());
        if st.closed {
            drop(st);
            if let Some(r) = (*inner.ops).release {
                r(buf.as_mut_ptr().cast());
            }
            rt_panic!(loc, "send on a closed channel");
        }
        st.items.push_back(buf);
        drop(st);
        inner.cv.notify_one();
    }
}

/// `c.recv()`: wait for a message and write a copy to `out`; false once the channel is closed
/// and empty. Cancellable on a task thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_chan_recv(c: *mut AukChan, out: *mut c_void) -> bool {
    unsafe {
        let inner = &*(*c).inner;
        let mut st = inner.state.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            if let Some(mut b) = st.items.pop_front() {
                drop(st);
                crate::copy::copy_elem(inner.ops, b.as_ptr(), out.cast());
                if let Some(r) = (*inner.ops).release {
                    let old = crate::heap::switch(null_mut());
                    r(b.as_mut_ptr().cast());
                    crate::heap::switch(old);
                }
                return true;
            }
            if st.closed {
                return false;
            }
            if crate::task::on_task() {
                drop(st);
                crate::task::check_cancel(c"a channel receive".as_ptr());
                st = inner.state.lock().unwrap_or_else(|e| e.into_inner());
                st = inner.cv.wait_timeout(st, Duration::from_millis(50)).unwrap_or_else(|e| e.into_inner()).0;
            } else {
                st = inner.cv.wait(st).unwrap_or_else(|e| e.into_inner());
            }
        }
    }
}

/// `c.recv_for(ms)`: `recv`, giving up after `ms` milliseconds (false: closed and empty, or
/// nothing came in time). Cancellable on a task thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_chan_recv_for(c: *mut AukChan, ms: i64, out: *mut c_void) -> bool {
    unsafe {
        let inner = &*(*c).inner;
        let end = std::time::Instant::now() + Duration::from_millis(ms.max(0) as u64);
        let mut st = inner.state.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            if let Some(mut b) = st.items.pop_front() {
                drop(st);
                crate::copy::copy_elem(inner.ops, b.as_ptr(), out.cast());
                if let Some(r) = (*inner.ops).release {
                    let old = crate::heap::switch(null_mut());
                    r(b.as_mut_ptr().cast());
                    crate::heap::switch(old);
                }
                return true;
            }
            let now = std::time::Instant::now();
            if st.closed || now >= end {
                return false;
            }
            let wait = (end - now).min(Duration::from_millis(50));
            if crate::task::on_task() {
                drop(st);
                crate::task::check_cancel(c"a channel receive".as_ptr());
                st = inner.state.lock().unwrap_or_else(|e| e.into_inner());
            }
            st = inner.cv.wait_timeout(st, wait).unwrap_or_else(|e| e.into_inner()).0;
        }
    }
}

/// `c.close()`: no more sends; receivers drain what is queued, then get none.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_chan_close(c: *mut AukChan) {
    unsafe {
        let inner = &*(*c).inner;
        inner.state.lock().unwrap_or_else(|e| e.into_inner()).closed = true;
        inner.cv.notify_all();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk__chan_free(c: *mut AukChan) {
    unsafe {
        let inner = Box::from_raw((*c).inner);
        let st = inner.state.into_inner().unwrap_or_else(|e| e.into_inner());
        for mut b in st.items {
            if let Some(r) = (*inner.ops).release {
                r(b.as_mut_ptr().cast());
            }
        }
        crate::rc::auk__free_obj(c.cast());
    }
}
