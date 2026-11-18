//! Immutable UTF-8 strings, parsing, formatting and the string builder (was str.c).

use std::ffi::{c_char, c_int, c_void};
use std::ptr::null_mut;

use crate::rc::{auk__alloc, auk__free_obj, auk__xmalloc, auk__xrealloc, auk_release, auk_retain};
use crate::*;

/// Bytes at p[0..n) (empty when n <= 0, so p may be NULL then).
unsafe fn raw<'a>(p: *const c_char, n: i64) -> &'a [u8] {
    if n <= 0 || p.is_null() { b"" } else { unsafe { std::slice::from_raw_parts(p.cast(), n as usize) } }
}

/// A C-string-style prefix: the bytes up to the first NUL (what `%s` prints).
fn upto_nul(b: &[u8]) -> &[u8] {
    match b.iter().position(|&c| c == 0) {
        Some(i) => &b[..i],
        None => b,
    }
}

// ---- accessors (exported for generated code) ------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_len(s: *const AukStr) -> i64 {
    if s.is_null() { 0 } else { unsafe { (*s).len_chars } }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_byte_len(s: *const AukStr) -> i64 {
    if s.is_null() { 0 } else { unsafe { (*s).len_bytes } }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_cstr(s: *const AukStr) -> *const c_char {
    if s.is_null() { c"".as_ptr() } else { unsafe { (*s).data.as_ptr().cast() } }
}

unsafe fn is_ascii(s: *const AukStr) -> bool {
    s.is_null() || unsafe { (*s).is_ascii }
}

unsafe fn arr_len(a: *const AukArr) -> i64 {
    if a.is_null() { 0 } else { unsafe { (*a).len } }
}
unsafe fn arr_data(a: *const AukArr) -> *const u8 {
    if a.is_null() { std::ptr::null() } else { unsafe { (*a).data } }
}

// ---- UTF-8 -------------------------------------------------------------------------------

fn utf8_valid(s: &[u8]) -> Option<(i64, bool)> {
    let n = s.len();
    let mut i = 0usize;
    let mut chars: i64 = 0;
    let mut ascii = true;
    while i < n {
        let c = s[i];
        if c < 0x80 {
            i += 1;
        } else {
            ascii = false;
            let (len, mut cp): (usize, u32) = if (0xC2..=0xDF).contains(&c) {
                (2, (c & 0x1F) as u32)
            } else if (0xE0..=0xEF).contains(&c) {
                (3, (c & 0x0F) as u32)
            } else if (0xF0..=0xF4).contains(&c) {
                (4, (c & 0x07) as u32)
            } else {
                return None;
            };
            if i + len > n {
                return None;
            }
            for k in 1..len {
                if s[i + k] & 0xC0 != 0x80 {
                    return None;
                }
                cp = (cp << 6) | (s[i + k] & 0x3F) as u32;
            }
            if len == 3 && (cp < 0x800 || (0xD800..=0xDFFF).contains(&cp)) {
                return None;
            }
            if len == 4 && !(0x10000..=0x10FFFF).contains(&cp) {
                return None;
            }
            i += len;
        }
        chars += 1;
    }
    Some((chars, ascii))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_utf8_valid(p: *const c_char, n: i64, chars_out: *mut i64, ascii_out: *mut bool) -> bool {
    match utf8_valid(unsafe { raw(p, n) }) {
        None => false,
        Some((chars, ascii)) => {
            unsafe {
                if !chars_out.is_null() {
                    *chars_out = chars;
                }
                if !ascii_out.is_null() {
                    *ascii_out = ascii;
                }
            }
            true
        }
    }
}

/// Length of the valid UTF-8 sequence at s[i..), or 0 if invalid.
fn utf8_seq_len(s: &[u8], i: usize) -> usize {
    if s[i] < 0x80 {
        return 1;
    }
    for len in 2..=4 {
        if i + len <= s.len() && matches!(utf8_valid(&s[i..i + len]), Some((1, _))) {
            return len;
        }
    }
    0
}

/// Decode one char at s[i..] (valid input); returns (char, length). Bytes past the end read as 0.
pub fn utf8_decode(s: &[u8], i: usize) -> (u32, usize) {
    let at = |k: usize| s.get(i + k).copied().unwrap_or(0) as u32;
    let b0 = at(0);
    if b0 < 0x80 {
        (b0, 1)
    } else if b0 < 0xE0 {
        (((b0 & 0x1F) << 6) | (at(1) & 0x3F), 2)
    } else if b0 < 0xF0 {
        (((b0 & 0x0F) << 12) | ((at(1) & 0x3F) << 6) | (at(2) & 0x3F), 3)
    } else {
        (((b0 & 0x07) << 18) | ((at(1) & 0x3F) << 12) | ((at(2) & 0x3F) << 6) | (at(3) & 0x3F), 4)
    }
}

pub unsafe fn auk__utf8_decode(p: *const c_char, len: *mut c_int) -> u32 {
    let s = p as *const u8;
    unsafe {
        let b = |k: usize| *s.add(k) as u32;
        if b(0) < 0x80 {
            *len = 1;
            return b(0);
        }
        if b(0) < 0xE0 {
            *len = 2;
            return ((b(0) & 0x1F) << 6) | (b(1) & 0x3F);
        }
        if b(0) < 0xF0 {
            *len = 3;
            return ((b(0) & 0x0F) << 12) | ((b(1) & 0x3F) << 6) | (b(2) & 0x3F);
        }
        *len = 4;
        ((b(0) & 0x07) << 18) | ((b(1) & 0x3F) << 12) | ((b(2) & 0x3F) << 6) | (b(3) & 0x3F)
    }
}

/// Encode c (surrogates / out-of-range become U+FFFD) into buf; returns the length.
pub fn utf8_encode(mut c: u32, b: &mut [u8; 4]) -> usize {
    if c > 0x10FFFF || (0xD800..=0xDFFF).contains(&c) {
        c = 0xFFFD;
    }
    if c < 0x80 {
        b[0] = c as u8;
        return 1;
    }
    if c < 0x800 {
        b[0] = (0xC0 | (c >> 6)) as u8;
        b[1] = (0x80 | (c & 0x3F)) as u8;
        return 2;
    }
    if c < 0x10000 {
        b[0] = (0xE0 | (c >> 12)) as u8;
        b[1] = (0x80 | ((c >> 6) & 0x3F)) as u8;
        b[2] = (0x80 | (c & 0x3F)) as u8;
        return 3;
    }
    b[0] = (0xF0 | (c >> 18)) as u8;
    b[1] = (0x80 | ((c >> 12) & 0x3F)) as u8;
    b[2] = (0x80 | ((c >> 6) & 0x3F)) as u8;
    b[3] = (0x80 | (c & 0x3F)) as u8;
    4
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_utf8_encode(c: u32, buf: *mut c_char) -> c_int {
    let mut b = [0u8; 4];
    let n = utf8_encode(c, &mut b);
    unsafe { std::ptr::copy_nonoverlapping(b.as_ptr(), buf.cast(), n) };
    n as c_int
}

// ---- construction ------------------------------------------------------------------------

/// A string from bytes whose metadata is already known.
pub fn str_raw(b: &[u8], chars: i64, ascii: bool) -> *mut AukStr {
    let n = b.len();
    unsafe {
        let s = auk__alloc(size_of::<AukStr>() + n + 1, AUK_K_STR) as *mut AukStr;
        let d = (*s).data.as_mut_ptr();
        if n != 0 {
            std::ptr::copy_nonoverlapping(b.as_ptr(), d, n);
        }
        *d.add(n) = 0;
        (*s).len_bytes = n as i64;
        (*s).len_chars = chars;
        (*s).is_ascii = ascii;
        s
    }
}

pub unsafe fn auk__str_raw(p: *const c_char, n: i64, chars: i64, ascii: bool) -> *mut AukStr {
    str_raw(unsafe { raw(p, n) }, chars, ascii)
}

/// A string from bytes already known to be valid UTF-8.
pub fn str_new(b: &[u8]) -> *mut AukStr {
    let mut chars = 0i64;
    let mut ascii = true;
    for &u in b {
        if u >= 0x80 {
            ascii = false;
        }
        if u & 0xC0 != 0x80 {
            chars += 1;
        }
    }
    str_raw(b, chars, ascii)
}

pub unsafe fn auk__str_new(p: *const c_char, n: i64) -> *mut AukStr {
    str_new(unsafe { raw(p, n) })
}

/// A string from arbitrary bytes, each invalid byte replaced with U+FFFD.
pub fn str_from_bytes(s: &[u8]) -> *mut AukStr {
    if let Some((chars, ascii)) = utf8_valid(s) {
        return str_raw(s, chars, ascii);
    }
    let mut b = AukStrBuf::INIT;
    let mut i = 0usize;
    unsafe {
        while i < s.len() {
            let len = utf8_seq_len(s, i);
            if len != 0 {
                sb_bytes(&mut b, &s[i..i + len]);
                i += len;
            } else {
                sb_bytes(&mut b, b"\xEF\xBF\xBD");
                i += 1;
            }
        }
        auk_sb_finish(&mut b)
    }
}

/// A string from Rust text (same as `auk_str_lit`).
pub fn str_from(s: &str) -> *mut AukStr {
    str_from_bytes(s.as_bytes())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_from_bytes(p: *const c_char, n: i64) -> *mut AukStr {
    str_from_bytes(unsafe { raw(p, n) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_lit(cstr: *const c_char) -> *mut AukStr {
    str_from_bytes(unsafe { cbytes(cstr) })
}

fn try_from_bytes(s: &[u8]) -> AukRes_str {
    if let Some((chars, ascii)) = utf8_valid(s) {
        return AukRes::ok(str_raw(s, chars, ascii));
    }
    let mut i = 0usize;
    while i < s.len() {
        let len = utf8_seq_len(s, i);
        if len == 0 {
            break;
        }
        i += len;
    }
    err_ptr(crate::err::err_msg(&format!("invalid UTF-8 at byte {i}")))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_try_from_bytes(p: *const c_char, n: i64) -> AukRes_str {
    try_from_bytes(unsafe { raw(p, n) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_from_utf8(bytes: *mut AukArr) -> AukRes_str {
    unsafe {
        let n = arr_len(bytes);
        let xs = arr_data(bytes) as *const i64;
        let mut buf: Vec<u8> = Vec::with_capacity(n.max(0) as usize);
        for i in 0..n {
            let x = *xs.add(i as usize);
            if !(0..=255).contains(&x) {
                return err_ptr(crate::err::err_msg(&format!("byte {x} at index {i} is out of range 0..255")));
            }
            buf.push(x as u8);
        }
        try_from_bytes(&buf)
    }
}

// ---- indexing ----------------------------------------------------------------------------

pub unsafe fn auk__str_byte_offset(s: *const AukStr, i: i64) -> i64 {
    if s.is_null() {
        return 0;
    }
    unsafe {
        if (*s).is_ascii {
            return i;
        }
        if i >= (*s).len_chars {
            return (*s).len_bytes;
        }
        let p = sbytes(s);
        let n = (*s).len_bytes;
        let (mut b, mut c) = (0i64, 0i64);
        while c < i {
            b += 1;
            while b < n && p[b as usize] & 0xC0 == 0x80 {
                b += 1;
            }
            c += 1;
        }
        b
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_char_at(s: *const AukStr, i: i64, loc: *const c_char) -> u32 {
    unsafe {
        let n = auk_str_len(s);
        if i < 0 || i >= n {
            rt_panic!(loc, "index {i} out of range for string of length {n}");
        }
        let d = sbytes(s);
        if (*s).is_ascii {
            return d[i as usize] as u32;
        }
        utf8_decode(d, auk__str_byte_offset(s, i) as usize).0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_get(s: *const AukStr, i: i64) -> AukOpt_char {
    unsafe {
        if i < 0 || i >= auk_str_len(s) {
            return AukOpt::none();
        }
        AukOpt::some(auk_str_char_at(s, i, std::ptr::null()))
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_slice(s: *const AukStr, a: i64, b: i64, loc: *const c_char) -> *mut AukStr {
    unsafe {
        let n = auk_str_len(s);
        if a < 0 || b < a || b > n {
            rt_panic!(loc, "slice {a}..{b} out of range for string of length {n}");
        }
        if a == 0 && b == n && !s.is_null() {
            return auk_retain(s as *mut c_void).cast();
        }
        let ba = auk__str_byte_offset(s, a) as usize;
        let bb = auk__str_byte_offset(s, b) as usize;
        str_raw(&sbytes(s)[ba..bb], b - a, is_ascii(s))
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_concat(a: *const AukStr, b: *const AukStr) -> *mut AukStr {
    unsafe {
        let (x, y) = (sbytes(a), sbytes(b));
        let (na, nb) = (x.len(), y.len());
        let s = auk__alloc(size_of::<AukStr>() + na + nb + 1, AUK_K_STR) as *mut AukStr;
        let d = (*s).data.as_mut_ptr();
        std::ptr::copy_nonoverlapping(x.as_ptr(), d, na);
        std::ptr::copy_nonoverlapping(y.as_ptr(), d.add(na), nb);
        *d.add(na + nb) = 0;
        (*s).len_bytes = (na + nb) as i64;
        (*s).len_chars = auk_str_len(a) + auk_str_len(b);
        (*s).is_ascii = is_ascii(a) && is_ascii(b);
        s
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_eq(a: *const AukStr, b: *const AukStr) -> bool {
    a == b || unsafe { sbytes(a) == sbytes(b) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_eq_lit(s: *const AukStr, lit: *const c_char) -> bool {
    unsafe { sbytes(s) == cbytes(lit) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_cmp(a: *const AukStr, b: *const AukStr) -> c_int {
    // memcmp on the common prefix, then length: exactly lexicographic byte order.
    match unsafe { sbytes(a).cmp(sbytes(b)) } {
        std::cmp::Ordering::Less => -1,
        std::cmp::Ordering::Equal => 0,
        std::cmp::Ordering::Greater => 1,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_hash(s: *const AukStr) -> u64 {
    unsafe { crate::rc::auk_hash_bytes(auk_str_cstr(s).cast(), auk_str_byte_len(s) as usize) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk__str_free(s: *mut AukStr) {
    unsafe { auk__free_obj(s.cast()) }
}

// ---- searching ---------------------------------------------------------------------------

/// Byte offset of needle in hay starting at `from`, or -1.
fn find_bytes(hay: &[u8], needle: &[u8], from: i64) -> i64 {
    let (hn, nn) = (hay.len() as i64, needle.len() as i64);
    if nn == 0 {
        return if from <= hn { from } else { -1 };
    }
    let mut i = from;
    while i + nn <= hn {
        let window = &hay[i as usize..(hn - nn + 1) as usize];
        let Some(off) = window.iter().position(|&c| c == needle[0]) else { return -1 };
        i += off as i64;
        if &hay[i as usize..(i + nn) as usize] == needle {
            return i;
        }
        i += 1;
    }
    -1
}

fn chars_in(p: &[u8]) -> i64 {
    p.iter().filter(|&&c| c & 0xC0 != 0x80).count() as i64
}

/// Sub-string by byte range [a, b) of s (s valid UTF-8, a/b on boundaries).
unsafe fn sub_bytes(s: *const AukStr, a: usize, b: usize) -> *mut AukStr {
    unsafe {
        if !s.is_null() && a == 0 && b as i64 == (*s).len_bytes {
            return auk_retain(s as *mut c_void).cast();
        }
        let p = &sbytes(s)[a..b];
        let ascii = is_ascii(s);
        str_raw(p, if ascii { p.len() as i64 } else { chars_in(p) }, ascii)
    }
}

unsafe fn push_own(a: &mut *mut AukArr, s: *mut AukStr) {
    unsafe {
        crate::arr::auk_arr_push(a, (&s as *const *mut AukStr).cast());
        auk_release(s.cast());
    }
}

fn is_ws(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\r' | 0x0B | 0x0C)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_split_ws(s: *const AukStr) -> *mut AukArr {
    unsafe {
        let mut out = crate::arr::auk_arr_new(&crate::rc::auk_ops_str, 0);
        let p = sbytes(s);
        let n = p.len();
        let mut i = 0;
        while i < n {
            while i < n && is_ws(p[i]) {
                i += 1;
            }
            if i >= n {
                break;
            }
            let st = i;
            while i < n && !is_ws(p[i]) {
                i += 1;
            }
            push_own(&mut out, sub_bytes(s, st, i));
        }
        out
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_split(s: *const AukStr, sep: *const AukStr) -> *mut AukArr {
    unsafe {
        let mut out = crate::arr::auk_arr_new(&crate::rc::auk_ops_str, 0);
        let p = sbytes(s);
        let n = p.len();
        let sp = sbytes(sep);
        if sp.is_empty() {
            let mut i = 0;
            while i < n {
                let (_, len) = utf8_decode(p, i);
                push_own(&mut out, sub_bytes(s, i, i + len));
                i += len;
            }
            return out;
        }
        let mut st = 0usize;
        loop {
            let at = find_bytes(p, sp, st as i64);
            if at < 0 {
                break;
            }
            push_own(&mut out, sub_bytes(s, st, at as usize));
            st = at as usize + sp.len();
        }
        push_own(&mut out, sub_bytes(s, st, n));
        out
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_trim_start(s: *const AukStr) -> *mut AukStr {
    unsafe {
        let p = sbytes(s);
        let mut a = 0;
        while a < p.len() && is_ws(p[a]) {
            a += 1;
        }
        sub_bytes(s, a, p.len())
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_trim_end(s: *const AukStr) -> *mut AukStr {
    unsafe {
        let p = sbytes(s);
        let mut b = p.len();
        while b > 0 && is_ws(p[b - 1]) {
            b -= 1;
        }
        sub_bytes(s, 0, b)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_trim(s: *const AukStr) -> *mut AukStr {
    unsafe {
        let p = sbytes(s);
        let n = p.len();
        let (mut a, mut b) = (0, n);
        while a < n && is_ws(p[a]) {
            a += 1;
        }
        while b > a && is_ws(p[b - 1]) {
            b -= 1;
        }
        sub_bytes(s, a, b)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_lines(s: *const AukStr) -> *mut AukArr {
    unsafe {
        let mut out = crate::arr::auk_arr_new(&crate::rc::auk_ops_str, 0);
        let p = sbytes(s);
        let n = p.len();
        let mut st = 0;
        while st < n {
            let end = match p[st..].iter().position(|&c| c == b'\n') {
                Some(k) => st + k,
                None => n,
            };
            let mut e = end;
            if e > st && p[e - 1] == b'\r' {
                e -= 1;
            }
            push_own(&mut out, sub_bytes(s, st, e));
            st = end + 1;
        }
        out
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_starts_with(s: *const AukStr, pre: *const AukStr) -> bool {
    unsafe { sbytes(s).starts_with(sbytes(pre)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_ends_with(s: *const AukStr, suf: *const AukStr) -> bool {
    unsafe { sbytes(s).ends_with(sbytes(suf)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_contains(s: *const AukStr, sub: *const AukStr) -> bool {
    unsafe { find_bytes(sbytes(s), sbytes(sub), 0) >= 0 }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_find(s: *const AukStr, sub: *const AukStr) -> AukOpt_int {
    unsafe {
        let p = sbytes(s);
        let at = find_bytes(p, sbytes(sub), 0);
        if at < 0 {
            return AukOpt::none();
        }
        AukOpt::some(if !s.is_null() && (*s).is_ascii { at } else { chars_in(&p[..at as usize]) })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_replace(s: *const AukStr, from: *const AukStr, to: *const AukStr) -> *mut AukStr {
    unsafe {
        let f = sbytes(from);
        let p = sbytes(s);
        if f.is_empty() {
            return if s.is_null() { auk_str_lit(c"".as_ptr()) } else { auk_retain(s as *mut c_void).cast() };
        }
        let mut b = AukStrBuf::INIT;
        let mut st = 0usize;
        loop {
            let at = find_bytes(p, f, st as i64);
            if at < 0 {
                break;
            }
            sb_bytes(&mut b, &p[st..at as usize]);
            auk_sb_str(&mut b, to);
            st = at as usize + f.len();
        }
        sb_bytes(&mut b, &p[st..]);
        auk_sb_finish(&mut b)
    }
}

unsafe fn map_ascii(s: *const AukStr, up: bool) -> *mut AukStr {
    unsafe {
        let r = str_raw(sbytes(s), auk_str_len(s), is_ascii(s));
        let n = (*r).len_bytes as usize;
        let d = std::slice::from_raw_parts_mut((*r).data.as_mut_ptr(), n);
        for c in d.iter_mut() {
            if up && c.is_ascii_lowercase() {
                *c -= 32;
            }
            if !up && c.is_ascii_uppercase() {
                *c += 32;
            }
        }
        r
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_upper(s: *const AukStr) -> *mut AukStr {
    unsafe { map_ascii(s, true) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_lower(s: *const AukStr) -> *mut AukStr {
    unsafe { map_ascii(s, false) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_repeat(s: *const AukStr, n: i64, loc: *const c_char) -> *mut AukStr {
    unsafe {
        if n < 0 {
            rt_panic!(loc, "repeat count {n} is negative");
        }
        let src = sbytes(s);
        let bl = src.len() as i64;
        let total = match bl.checked_mul(n) {
            Some(t) => t,
            None => crate::rc::auk_panic_overflow(loc, c"repeat".as_ptr()),
        };
        let r = auk__alloc(size_of::<AukStr>() + total as usize + 1, AUK_K_STR) as *mut AukStr;
        let d = (*r).data.as_mut_ptr();
        if bl > 0 {
            for i in 0..n {
                std::ptr::copy_nonoverlapping(src.as_ptr(), d.add((i * bl) as usize), bl as usize);
            }
        }
        *d.add(total as usize) = 0;
        (*r).len_bytes = total;
        (*r).len_chars = auk_str_len(s).wrapping_mul(n);
        (*r).is_ascii = is_ascii(s);
        r
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_chars(s: *const AukStr) -> *mut AukArr {
    unsafe {
        let n = auk_str_len(s);
        let mut out = crate::arr::auk_arr_new(&crate::rc::auk_ops_char, n);
        let d = crate::arr::auk_arr_make_unique(&mut out) as *mut u32;
        let p = sbytes(s);
        let (mut i, mut k) = (0usize, 0usize);
        while i < p.len() {
            let (c, len) = utf8_decode(p, i);
            *d.add(k) = c;
            k += 1;
            i += len;
        }
        (*out).len = k as i64;
        out
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_bytes(s: *const AukStr) -> *mut AukArr {
    unsafe {
        let p = sbytes(s);
        let n = p.len() as i64;
        let mut out = crate::arr::auk_arr_new(&crate::rc::auk_ops_int, n);
        let d = crate::arr::auk_arr_make_unique(&mut out) as *mut i64;
        for (i, &c) in p.iter().enumerate() {
            *d.add(i) = c as i64;
        }
        (*out).len = n;
        out
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_from_chars(chars: *mut AukArr) -> *mut AukStr {
    unsafe {
        let mut b = AukStrBuf::INIT;
        let cs = arr_data(chars) as *const u32;
        for i in 0..arr_len(chars) {
            auk_sb_char(&mut b, *cs.add(i as usize));
        }
        auk_sb_finish(&mut b)
    }
}

// ---- parsing -----------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_int_parse(s: *const AukStr) -> AukRes_int {
    let p = unsafe { sbytes(s) };
    let shown = || String::from_utf8_lossy(upto_nul(p)).into_owned();
    let bad = || AukRes::err(crate::err::err_msg(&format!("int.parse: invalid int \"{}\"", shown())));
    let n = p.len();
    let mut i = 0;
    let mut neg = false;
    if i < n && (p[i] == b'+' || p[i] == b'-') {
        neg = p[i] == b'-';
        i += 1;
    }
    if i >= n {
        return bad();
    }
    let mut acc: u64 = 0;
    let limit: u64 = if neg { i64::MAX as u64 + 1 } else { i64::MAX as u64 };
    let mut prev_digit = false;
    while i < n {
        let c = p[i];
        if c == b'_' && prev_digit && i + 1 < n && p[i + 1].is_ascii_digit() {
            prev_digit = false;
            i += 1;
            continue;
        }
        if !c.is_ascii_digit() {
            return bad();
        }
        let d = (c - b'0') as u64;
        if acc > (limit - d) / 10 {
            return AukRes::err(crate::err::err_msg(&format!("int.parse: \"{}\" is out of range", shown())));
        }
        acc = acc * 10 + d;
        prev_digit = true;
        i += 1;
    }
    if neg {
        return AukRes::ok(if acc == i64::MAX as u64 + 1 { i64::MIN } else { -(acc as i64) });
    }
    AukRes::ok(acc as i64)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_float_parse(s: *const AukStr) -> AukRes_float {
    unsafe {
        let p = sbytes(s);
        let n = p.len();
        let bad = || {
            AukRes::err(crate::err::err_msg(&format!(
                "float.parse: invalid float \"{}\"",
                String::from_utf8_lossy(upto_nul(p))
            )))
        };
        if n == 0 || is_ws(p[0]) || upto_nul(p).len() != n {
            return bad();
        }
        // reject hex floats and other strtod extras
        if p.iter().any(|&c| c == b'x' || c == b'X' || c == b'(') {
            return bad();
        }
        let cp = auk_str_cstr(s);
        let mut end: *mut c_char = null_mut();
        let d = libc::strtod(cp, &mut end);
        if !std::ptr::eq(end, cp.add(n)) {
            return bad();
        }
        AukRes::ok(d)
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_char_is_digit(c: u32) -> bool {
    (b'0' as u32..=b'9' as u32).contains(&c)
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_char_is_alpha(c: u32) -> bool {
    (b'a' as u32..=b'z' as u32).contains(&c) || (b'A' as u32..=b'Z' as u32).contains(&c)
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_char_is_space(c: u32) -> bool {
    c < 128 && is_ws(c as u8)
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_char_upper(c: u32) -> u32 {
    if (b'a' as u32..=b'z' as u32).contains(&c) { c - 32 } else { c }
}
#[unsafe(no_mangle)]
pub extern "C" fn auk_char_lower(c: u32) -> u32 {
    if (b'A' as u32..=b'Z' as u32).contains(&c) { c + 32 } else { c }
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_char_from_int(n: i64) -> AukOpt_char {
    if !(0..=0x10FFFF).contains(&n) || (0xD800..=0xDFFF).contains(&n) {
        return AukOpt::none();
    }
    AukOpt::some(n as u32)
}

// ---- formatting --------------------------------------------------------------------------

/// `v` in decimal, written into the end of `buf`; returns where it starts.
fn int_digits(v: i64, buf: &mut [u8; 20]) -> usize {
    let mut i = buf.len();
    let mut n = v.unsigned_abs();
    loop {
        i -= 1;
        buf[i] = b'0' + (n % 10) as u8;
        n /= 10;
        if n == 0 {
            break;
        }
    }
    if v < 0 {
        i -= 1;
        buf[i] = b'-';
    }
    i
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_str_from_int(v: i64) -> *mut AukStr {
    let mut buf = [0u8; 20];
    let at = int_digits(v, &mut buf);
    str_raw(&buf[at..], (buf.len() - at) as i64, true)
}

/// Append `v` in decimal (what interpolating an int does: no temporary string).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_sb_int(b: *mut AukStrBuf, v: i64) {
    let mut buf = [0u8; 20];
    let at = int_digits(v, &mut buf);
    unsafe { sb_put(b, &buf[at..]) }
}

/// C's `snprintf(buf, .., "%.*e", prec, v)`.
fn c_fmt_e(prec: c_int, v: f64) -> Vec<u8> {
    let mut buf = [0u8; 64];
    let n = unsafe { libc::snprintf(buf.as_mut_ptr().cast(), buf.len(), c"%.*e".as_ptr(), prec, v) };
    buf[..(n.max(0) as usize).min(63)].to_vec()
}

/// Shortest round-trip float text (see auk_str_from_float).
pub fn fmt_float_shortest(v: f64) -> String {
    if v.is_nan() {
        return "NaN".into();
    }
    if v.is_infinite() {
        return if v < 0.0 { "-inf" } else { "inf" }.into();
    }
    if v == 0.0 {
        return if v.is_sign_negative() { "-0.0" } else { "0.0" }.into();
    }
    // The C version tries `%.*e` with prec = 0, 1, .. 17 until strtod round-trips. Rust's `{:e}`
    // gives the shortest round-trip digit count n, and no prec below n-1 can round-trip, so start
    // the same search at n-1: the result is byte-identical, in one or two snprintf calls.
    let rust = format!("{:e}", v);
    let mant = rust.split('e').next().unwrap_or("");
    let n = mant.bytes().filter(|c| c.is_ascii_digit()).count() as c_int;
    let mut tmp = Vec::new();
    let mut prec = (n - 1).max(0);
    while prec <= 17 {
        tmp = c_fmt_e(prec, v);
        let mut z = tmp.clone();
        z.push(0);
        if unsafe { libc::strtod(z.as_ptr().cast(), null_mut()) } == v {
            break;
        }
        prec += 1;
    }
    // tmp = [-]d[.ddd]e(+|-)XX
    let mut p = 0usize;
    let neg = tmp.first() == Some(&b'-');
    if neg {
        p += 1;
    }
    let mut digits: Vec<u8> = Vec::new();
    while p < tmp.len() && tmp[p] != b'e' {
        if tmp[p] != b'.' {
            digits.push(tmp[p]);
        }
        p += 1;
    }
    while digits.len() > 1 && *digits.last().unwrap() == b'0' {
        digits.pop();
    }
    let nd = digits.len() as i32;
    let exp: i32 = std::str::from_utf8(&tmp[(p + 1).min(tmp.len())..]).ok().and_then(|e| e.parse().ok()).unwrap_or(0);
    let mut res: Vec<u8> = Vec::new();
    if neg {
        res.push(b'-');
    }
    if !(-6..21).contains(&exp) {
        res.push(digits[0]);
        if nd > 1 {
            res.push(b'.');
            res.extend_from_slice(&digits[1..]);
        }
        res.extend_from_slice(format!("e{exp}").as_bytes());
    } else {
        let point = exp + 1; // digits before the decimal point
        if point <= 0 {
            res.extend_from_slice(b"0.");
            res.extend(std::iter::repeat_n(b'0', (-point) as usize));
            res.extend_from_slice(&digits);
        } else if point >= nd {
            res.extend_from_slice(&digits);
            res.extend(std::iter::repeat_n(b'0', (point - nd) as usize));
            res.extend_from_slice(b".0");
        } else {
            res.extend_from_slice(&digits[..point as usize]);
            res.push(b'.');
            res.extend_from_slice(&digits[point as usize..]);
        }
    }
    String::from_utf8(res).unwrap_or_default()
}

pub unsafe fn auk__fmt_float_shortest(v: f64, out: *mut c_char, outn: usize) {
    if outn == 0 {
        return;
    }
    let s = fmt_float_shortest(v);
    let n = s.len().min(outn - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(s.as_ptr(), out.cast(), n);
        *out.add(n) = 0;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_str_from_float(v: f64) -> *mut AukStr {
    let s = fmt_float_shortest(v);
    str_raw(s.as_bytes(), s.len() as i64, true)
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_str_from_char(c: u32) -> *mut AukStr {
    let mut b = [0u8; 4];
    let n = utf8_encode(c, &mut b);
    str_raw(&b[..n], 1, n == 1)
}

#[unsafe(no_mangle)]
pub extern "C" fn auk_str_from_bool(b: bool) -> *mut AukStr {
    str_from_bytes(if b { b"true" } else { b"false" })
}

unsafe fn quote_char(b: *mut AukStrBuf, c: u32, q: u8) {
    unsafe {
        match c {
            0x0A => return sb_bytes(b, b"\\n"),
            0x09 => return sb_bytes(b, b"\\t"),
            0x0D => return sb_bytes(b, b"\\r"),
            0x00 => return sb_bytes(b, b"\\0"),
            0x5C => return sb_bytes(b, b"\\\\"),
            _ => {}
        }
        if c == q as u32 {
            auk_sb_char(b, '\\' as u32);
            auk_sb_char(b, c);
        } else if c < 0x20 || c == 0x7F {
            sb_push_str(b, &format!("\\u{{{c:X}}}"));
        } else {
            auk_sb_char(b, c);
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_str_quote(s: *const AukStr) -> *mut AukStr {
    unsafe {
        let mut b = AukStrBuf::INIT;
        auk_sb_char(&mut b, '"' as u32);
        let p = sbytes(s);
        let mut i = 0;
        while i < p.len() && !crate::trace::show_exhausted() {
            let (c, len) = utf8_decode(p, i);
            quote_char(&mut b, c, b'"');
            i += len;
        }
        auk_sb_char(&mut b, '"' as u32);
        auk_sb_finish(&mut b)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_char_quote(c: u32) -> *mut AukStr {
    unsafe {
        let mut b = AukStrBuf::INIT;
        auk_sb_char(&mut b, '\'' as u32);
        quote_char(&mut b, c, b'\'');
        auk_sb_char(&mut b, '\'' as u32);
        auk_sb_finish(&mut b)
    }
}

// ---- format specs ------------------------------------------------------------------------

struct Spec {
    fill: u32,
    align: u8, // 0, '<', '>', '^'
    zero: bool,
    width: i64, // -1 = none
    prec: i64,  // -1 = none
}

unsafe fn parse_spec(spec: *const c_char) -> Spec {
    let mut sp = Spec { fill: ' ' as u32, align: 0, zero: false, width: -1, prec: -1 };
    if spec.is_null() {
        return sp;
    }
    let s = unsafe { cbytes(spec) };
    let at = |i: usize| s.get(i).copied().unwrap_or(0);
    let bad = || -> ! { rt_panic!(c"format".as_ptr(), "bad format spec \"{}\"", String::from_utf8_lossy(s)) };
    let mut p = 0usize;
    if at(0) != 0 {
        let (c, len) = utf8_decode(s, 0);
        let a = at(len);
        if a == b'<' || a == b'>' || a == b'^' {
            sp.fill = c;
            sp.align = a;
            p = len + 1;
        } else if matches!(at(0), b'<' | b'>' | b'^') {
            sp.align = at(0);
            p = 1;
        }
    }
    if at(p) == b'0' {
        sp.zero = true;
        p += 1;
    }
    if at(p).is_ascii_digit() {
        sp.width = 0;
        while at(p).is_ascii_digit() {
            sp.width = sp.width.wrapping_mul(10).wrapping_add((at(p) - b'0') as i64);
            p += 1;
        }
    }
    if at(p) == b'.' {
        p += 1;
        if !at(p).is_ascii_digit() {
            bad();
        }
        sp.prec = 0;
        while at(p).is_ascii_digit() {
            sp.prec = sp.prec.wrapping_mul(10).wrapping_add((at(p) - b'0') as i64);
            p += 1;
        }
    }
    if at(p) != 0 {
        bad();
    }
    if sp.width > 1 << 20 || sp.prec > 1 << 20 {
        rt_panic!(c"format".as_ptr(), "format spec \"{}\" is too large", String::from_utf8_lossy(s));
    }
    sp
}

/// Pad body (owned, consumed) according to sp.
unsafe fn pad(body: *mut AukStr, sp: &Spec, numeric: bool) -> *mut AukStr {
    unsafe {
        let n = auk_str_len(body);
        if sp.width <= n {
            return body;
        }
        let extra = sp.width - n;
        let mut b = AukStrBuf::INIT;
        let p = sbytes(body);
        if numeric && sp.zero && sp.align == 0 {
            let mut i = 0;
            if matches!(p.first(), Some(b'-' | b'+')) {
                sb_bytes(&mut b, &p[..1]);
                i = 1;
            }
            for _ in 0..extra {
                auk_sb_char(&mut b, '0' as u32);
            }
            sb_bytes(&mut b, &p[i..]);
        } else {
            let al = if sp.align != 0 { sp.align } else if numeric { b'>' } else { b'<' };
            let left = if al == b'>' { extra } else if al == b'^' { extra / 2 } else { 0 };
            for _ in 0..left {
                auk_sb_char(&mut b, sp.fill);
            }
            auk_sb_str(&mut b, body);
            for _ in 0..extra - left {
                auk_sb_char(&mut b, sp.fill);
            }
        }
        auk_release(body.cast());
        auk_sb_finish(&mut b)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_fmt_int(v: i64, spec: *const c_char) -> *mut AukStr {
    unsafe {
        let sp = parse_spec(spec);
        pad(auk_str_from_int(v), &sp, true)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_fmt_float(v: f64, spec: *const c_char) -> *mut AukStr {
    unsafe {
        let sp = parse_spec(spec);
        let body = if sp.prec >= 0 && v.is_finite() {
            let prec = sp.prec as c_int;
            let n = libc::snprintf(null_mut(), 0, c"%.*f".as_ptr(), prec, v);
            let buf = auk__xmalloc(n as usize + 1) as *mut c_char;
            libc::snprintf(buf, n as usize + 1, c"%.*f".as_ptr(), prec, v);
            let r = auk__str_raw(buf, n as i64, n as i64, true);
            libc::free(buf.cast());
            r
        } else {
            auk_str_from_float(v)
        };
        pad(body, &sp, true)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_fmt_str(s: *const AukStr, spec: *const c_char) -> *mut AukStr {
    unsafe {
        let sp = parse_spec(spec);
        let body = if sp.prec >= 0 && sp.prec < auk_str_len(s) {
            auk_str_slice(s, 0, sp.prec, std::ptr::null())
        } else if s.is_null() {
            auk_str_lit(c"".as_ptr())
        } else {
            auk_retain(s as *mut c_void).cast()
        };
        pad(body, &sp, false)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_fmt_char(c: u32, spec: *const c_char) -> *mut AukStr {
    unsafe {
        let sp = parse_spec(spec);
        pad(auk_str_from_char(c), &sp, false)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_fmt_bool(v: bool, spec: *const c_char) -> *mut AukStr {
    unsafe {
        let sp = parse_spec(spec);
        pad(auk_str_from_bool(v), &sp, false)
    }
}

// ---- builder -----------------------------------------------------------------------------

/// Where the builder's text is: its inline bytes or its heap buffer.
unsafe fn sb_data(b: *mut AukStrBuf) -> *mut u8 {
    unsafe { if (*b).buf.is_null() { (*b).small.as_mut_ptr() } else { (*b).buf } }
}

unsafe fn sb_reserve(b: *mut AukStrBuf, extra: i64) {
    unsafe {
        let b = &mut *b;
        if b.buf.is_null() {
            // inline until the text outgrows it, then to the heap with what's there
            if b.len + extra <= AUK_SB_SMALL as i64 {
                return;
            }
            let mut cap = 2 * AUK_SB_SMALL as i64;
            while cap < b.len + extra + 1 {
                cap *= 2;
            }
            let heap: *mut u8 = auk__xrealloc(std::ptr::null_mut(), cap as usize).cast();
            std::ptr::copy_nonoverlapping(b.small.as_ptr(), heap, b.len as usize);
            b.buf = heap;
            b.cap = cap;
            return;
        }
        if b.len + extra < b.cap {
            return;
        }
        let mut cap = b.cap * 2;
        while cap < b.len + extra + 1 {
            cap *= 2;
        }
        b.buf = auk__xrealloc(b.buf.cast(), cap as usize).cast();
        b.cap = cap;
    }
}

unsafe fn sb_put(b: *mut AukStrBuf, p: &[u8]) {
    if p.is_empty() {
        return;
    }
    unsafe {
        sb_reserve(b, p.len() as i64);
        std::ptr::copy_nonoverlapping(p.as_ptr(), sb_data(b).add((*b).len as usize), p.len());
        (*b).len += p.len() as i64;
    }
}

/// `auk_sb_bytes` for a Rust slice. Pieces of text count against a trace's show budget;
/// whole strings (a part already built, e.g. a field's show) don't, so a capped show is an
/// exact prefix of the full one.
pub unsafe fn sb_bytes(b: *mut AukStrBuf, p: &[u8]) {
    if crate::trace::show_take(p.len() as i64) {
        unsafe { sb_put(b, p) }
    }
}

/// Replacement for C's `auk_sb_printf`: format with `format!`, then push here.
pub unsafe fn sb_push_str(b: *mut AukStrBuf, s: &str) {
    if !s.is_empty() && crate::trace::show_take(s.len() as i64) {
        unsafe { sb_put(b, s.as_bytes()) }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_sb_bytes(b: *mut AukStrBuf, p: *const c_char, n: i64) {
    if crate::trace::show_take(n) {
        unsafe { sb_put(b, raw(p, n)) }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_sb_lit(b: *mut AukStrBuf, cstr: *const c_char) {
    unsafe { sb_bytes(b, cbytes(cstr)) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_sb_str(b: *mut AukStrBuf, s: *const AukStr) {
    unsafe { sb_put(b, sbytes(s)) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_sb_str_own(b: *mut AukStrBuf, s: *mut AukStr) {
    unsafe {
        auk_sb_str(b, s);
        auk_release(s.cast());
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_sb_char(b: *mut AukStrBuf, c: u32) {
    let mut buf = [0u8; 4];
    let n = utf8_encode(c, &mut buf);
    unsafe { sb_bytes(b, &buf[..n]) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_sb_finish(b: *mut AukStrBuf) -> *mut AukStr {
    unsafe {
        let s = str_from_bytes(raw(sb_data(b) as *const c_char, (*b).len));
        auk_sb_free(b);
        s
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_sb_free(b: *mut AukStrBuf) {
    unsafe {
        if !(*b).buf.is_null() {
            libc::free((*b).buf.cast());
        }
        (*b).buf = std::ptr::null_mut();
        (*b).len = 0;
        (*b).cap = 0;
    }
}
