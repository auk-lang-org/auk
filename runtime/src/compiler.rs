//! Small entry points used only by compiler-generated code: messages that the generated code
//! would otherwise format with varargs, hashing helpers, and the imprint evaluator's protocol
//! (see `src/build.rs`: compile-time evaluation of `imprint` constants).

use std::ffi::{c_char, c_int};
use std::io::Write;
use std::sync::Mutex;

use crate::*;

/// `<prefix><Value tag name>` as a new error (from_value's "expected X for `T`, got Y").
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk__err_with_tag(prefix: *const c_char, tag: c_int) -> *mut AukErr {
    let name = unsafe { cstr(crate::value::auk_value_tag_name(tag as u32)) };
    crate::err::err_msg(&format!("{}{}", unsafe { cstr(prefix) }, name))
}

/// `<a><s><b>` as a new error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk__err_concat(a: *const c_char, s: *const AukStr, b: *const c_char) -> *mut AukErr {
    let mid = String::from_utf8_lossy(unsafe { sbytes(s) }).into_owned();
    let mid = mid.split('\0').next().unwrap_or("").to_string();
    crate::err::err_msg(&format!("{}{}{}", unsafe { cstr(a) }, mid, unsafe { cstr(b) }))
}

/// The hash of a float (as the `float` element ops hash it).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_hash_float(x: f64) -> u64 {
    unsafe { (crate::rc::auk_ops_float.hash.unwrap())((&x as *const f64).cast()) }
}

/// The hash of a `Value` (as the `Value` element ops hash it).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_value_hash(v: *const AukValue) -> u64 {
    unsafe { (crate::value::auk_ops_value.hash.unwrap())(v.cast()) }
}

// ---- the imprint evaluator's records ----
//
// Records go to the file named by the helper's argv[1]: `B<c>\n` / `E<c>\n` when constant `c`
// starts / finishes computing, `C<c>\n` (then exit 3) when it is needed while being computed,
// and `V<c> <value>\n` for each imprint's value: `N`, `T`, `F`, `I<int>;`, `D<16 hex digits: the
// f64 bits>;`, `S<n>:<n bytes>`, `L<n>;<n values>` or `M<n>;<n (S-key, value) pairs>`.

static OUT: Mutex<Option<std::fs::File>> = Mutex::new(None);

fn out<R>(f: impl FnOnce(&mut std::fs::File) -> R) -> Option<R> {
    let mut g = OUT.lock().unwrap_or_else(|e| e.into_inner());
    g.as_mut().map(f)
}

/// Open the records file named by `argv[1]`; false without one.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk__imprint_open(argc: c_int, argv: *const *const c_char) -> bool {
    if argc < 2 {
        return false;
    }
    let p = unsafe { cstr(*argv.add(1)) }.into_owned();
    match std::fs::File::create(p) {
        Ok(f) => {
            *OUT.lock().unwrap_or_else(|e| e.into_inner()) = Some(f);
            true
        }
        Err(_) => false,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn auk__imprint_close() {
    *OUT.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

#[unsafe(no_mangle)]
pub extern "C" fn auk__imprint_mark(tag: c_int, c: i64) {
    out(|f| {
        let _ = writeln!(f, "{}{c}", tag as u8 as char);
        let _ = f.flush();
    });
    if tag as u8 == b'C' {
        unsafe { libc::_exit(3) }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk__imprint_value(c: i64, v: *const AukValue) {
    let mut s = format!("V{c} ").into_bytes();
    unsafe { dump(&*v, &mut s) };
    s.push(b'\n');
    out(|f| {
        let _ = f.write_all(&s);
        let _ = f.flush();
    });
}

unsafe fn dump(v: &AukValue, out: &mut Vec<u8>) {
    unsafe {
        match v.tag {
            AUK_V_NULL => out.push(b'N'),
            AUK_V_BOOL => out.push(if v.u.b { b'T' } else { b'F' }),
            AUK_V_INT => out.extend(format!("I{};", v.u.i).bytes()),
            AUK_V_FLOAT => out.extend(format!("D{:016x};", v.u.f.to_bits()).bytes()),
            AUK_V_STR => {
                let b = sbytes(v.u.s);
                out.extend(format!("S{}:", b.len()).bytes());
                out.extend_from_slice(b);
            }
            AUK_V_LIST => {
                let a = v.u.list;
                let n = if a.is_null() { 0 } else { (*a).len };
                out.extend(format!("L{n};").bytes());
                for i in 0..n {
                    dump(&*((*a).data as *const AukValue).add(i as usize), out);
                }
            }
            AUK_V_MAP => {
                let m = v.u.map;
                let n = if m.is_null() { 0 } else { (*m).len };
                out.extend(format!("M{n};").bytes());
                let mut it = 0i64;
                let (mut kp, mut vp) = (std::ptr::null_mut(), std::ptr::null_mut());
                while crate::map::auk_map_next(m, &mut it, &mut kp, &mut vp) {
                    let k = sbytes(*(kp as *const *const AukStr));
                    out.extend(format!("S{}:", k.len()).bytes());
                    out.extend_from_slice(k);
                    dump(&*(vp as *const AukValue), out);
                }
            }
            _ => {}
        }
    }
}
