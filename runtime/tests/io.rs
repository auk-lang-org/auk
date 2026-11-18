//! Console I/O (stdin, eprint, exit), filesystem extras, binary files and secure random.
mod common;

use common::*;
use auk_rt::arr::*;
use auk_rt::core::*;
use auk_rt::rc::*;
use auk_rt::str::auk_str_eq;
use auk_rt::*;

// ---- stdin ------------------------------------------------------------

/// Feed `text` to this (child) process's stdin through a pipe.
fn feed_stdin(text: &[u8]) {
    unsafe {
        let mut fds = [0i32; 2];
        assert!(libc::pipe(fds.as_mut_ptr()) == 0);
        assert!(libc::write(fds[1], text.as_ptr().cast(), text.len()) == text.len() as isize);
        libc::close(fds[1]);
        libc::dup2(fds[0], 0);
        libc::close(fds[0]);
        libc::clearerr(c_stdin());
    }
}

#[test]
fn stdin_read_line_lines_and_all() {
    run(|| {
        let (code, out) = child(|| unsafe {
            feed_stdin(b"one\r\ntwo\n\nlast");
            let a = auk_env_read_line();
            let b = auk_env_read_line();
            cprint(&format!("[{}][{}]", text(a.val), text(b.val)));
            rel(a.val);
            rel(b.val);
            let rest = auk_env_lines(); // "", "last"
            cprint(&format!("{}", auk_arr_len(rest)));
            rel(rest);
            let eof = auk_env_read_line();
            cprint(&format!(" eof={}", !eof.some as i32));
            let none = auk_env_lines();
            cprint(&format!(" {}", auk_arr_len(none)));
            rel(none);
            if auk_live_objects() != 0 {
                cprint(" LEAK");
            }
        });
        assert_eq!(code, 0);
        assert_eq!(out, "[one][two]2 eof=1 0");
        let (code, out) = child(|| unsafe {
            feed_stdin(b"x\n");
            let a = auk_env_read_line();
            rel(a.val);
            feed_stdin("hé\nllo".as_bytes());
            let r = auk_env_read_all();
            cprint(&format!("ok={} [{}]", r.ok as i32, if r.ok { text(r.val) } else { String::new() }));
            rel(r.val);
            feed_stdin(b"bad \xFF\n");
            let bad = auk_env_read_all();
            let msg = if bad.ok { String::new() } else { err_text(bad.err) };
            cprint(&format!(" | ok={} {}", bad.ok as i32, msg));
            feed_stdin(b"a\xFFb\n");
            let lossy = auk_env_read_line();
            cprint(&format!(" | {}", text(lossy.val)));
            rel(lossy.val);
        });
        assert_eq!(code, 0);
        assert!(out.starts_with("ok=1 [hé\nllo]"), "{out}");
        assert!(out.contains("| ok=0 env.read_all: stdin: invalid UTF-8"), "{out}");
        assert!(out.contains("| a\u{FFFD}b"), "{out}");
    });
}

// ---- eprint / exit ----------------------------------------------------

#[test]
fn eprint_goes_to_stderr() {
    run(|| {
        let (code, out) = child(|| unsafe {
            // stderr goes to a pipe of its own, so the parent can tell the streams apart
            let mut fds = [0i32; 2];
            assert!(libc::pipe(fds.as_mut_ptr()) == 0);
            libc::dup2(fds[1], 2);
            libc::close(fds[1]);
            let s = s("to stderr");
            auk_print_lit(c"to stdout".as_ptr());
            auk_eprint(s);
            rel(s);
            libc::fflush(c_stderr());
            let mut buf = [0u8; 63];
            let n = libc::read(fds[0], buf.as_mut_ptr().cast(), buf.len());
            let got = String::from_utf8_lossy(&buf[..n.max(0) as usize]).into_owned();
            cprint(&format!("err={got}"));
        });
        assert_eq!(code, 0);
        assert_eq!(out, "to stdout\nerr=to stderr\n");
    });
}

fn exit_child(code: i64) -> ! {
    cprint("unflushed");
    unsafe { auk_proc_exit(code, c"t.auk:1:1".as_ptr()) }
}

static mut EXIT_GLOBAL: *mut AukStr = std::ptr::null_mut();
unsafe extern "C" fn exit_cleanup() {
    unsafe {
        rel(EXIT_GLOBAL);
        EXIT_GLOBAL = std::ptr::null_mut();
    }
}
fn exit_leak_child(leak: bool) -> ! {
    unsafe {
        std::env::set_var("AUK_LEAK_CHECK", "1");
        EXIT_GLOBAL = s("global"); // released by the cleanup
        auk_set_cleanup(Some(exit_cleanup));
        let _leaked = if leak { s("leaked") } else { std::ptr::null_mut() };
        auk_proc_exit(3, c"t.auk:1:1".as_ptr())
    }
}

#[test]
fn proc_exit_flushes_and_checks_leaks() {
    run(|| {
        let (code, out) = child(|| exit_child(7));
        assert_eq!(code, 7);
        assert_eq!(out, "unflushed");
        let (code, _) = child(|| exit_child(0));
        assert_eq!(code, 0);
        expect_panic(|| exit_child(256), "proc.exit(256): code out of range 0..255\n  at t.auk:1:1");
        expect_panic(|| exit_child(-1), "out of range");
        let (code, out) = child(|| exit_leak_child(false));
        assert_eq!(code, 3, "{out}");
        assert_eq!(out, "");
        let (code, out) = child(|| exit_leak_child(true));
        assert_eq!(code, 102, "{out}");
        assert!(out.contains("leak: 1 runtime object(s) still live at exit"), "{out}");
    });
}

// ---- fs extras --------------------------------------------------------

#[track_caller]
fn check_ok(r: AukRes_unit, what: &str) {
    if !r.ok {
        panic!("{what} failed: {}", err_text(r.err));
    }
}

#[test]
fn fs_dirs_list_rename_remove() {
    run(|| unsafe {
        let tmp = TempDir::new();
        let root = tmp.path("fsx");
        let deep = tmp.path("fsx/a/b/c");
        let f1 = tmp.path("fsx/b.txt");
        let f2 = tmp.path("fsx/a.txt");
        let f3 = tmp.path("fsx/z.txt");
        let missing = tmp.path("fsx/missing");
        assert!(!auk_fs_exists(root));
        check_ok(auk_fs_mkdir(deep), "mkdir -p");
        check_ok(auk_fs_mkdir(deep), "mkdir existing");
        assert!(auk_fs_is_dir(deep) && auk_fs_exists(deep));
        let (x, yn, empty) = (s("x"), s("y\n"), s(""));
        check_ok(auk_fs_append(f1, x), "append new");
        check_ok(auk_fs_append(f1, yn), "append more");
        let rd = auk_fs_read(f1);
        assert!(rd.ok);
        check_str(rd.val, "xy\n");
        assert!(auk_fs_exists(f1) && !auk_fs_is_dir(f1));
        check_ok(auk_fs_write(f2, empty), "write");

        let bad = auk_fs_mkdir(f1); // a file is in the way
        assert!(!bad.ok);
        assert!(text((*bad.err).msg).contains("fs.mkdir"));
        rel(bad.err);

        let ls = auk_fs_list(root);
        assert!(ls.ok);
        check_str(auk_arr_show(ls.val), "[\"a\", \"a.txt\", \"b.txt\"]");
        rel(ls.val);

        check_ok(auk_fs_rename(f1, f3), "rename");
        assert!(!auk_fs_exists(f1) && auk_fs_exists(f3));
        let rn = auk_fs_rename(f1, f3);
        assert!(!rn.ok);
        let m = err_text(rn.err);
        assert!(m.contains("fs.rename ") && m.contains(" -> "), "{m}");

        let rm = auk_fs_remove(root); // not empty
        assert!(!rm.ok);
        rel(rm.err);
        check_ok(auk_fs_remove(f3), "remove file");
        check_ok(auk_fs_remove(deep), "remove empty dir");
        assert!(!auk_fs_exists(f3) && !auk_fs_exists(deep));
        let rm = auk_fs_remove(missing);
        assert!(!rm.ok && (*rm.err).code == libc::ENOENT as i64);
        rel(rm.err);

        let none = auk_fs_list(missing);
        assert!(!none.ok);
        let m = err_text(none.err);
        assert!(m.contains("fs.list ") && m.contains("missing"), "{m}");

        let nested = tmp.path("fsx/no/such/f");
        let ap = auk_fs_append(nested, x);
        assert!(!ap.ok);
        rel(ap.err);
        for p in [nested, x, yn, empty, root, deep, f1, f2, f3, missing] {
            rel(p);
        }
    });
}

#[test]
fn fs_temp_dir_is_fresh() {
    use std::os::unix::fs::PermissionsExt;
    run(|| unsafe {
        let a = auk_fs_temp_dir();
        let b = auk_fs_temp_dir();
        assert!(a.ok && b.ok);
        assert!(!auk_str_eq(a.val, b.val));
        assert!(auk_fs_is_dir(a.val) && auk_fs_is_dir(b.val));
        let md = std::fs::metadata(text(a.val)).unwrap();
        assert_eq!(md.permissions().mode() & 0o777, 0o700);
        let ls = auk_fs_list(a.val);
        assert!(ls.ok && auk_arr_len(ls.val) == 0);
        rel(ls.val);
        check_ok(auk_fs_remove(a.val), "remove a");
        check_ok(auk_fs_remove(b.val), "remove b");
        rel(a.val);
        rel(b.val);
    });
}

#[test]
fn fs_bytes_round_trip() {
    run(|| unsafe {
        let tmp = TempDir::new();
        let p = tmp.path("bytes.bin");
        let mut a = auk_arr_new(&auk_ops_int, 256);
        for i in 0i64..256 {
            push(&mut a, (i * 7 + 3) % 256);
        }
        check_ok(auk_fs_write_bytes(p, a), "write_bytes");
        let r = auk_fs_read_bytes(p);
        assert!(r.ok);
        assert!(auk_arr_eq(r.val, a));
        rel(r.val);

        // out of range: an Err, and the file is left alone
        push(&mut a, 256i64);
        let w = auk_fs_write_bytes(p, a);
        assert!(!w.ok);
        let m = err_text(w.err);
        assert!(m.contains("byte 256 at index 256 is out of range 0..255"), "{m}");
        let r = auk_fs_read_bytes(p);
        assert!(r.ok && auk_arr_len(r.val) == 256);
        rel(r.val);
        let mut b = auk_arr_new(&auk_ops_int, 1);
        push(&mut b, -1i64);
        let w = auk_fs_write_bytes(p, b);
        assert!(!w.ok);
        rel(w.err);
        rel(b);

        let empty = auk_arr_new(&auk_ops_int, 0);
        check_ok(auk_fs_write_bytes(p, empty), "write empty");
        let r = auk_fs_read_bytes(p);
        assert!(r.ok && auk_arr_len(r.val) == 0);
        rel(r.val);
        rel(empty);

        let missing = tmp.path("nope.bin");
        let r = auk_fs_read_bytes(missing);
        assert!(!r.ok && (*r.err).code == libc::ENOENT as i64);
        rel(r.err);
        rel(missing);
        rel(a);
        rel(p);
    });
}

// ---- secure random ------------------------------------------------------

fn data(a: *mut AukArr) -> Vec<i64> {
    int_elems(a)
}

#[test]
fn rand_bytes_and_seed() {
    run(|| unsafe {
        let t = c"t".as_ptr();
        let a = auk_rand_bytes(32, t);
        let b = auk_rand_bytes(32, t);
        assert_eq!(auk_arr_len(a), 32);
        assert!(data(a).iter().all(|&x| (0..=255).contains(&x)));
        assert!(!auk_arr_eq(a, b)); // 2^-256
        rel(a);
        rel(b);
        let z = auk_rand_bytes(0, t);
        assert_eq!(auk_arr_len(z), 0);
        rel(z);
        let big = auk_rand_bytes(4096, t); // more than getentropy's 256-byte limit
        let mut seen = [false; 256];
        let mut distinct = 0;
        for y in data(big) {
            if !seen[y as usize] {
                seen[y as usize] = true;
                distinct += 1;
            }
        }
        assert!(distinct > 200);
        rel(big);
        expect_panic(
            || {
                auk_rand_bytes(-1, c"r.auk:2:3".as_ptr());
            },
            "rand.bytes(-1): negative count\n  at r.auk:2:3",
        );

        // a seed makes rand.int/rand.float repeatable
        auk_rand_seed(42);
        let s1: Vec<i64> = (0..8).map(|_| auk_rand_int(0, 1000000)).collect();
        let f1 = auk_rand_float();
        auk_rand_seed(42);
        for &x in &s1 {
            assert_eq!(auk_rand_int(0, 1000000), x);
        }
        assert!(auk_rand_float() == f1);
        auk_rand_seed(43);
        let mut differ = false;
        for &x in &s1 {
            differ |= auk_rand_int(0, 1000000) != x;
        }
        assert!(differ);
        // ... but never the CSPRNG
        auk_rand_seed(42);
        let a = auk_rand_bytes(16, t);
        auk_rand_seed(42);
        let b = auk_rand_bytes(16, t);
        assert!(!auk_arr_eq(a, b));
        rel(a);
        rel(b);
    });
}
