//! The few runtime services the compiler itself uses (the runtime, `runtime/c`, is linked into
//! it): the `auk run --live` driver's reload counter, task cancellation and window shutdown, the
//! window process's entry, and the debugger's expression hook.

use std::ffi::{c_char, c_void};
use std::sync::OnceLock;
use std::sync::atomic::AtomicI64;

/// An Auk string (`AukStr`, runtime/c/auk_rt.h): only its address is used here.
#[repr(C)]
pub struct AukStr {
    _private: [u8; 0],
}

unsafe extern "C" {
    /// How many times `auk run --live` has swapped new code into this program.
    #[link_name = "auk__live_reloads"]
    pub safe static LIVE_RELOADS: AtomicI64;
    fn auk__cancel_running(pick: unsafe extern "C" fn(*mut c_void, usize, usize) -> bool, ctx: *mut c_void) -> i64;
    safe fn auk_gui_shutdown();
    safe fn auk__gui_host_main() -> i32;
    fn auk_dbg_set_eval_hook(h: CHook);
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

/// Close this program's windows: it is ending normally (`auk run --live` calls this when the
/// program returns, so its windows don't wait to be taken over by the next run).
pub fn gui_shutdown() {
    auk_gui_shutdown()
}

/// Run the window process (`AUK_GUI_HOST` is set). Returns an exit code only if it can't start.
pub fn gui_host_main() -> i32 {
    auk__gui_host_main()
}

// ---- the debugger's expression hook ----

/// What the compiler hands back for an expression at a site: a function of the addresses of
/// the locals it uses (in `slots` order) that returns the value shown, and its type.
pub struct Compiled {
    pub run: unsafe extern "C" fn(*const *mut c_void) -> *mut AukStr,
    pub slots: Vec<u32>,
    pub ty: String,
}

/// Compile `expr` at `site` of debug function `func` (src/dbg_eval.rs).
pub type EvalHook = fn(func: u32, site: u32, expr: &str) -> Result<Compiled, String>;

/// `AukDbgCompiled` (dbg.c).
#[repr(C)]
struct CCompiled {
    run: Option<unsafe extern "C" fn(*const *mut c_void) -> *mut AukStr>,
    slots: *mut u32,
    nslots: i64,
    ty: *mut c_char,
}

type CHook = unsafe extern "C" fn(u32, u32, *const c_char, *mut CCompiled, *mut *mut c_char) -> bool;

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
    let expr = unsafe { std::ffi::CStr::from_ptr(expr) }.to_string_lossy();
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

/// Let the debugger (dbg.c) evaluate expressions through `h`.
pub fn set_eval_hook(h: EvalHook) {
    let _ = HOOK.set(h);
    unsafe { auk_dbg_set_eval_hook(adapter) };
}
