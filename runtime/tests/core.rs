//! Arithmetic, Err, Value, closures, tasks, core library and hooks.
mod common;

use std::ffi::{CStr, c_void};
use std::ptr::null_mut;
use std::sync::atomic::{AtomicI32, AtomicPtr, Ordering};

use common::*;
use duck_rt::arr::*;
use duck_rt::core::*;
use duck_rt::err::*;
use duck_rt::map::*;
use duck_rt::rc::*;
use duck_rt::str::*;
use duck_rt::task::*;
use duck_rt::testing::*;
use duck_rt::value::*;
use duck_rt::*;

fn vp<T>(x: &T) -> *const c_void {
    (x as *const T).cast()
}

// ---- arithmetic ------------------------------------------------------

#[test]
fn arith_checked() {
    run(|| {
        let t = c"t".as_ptr();
        assert_eq!(duck_add(2, 3, t), 5);
        assert_eq!(duck_sub(2, 3, t), -1);
        assert_eq!(duck_mul(-4, 3, t), -12);
        assert_eq!(duck_div(7, 2, t), 3);
        assert_eq!(duck_div(-7, 2, t), -3);
        assert_eq!(duck_mod(-7, 2, t), -1);
        assert_eq!(duck_mod(i64::MIN, -1, t), 0);
        assert_eq!(duck_pow(3, 4, t), 81);
        assert_eq!(duck_pow(-2, 63, t), i64::MIN);
        assert_eq!(duck_pow(7, 0, t), 1);
        assert_eq!(duck_pow(0, 0, t), 1);
        assert_eq!(duck_wadd(i64::MAX, 1), i64::MIN);
        assert_eq!(duck_wsub(i64::MIN, 1), i64::MAX);
        assert_eq!(duck_wmul(i64::MAX, 2), -2);
        assert_eq!(duck_float_to_int(-2.9, t), -2);
        assert!(duck_fround(2.5) == 3.0 && duck_fround(-2.5) == -3.0);
        assert!(duck_fsqrt(16.0) == 4.0 && duck_ffloor(-1.5) == -2.0 && duck_fceil(1.2) == 2.0);
        assert!(duck_fpow(2.0, 10.0) == 1024.0);
        assert!(duck_float_cmp(f64::NAN, 1.0) > 0 && duck_float_cmp(1.0, 2.0) < 0);
    });
}

#[test]
fn arith_panics_exit_101() {
    run(|| {
        let x = c"x".as_ptr();
        expect_panic(
            || {
                duck_add(i64::MAX, 1, c"math.duck:1:9".as_ptr());
            },
            "panic: integer overflow in `+`\n  at math.duck:1:9\n",
        );
        expect_panic(
            || {
                duck_sub(i64::MIN, 1, c"math.duck:2:9".as_ptr());
            },
            "integer overflow in `-`",
        );
        expect_panic(
            || {
                duck_mul(i64::MAX / 2 + 1, 2, x);
            },
            "integer overflow in `*`",
        );
        expect_panic(
            || {
                duck_div(1, 0, c"math.duck:4:9".as_ptr());
            },
            "panic: division by zero\n  at math.duck:4:9",
        );
        expect_panic(
            || {
                duck_mod(1, 0, x);
            },
            "division by zero",
        );
        expect_panic(
            || {
                duck_div(i64::MIN, -1, x);
            },
            "integer overflow in `/`",
        );
        expect_panic(
            || {
                duck_neg(i64::MIN, x);
            },
            "integer overflow",
        );
        expect_panic(
            || {
                duck_pow(2, 63, x);
            },
            "integer overflow in `**`",
        );
        expect_panic(
            || {
                duck_pow(2, -1, x);
            },
            "negative exponent",
        );
        expect_panic(
            || {
                duck_float_to_int(f64::NAN, x);
            },
            "int(NaN)",
        );
        expect_panic(
            || {
                duck_float_to_int(1e19, x);
            },
            "out of range",
        );
    });
}

// ---- Err -------------------------------------------------------------

/// A typed error payload with an RC field.
#[repr(C)]
struct BadToken {
    at: i64,
    why: *mut DuckStr,
}

unsafe extern "C" fn bt_retain(p: *mut c_void) {
    unsafe { duck_retain((*(p as *mut BadToken)).why.cast()) };
}
unsafe extern "C" fn bt_release(p: *mut c_void) {
    unsafe { duck_release((*(p as *mut BadToken)).why.cast()) };
}
unsafe extern "C" fn bt_show(p: *const c_void) -> *mut DuckStr {
    unsafe {
        let b = &*(p as *const BadToken);
        let mut sb = DuckStrBuf::INIT;
        sb_push_str(&mut sb, &format!("BadToken({}, ", b.at));
        duck_sb_str_own(&mut sb, duck_str_quote(b.why));
        duck_sb_lit(&mut sb, c")".as_ptr());
        duck_sb_finish(&mut sb)
    }
}
static BT_OPS: DuckElemOps = DuckElemOps {
    size: size_of::<BadToken>(),
    retain: Some(bt_retain),
    release: Some(bt_release),
    eq: None,
    cmp: None,
    hash: None,
    show: Some(bt_show),
    copy: None,
};
const TYPE_BADTOKEN: u32 = 17;
const TYPE_OTHER: u32 = 18;

#[test]
fn err_chain_and_payload() {
    run(|| unsafe {
        let root = err_msg("connection refused");
        (*root).code = 61;
        let m1 = s("fetching config");
        let mid = duck_err_wrap(m1, root);
        let m2 = s("startup failed");
        let top = duck_err_wrap(m2, mid);
        rel(root);
        rel(mid);
        rel(m1);
        rel(m2);
        check_str(duck_err_show(top), "startup failed: fetching config: connection refused");
        assert_eq!((*(*(*top).cause).cause).code, 61);
        rel(top);

        let bt = BadToken { at: 7, why: s("unexpected '}'") };
        let e = duck_err_typed(TYPE_BADTOKEN, vp(&bt), &BT_OPS, std::ptr::null());
        rel(bt.why); // the error holds its own reference
        check_str(duck_err_show(e), "BadToken(7, \"unexpected '}'\")");
        let got = duck_err_payload(e, TYPE_BADTOKEN) as *const BadToken;
        assert!(!got.is_null() && (*got).at == 7 && duck_str_eq_lit((*got).why, c"unexpected '}'".as_ptr()));
        assert!(duck_err_payload(e, TYPE_OTHER).is_null());
        let ctx = s("parsing a.json");
        let w = duck_err_wrap(ctx, e);
        rel(ctx);
        rel(e);
        assert!(!duck_err_payload((*w).cause, TYPE_BADTOKEN).is_null());
        check_str(duck_err_show(w), "parsing a.json: BadToken(7, \"unexpected '}'\")");
        rel(w);

        // a long chain frees without recursion problems
        let mut chain = err_msg("base");
        for _ in 0..100000 {
            let n = duck_err_wrap(std::ptr::null(), chain);
            rel(chain);
            chain = n;
        }
        rel(chain);
    });
}

#[test]
fn err_unwrap_panics() {
    run(|| {
        expect_panic(|| unsafe { duck_unwrap_err(c"u.duck:1:1".as_ptr(), err_msg("boom")) }, "boom");
        expect_panic(|| duck_unwrap_none(c"u.duck:2:2".as_ptr()), "unwrapped `none`\n  at u.duck:2:2");
    });
}

// ---- Value -----------------------------------------------------------

#[test]
fn value_tree() {
    run(|| unsafe {
        let t = c"t".as_ptr();
        let mut m = duck_value_map_new();
        let name = s("duck");
        let vs = duck_value_str(name);
        duck_value_map_put(&mut m, c"name".as_ptr(), vs);
        duck_value_release(vs);
        duck_value_map_put(&mut m, c"age".as_ptr(), duck_value_int(3));
        duck_value_map_put(&mut m, c"w".as_ptr(), duck_value_float(1.5));
        duck_value_map_put(&mut m, c"ok".as_ptr(), duck_value_bool(true));
        duck_value_map_put(&mut m, c"nil".as_ptr(), duck_value_null());
        let mut l = duck_value_list_new();
        let (one, two) = (duck_value_int(1), duck_value_float(2.0));
        duck_arr_push(&mut l, vp(&one));
        duck_arr_push(&mut l, vp(&two));
        let vl = duck_value_list(l);
        duck_value_map_put(&mut m, c"xs".as_ptr(), vl);
        duck_value_release(vl);
        let root = duck_value_map(m);
        check_str(
            duck_value_show(root),
            "{\"name\": \"duck\", \"age\": 3, \"w\": 1.5, \"ok\": true, \"nil\": Null, \"xs\": [1, 2.0]}",
        );
        let copy = duck_value_map(duck_map_copy(m));
        rel(copy.u.map); // duck_value_map retained it
        assert!(duck_value_eq(root, copy));
        assert!(!duck_value_eq(duck_value_int(1), duck_value_float(1.0)));
        assert!(duck_value_as_float(duck_value_int(2), t) == 2.0);
        let k = s("age");
        let age = duck_map_at(duck_value_as_map(root, t), vp(&k), t) as *const DuckValue;
        assert_eq!(duck_value_as_int(*age, t), 3);
        assert_eq!(CStr::from_ptr(duck_value_tag_name(DUCK_V_LIST)).to_bytes(), b"List");
        rel(k);
        duck_value_release(copy);
        duck_value_release(root);
        rel(m);
        rel(l);
        rel(name);
    });
}

#[test]
fn value_accessor_panics() {
    run(|| {
        expect_panic(
            || unsafe {
                duck_value_as_int(duck_value_bool(true), c"v.duck:1:1".as_ptr());
            },
            "expected Int, got Bool",
        )
    });
}

// ---- closures & boxes ------------------------------------------------

#[repr(C)]
struct GreetEnv {
    base: DuckEnv,
    greeting: *mut DuckStr,
    n: i64,
}

static DROPS: AtomicI32 = AtomicI32::new(0);
unsafe extern "C" fn greet_drop(o: *mut DuckObj) {
    DROPS.fetch_add(1, Ordering::SeqCst);
    unsafe { duck_release((*(o as *mut GreetEnv)).greeting.cast()) };
}
type GreetFn = unsafe extern "C" fn(*mut DuckEnv, *mut DuckStr) -> *mut DuckStr;
unsafe extern "C" fn greet_fn(env: *mut DuckEnv, who: *mut DuckStr) -> *mut DuckStr {
    unsafe {
        let e = env as *mut GreetEnv;
        let mut b = DuckStrBuf::INIT;
        duck_sb_str(&mut b, (*e).greeting);
        duck_sb_lit(&mut b, c" ".as_ptr());
        duck_sb_str(&mut b, who);
        sb_push_str(&mut b, &format!(" x{}", (*e).n));
        duck_sb_finish(&mut b)
    }
}

#[test]
fn closures_env_rc() {
    run(|| unsafe {
        DROPS.store(0, Ordering::SeqCst);
        let env = duck_rt::copy::duck_obj_alloc(size_of::<GreetEnv>(), Some(greet_drop), None) as *mut GreetEnv;
        (*env).greeting = s("hi");
        (*env).n = 2;
        let c = DuckClosure { fn_: greet_fn as GreetFn as *mut c_void, env: &raw mut (*env).base };
        let mut fs = duck_arr_new(&duck_ops_closure, 0);
        duck_arr_push(&mut fs, vp(&c));
        duck_closure_release(c); // the array holds it now
        let c2 = at::<DuckClosure>(fs, 0);
        let who = s("duck");
        let f: GreetFn = std::mem::transmute(c2.fn_);
        check_str(f(c2.env, who), "hi duck x2");
        rel(who);
        assert_eq!(DROPS.load(Ordering::SeqCst), 0);
        rel(fs);
        assert_eq!(DROPS.load(Ordering::SeqCst), 1);
    });
}

// ---- tasks -------------------------------------------------------------

#[repr(C)]
struct SleepArgs {
    ms: i64,
    tag: *mut DuckStr,
}

unsafe extern "C" fn sleep_thunk(args: *mut c_void, result: *mut c_void) {
    unsafe {
        let a = args as *mut SleepArgs;
        duck_time_sleep((*a).ms);
        let mut b = DuckStrBuf::INIT;
        duck_sb_str(&mut b, (*a).tag);
        duck_sb_lit(&mut b, c" done".as_ptr());
        *(result as *mut *mut DuckStr) = duck_sb_finish(&mut b);
        duck_release((*a).tag.cast()); // the thunk owns its args
    }
}

#[test]
fn tasks_run_concurrently() {
    run(|| unsafe {
        let t0 = duck_time_now();
        let a1 = SleepArgs { ms: 200, tag: s("a") };
        let a2 = SleepArgs { ms: 200, tag: s("b") };
        let sz = size_of::<SleepArgs>();
        let ps = size_of::<*mut DuckStr>();
        let mut ts = [
            duck_task_spawn(sleep_thunk, vp(&a1), sz, ps, &duck_ops_str, std::ptr::null_mut(), None, std::ptr::null()),
            duck_task_spawn(sleep_thunk, vp(&a2), sz, ps, &duck_ops_str, std::ptr::null_mut(), None, std::ptr::null()),
        ];
        let mut outs: [*mut DuckStr; 2] = [null_mut(); 2];
        duck_task_await_all(ts.as_mut_ptr(), 2, outs.as_mut_ptr().cast());
        let dt = duck_time_now() - t0;
        assert!(dt >= 195);
        assert!(dt < 350, "two 200ms tasks took {dt}ms");
        check_str(outs[0], "a done");
        check_str(outs[1], "b done");
        // awaiting again hands out another reference
        let mut again: *mut DuckStr = null_mut();
        duck_task_await(ts[0], (&raw mut again).cast());
        check_str(again, "a done");
        rel(ts[0]);
        rel(ts[1]);
    });
}

unsafe extern "C" fn sum_thunk(args: *mut c_void, result: *mut c_void) {
    unsafe {
        let n = *(args as *const i64);
        let mut s: i64 = 0;
        for i in 1..=n {
            s = duck_add(s, i, c"t".as_ptr());
        }
        *(result as *mut i64) = s;
    }
}

#[test]
fn tasks_many_and_unawaited() {
    run(|| unsafe {
        let mut ts: [*mut DuckTask; 16] = [null_mut(); 16];
        for (i, t) in ts.iter_mut().enumerate() {
            let n: i64 = 1000 * (i as i64 + 1);
            *t = duck_task_spawn(sum_thunk, vp(&n), size_of::<i64>(), size_of::<i64>(), std::ptr::null(), std::ptr::null_mut(), None, std::ptr::null());
        }
        for (i, &t) in ts.iter().enumerate() {
            let mut r: i64 = 0;
            let n: i64 = 1000 * (i as i64 + 1);
            duck_task_await(t, (&raw mut r).cast());
            assert_eq!(r, n * (n + 1) / 2);
            rel(t);
        }
        // releasing a never-awaited task joins it and releases its result
        let a = SleepArgs { ms: 10, tag: s("x") };
        let t = duck_task_spawn(sleep_thunk, vp(&a), size_of::<SleepArgs>(), size_of::<*mut DuckStr>(), &duck_ops_str, std::ptr::null_mut(), None, std::ptr::null());
        rel(t);
    });
}

#[repr(C)]
struct PushArgs {
    xs: *mut DuckArr,
}

unsafe extern "C" fn shared_push_thunk(args: *mut c_void, result: *mut c_void) {
    unsafe {
        let a = args as *mut PushArgs;
        for i in 0i64..1000 {
            duck_arr_push(&mut (*a).xs, vp(&i)); // COW: copies once
        }
        *(result as *mut i64) = duck_arr_len((*a).xs);
        duck_release((*a).xs.cast());
    }
}

#[test]
fn tasks_atomic_refcounts() {
    run(|| unsafe {
        let xs = duck_arr_new(&duck_ops_int, 0);
        let mut ts: [*mut DuckTask; 8] = [null_mut(); 8];
        for t in ts.iter_mut() {
            let a = PushArgs { xs: ret(xs) };
            *t = duck_task_spawn(shared_push_thunk, vp(&a), size_of::<PushArgs>(), size_of::<i64>(), std::ptr::null(), std::ptr::null_mut(), None, std::ptr::null());
        }
        let mut outs = [0i64; 8];
        duck_task_await_all(ts.as_mut_ptr(), 8, outs.as_mut_ptr().cast());
        for i in 0..8 {
            assert_eq!(outs[i], 1000);
            rel(ts[i]);
        }
        assert_eq!(duck_arr_len(xs), 0);
        assert_eq!(duck_refcount(xs.cast()), 1);
        rel(xs);
    });
}

// ---- fs ------------------------------------------------------------------

#[test]
fn fs_round_trip() {
    run(|| unsafe {
        let tmp = TempDir::new();
        let p = tmp.path("hello.txt");
        let content = s("line one\ndück\r\nlast");
        let w = duck_fs_write(p, content);
        assert!(w.ok);
        let r = duck_fs_read(p);
        assert!(r.ok && duck_str_eq(r.val, content));
        assert_eq!(duck_str_len(r.val), 19);
        rel(r.val);
        let ls = duck_fs_lines(p);
        assert!(ls.ok);
        let sep = s("|");
        check_str(duck_arr_join(ls.val, sep), "line one|dück|last");
        rel(sep);
        rel(ls.val);
        rel(p);
        rel(content);

        let missing = s("/definitely/not/here.txt");
        let r = duck_fs_read(missing);
        assert!(!r.ok);
        assert!((*r.err).code != 0);
        let msg = err_text(r.err);
        assert!(msg.contains("fs.read /definitely/not/here.txt: "), "{msg}");
        let ls = duck_fs_lines(missing);
        assert!(!ls.ok);
        rel(ls.err);
        let w = duck_fs_write(missing, missing);
        assert!(!w.ok);
        rel(w.err);
        rel(missing);

        // invalid UTF-8 on disk is an Err, not a corrupt str
        std::fs::write(format!("{}/bad.bin", tmp.0), b"ok\xFF").unwrap();
        let p = tmp.path("bad.bin");
        let r = duck_fs_read(p);
        assert!(!r.ok);
        let msg = err_text(r.err);
        assert!(msg.contains("invalid UTF-8 at byte 2"), "{msg}");
        rel(p);
    });
}

// ---- proc ----------------------------------------------------------------

#[test]
fn proc_run() {
    run(|| unsafe {
        let echo = s("echo");
        let mut args = duck_arr_new(&duck_ops_str, 0);
        let (a1, a2) = (s("hello"), s("dück world"));
        duck_arr_push(&mut args, vp(&a1));
        duck_arr_push(&mut args, vp(&a2));
        let r = duck_proc_run(echo, args);
        assert!(r.ok);
        check_str(r.val, "hello dück world\n");
        rel(args);
        rel(a1);
        rel(a2);
        rel(echo);

        let f = s("false");
        let none = duck_arr_new(&duck_ops_str, 0);
        let r = duck_proc_run(f, none);
        assert!(!r.ok);
        assert_eq!((*r.err).code, 1);
        check_str(duck_err_show(r.err), "proc.run false: exited with status 1");
        rel(r.err);
        rel(f);

        let nope = s("duck-no-such-command-xyz");
        let r = duck_proc_run(nope, none);
        assert!(!r.ok);
        rel(r.err);
        rel(nope);
        rel(none);
    });
}

// ---- net -----------------------------------------------------------------

#[test]
fn net_tcp_echo() {
    use std::io::{Read, Write};
    run(|| unsafe {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port() as i64;
        let srv = listener.try_clone().unwrap();
        let th = std::thread::spawn(move || {
            let Ok((mut c, _)) = srv.accept() else { return };
            let mut buf = [0u8; 256];
            if let Ok(n) = c.read(&mut buf)
                && n > 0
            {
                let _ = c.write_all(b"echo:");
                let _ = c.write_all(&buf[..n]);
            }
        });

        let host = s("127.0.0.1");
        let c = duck_net_tcp(host, port);
        assert!(c.ok);
        let msg = s("ping 🦆");
        let bytes = duck_str_bytes(msg);
        let w = duck_conn_write(c.val, bytes);
        assert!(w.ok);
        let mut all = duck_arr_new(&duck_ops_int, 0);
        loop {
            let r = duck_conn_read(c.val, 4);
            assert!(r.ok);
            let n = duck_arr_len(r.val);
            duck_arr_extend(&mut all, r.val);
            rel(r.val);
            if n == 0 {
                break; // peer closed
            }
        }
        let st = duck_str_from_utf8(all);
        assert!(st.ok);
        check_str(st.val, "echo:ping 🦆");
        duck_conn_close(c.val);
        let after = duck_conn_read(c.val, 10);
        assert!(!after.ok);
        rel(after.err);
        rel(c.val);
        rel(all);
        rel(bytes);
        rel(msg);
        th.join().unwrap();
        drop(listener);

        // nothing listening on the port any more: connection refused
        let c = duck_net_tcp(host, port);
        assert!(!c.ok);
        rel(c.err);
        let bad = s("no-such-host.invalid");
        let c = duck_net_tcp(bad, 80);
        assert!(!c.ok);
        rel(c.err);
        rel(bad);

        // TLS to the closed port fails cleanly too (more in net.rs)
        let c = duck_rt::tls::duck_net_tls(host, port);
        assert!(!c.ok);
        rel(c.err);
        rel(host);
    });
}

// ---- time, rand, env -----------------------------------------------------

#[test]
fn time_rand_env() {
    run(|| unsafe {
        let t0 = duck_time_now();
        assert!(t0 > 1600000000000);
        duck_time_sleep(20);
        assert!(duck_time_now() - t0 >= 19);
        let mut seen = [false; 7];
        for _ in 0..2000 {
            let r = duck_rand_int(1, 6);
            assert!((1..=6).contains(&r));
            seen[r as usize] = true;
        }
        assert!(seen[1..].iter().all(|&b| b));
        assert_eq!(duck_rand_int(5, 5), 5);
        let _ = duck_rand_int(i64::MIN, i64::MAX);
        let f = duck_rand_float();
        assert!((0.0..1.0).contains(&f));

        std::env::set_var("DUCK_TEST_VAR", "quäck");
        let (k, k2) = (s("DUCK_TEST_VAR"), s("DUCK_TEST_UNSET_VAR"));
        let v = duck_env_get(k);
        assert!(v.some);
        check_str(v.val, "quäck");
        assert!(!duck_env_get(k2).some);
        rel(k);
        rel(k2);

        duck_env_set_args(3, argv(&["prog", "a", "b"]));
        let args = duck_env_args();
        assert_eq!(duck_arr_len(args), 3);
        assert!(duck_str_eq_lit(at::<*mut DuckStr>(args, 2), c"b".as_ptr()));
        rel(args); // immortal: harmless
    });
}

#[test]
fn rand_bad_range_panics() {
    run(|| {
        expect_panic(
            || {
                duck_rand_int(3, 1);
            },
            "lo > hi",
        )
    });
}

// ---- hooks -----------------------------------------------------------------

#[test]
fn hooks_contracts_holes_peek() {
    run(|| unsafe {
        expect_panic(
            || duck_requires_fail(c"isqrt.duck:2:12".as_ptr(), c"n >= 0".as_ptr()),
            "panic: requires failed: n >= 0\n  at isqrt.duck:2:12\n",
        );
        expect_panic(
            || duck_ensures_fail(c"isqrt.duck:3:11".as_ptr(), c"result * result <= n".as_ptr()),
            "ensures failed: result * result <= n",
        );
        expect_panic(
            || duck_hole(c"isqrt.duck:4:3".as_ptr(), c"int".as_ptr()),
            "unfilled hole (expected int)\n  at isqrt.duck:4:3",
        );
        expect_panic(
            || {
                let (l, r) = (s("1"), s("2"));
                duck_assert_fail_cmp(c"t.duck:9:3".as_ptr(), c"a == b".as_ptr(), l, r)
            },
            "assertion failed: a == b\n  left: 1\n  right: 2",
        );
        let (code, out) = child(|| {
            let v = duck_str_from_int(84);
            duck_peek(c"main.duck:7".as_ptr(), c"x * 2".as_ptr(), v);
            rel(v);
        });
        assert_eq!(code, 0);
        assert_eq!(out, "[main.duck:7] x * 2 = 84\n");
    });
}

// ---- duck_test_main ------------------------------------------------------

unsafe extern "C" fn t_pass() -> *mut DuckErr {
    cprint("this output is hidden\n");
    null_mut()
}
unsafe extern "C" fn t_panic() -> *mut DuckErr {
    cprint("before the panic\n");
    duck_add(i64::MAX, 1, c"tests.duck:5:7".as_ptr());
    null_mut()
}
unsafe extern "C" fn t_err() -> *mut DuckErr {
    err_msg("fail() called")
}

#[test]
fn test_runner() {
    run(|| unsafe {
        let (code, out) = child(|| {
            duck_test_register(c"passes".as_ptr(), t_pass);
            duck_test_register(c"overflows".as_ptr(), t_panic);
            duck_test_register(c"returns an error".as_ptr(), t_err);
            let code = duck_test_main(1, argv(&["tests"]));
            libc::fflush(c_stdout());
            libc::_exit(if code == 1 { 42 } else { 43 });
        });
        assert_eq!(code, 42, "{out}");
        let want = "ok passes\n\
                    FAIL overflows\n    before the panic\n    panic: integer overflow in `+`\n      at tests.duck:5:7\n\
                    FAIL returns an error\n    error: fail() called\n\
                    1 passed, 2 failed\n";
        assert_eq!(out, want, "runner output");
        let (code, out) = child(|| {
            duck_test_register(c"passes".as_ptr(), t_pass);
            duck_test_register(c"overflows".as_ptr(), t_panic);
            libc::_exit(if duck_test_main(2, argv(&["tests", "pass"])) == 0 { 42 } else { 43 });
        });
        assert_eq!(code, 42, "{out}");
        assert_eq!(out, "ok passes\n1 passed, 0 failed\n");
    });
}

// ---- duck_main_wrapper ---------------------------------------------------

unsafe extern "C" fn main_ok(args: *mut DuckArr) -> DuckRes_int {
    cprint(&format!("argc={}\n", unsafe { duck_arr_len(args) }));
    DuckRes::ok(7)
}
unsafe extern "C" fn main_err(_args: *mut DuckArr) -> DuckRes_int {
    let cause = err_msg("no such file");
    let m = s("loading config");
    let e = unsafe { duck_err_wrap(m, cause) };
    rel(m);
    rel(cause);
    DuckRes::err(e)
}

#[test]
fn main_wrapper() {
    run(|| unsafe {
        let (code, out) = child(|| libc::_exit(duck_main_wrapper(2, argv(&["prog", "x"]), main_ok)));
        assert_eq!(code, 7);
        assert_eq!(out, "argc=2\n");
        let (code, out) = child(|| libc::_exit(duck_main_wrapper(1, argv(&["prog"]), main_err)));
        assert_eq!(code, 1);
        assert_eq!(out, "error: loading config: no such file\n");
    });
}

#[test]
fn print_lines() {
    run(|| {
        let (code, out) = child(|| unsafe {
            let s = s("héllo");
            duck_print(s);
            duck_print_lit(c"bye".as_ptr());
            rel(s);
        });
        assert_eq!(code, 0);
        assert_eq!(out, "héllo\nbye\n");
    });
}

// Compiler-emitted globals (string literals) are made immortal; the cleanup hook and the
// DUCK_LEAK_CHECK leak check used by `duck test` and duck_main_wrapper.
static CLEANUP_CALLS: AtomicI32 = AtomicI32::new(0);
static CLEANUP_GLOBAL: AtomicPtr<DuckStr> = AtomicPtr::new(null_mut());
unsafe extern "C" fn cleanup_fn() {
    CLEANUP_CALLS.fetch_add(1, Ordering::SeqCst);
    rel(CLEANUP_GLOBAL.swap(null_mut(), Ordering::SeqCst));
}

#[test]
fn immortal_and_leak_check() {
    run(|| unsafe {
        let live = duck_live_objects();
        let lit = s("forever");
        duck_make_immortal(lit.cast());
        assert_eq!(duck_live_objects(), live);
        duck_retain(lit.cast());
        rel(lit);
        rel(lit);
        assert!(duck_str_eq_lit(lit, c"forever".as_ptr()));
        duck_make_immortal(null_mut());

        // without DUCK_LEAK_CHECK the check is a no-op
        std::env::remove_var("DUCK_LEAK_CHECK");
        CLEANUP_GLOBAL.store(s("global"), Ordering::SeqCst);
        duck_set_cleanup(Some(cleanup_fn));
        assert_eq!(duck_leak_check(), 0);
        assert_eq!(CLEANUP_CALLS.load(Ordering::SeqCst), 0);
        // with it: the cleanup runs first, then live objects are counted
        std::env::set_var("DUCK_LEAK_CHECK", "1");
        assert_eq!(duck_leak_check() - live, 0);
        assert_eq!(CLEANUP_CALLS.load(Ordering::SeqCst), 1);
        assert!(CLEANUP_GLOBAL.load(Ordering::SeqCst).is_null());
        std::env::remove_var("DUCK_LEAK_CHECK");
        duck_set_cleanup(None);
    });
}
