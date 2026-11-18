//! Frames: now in C (`runtime/c/pixels.c`). This keeps gui.rs compiling until it is ported.

use crate::*;

/// A frame's pixels.
pub unsafe fn pixels<'a>(f: *const AukFrame) -> &'a [u32] {
    unsafe { std::slice::from_raw_parts((*f).data.as_ptr(), ((*f).w * (*f).hgt) as usize) }
}
