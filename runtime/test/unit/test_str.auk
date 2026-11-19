/// str: UTF-8, indexing, searching, parsing and formatting (was runtime/c/test/test_str.c).

fn valid(b: ut.Bytes): bool uses raw, ffi = rt.auk_utf8_valid(b.p, b.n, raw.null(), raw.null())

/// auk_utf8_valid with its outputs: ok, chars, ascii must match (C's CHECK_V).
fn check_v(lit: raw.Ptr<u8>, w_ok: bool, w_chars: i64, w_ascii: bool) uses raw, ffi {
  let b = ut.bin(lit)
  var chars: i64 = -1
  var ascii = false
  let ok_ = rt.auk_utf8_valid(b.p, b.n, raw.addr_of(&chars), raw.addr_of(&ascii))
  ut.check(ok_ == w_ok && chars == w_chars && ascii == w_ascii, lit)
}

fn str_utf8_validation() uses raw, ffi {
  var chars: i64 = -1
  var ascii = false
  let pc = raw.addr_of(&chars)
  let pa = raw.addr_of(&ascii)
  check_v("", true, 0, true)
  check_v("abc", true, 3, true)
  check_v("h\\xC3\\xA9", true, 2, false) // hé
  let duck = ut.bin("\\xF0\\x9F\\xA6\\x86")
  ut.check(rt.auk_utf8_valid(duck.p, duck.n, pc, pa) && chars == 1, "auk_utf8_valid(🦆) && chars == 1")
  let euro = ut.bin("\\xE2\\x82\\xAC")
  ut.check(rt.auk_utf8_valid(euro.p, euro.n, pc, pa) && chars == 1, "auk_utf8_valid(€) && chars == 1")
  let max = ut.bin("\\xF4\\x8F\\xBF\\xBF")
  ut.check(rt.auk_utf8_valid(max.p, max.n, pc, pa), "auk_utf8_valid(U+10FFFF)")
  ut.check(valid(ut.bin("\\xEF\\xBF\\xBF")), "valid(U+FFFF)")
  ut.check(!valid(ut.bin("\\xC0\\x80")), "!valid(overlong NUL)")
  ut.check(!valid(ut.bin("\\xE0\\x80\\xAF")), "!valid(overlong '/')")
  ut.check(!valid(ut.bin("\\xF0\\x80\\x80\\xAF")), "!valid(overlong 4-byte)")
  ut.check(!valid(ut.bin("\\xED\\xA0\\x80")), "!valid(surrogate)")
  ut.check(!valid(ut.bin("\\xF4\\x90\\x80\\x80")), "!valid(> U+10FFFF)")
  ut.check(!valid(ut.bin("\\xC3")), "!valid(truncated)")
  ut.check(!valid(ut.bin("\\xE2\\x82")), "!valid(truncated)")
  ut.check(!valid(ut.bin("\\x80")), "!valid(lone continuation)")
  ut.check(!valid(ut.bin("a\\xFF")), "!valid(a\\xFF)")
  ut.check(!valid(ut.bin("\\xC3\\x28")), "!valid(bad continuation)")
  chars = 0
  let nul = ut.bin("a\\x00b")
  ut.check(rt.auk_utf8_valid(nul.p, nul.n, pc, raw.null()) && chars == 3, "auk_utf8_valid(a\\0b) && chars == 3")
}

fn str_construct_and_repair() uses raw, ffi {
  let fb = ut.bin("a\\xFFb")
  let x = rt.auk_str_from_bytes(fb.p, fb.n)
  ut.check(rt.auk_str_len(x) == 3, "auk_str_len(x) == 3")
  ut.check(!x.is_ascii, "!x->is_ascii")
  ut.str_eq(x, "a\u{FFFD}b", "x") // a U+FFFD b
  let tb = ut.bin("ab\\xC3")
  var r = rt.auk_str_try_from_bytes(tb.p, tb.n)
  ut.check(!r.ok, "!r.ok")
  ut.str_eq(rt.auk_err_show(r.err), "invalid UTF-8 at byte 2", "auk_err_show(r.err)")
  ut.rel(raw.cast(r.err))
  let eb = ut.bin("\\xC3\\xA9")
  r = rt.auk_str_try_from_bytes(eb.p, eb.n)
  ut.check(r.ok && rt.auk_str_len(r.val) == 1, "r.ok && auk_str_len(r.val) == 1")
  ut.rel(raw.cast(r.val))
  let e = ut.s("")
  ut.check(rt.auk_str_len(e) == 0 && rt.auk_str_byte_len(e) == 0 && e.is_ascii, "auk_str_len(e) == 0 && auk_str_byte_len(e) == 0 && e->is_ascii")
  ut.rel(raw.cast(e))
  // NULL is the empty string
  ut.check(rt.auk_str_len(raw.null()) == 0, "auk_str_len(NULL) == 0")
  ut.check(rt.auk_str_eq(raw.null(), raw.null()), "auk_str_eq(NULL, NULL)")
  ut.str_eq(rt.auk_str_concat(raw.null(), raw.null()), "", "auk_str_concat(NULL, NULL)")
}

fn str_char_indexing() uses raw, ffi {
  let a = ut.s("hello")
  ut.check(a.is_ascii, "a->is_ascii")
  ut.check(rt.auk_str_char_at(a, 0, "t") == 104, "auk_str_char_at(a, 0, T) == 'h'")
  ut.check(rt.auk_str_char_at(a, 4, "t") == 111, "auk_str_char_at(a, 4, T) == 'o'")
  let u = ut.s("héllo 🦆!")
  ut.check(rt.auk_str_len(u) == 8, "auk_str_len(u) == 8")
  ut.check(rt.auk_str_byte_len(u) == 12, "auk_str_byte_len(u) == 12")
  ut.check(rt.auk_str_char_at(u, 1, "t") == 0xE9, "auk_str_char_at(u, 1, T) == 0xE9")
  ut.check(rt.auk_str_char_at(u, 6, "t") == 0x1F986, "auk_str_char_at(u, 6, T) == 0x1F986")
  ut.check(rt.auk_str_char_at(u, 7, "t") == 33, "auk_str_char_at(u, 7, T) == '!'")
  ut.check(!rt.auk_str_get(u, 8).some, "!auk_str_get(u, 8).some")
  ut.check(!rt.auk_str_get(u, -1).some, "!auk_str_get(u, -1).some")
  ut.check(rt.auk_str_get(u, 2).some && rt.auk_str_get(u, 2).val == 108, "auk_str_get(u, 2).some && auk_str_get(u, 2).val == 'l'")
  ut.str_eq(rt.auk_str_slice(u, 1, 3, "t"), "él", "auk_str_slice(u, 1, 3, T)")
  ut.str_eq(rt.auk_str_slice(u, 6, 8, "t"), "🦆!", "auk_str_slice(u, 6, 8, T)")
  ut.str_eq(rt.auk_str_slice(u, 3, 3, "t"), "", "auk_str_slice(u, 3, 3, T)")
  let whole = rt.auk_str_slice(u, 0, 8, "t")
  ut.check(whole == u, "whole == u") // full slice shares
  ut.rel(raw.cast(whole))
  ut.str_eq(rt.auk_str_slice(a, 1, 4, "t"), "ell", "auk_str_slice(a, 1, 4, T)")
  ut.rel(raw.cast(a))
  ut.rel(raw.cast(u))
}

fn char_at_oob(ctx: raw.Ptr<()>) uses ffi {
  let x = ut.s("hé")
  let _ = rt.auk_str_char_at(x, 2, "main.auk:3:7")
}

fn slice_backwards(ctx: raw.Ptr<()>) uses ffi {
  let x = ut.s("abc")
  let _ = rt.auk_str_slice(x, 2, 1, "main.auk:4:1")
}

fn str_index_panics() uses raw, ffi {
  ut.expect_panic(raw.fn_of(char_at_oob), raw.null(), "index 2 out of range for string of length 2\n  at main.auk:3:7")
  ut.expect_panic(raw.fn_of(slice_backwards), raw.null(), "slice 2..1 out of range")
}

fn str_concat_eq_cmp_hash() uses raw, ffi {
  let a = ut.s("ab")
  let b = ut.s("é")
  let c = rt.auk_str_concat(a, b)
  ut.check(rt.auk_str_len(c) == 3 && !c.is_ascii, "auk_str_len(c) == 3 && !c->is_ascii")
  let c2 = ut.s("abé")
  ut.check(rt.auk_str_eq(c, c2), "auk_str_eq(c, c2)")
  ut.check(rt.auk_str_hash(c) == rt.auk_str_hash(c2), "auk_str_hash(c) == auk_str_hash(c2)")
  ut.check(rt.auk_str_cmp(a, c) < 0, "auk_str_cmp(a, c) < 0")
  ut.check(rt.auk_str_cmp(c, a) > 0, "auk_str_cmp(c, a) > 0")
  ut.check(rt.auk_str_cmp(c, c2) == 0, "auk_str_cmp(c, c2) == 0")
  let z = ut.s("z")
  ut.check(rt.auk_str_cmp(z, b) < 0, "auk_str_cmp(z, b) < 0") // 'z' < 'é' by code point
  ut.check(rt.auk_str_eq_lit(a, "ab") && !rt.auk_str_eq_lit(a, "abc"), "auk_str_eq_lit(a, \"ab\") && !auk_str_eq_lit(a, \"abc\")")
  ut.rel(raw.cast(a))
  ut.rel(raw.cast(b))
  ut.rel(raw.cast(c))
  ut.rel(raw.cast(c2))
  ut.rel(raw.cast(z))
}

/// Join an owned array with "|", releasing it.
fn join_arr(a: raw.Ptr<abi.Arr>): raw.Ptr<abi.Str> uses raw, ffi {
  let sep = ut.s("|")
  let r = rt.auk_arr_join(a, sep)
  ut.rel(raw.cast(sep))
  ut.rel(raw.cast(a))
  r
}

fn str_split_trim_lines() uses raw, ffi {
  let x = ut.s("  the quick\t brown\n fox  ")
  ut.str_eq(join_arr(rt.auk_str_split_ws(x)), "the|quick|brown|fox", "auk_str_split_ws(x)")
  ut.str_eq(rt.auk_str_trim(x), "the quick\t brown\n fox", "auk_str_trim(x)")
  ut.str_eq(rt.auk_str_trim_start(x), "the quick\t brown\n fox  ", "auk_str_trim_start(x)")
  ut.str_eq(rt.auk_str_trim_end(x), "  the quick\t brown\n fox", "auk_str_trim_end(x)")
  ut.rel(raw.cast(x))

  let e = ut.s("")
  let ea = rt.auk_str_split_ws(e)
  ut.check(rt.auk_arr_len(ea) == 0, "auk_arr_len(ea) == 0")
  ut.rel(raw.cast(ea))
  let comma = ut.s(",")
  let one = rt.auk_str_split(e, comma)
  ut.check(rt.auk_arr_len(one) == 1, "auk_arr_len(one) == 1")
  ut.rel(raw.cast(one))
  ut.rel(raw.cast(e))

  let csv = ut.s("a,,b,")
  ut.str_eq(join_arr(rt.auk_str_split(csv, comma)), "a||b|", "auk_str_split(csv, comma)")
  ut.rel(raw.cast(csv))
  ut.rel(raw.cast(comma))

  let u = ut.s("x→y→z")
  let arrow = ut.s("→")
  let empty = ut.s("")
  let parts = rt.auk_str_split(u, arrow)
  ut.check(rt.auk_arr_len(parts) == 3, "auk_arr_len(parts) == 3")
  ut.check(rt.auk_str_len(raw.cast(ut.at_ptr(parts, 1))) == 1, "auk_str_len(AT(AukStr *, parts, 1)) == 1")
  ut.rel(raw.cast(parts))
  ut.str_eq(join_arr(rt.auk_str_split(u, empty)), "x|→|y|→|z", "auk_str_split(u, empty)")
  ut.rel(raw.cast(u))
  ut.rel(raw.cast(arrow))
  ut.rel(raw.cast(empty))

  var t = ut.s("one\r\ntwo\n\nthree\n")
  ut.str_eq(join_arr(rt.auk_str_lines(t)), "one|two||three", "auk_str_lines(t)")
  ut.rel(raw.cast(t))
  t = ut.s("no newline")
  ut.str_eq(join_arr(rt.auk_str_lines(t)), "no newline", "auk_str_lines(t)")
  ut.rel(raw.cast(t))
}

fn str_search_replace() uses raw, ffi {
  let x = ut.s("héllo wörld")
  let p = ut.s("hé")
  let q = ut.s("rld")
  let w = ut.s("wö")
  let no = ut.s("xyz")
  let e = ut.s("")
  ut.check(rt.auk_str_starts_with(x, p) && !rt.auk_str_starts_with(p, x), "auk_str_starts_with(x, p) && !auk_str_starts_with(p, x)")
  ut.check(rt.auk_str_ends_with(x, q) && !rt.auk_str_ends_with(x, p), "auk_str_ends_with(x, q) && !auk_str_ends_with(x, p)")
  ut.check(
    rt.auk_str_contains(x, w) && !rt.auk_str_contains(x, no) && rt.auk_str_contains(x, e),
    "auk_str_contains(x, w) && !auk_str_contains(x, no) && auk_str_contains(x, e)",
  )
  let f = rt.auk_str_find(x, w)
  ut.check(f.some && f.val == 6, "f.some && f.val == 6") // char index, not byte index (7)
  ut.check(!rt.auk_str_find(x, no).some, "!auk_str_find(x, no).some")
  let l = ut.s("l")
  let ll = ut.s("LL")
  ut.str_eq(rt.auk_str_replace(x, l, ll), "héLLLLo wörLLd", "auk_str_replace(x, l, ll)")
  ut.str_eq(rt.auk_str_replace(x, e, ll), "héllo wörld", "auk_str_replace(x, e, ll)")
  ut.str_eq(rt.auk_str_replace(x, no, ll), "héllo wörld", "auk_str_replace(x, no, ll)")
  let aaaa = ut.s("aaaa")
  let aa = ut.s("aa")
  let b = ut.s("b")
  ut.str_eq(rt.auk_str_replace(aaaa, aa, b), "bb", "auk_str_replace(aaaa, aa, b)")
  ut.str_eq(rt.auk_str_upper(x), "HéLLO WöRLD", "auk_str_upper(x)")
  let mixed = ut.s("MiXeD Été")
  ut.str_eq(rt.auk_str_lower(mixed), "mixed Été", "auk_str_lower(mixed)")
  ut.str_eq(rt.auk_str_repeat(aa, 3, "t"), "aaaaaa", "auk_str_repeat(aa, 3, T)")
  ut.rel(raw.cast(x))
  ut.rel(raw.cast(p))
  ut.rel(raw.cast(q))
  ut.rel(raw.cast(w))
  ut.rel(raw.cast(no))
  ut.rel(raw.cast(e))
  ut.rel(raw.cast(l))
  ut.rel(raw.cast(ll))
  ut.rel(raw.cast(aaaa))
  ut.rel(raw.cast(aa))
  ut.rel(raw.cast(b))
  ut.rel(raw.cast(mixed))
}

fn str_chars_bytes_utf8() uses raw, ffi {
  let x = ut.s("aé🦆")
  let cs = rt.auk_str_chars(x)
  ut.check(rt.auk_arr_len(cs) == 3, "auk_arr_len(cs) == 3")
  ut.check(ut.at_u32(cs, 0) == 97, "AT(uint32_t, cs, 0) == 'a'")
  ut.check(ut.at_u32(cs, 1) == 0xE9, "AT(uint32_t, cs, 1) == 0xE9")
  ut.check(ut.at_u32(cs, 2) == 0x1F986, "AT(uint32_t, cs, 2) == 0x1F986")
  ut.str_eq(rt.auk_str_from_chars(cs), "aé🦆", "auk_str_from_chars(cs)")
  ut.str_eq(rt.auk_arr_show(cs), "['a', 'é', '🦆']", "auk_arr_show(cs)")
  let back = rt.auk_str_from_chars(cs)
  ut.check(back.len_bytes == 7 && back.len_chars == 3 && !back.is_ascii, "back->len_bytes == 7 && back->len_chars == 3 && !back->is_ascii")
  ut.rel(raw.cast(back))
  ut.rel(raw.cast(cs))
  // ASCII, empty, and chars that aren't scalar values (U+FFFD each)
  let abs = ut.s("ab")
  let as_ = rt.auk_str_chars(abs)
  let ab = rt.auk_str_from_chars(as_)
  ut.check(ab.len_bytes == 2 && ab.len_chars == 2 && ab.is_ascii, "ab->len_bytes == 2 && ab->len_chars == 2 && ab->is_ascii")
  ut.str_eq(ab, "ab", "ab")
  ut.rel(raw.cast(as_))
  ut.rel(raw.cast(abs))
  var none_ = rt.auk_arr_new(rt.OPS_CHAR, 0)
  ut.str_eq(rt.auk_str_from_chars(none_), "", "auk_str_from_chars(none)")
  var bad: [u32; 3]
  let pb = raw.cast<u32>(raw.addr_of(&bad))
  pb.at(0) = 0xD800
  pb.at(1) = 120 // 'x'
  pb.at(2) = 0x110000
  var i = 0
  while i < 3 {
    rt.auk_arr_push(raw.addr_of(&none_), raw.cast(pb.offset(i)))
    i += 1
  }
  let rep = rt.auk_str_from_chars(none_)
  ut.check(rep.len_chars == 3 && rep.len_bytes == 7 && !rep.is_ascii, "rep->len_chars == 3 && rep->len_bytes == 7 && !rep->is_ascii")
  ut.str_eq(rep, "\u{FFFD}x\u{FFFD}", "rep")
  ut.rel(raw.cast(none_))
  var bs = rt.auk_str_bytes(x)
  ut.check(rt.auk_arr_len(bs) == 7, "auk_arr_len(bs) == 7")
  ut.check(ut.at_int(bs, 1) == 0xC3, "AT(int64_t, bs, 1) == 0xC3")
  var r = rt.auk_str_from_utf8(bs)
  ut.check(r.ok && rt.auk_str_eq(r.val, x), "r.ok && auk_str_eq(r.val, x)")
  ut.rel(raw.cast(r.val))
  // truncate the duck: invalid
  let _ = rt.auk_arr_pop(raw.addr_of(&bs), raw.null())
  r = rt.auk_str_from_utf8(bs)
  ut.check(!r.ok, "!r.ok")
  ut.str_eq(rt.auk_err_show(r.err), "invalid UTF-8 at byte 3", "auk_err_show(r.err)")
  ut.rel(raw.cast(r.err))
  ut.push_int(raw.addr_of(&bs), 256)
  r = rt.auk_str_from_utf8(bs)
  ut.check(!r.ok, "!r.ok")
  ut.rel(raw.cast(r.err))
  ut.rel(raw.cast(bs))
  ut.rel(raw.cast(x))
}

fn check_int_parse(input: raw.Ptr<u8>, ok_: bool, want: i64) uses raw, ffi {
  let x = ut.s(input)
  let r = rt.auk_int_parse(x)
  ut.rel(raw.cast(x))
  let m = ut.scratch(256)
  if r.ok != ok_ {
    let _ = rt.snprintf(m, 256, "int.parse(\"%s\") ok=%d", input, r.ok)
    ut.fail(m)
  }
  if ok_ {
    if r.val != want {
      let _ = rt.snprintf(m, 256, "int.parse(\"%s\") = %lld", input, r.val)
      ut.fail(m)
    }
  } else {
    ut.rel(raw.cast(r.err))
  }
}

fn check_float_parse(input: raw.Ptr<u8>, ok_: bool, want: float) uses raw, ffi {
  let x = ut.s(input)
  let r = rt.auk_float_parse(x)
  ut.rel(raw.cast(x))
  let m = ut.scratch(256)
  if r.ok != ok_ {
    let _ = rt.snprintf(m, 256, "float.parse(\"%s\") ok=%d", input, r.ok)
    ut.fail(m)
  }
  if ok_ {
    if !(r.val == want || (want != want && r.val != r.val)) {
      let _ = rt.snprintf(m, 256, "float.parse(\"%s\") = %g", input, r.val)
      ut.fail(m)
    }
  } else {
    ut.rel(raw.cast(r.err))
  }
}

fn int64_min(): i64 = i64(-9223372036854775807) - 1

fn inf(): float uses ffi = rt.auk_ffrom_bits(0x7ff0000000000000)

fn nan(): float uses ffi = rt.auk_ffrom_bits(0x7ff8000000000000)

fn str_parse() uses raw, ffi {
  check_int_parse("0", true, 0)
  check_int_parse("42", true, 42)
  check_int_parse("-17", true, -17)
  check_int_parse("+5", true, 5)
  check_int_parse("1_000_000", true, 1000000)
  check_int_parse("9223372036854775807", true, 9223372036854775807)
  check_int_parse("-9223372036854775808", true, int64_min())
  check_int_parse("9223372036854775808", false, 0)
  check_int_parse("-9223372036854775809", false, 0)
  check_int_parse("", false, 0)
  check_int_parse("-", false, 0)
  check_int_parse(" 1", false, 0)
  check_int_parse("1 ", false, 0)
  check_int_parse("12a", false, 0)
  check_int_parse("_1", false, 0)
  check_int_parse("1__0", false, 0)
  check_int_parse("1_", false, 0)
  check_int_parse("0x10", false, 0)
  let bad = ut.s("abc")
  let r = rt.auk_int_parse(bad)
  ut.str_eq(rt.auk_err_show(r.err), "int.parse: invalid int \"abc\"", "auk_err_show(r.err)")
  ut.rel(raw.cast(r.err))
  ut.rel(raw.cast(bad))

  check_float_parse("1.5", true, 1.5)
  check_float_parse("-0.25", true, -0.25)
  check_float_parse("1e-9", true, 1.0e-9)
  check_float_parse("3", true, 3.0)
  check_float_parse("inf", true, inf())
  check_float_parse("", false, 0.0)
  check_float_parse("1.5x", false, 0.0)
  check_float_parse(" 1.5", false, 0.0)
  check_float_parse("0x1p3", false, 0.0)
}

/// str(v) must be want, and parse back to v (with its sign).
fn check_float(v: float, want: raw.Ptr<u8>) uses raw, ffi {
  let x = rt.auk_str_from_float(v)
  let got = ut.text(x)
  let m = ut.scratch(512)
  if rt.strcmp(got, want) != 0 {
    let g = ut.copy_bytes(got, rt.strlen(got))
    ut.rel(raw.cast(x))
    let _ = rt.snprintf(m, 512, "str(%e) = \"%s\", want \"%s\"", v, g, want)
    ut.fail(m)
  }
  // round trip
  let r = rt.auk_float_parse(x)
  ut.rel(raw.cast(x))
  if v == v && (!r.ok || r.val != v || (rt.auk_fbits(r.val) < 0) != (rt.auk_fbits(v) < 0)) {
    let _ = rt.snprintf(m, 512, "\"%s\" does not round-trip", want)
    ut.fail(m)
  }
  if !r.ok {
    ut.rel(raw.cast(r.err))
  }
}

fn str_float_formatting() uses raw, ffi {
  check_float(0.1, "0.1")
  check_float(2.0, "2.0")
  check_float(rt.auk_ffrom_bits(int64_min()), "-0.0")
  check_float(0.0, "0.0")
  check_float(1.0e21, "1e21")
  check_float(1.0e20, "100000000000000000000.0")
  check_float(123456789.125, "123456789.125")
  check_float(0.1 + 0.2, "0.30000000000000004")
  check_float(1.0 / 3.0, "0.3333333333333333")
  check_float(-1.5, "-1.5")
  check_float(1.0e-7, "1e-7")
  check_float(1.5e-7, "1.5e-7")
  check_float(0.000001, "0.000001")
  check_float(rt.auk_ffrom_bits(1), "5e-324")
  check_float(1.7976931348623157e308, "1.7976931348623157e308")
  check_float(100.0, "100.0")
  check_float(3.14, "3.14")
  check_float(inf(), "inf")
  check_float(0.0 - inf(), "-inf")
  check_float(nan(), "NaN")
  // random round-trips
  var x: u64 = 88172645463325252
  var i = 0
  while i < 2000 {
    i += 1
    x = x ^ (x << 13)
    x = x ^ (x >> 7)
    x = x ^ (x << 17)
    let d = rt.auk_ffrom_bits(i64(x))
    if d - d != 0.0 {
      continue // not finite
    }
    let st = rt.auk_str_from_float(d)
    let t = ut.copy_bytes(ut.text(st), usize(rt.auk_str_byte_len(st)))
    let m = ut.scratch(512)
    if rt.strchr(t, 46).is_null() && rt.strchr(t, 101).is_null() { // '.', 'e'
      ut.rel(raw.cast(st))
      let _ = rt.snprintf(m, 512, "%s has no '.' or 'e'", t)
      ut.fail(m)
    }
    let r = rt.auk_float_parse(st)
    ut.rel(raw.cast(st))
    if !(r.ok && r.val == d) {
      if !r.ok {
        ut.rel(raw.cast(r.err))
      }
      let _ = rt.snprintf(m, 512, "%s does not round-trip", t)
      ut.fail(m)
    }
  }
}

fn str_scalar_formatting() uses raw, ffi {
  ut.str_eq(rt.auk_str_from_int(0), "0", "auk_str_from_int(0)")
  ut.str_eq(rt.auk_str_from_int(-42), "-42", "auk_str_from_int(-42)")
  ut.str_eq(rt.auk_str_from_int(int64_min()), "-9223372036854775808", "auk_str_from_int(INT64_MIN)")
  ut.str_eq(rt.auk_str_from_char(0x1F986), "🦆", "auk_str_from_char(0x1F986)")
  ut.str_eq(rt.auk_str_from_char(120), "x", "auk_str_from_char('x')")
  ut.str_eq(rt.auk_str_from_bool(true), "true", "auk_str_from_bool(true)")
  ut.str_eq(rt.auk_str_from_bool(false), "false", "auk_str_from_bool(false)")
  let q = ut.s("a\"b\\c\nd\té\u{1}")
  ut.str_eq(rt.auk_str_quote(q), "\"a\\\"b\\\\c\\nd\\té\\u{{1}}\"", "auk_str_quote(q)")
  ut.rel(raw.cast(q))
  ut.str_eq(rt.auk_char_quote(39), "'\\''", "auk_char_quote('\\'')")
  ut.str_eq(rt.auk_char_quote(97), "'a'", "auk_char_quote('a')")
}

fn str_format_specs() uses raw, ffi {
  ut.str_eq(rt.auk_fmt_int(42, ">5"), "   42", "auk_fmt_int(42, \">5\")")
  ut.str_eq(rt.auk_fmt_int(42, "5"), "   42", "auk_fmt_int(42, \"5\")") // numbers default right
  ut.str_eq(rt.auk_fmt_int(42, "<5"), "42   ", "auk_fmt_int(42, \"<5\")")
  ut.str_eq(rt.auk_fmt_int(42, "^6"), "  42  ", "auk_fmt_int(42, \"^6\")")
  ut.str_eq(rt.auk_fmt_int(-42, "05"), "-0042", "auk_fmt_int(-42, \"05\")")
  ut.str_eq(rt.auk_fmt_int(42, "05"), "00042", "auk_fmt_int(42, \"05\")")
  ut.str_eq(rt.auk_fmt_int(123456, "3"), "123456", "auk_fmt_int(123456, \"3\")")
  ut.str_eq(rt.auk_fmt_int(7, ""), "7", "auk_fmt_int(7, \"\")")
  ut.str_eq(rt.auk_fmt_int(7, raw.null()), "7", "auk_fmt_int(7, NULL)")
  ut.str_eq(rt.auk_fmt_int(7, "*>4"), "***7", "auk_fmt_int(7, \"*>4\")")
  ut.str_eq(rt.auk_fmt_float(3.14159, ".2"), "3.14", "auk_fmt_float(3.14159, \".2\")")
  ut.str_eq(rt.auk_fmt_float(2.0, ".3"), "2.000", "auk_fmt_float(2.0, \".3\")")
  ut.str_eq(rt.auk_fmt_float(2.5, ".0"), "2", "auk_fmt_float(2.5, \".0\")")
  ut.str_eq(rt.auk_fmt_float(-1.5, "08.2"), "-0001.50", "auk_fmt_float(-1.5, \"08.2\")")
  ut.str_eq(rt.auk_fmt_float(3.14159, ">8.3"), "   3.142", "auk_fmt_float(3.14159, \">8.3\")")
  ut.str_eq(rt.auk_fmt_float(0.1, ""), "0.1", "auk_fmt_float(0.1, \"\")")
  ut.str_eq(rt.auk_fmt_float(2.0, "6"), "   2.0", "auk_fmt_float(2.0, \"6\")")
  let w = ut.s("wörd")
  ut.str_eq(rt.auk_fmt_str(w, "<8"), "wörd    ", "auk_fmt_str(w, \"<8\")") // width counts chars
  ut.str_eq(rt.auk_fmt_str(w, ">6"), "  wörd", "auk_fmt_str(w, \">6\")")
  ut.str_eq(rt.auk_fmt_str(w, "8"), "wörd    ", "auk_fmt_str(w, \"8\")") // strings default left
  ut.str_eq(rt.auk_fmt_str(w, ".2"), "wö", "auk_fmt_str(w, \".2\")")
  ut.str_eq(rt.auk_fmt_str(w, "·^8"), "··wörd··", "auk_fmt_str(w, \"·^8\")") // fill ·
  ut.str_eq(rt.auk_fmt_str(w, ""), "wörd", "auk_fmt_str(w, \"\")")
  ut.rel(raw.cast(w))
  ut.str_eq(rt.auk_fmt_char(120, ">3"), "  x", "auk_fmt_char('x', \">3\")")
  ut.str_eq(rt.auk_fmt_bool(true, "<6"), "true  ", "auk_fmt_bool(true, \"<6\")")
}

fn bad_spec(ctx: raw.Ptr<()>) uses ffi {
  let _ = rt.auk_fmt_int(1, ">q") // x is hex now; q is no format
}

fn str_bad_spec_panics() uses raw, ffi = ut.expect_panic(raw.fn_of(bad_spec), raw.null(), "bad format spec")

fn str_builder() uses raw, ffi {
  var b = abi.StrBuf {}
  let pb = raw.addr_of(&b)
  rt.auk_sb_lit(pb, "hi ")
  let name = ut.s("dück")
  rt.auk_sb_str(pb, name)
  rt.auk_sb_lit(pb, " n=")
  rt.auk_sb_str_own(pb, rt.auk_fmt_int(5, ">3"))
  rt.auk_sb_char(pb, 32) // ' '
  rt.auk_sb_char(pb, 0x1F986)
  var num: [u8; 32]
  let pn = raw.cast<u8>(raw.addr_of(&num))
  let _ = rt.snprintf(pn, 32, " %d", i32(7))
  ut.sb_push(pb, pn)
  let x = rt.auk_sb_finish(pb)
  ut.check(rt.auk_str_len(x) == 17, "auk_str_len(x) == 17")
  ut.str_eq(x, "hi dück n=  5 🦆 7", "x")
  ut.rel(raw.cast(name))
  var e = abi.StrBuf {}
  ut.str_eq(rt.auk_sb_finish(raw.addr_of(&e)), "", "auk_sb_finish(&e)")
}

fn str_switch_lookup() uses raw, ffi {
  // sorted by (length, bytes): the 3-byte "hé" sorts before "let"
  var sorted: [abi.StrCase; 6]
  let cases = raw.cast<abi.StrCase>(raw.addr_of(&sorted))
  cases.at(0) = abi.StrCase { s: "", len: 0 }
  cases.at(1) = abi.StrCase { s: "fn", len: 2 }
  cases.at(2) = abi.StrCase { s: "if", len: 2 }
  cases.at(3) = abi.StrCase { s: "hé", len: 3 }
  cases.at(4) = abi.StrCase { s: "let", len: 3 }
  cases.at(5) = abi.StrCase { s: "else", len: 4 }
  var i: i64 = 0
  while i < 6 {
    let k = ut.s(cases.at(i).s)
    ut.eq(rt.auk_str_switch(k, cases, 6), i, "auk_str_switch(k, sorted, 6)")
    ut.rel(raw.cast(k))
    i += 1
  }
  var misses: [raw.Ptr<u8>; 6]
  let pm = raw.cast<raw.Ptr<u8>>(raw.addr_of(&misses))
  pm.at(0) = "f"
  pm.at(1) = "fx"
  pm.at(2) = "lets"
  pm.at(3) = "els"
  pm.at(4) = "zz"
  pm.at(5) = "else!"
  i = 0
  while i < 6 {
    let k = ut.s(pm.at(i))
    ut.eq(rt.auk_str_switch(k, cases, 6), -1, "auk_str_switch(miss, sorted, 6)")
    ut.rel(raw.cast(k))
    i += 1
  }
  let k = ut.s("fn")
  ut.eq(rt.auk_str_switch(k, cases, 0), -1, "auk_str_switch(k, sorted, 0)")
  ut.rel(raw.cast(k))
}

fn str_append_in_place() uses raw, ffi {
  var a = ut.s("ab")
  let pa = raw.addr_of(&a)
  let shared: raw.Ptr<abi.Str> = raw.cast(ut.ret(raw.cast(a)))
  rt.auk_str_append(pa, shared) // shared: a new string, the old one released
  ut.check(a != shared, "a != shared")
  ut.eq(rt.auk_refcount(raw.cast(shared)), 1, "auk_refcount(shared)")
  var i = 0
  while i < 1000 {
    let e = ut.s("é")
    rt.auk_str_append(pa, e)
    ut.rel(raw.cast(e))
    i += 1
  }
  ut.eq(a.len_bytes, 2004, "a->len_bytes")
  ut.eq(a.len_chars, 1004, "a->len_chars")
  ut.check(!a.is_ascii, "!a->is_ascii")
  rt.auk_str_append(pa, a) // appending itself
  ut.eq(a.len_bytes, 4008, "a->len_bytes")
  let want: raw.Ptr<u8> = "ababé"
  ut.check(raw.compare(a.data.offset(2004), want, 6) == 0 && a.data.at(4008) == 0, "memcmp(a->data + 2004, \"abab\\xc3\\xa9\", 6) == 0 && a->data[4008] == 0")
  rt.auk_str_append(pa, raw.null()) // "" changes nothing
  ut.eq(a.len_chars, 2008, "a->len_chars")
  ut.rel(raw.cast(a))
  ut.rel(raw.cast(shared))
}

fn str_char_helpers() uses raw, ffi {
  ut.check(rt.auk_char_is_digit(55) && !rt.auk_char_is_digit(97), "auk_char_is_digit('7') && !auk_char_is_digit('a')")
  ut.check(rt.auk_char_is_alpha(81) && !rt.auk_char_is_alpha(49), "auk_char_is_alpha('Q') && !auk_char_is_alpha('1')")
  ut.check(rt.auk_char_is_space(9) && !rt.auk_char_is_space(0xA0 + 0x1000), "auk_char_is_space('\\t') && !auk_char_is_space(0xA0 + 0x1000)")
  ut.check(
    rt.auk_char_upper(97) == 65 && rt.auk_char_lower(65) == 97 && rt.auk_char_upper(0xE9) == 0xE9,
    "auk_char_upper('a') == 'A' && auk_char_lower('A') == 'a' && auk_char_upper(0xE9) == 0xE9",
  )
  ut.check(rt.auk_char_from_int(65).some && rt.auk_char_from_int(65).val == 65, "auk_char_from_int(65).some && auk_char_from_int(65).val == 'A'")
  ut.check(!rt.auk_char_from_int(0xD800).some, "!auk_char_from_int(0xD800).some")
  ut.check(!rt.auk_char_from_int(0x110000).some, "!auk_char_from_int(0x110000).some")
  ut.check(!rt.auk_char_from_int(-1).some, "!auk_char_from_int(-1).some")
}

/// The tests, in the C file's order.
pub fn all() uses raw, ffi {
  ut.run("str_utf8_validation", raw.fn_of(str_utf8_validation))
  ut.run("str_construct_and_repair", raw.fn_of(str_construct_and_repair))
  ut.run("str_char_indexing", raw.fn_of(str_char_indexing))
  ut.run("str_index_panics", raw.fn_of(str_index_panics))
  ut.run("str_concat_eq_cmp_hash", raw.fn_of(str_concat_eq_cmp_hash))
  ut.run("str_split_trim_lines", raw.fn_of(str_split_trim_lines))
  ut.run("str_search_replace", raw.fn_of(str_search_replace))
  ut.run("str_chars_bytes_utf8", raw.fn_of(str_chars_bytes_utf8))
  ut.run("str_parse", raw.fn_of(str_parse))
  ut.run("str_float_formatting", raw.fn_of(str_float_formatting))
  ut.run("str_scalar_formatting", raw.fn_of(str_scalar_formatting))
  ut.run("str_format_specs", raw.fn_of(str_format_specs))
  ut.run("str_bad_spec_panics", raw.fn_of(str_bad_spec_panics))
  ut.run("str_builder", raw.fn_of(str_builder))
  ut.run("str_char_helpers", raw.fn_of(str_char_helpers))
  ut.run("str_switch_lookup", raw.fn_of(str_switch_lookup))
  ut.run("str_append_in_place", raw.fn_of(str_append_in_place))
}
