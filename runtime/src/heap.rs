//! Per-task heaps: now in C (`runtime/c/heap.c`, which explains them). These declarations keep
//! the Rust modules not yet ported compiling.

use std::ffi::c_void;

/// A task's heap (opaque; heap.c).
pub enum Heap {}

/// Is an object of this kind a handle (never tracked, shared by reference count)?
pub fn is_handle(kind: u32) -> bool {
    (crate::AUK_K_TASK..=crate::AUK_K_FRAME).contains(&kind)
}

unsafe extern "C" {
    #[link_name = "auk__note_handle"]
    pub safe fn note_handle(p: *const c_void, delta: i64);
    #[link_name = "auk__heap_new"]
    pub safe fn new() -> *mut Heap;
    #[link_name = "auk__heap_current"]
    pub safe fn current() -> *mut Heap;
    #[link_name = "auk__heap_switch"]
    pub safe fn switch(h: *mut Heap) -> *mut Heap;
    #[link_name = "auk__heap_sweep"]
    pub unsafe fn sweep(heap: *mut Heap);
}
