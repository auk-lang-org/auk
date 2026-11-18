//! Strings, the builder, parsing and formatting: now in C (`runtime/c/str.c`). These
//! declarations keep the Rust modules not yet ported compiling.

use std::ffi::{c_char, c_int, c_void};

use crate::*;

unsafe extern "C" {
    pub unsafe fn auk_str_len(s: *const AukStr) -> i64;
    pub unsafe fn auk_str_byte_len(s: *const AukStr) -> i64;
    pub unsafe fn auk_str_cstr(s: *const AukStr) -> *const c_char;
    pub unsafe fn auk_utf8_valid(p: *const c_char, n: i64, chars_out: *mut i64, ascii_out: *mut bool) -> bool;
    pub unsafe fn auk_utf8_encode(c: u32, buf: *mut c_char) -> c_int;
    pub unsafe fn auk__sb_put(b: *mut AukStrBuf, p: *const c_void, n: i64);
    pub unsafe fn auk__sb_put_cstr(b: *mut AukStrBuf, s: *const c_char);
    pub unsafe fn auk_sb_bytes(b: *mut AukStrBuf, p: *const c_char, n: i64);
    pub unsafe fn auk_sb_lit(b: *mut AukStrBuf, cstr: *const c_char);
    pub unsafe fn auk_sb_str(b: *mut AukStrBuf, s: *const AukStr);
    pub unsafe fn auk_sb_str_own(b: *mut AukStrBuf, s: *mut AukStr);
    pub unsafe fn auk_sb_char(b: *mut AukStrBuf, c: u32);
    pub unsafe fn auk_sb_int(b: *mut AukStrBuf, v: i64);
    pub unsafe fn auk_sb_finish(b: *mut AukStrBuf) -> *mut AukStr;
    pub unsafe fn auk_sb_free(b: *mut AukStrBuf);
    pub unsafe fn auk__panic_sb(loc: *const c_char, b: *mut AukStrBuf) -> !;
    pub unsafe fn auk__err_sb(b: *mut AukStrBuf) -> *mut AukErr;
    pub unsafe fn auk__str_raw(p: *const c_char, n: i64, chars: i64, ascii: bool) -> *mut AukStr;
    pub unsafe fn auk__str_new(p: *const c_char, n: i64) -> *mut AukStr;
    pub unsafe fn auk_str_from_bytes(p: *const c_char, n: i64) -> *mut AukStr;
    pub unsafe fn auk_str_lit(cstr: *const c_char) -> *mut AukStr;
    pub unsafe fn auk_str_try_from_bytes(p: *const c_char, n: i64) -> AukRes_str;
    pub unsafe fn auk_str_from_utf8(bytes: *mut AukArr) -> AukRes_str;
    pub unsafe fn auk__str_byte_offset(s: *const AukStr, i: i64) -> i64;
    pub unsafe fn auk_str_char_at(s: *const AukStr, i: i64, loc: *const c_char) -> u32;
    pub unsafe fn auk_str_get(s: *const AukStr, i: i64) -> AukOpt_char;
    pub unsafe fn auk_str_slice(s: *const AukStr, a: i64, b: i64, loc: *const c_char) -> *mut AukStr;
    pub unsafe fn auk_str_concat(a: *const AukStr, b: *const AukStr) -> *mut AukStr;
    pub unsafe fn auk_str_eq(a: *const AukStr, b: *const AukStr) -> bool;
    pub unsafe fn auk_str_eq_lit(s: *const AukStr, lit: *const c_char) -> bool;
    pub unsafe fn auk_str_cmp(a: *const AukStr, b: *const AukStr) -> c_int;
    pub unsafe fn auk_str_hash(s: *const AukStr) -> u64;
    pub unsafe fn auk__str_free(s: *mut AukStr);
    pub unsafe fn auk_str_split_ws(s: *const AukStr) -> *mut AukArr;
    pub unsafe fn auk_str_split(s: *const AukStr, sep: *const AukStr) -> *mut AukArr;
    pub unsafe fn auk_str_trim_start(s: *const AukStr) -> *mut AukStr;
    pub unsafe fn auk_str_trim_end(s: *const AukStr) -> *mut AukStr;
    pub unsafe fn auk_str_trim(s: *const AukStr) -> *mut AukStr;
    pub unsafe fn auk_str_lines(s: *const AukStr) -> *mut AukArr;
    pub unsafe fn auk_str_starts_with(s: *const AukStr, pre: *const AukStr) -> bool;
    pub unsafe fn auk_str_ends_with(s: *const AukStr, suf: *const AukStr) -> bool;
    pub unsafe fn auk_str_contains(s: *const AukStr, sub: *const AukStr) -> bool;
    pub unsafe fn auk_str_find(s: *const AukStr, sub: *const AukStr) -> AukOpt_int;
    pub unsafe fn auk_str_replace(s: *const AukStr, from: *const AukStr, to: *const AukStr) -> *mut AukStr;
    pub unsafe fn auk_str_upper(s: *const AukStr) -> *mut AukStr;
    pub unsafe fn auk_str_lower(s: *const AukStr) -> *mut AukStr;
    pub unsafe fn auk_str_repeat(s: *const AukStr, n: i64, loc: *const c_char) -> *mut AukStr;
    pub unsafe fn auk_str_chars(s: *const AukStr) -> *mut AukArr;
    pub unsafe fn auk_str_bytes(s: *const AukStr) -> *mut AukArr;
    pub unsafe fn auk_str_from_chars(chars: *mut AukArr) -> *mut AukStr;
    pub unsafe fn auk_int_parse(s: *const AukStr) -> AukRes_int;
    pub unsafe fn auk_float_parse(s: *const AukStr) -> AukRes_float;
    pub safe fn auk_char_is_digit(c: u32) -> bool;
    pub safe fn auk_char_is_alpha(c: u32) -> bool;
    pub safe fn auk_char_is_space(c: u32) -> bool;
    pub safe fn auk_char_upper(c: u32) -> u32;
    pub safe fn auk_char_lower(c: u32) -> u32;
    pub safe fn auk_char_from_int(n: i64) -> AukOpt_char;
    pub safe fn auk_str_from_int(v: i64) -> *mut AukStr;
    pub unsafe fn auk__fmt_float_shortest(v: f64, out: *mut c_char, outn: usize);
    pub safe fn auk_str_from_float(v: f64) -> *mut AukStr;
    pub safe fn auk_str_from_char(c: u32) -> *mut AukStr;
    pub safe fn auk_str_from_bool(b: bool) -> *mut AukStr;
    pub unsafe fn auk_str_quote(s: *const AukStr) -> *mut AukStr;
    pub safe fn auk_char_quote(c: u32) -> *mut AukStr;
    pub unsafe fn auk_fmt_int(v: i64, spec: *const c_char) -> *mut AukStr;
    pub unsafe fn auk_fmt_float(v: f64, spec: *const c_char) -> *mut AukStr;
    pub unsafe fn auk_fmt_str(s: *const AukStr, spec: *const c_char) -> *mut AukStr;
    pub unsafe fn auk_fmt_char(c: u32, spec: *const c_char) -> *mut AukStr;
    pub unsafe fn auk_fmt_bool(v: bool, spec: *const c_char) -> *mut AukStr;
}

/// Append Rust text to a builder (counts against the show budget, like `auk_sb_bytes`).
pub unsafe fn sb_push_str(b: *mut AukStrBuf, s: &str) {
    unsafe { auk_sb_bytes(b, s.as_ptr().cast(), s.len() as i64) }
}
