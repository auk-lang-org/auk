//! The debugger engine: now in C (`runtime/c/dbg.c`, which explains it). This keeps the
//! compiler's side of expression evaluation (src/dbg_eval.rs) unchanged: it registers a Rust
//! function, which a C-ABI adapter here calls.

use std::ffi::{c_char, c_void};
use std::sync::OnceLock;

use crate::*;

/// What the compiler hands back for an expression at a site: a function of the addresses of
/// the locals it uses (in `slots` order) that returns the value shown, and its type.
pub struct Compiled {
    pub run: unsafe extern "C" fn(*const *mut c_void) -> *mut AukStr,
    pub slots: Vec<u32>,
    pub ty: String,
}

/// The compiler's side (src/dbg_eval.rs, in the same process for `auk run --debug`): compile
/// `expr` at `site` of debug function `func`.
pub type EvalHook = fn(func: u32, site: u32, expr: &str) -> Result<Compiled, String>;

#[repr(C)]
struct CCompiled {
    run: Option<unsafe extern "C" fn(*const *mut c_void) -> *mut AukStr>,
    slots: *mut u32,
    nslots: i64,
    ty: *mut c_char,
}

type CHook = unsafe extern "C" fn(u32, u32, *const c_char, *mut CCompiled, *mut *mut c_char) -> bool;

unsafe extern "C" {
    fn auk_dbg_set_eval_hook(h: CHook);
}

static HOOK: OnceLock<EvalHook> = OnceLock::new();

/// A malloc'd C string of s (dbg.c keeps it).
fn c_text(s: &str) -> *mut c_char {
    unsafe {
        let p = libc::malloc(s.len() + 1) as *mut u8;
        std::ptr::copy_nonoverlapping(s.as_ptr(), p, s.len());
        *p.add(s.len()) = 0;
        p.cast()
    }
}

unsafe extern "C" fn adapter(func: u32, site: u32, expr: *const c_char, out: *mut CCompiled, err: *mut *mut c_char) -> bool {
    let Some(h) = HOOK.get() else { return false };
    let expr = unsafe { cstr(expr) };
    match h(func, site, &expr) {
        Ok(c) => unsafe {
            let slots = libc::malloc(c.slots.len().max(1) * size_of::<u32>()) as *mut u32;
            std::ptr::copy_nonoverlapping(c.slots.as_ptr(), slots, c.slots.len());
            *out = CCompiled { run: Some(c.run), slots, nslots: c.slots.len() as i64, ty: c_text(&c.ty) };
            true
        },
        Err(e) => {
            unsafe { *err = c_text(&e) };
            false
        }
    }
}

pub fn set_eval_hook(h: EvalHook) {
    let _ = HOOK.set(h);
    unsafe { auk_dbg_set_eval_hook(adapter) };
}
