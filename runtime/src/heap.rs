//! Per-task heaps: what makes a crashed task leave nothing behind.
//!
//! Every task thread allocates into a heap of its own. A tracked object has a hidden prefix just
//! before its header (`Link`: the heap's doubly linked list, and the heap itself), and its
//! header's `flags` say so; objects allocated with no current heap (the main thread, constants,
//! handles) have no prefix and are not tracked.
//!
//! Nothing crosses a task boundary by reference: spawn arguments are deep-copied into the new
//! task's heap, `await` deep-copies the result into the awaiter's, and channels copy messages.
//! Only handles (tasks, connections, listeners, channels) are shared, and they are never tracked.
//! So when a task's heap goes (its task crashed, was cancelled or was freed), no object outside
//! the heap can point into it, and `sweep` frees everything still in it, whatever its reference
//! count says: what aborted code never released, and what a `catch` inside the task left behind.
//!
//! Handles live outside every heap, so a heap also keeps a ledger of the references its task
//! took on handles (creating one counts, as do retains, minus releases). References held only by
//! the frames of a crashed task are on the ledger and nowhere else: the sweep gives them back,
//! closing the connections the task still had open (as Erlang closes a dead process's ports).

use std::cell::Cell;
use std::ffi::c_void;
use std::ptr::null_mut;
use std::sync::Mutex;
use std::sync::atomic::Ordering;

use crate::*;

/// `DuckHeader::flags`: the object has a `Link` prefix and belongs to a heap.
pub const TRACKED: u32 = 1;

/// The prefix of a tracked object (32 bytes, so the header stays 16-byte aligned).
#[repr(C)]
pub struct Link {
    prev: *mut Link,
    next: *mut Link,
    heap: *mut Heap,
    _pad: usize,
}

pub const PREFIX: usize = size_of::<Link>();

pub struct Heap {
    lock: Mutex<()>,
    /// The list's sentinel.
    head: Link,
    /// References this heap's task holds on handles (by address).
    handles: Mutex<std::collections::HashMap<usize, i64>>,
}

/// Is an object of this kind a handle (never tracked, shared by reference count)?
pub fn is_handle(kind: u32) -> bool {
    matches!(kind, DUCK_K_TASK | DUCK_K_CONN | DUCK_K_LISTENER | DUCK_K_CHAN | DUCK_K_FRAME)
}

/// The current task took (`+1`) or gave back (`-1`) a reference to the handle `p`.
pub fn note_handle(p: *const c_void, delta: i64) {
    let h = current();
    if h.is_null() {
        return;
    }
    let mut m = unsafe { (*h).handles.lock().unwrap_or_else(|e| e.into_inner()) };
    let n = m.entry(p as usize).or_insert(0);
    *n += delta;
    if *n == 0 {
        m.remove(&(p as usize));
    }
}

/// A reference count no release can bring to zero while a heap is swept.
const DYING: i64 = i64::MAX / 4;

thread_local! {
    static CURRENT: Cell<*mut Heap> = const { Cell::new(null_mut()) };
}

/// A new, empty heap.
pub fn new() -> *mut Heap {
    let h = Box::into_raw(Box::new(Heap {
        lock: Mutex::new(()),
        head: Link { prev: null_mut(), next: null_mut(), heap: null_mut(), _pad: 0 },
        handles: Mutex::new(std::collections::HashMap::new()),
    }));
    unsafe {
        let s = &raw mut (*h).head;
        (*s).prev = s;
        (*s).next = s;
    }
    h
}

/// This thread's heap (null: untracked).
pub fn current() -> *mut Heap {
    CURRENT.with(|c| c.get())
}

/// Make `h` this thread's heap; returns the previous one.
pub fn switch(h: *mut Heap) -> *mut Heap {
    CURRENT.with(|c| c.replace(h))
}

/// For generated code: switch heaps (a constant's initializer runs untracked, since its value
/// outlives the task that happened to compute it first).
#[unsafe(no_mangle)]
pub extern "C" fn duck_heap_switch(h: *mut c_void) -> *mut c_void {
    switch(h.cast()).cast()
}

/// For generated code: a fresh heap for a task about to be spawned.
#[unsafe(no_mangle)]
pub extern "C" fn duck_heap_new() -> *mut c_void {
    new().cast()
}

/// Allocate `size` zeroed bytes for an object of `kind` in the current heap (untracked when
/// there is none, or for a handle kind). Returns the header's address.
pub unsafe fn alloc(size: usize, kind: u32) -> *mut DuckHeader {
    let heap = if is_handle(kind) { null_mut() } else { current() };
    unsafe {
        if heap.is_null() {
            let h = crate::rc::duck__xcalloc(1, size) as *mut DuckHeader;
            (*h).kind = kind;
            if is_handle(kind) {
                note_handle(h.cast(), 1);
            }
            return h;
        }
        let l = crate::rc::duck__xcalloc(1, PREFIX + size) as *mut Link;
        let h = (l as *mut u8).add(PREFIX) as *mut DuckHeader;
        (*h).kind = kind;
        (*h).flags = TRACKED;
        (*l).heap = heap;
        let _g = (*heap).lock.lock().unwrap_or_else(|e| e.into_inner());
        let s = &raw mut (*heap).head;
        (*l).prev = s;
        (*l).next = (*s).next;
        (*(*s).next).prev = l;
        (*s).next = l;
        h
    }
}

/// Free an object's memory (taking it off its heap's list).
pub unsafe fn free(h: *mut DuckHeader) {
    unsafe {
        if (*h).flags & TRACKED == 0 {
            libc::free(h.cast());
            return;
        }
        let l = (h as *mut u8).sub(PREFIX) as *mut Link;
        let heap = (*l).heap;
        {
            let _g = (*heap).lock.lock().unwrap_or_else(|e| e.into_inner());
            (*(*l).prev).next = (*l).next;
            (*(*l).next).prev = (*l).prev;
        }
        libc::free(l.cast());
    }
}

/// Free every object still in `heap`, then the heap. No object outside it may point into it.
/// Each object is freed by its kind's ordinary free routine, so what it holds outside the heap
/// (handles: a connection, a task) is released properly; objects inside the heap first get a
/// reference count no release can bring to zero, so each is freed exactly once, here.
pub unsafe fn sweep(heap: *mut Heap) {
    if heap.is_null() {
        return;
    }
    unsafe {
        let objs: Vec<*mut DuckHeader> = {
            let _g = (*heap).lock.lock().unwrap_or_else(|e| e.into_inner());
            let s = &raw mut (*heap).head;
            let mut out = Vec::new();
            let mut l = (*s).next;
            while l != s {
                let h = (l as *mut u8).add(PREFIX) as *mut DuckHeader;
                let next = (*l).next;
                if (*h).rc.load(Ordering::SeqCst) < 0 {
                    // immortal: it must stay; just take it off the list
                    (*(*l).prev).next = next;
                    (*next).prev = (*l).prev;
                    (*h).flags &= !TRACKED;
                } else {
                    (*h).rc.store(DYING, Ordering::SeqCst);
                    out.push(h);
                }
                l = next;
            }
            out
        };
        // free them as this heap's task would (their handle releases come off its ledger)
        let old = switch(heap);
        for h in objs {
            crate::rc::free_now(h.cast());
        }
        switch(null_mut());
        let held: Vec<(usize, i64)> = (*heap).handles.lock().unwrap_or_else(|e| e.into_inner()).drain().collect();
        for (p, n) in held {
            for _ in 0..n {
                crate::rc::duck_release(p as *mut c_void);
            }
        }
        switch(if old == heap { null_mut() } else { old });
        drop(Box::from_raw(heap));
    }
}
