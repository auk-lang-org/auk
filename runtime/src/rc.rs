//! Refcounting, allocation, panics, arithmetic, hashing and scalar element ops (was rc.c).

use std::ffi::{c_char, c_int, c_void};
use std::sync::Mutex;
use std::sync::atomic::{AtomicI64, Ordering, fence};

use crate::*;

// ---- allocation & leak counter -----------------------------------------------------------

static LIVE_OBJECTS: AtomicI64 = AtomicI64::new(0);

#[unsafe(no_mangle)]
pub extern "C" fn auk_live_objects() -> i64 {
    LIVE_OBJECTS.load(Ordering::SeqCst)
}

fn oom() -> ! {
    fwrite_bytes(c_stderr(), b"panic: out of memory\n");
    unsafe { libc::_exit(101) }
}

pub unsafe fn auk__xmalloc(n: usize) -> *mut c_void {
    let p = unsafe { libc::malloc(n.max(1)) };
    if p.is_null() {
        oom()
    }
    p
}
pub unsafe fn auk__xcalloc(n: usize, sz: usize) -> *mut c_void {
    let p = unsafe { libc::calloc(n.max(1), sz.max(1)) };
    if p.is_null() {
        oom()
    }
    p
}
pub unsafe fn auk__xrealloc(p: *mut c_void, n: usize) -> *mut c_void {
    let q = unsafe { libc::realloc(p, n.max(1)) };
    if q.is_null() {
        oom()
    }
    q
}

/// Allocate a zeroed heap object with rc = 1 (counted as live).
pub unsafe fn auk__alloc(size: usize, kind: u32) -> *mut c_void {
    let h = unsafe { crate::heap::alloc(size, kind) };
    unsafe {
        (*h).rc.store(1, Ordering::Relaxed);
    }
    LIVE_OBJECTS.fetch_add(1, Ordering::Relaxed);
    h.cast()
}

/// Free the object memory itself (and update the live counter).
pub unsafe fn auk__free_obj(p: *mut c_void) {
    LIVE_OBJECTS.fetch_sub(1, Ordering::Relaxed);
    unsafe { crate::heap::free(p.cast()) }
}

pub unsafe fn auk__make_immortal(p: *mut c_void) {
    if p.is_null() {
        return;
    }
    let h = p as *mut AukHeader;
    unsafe {
        if (*h).rc.load(Ordering::SeqCst) < 0 {
            return;
        }
        (*h).rc.store(i64::MIN / 2, Ordering::SeqCst);
    }
    LIVE_OBJECTS.fetch_sub(1, Ordering::Relaxed);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_make_immortal(p: *mut c_void) {
    unsafe { auk__make_immortal(p) }
}

static CLEANUP: Mutex<Option<unsafe extern "C" fn()>> = Mutex::new(None);

#[unsafe(no_mangle)]
pub extern "C" fn auk_set_cleanup(f: Option<unsafe extern "C" fn()>) {
    *CLEANUP.lock().unwrap_or_else(|e| e.into_inner()) = f;
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_leak_check() -> i64 {
    if std::env::var_os("AUK_LEAK_CHECK").is_none() {
        return 0;
    }
    let f = *CLEANUP.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(f) = f {
        unsafe { f() };
    }
    let n = auk_live_objects();
    if n != 0 {
        unsafe { libc::fflush(c_stdout()) };
        fwrite_bytes(c_stderr(), format!("leak: {n} runtime object(s) still live at exit\n").as_bytes());
        unsafe { libc::fflush(c_stderr()) };
    }
    n
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_retain(p: *mut c_void) -> *mut c_void {
    if p.is_null() {
        return p;
    }
    let h = p as *const AukHeader;
    unsafe {
        if (*h).rc.load(Ordering::Relaxed) < 0 {
            return p;
        }
        (*h).rc.fetch_add(1, Ordering::Relaxed);
        if crate::heap::is_handle((*h).kind) {
            crate::heap::note_handle(p, 1);
        }
    }
    p
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_release(p: *mut c_void) {
    if p.is_null() {
        return;
    }
    let h = p as *const AukHeader;
    unsafe {
        if (*h).rc.load(Ordering::Relaxed) < 0 {
            return;
        }
        if crate::heap::is_handle((*h).kind) {
            crate::heap::note_handle(p, -1);
        }
        if (*h).rc.fetch_sub(1, Ordering::Release) != 1 {
            return;
        }
        fence(Ordering::Acquire);
        free_now(p);
    }
}

/// The slow end of `auk_release` inlined by the LLVM back end: generated code has already
/// dropped the last reference (its decrement returned 1) and issued the acquire fence.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk__free_last(p: *mut c_void) {
    unsafe { free_now(p) }
}

/// Free an object whose last reference is gone (or whose heap is being swept): release what it
/// holds and free its memory, by kind.
pub unsafe fn free_now(p: *mut c_void) {
    let h = p as *const AukHeader;
    unsafe {
        match (*h).kind {
            AUK_K_STR => crate::str::auk__str_free(p.cast()),
            AUK_K_ARR => crate::arr::auk__arr_free(p.cast()),
            AUK_K_MAP => crate::map::auk__map_free(p.cast()),
            AUK_K_ERR => crate::err::auk__err_free(p.cast()),
            AUK_K_TASK => crate::task::auk__task_free(p.cast()),
            AUK_K_CONN => crate::core::auk__conn_free(p.cast()),
            AUK_K_LISTENER => crate::core::auk__listener_free(p.cast()),
            AUK_K_CHAN => crate::chan::auk__chan_free(p.cast()),
            AUK_K_FRAME => auk__free_obj(p),
            AUK_K_OBJ => {
                let o = p as *mut AukObj;
                if let Some(d) = (*o).drop {
                    d(o);
                }
                auk__free_obj(p);
            }
            k => panic_msg(c"runtime".as_ptr(), &format!("release of an object with unknown kind {k}")),
        }
    }
}

/// Typed conveniences for Rust callers.
pub unsafe fn retain<T>(p: *mut T) -> *mut T {
    unsafe { auk_retain(p.cast()).cast() }
}
pub unsafe fn release<T>(p: *mut T) {
    unsafe { auk_release(p.cast()) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_refcount(p: *const c_void) -> i64 {
    if p.is_null() {
        return 0;
    }
    unsafe { (*(p as *const AukHeader)).rc.load(Ordering::SeqCst) }
}


// ---- panics ------------------------------------------------------------------------------

/// The one panic path: flush stdout, print `panic: <msg>\n  at <loc>`, record it in the trace,
/// and `_exit(101)` (no atexit handlers: other threads may still be busy). Under a recovery point
/// (`catch`, a task thread) it jumps back there instead (catch.rs).
pub fn panic_msg(loc: *const c_char, msg: &str) -> ! {
    unsafe { libc::fflush(c_stdout()) };
    // C's fixed 2 KB buffer truncated long messages; keep that bound.
    let mut msg = msg;
    if msg.len() > 2047 {
        let mut end = 2047;
        while !msg.is_char_boundary(end) {
            end -= 1;
        }
        msg = &msg[..end];
    }
    let loc_s = if loc.is_null() { "<unknown>".into() } else { unsafe { cstr(loc) } };
    crate::dbg::on_panic(&loc_s, msg, crate::catch::recoverable());
    // inside `catch` (or on a task thread, whose awaiter re-raises it): record it, jump back
    if crate::catch::recoverable() {
        crate::trace::auk__trace_panic(loc, msg, true);
        crate::catch::throw(&loc_s, msg);
    }
    fwrite_bytes(c_stderr(), format!("panic: {msg}\n  at {loc_s}\n").as_bytes());
    unsafe { libc::fflush(c_stderr()) };
    crate::trace::auk__trace_panic(loc, msg, false);
    unsafe { libc::_exit(101) }
}

/// The panic entry point for generated code: `msg` is a NUL-terminated message.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_panic_str(loc: *const c_char, msg: *const c_char) -> ! {
    panic_msg(loc, &unsafe { cstr(msg) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_panic_overflow(loc: *const c_char, op: *const c_char) -> ! {
    panic_msg(loc, &format!("integer overflow in `{}`", unsafe { cstr(op) }))
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_panic_div_zero(loc: *const c_char) -> ! {
    panic_msg(loc, "division by zero")
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_unwrap_none(loc: *const c_char) -> ! {
    panic_msg(loc, "unwrapped `none`")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_unwrap_err(loc: *const c_char, e: *mut AukErr) -> ! {
    let s = unsafe { crate::err::auk_err_show(e) };
    panic_msg(loc, &format!("unwrapped an error: {}", unsafe { sstr(s) }))
}

// ---- arithmetic --------------------------------------------------------------------------
// The checked-arithmetic helpers (the C runtime had them `static inline`) are exported here (the generated code calls
// or inlines them; C code keeps using the header's inline copies).

#[unsafe(no_mangle)]
pub extern "C" fn auk_add(a: i64, b: i64, loc: *const c_char) -> i64 {
    a.checked_add(b).unwrap_or_else(|| unsafe { auk_panic_overflow(loc, c"+".as_ptr()) })
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_sub(a: i64, b: i64, loc: *const c_char) -> i64 {
    a.checked_sub(b).unwrap_or_else(|| unsafe { auk_panic_overflow(loc, c"-".as_ptr()) })
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_mul(a: i64, b: i64, loc: *const c_char) -> i64 {
    a.checked_mul(b).unwrap_or_else(|| unsafe { auk_panic_overflow(loc, c"*".as_ptr()) })
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_div(a: i64, b: i64, loc: *const c_char) -> i64 {
    if b == 0 {
        auk_panic_div_zero(loc)
    }
    if a == i64::MIN && b == -1 {
        unsafe { auk_panic_overflow(loc, c"/".as_ptr()) }
    }
    a / b
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_mod(a: i64, b: i64, loc: *const c_char) -> i64 {
    if b == 0 {
        auk_panic_div_zero(loc)
    }
    if b == -1 {
        return 0;
    }
    a % b
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_neg(a: i64, loc: *const c_char) -> i64 {
    if a == i64::MIN {
        unsafe { auk_panic_overflow(loc, c"-".as_ptr()) }
    }
    -a
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_wadd(a: i64, b: i64) -> i64 {
    a.wrapping_add(b)
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_wsub(a: i64, b: i64) -> i64 {
    a.wrapping_sub(b)
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_wmul(a: i64, b: i64) -> i64 {
    a.wrapping_mul(b)
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_shl(a: i64, n: i64, loc: *const c_char) -> i64 {
    if n as u64 > 63 {
        panic_msg(loc, &format!("shift amount {n} is outside 0..63"))
    }
    ((a as u64) << n) as i64
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_shr(a: i64, n: i64, loc: *const c_char) -> i64 {
    if n as u64 > 63 {
        panic_msg(loc, &format!("shift amount {n} is outside 0..63"))
    }
    a >> n
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_int_cmp(a: i64, b: i64) -> c_int {
    (a > b) as c_int - (a < b) as c_int
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_pow(mut a: i64, mut b: i64, loc: *const c_char) -> i64 {
    if b < 0 {
        panic_msg(loc, "negative exponent in `**`")
    }
    let ovf = || -> ! { unsafe { auk_panic_overflow(loc, c"**".as_ptr()) } };
    let mut r: i64 = 1;
    while b > 0 {
        if b & 1 != 0 {
            r = r.checked_mul(a).unwrap_or_else(|| ovf());
        }
        b >>= 1;
        if b > 0 {
            a = a.checked_mul(a).unwrap_or_else(|| ovf());
        }
    }
    r
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_int_abs(a: i64, loc: *const c_char) -> i64 {
    if a == i64::MIN {
        unsafe { auk_panic_overflow(loc, c"abs".as_ptr()) }
    }
    a.abs()
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_fpow(a: f64, b: f64) -> f64 {
    a.powf(b)
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_fmod(a: f64, b: f64) -> f64 {
    a % b
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_fsqrt(a: f64) -> f64 {
    a.sqrt()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_fabs(a: f64) -> f64 {
    a.abs()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_ffloor(a: f64) -> f64 {
    a.floor()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_fceil(a: f64) -> f64 {
    a.ceil()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_fround(a: f64) -> f64 {
    a.round()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_fsin(a: f64) -> f64 {
    a.sin()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_fcos(a: f64) -> f64 {
    a.cos()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_ftan(a: f64) -> f64 {
    a.tan()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_fasin(a: f64) -> f64 {
    a.asin()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_facos(a: f64) -> f64 {
    a.acos()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_fatan(a: f64) -> f64 {
    a.atan()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_fexp(a: f64) -> f64 {
    a.exp()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_fln(a: f64) -> f64 {
    a.ln()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_flog10(a: f64) -> f64 {
    a.log10()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_flog2(a: f64) -> f64 {
    a.log2()
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_fatan2(y: f64, x: f64) -> f64 {
    y.atan2(x)
}
/// The IEEE 754 bits of a float, as an int.
#[unsafe(no_mangle)]
pub extern "C" fn auk_fbits(a: f64) -> i64 {
    a.to_bits() as i64
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_ffrom_bits(n: i64) -> f64 {
    f64::from_bits(n as u64)
}
/// The bits of a float rounded to single precision (0 to 2^32 - 1).
#[unsafe(no_mangle)]
pub extern "C" fn auk_fbits32(a: f64) -> i64 {
    i64::from((a as f32).to_bits())
}
/// A single-precision float from its low 32 bits.
#[unsafe(no_mangle)]
pub extern "C" fn auk_ffrom_bits32(n: i64) -> f64 {
    f64::from(f32::from_bits(n as u32))
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_float_to_int(x: f64, loc: *const c_char) -> i64 {
    if x.is_nan() {
        panic_msg(loc, "int(NaN)")
    }
    if !(-9223372036854775808.0..9223372036854775808.0).contains(&x) {
        panic_msg(loc, &format!("int({}) is out of range", fmt_g(x)))
    }
    x as i64
}

/// C's `%g` (6 significant digits, shortest of %e/%f, trailing zeros stripped).
pub fn fmt_g(x: f64) -> String {
    let mut buf = [0u8; 64];
    let n = unsafe { libc::snprintf(buf.as_mut_ptr().cast(), buf.len(), c"%g".as_ptr(), x) };
    String::from_utf8_lossy(&buf[..(n.max(0) as usize).min(63)]).into_owned()
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_float_cmp(a: f64, b: f64) -> c_int {
    if a.is_nan() || b.is_nan() {
        return a.is_nan() as c_int - b.is_nan() as c_int;
    }
    (a > b) as c_int - (a < b) as c_int
}

// ---- hashing -----------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_hash_bytes(p: *const c_void, n: usize) -> u64 {
    let b: &[u8] = if n == 0 { &[] } else { unsafe { std::slice::from_raw_parts(p.cast(), n) } };
    let mut h: u64 = 1469598103934665603;
    for &x in b {
        h ^= x as u64;
        h = h.wrapping_mul(1099511628211);
    }
    auk_hash_int(h as i64)
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_hash_int(x: i64) -> u64 {
    let mut z = (x as u64).wrapping_add(0x9e3779b97f4a7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
    z ^ (z >> 31)
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_hash_combine(h: u64, x: u64) -> u64 {
    auk_hash_int(h.wrapping_mul(31).wrapping_add(x) as i64)
}

// ---- scalar element ops ------------------------------------------------------------------

unsafe extern "C" fn int_eq(a: *const c_void, b: *const c_void) -> bool {
    unsafe { *(a as *const i64) == *(b as *const i64) }
}
unsafe extern "C" fn int_cmp(a: *const c_void, b: *const c_void) -> c_int {
    unsafe { auk_int_cmp(*(a as *const i64), *(b as *const i64)) }
}
unsafe extern "C" fn int_hash(a: *const c_void) -> u64 {
    unsafe { auk_hash_int(*(a as *const i64)) }
}
unsafe extern "C" fn int_show(a: *const c_void) -> *mut AukStr {
    unsafe { crate::str::auk_str_from_int(*(a as *const i64)) }
}
#[unsafe(no_mangle)]
pub static auk_ops_int: AukElemOps = AukElemOps {
    size: 8,
    retain: None,
    release: None,
    eq: Some(int_eq),
    cmp: Some(int_cmp),
    hash: Some(int_hash),
    show: Some(int_show),    copy: None,
};

unsafe extern "C" fn float_eq(a: *const c_void, b: *const c_void) -> bool {
    unsafe { *(a as *const f64) == *(b as *const f64) }
}
unsafe extern "C" fn float_cmp(a: *const c_void, b: *const c_void) -> c_int {
    unsafe { auk_float_cmp(*(a as *const f64), *(b as *const f64)) }
}
unsafe extern "C" fn float_hash(a: *const c_void) -> u64 {
    let mut d = unsafe { *(a as *const f64) };
    if d == 0.0 {
        d = 0.0; // -0.0 == 0.0
    }
    auk_hash_int(d.to_bits() as i64)
}
unsafe extern "C" fn float_show(a: *const c_void) -> *mut AukStr {
    unsafe { crate::str::auk_str_from_float(*(a as *const f64)) }
}
#[unsafe(no_mangle)]
pub static auk_ops_float: AukElemOps = AukElemOps {
    size: 8,
    retain: None,
    release: None,
    eq: Some(float_eq),
    cmp: Some(float_cmp),
    hash: Some(float_hash),
    show: Some(float_show),    copy: None,
};

unsafe extern "C" fn bool_eq(a: *const c_void, b: *const c_void) -> bool {
    unsafe { *(a as *const bool) == *(b as *const bool) }
}
unsafe extern "C" fn bool_cmp(a: *const c_void, b: *const c_void) -> c_int {
    unsafe { *(a as *const bool) as c_int - *(b as *const bool) as c_int }
}
unsafe extern "C" fn bool_hash(a: *const c_void) -> u64 {
    unsafe { auk_hash_int(*(a as *const bool) as i64) }
}
unsafe extern "C" fn bool_show(a: *const c_void) -> *mut AukStr {
    unsafe { crate::str::auk_str_from_bool(*(a as *const bool)) }
}
#[unsafe(no_mangle)]
pub static auk_ops_bool: AukElemOps = AukElemOps {
    size: 1,
    retain: None,
    release: None,
    eq: Some(bool_eq),
    cmp: Some(bool_cmp),
    hash: Some(bool_hash),
    show: Some(bool_show),    copy: None,
};

unsafe extern "C" fn char_eq(a: *const c_void, b: *const c_void) -> bool {
    unsafe { *(a as *const u32) == *(b as *const u32) }
}
unsafe extern "C" fn char_cmp(a: *const c_void, b: *const c_void) -> c_int {
    let (x, y) = unsafe { (*(a as *const u32), *(b as *const u32)) };
    (x > y) as c_int - (x < y) as c_int
}
unsafe extern "C" fn char_hash(a: *const c_void) -> u64 {
    unsafe { auk_hash_int(*(a as *const u32) as i64) }
}
unsafe extern "C" fn char_show(a: *const c_void) -> *mut AukStr {
    unsafe { crate::str::auk_char_quote(*(a as *const u32)) }
}
#[unsafe(no_mangle)]
pub static auk_ops_char: AukElemOps = AukElemOps {
    size: 4,
    retain: None,
    release: None,
    eq: Some(char_eq),
    cmp: Some(char_cmp),
    hash: Some(char_hash),
    show: Some(char_show),    copy: None,
};

unsafe extern "C" fn unit_eq(_: *const c_void, _: *const c_void) -> bool {
    true
}
unsafe extern "C" fn unit_cmp(_: *const c_void, _: *const c_void) -> c_int {
    0
}
unsafe extern "C" fn unit_hash(_: *const c_void) -> u64 {
    0
}
unsafe extern "C" fn unit_show(_: *const c_void) -> *mut AukStr {
    unsafe { crate::str::auk_str_lit(c"()".as_ptr()) }
}
#[unsafe(no_mangle)]
pub static auk_ops_unit: AukElemOps = AukElemOps {
    size: 1,
    retain: None,
    release: None,
    eq: Some(unit_eq),
    cmp: Some(unit_cmp),
    hash: Some(unit_hash),
    show: Some(unit_show),    copy: None,
};

pub unsafe extern "C" fn ptr_retain(p: *mut c_void) {
    unsafe { auk_retain(*(p as *mut *mut c_void)) };
}
pub unsafe extern "C" fn ptr_release(p: *mut c_void) {
    unsafe { auk_release(*(p as *mut *mut c_void)) }
}

unsafe extern "C" fn str_eq(a: *const c_void, b: *const c_void) -> bool {
    unsafe { crate::str::auk_str_eq(*(a as *const *const AukStr), *(b as *const *const AukStr)) }
}
unsafe extern "C" fn str_cmp(a: *const c_void, b: *const c_void) -> c_int {
    unsafe { crate::str::auk_str_cmp(*(a as *const *const AukStr), *(b as *const *const AukStr)) }
}
unsafe extern "C" fn str_hash(a: *const c_void) -> u64 {
    unsafe { crate::str::auk_str_hash(*(a as *const *const AukStr)) }
}
unsafe extern "C" fn str_show(a: *const c_void) -> *mut AukStr {
    unsafe { crate::str::auk_str_quote(*(a as *const *const AukStr)) }
}
#[unsafe(no_mangle)]
pub static auk_ops_str: AukElemOps = AukElemOps {
    size: 8,
    retain: Some(ptr_retain),
    release: Some(ptr_release),
    eq: Some(str_eq),
    cmp: Some(str_cmp),
    hash: Some(str_hash),
    show: Some(str_show),    copy: Some(crate::copy::str_copy_elem),
};

unsafe extern "C" fn arr_eq(a: *const c_void, b: *const c_void) -> bool {
    unsafe { crate::arr::auk_arr_eq(*(a as *const *const AukArr), *(b as *const *const AukArr)) }
}
unsafe extern "C" fn arr_cmp(a: *const c_void, b: *const c_void) -> c_int {
    unsafe { crate::arr::auk_arr_cmp(*(a as *const *const AukArr), *(b as *const *const AukArr)) }
}
unsafe extern "C" fn arr_hash(a: *const c_void) -> u64 {
    unsafe { crate::arr::auk_arr_hash(*(a as *const *const AukArr)) }
}
unsafe extern "C" fn arr_show(a: *const c_void) -> *mut AukStr {
    unsafe { crate::arr::auk_arr_show(*(a as *const *const AukArr)) }
}
#[unsafe(no_mangle)]
pub static auk_ops_arr: AukElemOps = AukElemOps {
    size: 8,
    retain: Some(ptr_retain),
    release: Some(ptr_release),
    eq: Some(arr_eq),
    cmp: Some(arr_cmp),
    hash: Some(arr_hash),
    show: Some(arr_show),    copy: Some(crate::copy::arr_copy_elem),
};

unsafe extern "C" fn map_eq(a: *const c_void, b: *const c_void) -> bool {
    unsafe { crate::map::auk_map_eq(*(a as *const *const AukMap), *(b as *const *const AukMap)) }
}
unsafe extern "C" fn map_show(a: *const c_void) -> *mut AukStr {
    unsafe { crate::map::auk_map_show(*(a as *const *const AukMap)) }
}
#[unsafe(no_mangle)]
pub static auk_ops_map: AukElemOps = AukElemOps {
    size: 8,
    retain: Some(ptr_retain),
    release: Some(ptr_release),
    eq: Some(map_eq),
    cmp: None,
    hash: None,
    show: Some(map_show),    copy: Some(crate::copy::map_copy_elem),
};

unsafe extern "C" fn err_show(a: *const c_void) -> *mut AukStr {
    unsafe { crate::err::auk_err_show(*(a as *const *const AukErr)) }
}
#[unsafe(no_mangle)]
pub static auk_ops_err: AukElemOps = AukElemOps {
    size: 8,
    retain: Some(ptr_retain),
    release: Some(ptr_release),
    eq: None,
    cmp: None,
    hash: None,
    show: Some(err_show),    copy: Some(crate::copy::err_copy_elem),
};

#[unsafe(no_mangle)]
pub static auk_ops_obj: AukElemOps = AukElemOps {
    size: 8,
    retain: Some(ptr_retain),
    release: Some(ptr_release),
    eq: None,
    cmp: None,
    hash: None,
    show: None,    copy: Some(crate::copy::obj_copy_elem),
};
#[unsafe(no_mangle)]
pub static auk_ops_task: AukElemOps = AukElemOps {
    size: 8,
    retain: Some(ptr_retain),
    release: Some(ptr_release),
    eq: None,
    cmp: None,
    hash: None,
    show: None,    copy: Some(crate::copy::handle_copy_elem),
};

unsafe extern "C" fn closure_retain(p: *mut c_void) {
    unsafe { auk_retain((*(p as *mut AukClosure)).env.cast()) };
}
unsafe extern "C" fn closure_release(p: *mut c_void) {
    unsafe { auk_release((*(p as *mut AukClosure)).env.cast()) }
}
#[unsafe(no_mangle)]
pub static auk_ops_closure: AukElemOps = AukElemOps {
    size: 16,
    retain: Some(closure_retain),
    release: Some(closure_release),
    eq: None,
    cmp: None,
    hash: None,
    show: None,    copy: Some(crate::copy::closure_copy_elem),
};

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_closure_retain(c: AukClosure) {
    unsafe { auk_retain(c.env.cast()) };
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_closure_release(c: AukClosure) {
    unsafe { auk_release(c.env.cast()) }
}

// `AukElemOps` holds only fn pointers and a size; sharing it across threads is fine.
unsafe impl Sync for AukElemOps {}
