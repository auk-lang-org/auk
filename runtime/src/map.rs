//! `{K: V}`: insertion-ordered hash map (index table + entries), copy-on-write (was map.c).

use std::ffi::{CStr, c_char, c_void};
use std::ptr::{self, null_mut};

use crate::rc::{duck__alloc, duck__free_obj, duck__xmalloc, duck__xrealloc, duck_refcount, duck_release};
use crate::*;

/// An index slot: 0 is empty; a removed entry's slot is `TOMB`; any other is
/// `(hash >> 32) << 32 | (entry + 1)`.
const EMPTY: u64 = 0;
pub const TOMB: u64 = u64::MAX;
/// The most entries a map holds (the entry number must fit the slot's low 32 bits).
const MAX_ENTRIES: i64 = u32::MAX as i64 - 2;

#[inline]
fn slot_of(h: u64, e: i64) -> u64 {
    (h & !0xffff_ffff) | (e as u64 + 1)
}
/// The entry a live slot points to.
#[inline]
fn entry_of(x: u64) -> i64 {
    (x as u32) as i64 - 1
}
#[inline]
fn live(x: u64) -> bool {
    x != EMPTY && x != TOMB
}

/// The key of entry `i`.
#[inline]
pub(crate) unsafe fn key(m: *const DuckMap, i: i64) -> *mut u8 {
    unsafe { (*m).entries.add((i * (*m).stride) as usize) }
}
/// The value of entry `i`.
#[inline]
pub(crate) unsafe fn val(m: *const DuckMap, i: i64) -> *mut u8 {
    unsafe { (*m).entries.add((i * (*m).stride + (*m).voff) as usize) }
}

fn panic_rt(msg: &str) -> ! {
    crate::rc::panic_msg(c"runtime".as_ptr(), msg)
}

/// A scratch element buffer: on the stack when it fits in 256 bytes, else malloc'd (like C).
struct Tmp {
    stack: [u8; 256],
    heap: *mut u8,
}
impl Tmp {
    unsafe fn new(sz: usize) -> Tmp {
        let heap = if sz <= 256 { null_mut() } else { unsafe { duck__xmalloc(sz) as *mut u8 } };
        Tmp { stack: [0; 256], heap }
    }
    fn ptr(&mut self) -> *mut u8 {
        if self.heap.is_null() { self.stack.as_mut_ptr() } else { self.heap }
    }
}
impl Drop for Tmp {
    fn drop(&mut self) {
        if !self.heap.is_null() {
            unsafe { libc::free(self.heap.cast()) }
        }
    }
}

// An accessor (once `static inline` in C), exported for the generated code.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_len(m: *const DuckMap) -> i64 {
    if m.is_null() { 0 } else { unsafe { (*m).len } }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_new(kops: *const DuckElemOps, vops: *const DuckElemOps) -> *mut DuckMap {
    unsafe {
        if kops.is_null() || vops.is_null() {
            panic_rt("duck_map_new: missing ops");
        }
        if (*kops).hash.is_none() || (*kops).eq.is_none() {
            panic_rt("duck_map_new: key type needs hash and eq");
        }
        let m = duck__alloc(size_of::<DuckMap>(), DUCK_K_MAP) as *mut DuckMap;
        (*m).kops = kops;
        (*m).vops = vops;
        // every Duck value's alignment is at most 8: the value starts at the key's size rounded up
        let r8 = |n: usize| n.div_ceil(8) as i64 * 8;
        (*m).voff = r8((*kops).size);
        (*m).stride = ((*m).voff + r8((*vops).size)).max(8);
        m
    }
}

pub unsafe fn duck__map_free(m: *mut DuckMap) {
    unsafe {
        for i in 0..(*m).n {
            if *(*m).dead.add(i as usize) {
                continue;
            }
            if let Some(r) = (*(*m).kops).release {
                r(key(m, i).cast());
            }
            if let Some(r) = (*(*m).vops).release {
                r(val(m, i).cast());
            }
        }
        libc::free((*m).entries.cast());
        libc::free((*m).hashes.cast());
        libc::free((*m).dead.cast());
        libc::free((*m).index.cast());
        duck__free_obj(m.cast());
    }
}

unsafe fn rebuild_index(m: *mut DuckMap, icap: i64) {
    unsafe {
        libc::free((*m).index.cast());
        (*m).icap = icap;
        (*m).index = duck__xmalloc(icap as usize * size_of::<u64>()) as *mut u64;
        ptr::write_bytes((*m).index, 0, icap as usize);
        let mask = icap as u64 - 1;
        for e in 0..(*m).n {
            if *(*m).dead.add(e as usize) {
                continue;
            }
            let h = *(*m).hashes.add(e as usize);
            let mut s = h & mask;
            while *(*m).index.add(s as usize) != EMPTY {
                s = (s + 1) & mask;
            }
            *(*m).index.add(s as usize) = slot_of(h, e);
        }
    }
}

/// Drop dead entries (keeps order). The caller rebuilds the index.
unsafe fn compact(m: *mut DuckMap) {
    unsafe {
        let mut k: i64 = 0;
        let stride = (*m).stride as usize;
        for e in 0..(*m).n {
            if *(*m).dead.add(e as usize) {
                continue;
            }
            if k != e {
                ptr::copy_nonoverlapping(key(m, e), key(m, k), stride);
                *(*m).hashes.add(k as usize) = *(*m).hashes.add(e as usize);
                *(*m).dead.add(k as usize) = false;
            }
            k += 1;
        }
        (*m).n = k;
    }
}

unsafe fn set_cap(m: *mut DuckMap, cap: i64) {
    unsafe {
        if cap > MAX_ENTRIES {
            panic_rt("a map can't hold more than 4294967293 entries");
        }
        let cap_u = cap as usize;
        (*m).entries = duck__xrealloc((*m).entries.cast(), cap_u * (*m).stride as usize) as *mut u8;
        (*m).hashes = duck__xrealloc((*m).hashes.cast(), cap_u * size_of::<u64>()) as *mut u64;
        (*m).dead = duck__xrealloc((*m).dead.cast(), cap_u * size_of::<bool>()) as *mut bool;
        (*m).cap = cap;
    }
}

fn icap_for(cap: i64) -> i64 {
    let mut ic: i64 = 8;
    while ic < cap * 2 {
        ic *= 2;
    }
    ic
}

/// Returns the index slot holding key, or -1.
unsafe fn find_slot(m: *const DuckMap, k: *const c_void, h: u64) -> i64 {
    unsafe {
        if m.is_null() || (*m).icap == 0 {
            return -1;
        }
        let mask = (*m).icap as u64 - 1;
        let eq = (*(*m).kops).eq.unwrap_unchecked();
        let fp = h >> 32;
        let mut s = h & mask;
        loop {
            let x = *(*m).index.add(s as usize);
            if x == EMPTY {
                return -1;
            }
            if x != TOMB && x >> 32 == fp && eq(key(m, entry_of(x)).cast(), k) {
                return s as i64;
            }
            s = (s + 1) & mask;
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_find(m: *const DuckMap, k: *const c_void) -> *mut c_void {
    unsafe {
        if m.is_null() {
            return null_mut();
        }
        let s = find_slot(m, k, ((*(*m).kops).hash.unwrap_unchecked())(k));
        if s < 0 { null_mut() } else { val(m, entry_of(*(*m).index.add(s as usize))).cast() }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_at(m: *const DuckMap, k: *const c_void, loc: *const c_char) -> *mut c_void {
    unsafe {
        let v = duck_map_find(m, k);
        if v.is_null() {
            let ks = match if m.is_null() { None } else { (*(*m).kops).show } {
                Some(show) => show(k),
                None => crate::str::duck_str_lit(c"?".as_ptr()),
            };
            // `%s` of duck_str_cstr(k): stops at the first NUL byte.
            let text = if ks.is_null() {
                String::new()
            } else {
                CStr::from_ptr((*ks).data.as_ptr().cast()).to_string_lossy().into_owned()
            };
            rt_panic!(loc, "key not found: {}", text);
        }
        v
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_get_opt(m: *const DuckMap, k: *const c_void, out: *mut c_void) -> bool {
    unsafe {
        let v = duck_map_find(m, k);
        if v.is_null() {
            return false;
        }
        ptr::copy_nonoverlapping(v as *const u8, out as *mut u8, (*(*m).vops).size);
        if let Some(r) = (*(*m).vops).retain {
            r(out);
        }
        true
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_contains(m: *const DuckMap, k: *const c_void) -> bool {
    unsafe { !duck_map_find(m, k).is_null() }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_copy(m: *const DuckMap) -> *mut DuckMap {
    unsafe {
        let c = duck_map_new((*m).kops, (*m).vops);
        if (*m).len != 0 {
            set_cap(c, (*m).len);
            let stride = (*m).stride as usize;
            for e in 0..(*m).n {
                if *(*m).dead.add(e as usize) {
                    continue;
                }
                let k = (*c).n;
                (*c).n += 1;
                ptr::copy_nonoverlapping(key(m, e), key(c, k), stride);
                if let Some(r) = (*(*m).kops).retain {
                    r(key(c, k).cast());
                }
                if let Some(r) = (*(*m).vops).retain {
                    r(val(c, k).cast());
                }
                *(*c).hashes.add(k as usize) = *(*m).hashes.add(e as usize);
                *(*c).dead.add(k as usize) = false;
            }
            (*c).len = (*c).n;
            rebuild_index(c, icap_for((*c).cap));
        }
        c
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_make_unique(pm: *mut *mut DuckMap) -> *mut c_void {
    unsafe {
        let m = *pm;
        if duck_refcount(m.cast()) != 1 {
            *pm = duck_map_copy(m);
            duck_release(m.cast());
        }
        (*pm).cast()
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_set(pm: *mut *mut DuckMap, k_in: *const c_void, v_in: *const c_void) {
    unsafe {
        let m0 = *pm;
        // Hold copies of key/val (retained) before COW: they may live in *pm.
        let (ks, vs) = ((*(*m0).kops).size, (*(*m0).vops).size);
        let mut kt = Tmp::new(ks);
        let mut vt = Tmp::new(vs);
        let k = kt.ptr();
        let v = vt.ptr();
        ptr::copy_nonoverlapping(k_in as *const u8, k, ks);
        ptr::copy_nonoverlapping(v_in as *const u8, v, vs);
        if let Some(r) = (*(*m0).vops).retain {
            r(v.cast());
        }
        duck_map_make_unique(pm);
        let m = *pm;
        let h = ((*(*m).kops).hash.unwrap_unchecked())(k.cast());
        let s = find_slot(m, k.cast(), h);
        if s >= 0 {
            let e = entry_of(*(*m).index.add(s as usize));
            if let Some(r) = (*(*m).vops).release {
                r(val(m, e).cast());
            }
            ptr::copy_nonoverlapping(v, val(m, e), vs);
        } else {
            if let Some(r) = (*(*m).kops).retain {
                r(k.cast());
            }
            if (*m).n == (*m).cap {
                if (*m).n - (*m).len > (*m).len / 2 && (*m).n - (*m).len > 0 {
                    compact(m);
                }
                if (*m).n == (*m).cap {
                    set_cap(m, if (*m).cap != 0 { (*m).cap * 2 } else { 4 });
                }
                rebuild_index(m, icap_for((*m).cap));
            } else if (*m).icap == 0 {
                rebuild_index(m, icap_for((*m).cap));
            }
            let e = (*m).n;
            (*m).n += 1;
            ptr::copy_nonoverlapping(k, key(m, e), ks);
            ptr::copy_nonoverlapping(v, val(m, e), vs);
            *(*m).hashes.add(e as usize) = h;
            *(*m).dead.add(e as usize) = false;
            (*m).len += 1;
            let mask = (*m).icap as u64 - 1;
            let mut slot = h & mask;
            while live(*(*m).index.add(slot as usize)) {
                slot = (slot + 1) & mask;
            }
            *(*m).index.add(slot as usize) = slot_of(h, e);
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_remove(pm: *mut *mut DuckMap, k_in: *const c_void, out: *mut c_void) -> bool {
    unsafe {
        if !duck_map_contains(*pm, k_in) {
            return false;
        }
        let ks = (*(**pm).kops).size;
        let mut kt = Tmp::new(ks);
        let k = kt.ptr();
        ptr::copy_nonoverlapping(k_in as *const u8, k, ks);
        if let Some(r) = (*(**pm).kops).retain {
            r(k.cast());
        }
        duck_map_make_unique(pm);
        let m = *pm;
        let s = find_slot(m, k.cast(), ((*(*m).kops).hash.unwrap_unchecked())(k.cast()));
        let e = entry_of(*(*m).index.add(s as usize));
        *(*m).index.add(s as usize) = TOMB;
        *(*m).dead.add(e as usize) = true;
        (*m).len -= 1;
        if let Some(r) = (*(*m).kops).release {
            r(key(m, e).cast());
        }
        if !out.is_null() {
            ptr::copy_nonoverlapping(val(m, e), out as *mut u8, (*(*m).vops).size);
        } else if let Some(r) = (*(*m).vops).release {
            r(val(m, e).cast());
        }
        if (*m).n - (*m).len > 16 && (*m).n - (*m).len > (*m).len {
            compact(m);
            rebuild_index(m, icap_for((*m).cap));
        }
        if let Some(r) = (*(*m).kops).release {
            r(k.cast());
        }
        true
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_next(
    m: *const DuckMap,
    it: *mut i64,
    k: *mut *mut c_void,
    v: *mut *mut c_void,
) -> bool {
    unsafe {
        if m.is_null() {
            return false;
        }
        while *it < (*m).n {
            let e = *it;
            *it += 1;
            if *(*m).dead.add(e as usize) {
                continue;
            }
            if !k.is_null() {
                *k = key(m, e).cast();
            }
            if !v.is_null() {
                *v = val(m, e).cast();
            }
            return true;
        }
        false
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_keys(m: *const DuckMap) -> *mut DuckArr {
    unsafe {
        let mut a = crate::arr::duck_arr_new((*m).kops, (*m).len);
        let mut it: i64 = 0;
        let mut k: *mut c_void = null_mut();
        while duck_map_next(m, &mut it, &mut k, null_mut()) {
            crate::arr::duck_arr_push(&mut a, k);
        }
        a
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_values(m: *const DuckMap) -> *mut DuckArr {
    unsafe {
        let mut a = crate::arr::duck_arr_new((*m).vops, (*m).len);
        let mut it: i64 = 0;
        let mut v: *mut c_void = null_mut();
        while duck_map_next(m, &mut it, null_mut(), &mut v) {
            crate::arr::duck_arr_push(&mut a, v);
        }
        a
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_eq(a: *const DuckMap, b: *const DuckMap) -> bool {
    unsafe {
        if a == b {
            return true;
        }
        if duck_map_len(a) != duck_map_len(b) {
            return false;
        }
        if a.is_null() || b.is_null() {
            return true; // both empty
        }
        let mut it: i64 = 0;
        let mut k: *mut c_void = null_mut();
        let mut v: *mut c_void = null_mut();
        while duck_map_next(a, &mut it, &mut k, &mut v) {
            let w = duck_map_find(b, k);
            if w.is_null() {
                return false;
            }
            match (*(*a).vops).eq {
                Some(eq) if eq(v, w) => {}
                _ => return false,
            }
        }
        true
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_map_show(m: *const DuckMap) -> *mut DuckStr {
    use crate::str::{duck_sb_char, duck_sb_finish, duck_sb_lit, duck_sb_str_own};
    unsafe {
        let mut b = DuckStrBuf::INIT;
        duck_sb_char(&mut b, '{' as u32);
        let mut it: i64 = 0;
        let mut k: *mut c_void = null_mut();
        let mut v: *mut c_void = null_mut();
        let mut first = true;
        while !crate::trace::show_exhausted() && duck_map_next(m, &mut it, &mut k, &mut v) {
            if !first {
                duck_sb_lit(&mut b, c", ".as_ptr());
            }
            first = false;
            let kshow = (*(*m).kops).show.expect("key type has no show");
            duck_sb_str_own(&mut b, kshow(k));
            duck_sb_lit(&mut b, c": ".as_ptr());
            let vshow = (*(*m).vops).show.expect("value type has no show");
            duck_sb_str_own(&mut b, vshow(v));
        }
        duck_sb_char(&mut b, '}' as u32);
        duck_sb_finish(&mut b)
    }
}
