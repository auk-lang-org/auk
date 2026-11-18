//! [T]: element lifetimes, copy-on-write, slices, sorting.
mod common;

use std::ffi::{c_int, c_void};
use std::ptr::null_mut;

use common::*;
use auk_rt::arr::*;
use auk_rt::rc::*;
use auk_rt::*;

fn vp<T>(x: &T) -> *const c_void {
    (x as *const T).cast()
}
fn op<T>(x: &mut T) -> *mut c_void {
    (x as *mut T).cast()
}

#[test]
fn arr_basic_ops() {
    run(|| unsafe {
        let mut a = auk_arr_new(&auk_ops_int, 0);
        for i in 0i64..100 {
            auk_arr_push(&mut a, vp(&i));
        }
        assert_eq!(auk_arr_len(a), 100);
        assert_eq!(at::<i64>(a, 99), 99);
        let mut out: i64 = -1;
        assert!(auk_arr_pop(&mut a, op(&mut out)) && out == 99);
        assert_eq!(auk_arr_len(a), 99);
        let mut v: i64 = 1000;
        auk_arr_insert(&mut a, 0, vp(&v), c"t".as_ptr());
        assert_eq!(at::<i64>(a, 0), 1000);
        assert_eq!(at::<i64>(a, 1), 0);
        v = 2000;
        auk_arr_insert(&mut a, auk_arr_len(a), vp(&v), c"t".as_ptr());
        assert_eq!(at::<i64>(a, 100), 2000);
        auk_arr_remove(&mut a, 0, op(&mut out), c"t".as_ptr());
        assert_eq!(out, 1000);
        assert_eq!(at::<i64>(a, 0), 0);
        v = -5;
        auk_arr_set(&mut a, 3, vp(&v), c"t".as_ptr());
        assert_eq!(at::<i64>(a, 3), -5);
        assert!(auk_arr_get_opt(a, 3, op(&mut out)) && out == -5);
        assert!(!auk_arr_get_opt(a, 101, op(&mut out)));
        assert!(!auk_arr_get_opt(a, -1, op(&mut out)));
        auk_arr_clear(&mut a);
        assert_eq!(auk_arr_len(a), 0);
        assert!(!auk_arr_pop(&mut a, op(&mut out)));
        rel(a);
    });
}

#[test]
fn arr_bounds_panics() {
    run(|| unsafe {
        let a = ints(&[1, 2, 3]);
        expect_panic(
            || {
                auk_arr_at(a, 3, c"list.auk:9:5".as_ptr());
            },
            "index 3 out of range for length 3\n  at list.auk:9:5",
        );
        expect_panic(
            || {
                let mut a = a;
                let v: i64 = 1;
                auk_arr_set(&mut a, -1, vp(&v), c"list.auk:10:5".as_ptr());
            },
            "index -1 out of range for length 3",
        );
        expect_panic(
            || {
                let mut a = a;
                auk_arr_remove(&mut a, 7, null_mut(), c"x".as_ptr());
            },
            "index 7 out of range",
        );
        expect_panic(
            || {
                auk_arr_slice(a, 1, 4, c"x".as_ptr());
            },
            "slice 1..4 out of range for length 3",
        );
        rel(a);
    });
}

#[test]
fn arr_str_elements_lifetimes() {
    run(|| unsafe {
        let mut a = auk_arr_new(&auk_ops_str, 0);
        let s = s("shared");
        for _ in 0..10 {
            auk_arr_push(&mut a, vp(&s));
        }
        assert_eq!(auk_refcount(s.cast()), 11);
        let t = common::s("other");
        auk_arr_set(&mut a, 0, vp(&t), c"t".as_ptr());
        assert_eq!(auk_refcount(s.cast()), 10);
        assert_eq!(auk_refcount(t.cast()), 2);
        // setting an element to itself
        auk_arr_set(&mut a, 0, auk_arr_at(a, 0, c"t".as_ptr()), c"t".as_ptr());
        assert_eq!(auk_refcount(t.cast()), 2);
        // push an element of the same array (may realloc)
        auk_arr_push(&mut a, auk_arr_at(a, 0, c"t".as_ptr()));
        assert_eq!(auk_refcount(t.cast()), 3);
        let mut popped: *mut AukStr = null_mut();
        assert!(auk_arr_pop(&mut a, op(&mut popped)) && popped == t);
        rel(popped);
        let mut got: *mut AukStr = null_mut();
        assert!(auk_arr_get_opt(a, 1, op(&mut got)) && got == s);
        assert_eq!(auk_refcount(s.cast()), 11);
        rel(got);
        check_str(
            auk_arr_show(a),
            "[\"other\", \"shared\", \"shared\", \"shared\", \"shared\", \"shared\", \"shared\", \
             \"shared\", \"shared\", \"shared\"]",
        );
        rel(a);
        assert_eq!(auk_refcount(s.cast()), 1);
        assert_eq!(auk_refcount(t.cast()), 1);
        rel(s);
        rel(t);
    });
}

#[test]
fn arr_copy_on_write() {
    run(|| unsafe {
        let a = ints(&[1, 2, 3]);
        let mut b = ret(a); // `let b = a`
        let v: i64 = 99;
        auk_arr_set(&mut b, 0, vp(&v), c"t".as_ptr()); // mutating the shared array copies
        assert!(a != b);
        assert_eq!(at::<i64>(a, 0), 1);
        assert_eq!(at::<i64>(b, 0), 99);
        assert_eq!(auk_refcount(a.cast()), 1);
        let b_before = b;
        auk_arr_push(&mut b, vp(&v)); // unique now: mutates in place (no copy)
        assert!(b == b_before || auk_arr_len(b) == 4);
        assert_eq!(auk_arr_len(a), 3);
        assert_eq!(auk_arr_len(b), 4);
        // push / pop / remove / insert / sort / reverse on a shared array
        let mut c = ret(a);
        auk_arr_push(&mut c, vp(&v));
        auk_arr_reverse(&mut c);
        assert_eq!(at::<i64>(c, 0), 99);
        check_str(auk_arr_show(a), "[1, 2, 3]");
        rel(c);
        c = ret(a);
        auk_arr_remove(&mut c, 0, null_mut(), c"t".as_ptr());
        check_str(auk_arr_show(a), "[1, 2, 3]");
        check_str(auk_arr_show(c), "[2, 3]");
        rel(c);
        c = ret(a);
        auk_arr_clear(&mut c);
        assert_eq!(auk_arr_len(a), 3);
        rel(c);
        rel(a);
        rel(b);
    });
}

#[test]
fn arr_cow_nested_strings() {
    run(|| unsafe {
        // [[str]]: copying the outer array must retain inner arrays
        let mut inner = auk_arr_new(&auk_ops_str, 0);
        let s = s("x");
        auk_arr_push(&mut inner, vp(&s));
        let mut outer = auk_arr_new(&auk_ops_arr, 0);
        auk_arr_push(&mut outer, vp(&inner));
        auk_arr_push(&mut outer, vp(&inner));
        let mut copy = ret(outer);
        auk_arr_pop(&mut copy, null_mut());
        assert_eq!(auk_arr_len(outer), 2);
        assert_eq!(auk_arr_len(copy), 1);
        assert_eq!(auk_refcount(inner.cast()), 4); // our ref + 2 in outer + 1 in copy
        check_str(auk_arr_show(outer), "[[\"x\"], [\"x\"]]");
        // mutate inner via outer[0]: COW of the element
        let slot = auk_arr_make_unique(&mut copy) as *mut *mut AukArr;
        let y = common::s("y");
        auk_arr_push(&mut *slot, vp(&y));
        check_str(auk_arr_show(copy), "[[\"x\", \"y\"]]");
        check_str(auk_arr_show(outer), "[[\"x\"], [\"x\"]]");
        assert!(auk_arr_eq(outer, outer));
        assert!(!auk_arr_eq(outer, copy));
        rel(copy);
        rel(outer);
        rel(inner);
        rel(s);
        rel(y);
    });
}

#[test]
fn arr_slices_share() {
    run(|| unsafe {
        let a = ints(&[0, 1, 2, 3, 4, 5]);
        let mut s = auk_arr_slice(a, 1, 5, c"t".as_ptr());
        assert_eq!(auk_arr_len(s), 4);
        assert!((*s).data == (*a).data.add(size_of::<i64>())); // shares the buffer, O(1)
        assert_eq!(at::<i64>(s, 0), 1);
        let mut ss = auk_arr_slice(s, 1, 3, c"t".as_ptr()); // [h, ..t] of a slice
        assert!((*ss).base == a); // views always point at the owner
        check_str(auk_arr_show(ss), "[2, 3]");
        assert_eq!(auk_refcount(a.cast()), 3);
        // mutating a slice copies; the base is untouched
        let v: i64 = 42;
        auk_arr_set(&mut s, 0, vp(&v), c"t".as_ptr());
        assert!((*s).base.is_null());
        check_str(auk_arr_show(s), "[42, 2, 3, 4]");
        check_str(auk_arr_show(a), "[0, 1, 2, 3, 4, 5]");
        // push on a slice must not clobber the base's next element
        auk_arr_push(&mut ss, vp(&v));
        check_str(auk_arr_show(ss), "[2, 3, 42]");
        check_str(auk_arr_show(a), "[0, 1, 2, 3, 4, 5]");
        // the base stays alive while a view exists
        let tail = auk_arr_slice(a, 4, 6, c"t".as_ptr());
        rel(a);
        check_str(auk_arr_show(tail), "[4, 5]");
        let empty = auk_arr_slice(tail, 2, 2, c"t".as_ptr());
        assert_eq!(auk_arr_len(empty), 0);
        let t2 = auk_arr_take(tail, 10);
        let k2 = auk_arr_skip(tail, 1);
        check_str(auk_arr_show(t2), "[4, 5]");
        check_str(auk_arr_show(k2), "[5]");
        rel(t2);
        rel(k2);
        rel(empty);
        rel(tail);
        rel(s);
        rel(ss);
    });
}

#[test]
fn arr_slices_of_strings() {
    run(|| unsafe {
        let mut a = auk_arr_new(&auk_ops_str, 0);
        for w in ["a", "b", "c", "d"] {
            let w = s(w);
            auk_arr_push(&mut a, vp(&w));
            rel(w);
        }
        let v = auk_arr_slice(a, 2, 4, c"t".as_ptr());
        rel(a);
        let c = auk_arr_copy(v);
        rel(v); // frees the base and its strings
        check_str(auk_arr_show(c), "[\"c\", \"d\"]");
        rel(c);
    });
}

#[test]
fn arr_concat_reverse_extend() {
    run(|| unsafe {
        let mut a = ints(&[1, 2]);
        let b = ints(&[3, 4, 5]);
        let c = auk_arr_concat(a, b);
        check_str(auk_arr_show(c), "[1, 2, 3, 4, 5]");
        let r = auk_arr_reversed(c);
        check_str(auk_arr_show(r), "[5, 4, 3, 2, 1]");
        check_str(auk_arr_show(c), "[1, 2, 3, 4, 5]");
        auk_arr_extend(&mut a, a); // self-extend
        check_str(auk_arr_show(a), "[1, 2, 1, 2]");
        assert_eq!(auk_arr_sum_int(c, c"t".as_ptr()), 15);
        let sep = s(", ");
        check_str(auk_arr_join(c, sep), "1, 2, 3, 4, 5");
        rel(sep);
        assert!(auk_arr_contains(c, vp(&4i64)));
        assert!(!auk_arr_contains(c, vp(&9i64)));
        assert!(auk_arr_index_of(c, vp(&3i64)).val == 2);
        assert!(auk_arr_cmp(a, c) < 0 || auk_arr_cmp(a, c) > 0);
        let p = ints(&[1, 2]);
        assert!(auk_arr_cmp(p, c) < 0); // prefix sorts first
        assert!(auk_arr_hash(p) == auk_arr_hash(b) || !auk_arr_eq(p, b));
        rel(a);
        rel(b);
        rel(c);
        rel(r);
        rel(p);
    });
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Pair {
    key: i64,
    seq: i64,
}

unsafe extern "C" fn pair_cmp(x: *const c_void, y: *const c_void, _ctx: *mut c_void) -> c_int {
    unsafe { auk_int_cmp((*(x as *const Pair)).key, (*(y as *const Pair)).key) }
}
static PAIR_OPS: AukElemOps =
    AukElemOps { size: size_of::<Pair>(), retain: None, release: None, eq: None, cmp: None, hash: None, show: None, copy: None };

#[test]
fn arr_sort_stable() {
    run(|| unsafe {
        let mut a = auk_arr_new(&PAIR_OPS, 0);
        let mut x: u64 = 12345;
        for i in 0i64..1000 {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let p = Pair { key: (x >> 59) as i64, seq: i }; // lots of equal keys
            auk_arr_push(&mut a, vp(&p));
        }
        let keep = ret(a);
        auk_arr_sort_with(&mut a, pair_cmp, null_mut());
        let ps = std::slice::from_raw_parts(auk_arr_data(a) as *const Pair, 1000);
        for i in 1..1000 {
            assert!(ps[i - 1].key <= ps[i].key);
            if ps[i - 1].key == ps[i].key {
                assert!(ps[i - 1].seq < ps[i].seq);
            }
        }
        assert!((*(auk_arr_data(keep) as *const Pair)).seq == 0); // original untouched
        rel(keep);
        rel(a);

        let mut w = auk_arr_new(&auk_ops_str, 0);
        for word in ["pear", "apple", "éclair", "fig", "apple"] {
            let s = s(word);
            auk_arr_push(&mut w, vp(&s));
            rel(s);
        }
        let sorted = auk_arr_sorted(w);
        check_str(auk_arr_show(sorted), "[\"apple\", \"apple\", \"fig\", \"pear\", \"éclair\"]");
        let mut f = auk_arr_new(&auk_ops_float, 0);
        for d in [2.5f64, -1.0, 0.1, 10.0] {
            auk_arr_push(&mut f, vp(&d));
        }
        auk_arr_sort(&mut f);
        check_str(auk_arr_show(f), "[-1.0, 0.1, 2.5, 10.0]");
        rel(w);
        rel(sorted);
        rel(f);
    });
}

#[test]
fn arr_literal_and_show() {
    run(|| unsafe {
        let xs: [i64; 3] = [3, 1, 2];
        let a = auk_arr_from(&auk_ops_int, xs.as_ptr().cast(), 3);
        check_str(auk_arr_show(a), "[3, 1, 2]");
        let e = auk_arr_new(&auk_ops_int, 0);
        check_str(auk_arr_show(e), "[]");
        let bs = [true, false];
        let b = auk_arr_from(&auk_ops_bool, bs.as_ptr().cast(), 2);
        check_str(auk_arr_show(b), "[true, false]");
        let cs: [u32; 2] = ['a' as u32, 'b' as u32];
        let c = auk_arr_from(&auk_ops_char, cs.as_ptr().cast(), 2);
        let empty = s("");
        check_str(auk_arr_join(c, empty), "ab");
        rel(empty);
        rel(a);
        rel(e);
        rel(b);
        rel(c);
    });
}

#[test]
fn arr_sum_overflow_panics() {
    run(|| {
        expect_panic(
            || unsafe {
                let a = ints(&[i64::MAX, 1]);
                auk_arr_sum_int(a, c"sum.auk:1:1".as_ptr());
            },
            "integer overflow",
        )
    });
}
