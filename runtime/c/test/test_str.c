/* str: UTF-8, indexing, searching, parsing and formatting. */
#include "test.h"

#include <math.h>

static const char *T = "t";

/* A byte-string literal and its length (it may hold NULs). */
#define B(lit) (lit), (int64_t)(sizeof(lit) - 1)

static bool valid(const char *p, int64_t n) { return auk_utf8_valid(p, n, NULL, NULL); }

/* auk_utf8_valid with its outputs: ok, chars, ascii must match. */
#define CHECK_V(lit, w_ok, w_chars, w_ascii)                                          \
    do {                                                                              \
        int64_t chars_ = -1;                                                          \
        bool ascii_ = false;                                                          \
        bool ok_ = auk_utf8_valid(B(lit), &chars_, &ascii_);                          \
        CHECK(ok_ == (w_ok) && chars_ == (w_chars) && ascii_ == (w_ascii));           \
    } while (0)

static void str_utf8_validation(void) {
    int64_t chars = -1;
    bool ascii = false;
    CHECK_V("", true, 0, true);
    CHECK_V("abc", true, 3, true);
    CHECK_V("h\xC3\xA9", true, 2, false); /* hé */
    CHECK(auk_utf8_valid(B("\xF0\x9F\xA6\x86"), &chars, &ascii) && chars == 1); /* 🦆 */
    CHECK(auk_utf8_valid(B("\xE2\x82\xAC"), &chars, &ascii) && chars == 1);     /* € */
    CHECK(auk_utf8_valid(B("\xF4\x8F\xBF\xBF"), &chars, &ascii));               /* U+10FFFF */
    CHECK(valid(B("\xEF\xBF\xBF")));         /* U+FFFF */
    CHECK(!valid(B("\xC0\x80")));            /* overlong NUL */
    CHECK(!valid(B("\xE0\x80\xAF")));        /* overlong '/' */
    CHECK(!valid(B("\xF0\x80\x80\xAF")));    /* overlong 4-byte */
    CHECK(!valid(B("\xED\xA0\x80")));        /* surrogate */
    CHECK(!valid(B("\xF4\x90\x80\x80")));    /* > U+10FFFF */
    CHECK(!valid(B("\xC3")));                /* truncated */
    CHECK(!valid(B("\xE2\x82")));            /* truncated */
    CHECK(!valid(B("\x80")));                /* lone continuation */
    CHECK(!valid(B("a\xFF")));
    CHECK(!valid(B("\xC3\x28")));            /* bad continuation */
    chars = 0;
    CHECK(auk_utf8_valid(B("a\0b"), &chars, NULL) && chars == 3);
}

static void str_construct_and_repair(void) {
    AukStr *x = auk_str_from_bytes(B("a\xFF" "b"));
    CHECK(auk_str_len(x) == 3);
    CHECK(!x->is_ascii);
    CHECK_STR(x, "a\xEF\xBF\xBD" "b"); /* a U+FFFD b */
    AukRes_str r = auk_str_try_from_bytes(B("ab\xC3"));
    CHECK(!r.ok);
    CHECK_STR(auk_err_show(r.err), "invalid UTF-8 at byte 2");
    rel(r.err);
    r = auk_str_try_from_bytes(B("\xC3\xA9"));
    CHECK(r.ok && auk_str_len(r.val) == 1);
    rel(r.val);
    AukStr *e = s("");
    CHECK(auk_str_len(e) == 0 && auk_str_byte_len(e) == 0 && e->is_ascii);
    rel(e);
    /* NULL is the empty string */
    CHECK(auk_str_len(NULL) == 0);
    CHECK(auk_str_eq(NULL, NULL));
    CHECK_STR(auk_str_concat(NULL, NULL), "");
}

static void str_char_indexing(void) {
    AukStr *a = s("hello");
    CHECK(a->is_ascii);
    CHECK(auk_str_char_at(a, 0, T) == 'h');
    CHECK(auk_str_char_at(a, 4, T) == 'o');
    AukStr *u = s("héllo 🦆!");
    CHECK(auk_str_len(u) == 8);
    CHECK(auk_str_byte_len(u) == 12);
    CHECK(auk_str_char_at(u, 1, T) == 0xE9);
    CHECK(auk_str_char_at(u, 6, T) == 0x1F986);
    CHECK(auk_str_char_at(u, 7, T) == '!');
    CHECK(!auk_str_get(u, 8).some);
    CHECK(!auk_str_get(u, -1).some);
    CHECK(auk_str_get(u, 2).some && auk_str_get(u, 2).val == 'l');
    CHECK_STR(auk_str_slice(u, 1, 3, T), "él");
    CHECK_STR(auk_str_slice(u, 6, 8, T), "🦆!");
    CHECK_STR(auk_str_slice(u, 3, 3, T), "");
    AukStr *whole = auk_str_slice(u, 0, 8, T);
    CHECK(whole == u); /* full slice shares */
    rel(whole);
    CHECK_STR(auk_str_slice(a, 1, 4, T), "ell");
    rel(a);
    rel(u);
}

static void char_at_oob(void *ctx) {
    (void)ctx;
    AukStr *x = s("hé");
    auk_str_char_at(x, 2, "main.auk:3:7");
}
static void slice_backwards(void *ctx) {
    (void)ctx;
    AukStr *x = s("abc");
    auk_str_slice(x, 2, 1, "main.auk:4:1");
}

static void str_index_panics(void) {
    EXPECT_PANIC(char_at_oob, NULL, "index 2 out of range for string of length 2\n  at main.auk:3:7");
    EXPECT_PANIC(slice_backwards, NULL, "slice 2..1 out of range");
}

static void str_concat_eq_cmp_hash(void) {
    AukStr *a = s("ab"), *b = s("é");
    AukStr *c = auk_str_concat(a, b);
    CHECK(auk_str_len(c) == 3 && !c->is_ascii);
    AukStr *c2 = s("abé");
    CHECK(auk_str_eq(c, c2));
    CHECK(auk_str_hash(c) == auk_str_hash(c2));
    CHECK(auk_str_cmp(a, c) < 0);
    CHECK(auk_str_cmp(c, a) > 0);
    CHECK(auk_str_cmp(c, c2) == 0);
    AukStr *z = s("z");
    CHECK(auk_str_cmp(z, b) < 0); /* 'z' < 'é' by code point */
    CHECK(auk_str_eq_lit(a, "ab") && !auk_str_eq_lit(a, "abc"));
    rel(a);
    rel(b);
    rel(c);
    rel(c2);
    rel(z);
}

/* Join an owned array with "|", releasing it. */
static AukStr *join_arr(AukArr *a) {
    AukStr *sep = s("|");
    AukStr *r = auk_arr_join(a, sep);
    rel(sep);
    rel(a);
    return r;
}

static void str_split_trim_lines(void) {
    AukStr *x = s("  the quick\t brown\n fox  ");
    CHECK_STR(join_arr(auk_str_split_ws(x)), "the|quick|brown|fox");
    CHECK_STR(auk_str_trim(x), "the quick\t brown\n fox");
    CHECK_STR(auk_str_trim_start(x), "the quick\t brown\n fox  ");
    CHECK_STR(auk_str_trim_end(x), "  the quick\t brown\n fox");
    rel(x);

    AukStr *e = s("");
    AukArr *ea = auk_str_split_ws(e);
    CHECK(auk_arr_len(ea) == 0);
    rel(ea);
    AukStr *comma = s(",");
    AukArr *one = auk_str_split(e, comma);
    CHECK(auk_arr_len(one) == 1);
    rel(one);
    rel(e);

    AukStr *csv = s("a,,b,");
    CHECK_STR(join_arr(auk_str_split(csv, comma)), "a||b|");
    rel(csv);
    rel(comma);

    AukStr *u = s("x→y→z"), *arrow = s("→"), *empty = s("");
    AukArr *parts = auk_str_split(u, arrow);
    CHECK(auk_arr_len(parts) == 3);
    CHECK(auk_str_len(AT(AukStr *, parts, 1)) == 1);
    rel(parts);
    CHECK_STR(join_arr(auk_str_split(u, empty)), "x|→|y|→|z");
    rel(u);
    rel(arrow);
    rel(empty);

    AukStr *t = s("one\r\ntwo\n\nthree\n");
    CHECK_STR(join_arr(auk_str_lines(t)), "one|two||three");
    rel(t);
    t = s("no newline");
    CHECK_STR(join_arr(auk_str_lines(t)), "no newline");
    rel(t);
}

static void str_search_replace(void) {
    AukStr *x = s("héllo wörld");
    AukStr *p = s("hé"), *q = s("rld"), *w = s("wö"), *no = s("xyz"), *e = s("");
    CHECK(auk_str_starts_with(x, p) && !auk_str_starts_with(p, x));
    CHECK(auk_str_ends_with(x, q) && !auk_str_ends_with(x, p));
    CHECK(auk_str_contains(x, w) && !auk_str_contains(x, no) && auk_str_contains(x, e));
    AukOpt_int f = auk_str_find(x, w);
    CHECK(f.some && f.val == 6); /* char index, not byte index (7) */
    CHECK(!auk_str_find(x, no).some);
    AukStr *l = s("l"), *ll = s("LL");
    CHECK_STR(auk_str_replace(x, l, ll), "héLLLLo wörLLd");
    CHECK_STR(auk_str_replace(x, e, ll), "héllo wörld");
    CHECK_STR(auk_str_replace(x, no, ll), "héllo wörld");
    AukStr *aaaa = s("aaaa"), *aa = s("aa"), *b = s("b");
    CHECK_STR(auk_str_replace(aaaa, aa, b), "bb");
    CHECK_STR(auk_str_upper(x), "HéLLO WöRLD");
    AukStr *mixed = s("MiXeD Été");
    CHECK_STR(auk_str_lower(mixed), "mixed Été");
    CHECK_STR(auk_str_repeat(aa, 3, T), "aaaaaa");
    AukStr *all[] = {x, p, q, w, no, e, l, ll, aaaa, aa, b, mixed};
    for (size_t i = 0; i < sizeof all / sizeof all[0]; i++) rel(all[i]);
}

static void str_chars_bytes_utf8(void) {
    AukStr *x = s("aé🦆");
    AukArr *cs = auk_str_chars(x);
    CHECK(auk_arr_len(cs) == 3);
    CHECK(AT(uint32_t, cs, 0) == 'a');
    CHECK(AT(uint32_t, cs, 1) == 0xE9);
    CHECK(AT(uint32_t, cs, 2) == 0x1F986);
    CHECK_STR(auk_str_from_chars(cs), "aé🦆");
    CHECK_STR(auk_arr_show(cs), "['a', 'é', '🦆']");
    AukStr *back = auk_str_from_chars(cs);
    CHECK(back->len_bytes == 7 && back->len_chars == 3 && !back->is_ascii);
    rel(back);
    rel(cs);
    /* ASCII, empty, and chars that aren't scalar values (U+FFFD each) */
    AukStr *abs = s("ab");
    AukArr *as = auk_str_chars(abs);
    AukStr *ab = auk_str_from_chars(as);
    CHECK(ab->len_bytes == 2 && ab->len_chars == 2 && ab->is_ascii);
    CHECK_STR(ab, "ab");
    rel(as);
    rel(abs);
    AukArr *none = auk_arr_new(&auk_ops_char, 0);
    CHECK_STR(auk_str_from_chars(none), "");
    uint32_t bad[] = {0xD800, 'x', 0x110000};
    for (int i = 0; i < 3; i++) auk_arr_push(&none, &bad[i]);
    AukStr *rep = auk_str_from_chars(none);
    CHECK(rep->len_chars == 3 && rep->len_bytes == 7 && !rep->is_ascii);
    CHECK_STR(rep, "\xEF\xBF\xBDx\xEF\xBF\xBD");
    rel(none);
    AukArr *bs = auk_str_bytes(x);
    CHECK(auk_arr_len(bs) == 7);
    CHECK(AT(int64_t, bs, 1) == 0xC3);
    AukRes_str r = auk_str_from_utf8(bs);
    CHECK(r.ok && auk_str_eq(r.val, x));
    rel(r.val);
    /* truncate the duck: invalid */
    auk_arr_pop(&bs, NULL);
    r = auk_str_from_utf8(bs);
    CHECK(!r.ok);
    CHECK_STR(auk_err_show(r.err), "invalid UTF-8 at byte 3");
    rel(r.err);
    PUSH(int64_t, &bs, 256);
    r = auk_str_from_utf8(bs);
    CHECK(!r.ok);
    rel(r.err);
    rel(bs);
    rel(x);
}

static void check_int_parse(const char *file, int line, const char *input, bool ok, int64_t want) {
    AukStr *x = s(input);
    AukRes_int r = auk_int_parse(x);
    rel(x);
    if (r.ok != ok) t_fail(file, line, "int.parse(\"%s\") ok=%d", input, r.ok);
    if (ok) {
        if (r.val != want) t_fail(file, line, "int.parse(\"%s\") = %lld", input, (long long)r.val);
    } else {
        rel(r.err);
    }
}
#define CHECK_INT_PARSE(in, ok, want) check_int_parse(__FILE__, __LINE__, (in), (ok), (want))

static void check_float_parse(const char *file, int line, const char *input, bool ok, double want) {
    AukStr *x = s(input);
    AukRes_float r = auk_float_parse(x);
    rel(x);
    if (r.ok != ok) t_fail(file, line, "float.parse(\"%s\") ok=%d", input, r.ok);
    if (ok) {
        if (!(r.val == want || (isnan(want) && isnan(r.val))))
            t_fail(file, line, "float.parse(\"%s\") = %g", input, r.val);
    } else {
        rel(r.err);
    }
}
#define CHECK_FLOAT_PARSE(in, ok, want) check_float_parse(__FILE__, __LINE__, (in), (ok), (want))

static void str_parse(void) {
    CHECK_INT_PARSE("0", true, 0);
    CHECK_INT_PARSE("42", true, 42);
    CHECK_INT_PARSE("-17", true, -17);
    CHECK_INT_PARSE("+5", true, 5);
    CHECK_INT_PARSE("1_000_000", true, 1000000);
    CHECK_INT_PARSE("9223372036854775807", true, INT64_MAX);
    CHECK_INT_PARSE("-9223372036854775808", true, INT64_MIN);
    CHECK_INT_PARSE("9223372036854775808", false, 0);
    CHECK_INT_PARSE("-9223372036854775809", false, 0);
    CHECK_INT_PARSE("", false, 0);
    CHECK_INT_PARSE("-", false, 0);
    CHECK_INT_PARSE(" 1", false, 0);
    CHECK_INT_PARSE("1 ", false, 0);
    CHECK_INT_PARSE("12a", false, 0);
    CHECK_INT_PARSE("_1", false, 0);
    CHECK_INT_PARSE("1__0", false, 0);
    CHECK_INT_PARSE("1_", false, 0);
    CHECK_INT_PARSE("0x10", false, 0);
    AukStr *bad = s("abc");
    AukRes_int r = auk_int_parse(bad);
    CHECK_STR(auk_err_show(r.err), "int.parse: invalid int \"abc\"");
    rel(r.err);
    rel(bad);

    CHECK_FLOAT_PARSE("1.5", true, 1.5);
    CHECK_FLOAT_PARSE("-0.25", true, -0.25);
    CHECK_FLOAT_PARSE("1e-9", true, 1e-9);
    CHECK_FLOAT_PARSE("3", true, 3.0);
    CHECK_FLOAT_PARSE("inf", true, INFINITY);
    CHECK_FLOAT_PARSE("", false, 0.0);
    CHECK_FLOAT_PARSE("1.5x", false, 0.0);
    CHECK_FLOAT_PARSE(" 1.5", false, 0.0);
    CHECK_FLOAT_PARSE("0x1p3", false, 0.0);
}

/* str(v) must be want, and parse back to v (with its sign). */
static void check_float(const char *file, int line, double v, const char *want) {
    AukStr *x = auk_str_from_float(v);
    const char *got = text(x);
    if (strcmp(got, want) != 0) {
        char *g = t_copy(got, strlen(got));
        rel(x);
        t_fail(file, line, "str(%e) = \"%s\", want \"%s\"", v, g, want);
    }
    /* round trip */
    AukRes_float r = auk_float_parse(x);
    rel(x);
    if (!isnan(v) && (!r.ok || r.val != v || signbit(r.val) != signbit(v)))
        t_fail(file, line, "\"%s\" does not round-trip", want);
    if (!r.ok) rel(r.err);
}
#define CHECK_FLOAT(v, want) check_float(__FILE__, __LINE__, (v), (want))

static void str_float_formatting(void) {
    CHECK_FLOAT(0.1, "0.1");
    CHECK_FLOAT(2.0, "2.0");
    CHECK_FLOAT(-0.0, "-0.0");
    CHECK_FLOAT(0.0, "0.0");
    CHECK_FLOAT(1e21, "1e21");
    CHECK_FLOAT(1e20, "100000000000000000000.0");
    CHECK_FLOAT(123456789.125, "123456789.125");
    CHECK_FLOAT(0.1 + 0.2, "0.30000000000000004");
    CHECK_FLOAT(1.0 / 3.0, "0.3333333333333333");
    CHECK_FLOAT(-1.5, "-1.5");
    CHECK_FLOAT(1e-7, "1e-7");
    CHECK_FLOAT(1.5e-7, "1.5e-7");
    CHECK_FLOAT(0.000001, "0.000001");
    CHECK_FLOAT(5e-324, "5e-324");
    CHECK_FLOAT(1.7976931348623157e308, "1.7976931348623157e308");
    CHECK_FLOAT(100.0, "100.0");
    CHECK_FLOAT(3.14, "3.14");
    CHECK_FLOAT(INFINITY, "inf");
    CHECK_FLOAT(-INFINITY, "-inf");
    CHECK_FLOAT(NAN, "NaN");
    /* random round-trips */
    uint64_t x = 88172645463325252ull;
    for (int i = 0; i < 2000; i++) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        double d;
        memcpy(&d, &x, sizeof d);
        if (!isfinite(d)) continue;
        AukStr *st = auk_str_from_float(d);
        const char *t = t_copy(text(st), (size_t)auk_str_byte_len(st));
        if (strchr(t, '.') == NULL && strchr(t, 'e') == NULL) {
            rel(st);
            t_fail(__FILE__, __LINE__, "%s has no '.' or 'e'", t);
        }
        AukRes_float r = auk_float_parse(st);
        rel(st);
        if (!(r.ok && r.val == d)) {
            if (!r.ok) rel(r.err);
            t_fail(__FILE__, __LINE__, "%s does not round-trip", t);
        }
    }
}

static void str_scalar_formatting(void) {
    CHECK_STR(auk_str_from_int(0), "0");
    CHECK_STR(auk_str_from_int(-42), "-42");
    CHECK_STR(auk_str_from_int(INT64_MIN), "-9223372036854775808");
    CHECK_STR(auk_str_from_char(0x1F986), "🦆");
    CHECK_STR(auk_str_from_char('x'), "x");
    CHECK_STR(auk_str_from_bool(true), "true");
    CHECK_STR(auk_str_from_bool(false), "false");
    AukStr *q = s("a\"b\\c\nd\té\x01");
    CHECK_STR(auk_str_quote(q), "\"a\\\"b\\\\c\\nd\\té\\u{1}\"");
    rel(q);
    CHECK_STR(auk_char_quote('\''), "'\\''");
    CHECK_STR(auk_char_quote('a'), "'a'");
}

static void str_format_specs(void) {
    CHECK_STR(auk_fmt_int(42, ">5"), "   42");
    CHECK_STR(auk_fmt_int(42, "5"), "   42"); /* numbers default right */
    CHECK_STR(auk_fmt_int(42, "<5"), "42   ");
    CHECK_STR(auk_fmt_int(42, "^6"), "  42  ");
    CHECK_STR(auk_fmt_int(-42, "05"), "-0042");
    CHECK_STR(auk_fmt_int(42, "05"), "00042");
    CHECK_STR(auk_fmt_int(123456, "3"), "123456");
    CHECK_STR(auk_fmt_int(7, ""), "7");
    CHECK_STR(auk_fmt_int(7, NULL), "7");
    CHECK_STR(auk_fmt_int(7, "*>4"), "***7");
    CHECK_STR(auk_fmt_float(3.14159, ".2"), "3.14");
    CHECK_STR(auk_fmt_float(2.0, ".3"), "2.000");
    CHECK_STR(auk_fmt_float(2.5, ".0"), "2");
    CHECK_STR(auk_fmt_float(-1.5, "08.2"), "-0001.50");
    CHECK_STR(auk_fmt_float(3.14159, ">8.3"), "   3.142");
    CHECK_STR(auk_fmt_float(0.1, ""), "0.1");
    CHECK_STR(auk_fmt_float(2.0, "6"), "   2.0");
    AukStr *w = s("wörd");
    CHECK_STR(auk_fmt_str(w, "<8"), "wörd    "); /* width counts chars */
    CHECK_STR(auk_fmt_str(w, ">6"), "  wörd");
    CHECK_STR(auk_fmt_str(w, "8"), "wörd    "); /* strings default left */
    CHECK_STR(auk_fmt_str(w, ".2"), "wö");
    CHECK_STR(auk_fmt_str(w, "·^8"), "··wörd··"); /* fill · */
    CHECK_STR(auk_fmt_str(w, ""), "wörd");
    rel(w);
    CHECK_STR(auk_fmt_char('x', ">3"), "  x");
    CHECK_STR(auk_fmt_bool(true, "<6"), "true  ");
}

static void bad_spec(void *ctx) {
    (void)ctx;
    auk_fmt_int(1, ">q"); /* x is hex now; q is no format */
}

static void str_bad_spec_panics(void) { EXPECT_PANIC(bad_spec, NULL, "bad format spec"); }

static void str_builder(void) {
    AukStrBuf b = {0};
    auk_sb_lit(&b, "hi ");
    AukStr *name = s("dück");
    auk_sb_str(&b, name);
    auk_sb_lit(&b, " n=");
    auk_sb_str_own(&b, auk_fmt_int(5, ">3"));
    auk_sb_char(&b, ' ');
    auk_sb_char(&b, 0x1F986);
    char num[32];
    snprintf(num, sizeof num, " %d", 7);
    sb_push(&b, num);
    AukStr *x = auk_sb_finish(&b);
    CHECK(auk_str_len(x) == 17);
    CHECK_STR(x, "hi dück n=  5 🦆 7");
    rel(name);
    AukStrBuf e = {0};
    CHECK_STR(auk_sb_finish(&e), "");
}

static void str_switch_lookup(void) {
    /* sorted by (length, bytes): the 3-byte "h\xc3\xa9" sorts before "let" */
    static const AukStrCase sorted[] = {{"", 0}, {"fn", 2}, {"if", 2}, {"h\xc3\xa9", 3}, {"let", 3}, {"else", 4}};
    const char *keys[] = {"", "fn", "if", "h\xc3\xa9", "let", "else"};
    for (int i = 0; i < 6; i++) {
        AukStr *k = s(keys[i]);
        CHECK_INT(auk_str_switch(k, sorted, 6), i);
        rel(k);
    }
    const char *misses[] = {"f", "fx", "lets", "els", "zz", "else!"};
    for (int i = 0; i < 6; i++) {
        AukStr *k = s(misses[i]);
        CHECK_INT(auk_str_switch(k, sorted, 6), -1);
        rel(k);
    }
    AukStr *k = s("fn");
    CHECK_INT(auk_str_switch(k, sorted, 0), -1);
    rel(k);
}

static void str_append_in_place(void) {
    AukStr *a = s("ab");
    AukStr *shared = ret(a);
    auk_str_append(&a, shared); /* shared: a new string, the old one released */
    CHECK(a != shared);
    CHECK_INT(auk_refcount(shared), 1);
    for (int i = 0; i < 1000; i++) {
        AukStr *e = s("\xc3\xa9");
        auk_str_append(&a, e);
        rel(e);
    }
    CHECK_INT(a->len_bytes, 2004);
    CHECK_INT(a->len_chars, 1004);
    CHECK(!a->is_ascii);
    auk_str_append(&a, a); /* appending itself */
    CHECK_INT(a->len_bytes, 4008);
    CHECK(memcmp(a->data + 2004, "abab\xc3\xa9", 6) == 0 && a->data[4008] == 0);
    auk_str_append(&a, NULL); /* "" changes nothing */
    CHECK_INT(a->len_chars, 2008);
    rel(a);
    rel(shared);
}

static void str_char_helpers(void) {
    CHECK(auk_char_is_digit('7') && !auk_char_is_digit('a'));
    CHECK(auk_char_is_alpha('Q') && !auk_char_is_alpha('1'));
    CHECK(auk_char_is_space('\t') && !auk_char_is_space(0xA0 + 0x1000));
    CHECK(auk_char_upper('a') == 'A' && auk_char_lower('A') == 'a' && auk_char_upper(0xE9) == 0xE9);
    CHECK(auk_char_from_int(65).some && auk_char_from_int(65).val == 'A');
    CHECK(!auk_char_from_int(0xD800).some);
    CHECK(!auk_char_from_int(0x110000).some);
    CHECK(!auk_char_from_int(-1).some);
}

const TestCase str_tests[] = {
    {"str_utf8_validation", str_utf8_validation},
    {"str_construct_and_repair", str_construct_and_repair},
    {"str_char_indexing", str_char_indexing},
    {"str_index_panics", str_index_panics},
    {"str_concat_eq_cmp_hash", str_concat_eq_cmp_hash},
    {"str_split_trim_lines", str_split_trim_lines},
    {"str_search_replace", str_search_replace},
    {"str_chars_bytes_utf8", str_chars_bytes_utf8},
    {"str_parse", str_parse},
    {"str_float_formatting", str_float_formatting},
    {"str_scalar_formatting", str_scalar_formatting},
    {"str_format_specs", str_format_specs},
    {"str_bad_spec_panics", str_bad_spec_panics},
    {"str_builder", str_builder},
    {"str_char_helpers", str_char_helpers},
    {"str_switch_lookup", str_switch_lookup},
    {"str_append_in_place", str_append_in_place},
    {NULL, NULL},
};
