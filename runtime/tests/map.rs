//! {K: V}: insertion order, replacement, removal, COW.
mod common;

use std::ffi::c_void;
use std::ptr::null_mut;

use common::*;
use duck_rt::arr::*;
use duck_rt::map::*;
use duck_rt::rc::*;
use duck_rt::str::duck_str_eq;
use duck_rt::*;

fn vp<T>(x: &T) -> *const c_void {
    (x as *const T).cast()
}

fn put_si(m: &mut *mut DuckMap, k: &str, v: i64) {
    let ks = s(k);
    unsafe { duck_map_set(m, vp(&ks), vp(&v)) };
    rel(ks);
}

fn get_si(m: *mut DuckMap, k: &str, found: &mut bool) -> i64 {
    let ks = s(k);
    let mut v: i64 = 0;
    *found = unsafe { duck_map_get_opt(m, vp(&ks), (&raw mut v).cast()) };
    rel(ks);
    v
}

#[test]
fn map_insertion_order_and_replace() {
    run(|| unsafe {
        let mut m = duck_map_new(&duck_ops_str, &duck_ops_int);
        put_si(&mut m, "zebra", 1);
        put_si(&mut m, "apple", 2);
        put_si(&mut m, "mango", 3);
        check_str(duck_map_show(m), "{\"zebra\": 1, \"apple\": 2, \"mango\": 3}");
        put_si(&mut m, "apple", 20); // replace keeps position
        check_str(duck_map_show(m), "{\"zebra\": 1, \"apple\": 20, \"mango\": 3}");
        assert_eq!(duck_map_len(m), 3);
        let mut found = false;
        assert!(get_si(m, "apple", &mut found) == 20 && found);
        get_si(m, "nope", &mut found);
        assert!(!found);
        let k = s("zebra");
        assert!(duck_map_contains(m, vp(&k)));
        let mut old: i64 = 0;
        assert!(duck_map_remove(&mut m, vp(&k), (&raw mut old).cast()) && old == 1);
        assert!(!duck_map_remove(&mut m, vp(&k), null_mut()));
        assert!(!duck_map_contains(m, vp(&k)));
        check_str(duck_map_show(m), "{\"apple\": 20, \"mango\": 3}");
        put_si(&mut m, "zebra", 9); // re-inserted keys go to the end
        check_str(duck_map_show(m), "{\"apple\": 20, \"mango\": 3, \"zebra\": 9}");
        let keys = duck_map_keys(m);
        let vals = duck_map_values(m);
        check_str(duck_arr_show(keys), "[\"apple\", \"mango\", \"zebra\"]");
        check_str(duck_arr_show(vals), "[20, 3, 9]");
        let (mut it, mut n) = (0i64, 0i64);
        let (mut kp, mut vp_): (*mut c_void, *mut c_void) = (null_mut(), null_mut());
        while duck_map_next(m, &mut it, &mut kp, &mut vp_) {
            n += *(vp_ as *const i64);
        }
        assert_eq!(n, 32);
        assert_eq!(*(duck_map_at(m, vp(&k), c"t".as_ptr()) as *const i64), 9);
        rel(k);
        rel(keys);
        rel(vals);
        rel(m);
    });
}

#[test]
fn map_many_entries() {
    run(|| unsafe {
        let mut m = duck_map_new(&duck_ops_int, &duck_ops_int);
        for i in 0i64..5000 {
            let v = i * i;
            duck_map_set(&mut m, vp(&i), vp(&v));
        }
        assert_eq!(duck_map_len(m), 5000);
        for i in (0i64..5000).step_by(2) {
            assert!(duck_map_remove(&mut m, vp(&i), null_mut()));
        }
        assert_eq!(duck_map_len(m), 2500);
        for i in 0i64..5000 {
            let v = duck_map_find(m, vp(&i)) as *const i64;
            if i % 2 != 0 {
                assert!(!v.is_null() && *v == i * i);
            } else {
                assert!(v.is_null());
            }
        }
        // order of the survivors is still insertion order
        let (mut it, mut prev) = (0i64, -1i64);
        let mut k: *mut c_void = null_mut();
        while duck_map_next(m, &mut it, &mut k, null_mut()) {
            assert!(*(k as *const i64) > prev);
            prev = *(k as *const i64);
        }
        // churn: remove/insert the same keys many times
        for _round in 0..50 {
            for i in (1i64..200).step_by(2) {
                assert!(duck_map_remove(&mut m, vp(&i), null_mut()));
                duck_map_set(&mut m, vp(&i), vp(&i));
            }
        }
        assert_eq!(duck_map_len(m), 2500);
        it = 0;
        duck_map_next(m, &mut it, &mut k, null_mut());
        let first = *(k as *const i64);
        assert_eq!(first, 201); // 1..199 were moved to the end
        rel(m);
    });
}

#[test]
fn map_copy_on_write() {
    run(|| unsafe {
        let mut a = duck_map_new(&duck_ops_str, &duck_ops_str);
        let (k, v1, v2) = (s("k"), s("v1"), s("v2"));
        duck_map_set(&mut a, vp(&k), vp(&v1));
        let mut b = ret(a);
        duck_map_set(&mut b, vp(&k), vp(&v2));
        assert!(a != b);
        assert!(duck_str_eq(*(duck_map_at(a, vp(&k), c"t".as_ptr()) as *const *mut DuckStr), v1));
        assert!(duck_str_eq(*(duck_map_at(b, vp(&k), c"t".as_ptr()) as *const *mut DuckStr), v2));
        let mut c = ret(a);
        assert!(duck_map_remove(&mut c, vp(&k), null_mut()));
        assert_eq!(duck_map_len(a), 1);
        assert_eq!(duck_map_len(c), 0);
        assert!(!duck_map_eq(a, b));
        let mut d = duck_map_copy(a);
        assert!(duck_map_eq(a, d));
        // value object refcounts: v1 held by a and d
        assert_eq!(duck_refcount(v1.cast()), 3);
        // setting a value that lives inside the map itself
        duck_map_set(&mut d, vp(&k), duck_map_at(d, vp(&k), c"t".as_ptr()));
        assert_eq!(duck_refcount(v1.cast()), 3);
        rel(a);
        rel(b);
        rel(c);
        rel(d);
        assert_eq!(duck_refcount(v1.cast()), 1);
        rel(k);
        rel(v1);
        rel(v2);
    });
}

#[test]
fn map_eq_ignores_order() {
    run(|| unsafe {
        let mut a = duck_map_new(&duck_ops_str, &duck_ops_int);
        let mut b = duck_map_new(&duck_ops_str, &duck_ops_int);
        put_si(&mut a, "x", 1);
        put_si(&mut a, "y", 2);
        put_si(&mut b, "y", 2);
        put_si(&mut b, "x", 1);
        assert!(duck_map_eq(a, b));
        put_si(&mut b, "x", 3);
        assert!(!duck_map_eq(a, b));
        rel(a);
        rel(b);
    });
}

#[test]
fn map_missing_key_panics() {
    run(|| unsafe {
        let m = duck_map_new(&duck_ops_str, &duck_ops_int);
        expect_panic(
            || {
                let k = s("ghost");
                duck_map_at(m, vp(&k), c"m.duck:2:3".as_ptr());
            },
            "key not found: \"ghost\"\n  at m.duck:2:3",
        );
        rel(m);
    });
}

#[test]
fn map_nested_values() {
    run(|| unsafe {
        // {str: [int]} with COW on the inner list
        let mut m = duck_map_new(&duck_ops_str, &duck_ops_arr);
        let k = s("xs");
        let xs = duck_arr_new(&duck_ops_int, 0);
        duck_map_set(&mut m, vp(&k), vp(&xs));
        let snap = ret(m);
        duck_map_make_unique(&mut m);
        let slot = duck_map_find(m, vp(&k)) as *mut *mut DuckArr;
        push(&mut *slot, 7i64);
        check_str(duck_map_show(m), "{\"xs\": [7]}");
        check_str(duck_map_show(snap), "{\"xs\": []}");
        rel(m);
        rel(snap);
        rel(k);
        rel(xs);
    });
}
