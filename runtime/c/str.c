/* Immutable UTF-8 strings, parsing, formatting and the string builder. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "auk_rt.h"

/* ---- the show budget ----------------------------------------------------------------------
 * While the tracer or the debugger shows a value, text appended to a builder counts against a
 * per-thread budget, so a huge value is shown as a prefix instead of in full. */

static _Thread_local int64_t show_left = -1;
static _Thread_local bool dbg_busy;

bool auk__dbg_busy(void) {
    return dbg_busy;
}

bool auk__dbg_set_busy(bool b) {
    bool old = dbg_busy;
    dbg_busy = b;
    return old;
}

int64_t auk__show_left(void) {
    return show_left;
}

void auk__set_show_left(int64_t v) {
    show_left = v;
}

static bool showing(void) {
    return atomic_load_explicit(&auk_trace_live, memory_order_relaxed) || dbg_busy;
}

bool auk__show_exhausted(void) {
    return showing() && show_left == 0;
}

/* Count n appended bytes against the budget; false: drop them. */
bool auk__show_take(int64_t n) {
    if (!showing() || show_left < 0) {
        return true;
    }
    if (show_left == 0) {
        return false;
    }
    show_left = n >= show_left ? 0 : show_left - n;
    return true;
}

/* ---- accessors --------------------------------------------------------------------------- */

static const uint8_t *sdata(const AukStr *s) {
    return s == NULL ? (const uint8_t *)"" : s->data;
}

static int64_t slen(const AukStr *s) {
    return s == NULL ? 0 : s->len_bytes;
}

AUK_API int64_t auk_str_len(const AukStr *s) {
    return s == NULL ? 0 : s->len_chars;
}

AUK_API int64_t auk_str_byte_len(const AukStr *s) {
    return s == NULL ? 0 : s->len_bytes;
}

AUK_API const char *auk_str_cstr(const AukStr *s) {
    return s == NULL ? "" : (const char *)s->data;
}

static bool is_ascii(const AukStr *s) {
    return s == NULL || s->is_ascii;
}

static int64_t arr_len(const AukArr *a) {
    return a == NULL ? 0 : a->len;
}

/* ---- UTF-8 ------------------------------------------------------------------------------- */

/* Is s[0..n) valid UTF-8? Then *chars and *ascii describe it. */
static bool utf8_valid(const uint8_t *s, int64_t n, int64_t *chars, bool *ascii) {
    int64_t i = 0;
    int64_t count = 0;
    bool all_ascii = true;
    while (i < n) {
        uint8_t c = s[i];
        if (c < 0x80) {
            i++;
        } else {
            all_ascii = false;
            int64_t len;
            uint32_t cp;
            if (c >= 0xC2 && c <= 0xDF) {
                len = 2;
                cp = c & 0x1F;
            } else if (c >= 0xE0 && c <= 0xEF) {
                len = 3;
                cp = c & 0x0F;
            } else if (c >= 0xF0 && c <= 0xF4) {
                len = 4;
                cp = c & 0x07;
            } else {
                return false;
            }
            if (i + len > n) {
                return false;
            }
            for (int64_t k = 1; k < len; k++) {
                if ((s[i + k] & 0xC0) != 0x80) {
                    return false;
                }
                cp = (cp << 6) | (s[i + k] & 0x3F);
            }
            if (len == 3 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) {
                return false;
            }
            if (len == 4 && (cp < 0x10000 || cp > 0x10FFFF)) {
                return false;
            }
            i += len;
        }
        count++;
    }
    *chars = count;
    *ascii = all_ascii;
    return true;
}

AUK_API bool auk_utf8_valid(const char *p, int64_t n, int64_t *chars_out, bool *ascii_out) {
    int64_t chars = 0;
    bool ascii = true;
    if (n > 0 && !utf8_valid((const uint8_t *)p, n, &chars, &ascii)) {
        return false;
    }
    if (chars_out != NULL) {
        *chars_out = chars;
    }
    if (ascii_out != NULL) {
        *ascii_out = ascii;
    }
    return true;
}

/* Length of the valid UTF-8 sequence at s[i..n), or 0 if invalid. */
static int64_t utf8_seq_len(const uint8_t *s, int64_t n, int64_t i) {
    if (s[i] < 0x80) {
        return 1;
    }
    for (int64_t len = 2; len <= 4; len++) {
        int64_t chars;
        bool ascii;
        if (i + len <= n && utf8_valid(s + i, len, &chars, &ascii) && chars == 1) {
            return len;
        }
    }
    return 0;
}

/* Byte k of s past i, or 0 past the end. */
static uint32_t byte_at(const uint8_t *s, int64_t n, int64_t i) {
    return i < n ? s[i] : 0;
}

/* Decode one char at s[i..n) (valid input); *len gets its length. Bytes past n read as 0. */
static uint32_t utf8_decode(const uint8_t *s, int64_t n, int64_t i, int64_t *len) {
    uint32_t b0 = s[i];
    if (b0 < 0x80) {
        *len = 1;
        return b0;
    }
    if (b0 < 0xE0) {
        *len = 2;
        return ((b0 & 0x1F) << 6) | (byte_at(s, n, i + 1) & 0x3F);
    }
    if (b0 < 0xF0) {
        *len = 3;
        return ((b0 & 0x0F) << 12) | ((byte_at(s, n, i + 1) & 0x3F) << 6) | (byte_at(s, n, i + 2) & 0x3F);
    }
    *len = 4;
    return ((b0 & 0x07) << 18) | ((byte_at(s, n, i + 1) & 0x3F) << 12) | ((byte_at(s, n, i + 2) & 0x3F) << 6) |
           (byte_at(s, n, i + 3) & 0x3F);
}

/* Encode c (surrogates and out-of-range become U+FFFD) into b; returns the length. */
static int utf8_encode(uint32_t c, uint8_t *b) {
    if (c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)) {
        c = 0xFFFD;
    }
    if (c < 0x80) {
        b[0] = (uint8_t)c;
        return 1;
    }
    if (c < 0x800) {
        b[0] = (uint8_t)(0xC0 | (c >> 6));
        b[1] = (uint8_t)(0x80 | (c & 0x3F));
        return 2;
    }
    if (c < 0x10000) {
        b[0] = (uint8_t)(0xE0 | (c >> 12));
        b[1] = (uint8_t)(0x80 | ((c >> 6) & 0x3F));
        b[2] = (uint8_t)(0x80 | (c & 0x3F));
        return 3;
    }
    b[0] = (uint8_t)(0xF0 | (c >> 18));
    b[1] = (uint8_t)(0x80 | ((c >> 12) & 0x3F));
    b[2] = (uint8_t)(0x80 | ((c >> 6) & 0x3F));
    b[3] = (uint8_t)(0x80 | (c & 0x3F));
    return 4;
}

AUK_API int auk_utf8_encode(uint32_t c, char *buf) {
    return utf8_encode(c, (uint8_t *)buf);
}

/* ---- the builder ------------------------------------------------------------------------- */

/* Where the builder's text is: its inline bytes or its heap buffer. */
static uint8_t *sb_data(AukStrBuf *b) {
    return b->buf == NULL ? b->small : b->buf;
}

static void sb_reserve(AukStrBuf *b, int64_t extra) {
    if (b->buf == NULL) {
        /* inline until the text outgrows it, then to the heap with what's there */
        if (b->len + extra <= AUK_SB_SMALL) {
            return;
        }
        int64_t cap = 2 * AUK_SB_SMALL;
        while (cap < b->len + extra + 1) {
            cap *= 2;
        }
        uint8_t *heap = auk__xmalloc((size_t)cap);
        memcpy(heap, b->small, (size_t)b->len);
        b->buf = heap;
        b->cap = cap;
        return;
    }
    if (b->len + extra < b->cap) {
        return;
    }
    int64_t cap = b->cap * 2;
    while (cap < b->len + extra + 1) {
        cap *= 2;
    }
    b->buf = auk__xrealloc(b->buf, (size_t)cap);
    b->cap = cap;
}

/* Append n bytes, outside the show budget (whole strings, message text). */
void auk__sb_put(AukStrBuf *b, const void *p, int64_t n) {
    if (n <= 0) {
        return;
    }
    sb_reserve(b, n);
    memcpy(sb_data(b) + b->len, p, (size_t)n);
    b->len += n;
}

void auk__sb_put_cstr(AukStrBuf *b, const char *s) {
    auk__sb_put(b, s, (int64_t)strlen(s));
}

/* Append n bytes as a piece of text: it counts against the show budget. Whole strings (a part
 * already built, e.g. a field's show) don't, so a capped show is an exact prefix of the full
 * one. */
AUK_API void auk_sb_bytes(AukStrBuf *b, const char *p, int64_t n) {
    if (auk__show_take(n)) {
        auk__sb_put(b, p, n);
    }
}

AUK_API void auk_sb_lit(AukStrBuf *b, const char *cstr) {
    auk_sb_bytes(b, cstr, cstr == NULL ? 0 : (int64_t)strlen(cstr));
}

AUK_API void auk_sb_str(AukStrBuf *b, const AukStr *s) {
    auk__sb_put(b, sdata(s), slen(s));
}

AUK_API void auk_sb_str_own(AukStrBuf *b, AukStr *s) {
    auk_sb_str(b, s);
    auk_release(s);
}

AUK_API void auk_sb_char(AukStrBuf *b, uint32_t c) {
    uint8_t buf[4];
    int n = utf8_encode(c, buf);
    auk_sb_bytes(b, (const char *)buf, n);
}

AUK_API AukStr *auk_sb_finish(AukStrBuf *b) {
    AukStr *s = auk_str_from_bytes((const char *)sb_data(b), b->len);
    auk_sb_free(b);
    return s;
}

AUK_API void auk_sb_free(AukStrBuf *b) {
    free(b->buf);
    b->buf = NULL;
    b->len = 0;
    b->cap = 0;
}

/* Panic with the builder's text (it is consumed). */
_Noreturn void auk__panic_sb(const char *loc, AukStrBuf *b) {
    /* copied out (bounded like every panic message) so the builder can be freed first */
    char m[2048];
    size_t n = b->len < (int64_t)sizeof m ? (size_t)b->len : sizeof m;
    memcpy(m, sb_data(b), n);
    auk_sb_free(b);
    auk__panic_bytes(loc, m, n);
}

/* A new error with the builder's text (it is consumed). */
AukErr *auk__err_sb(AukStrBuf *b) {
    AukErr *e = auk__err_bytes((const char *)sb_data(b), (size_t)b->len);
    auk_sb_free(b);
    return e;
}

/* ---- construction ------------------------------------------------------------------------ */

/* A string from n bytes at p whose metadata is already known. */
AukStr *auk__str_raw(const char *p, int64_t n, int64_t chars, bool ascii) {
    AukStr *s = auk__alloc(sizeof(AukStr) + (size_t)n + 1, AUK_K_STR);
    if (n > 0) {
        memcpy(s->data, p, (size_t)n);
    }
    s->data[n] = 0;
    s->len_bytes = n;
    s->len_chars = chars;
    s->is_ascii = ascii;
    return s;
}

/* A string from bytes already known to be valid UTF-8. */
AukStr *auk__str_new(const char *p, int64_t n) {
    int64_t chars = 0;
    bool ascii = true;
    for (int64_t i = 0; i < n; i++) {
        uint8_t u = (uint8_t)p[i];
        if (u >= 0x80) {
            ascii = false;
        }
        if ((u & 0xC0) != 0x80) {
            chars++;
        }
    }
    return auk__str_raw(p, n, chars, ascii);
}

/* A string from arbitrary bytes, each invalid byte replaced with U+FFFD. */
AUK_API AukStr *auk_str_from_bytes(const char *p, int64_t n) {
    if (n <= 0 || p == NULL) {
        return auk__str_raw("", 0, 0, true);
    }
    const uint8_t *s = (const uint8_t *)p;
    int64_t chars;
    bool ascii;
    if (utf8_valid(s, n, &chars, &ascii)) {
        return auk__str_raw(p, n, chars, ascii);
    }
    AukStrBuf b = {0};
    int64_t i = 0;
    while (i < n) {
        int64_t len = utf8_seq_len(s, n, i);
        if (len != 0) {
            auk_sb_bytes(&b, p + i, len);
            i += len;
        } else {
            auk_sb_bytes(&b, "\xEF\xBF\xBD", 3);
            i++;
        }
    }
    return auk_sb_finish(&b);
}

AUK_API AukStr *auk_str_lit(const char *cstr) {
    return auk_str_from_bytes(cstr, cstr == NULL ? 0 : (int64_t)strlen(cstr));
}

static AukRes_str res_str_err(AukErr *e) {
    AukRes_str r = {0};
    r.ok = false;
    r.err = e;
    return r;
}

static AukRes_str try_from_bytes(const uint8_t *s, int64_t n) {
    int64_t chars = 0;
    bool ascii = true;
    if (n <= 0 || utf8_valid(s, n, &chars, &ascii)) {
        AukRes_str r = {0};
        r.ok = true;
        r.val = auk__str_raw((const char *)s, n < 0 ? 0 : n, chars, ascii);
        return r;
    }
    int64_t i = 0;
    while (i < n) {
        int64_t len = utf8_seq_len(s, n, i);
        if (len == 0) {
            break;
        }
        i += len;
    }
    AukStrBuf b = {0};
    auk__sb_put_cstr(&b, "invalid UTF-8 at byte ");
    auk_sb_int(&b, i);
    return res_str_err(auk__err_sb(&b));
}

AUK_API AukRes_str auk_str_try_from_bytes(const char *p, int64_t n) {
    return try_from_bytes((const uint8_t *)p, n);
}

AUK_API AukRes_str auk_str_from_utf8(AukArr *bytes) {
    int64_t n = arr_len(bytes);
    const int64_t *xs = n > 0 ? (const int64_t *)bytes->data : NULL;
    uint8_t *buf = auk__xmalloc((size_t)n + 1);
    for (int64_t i = 0; i < n; i++) {
        int64_t x = xs[i];
        if (x < 0 || x > 255) {
            free(buf);
            AukStrBuf b = {0};
            auk__sb_put_cstr(&b, "byte ");
            auk_sb_int(&b, x);
            auk__sb_put_cstr(&b, " at index ");
            auk_sb_int(&b, i);
            auk__sb_put_cstr(&b, " is out of range 0..255");
            return res_str_err(auk__err_sb(&b));
        }
        buf[i] = (uint8_t)x;
    }
    AukRes_str r = try_from_bytes(buf, n);
    free(buf);
    return r;
}

/* ---- indexing ---------------------------------------------------------------------------- */

int64_t auk__str_byte_offset(const AukStr *s, int64_t i) {
    if (s == NULL) {
        return 0;
    }
    if (s->is_ascii) {
        return i;
    }
    if (i >= s->len_chars) {
        return s->len_bytes;
    }
    const uint8_t *p = s->data;
    int64_t n = s->len_bytes;
    int64_t b = 0;
    for (int64_t c = 0; c < i; c++) {
        b++;
        while (b < n && (p[b] & 0xC0) == 0x80) {
            b++;
        }
    }
    return b;
}

AUK_API uint32_t auk_str_char_at(const AukStr *s, int64_t i, const char *loc) {
    int64_t n = auk_str_len(s);
    if (i < 0 || i >= n) {
        AukStrBuf b = {0};
        auk__sb_put_cstr(&b, "index ");
        auk_sb_int(&b, i);
        auk__sb_put_cstr(&b, " out of range for string of length ");
        auk_sb_int(&b, n);
        auk__panic_sb(loc, &b);
    }
    if (s->is_ascii) {
        return s->data[i];
    }
    int64_t len;
    return utf8_decode(s->data, s->len_bytes, auk__str_byte_offset(s, i), &len);
}

AUK_API AukOpt_char auk_str_get(const AukStr *s, int64_t i) {
    AukOpt_char r = {0};
    if (i < 0 || i >= auk_str_len(s)) {
        return r;
    }
    r.some = true;
    r.val = auk_str_char_at(s, i, NULL);
    return r;
}

AUK_API AukStr *auk_str_slice(const AukStr *s, int64_t a, int64_t b, const char *loc) {
    int64_t n = auk_str_len(s);
    if (a < 0 || b < a || b > n) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "slice ");
        auk_sb_int(&m, a);
        auk__sb_put_cstr(&m, "..");
        auk_sb_int(&m, b);
        auk__sb_put_cstr(&m, " out of range for string of length ");
        auk_sb_int(&m, n);
        auk__panic_sb(loc, &m);
    }
    if (a == 0 && b == n && s != NULL) {
        return auk_retain((void *)s);
    }
    int64_t ba = auk__str_byte_offset(s, a);
    int64_t bb = auk__str_byte_offset(s, b);
    return auk__str_raw((const char *)sdata(s) + ba, bb - ba, b - a, is_ascii(s));
}

AUK_API AukStr *auk_str_concat(const AukStr *a, const AukStr *b) {
    int64_t na = slen(a);
    int64_t nb = slen(b);
    AukStr *s = auk__alloc(sizeof(AukStr) + (size_t)(na + nb) + 1, AUK_K_STR);
    memcpy(s->data, sdata(a), (size_t)na);
    memcpy(s->data + na, sdata(b), (size_t)nb);
    s->data[na + nb] = 0;
    s->len_bytes = na + nb;
    s->len_chars = auk_str_len(a) + auk_str_len(b);
    s->is_ascii = is_ascii(a) && is_ascii(b);
    return s;
}

AUK_API void auk_str_append(AukStr **ps, const AukStr *b) {
    AukStr *a = *ps;
    int64_t nb = slen(b);
    if (nb == 0) {
        return;
    }
    if (a == NULL || atomic_load_explicit(&a->h.rc, memory_order_acquire) != 1) {
        *ps = auk_str_concat(a, b);
        auk_release(a);
        return;
    }
    /* unique: nobody else can see a change; grow in place */
    int64_t na = a->len_bytes;
    int64_t chars = auk_str_len(b);
    bool ascii = is_ascii(b);
    size_t need = sizeof(AukStr) + (size_t)(na + nb) + 1;
    if (auk__heap_usable(&a->h) < need) {
        size_t want = sizeof(AukStr) + (size_t)(na + nb) * 2 + 1;
        bool self = a == b;
        a = (AukStr *)auk__heap_resize(&a->h, want);
        if (self) {
            b = a;
        }
    }
    memmove(a->data + na, sdata(b), (size_t)nb);
    a->data[na + nb] = 0;
    a->len_bytes = na + nb;
    a->len_chars += chars;
    a->is_ascii = a->is_ascii && ascii;
    *ps = a;
}

static bool bytes_eq(const uint8_t *a, int64_t na, const uint8_t *b, int64_t nb) {
    return na == nb && memcmp(a, b, (size_t)na) == 0;
}

AUK_API bool auk_str_eq(const AukStr *a, const AukStr *b) {
    return a == b || bytes_eq(sdata(a), slen(a), sdata(b), slen(b));
}

AUK_API bool auk_str_eq_lit(const AukStr *s, const char *lit) {
    const char *l = lit == NULL ? "" : lit;
    return bytes_eq(sdata(s), slen(s), (const uint8_t *)l, (int64_t)strlen(l));
}

AUK_API int64_t auk_str_switch(const AukStr *s, const AukStrCase *cases, int64_t n) {
    const uint8_t *d = sdata(s);
    int64_t len = slen(s);
    int64_t lo = 0, hi = n;
    while (lo < hi) {
        int64_t mid = lo + (hi - lo) / 2;
        const AukStrCase *c = &cases[mid];
        int r = c->len < len ? -1 : c->len > len ? 1 : len == 0 ? 0 : memcmp(c->s, d, (size_t)len);
        if (r == 0) {
            return mid;
        }
        if (r < 0) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return -1;
}

/* memcmp on the common prefix, then length: exactly lexicographic byte order. */
AUK_API int auk_str_cmp(const AukStr *a, const AukStr *b) {
    int64_t na = slen(a);
    int64_t nb = slen(b);
    int c = memcmp(sdata(a), sdata(b), (size_t)(na < nb ? na : nb));
    if (c != 0) {
        return c < 0 ? -1 : 1;
    }
    return (na > nb) - (na < nb);
}

AUK_API uint64_t auk_str_hash(const AukStr *s) {
    return auk_hash_bytes(sdata(s), (size_t)slen(s));
}

void auk__str_free(AukStr *s) {
    auk__free_obj(s);
}

/* ---- searching --------------------------------------------------------------------------- */

/* Byte offset of needle in hay starting at from, or -1. */
static int64_t find_bytes(const uint8_t *hay, int64_t hn, const uint8_t *needle, int64_t nn, int64_t from) {
    if (nn == 0) {
        return from <= hn ? from : -1;
    }
    int64_t i = from;
    while (i + nn <= hn) {
        const uint8_t *at = memchr(hay + i, needle[0], (size_t)(hn - nn + 1 - i));
        if (at == NULL) {
            return -1;
        }
        i = at - hay;
        if (memcmp(hay + i, needle, (size_t)nn) == 0) {
            return i;
        }
        i++;
    }
    return -1;
}

static int64_t chars_in(const uint8_t *p, int64_t n) {
    int64_t c = 0;
    for (int64_t i = 0; i < n; i++) {
        if ((p[i] & 0xC0) != 0x80) {
            c++;
        }
    }
    return c;
}

/* Sub-string by byte range [a, b) of s (valid UTF-8, a and b on boundaries). */
static AukStr *sub_bytes(const AukStr *s, int64_t a, int64_t b) {
    if (s != NULL && a == 0 && b == s->len_bytes) {
        return auk_retain((void *)s);
    }
    const uint8_t *p = sdata(s) + a;
    bool ascii = is_ascii(s);
    return auk__str_raw((const char *)p, b - a, ascii ? b - a : chars_in(p, b - a), ascii);
}

static void push_own(AukArr **a, AukStr *s) {
    auk_arr_push(a, &s);
    auk_release(s);
}

static bool is_ws(uint8_t c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0x0B || c == 0x0C;
}

AUK_API AukArr *auk_str_split_ws(const AukStr *s) {
    AukArr *out = auk_arr_new(&auk_ops_str, 0);
    const uint8_t *p = sdata(s);
    int64_t n = slen(s);
    int64_t i = 0;
    while (i < n) {
        while (i < n && is_ws(p[i])) {
            i++;
        }
        if (i >= n) {
            break;
        }
        int64_t st = i;
        while (i < n && !is_ws(p[i])) {
            i++;
        }
        push_own(&out, sub_bytes(s, st, i));
    }
    return out;
}

AUK_API AukArr *auk_str_split(const AukStr *s, const AukStr *sep) {
    AukArr *out = auk_arr_new(&auk_ops_str, 0);
    const uint8_t *p = sdata(s);
    int64_t n = slen(s);
    int64_t sn = slen(sep);
    if (sn == 0) {
        int64_t i = 0;
        while (i < n) {
            int64_t len;
            utf8_decode(p, n, i, &len);
            push_own(&out, sub_bytes(s, i, i + len));
            i += len;
        }
        return out;
    }
    int64_t st = 0;
    for (;;) {
        int64_t at = find_bytes(p, n, sdata(sep), sn, st);
        if (at < 0) {
            break;
        }
        push_own(&out, sub_bytes(s, st, at));
        st = at + sn;
    }
    push_own(&out, sub_bytes(s, st, n));
    return out;
}

AUK_API AukStr *auk_str_trim_start(const AukStr *s) {
    const uint8_t *p = sdata(s);
    int64_t n = slen(s);
    int64_t a = 0;
    while (a < n && is_ws(p[a])) {
        a++;
    }
    return sub_bytes(s, a, n);
}

AUK_API AukStr *auk_str_trim_end(const AukStr *s) {
    const uint8_t *p = sdata(s);
    int64_t b = slen(s);
    while (b > 0 && is_ws(p[b - 1])) {
        b--;
    }
    return sub_bytes(s, 0, b);
}

AUK_API AukStr *auk_str_trim(const AukStr *s) {
    const uint8_t *p = sdata(s);
    int64_t n = slen(s);
    int64_t a = 0;
    int64_t b = n;
    while (a < n && is_ws(p[a])) {
        a++;
    }
    while (b > a && is_ws(p[b - 1])) {
        b--;
    }
    return sub_bytes(s, a, b);
}

AUK_API AukArr *auk_str_lines(const AukStr *s) {
    AukArr *out = auk_arr_new(&auk_ops_str, 0);
    const uint8_t *p = sdata(s);
    int64_t n = slen(s);
    int64_t st = 0;
    while (st < n) {
        const uint8_t *nl = memchr(p + st, '\n', (size_t)(n - st));
        int64_t end = nl == NULL ? n : nl - p;
        int64_t e = end;
        if (e > st && p[e - 1] == '\r') {
            e--;
        }
        push_own(&out, sub_bytes(s, st, e));
        st = end + 1;
    }
    return out;
}

AUK_API bool auk_str_starts_with(const AukStr *s, const AukStr *pre) {
    int64_t n = slen(pre);
    return n <= slen(s) && memcmp(sdata(s), sdata(pre), (size_t)n) == 0;
}

AUK_API bool auk_str_ends_with(const AukStr *s, const AukStr *suf) {
    int64_t n = slen(suf);
    int64_t sn = slen(s);
    return n <= sn && memcmp(sdata(s) + sn - n, sdata(suf), (size_t)n) == 0;
}

AUK_API bool auk_str_contains(const AukStr *s, const AukStr *sub) {
    return find_bytes(sdata(s), slen(s), sdata(sub), slen(sub), 0) >= 0;
}

AUK_API AukOpt_int auk_str_find(const AukStr *s, const AukStr *sub) {
    AukOpt_int r = {0};
    const uint8_t *p = sdata(s);
    int64_t at = find_bytes(p, slen(s), sdata(sub), slen(sub), 0);
    if (at < 0) {
        return r;
    }
    r.some = true;
    r.val = s != NULL && s->is_ascii ? at : chars_in(p, at);
    return r;
}

AUK_API AukStr *auk_str_replace(const AukStr *s, const AukStr *from, const AukStr *to) {
    const uint8_t *f = sdata(from);
    int64_t fn = slen(from);
    const uint8_t *p = sdata(s);
    int64_t n = slen(s);
    if (fn == 0) {
        return s == NULL ? auk_str_lit("") : auk_retain((void *)s);
    }
    AukStrBuf b = {0};
    int64_t st = 0;
    for (;;) {
        int64_t at = find_bytes(p, n, f, fn, st);
        if (at < 0) {
            break;
        }
        auk_sb_bytes(&b, (const char *)p + st, at - st);
        auk_sb_str(&b, to);
        st = at + fn;
    }
    auk_sb_bytes(&b, (const char *)p + st, n - st);
    return auk_sb_finish(&b);
}

static AukStr *map_ascii(const AukStr *s, bool up) {
    AukStr *r = auk__str_raw((const char *)sdata(s), slen(s), auk_str_len(s), is_ascii(s));
    for (int64_t i = 0; i < r->len_bytes; i++) {
        uint8_t c = r->data[i];
        if (up && c >= 'a' && c <= 'z') {
            r->data[i] = (uint8_t)(c - 32);
        }
        if (!up && c >= 'A' && c <= 'Z') {
            r->data[i] = (uint8_t)(c + 32);
        }
    }
    return r;
}

AUK_API AukStr *auk_str_upper(const AukStr *s) {
    return map_ascii(s, true);
}

AUK_API AukStr *auk_str_lower(const AukStr *s) {
    return map_ascii(s, false);
}

AUK_API AukStr *auk_str_repeat(const AukStr *s, int64_t n, const char *loc) {
    if (n < 0) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "repeat count ");
        auk_sb_int(&m, n);
        auk__sb_put_cstr(&m, " is negative");
        auk__panic_sb(loc, &m);
    }
    int64_t bl = slen(s);
    int64_t total;
    if (__builtin_mul_overflow(bl, n, &total)) {
        auk_panic_overflow(loc, "repeat");
    }
    AukStr *r = auk__alloc(sizeof(AukStr) + (size_t)total + 1, AUK_K_STR);
    if (bl > 0) {
        for (int64_t i = 0; i < n; i++) {
            memcpy(r->data + i * bl, sdata(s), (size_t)bl);
        }
    }
    r->data[total] = 0;
    r->len_bytes = total;
    r->len_chars = (int64_t)((uint64_t)auk_str_len(s) * (uint64_t)n);
    r->is_ascii = is_ascii(s);
    return r;
}

AUK_API AukArr *auk_str_chars(const AukStr *s) {
    int64_t n = auk_str_len(s);
    AukArr *out = auk_arr_new(&auk_ops_char, n);
    uint32_t *d = auk_arr_make_unique(&out);
    const uint8_t *p = sdata(s);
    int64_t bn = slen(s);
    if (is_ascii(s)) {
        for (int64_t i = 0; i < bn; i++) {
            d[i] = p[i];
        }
        out->len = bn;
        return out;
    }
    int64_t i = 0;
    int64_t k = 0;
    while (i < bn) {
        int64_t len;
        d[k++] = utf8_decode(p, bn, i, &len);
        i += len;
    }
    out->len = k;
    return out;
}

AUK_API AukArr *auk_str_bytes(const AukStr *s) {
    const uint8_t *p = sdata(s);
    int64_t n = slen(s);
    AukArr *out = auk_arr_new(&auk_ops_int, n);
    int64_t *d = auk_arr_make_unique(&out);
    for (int64_t i = 0; i < n; i++) {
        d[i] = p[i];
    }
    out->len = n;
    return out;
}

/* The UTF-8 length of char c (a surrogate or out-of-range value becomes U+FFFD: 3 bytes). */
static int utf8_len(uint32_t c) {
    if (c < 0x80) {
        return 1;
    }
    if (c < 0x800) {
        return 2;
    }
    if (c < 0x10000 || c > 0x10FFFF) {
        return 3;
    }
    return 4;
}

/* One pass to size the string, one to encode straight into it (no builder, no copy). */
static AukStr *str_of_chars(const uint32_t *cs, int64_t n) {
    int64_t bytes = 0;
    uint32_t any = 0;
    for (int64_t i = 0; i < n; i++) {
        any |= cs[i];
    }
    bool ascii = any < 0x80;
    if (ascii) {
        bytes = n;
    } else {
        for (int64_t i = 0; i < n; i++) {
            bytes += utf8_len(cs[i]);
        }
    }
    AukStr *s = auk__alloc(sizeof(AukStr) + (size_t)bytes + 1, AUK_K_STR);
    uint8_t *d = s->data;
    if (ascii) {
        for (int64_t i = 0; i < n; i++) {
            d[i] = (uint8_t)cs[i];
        }
    } else {
        for (int64_t i = 0; i < n; i++) {
            d += utf8_encode(cs[i], d);
        }
    }
    s->data[bytes] = 0;
    s->len_bytes = bytes;
    s->len_chars = n;
    s->is_ascii = ascii;
    return s;
}

AUK_API AukStr *auk_str_from_chars(AukArr *chars) {
    int64_t n = arr_len(chars);
    return str_of_chars(n > 0 ? (const uint32_t *)chars->data : NULL, n);
}

AUK_API AukStr *auk_str_from_char_range(AukArr *chars, int64_t lo, int64_t hi, const char *loc) {
    int64_t n = arr_len(chars);
    if (lo < 0 || hi < lo || hi > n) {
        auk_arr_slice(chars, lo, hi, loc); /* panics with the slice's message */
    }
    return str_of_chars(hi > lo ? (const uint32_t *)chars->data + lo : NULL, hi - lo);
}

/* ---- parsing ----------------------------------------------------------------------------- */

/* "<a>\"<s up to a NUL>\"<b>" as a new error. */
static AukErr *quoted_err(const char *a, const AukStr *s, const char *b) {
    AukStrBuf m = {0};
    auk__sb_put_cstr(&m, a);
    auk__sb_put_cstr(&m, "\"");
    auk__sb_put_cstr(&m, auk_str_cstr(s));
    auk__sb_put_cstr(&m, "\"");
    auk__sb_put_cstr(&m, b);
    return auk__err_sb(&m);
}

static bool is_digit(uint8_t c) {
    return c >= '0' && c <= '9';
}

AUK_API AukRes_int auk_int_parse(const AukStr *s) {
    AukRes_int r = {0};
    const uint8_t *p = sdata(s);
    int64_t n = slen(s);
    int64_t i = 0;
    bool neg = false;
    if (i < n && (p[i] == '+' || p[i] == '-')) {
        neg = p[i] == '-';
        i++;
    }
    if (i >= n) {
        r.err = quoted_err("int.parse: invalid int ", s, "");
        return r;
    }
    uint64_t acc = 0;
    uint64_t limit = neg ? (uint64_t)INT64_MAX + 1 : (uint64_t)INT64_MAX;
    bool prev_digit = false;
    while (i < n) {
        uint8_t c = p[i];
        if (c == '_' && prev_digit && i + 1 < n && is_digit(p[i + 1])) {
            prev_digit = false;
            i++;
            continue;
        }
        if (!is_digit(c)) {
            r.err = quoted_err("int.parse: invalid int ", s, "");
            return r;
        }
        uint64_t d = (uint64_t)(c - '0');
        if (acc > (limit - d) / 10) {
            r.err = quoted_err("int.parse: ", s, " is out of range");
            return r;
        }
        acc = acc * 10 + d;
        prev_digit = true;
        i++;
    }
    r.ok = true;
    if (neg) {
        r.val = acc == (uint64_t)INT64_MAX + 1 ? INT64_MIN : -(int64_t)acc;
    } else {
        r.val = (int64_t)acc;
    }
    return r;
}

AUK_API AukRes_float auk_float_parse(const AukStr *s) {
    AukRes_float r = {0};
    const uint8_t *p = sdata(s);
    int64_t n = slen(s);
    bool bad = n == 0 || is_ws(p[0]) || (int64_t)strlen((const char *)p) != n;
    /* reject hex floats and other strtod extras */
    for (int64_t i = 0; i < n && !bad; i++) {
        if (p[i] == 'x' || p[i] == 'X' || p[i] == '(') {
            bad = true;
        }
    }
    if (!bad) {
        char *end = NULL;
        double d = strtod((const char *)p, &end);
        if (end == (const char *)p + n) {
            r.ok = true;
            r.val = d;
            return r;
        }
    }
    r.err = quoted_err("float.parse: invalid float ", s, "");
    return r;
}

AUK_API bool auk_char_is_digit(uint32_t c) {
    return c >= '0' && c <= '9';
}

AUK_API bool auk_char_is_alpha(uint32_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

AUK_API bool auk_char_is_space(uint32_t c) {
    return c < 128 && is_ws((uint8_t)c);
}

AUK_API uint32_t auk_char_upper(uint32_t c) {
    return c >= 'a' && c <= 'z' ? c - 32 : c;
}

AUK_API uint32_t auk_char_lower(uint32_t c) {
    return c >= 'A' && c <= 'Z' ? c + 32 : c;
}

AUK_API AukOpt_char auk_char_from_int(int64_t n) {
    AukOpt_char r = {0};
    if (n < 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF)) {
        return r;
    }
    r.some = true;
    r.val = (uint32_t)n;
    return r;
}

/* ---- formatting -------------------------------------------------------------------------- */

/* v in decimal, written into the end of buf (20 bytes); returns where it starts. */
static int int_digits(int64_t v, char *buf) {
    int i = 20;
    uint64_t n = v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
    do {
        buf[--i] = (char)('0' + n % 10);
        n /= 10;
    } while (n != 0);
    if (v < 0) {
        buf[--i] = '-';
    }
    return i;
}

AUK_API AukStr *auk_str_from_int(int64_t v) {
    char buf[20];
    int at = int_digits(v, buf);
    return auk__str_raw(buf + at, 20 - at, 20 - at, true);
}

/* Append v in decimal (what interpolating an int does: no temporary string). */
AUK_API void auk_sb_int(AukStrBuf *b, int64_t v) {
    char buf[20];
    int at = int_digits(v, buf);
    auk__sb_put(b, buf + at, 20 - at);
}

/* ---- text without printf ------------------------------------------------------------------
 * The runtime calls no varargs function except through cwrap.c (docs/runtime-port.md): numbers
 * are formatted here, messages are built with the builder (outside the show budget) and then
 * copied, printed or duplicated. */

/* v in decimal into out (at least 21 bytes), NUL-terminated: its length (`%lld`). */
int auk__fmt_i64(char *out, int64_t v) {
    char buf[20];
    int at = int_digits(v, buf);
    int n = 20 - at;
    memcpy(out, buf + at, (size_t)n);
    out[n] = 0;
    return n;
}

/* v in decimal into out (at least 21 bytes), NUL-terminated: its length (`%llu`). */
int auk__fmt_u64(char *out, uint64_t v) {
    char buf[20];
    int i = 20;
    do {
        buf[--i] = (char)('0' + v % 10);
        v /= 10;
    } while (v != 0);
    int n = 20 - i;
    memcpy(out, buf + i, (size_t)n);
    out[n] = 0;
    return n;
}

/* v in hex (upper or lower case digits, at least min_digits of them: 1..16) into out (at least
 * 17 bytes), NUL-terminated: its length (`%llx`, `%016llx`, `%X`). */
int auk__fmt_hex(char *out, uint64_t v, int min_digits, bool upper) {
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    char buf[16];
    int i = 16;
    do {
        buf[--i] = digits[v & 15];
        v >>= 4;
    } while (v != 0);
    while (16 - i < min_digits) {
        buf[--i] = '0';
    }
    int n = 16 - i;
    memcpy(out, buf + i, (size_t)n);
    out[n] = 0;
    return n;
}

/* s into out[0..cap), cut to cap - 1 bytes and NUL-terminated (`snprintf(out, cap, "%s", s)`). */
void auk__cstr_copy(char *out, size_t cap, const char *s) {
    if (cap == 0) {
        return;
    }
    size_t n = strlen(s);
    if (n > cap - 1) {
        n = cap - 1;
    }
    memcpy(out, s, n);
    out[n] = 0;
}

/* Append v in decimal, outside the show budget. */
void auk__sb_u64(AukStrBuf *b, uint64_t v) {
    char buf[24];
    int n = auk__fmt_u64(buf, v);
    auk__sb_put(b, buf, n);
}

/* Append v in hex (see auk__fmt_hex), outside the show budget. */
void auk__sb_hex(AukStrBuf *b, uint64_t v, int min_digits, bool upper) {
    char buf[24];
    int n = auk__fmt_hex(buf, v, min_digits, upper);
    auk__sb_put(b, buf, n);
}

/* The builder's text, NUL-terminated (valid until the builder changes). */
const char *auk__sb_cstr(AukStrBuf *b) {
    sb_reserve(b, 1);
    sb_data(b)[b->len] = 0;
    return (const char *)sb_data(b);
}

/* The builder's text into out[0..cap), cut and NUL-terminated as snprintf would; the builder
 * is freed. */
void auk__sb_take_into(AukStrBuf *b, char *out, size_t cap) {
    auk__cstr_copy(out, cap, auk__sb_cstr(b));
    auk_sb_free(b);
}

/* The builder's text as a malloc'd C string; the builder is freed. */
char *auk__sb_take_cstr(AukStrBuf *b) {
    size_t n = (size_t)b->len;
    char *s = auk__xmalloc(n + 1);
    memcpy(s, sb_data(b), n);
    s[n] = 0;
    auk_sb_free(b);
    return s;
}

/* Write the builder's text to stderr in one piece (as one fprintf would); the builder is
 * freed. */
void auk__sb_eprint(AukStrBuf *b) {
    fwrite(sb_data(b), 1, (size_t)b->len, stderr);
    auk_sb_free(b);
}

/* Does `%.<prec>e` of v read back as v? Leaves the text in buf. */
static bool round_trips(double v, int prec, char *buf, size_t n) {
    auk__c_fmt_e(buf, n, prec, v);
    return strtod(buf, NULL) == v;
}

/* The shortest text that reads back as v (at most 32 bytes with the NUL), into out. JavaScript
 * style: plain decimals for exponents -6..20 (with ".0" when integral), else d.ddde<exp>. */
void auk__fmt_float_shortest(double v, char *out, size_t outn) {
    char res[40];
    int k = 0;
    if (isnan(v)) {
        auk__cstr_copy(res, sizeof res, "NaN");
        k = 3;
    } else if (isinf(v)) {
        auk__cstr_copy(res, sizeof res, v < 0 ? "-inf" : "inf");
        k = (int)strlen(res);
    } else if (v == 0.0) {
        auk__cstr_copy(res, sizeof res, signbit(v) ? "-0.0" : "0.0");
        k = (int)strlen(res);
    } else {
        /* the smallest precision that round-trips (17 digits always do; a precision that
         * round-trips means every larger one does too) */
        char tmp[40];
        int lo = 0;
        int hi = 16;
        while (lo < hi) {
            int mid = (lo + hi) / 2;
            if (round_trips(v, mid, tmp, sizeof tmp)) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        round_trips(v, lo, tmp, sizeof tmp);
        /* tmp = [-]d[.ddd]e(+|-)XX */
        int p = 0;
        bool neg = tmp[0] == '-';
        if (neg) {
            p++;
        }
        char digits[24];
        int nd = 0;
        while (tmp[p] != 0 && tmp[p] != 'e') {
            if (tmp[p] != '.') {
                digits[nd++] = tmp[p];
            }
            p++;
        }
        while (nd > 1 && digits[nd - 1] == '0') {
            nd--;
        }
        int exp = tmp[p] == 'e' ? atoi(tmp + p + 1) : 0;
        if (neg) {
            res[k++] = '-';
        }
        if (exp < -6 || exp >= 21) {
            res[k++] = digits[0];
            if (nd > 1) {
                res[k++] = '.';
                memcpy(res + k, digits + 1, (size_t)(nd - 1));
                k += nd - 1;
            }
            res[k++] = 'e';
            k += auk__fmt_i64(res + k, exp);
        } else {
            int point = exp + 1; /* digits before the decimal point */
            if (point <= 0) {
                res[k++] = '0';
                res[k++] = '.';
                for (int i = 0; i < -point; i++) {
                    res[k++] = '0';
                }
                memcpy(res + k, digits, (size_t)nd);
                k += nd;
            } else if (point >= nd) {
                memcpy(res + k, digits, (size_t)nd);
                k += nd;
                for (int i = 0; i < point - nd; i++) {
                    res[k++] = '0';
                }
                res[k++] = '.';
                res[k++] = '0';
            } else {
                memcpy(res + k, digits, (size_t)point);
                k += point;
                res[k++] = '.';
                memcpy(res + k, digits + point, (size_t)(nd - point));
                k += nd - point;
            }
        }
    }
    if (outn == 0) {
        return;
    }
    size_t n = (size_t)k < outn - 1 ? (size_t)k : outn - 1;
    memcpy(out, res, n);
    out[n] = 0;
}

AUK_API AukStr *auk_str_from_float(double v) {
    char buf[40];
    auk__fmt_float_shortest(v, buf, sizeof buf);
    int64_t n = (int64_t)strlen(buf);
    return auk__str_raw(buf, n, n, true);
}

AUK_API AukStr *auk_str_from_char(uint32_t c) {
    uint8_t b[4];
    int n = utf8_encode(c, b);
    return auk__str_raw((const char *)b, n, 1, n == 1);
}

AUK_API AukStr *auk_str_from_bool(bool b) {
    return b ? auk__str_raw("true", 4, 4, true) : auk__str_raw("false", 5, 5, true);
}

static void quote_char(AukStrBuf *b, uint32_t c, uint8_t q) {
    switch (c) {
    case 0x0A:
        auk_sb_bytes(b, "\\n", 2);
        return;
    case 0x09:
        auk_sb_bytes(b, "\\t", 2);
        return;
    case 0x0D:
        auk_sb_bytes(b, "\\r", 2);
        return;
    case 0x00:
        auk_sb_bytes(b, "\\0", 2);
        return;
    case 0x5C:
        auk_sb_bytes(b, "\\\\", 2);
        return;
    default:
        break;
    }
    if (c == q) {
        auk_sb_char(b, '\\');
        auk_sb_char(b, c);
    } else if (c < 0x20 || c == 0x7F) {
        char buf[24] = "\\u{";
        int n = 3 + auk__fmt_hex(buf + 3, c, 1, true);
        buf[n++] = '}';
        auk_sb_bytes(b, buf, n);
    } else {
        auk_sb_char(b, c);
    }
}

AUK_API AukStr *auk_str_quote(const AukStr *s) {
    AukStrBuf b = {0};
    auk_sb_char(&b, '"');
    const uint8_t *p = sdata(s);
    int64_t n = slen(s);
    int64_t i = 0;
    while (i < n && !auk__show_exhausted()) {
        int64_t len;
        uint32_t c = utf8_decode(p, n, i, &len);
        quote_char(&b, c, '"');
        i += len;
    }
    auk_sb_char(&b, '"');
    return auk_sb_finish(&b);
}

AUK_API AukStr *auk_char_quote(uint32_t c) {
    AukStrBuf b = {0};
    auk_sb_char(&b, '\'');
    quote_char(&b, c, '\'');
    auk_sb_char(&b, '\'');
    return auk_sb_finish(&b);
}

/* ---- format specs ------------------------------------------------------------------------ */

typedef struct Spec {
    uint32_t fill;
    uint8_t align; /* 0, '<', '>', '^' */
    bool zero;
    int64_t width; /* -1: none */
    int64_t prec;  /* -1: none */
    uint8_t radix; /* 0: decimal, or the type char 'x' 'X' 'o' 'b' (ints only) */
} Spec;

/* Panic over spec: `bad format spec "<spec>"`, or with too_large `format spec "<spec>" is too
 * large`. */
static _Noreturn void bad_spec(const char *spec, bool too_large) {
    AukStrBuf m = {0};
    auk__sb_put_cstr(&m, too_large ? "format spec \"" : "bad format spec \"");
    AukStr *shown = auk_str_lit(spec); /* invalid UTF-8 shown repaired */
    auk_sb_str(&m, shown);
    auk_release(shown);
    auk__sb_put_cstr(&m, too_large ? "\" is too large" : "\"");
    auk__panic_sb("format", &m);
}

static Spec parse_spec(const char *spec) {
    Spec sp = {' ', 0, false, -1, -1, 0};
    if (spec == NULL) {
        return sp;
    }
    const uint8_t *s = (const uint8_t *)spec;
    int64_t n = (int64_t)strlen(spec);
    int64_t p = 0;
    if (n > 0) {
        int64_t len;
        uint32_t c = utf8_decode(s, n, 0, &len);
        uint8_t a = len < n ? s[len] : 0;
        if (a == '<' || a == '>' || a == '^') {
            sp.fill = c;
            sp.align = a;
            p = len + 1;
        } else if (s[0] == '<' || s[0] == '>' || s[0] == '^') {
            sp.align = s[0];
            p = 1;
        }
    }
    if (s[p] == '0') {
        sp.zero = true;
        p++;
    }
    if (is_digit(s[p])) {
        sp.width = 0;
        while (is_digit(s[p])) {
            sp.width = (int64_t)((uint64_t)sp.width * 10 + (uint64_t)(s[p] - '0'));
            p++;
        }
    }
    if (s[p] == '.') {
        p++;
        if (!is_digit(s[p])) {
            bad_spec(spec, false);
        }
        sp.prec = 0;
        while (is_digit(s[p])) {
            sp.prec = (int64_t)((uint64_t)sp.prec * 10 + (uint64_t)(s[p] - '0'));
            p++;
        }
    }
    if (s[p] == 'x' || s[p] == 'X' || s[p] == 'o' || s[p] == 'b') {
        sp.radix = s[p];
        p++;
    }
    if (s[p] != 0) {
        bad_spec(spec, false);
    }
    if (sp.width > (1 << 20) || sp.prec > (1 << 20)) {
        bad_spec(spec, true);
    }
    return sp;
}

/* Pad body (owned, consumed) according to sp. */
static AukStr *pad(AukStr *body, Spec sp, bool numeric) {
    int64_t n = auk_str_len(body);
    if (sp.width <= n) {
        return body;
    }
    int64_t extra = sp.width - n;
    AukStrBuf b = {0};
    const uint8_t *p = sdata(body);
    int64_t bn = slen(body);
    if (numeric && sp.zero && sp.align == 0) {
        int64_t i = 0;
        if (bn > 0 && (p[0] == '-' || p[0] == '+')) {
            auk_sb_bytes(&b, (const char *)p, 1);
            i = 1;
        }
        for (int64_t k = 0; k < extra; k++) {
            auk_sb_char(&b, '0');
        }
        auk_sb_bytes(&b, (const char *)p + i, bn - i);
    } else {
        uint8_t al = sp.align != 0 ? sp.align : (numeric ? '>' : '<');
        int64_t left = al == '>' ? extra : (al == '^' ? extra / 2 : 0);
        for (int64_t k = 0; k < left; k++) {
            auk_sb_char(&b, sp.fill);
        }
        auk_sb_str(&b, body);
        for (int64_t k = 0; k < extra - left; k++) {
            auk_sb_char(&b, sp.fill);
        }
    }
    auk_release(body);
    return auk_sb_finish(&b);
}

/* The bits of v in base 16, 8 or 2 (a negative v as its 64-bit two's complement). */
static AukStr *int_in_radix(int64_t v, uint8_t type) {
    unsigned shift = type == 'b' ? 1 : (type == 'o' ? 3 : 4);
    const char *digits = type == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
    uint64_t u = (uint64_t)v;
    uint64_t mask = ((uint64_t)1 << shift) - 1;
    char buf[64];
    int n = 0;
    do {
        buf[63 - n] = digits[u & mask];
        n++;
        u >>= shift;
    } while (u != 0);
    return auk__str_raw(buf + 64 - n, n, n, true);
}

AUK_API AukStr *auk_fmt_int(int64_t v, const char *spec) {
    Spec sp = parse_spec(spec);
    return pad(sp.radix != 0 ? int_in_radix(v, sp.radix) : auk_str_from_int(v), sp, true);
}

AUK_API AukStr *auk_fmt_float(double v, const char *spec) {
    Spec sp = parse_spec(spec);
    AukStr *body;
    if (sp.prec >= 0 && isfinite(v)) {
        int prec = (int)sp.prec;
        int n = auk__c_fmt_f(NULL, 0, prec, v);
        char *buf = auk__xmalloc((size_t)n + 1);
        auk__c_fmt_f(buf, (size_t)n + 1, prec, v);
        body = auk__str_raw(buf, n, n, true);
        free(buf);
    } else {
        body = auk_str_from_float(v);
    }
    return pad(body, sp, true);
}

AUK_API AukStr *auk_fmt_str(const AukStr *s, const char *spec) {
    Spec sp = parse_spec(spec);
    AukStr *body;
    if (sp.prec >= 0 && sp.prec < auk_str_len(s)) {
        body = auk_str_slice(s, 0, sp.prec, NULL);
    } else if (s == NULL) {
        body = auk_str_lit("");
    } else {
        body = auk_retain((void *)s);
    }
    return pad(body, sp, false);
}

AUK_API AukStr *auk_fmt_char(uint32_t c, const char *spec) {
    Spec sp = parse_spec(spec);
    return pad(auk_str_from_char(c), sp, false);
}

AUK_API AukStr *auk_fmt_bool(bool v, const char *spec) {
    Spec sp = parse_spec(spec);
    return pad(auk_str_from_bool(v), sp, false);
}
