/* str: immutable UTF-8 strings, parsing, formatting and the string builder. */
#include "duck_internal.h"

#include <errno.h>
#include <math.h>
#include <stdarg.h>

/* ---- UTF-8 ----------------------------------------------------------- */

bool duck_utf8_valid(const char *p, int64_t n, int64_t *chars_out, bool *ascii_out) {
    const unsigned char *s = (const unsigned char *)p;
    int64_t i = 0, chars = 0;
    bool ascii = true;
    while (i < n) {
        unsigned char c = s[i];
        if (c < 0x80) {
            i++;
        } else {
            ascii = false;
            int len;
            uint32_t cp;
            if (c >= 0xC2 && c <= 0xDF) len = 2, cp = c & 0x1F;
            else if (c >= 0xE0 && c <= 0xEF) len = 3, cp = c & 0x0F;
            else if (c >= 0xF0 && c <= 0xF4) len = 4, cp = c & 0x07;
            else return false;
            if (i + len > n) return false;
            for (int k = 1; k < len; k++) {
                if ((s[i + k] & 0xC0) != 0x80) return false;
                cp = (cp << 6) | (s[i + k] & 0x3F);
            }
            if (len == 3 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) return false;
            if (len == 4 && (cp < 0x10000 || cp > 0x10FFFF)) return false;
            i += len;
        }
        chars++;
    }
    if (chars_out) *chars_out = chars;
    if (ascii_out) *ascii_out = ascii;
    return true;
}

/* Length of the valid UTF-8 sequence at s[i..n), or 0 if invalid. */
static int utf8_seq_len(const unsigned char *s, int64_t i, int64_t n) {
    int64_t chars;
    if (s[i] < 0x80) return 1;
    for (int len = 2; len <= 4; len++) {
        if (i + len <= n && duck_utf8_valid((const char *)s + i, len, &chars, NULL) && chars == 1) return len;
    }
    return 0;
}

uint32_t duck__utf8_decode(const char *p, int *len) {
    const unsigned char *s = (const unsigned char *)p;
    if (s[0] < 0x80) { *len = 1; return s[0]; }
    if (s[0] < 0xE0) { *len = 2; return ((uint32_t)(s[0] & 0x1F) << 6) | (s[1] & 0x3F); }
    if (s[0] < 0xF0) {
        *len = 3;
        return ((uint32_t)(s[0] & 0x0F) << 12) | ((uint32_t)(s[1] & 0x3F) << 6) | (s[2] & 0x3F);
    }
    *len = 4;
    return ((uint32_t)(s[0] & 0x07) << 18) | ((uint32_t)(s[1] & 0x3F) << 12) | ((uint32_t)(s[2] & 0x3F) << 6) |
           (s[3] & 0x3F);
}

int duck_utf8_encode(uint32_t c, char *buf) {
    unsigned char *b = (unsigned char *)buf;
    if (c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)) c = 0xFFFD;
    if (c < 0x80) { b[0] = (unsigned char)c; return 1; }
    if (c < 0x800) {
        b[0] = (unsigned char)(0xC0 | (c >> 6));
        b[1] = (unsigned char)(0x80 | (c & 0x3F));
        return 2;
    }
    if (c < 0x10000) {
        b[0] = (unsigned char)(0xE0 | (c >> 12));
        b[1] = (unsigned char)(0x80 | ((c >> 6) & 0x3F));
        b[2] = (unsigned char)(0x80 | (c & 0x3F));
        return 3;
    }
    b[0] = (unsigned char)(0xF0 | (c >> 18));
    b[1] = (unsigned char)(0x80 | ((c >> 12) & 0x3F));
    b[2] = (unsigned char)(0x80 | ((c >> 6) & 0x3F));
    b[3] = (unsigned char)(0x80 | (c & 0x3F));
    return 4;
}

/* ---- construction ---------------------------------------------------- */

DuckStr *duck__str_raw(const char *p, int64_t n, int64_t chars, bool ascii) {
    DuckStr *s = duck__alloc(sizeof(DuckStr) + (size_t)n + 1, DUCK_K_STR);
    if (n) memcpy(s->data, p, (size_t)n);
    s->data[n] = 0;
    s->len_bytes = n;
    s->len_chars = chars;
    s->is_ascii = ascii;
    return s;
}

DuckStr *duck__str_new(const char *p, int64_t n) {
    int64_t chars = 0;
    bool ascii = true;
    const unsigned char *u = (const unsigned char *)p;
    for (int64_t i = 0; i < n; i++) {
        if (u[i] >= 0x80) ascii = false;
        if ((u[i] & 0xC0) != 0x80) chars++;
    }
    return duck__str_raw(p, n, chars, ascii);
}

DuckStr *duck_str_from_bytes(const char *p, int64_t n) {
    int64_t chars;
    bool ascii;
    if (duck_utf8_valid(p, n, &chars, &ascii)) return duck__str_raw(p, n, chars, ascii);
    /* Repair: replace each invalid byte with U+FFFD. */
    DuckStrBuf b = DUCK_SB_INIT;
    const unsigned char *s = (const unsigned char *)p;
    int64_t i = 0;
    while (i < n) {
        int len = utf8_seq_len(s, i, n);
        if (len) {
            duck_sb_bytes(&b, p + i, len);
            i += len;
        } else {
            duck_sb_bytes(&b, "\xEF\xBF\xBD", 3);
            i++;
        }
    }
    return duck_sb_finish(&b);
}

DuckStr *duck_str_lit(const char *cstr) { return duck_str_from_bytes(cstr, (int64_t)strlen(cstr)); }

DuckRes_str duck_str_try_from_bytes(const char *p, int64_t n) {
    int64_t chars;
    bool ascii;
    if (duck_utf8_valid(p, n, &chars, &ascii)) return DUCK_OK(DuckRes_str, duck__str_raw(p, n, chars, ascii));
    int64_t i = 0;
    while (i < n) {
        int len = utf8_seq_len((const unsigned char *)p, i, n);
        if (!len) break;
        i += len;
    }
    return DUCK_ERR(DuckRes_str, duck_err_fmt("invalid UTF-8 at byte %lld", (long long)i));
}

DuckRes_str duck_str_from_utf8(DuckArr *bytes) {
    int64_t n = duck_arr_len(bytes);
    char *buf = duck__xmalloc((size_t)n + 1);
    const int64_t *xs = duck_arr_data(bytes);
    for (int64_t i = 0; i < n; i++) {
        if (xs[i] < 0 || xs[i] > 255) {
            free(buf);
            return DUCK_ERR(DuckRes_str,
                            duck_err_fmt("byte %lld at index %lld is out of range 0..255", (long long)xs[i], (long long)i));
        }
        buf[i] = (char)xs[i];
    }
    DuckRes_str r = duck_str_try_from_bytes(buf, n);
    free(buf);
    return r;
}

/* ---- indexing -------------------------------------------------------- */

int64_t duck__str_byte_offset(const DuckStr *s, int64_t i) {
    if (!s) return 0;
    if (s->is_ascii) return i;
    if (i >= s->len_chars) return s->len_bytes;
    const unsigned char *p = (const unsigned char *)s->data;
    int64_t b = 0, c = 0;
    while (c < i) {
        b++;
        while (b < s->len_bytes && (p[b] & 0xC0) == 0x80) b++;
        c++;
    }
    return b;
}

uint32_t duck_str_char_at(const DuckStr *s, int64_t i, const char *loc) {
    int64_t n = duck_str_len(s);
    if (i < 0 || i >= n) duck_panic(loc, "index %lld out of range for string of length %lld", (long long)i, (long long)n);
    if (s->is_ascii) return (unsigned char)s->data[i];
    int len;
    return duck__utf8_decode(s->data + duck__str_byte_offset(s, i), &len);
}

DuckOpt_char duck_str_get(const DuckStr *s, int64_t i) {
    if (i < 0 || i >= duck_str_len(s)) return DUCK_NONE(DuckOpt_char);
    return DUCK_SOME(DuckOpt_char, duck_str_char_at(s, i, NULL));
}

DuckStr *duck_str_slice(const DuckStr *s, int64_t a, int64_t b, const char *loc) {
    int64_t n = duck_str_len(s);
    if (a < 0 || b < a || b > n)
        duck_panic(loc, "slice %lld..%lld out of range for string of length %lld", (long long)a, (long long)b,
                   (long long)n);
    if (a == 0 && b == n && s) return duck_retain((void *)s);
    int64_t ba = duck__str_byte_offset(s, a), bb = duck__str_byte_offset(s, b);
    bool ascii = s ? s->is_ascii : true;
    return duck__str_raw(duck_str_cstr(s) + ba, bb - ba, b - a, ascii);
}

DuckStr *duck_str_concat(const DuckStr *a, const DuckStr *b) {
    int64_t na = duck_str_byte_len(a), nb = duck_str_byte_len(b);
    DuckStr *s = duck__alloc(sizeof(DuckStr) + (size_t)(na + nb) + 1, DUCK_K_STR);
    memcpy(s->data, duck_str_cstr(a), (size_t)na);
    memcpy(s->data + na, duck_str_cstr(b), (size_t)nb);
    s->data[na + nb] = 0;
    s->len_bytes = na + nb;
    s->len_chars = duck_str_len(a) + duck_str_len(b);
    s->is_ascii = (!a || a->is_ascii) && (!b || b->is_ascii);
    return s;
}

bool duck_str_eq(const DuckStr *a, const DuckStr *b) {
    if (a == b) return true;
    int64_t n = duck_str_byte_len(a);
    return n == duck_str_byte_len(b) && memcmp(duck_str_cstr(a), duck_str_cstr(b), (size_t)n) == 0;
}

bool duck_str_eq_lit(const DuckStr *s, const char *lit) {
    size_t n = strlen(lit);
    return (size_t)duck_str_byte_len(s) == n && memcmp(duck_str_cstr(s), lit, n) == 0;
}

int duck_str_cmp(const DuckStr *a, const DuckStr *b) {
    int64_t na = duck_str_byte_len(a), nb = duck_str_byte_len(b);
    int c = memcmp(duck_str_cstr(a), duck_str_cstr(b), (size_t)(na < nb ? na : nb));
    if (c) return c < 0 ? -1 : 1;
    return (na > nb) - (na < nb);
}

uint64_t duck_str_hash(const DuckStr *s) { return duck_hash_bytes(duck_str_cstr(s), (size_t)duck_str_byte_len(s)); }

void duck__str_free(DuckStr *s) { duck__free_obj(s); }

/* ---- searching ------------------------------------------------------- */

/* Byte offset of needle in hay starting at `from`, or -1. */
static int64_t find_bytes(const char *hay, int64_t hn, const char *needle, int64_t nn, int64_t from) {
    if (nn == 0) return from <= hn ? from : -1;
    for (int64_t i = from; i + nn <= hn; i++) {
        const char *p = memchr(hay + i, needle[0], (size_t)(hn - nn - i + 1));
        if (!p) return -1;
        i = p - hay;
        if (memcmp(p, needle, (size_t)nn) == 0) return i;
    }
    return -1;
}

static int64_t chars_in(const char *p, int64_t n) {
    int64_t c = 0;
    for (int64_t i = 0; i < n; i++)
        if (((unsigned char)p[i] & 0xC0) != 0x80) c++;
    return c;
}

/* Sub-string by byte range [a, b) of s (s valid UTF-8, a/b on boundaries). */
static DuckStr *sub_bytes(const DuckStr *s, int64_t a, int64_t b) {
    if (s && a == 0 && b == s->len_bytes) return duck_retain((void *)s);
    const char *p = duck_str_cstr(s) + a;
    bool ascii = s ? s->is_ascii : true;
    return duck__str_raw(p, b - a, ascii ? b - a : chars_in(p, b - a), ascii);
}

static void push_own(DuckArr **a, DuckStr *s) {
    duck_arr_push(a, &s);
    duck_release(s);
}

static bool is_ws(unsigned char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'; }

DuckArr *duck_str_split_ws(const DuckStr *s) {
    DuckArr *out = duck_arr_new(&duck_ops_str, 0);
    const char *p = duck_str_cstr(s);
    int64_t n = duck_str_byte_len(s), i = 0;
    while (i < n) {
        while (i < n && is_ws((unsigned char)p[i])) i++;
        if (i >= n) break;
        int64_t st = i;
        while (i < n && !is_ws((unsigned char)p[i])) i++;
        push_own(&out, sub_bytes(s, st, i));
    }
    return out;
}

DuckArr *duck_str_split(const DuckStr *s, const DuckStr *sep) {
    DuckArr *out = duck_arr_new(&duck_ops_str, 0);
    const char *p = duck_str_cstr(s);
    int64_t n = duck_str_byte_len(s), sn = duck_str_byte_len(sep);
    if (sn == 0) {
        int64_t i = 0;
        while (i < n) {
            int len;
            duck__utf8_decode(p + i, &len);
            push_own(&out, sub_bytes(s, i, i + len));
            i += len;
        }
        return out;
    }
    int64_t st = 0;
    for (;;) {
        int64_t at = find_bytes(p, n, duck_str_cstr(sep), sn, st);
        if (at < 0) break;
        push_own(&out, sub_bytes(s, st, at));
        st = at + sn;
    }
    push_own(&out, sub_bytes(s, st, n));
    return out;
}

DuckStr *duck_str_trim_start(const DuckStr *s) {
    const char *p = duck_str_cstr(s);
    int64_t n = duck_str_byte_len(s), a = 0;
    while (a < n && is_ws((unsigned char)p[a])) a++;
    return sub_bytes(s, a, n);
}

DuckStr *duck_str_trim_end(const DuckStr *s) {
    const char *p = duck_str_cstr(s);
    int64_t b = duck_str_byte_len(s);
    while (b > 0 && is_ws((unsigned char)p[b - 1])) b--;
    return sub_bytes(s, 0, b);
}

DuckStr *duck_str_trim(const DuckStr *s) {
    const char *p = duck_str_cstr(s);
    int64_t n = duck_str_byte_len(s), a = 0, b = n;
    while (a < n && is_ws((unsigned char)p[a])) a++;
    while (b > a && is_ws((unsigned char)p[b - 1])) b--;
    return sub_bytes(s, a, b);
}

DuckArr *duck_str_lines(const DuckStr *s) {
    DuckArr *out = duck_arr_new(&duck_ops_str, 0);
    const char *p = duck_str_cstr(s);
    int64_t n = duck_str_byte_len(s), st = 0;
    while (st < n) {
        const char *nl = memchr(p + st, '\n', (size_t)(n - st));
        int64_t end = nl ? nl - p : n;
        int64_t e = end;
        if (e > st && p[e - 1] == '\r') e--;
        push_own(&out, sub_bytes(s, st, e));
        st = end + 1;
    }
    return out;
}

bool duck_str_starts_with(const DuckStr *s, const DuckStr *pre) {
    int64_t n = duck_str_byte_len(pre);
    return duck_str_byte_len(s) >= n && memcmp(duck_str_cstr(s), duck_str_cstr(pre), (size_t)n) == 0;
}

bool duck_str_ends_with(const DuckStr *s, const DuckStr *suf) {
    int64_t n = duck_str_byte_len(suf), sn = duck_str_byte_len(s);
    return sn >= n && memcmp(duck_str_cstr(s) + sn - n, duck_str_cstr(suf), (size_t)n) == 0;
}

bool duck_str_contains(const DuckStr *s, const DuckStr *sub) {
    return find_bytes(duck_str_cstr(s), duck_str_byte_len(s), duck_str_cstr(sub), duck_str_byte_len(sub), 0) >= 0;
}

DuckOpt_int duck_str_find(const DuckStr *s, const DuckStr *sub) {
    int64_t at = find_bytes(duck_str_cstr(s), duck_str_byte_len(s), duck_str_cstr(sub), duck_str_byte_len(sub), 0);
    if (at < 0) return DUCK_NONE(DuckOpt_int);
    return DUCK_SOME(DuckOpt_int, (s && s->is_ascii) ? at : chars_in(duck_str_cstr(s), at));
}

DuckStr *duck_str_replace(const DuckStr *s, const DuckStr *from, const DuckStr *to) {
    int64_t fn = duck_str_byte_len(from), n = duck_str_byte_len(s);
    const char *p = duck_str_cstr(s);
    if (fn == 0) return s ? duck_retain((void *)s) : duck_str_lit("");
    DuckStrBuf b = DUCK_SB_INIT;
    int64_t st = 0;
    for (;;) {
        int64_t at = find_bytes(p, n, duck_str_cstr(from), fn, st);
        if (at < 0) break;
        duck_sb_bytes(&b, p + st, at - st);
        duck_sb_str(&b, to);
        st = at + fn;
    }
    duck_sb_bytes(&b, p + st, n - st);
    return duck_sb_finish(&b);
}

static DuckStr *map_ascii(const DuckStr *s, int up) {
    int64_t n = duck_str_byte_len(s);
    DuckStr *r = duck__str_raw(duck_str_cstr(s), n, duck_str_len(s), s ? s->is_ascii : true);
    for (int64_t i = 0; i < n; i++) {
        char c = r->data[i];
        if (up && c >= 'a' && c <= 'z') r->data[i] = (char)(c - 32);
        if (!up && c >= 'A' && c <= 'Z') r->data[i] = (char)(c + 32);
    }
    return r;
}
DuckStr *duck_str_upper(const DuckStr *s) { return map_ascii(s, 1); }
DuckStr *duck_str_lower(const DuckStr *s) { return map_ascii(s, 0); }

DuckStr *duck_str_repeat(const DuckStr *s, int64_t n, const char *loc) {
    if (n < 0) duck_panic(loc, "repeat count %lld is negative", (long long)n);
    int64_t bl = duck_str_byte_len(s), total;
    if (__builtin_mul_overflow(bl, n, &total)) duck_panic_overflow(loc, "repeat");
    DuckStr *r = duck__alloc(sizeof(DuckStr) + (size_t)total + 1, DUCK_K_STR);
    for (int64_t i = 0; i < n; i++) memcpy(r->data + i * bl, duck_str_cstr(s), (size_t)bl);
    r->data[total] = 0;
    r->len_bytes = total;
    r->len_chars = duck_str_len(s) * n;
    r->is_ascii = s ? s->is_ascii : true;
    return r;
}

DuckArr *duck_str_chars(const DuckStr *s) {
    int64_t n = duck_str_len(s), nb = duck_str_byte_len(s);
    DuckArr *out = duck_arr_new(&duck_ops_char, n);
    uint32_t *d = duck_arr_make_unique(&out);
    const char *p = duck_str_cstr(s);
    int64_t i = 0, k = 0;
    while (i < nb) {
        int len;
        d[k++] = duck__utf8_decode(p + i, &len);
        i += len;
    }
    out->len = k;
    return out;
}

DuckArr *duck_str_bytes(const DuckStr *s) {
    int64_t n = duck_str_byte_len(s);
    DuckArr *out = duck_arr_new(&duck_ops_int, n);
    int64_t *d = duck_arr_make_unique(&out);
    for (int64_t i = 0; i < n; i++) d[i] = (unsigned char)duck_str_cstr(s)[i];
    out->len = n;
    return out;
}

DuckStr *duck_str_from_chars(DuckArr *chars) {
    DuckStrBuf b = DUCK_SB_INIT;
    const uint32_t *cs = duck_arr_data(chars);
    for (int64_t i = 0; i < duck_arr_len(chars); i++) duck_sb_char(&b, cs[i]);
    return duck_sb_finish(&b);
}

/* ---- parsing --------------------------------------------------------- */

DuckRes_int duck_int_parse(const DuckStr *s) {
    const char *p = duck_str_cstr(s);
    int64_t n = duck_str_byte_len(s), i = 0;
    bool neg = false;
    if (i < n && (p[i] == '+' || p[i] == '-')) neg = p[i++] == '-';
    if (i >= n) goto bad;
    uint64_t acc = 0, limit = neg ? (uint64_t)INT64_MAX + 1 : (uint64_t)INT64_MAX;
    bool prev_digit = false;
    for (; i < n; i++) {
        char c = p[i];
        if (c == '_' && prev_digit && i + 1 < n && p[i + 1] >= '0' && p[i + 1] <= '9') {
            prev_digit = false;
            continue;
        }
        if (c < '0' || c > '9') goto bad;
        uint64_t d = (uint64_t)(c - '0');
        if (acc > (limit - d) / 10) {
            return DUCK_ERR(DuckRes_int, duck_err_fmt("int.parse: \"%s\" is out of range", p));
        }
        acc = acc * 10 + d;
        prev_digit = true;
    }
    if (neg) return DUCK_OK(DuckRes_int, acc == (uint64_t)INT64_MAX + 1 ? INT64_MIN : -(int64_t)acc);
    return DUCK_OK(DuckRes_int, (int64_t)acc);
bad:
    return DUCK_ERR(DuckRes_int, duck_err_fmt("int.parse: invalid int \"%s\"", p));
}

DuckRes_float duck_float_parse(const DuckStr *s) {
    const char *p = duck_str_cstr(s);
    int64_t n = duck_str_byte_len(s);
    if (n == 0 || is_ws((unsigned char)p[0]) || (int64_t)strlen(p) != n) goto bad;
    for (int64_t i = 0; i < n; i++) /* reject hex floats and other strtod extras */
        if (p[i] == 'x' || p[i] == 'X' || p[i] == '(') goto bad;
    char *end;
    errno = 0;
    double d = strtod(p, &end);
    if (end != p + n) goto bad;
    return DUCK_OK(DuckRes_float, d);
bad:
    return DUCK_ERR(DuckRes_float, duck_err_fmt("float.parse: invalid float \"%s\"", p));
}

bool duck_char_is_digit(uint32_t c) { return c >= '0' && c <= '9'; }
bool duck_char_is_alpha(uint32_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
bool duck_char_is_space(uint32_t c) { return c < 128 && is_ws((unsigned char)c); }
uint32_t duck_char_upper(uint32_t c) { return (c >= 'a' && c <= 'z') ? c - 32 : c; }
uint32_t duck_char_lower(uint32_t c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

DuckOpt_char duck_char_from_int(int64_t n) {
    if (n < 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF)) return DUCK_NONE(DuckOpt_char);
    return DUCK_SOME(DuckOpt_char, (uint32_t)n);
}

/* ---- formatting ------------------------------------------------------ */

DuckStr *duck_str_from_int(int64_t v) {
    char buf[32];
    int n = snprintf(buf, sizeof buf, "%lld", (long long)v);
    return duck__str_raw(buf, n, n, true);
}

void duck__fmt_float_shortest(double v, char *out, size_t outn) {
    if (isnan(v)) { snprintf(out, outn, "NaN"); return; }
    if (isinf(v)) { snprintf(out, outn, v < 0 ? "-inf" : "inf"); return; }
    if (v == 0) { snprintf(out, outn, signbit(v) ? "-0.0" : "0.0"); return; }
    char tmp[48];
    for (int prec = 0; prec <= 17; prec++) {
        snprintf(tmp, sizeof tmp, "%.*e", prec, v);
        if (strtod(tmp, NULL) == v) break;
    }
    /* tmp = [-]d[.ddd]e(+|-)XX */
    const char *p = tmp;
    bool neg = *p == '-';
    if (neg) p++;
    char digits[32];
    int nd = 0;
    for (; *p && *p != 'e'; p++)
        if (*p != '.') digits[nd++] = *p;
    while (nd > 1 && digits[nd - 1] == '0') nd--;
    int exp = atoi(p + 1);
    char res[64];
    int k = 0;
    if (neg) res[k++] = '-';
    if (exp < -6 || exp >= 21) {
        res[k++] = digits[0];
        if (nd > 1) {
            res[k++] = '.';
            for (int i = 1; i < nd; i++) res[k++] = digits[i];
        }
        k += snprintf(res + k, sizeof res - (size_t)k, "e%d", exp);
    } else {
        int point = exp + 1; /* digits before the decimal point */
        if (point <= 0) {
            res[k++] = '0';
            res[k++] = '.';
            for (int i = 0; i < -point; i++) res[k++] = '0';
            for (int i = 0; i < nd; i++) res[k++] = digits[i];
        } else if (point >= nd) {
            for (int i = 0; i < nd; i++) res[k++] = digits[i];
            for (int i = nd; i < point; i++) res[k++] = '0';
            res[k++] = '.';
            res[k++] = '0';
        } else {
            for (int i = 0; i < point; i++) res[k++] = digits[i];
            res[k++] = '.';
            for (int i = point; i < nd; i++) res[k++] = digits[i];
        }
    }
    res[k] = 0;
    snprintf(out, outn, "%s", res);
}

DuckStr *duck_str_from_float(double v) {
    char buf[64];
    duck__fmt_float_shortest(v, buf, sizeof buf);
    int64_t n = (int64_t)strlen(buf);
    return duck__str_raw(buf, n, n, true);
}

DuckStr *duck_str_from_char(uint32_t c) {
    char buf[4];
    int n = duck_utf8_encode(c, buf);
    return duck__str_raw(buf, n, 1, n == 1);
}

DuckStr *duck_str_from_bool(bool b) { return duck_str_lit(b ? "true" : "false"); }

static void quote_char(DuckStrBuf *b, uint32_t c, char q) {
    switch (c) {
    case '\n': duck_sb_lit(b, "\\n"); return;
    case '\t': duck_sb_lit(b, "\\t"); return;
    case '\r': duck_sb_lit(b, "\\r"); return;
    case '\0': duck_sb_lit(b, "\\0"); return;
    case '\\': duck_sb_lit(b, "\\\\"); return;
    default: break;
    }
    if (c == (uint32_t)q) {
        duck_sb_char(b, '\\');
        duck_sb_char(b, c);
    } else if (c < 0x20 || c == 0x7F) {
        duck_sb_printf(b, "\\u{%X}", c);
    } else {
        duck_sb_char(b, c);
    }
}

DuckStr *duck_str_quote(const DuckStr *s) {
    DuckStrBuf b = DUCK_SB_INIT;
    duck_sb_char(&b, '"');
    const char *p = duck_str_cstr(s);
    int64_t n = duck_str_byte_len(s), i = 0;
    while (i < n && !duck__show_exhausted()) {
        int len;
        uint32_t c = duck__utf8_decode(p + i, &len);
        quote_char(&b, c, '"');
        i += len;
    }
    duck_sb_char(&b, '"');
    return duck_sb_finish(&b);
}

DuckStr *duck_char_quote(uint32_t c) {
    DuckStrBuf b = DUCK_SB_INIT;
    duck_sb_char(&b, '\'');
    quote_char(&b, c, '\'');
    duck_sb_char(&b, '\'');
    return duck_sb_finish(&b);
}

/* ---- format specs ---------------------------------------------------- */

typedef struct {
    uint32_t fill;
    char align; /* 0, '<', '>', '^' */
    bool zero;
    int64_t width; /* -1 = none */
    int64_t prec;  /* -1 = none */
} Spec;

static Spec parse_spec(const char *spec) {
    Spec sp = {' ', 0, false, -1, -1};
    if (!spec) return sp;
    const char *p = spec;
    if (*p) {
        int len;
        uint32_t c = duck__utf8_decode(p, &len);
        if (p[len] == '<' || p[len] == '>' || p[len] == '^') {
            sp.fill = c;
            sp.align = p[len];
            p += len + 1;
        } else if (*p == '<' || *p == '>' || *p == '^') {
            sp.align = *p++;
        }
    }
    if (*p == '0') {
        sp.zero = true;
        p++;
    }
    if (*p >= '0' && *p <= '9') {
        sp.width = 0;
        while (*p >= '0' && *p <= '9') sp.width = sp.width * 10 + (*p++ - '0');
    }
    if (*p == '.') {
        p++;
        if (!(*p >= '0' && *p <= '9')) duck_panic("format", "bad format spec \"%s\"", spec);
        sp.prec = 0;
        while (*p >= '0' && *p <= '9') sp.prec = sp.prec * 10 + (*p++ - '0');
    }
    if (*p) duck_panic("format", "bad format spec \"%s\"", spec);
    if (sp.width > 1 << 20 || sp.prec > 1 << 20) duck_panic("format", "format spec \"%s\" is too large", spec);
    return sp;
}

/* Pad body (owned, consumed) according to sp. */
static DuckStr *pad(DuckStr *body, const Spec *sp, bool numeric) {
    int64_t n = duck_str_len(body);
    if (sp->width <= n) return body;
    int64_t extra = sp->width - n;
    DuckStrBuf b = DUCK_SB_INIT;
    const char *p = duck_str_cstr(body);
    if (numeric && sp->zero && !sp->align) {
        int64_t i = 0;
        if (p[0] == '-' || p[0] == '+') duck_sb_bytes(&b, p, 1), i = 1;
        for (int64_t k = 0; k < extra; k++) duck_sb_char(&b, '0');
        duck_sb_bytes(&b, p + i, duck_str_byte_len(body) - i);
    } else {
        char al = sp->align ? sp->align : (numeric ? '>' : '<');
        int64_t left = al == '>' ? extra : al == '^' ? extra / 2 : 0;
        for (int64_t k = 0; k < left; k++) duck_sb_char(&b, sp->fill);
        duck_sb_str(&b, body);
        for (int64_t k = 0; k < extra - left; k++) duck_sb_char(&b, sp->fill);
    }
    duck_release(body);
    return duck_sb_finish(&b);
}

DuckStr *duck_fmt_int(int64_t v, const char *spec) {
    Spec sp = parse_spec(spec);
    return pad(duck_str_from_int(v), &sp, true);
}

DuckStr *duck_fmt_float(double v, const char *spec) {
    Spec sp = parse_spec(spec);
    DuckStr *body;
    if (sp.prec >= 0 && isfinite(v)) {
        int n = snprintf(NULL, 0, "%.*f", (int)sp.prec, v);
        char *buf = duck__xmalloc((size_t)n + 1);
        snprintf(buf, (size_t)n + 1, "%.*f", (int)sp.prec, v);
        body = duck__str_raw(buf, n, n, true);
        free(buf);
    } else {
        body = duck_str_from_float(v);
    }
    return pad(body, &sp, true);
}

DuckStr *duck_fmt_str(const DuckStr *s, const char *spec) {
    Spec sp = parse_spec(spec);
    DuckStr *body;
    if (sp.prec >= 0 && sp.prec < duck_str_len(s)) body = duck_str_slice(s, 0, sp.prec, NULL);
    else body = s ? duck_retain((void *)s) : duck_str_lit("");
    return pad(body, &sp, false);
}

DuckStr *duck_fmt_char(uint32_t c, const char *spec) {
    Spec sp = parse_spec(spec);
    return pad(duck_str_from_char(c), &sp, false);
}

DuckStr *duck_fmt_bool(bool v, const char *spec) {
    Spec sp = parse_spec(spec);
    return pad(duck_str_from_bool(v), &sp, false);
}

/* ---- builder --------------------------------------------------------- */

static void sb_reserve(DuckStrBuf *b, int64_t extra) {
    if (b->len + extra + 1 <= b->cap) return;
    int64_t cap = b->cap ? b->cap * 2 : 32;
    while (cap < b->len + extra + 1) cap *= 2;
    b->buf = duck__xrealloc(b->buf, (size_t)cap);
    b->cap = cap;
}

static void sb_put(DuckStrBuf *b, const char *p, int64_t n) {
    if (n <= 0) return;
    sb_reserve(b, n);
    memcpy(b->buf + b->len, p, (size_t)n);
    b->len += n;
}
/* Pieces of text count against a trace's show budget; whole strings (a part already built,
 * e.g. a field's show) don't, so a capped show is an exact prefix of the full one. */
void duck_sb_bytes(DuckStrBuf *b, const char *p, int64_t n) {
    if (duck__show_take(n)) sb_put(b, p, n);
}
void duck_sb_lit(DuckStrBuf *b, const char *cstr) { duck_sb_bytes(b, cstr, (int64_t)strlen(cstr)); }
void duck_sb_str(DuckStrBuf *b, const DuckStr *s) { sb_put(b, duck_str_cstr(s), duck_str_byte_len(s)); }
void duck_sb_str_own(DuckStrBuf *b, DuckStr *s) {
    duck_sb_str(b, s);
    duck_release(s);
}
void duck_sb_char(DuckStrBuf *b, uint32_t c) {
    char buf[4];
    duck_sb_bytes(b, buf, duck_utf8_encode(c, buf));
}
void duck_sb_printf(DuckStrBuf *b, const char *fmt, ...) {
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n > 0 && duck__show_take(n)) {
        sb_reserve(b, n);
        vsnprintf(b->buf + b->len, (size_t)n + 1, fmt, ap2);
        b->len += n;
    }
    va_end(ap2);
}
DuckStr *duck_sb_finish(DuckStrBuf *b) {
    DuckStr *s = duck_str_from_bytes(b->buf ? b->buf : "", b->len);
    duck_sb_free(b);
    return s;
}
void duck_sb_free(DuckStrBuf *b) {
    free(b->buf);
    *b = DUCK_SB_INIT;
}
