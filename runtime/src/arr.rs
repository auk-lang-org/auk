//! `[T]`: inline-element arrays with copy-on-write and O(1) slice views (was arr.c).

use std::ffi::{c_char, c_int, c_void};
use std::ptr::{self, null, null_mut};

use crate::rc::{duck__alloc, duck__free_obj, duck__xmalloc, duck__xrealloc, duck_refcount, duck_release, duck_retain};
use crate::*;

/// `ELEM(a, i)`: address of element i.
#[inline]
unsafe fn elem(a: *const DuckArr, i: i64) -> *mut u8 {
    unsafe { (*a).data.add(i as usize * (*(*a).ops).size) }
}

#[inline]
unsafe fn retain_elem(ops: *const DuckElemOps, e: *mut c_void) {
    unsafe {
        if let Some(r) = (*ops).retain {
            r(e)
        }
    }
}
#[inline]
unsafe fn release_elem(ops: *const DuckElemOps, e: *mut c_void) {
    unsafe {
        if let Some(r) = (*ops).release {
            r(e)
        }
    }
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

// Accessors (once `static inline` in C), exported for the Cranelift backend.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_len(a: *const DuckArr) -> i64 {
    if a.is_null() { 0 } else { unsafe { (*a).len } }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_data(a: *const DuckArr) -> *const c_void {
    if a.is_null() { null() } else { unsafe { (*a).data as *const c_void } }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_new(ops: *const DuckElemOps, cap: i64) -> *mut DuckArr {
    if ops.is_null() {
        panic_msg_rt("duck_arr_new: missing element ops");
    }
    unsafe {
        let a = duck__alloc(size_of::<DuckArr>(), DUCK_K_ARR) as *mut DuckArr;
        (*a).ops = ops;
        (*a).cap = if cap > 0 { cap } else { 0 };
        (*a).data = if (*a).cap != 0 { duck__xmalloc((*a).cap as usize * (*ops).size) as *mut u8 } else { null_mut() };
        a
    }
}

fn panic_msg_rt(msg: &str) -> ! {
    crate::rc::panic_msg(c"runtime".as_ptr(), msg)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_from(ops: *const DuckElemOps, elems: *const c_void, n: i64) -> *mut DuckArr {
    unsafe {
        let a = duck_arr_new(ops, n);
        if n != 0 {
            ptr::copy_nonoverlapping(elems as *const u8, (*a).data, n as usize * (*ops).size);
        }
        (*a).len = n;
        if let Some(r) = (*ops).retain {
            for i in 0..n {
                r(elem(a, i).cast());
            }
        }
        a
    }
}

pub unsafe fn duck__arr_free(a: *mut DuckArr) {
    unsafe {
        if !(*a).base.is_null() {
            duck_release((*a).base.cast());
        } else {
            if let Some(r) = (*(*a).ops).release {
                for i in 0..(*a).len {
                    r(elem(a, i).cast());
                }
            }
            libc::free((*a).data.cast());
        }
        duck__free_obj(a.cast());
    }
}

fn oob(loc: *const c_char, i: i64, len: i64) -> ! {
    rt_panic!(loc, "index {} out of range for length {}", i, len)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_at(a: *const DuckArr, i: i64, loc: *const c_char) -> *mut c_void {
    unsafe {
        let n = duck_arr_len(a);
        if i < 0 || i >= n {
            oob(loc, i, n);
        }
        elem(a, i).cast()
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_get_opt(a: *const DuckArr, i: i64, out: *mut c_void) -> bool {
    unsafe {
        if i < 0 || i >= duck_arr_len(a) {
            return false;
        }
        ptr::copy_nonoverlapping(elem(a, i), out as *mut u8, (*(*a).ops).size);
        retain_elem((*a).ops, out);
        true
    }
}

/// A fresh owner copy of a with capacity >= cap.
unsafe fn copy_with_cap(a: *const DuckArr, mut cap: i64) -> *mut DuckArr {
    unsafe {
        if cap < (*a).len {
            cap = (*a).len;
        }
        let c = duck_arr_new((*a).ops, cap);
        if (*a).len != 0 {
            ptr::copy_nonoverlapping((*a).data, (*c).data, (*a).len as usize * (*(*a).ops).size);
        }
        (*c).len = (*a).len;
        if let Some(r) = (*(*a).ops).retain {
            for i in 0..(*c).len {
                r(elem(c, i).cast());
            }
        }
        c
    }
}

unsafe fn is_unique(a: *const DuckArr) -> bool {
    unsafe { (*a).base.is_null() && duck_refcount(a.cast()) == 1 }
}

unsafe fn ensure_unique_cap(pa: *mut *mut DuckArr, need: i64) {
    unsafe {
        let a = *pa;
        if a.is_null() {
            panic_msg_rt("mutating a NULL array");
        }
        if !is_unique(a) {
            let cap = if need > (*a).len { need } else { (*a).len };
            let c = copy_with_cap(a, cap);
            duck_release(a.cast());
            *pa = c;
            return;
        }
        if need > (*a).cap {
            let mut cap = if (*a).cap != 0 { (*a).cap * 2 } else { 4 };
            while cap < need {
                cap *= 2;
            }
            (*a).data = duck__xrealloc((*a).data.cast(), cap as usize * (*(*a).ops).size) as *mut u8;
            (*a).cap = cap;
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_make_unique(pa: *mut *mut DuckArr) -> *mut c_void {
    unsafe {
        ensure_unique_cap(pa, (**pa).len);
        (**pa).data.cast()
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_set(pa: *mut *mut DuckArr, i: i64, e: *const c_void, loc: *const c_char) {
    unsafe {
        let n = duck_arr_len(*pa);
        if i < 0 || i >= n {
            oob(loc, i, n);
        }
        let sz = (*(**pa).ops).size;
        // copy + retain the new value first: e may point into *pa
        let mut tmp = Tmp::new(sz);
        let t = tmp.ptr();
        ptr::copy_nonoverlapping(e as *const u8, t, sz);
        retain_elem((**pa).ops, t.cast());
        ensure_unique_cap(pa, n);
        let a = *pa;
        release_elem((*a).ops, elem(a, i).cast());
        ptr::copy_nonoverlapping(t, elem(a, i), sz);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_push(pa: *mut *mut DuckArr, e: *const c_void) {
    unsafe {
        let mut a = *pa;
        let sz = (*(*a).ops).size;
        // e may point into *pa itself; copy before a possible realloc/COW
        let mut tmp = Tmp::new(sz);
        let t = tmp.ptr();
        ptr::copy_nonoverlapping(e as *const u8, t, sz);
        retain_elem((*a).ops, t.cast());
        ensure_unique_cap(pa, (*a).len + 1);
        a = *pa;
        ptr::copy_nonoverlapping(t, elem(a, (*a).len), sz);
        (*a).len += 1;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_pop(pa: *mut *mut DuckArr, out: *mut c_void) -> bool {
    unsafe {
        if duck_arr_len(*pa) == 0 {
            return false;
        }
        ensure_unique_cap(pa, (**pa).len);
        let a = *pa;
        (*a).len -= 1;
        if !out.is_null() {
            ptr::copy_nonoverlapping(elem(a, (*a).len), out as *mut u8, (*(*a).ops).size);
        } else {
            release_elem((*a).ops, elem(a, (*a).len).cast());
        }
        true
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_insert(pa: *mut *mut DuckArr, i: i64, e: *const c_void, loc: *const c_char) {
    unsafe {
        let n = duck_arr_len(*pa);
        if i < 0 || i > n {
            oob(loc, i, n);
        }
        let sz = (*(**pa).ops).size;
        let mut tmp = Tmp::new(sz);
        let t = tmp.ptr();
        ptr::copy_nonoverlapping(e as *const u8, t, sz);
        retain_elem((**pa).ops, t.cast());
        ensure_unique_cap(pa, n + 1);
        let a = *pa;
        ptr::copy(elem(a, i), elem(a, i + 1), (n - i) as usize * sz);
        ptr::copy_nonoverlapping(t, elem(a, i), sz);
        (*a).len += 1;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_remove(pa: *mut *mut DuckArr, i: i64, out: *mut c_void, loc: *const c_char) {
    unsafe {
        let n = duck_arr_len(*pa);
        if i < 0 || i >= n {
            oob(loc, i, n);
        }
        ensure_unique_cap(pa, n);
        let a = *pa;
        let sz = (*(*a).ops).size;
        if !out.is_null() {
            ptr::copy_nonoverlapping(elem(a, i), out as *mut u8, sz);
        } else {
            release_elem((*a).ops, elem(a, i).cast());
        }
        ptr::copy(elem(a, i + 1), elem(a, i), (n - i - 1) as usize * sz);
        (*a).len -= 1;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_clear(pa: *mut *mut DuckArr) {
    unsafe {
        let a = *pa;
        if !is_unique(a) {
            *pa = duck_arr_new((*a).ops, 0);
            duck_release(a.cast());
            return;
        }
        if let Some(r) = (*(*a).ops).release {
            for i in 0..(*a).len {
                r(elem(a, i).cast());
            }
        }
        (*a).len = 0;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_slice(a: *mut DuckArr, lo: i64, hi: i64, loc: *const c_char) -> *mut DuckArr {
    unsafe {
        let n = duck_arr_len(a);
        if lo < 0 || hi < lo || hi > n {
            rt_panic!(loc, "slice {}..{} out of range for length {}", lo, hi, n);
        }
        if lo == 0 && hi == n {
            return duck_retain(a.cast()).cast();
        }
        let root = if !(*a).base.is_null() { (*a).base } else { a };
        let v = duck__alloc(size_of::<DuckArr>(), DUCK_K_ARR) as *mut DuckArr;
        (*v).ops = (*a).ops;
        (*v).base = duck_retain(root.cast()).cast();
        (*v).data = elem(a, lo);
        (*v).len = hi - lo;
        (*v).cap = (*v).len;
        v
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_take(a: *mut DuckArr, mut n: i64) -> *mut DuckArr {
    unsafe {
        let len = duck_arr_len(a);
        if n < 0 {
            n = 0;
        }
        duck_arr_slice(a, 0, if n < len { n } else { len }, null())
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_skip(a: *mut DuckArr, mut n: i64) -> *mut DuckArr {
    unsafe {
        let len = duck_arr_len(a);
        if n < 0 {
            n = 0;
        }
        duck_arr_slice(a, if n < len { n } else { len }, len, null())
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_copy(a: *const DuckArr) -> *mut DuckArr {
    unsafe { copy_with_cap(a, (*a).len) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_concat(a: *const DuckArr, b: *const DuckArr) -> *mut DuckArr {
    unsafe {
        let mut c = copy_with_cap(a, (*a).len + duck_arr_len(b));
        duck_arr_extend(&mut c, b);
        c
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_extend(pa: *mut *mut DuckArr, b: *const DuckArr) {
    unsafe {
        let bn = duck_arr_len(b);
        if bn == 0 {
            return;
        }
        let keep = duck_retain(b as *mut c_void); // b may be *pa
        ensure_unique_cap(pa, (**pa).len + bn);
        let a = *pa;
        ptr::copy_nonoverlapping((*b).data, elem(a, (*a).len), bn as usize * (*(*a).ops).size);
        if let Some(r) = (*(*a).ops).retain {
            for i in (*a).len..(*a).len + bn {
                r(elem(a, i).cast());
            }
        }
        (*a).len += bn;
        duck_release(keep);
    }
}

unsafe fn reverse_in_place(a: *mut DuckArr) {
    unsafe {
        let sz = (*(*a).ops).size;
        let mut tmp = Tmp::new(sz);
        let t = tmp.ptr();
        let (mut i, mut j) = (0i64, (*a).len - 1);
        while i < j {
            ptr::copy_nonoverlapping(elem(a, i), t, sz);
            ptr::copy_nonoverlapping(elem(a, j), elem(a, i), sz);
            ptr::copy_nonoverlapping(t, elem(a, j), sz);
            i += 1;
            j -= 1;
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_reversed(a: *const DuckArr) -> *mut DuckArr {
    unsafe {
        let c = duck_arr_copy(a);
        reverse_in_place(c);
        c
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_reverse(pa: *mut *mut DuckArr) {
    unsafe {
        duck_arr_make_unique(pa);
        reverse_in_place(*pa);
    }
}

// ---- stable merge sort ------------------------------------------------------------------

/// `int (*cmp)(const void *a, const void *b, void *ctx)`
pub type SortCmpFn = unsafe extern "C" fn(*const c_void, *const c_void, *mut c_void) -> c_int;

struct SortCtx {
    cmp: SortCmpFn,
    ctx: *mut c_void,
    sz: usize,
}

unsafe fn merge_sort(d: *mut u8, tmp: *mut u8, n: i64, c: &SortCtx) {
    unsafe {
        let sz = c.sz;
        let at = |p: *mut u8, i: i64| p.add(i as usize * sz);
        let cmp = |x: *const u8, y: *const u8| (c.cmp)(x.cast(), y.cast(), c.ctx);
        if n < 2 {
            return;
        }
        if n <= 8 {
            // insertion sort
            for i in 1..n {
                ptr::copy_nonoverlapping(at(d, i), tmp, sz);
                let mut j = i;
                while j > 0 && cmp(at(d, j - 1), tmp) > 0 {
                    ptr::copy_nonoverlapping(at(d, j - 1), at(d, j), sz);
                    j -= 1;
                }
                ptr::copy_nonoverlapping(tmp, at(d, j), sz);
            }
            return;
        }
        let m = n / 2;
        merge_sort(d, tmp, m, c);
        merge_sort(at(d, m), tmp, n - m, c);
        if cmp(at(d, m - 1), at(d, m)) <= 0 {
            return;
        }
        ptr::copy_nonoverlapping(d, tmp, n as usize * sz);
        let (mut i, mut j, mut k) = (0i64, m, 0i64);
        while i < m && j < n {
            if cmp(at(tmp, j), at(tmp, i)) < 0 {
                ptr::copy_nonoverlapping(at(tmp, j), at(d, k), sz);
                j += 1;
            } else {
                ptr::copy_nonoverlapping(at(tmp, i), at(d, k), sz);
                i += 1;
            }
            k += 1;
        }
        if i < m {
            ptr::copy_nonoverlapping(at(tmp, i), at(d, k), (m - i) as usize * sz);
        }
        if j < n {
            ptr::copy_nonoverlapping(at(tmp, j), at(d, k), (n - j) as usize * sz);
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_sort_with(pa: *mut *mut DuckArr, cmp: SortCmpFn, ctx: *mut c_void) {
    unsafe {
        duck_arr_make_unique(pa);
        let a = *pa;
        if (*a).len < 2 {
            return;
        }
        let c = SortCtx { cmp, ctx, sz: (*(*a).ops).size };
        let tmp = duck__xmalloc((*a).len as usize * c.sz) as *mut u8;
        merge_sort((*a).data, tmp, (*a).len, &c);
        libc::free(tmp.cast());
    }
}

unsafe extern "C" fn ops_cmp(x: *const c_void, y: *const c_void, ctx: *mut c_void) -> c_int {
    unsafe { ((*(ctx as *const DuckElemOps)).cmp.unwrap_unchecked())(x, y) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_sort(pa: *mut *mut DuckArr) {
    unsafe {
        let ops = (**pa).ops;
        if (*ops).cmp.is_none() {
            panic_msg_rt("sort: element type has no cmp");
        }
        duck_arr_sort_with(pa, ops_cmp, ops as *mut c_void);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_sorted(a: *const DuckArr) -> *mut DuckArr {
    unsafe {
        let mut c = duck_arr_copy(a);
        duck_arr_sort(&mut c);
        c
    }
}

// ---- queries ----------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_index_of(a: *const DuckArr, e: *const c_void) -> DuckOpt_int {
    unsafe {
        for i in 0..duck_arr_len(a) {
            let Some(eq) = (*(*a).ops).eq else { panic_msg_rt("contains: element type has no eq") };
            if eq(elem(a, i).cast(), e) {
                return DuckOpt::some(i);
            }
        }
        DuckOpt::none()
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_contains(a: *const DuckArr, e: *const c_void) -> bool {
    unsafe { duck_arr_index_of(a, e).some }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_eq(a: *const DuckArr, b: *const DuckArr) -> bool {
    unsafe {
        if a == b {
            return true;
        }
        let n = duck_arr_len(a);
        if n != duck_arr_len(b) {
            return false;
        }
        for i in 0..n {
            let eq = (*(*a).ops).eq.expect("element type has no eq");
            if !eq(elem(a, i).cast(), elem(b, i).cast()) {
                return false;
            }
        }
        true
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_cmp(a: *const DuckArr, b: *const DuckArr) -> c_int {
    unsafe {
        let (na, nb) = (duck_arr_len(a), duck_arr_len(b));
        let mut i = 0;
        while i < na && i < nb {
            let cmp = (*(*a).ops).cmp.expect("element type has no cmp");
            let c = cmp(elem(a, i).cast(), elem(b, i).cast());
            if c != 0 {
                return if c < 0 { -1 } else { 1 };
            }
            i += 1;
        }
        (na > nb) as c_int - (na < nb) as c_int
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_hash(a: *const DuckArr) -> u64 {
    unsafe {
        let mut h: u64 = 0x1234;
        for i in 0..duck_arr_len(a) {
            let hash = (*(*a).ops).hash.expect("element type has no hash");
            h = crate::rc::duck_hash_combine(h, hash(elem(a, i).cast()));
        }
        h
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_show(a: *const DuckArr) -> *mut DuckStr {
    use crate::str::{duck_sb_char, duck_sb_finish, duck_sb_lit, duck_sb_str_own};
    unsafe {
        let mut b = DuckStrBuf::INIT;
        duck_sb_char(&mut b, '[' as u32);
        let mut i = 0;
        while i < duck_arr_len(a) && !crate::trace::show_exhausted() {
            if i != 0 {
                duck_sb_lit(&mut b, c", ".as_ptr());
            }
            let Some(show) = (*(*a).ops).show else { panic_msg_rt("show: element type has no show") };
            duck_sb_str_own(&mut b, show(elem(a, i).cast()));
            i += 1;
        }
        duck_sb_char(&mut b, ']' as u32);
        duck_sb_finish(&mut b)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_join(a: *const DuckArr, sep: *const DuckStr) -> *mut DuckStr {
    use crate::str::{duck_sb_char, duck_sb_finish, duck_sb_str, duck_sb_str_own};
    unsafe {
        let mut b = DuckStrBuf::INIT;
        for i in 0..duck_arr_len(a) {
            if i != 0 {
                duck_sb_str(&mut b, sep);
            }
            let ops = (*a).ops;
            if ptr::eq(ops, &crate::rc::duck_ops_str) {
                duck_sb_str(&mut b, *(elem(a, i) as *const *const DuckStr));
            } else if ptr::eq(ops, &crate::rc::duck_ops_char) {
                duck_sb_char(&mut b, *(elem(a, i) as *const u32));
            } else {
                let show = (*ops).show.expect("element type has no show");
                duck_sb_str_own(&mut b, show(elem(a, i).cast()));
            }
        }
        duck_sb_finish(&mut b)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_sum_int(a: *const DuckArr, loc: *const c_char) -> i64 {
    unsafe {
        let mut s: i64 = 0;
        let d = duck_arr_data(a) as *const i64;
        for i in 0..duck_arr_len(a) {
            s = crate::rc::duck_add(s, *d.add(i as usize), loc);
        }
        s
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn duck_arr_sum_float(a: *const DuckArr) -> f64 {
    unsafe {
        let mut s = 0.0;
        let d = duck_arr_data(a) as *const f64;
        for i in 0..duck_arr_len(a) {
            s += *d.add(i as usize);
        }
        s
    }
}
