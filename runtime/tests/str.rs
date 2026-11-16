#![allow(clippy::approx_constant)] // 3.14 etc. are formatting inputs, not pi
//! str: UTF-8, indexing, searching, parsing and formatting.
mod common;

use std::ffi::c_char;
use std::ptr::{null, null_mut};

use common::*;
use duck_rt::arr::*;
use duck_rt::str::*;
use duck_rt::*;

fn cp(b: &[u8]) -> *const c_char {
    b.as_ptr().cast()
}

fn valid(b: &[u8]) -> bool {
    unsafe { duck_utf8_valid(cp(b), b.len() as i64, null_mut(), null_mut()) }
}

#[test]
fn str_utf8_validation() {
    run(|| unsafe {
        // (valid, chars, ascii)
        let v = |b: &[u8]| {
            let (mut chars, mut ascii) = (-1i64, false);
            let ok = duck_utf8_valid(cp(b), b.len() as i64, &mut chars, &mut ascii);
            (ok, chars, ascii)
        };
        assert_eq!(v(b""), (true, 0, true));
        assert_eq!(v(b"abc"), (true, 3, true));
        assert_eq!(v(b"h\xC3\xA9"), (true, 2, false)); // hé
        assert!(matches!(v(b"\xF0\x9F\xA6\x86"), (true, 1, _))); // 🦆
        assert!(matches!(v(b"\xE2\x82\xAC"), (true, 1, _))); // €
        assert!(v(b"\xF4\x8F\xBF\xBF").0); // U+10FFFF
        assert!(valid(b"\xEF\xBF\xBF")); // U+FFFF
        assert!(!valid(b"\xC0\x80")); // overlong NUL
        assert!(!valid(b"\xE0\x80\xAF")); // overlong '/'
        assert!(!valid(b"\xF0\x80\x80\xAF")); // overlong 4-byte
        assert!(!valid(b"\xED\xA0\x80")); // surrogate
        assert!(!valid(b"\xF4\x90\x80\x80")); // > U+10FFFF
        assert!(!valid(b"\xC3")); // truncated
        assert!(!valid(b"\xE2\x82")); // truncated
        assert!(!valid(b"\x80")); // lone continuation
        assert!(!valid(b"a\xFF"));
        assert!(!valid(b"\xC3\x28")); // bad continuation
        let mut chars: i64 = 0;
        assert!(duck_utf8_valid(cp(b"a\0b"), 3, &mut chars, null_mut()) && chars == 3);
    });
}

#[test]
fn str_construct_and_repair() {
    run(|| unsafe {
        let s = duck_str_from_bytes(cp(b"a\xFFb"), 3);
        assert!(duck_str_len(s) == 3);
        assert!(!(*s).is_ascii);
        check_str(s, "a\u{FFFD}b");
        let r = duck_str_try_from_bytes(cp(b"ab\xC3"), 3);
        assert!(!r.ok);
        check_str(duck_rt::err::duck_err_show(r.err), "invalid UTF-8 at byte 2");
        rel(r.err);
        let r = duck_str_try_from_bytes(cp(b"\xC3\xA9"), 2);
        assert!(r.ok && duck_str_len(r.val) == 1);
        rel(r.val);
        let e = common::s("");
        assert!(duck_str_len(e) == 0 && duck_str_byte_len(e) == 0 && (*e).is_ascii);
        rel(e);
        // NULL is the empty string
        assert!(duck_str_len(null()) == 0);
        assert!(duck_str_eq(null(), null()));
        let x = duck_str_concat(null(), null());
        check_str(x, "");
    });
}

#[test]
fn str_char_indexing() {
    run(|| unsafe {
        let a = s("hello");
        assert!((*a).is_ascii);
        assert!(duck_str_char_at(a, 0, c"t".as_ptr()) == 'h' as u32);
        assert!(duck_str_char_at(a, 4, c"t".as_ptr()) == 'o' as u32);
        let u = s("héllo 🦆!");
        assert!(duck_str_len(u) == 8);
        assert!(duck_str_byte_len(u) == 12);
        assert!(duck_str_char_at(u, 1, c"t".as_ptr()) == 0xE9);
        assert!(duck_str_char_at(u, 6, c"t".as_ptr()) == 0x1F986);
        assert!(duck_str_char_at(u, 7, c"t".as_ptr()) == '!' as u32);
        assert!(!duck_str_get(u, 8).some);
        assert!(!duck_str_get(u, -1).some);
        assert!(duck_str_get(u, 2).some && duck_str_get(u, 2).val == 'l' as u32);
        check_str(duck_str_slice(u, 1, 3, c"t".as_ptr()), "él");
        check_str(duck_str_slice(u, 6, 8, c"t".as_ptr()), "🦆!");
        check_str(duck_str_slice(u, 3, 3, c"t".as_ptr()), "");
        let whole = duck_str_slice(u, 0, 8, c"t".as_ptr());
        assert!(whole == u); // full slice shares
        rel(whole);
        check_str(duck_str_slice(a, 1, 4, c"t".as_ptr()), "ell");
        rel(a);
        rel(u);
    });
}

#[test]
fn str_index_panics() {
    run(|| {
        expect_panic(
            || unsafe {
                let s = s("hé");
                duck_str_char_at(s, 2, c"main.duck:3:7".as_ptr());
            },
            "index 2 out of range for string of length 2\n  at main.duck:3:7",
        );
        expect_panic(
            || unsafe {
                let s = s("abc");
                duck_str_slice(s, 2, 1, c"main.duck:4:1".as_ptr());
            },
            "slice 2..1 out of range",
        );
    });
}

#[test]
fn str_concat_eq_cmp_hash() {
    run(|| unsafe {
        let (a, b) = (s("ab"), s("é"));
        let c = duck_str_concat(a, b);
        assert!(duck_str_len(c) == 3 && !(*c).is_ascii);
        let c2 = s("abé");
        assert!(duck_str_eq(c, c2));
        assert!(duck_str_hash(c) == duck_str_hash(c2));
        assert!(duck_str_cmp(a, c) < 0);
        assert!(duck_str_cmp(c, a) > 0);
        assert!(duck_str_cmp(c, c2) == 0);
        let z = s("z");
        assert!(duck_str_cmp(z, b) < 0); // 'z' < 'é' by code point
        assert!(duck_str_eq_lit(a, c"ab".as_ptr()) && !duck_str_eq_lit(a, c"abc".as_ptr()));
        for p in [a, b, c, c2, z] {
            rel(p);
        }
    });
}

fn join_arr(a: *mut DuckArr) -> *mut DuckStr {
    let sep = s("|");
    let r = unsafe { duck_arr_join(a, sep) };
    rel(sep);
    rel(a);
    r
}

#[test]
fn str_split_trim_lines() {
    run(|| unsafe {
        let s = common::s("  the quick\t brown\n fox  ");
        check_str(join_arr(duck_str_split_ws(s)), "the|quick|brown|fox");
        check_str(duck_str_trim(s), "the quick\t brown\n fox");
        check_str(duck_str_trim_start(s), "the quick\t brown\n fox  ");
        check_str(duck_str_trim_end(s), "  the quick\t brown\n fox");
        rel(s);

        let e = common::s("");
        let ea = duck_str_split_ws(e);
        assert!(duck_arr_len(ea) == 0);
        rel(ea);
        let comma = common::s(",");
        let one = duck_str_split(e, comma);
        assert!(duck_arr_len(one) == 1);
        rel(one);
        rel(e);

        let csv = common::s("a,,b,");
        check_str(join_arr(duck_str_split(csv, comma)), "a||b|");
        rel(csv);
        rel(comma);

        let (u, arrow, empty) = (common::s("x→y→z"), common::s("→"), common::s(""));
        let parts = duck_str_split(u, arrow);
        assert!(duck_arr_len(parts) == 3);
        assert!(duck_str_len(at::<*mut DuckStr>(parts, 1)) == 1);
        rel(parts);
        check_str(join_arr(duck_str_split(u, empty)), "x|→|y|→|z");
        rel(u);
        rel(arrow);
        rel(empty);

        let t = common::s("one\r\ntwo\n\nthree\n");
        check_str(join_arr(duck_str_lines(t)), "one|two||three");
        rel(t);
        let t = common::s("no newline");
        check_str(join_arr(duck_str_lines(t)), "no newline");
        rel(t);
    });
}

#[test]
fn str_search_replace() {
    run(|| unsafe {
        let s = common::s("héllo wörld");
        let (p, q, w, no, e) = (common::s("hé"), common::s("rld"), common::s("wö"), common::s("xyz"), common::s(""));
        assert!(duck_str_starts_with(s, p) && !duck_str_starts_with(p, s));
        assert!(duck_str_ends_with(s, q) && !duck_str_ends_with(s, p));
        assert!(duck_str_contains(s, w) && !duck_str_contains(s, no) && duck_str_contains(s, e));
        let f = duck_str_find(s, w);
        assert!(f.some && f.val == 6); // char index, not byte index (7)
        assert!(!duck_str_find(s, no).some);
        let (l, ll) = (common::s("l"), common::s("LL"));
        check_str(duck_str_replace(s, l, ll), "héLLLLo wörLLd");
        check_str(duck_str_replace(s, e, ll), "héllo wörld");
        check_str(duck_str_replace(s, no, ll), "héllo wörld");
        let (aaaa, aa, b) = (common::s("aaaa"), common::s("aa"), common::s("b"));
        check_str(duck_str_replace(aaaa, aa, b), "bb");
        check_str(duck_str_upper(s), "HéLLO WöRLD");
        let mixed = common::s("MiXeD Été");
        check_str(duck_str_lower(mixed), "mixed Été");
        check_str(duck_str_repeat(aa, 3, c"t".as_ptr()), "aaaaaa");
        for x in [s, p, q, w, no, e, l, ll, aaaa, aa, b, mixed] {
            rel(x);
        }
    });
}

#[test]
fn str_chars_bytes_utf8() {
    run(|| unsafe {
        let s = common::s("aé🦆");
        let cs = duck_str_chars(s);
        assert!(duck_arr_len(cs) == 3);
        assert!(at::<u32>(cs, 0) == 'a' as u32);
        assert!(at::<u32>(cs, 1) == 0xE9);
        assert!(at::<u32>(cs, 2) == 0x1F986);
        check_str(duck_str_from_chars(cs), "aé🦆");
        check_str(duck_arr_show(cs), "['a', 'é', '🦆']");
        rel(cs);
        let mut bs = duck_str_bytes(s);
        assert!(duck_arr_len(bs) == 7);
        assert!(at::<i64>(bs, 1) == 0xC3);
        let r = duck_str_from_utf8(bs);
        assert!(r.ok && duck_str_eq(r.val, s));
        rel(r.val);
        // truncate the duck: invalid
        duck_arr_pop(&mut bs, null_mut());
        let r = duck_str_from_utf8(bs);
        assert!(!r.ok);
        check_str(duck_rt::err::duck_err_show(r.err), "invalid UTF-8 at byte 3");
        rel(r.err);
        push(&mut bs, 256i64);
        let r = duck_str_from_utf8(bs);
        assert!(!r.ok);
        rel(r.err);
        rel(bs);
        rel(s);
    });
}

#[track_caller]
fn check_int_parse(input: &str, ok: bool, want: i64) {
    let s = s(input);
    let r = unsafe { duck_int_parse(s) };
    rel(s);
    assert_eq!(r.ok, ok, "int.parse({input:?}) ok={}", r.ok);
    if ok {
        assert_eq!(r.val, want, "int.parse({input:?}) = {}", r.val);
    } else {
        rel(r.err);
    }
}

#[track_caller]
fn check_float_parse(input: &str, ok: bool, want: f64) {
    let s = s(input);
    let r = unsafe { duck_float_parse(s) };
    rel(s);
    assert_eq!(r.ok, ok, "float.parse({input:?}) ok={}", r.ok);
    if ok {
        assert!(r.val == want || (want.is_nan() && r.val.is_nan()), "float.parse({input:?}) = {}", r.val);
    } else {
        rel(r.err);
    }
}

#[test]
fn str_parse() {
    run(|| unsafe {
        check_int_parse("0", true, 0);
        check_int_parse("42", true, 42);
        check_int_parse("-17", true, -17);
        check_int_parse("+5", true, 5);
        check_int_parse("1_000_000", true, 1000000);
        check_int_parse("9223372036854775807", true, i64::MAX);
        check_int_parse("-9223372036854775808", true, i64::MIN);
        check_int_parse("9223372036854775808", false, 0);
        check_int_parse("-9223372036854775809", false, 0);
        check_int_parse("", false, 0);
        check_int_parse("-", false, 0);
        check_int_parse(" 1", false, 0);
        check_int_parse("1 ", false, 0);
        check_int_parse("12a", false, 0);
        check_int_parse("_1", false, 0);
        check_int_parse("1__0", false, 0);
        check_int_parse("1_", false, 0);
        check_int_parse("0x10", false, 0);
        let bad = s("abc");
        let r = duck_int_parse(bad);
        check_str(duck_rt::err::duck_err_show(r.err), "int.parse: invalid int \"abc\"");
        rel(r.err);
        rel(bad);

        check_float_parse("1.5", true, 1.5);
        check_float_parse("-0.25", true, -0.25);
        check_float_parse("1e-9", true, 1e-9);
        check_float_parse("3", true, 3.0);
        check_float_parse("inf", true, f64::INFINITY);
        check_float_parse("", false, 0.0);
        check_float_parse("1.5x", false, 0.0);
        check_float_parse(" 1.5", false, 0.0);
        check_float_parse("0x1p3", false, 0.0);
    });
}

#[track_caller]
fn check_float(v: f64, want: &str) {
    let s = duck_str_from_float(v);
    let got = text(s);
    if got != want {
        rel(s);
        panic!("str({v:e}) = {got:?}, want {want:?}");
    }
    // round trip
    let r = unsafe { duck_float_parse(s) };
    rel(s);
    if !v.is_nan() && (!r.ok || r.val != v || r.val.is_sign_negative() != v.is_sign_negative()) {
        panic!("{want:?} does not round-trip");
    }
    if !r.ok {
        rel(r.err);
    }
}

#[test]
fn str_float_formatting() {
    run(|| unsafe {
        check_float(0.1, "0.1");
        check_float(2.0, "2.0");
        check_float(-0.0, "-0.0");
        check_float(0.0, "0.0");
        check_float(1e21, "1e21");
        check_float(1e20, "100000000000000000000.0");
        check_float(123456789.125, "123456789.125");
        check_float(0.1 + 0.2, "0.30000000000000004");
        check_float(1.0 / 3.0, "0.3333333333333333");
        check_float(-1.5, "-1.5");
        check_float(1e-7, "1e-7");
        check_float(1.5e-7, "1.5e-7");
        check_float(0.000001, "0.000001");
        check_float(5e-324, "5e-324");
        check_float(1.7976931348623157e308, "1.7976931348623157e308");
        check_float(100.0, "100.0");
        check_float(3.14, "3.14");
        check_float(f64::INFINITY, "inf");
        check_float(f64::NEG_INFINITY, "-inf");
        check_float(f64::NAN, "NaN");
        // random round-trips
        let mut x: u64 = 88172645463325252;
        for _ in 0..2000 {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            let d = f64::from_bits(x);
            if !d.is_finite() {
                continue;
            }
            let s = duck_str_from_float(d);
            let t = text(s);
            assert!(t.contains('.') || t.contains('e'), "{t}");
            let r = duck_float_parse(s);
            assert!(r.ok && r.val == d, "{t}");
            rel(s);
        }
    });
}

#[test]
fn str_scalar_formatting() {
    run(|| unsafe {
        check_str(duck_str_from_int(0), "0");
        check_str(duck_str_from_int(-42), "-42");
        check_str(duck_str_from_int(i64::MIN), "-9223372036854775808");
        check_str(duck_str_from_char(0x1F986), "🦆");
        check_str(duck_str_from_char('x' as u32), "x");
        check_str(duck_str_from_bool(true), "true");
        check_str(duck_str_from_bool(false), "false");
        let q = s("a\"b\\c\nd\té\x01");
        check_str(duck_str_quote(q), "\"a\\\"b\\\\c\\nd\\té\\u{1}\"");
        rel(q);
        check_str(duck_char_quote('\'' as u32), "'\\''");
        check_str(duck_char_quote('a' as u32), "'a'");
    });
}

#[test]
fn str_format_specs() {
    run(|| unsafe {
        check_str(duck_fmt_int(42, c">5".as_ptr()), "   42");
        check_str(duck_fmt_int(42, c"5".as_ptr()), "   42"); // numbers default right
        check_str(duck_fmt_int(42, c"<5".as_ptr()), "42   ");
        check_str(duck_fmt_int(42, c"^6".as_ptr()), "  42  ");
        check_str(duck_fmt_int(-42, c"05".as_ptr()), "-0042");
        check_str(duck_fmt_int(42, c"05".as_ptr()), "00042");
        check_str(duck_fmt_int(123456, c"3".as_ptr()), "123456");
        check_str(duck_fmt_int(7, c"".as_ptr()), "7");
        check_str(duck_fmt_int(7, null()), "7");
        check_str(duck_fmt_int(7, c"*>4".as_ptr()), "***7");
        check_str(duck_fmt_float(3.14159, c".2".as_ptr()), "3.14");
        check_str(duck_fmt_float(2.0, c".3".as_ptr()), "2.000");
        check_str(duck_fmt_float(2.5, c".0".as_ptr()), "2");
        check_str(duck_fmt_float(-1.5, c"08.2".as_ptr()), "-0001.50");
        check_str(duck_fmt_float(3.14159, c">8.3".as_ptr()), "   3.142");
        check_str(duck_fmt_float(0.1, c"".as_ptr()), "0.1");
        check_str(duck_fmt_float(2.0, c"6".as_ptr()), "   2.0");
        let w = s("wörd");
        check_str(duck_fmt_str(w, c"<8".as_ptr()), "wörd    "); // width counts chars
        check_str(duck_fmt_str(w, c">6".as_ptr()), "  wörd");
        check_str(duck_fmt_str(w, c"8".as_ptr()), "wörd    "); // strings default left
        check_str(duck_fmt_str(w, c".2".as_ptr()), "wö");
        check_str(duck_fmt_str(w, c"·^8".as_ptr()), "··wörd··"); // fill ·
        check_str(duck_fmt_str(w, c"".as_ptr()), "wörd");
        rel(w);
        check_str(duck_fmt_char('x' as u32, c">3".as_ptr()), "  x");
        check_str(duck_fmt_bool(true, c"<6".as_ptr()), "true  ");
    });
}

#[test]
fn str_bad_spec_panics() {
    run(|| {
        expect_panic(
            || unsafe {
                duck_fmt_int(1, c">x".as_ptr());
            },
            "bad format spec",
        )
    });
}

#[test]
fn str_builder() {
    run(|| unsafe {
        let mut b = DuckStrBuf::INIT;
        duck_sb_lit(&mut b, c"hi ".as_ptr());
        let name = s("dück");
        duck_sb_str(&mut b, name);
        duck_sb_lit(&mut b, c" n=".as_ptr());
        duck_sb_str_own(&mut b, duck_fmt_int(5, c">3".as_ptr()));
        duck_sb_char(&mut b, ' ' as u32);
        duck_sb_char(&mut b, 0x1F986);
        sb_push_str(&mut b, &format!(" {}", 7)); // C: duck_sb_printf(&b, " %d", 7)
        let s = duck_sb_finish(&mut b);
        assert!(duck_str_len(s) == 17);
        check_str(s, "hi dück n=  5 🦆 7");
        rel(name);
        let mut e = DuckStrBuf::INIT;
        check_str(duck_sb_finish(&mut e), "");
    });
}

#[test]
fn str_char_helpers() {
    run(|| {
        assert!(duck_char_is_digit('7' as u32) && !duck_char_is_digit('a' as u32));
        assert!(duck_char_is_alpha('Q' as u32) && !duck_char_is_alpha('1' as u32));
        assert!(duck_char_is_space('\t' as u32) && !duck_char_is_space(0xA0 + 0x1000));
        assert!(
            duck_char_upper('a' as u32) == 'A' as u32
                && duck_char_lower('A' as u32) == 'a' as u32
                && duck_char_upper(0xE9) == 0xE9
        );
        assert!(duck_char_from_int(65).some && duck_char_from_int(65).val == 'A' as u32);
        assert!(!duck_char_from_int(0xD800).some);
        assert!(!duck_char_from_int(0x110000).some);
        assert!(!duck_char_from_int(-1).some);
    });
}
