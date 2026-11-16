/* str: UTF-8, indexing, searching, parsing and formatting. */
#include "harness.h"

#include <math.h>

TEST(str_utf8_validation) {
    int64_t chars;
    bool ascii;
    CHECK(duck_utf8_valid("", 0, &chars, &ascii) && chars == 0 && ascii);
    CHECK(duck_utf8_valid("abc", 3, &chars, &ascii) && chars == 3 && ascii);
    CHECK(duck_utf8_valid("h\xC3\xA9", 3, &chars, &ascii) && chars == 2 && !ascii);         /* hé */
    CHECK(duck_utf8_valid("\xF0\x9F\xA6\x86", 4, &chars, &ascii) && chars == 1);             /* 🦆 */
    CHECK(duck_utf8_valid("\xE2\x82\xAC", 3, &chars, &ascii) && chars == 1);                 /* € */
    CHECK(duck_utf8_valid("\xF4\x8F\xBF\xBF", 4, &chars, &ascii));                           /* U+10FFFF */
    CHECK(duck_utf8_valid("\xEF\xBF\xBF", 3, NULL, NULL));                                   /* U+FFFF */
    CHECK(!duck_utf8_valid("\xC0\x80", 2, NULL, NULL));                                      /* overlong NUL */
    CHECK(!duck_utf8_valid("\xE0\x80\xAF", 3, NULL, NULL));                                  /* overlong '/' */
    CHECK(!duck_utf8_valid("\xF0\x80\x80\xAF", 4, NULL, NULL));                              /* overlong 4-byte */
    CHECK(!duck_utf8_valid("\xED\xA0\x80", 3, NULL, NULL));                                  /* surrogate */
    CHECK(!duck_utf8_valid("\xF4\x90\x80\x80", 4, NULL, NULL));                              /* > U+10FFFF */
    CHECK(!duck_utf8_valid("\xC3", 1, NULL, NULL));                                          /* truncated */
    CHECK(!duck_utf8_valid("\xE2\x82", 2, NULL, NULL));                                      /* truncated */
    CHECK(!duck_utf8_valid("\x80", 1, NULL, NULL));                                          /* lone continuation */
    CHECK(!duck_utf8_valid("a\xFF", 2, NULL, NULL));
    CHECK(!duck_utf8_valid("\xC3\x28", 2, NULL, NULL)); /* bad continuation */
    CHECK(duck_utf8_valid("a\0b", 3, &chars, NULL) && chars == 3);
}

TEST(str_construct_and_repair) {
    DuckStr *s = duck_str_from_bytes("a\xFF" "b", 3);
    CHECK(duck_str_len(s) == 3);
    CHECK(!s->is_ascii);
    CHECK_STR(s, "a\xEF\xBF\xBD" "b");
    DuckRes_str r = duck_str_try_from_bytes("ab\xC3", 3);
    CHECK(!r.ok);
    CHECK_STR(duck_err_show(r.err), "invalid UTF-8 at byte 2");
    duck_release(r.err);
    r = duck_str_try_from_bytes("\xC3\xA9", 2);
    CHECK(r.ok && duck_str_len(r.val) == 1);
    duck_release(r.val);
    DuckStr *e = S("");
    CHECK(duck_str_len(e) == 0 && duck_str_byte_len(e) == 0 && e->is_ascii);
    duck_release(e);
    /* NULL is the empty string */
    CHECK(duck_str_len(NULL) == 0);
    CHECK(duck_str_eq(NULL, NULL));
    DuckStr *x = duck_str_concat(NULL, NULL);
    CHECK_STR(x, "");
}

TEST(str_char_indexing) {
    DuckStr *a = S("hello");
    CHECK(a->is_ascii);
    CHECK(duck_str_char_at(a, 0, "t") == 'h');
    CHECK(duck_str_char_at(a, 4, "t") == 'o');
    DuckStr *u = S("h\xC3\xA9llo \xF0\x9F\xA6\x86!"); /* héllo 🦆! */
    CHECK(duck_str_len(u) == 8);
    CHECK(duck_str_byte_len(u) == 12);
    CHECK(duck_str_char_at(u, 1, "t") == 0xE9);
    CHECK(duck_str_char_at(u, 6, "t") == 0x1F986);
    CHECK(duck_str_char_at(u, 7, "t") == '!');
    CHECK(!duck_str_get(u, 8).some);
    CHECK(!duck_str_get(u, -1).some);
    CHECK(duck_str_get(u, 2).some && duck_str_get(u, 2).val == 'l');
    CHECK_STR(duck_str_slice(u, 1, 3, "t"), "\xC3\xA9l");
    CHECK_STR(duck_str_slice(u, 6, 8, "t"), "\xF0\x9F\xA6\x86!");
    CHECK_STR(duck_str_slice(u, 3, 3, "t"), "");
    DuckStr *whole = duck_str_slice(u, 0, 8, "t");
    CHECK(whole == u); /* full slice shares */
    duck_release(whole);
    CHECK_STR(duck_str_slice(a, 1, 4, "t"), "ell");
    duck_release(a);
    duck_release(u);
}

static void char_oob(void *p) {
    (void)p;
    DuckStr *s = S("h\xC3\xA9");
    duck_str_char_at(s, 2, "main.duck:3:7");
}
static void slice_oob(void *p) {
    (void)p;
    DuckStr *s = S("abc");
    duck_str_slice(s, 2, 1, "main.duck:4:1");
}

TEST(str_index_panics) {
    EXPECT_PANIC(char_oob, NULL, "index 2 out of range for string of length 2\n  at main.duck:3:7");
    EXPECT_PANIC(slice_oob, NULL, "slice 2..1 out of range");
}

TEST(str_concat_eq_cmp_hash) {
    DuckStr *a = S("ab"), *b = S("\xC3\xA9"), *c = duck_str_concat(a, b);
    CHECK(duck_str_len(c) == 3 && !c->is_ascii);
    DuckStr *c2 = S("ab\xC3\xA9");
    CHECK(duck_str_eq(c, c2));
    CHECK(duck_str_hash(c) == duck_str_hash(c2));
    CHECK(duck_str_cmp(a, c) < 0);
    CHECK(duck_str_cmp(c, a) > 0);
    CHECK(duck_str_cmp(c, c2) == 0);
    DuckStr *z = S("z");
    CHECK(duck_str_cmp(z, b) < 0); /* 'z' < 'é' by code point */
    CHECK(duck_str_eq_lit(a, "ab") && !duck_str_eq_lit(a, "abc"));
    duck_release(a), duck_release(b), duck_release(c), duck_release(c2), duck_release(z);
}

static DuckStr *join_arr(DuckArr *a) {
    DuckStr *sep = S("|");
    DuckStr *r = duck_arr_join(a, sep);
    duck_release(sep);
    duck_release(a);
    return r;
}

TEST(str_split_trim_lines) {
    DuckStr *s = S("  the quick\t brown\n fox  ");
    CHECK_STR(join_arr(duck_str_split_ws(s)), "the|quick|brown|fox");
    CHECK_STR(duck_str_trim(s), "the quick\t brown\n fox");
    CHECK_STR(duck_str_trim_start(s), "the quick\t brown\n fox  ");
    CHECK_STR(duck_str_trim_end(s), "  the quick\t brown\n fox");
    duck_release(s);

    DuckStr *e = S("");
    DuckArr *ea = duck_str_split_ws(e);
    CHECK(duck_arr_len(ea) == 0);
    duck_release(ea);
    DuckStr *comma = S(",");
    DuckArr *one = duck_str_split(e, comma);
    CHECK(duck_arr_len(one) == 1);
    duck_release(one);
    duck_release(e);

    DuckStr *csv = S("a,,b,");
    CHECK_STR(join_arr(duck_str_split(csv, comma)), "a||b|");
    duck_release(csv);
    duck_release(comma);

    DuckStr *u = S("x\xE2\x86\x92y\xE2\x86\x92z"), *arrow = S("\xE2\x86\x92"), *empty = S("");
    DuckArr *parts = duck_str_split(u, arrow);
    CHECK(duck_arr_len(parts) == 3);
    CHECK(duck_str_len(DUCK_ARR_AT(DuckStr *, parts, 1, "t")) == 1);
    duck_release(parts);
    CHECK_STR(join_arr(duck_str_split(u, empty)), "x|\xE2\x86\x92|y|\xE2\x86\x92|z");
    duck_release(u), duck_release(arrow), duck_release(empty);

    DuckStr *t = S("one\r\ntwo\n\nthree\n");
    CHECK_STR(join_arr(duck_str_lines(t)), "one|two||three");
    duck_release(t);
    t = S("no newline");
    CHECK_STR(join_arr(duck_str_lines(t)), "no newline");
    duck_release(t);
}

TEST(str_search_replace) {
    DuckStr *s = S("h\xC3\xA9llo w\xC3\xB6rld");
    DuckStr *p = S("h\xC3\xA9"), *q = S("rld"), *w = S("w\xC3\xB6"), *no = S("xyz"), *e = S("");
    CHECK(duck_str_starts_with(s, p) && !duck_str_starts_with(p, s));
    CHECK(duck_str_ends_with(s, q) && !duck_str_ends_with(s, p));
    CHECK(duck_str_contains(s, w) && !duck_str_contains(s, no) && duck_str_contains(s, e));
    DuckOpt_int f = duck_str_find(s, w);
    CHECK(f.some && f.val == 6); /* char index, not byte index (7) */
    CHECK(!duck_str_find(s, no).some);
    DuckStr *l = S("l"), *L = S("LL");
    CHECK_STR(duck_str_replace(s, l, L), "h\xC3\xA9LLLLo w\xC3\xB6rLLd");
    CHECK_STR(duck_str_replace(s, e, L), "h\xC3\xA9llo w\xC3\xB6rld");
    CHECK_STR(duck_str_replace(s, no, L), "h\xC3\xA9llo w\xC3\xB6rld");
    DuckStr *aaa = S("aaaa"), *aa = S("aa"), *b = S("b");
    CHECK_STR(duck_str_replace(aaa, aa, b), "bb");
    CHECK_STR(duck_str_upper(s), "H\xC3\xA9LLO W\xC3\xB6RLD");
    DuckStr *mixed = S("MiXeD \xC3\x89t\xC3\xA9");
    CHECK_STR(duck_str_lower(mixed), "mixed \xC3\x89t\xC3\xA9");
    CHECK_STR(duck_str_repeat(aa, 3, "t"), "aaaaaa");
    duck_release(s), duck_release(p), duck_release(q), duck_release(w), duck_release(no), duck_release(e);
    duck_release(l), duck_release(L), duck_release(aaa), duck_release(aa), duck_release(b), duck_release(mixed);
}

TEST(str_chars_bytes_utf8) {
    DuckStr *s = S("a\xC3\xA9\xF0\x9F\xA6\x86");
    DuckArr *cs = duck_str_chars(s);
    CHECK(duck_arr_len(cs) == 3);
    CHECK(DUCK_ARR_AT(uint32_t, cs, 0, "t") == 'a');
    CHECK(DUCK_ARR_AT(uint32_t, cs, 1, "t") == 0xE9);
    CHECK(DUCK_ARR_AT(uint32_t, cs, 2, "t") == 0x1F986);
    CHECK_STR(duck_str_from_chars(cs), "a\xC3\xA9\xF0\x9F\xA6\x86");
    CHECK_STR(duck_arr_show(cs), "['a', '\xC3\xA9', '\xF0\x9F\xA6\x86']");
    duck_release(cs);
    DuckArr *bs = duck_str_bytes(s);
    CHECK(duck_arr_len(bs) == 7);
    CHECK(DUCK_ARR_AT(int64_t, bs, 1, "t") == 0xC3);
    DuckRes_str r = duck_str_from_utf8(bs);
    CHECK(r.ok && duck_str_eq(r.val, s));
    duck_release(r.val);
    /* truncate the duck: invalid */
    duck_arr_pop(&bs, NULL);
    r = duck_str_from_utf8(bs);
    CHECK(!r.ok);
    CHECK_STR(duck_err_show(r.err), "invalid UTF-8 at byte 3");
    duck_release(r.err);
    DUCK_ARR_PUSH(int64_t, &bs, 256);
    r = duck_str_from_utf8(bs);
    CHECK(!r.ok);
    duck_release(r.err);
    duck_release(bs);
    duck_release(s);
}

static void check_int_parse(const char *in, bool ok, int64_t want) {
    DuckStr *s = S(in);
    DuckRes_int r = duck_int_parse(s);
    duck_release(s);
    if (r.ok != ok) th_fail(__FILE__, __LINE__, "int.parse(\"%s\") ok=%d", in, r.ok);
    if (ok && r.val != want) th_fail(__FILE__, __LINE__, "int.parse(\"%s\") = %lld", in, (long long)r.val);
    if (!ok) duck_release(r.err);
}

static void check_float_parse(const char *in, bool ok, double want) {
    DuckStr *s = S(in);
    DuckRes_float r = duck_float_parse(s);
    duck_release(s);
    if (r.ok != ok) th_fail(__FILE__, __LINE__, "float.parse(\"%s\") ok=%d", in, r.ok);
    if (ok && r.val != want && !(isnan(want) && isnan(r.val)))
        th_fail(__FILE__, __LINE__, "float.parse(\"%s\") = %g", in, r.val);
    if (!ok) duck_release(r.err);
}

TEST(str_parse) {
    check_int_parse("0", true, 0);
    check_int_parse("42", true, 42);
    check_int_parse("-17", true, -17);
    check_int_parse("+5", true, 5);
    check_int_parse("1_000_000", true, 1000000);
    check_int_parse("9223372036854775807", true, INT64_MAX);
    check_int_parse("-9223372036854775808", true, INT64_MIN);
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
    DuckStr *bad = S("abc");
    DuckRes_int r = duck_int_parse(bad);
    CHECK_STR(duck_err_show(r.err), "int.parse: invalid int \"abc\"");
    duck_release(r.err);
    duck_release(bad);

    check_float_parse("1.5", true, 1.5);
    check_float_parse("-0.25", true, -0.25);
    check_float_parse("1e-9", true, 1e-9);
    check_float_parse("3", true, 3.0);
    check_float_parse("inf", true, INFINITY);
    check_float_parse("", false, 0);
    check_float_parse("1.5x", false, 0);
    check_float_parse(" 1.5", false, 0);
    check_float_parse("0x1p3", false, 0);
}

static void check_float(double v, const char *want) {
    DuckStr *s = duck_str_from_float(v);
    if (strcmp(duck_str_cstr(s), want) != 0) {
        char got[64];
        snprintf(got, sizeof got, "%s", duck_str_cstr(s));
        duck_release(s);
        th_fail(__FILE__, __LINE__, "str(%.17g) = \"%s\", want \"%s\"", v, got, want);
    }
    /* round trip */
    DuckRes_float r = duck_float_parse(s);
    duck_release(s);
    if (!isnan(v) && (!r.ok || r.val != v || signbit(r.val) != signbit(v)))
        th_fail(__FILE__, __LINE__, "\"%s\" does not round-trip", want);
    if (!r.ok) duck_release(r.err);
}

TEST(str_float_formatting) {
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
    check_float(INFINITY, "inf");
    check_float(-INFINITY, "-inf");
    check_float(NAN, "NaN");
    /* random round-trips */
    uint64_t x = 88172645463325252ULL;
    for (int i = 0; i < 2000; i++) {
        x ^= x << 13, x ^= x >> 7, x ^= x << 17;
        double d;
        memcpy(&d, &x, sizeof d);
        if (!isfinite(d)) continue;
        DuckStr *s = duck_str_from_float(d);
        CHECK(strchr(duck_str_cstr(s), '.') || strchr(duck_str_cstr(s), 'e'));
        DuckRes_float r = duck_float_parse(s);
        CHECK(r.ok && r.val == d);
        duck_release(s);
    }
}

TEST(str_scalar_formatting) {
    CHECK_STR(duck_str_from_int(0), "0");
    CHECK_STR(duck_str_from_int(-42), "-42");
    CHECK_STR(duck_str_from_int(INT64_MIN), "-9223372036854775808");
    CHECK_STR(duck_str_from_char(0x1F986), "\xF0\x9F\xA6\x86");
    CHECK_STR(duck_str_from_char('x'), "x");
    CHECK_STR(duck_str_from_bool(true), "true");
    CHECK_STR(duck_str_from_bool(false), "false");
    DuckStr *q = S("a\"b\\c\nd\t\xC3\xA9\x01");
    CHECK_STR(duck_str_quote(q), "\"a\\\"b\\\\c\\nd\\t\xC3\xA9\\u{1}\"");
    duck_release(q);
    CHECK_STR(duck_char_quote('\''), "'\\''");
    CHECK_STR(duck_char_quote('a'), "'a'");
}

TEST(str_format_specs) {
    CHECK_STR(duck_fmt_int(42, ">5"), "   42");
    CHECK_STR(duck_fmt_int(42, "5"), "   42"); /* numbers default right */
    CHECK_STR(duck_fmt_int(42, "<5"), "42   ");
    CHECK_STR(duck_fmt_int(42, "^6"), "  42  ");
    CHECK_STR(duck_fmt_int(-42, "05"), "-0042");
    CHECK_STR(duck_fmt_int(42, "05"), "00042");
    CHECK_STR(duck_fmt_int(123456, "3"), "123456");
    CHECK_STR(duck_fmt_int(7, ""), "7");
    CHECK_STR(duck_fmt_int(7, NULL), "7");
    CHECK_STR(duck_fmt_int(7, "*>4"), "***7");
    CHECK_STR(duck_fmt_float(3.14159, ".2"), "3.14");
    CHECK_STR(duck_fmt_float(2.0, ".3"), "2.000");
    CHECK_STR(duck_fmt_float(2.5, ".0"), "2");
    CHECK_STR(duck_fmt_float(-1.5, "08.2"), "-0001.50");
    CHECK_STR(duck_fmt_float(3.14159, ">8.3"), "   3.142");
    CHECK_STR(duck_fmt_float(0.1, ""), "0.1");
    CHECK_STR(duck_fmt_float(2.0, "6"), "   2.0");
    DuckStr *w = S("w\xC3\xB6rd");
    CHECK_STR(duck_fmt_str(w, "<8"), "w\xC3\xB6rd    "); /* width counts chars */
    CHECK_STR(duck_fmt_str(w, ">6"), "  w\xC3\xB6rd");
    CHECK_STR(duck_fmt_str(w, "8"), "w\xC3\xB6rd    "); /* strings default left */
    CHECK_STR(duck_fmt_str(w, ".2"), "w\xC3\xB6");
    CHECK_STR(duck_fmt_str(w, "\xC2\xB7^8"), "\xC2\xB7\xC2\xB7w\xC3\xB6rd\xC2\xB7\xC2\xB7"); /* fill · */
    CHECK_STR(duck_fmt_str(w, ""), "w\xC3\xB6rd");
    duck_release(w);
    CHECK_STR(duck_fmt_char('x', ">3"), "  x");
    CHECK_STR(duck_fmt_bool(true, "<6"), "true  ");
}

static void bad_spec(void *p) {
    (void)p;
    duck_fmt_int(1, ">x");
}

TEST(str_bad_spec_panics) { EXPECT_PANIC(bad_spec, NULL, "bad format spec"); }

TEST(str_builder) {
    DuckStrBuf b = DUCK_SB_INIT;
    duck_sb_lit(&b, "hi ");
    DuckStr *name = S("d\xC3\xBC" "ck");
    duck_sb_str(&b, name);
    duck_sb_lit(&b, " n=");
    duck_sb_str_own(&b, duck_fmt_int(5, ">3"));
    duck_sb_char(&b, ' ');
    duck_sb_char(&b, 0x1F986);
    duck_sb_printf(&b, " %d", 7);
    DuckStr *s = duck_sb_finish(&b);
    CHECK(duck_str_len(s) == 17);
    CHECK_STR(s, "hi d\xC3\xBC" "ck n=  5 \xF0\x9F\xA6\x86 7");
    duck_release(name);
    DuckStrBuf e = DUCK_SB_INIT;
    CHECK_STR(duck_sb_finish(&e), "");
}

TEST(str_char_helpers) {
    CHECK(duck_char_is_digit('7') && !duck_char_is_digit('a'));
    CHECK(duck_char_is_alpha('Q') && !duck_char_is_alpha('1'));
    CHECK(duck_char_is_space('\t') && !duck_char_is_space(0xA0 + 0x1000));
    CHECK(duck_char_upper('a') == 'A' && duck_char_lower('A') == 'a' && duck_char_upper(0xE9) == 0xE9);
    CHECK(duck_char_from_int(65).some && duck_char_from_int(65).val == 'A');
    CHECK(!duck_char_from_int(0xD800).some);
    CHECK(!duck_char_from_int(0x110000).some);
    CHECK(!duck_char_from_int(-1).some);
}
