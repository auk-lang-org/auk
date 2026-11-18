/* Frames (`pixels.Frame`, pure): 32-bit pixels and the hot loops of filling, blending and
 * copying them, for gui programs and the graphics package.
 *
 * A frame holds w×h colors 0xTTRRGGBB, rows top to bottom. The top byte is transparency: 0 is
 * opaque (so a plain 0xRRGGBB is an opaque color) and 255 fully transparent; alpha is 255 - T,
 * straight (not premultiplied). A frame is a handle shared by reference count and copied before
 * a write while shared, so it behaves like any Auk value. Rectangles are clipped to the frame,
 * so drawing partly (or wholly) outside it is fine. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "auk_rt.h"

static const int64_t MAX_PIXELS = (int64_t)1 << 28;
/* Copies of shared frames at least this big are reported under AUK_GUI_TRACE=1. */
static const int64_t REPORT_PIXELS = 256 * 1024;

static AukFrame *frame_alloc(int64_t w, int64_t h) {
    AukFrame *f = auk__alloc(sizeof(AukFrame) + (size_t)(w * h) * 4, AUK_K_FRAME);
    f->w = w;
    f->hgt = h;
    return f;
}

/* Report (under AUK_GUI_TRACE=1) that a big shared frame was copied before a write: easy to
 * cause by accident (`let before = frame` kept alive across a draw loop) and costly at window
 * sizes. The first 20 are reported, then a count every 100. */
static void report_copy(int64_t w, int64_t h, const char *loc, const char *what) {
    static _Atomic int on = -1;
    static _Atomic uint64_t count;
    if (w * h < REPORT_PIXELS) {
        return;
    }
    if (atomic_load(&on) < 0) {
        const char *v = getenv("AUK_GUI_TRACE");
        atomic_store(&on, v != NULL && strcmp(v, "1") == 0 ? 1 : 0);
    }
    if (atomic_load(&on) == 0) {
        return;
    }
    uint64_t n = atomic_fetch_add(&count, 1) + 1;
    if (n <= 20) {
        fprintf(stderr,
                "pixels.%s%s%s: copied a shared %lldx%lld frame (%lld MB) to change it; something else still holds it "
                "(keep one reference to a frame you draw into)\n",
                what, loc == NULL ? "" : " at ", loc == NULL ? "" : loc, (long long)w, (long long)h,
                (long long)(w * h * 4 / 1000000));
    } else if (n % 100 == 0) {
        fprintf(stderr, "pixels: %llu copies of shared frames so far\n", (unsigned long long)n);
    }
}

/* The frame in *pf, writable: copied first if anything else holds it. */
static uint32_t *unique(AukFrame **pf, const char *loc, const char *what) {
    AukFrame *f = *pf;
    int64_t w = f->w;
    int64_t h = f->hgt;
    if (atomic_load_explicit(&f->h.rc, memory_order_acquire) != 1) {
        report_copy(w, h, loc, what);
        AukFrame *g = frame_alloc(w, h);
        memcpy(g->data, f->data, (size_t)(w * h) * 4);
        auk_release(f);
        *pf = g;
    }
    return (*pf)->data;
}

static int64_t sat_add(int64_t a, int64_t b) {
    int64_t r;
    if (__builtin_add_overflow(a, b, &r)) {
        return b > 0 ? INT64_MAX : INT64_MIN;
    }
    return r;
}

/* A rectangle clipped to a frame: [x0, x1) × [y0, y1). */
typedef struct PxRect {
    int64_t x0;
    int64_t y0;
    int64_t x1;
    int64_t y1;
} PxRect;

/* Clip (x, y, w, h) to an fw×fh frame; false if nothing is left. */
static bool clip(int64_t x, int64_t y, int64_t w, int64_t h, int64_t fw, int64_t fh, PxRect *r) {
    r->x0 = x > 0 ? x : 0;
    r->y0 = y > 0 ? y : 0;
    int64_t xe = sat_add(x, w);
    int64_t ye = sat_add(y, h);
    r->x1 = xe < fw ? xe : fw;
    r->y1 = ye < fh ? ye : fh;
    return r->x0 < r->x1 && r->y0 < r->y1;
}

/* t / 255 rounded to nearest (as (t + 127) / 255), for t in 0..=65025, without dividing. */
static uint32_t div255(uint32_t t) {
    t += 128;
    return (t + (t >> 8)) >> 8;
}

/* An opaque dst with 1 - sa of it kept (ia = 255 - sa) plus a color's premultiplied share (crb
 * = red and blue times sa, packed as 0x00RR00BB lanes of 16 bits; cg = green times sa): red and
 * blue are worked out together in one 32-bit multiply. Exact, the same as div255 per channel:
 * each lane stays below 65536 (d·ia + c·sa ≤ 255·255). */
static uint32_t mix_opaque(uint32_t d, uint32_t ia, uint32_t crb, uint32_t cg) {
    uint32_t rb = (d & 0x00ff00ffu) * ia + crb + 0x00800080u;
    rb = ((rb + ((rb >> 8) & 0x00ff00ffu)) >> 8) & 0x00ff00ffu;
    return rb | div255(((d >> 8) & 0xff) * ia + cg) << 8;
}

/* src (0xTTRRGGBB) over dst with src's alpha scaled by cov (0..=255). */
static uint32_t over(uint32_t dst, uint32_t src, uint32_t cov) {
    uint32_t sa = div255((255 - (src >> 24)) * cov);
    if (sa == 0) {
        return dst;
    }
    if (sa == 255) {
        return src & 0xffffff;
    }
    uint32_t da = 255 - (dst >> 24);
    if (da == 255) {
        /* an opaque destination, the usual case */
        uint32_t ia = 255 - sa;
        uint32_t r = div255(((dst >> 16) & 0xff) * ia + ((src >> 16) & 0xff) * sa) << 16;
        uint32_t g = div255(((dst >> 8) & 0xff) * ia + ((src >> 8) & 0xff) * sa) << 8;
        uint32_t b = div255((dst & 0xff) * ia + (src & 0xff) * sa);
        return r | g | b;
    }
    /* straight alpha: oa = sa + da (1 - sa), c = (sc sa + dc da (1 - sa)) / oa */
    uint32_t k = div255(da * (255 - sa));
    uint32_t oa = sa + k;
    if (oa == 0) {
        return 0xff000000u;
    }
    uint32_t r = ((((src >> 16) & 0xff) * sa + ((dst >> 16) & 0xff) * k + oa / 2) / oa) << 16;
    uint32_t g = ((((src >> 8) & 0xff) * sa + ((dst >> 8) & 0xff) * k + oa / 2) / oa) << 8;
    uint32_t b = ((src & 0xff) * sa + (dst & 0xff) * k + oa / 2) / oa;
    return (255 - oa) << 24 | r | g | b;
}

static uint32_t color(int64_t c) {
    return (uint32_t)c;
}

/* "pixels.<what>: <a>x<b>"-style messages: <pre><a><mid><b><post>. */
static _Noreturn void panic_size(const char *loc, const char *pre, int64_t a, const char *mid, int64_t b, const char *post) {
    AukStrBuf m = {0};
    auk__sb_put_cstr(&m, pre);
    auk_sb_int(&m, a);
    auk__sb_put_cstr(&m, mid);
    auk_sb_int(&m, b);
    auk__sb_put_cstr(&m, post);
    auk__panic_sb(loc, &m);
}

/* A w×h frame filled with color c. */
AUK_API AukFrame *auk_frame_new(int64_t w, int64_t h, int64_t c, const char *loc) {
    int64_t n;
    if (w < 0 || h < 0 || __builtin_mul_overflow(w, h, &n) || n > MAX_PIXELS) {
        panic_size(loc, "pixels.frame: size ", w, "x", h, "");
    }
    AukFrame *f = frame_alloc(w, h);
    if (c != 0) {
        uint32_t v = color(c);
        for (int64_t i = 0; i < n; i++) {
            f->data[i] = v;
        }
    }
    return f;
}

/* A w×h frame of the colors px (rows top to bottom). */
AUK_API AukFrame *auk_frame_from_list(int64_t w, int64_t h, const AukArr *px, const char *loc) {
    int64_t n = auk_arr_len(px);
    int64_t wh;
    if (w < 0 || h < 0 || __builtin_mul_overflow(w, h, &wh) || wh != n || n > MAX_PIXELS) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "pixels.from_list: ");
        auk_sb_int(&m, n);
        auk__sb_put_cstr(&m, " colors is not ");
        auk_sb_int(&m, w);
        auk__sb_put_cstr(&m, "x");
        auk_sb_int(&m, h);
        auk__panic_sb(loc, &m);
    }
    AukFrame *f = frame_alloc(w, h);
    const int64_t *src = n > 0 ? (const int64_t *)px->data : NULL;
    for (int64_t i = 0; i < n; i++) {
        f->data[i] = color(src[i]);
    }
    return f;
}

/* The frame's colors as a list, rows top to bottom. */
AUK_API AukArr *auk_frame_to_list(const AukFrame *f) {
    int64_t n = f->w * f->hgt;
    AukArr *out = auk_arr_new(&auk_ops_int, n);
    int64_t *d = auk_arr_make_unique(&out);
    for (int64_t i = 0; i < n; i++) {
        d[i] = f->data[i];
    }
    out->len = n;
    return out;
}

AUK_API int64_t auk_frame_width(const AukFrame *f) {
    return f->w;
}

AUK_API int64_t auk_frame_height(const AukFrame *f) {
    return f->hgt;
}

static void check(int64_t x, int64_t y, int64_t w, int64_t h, const char *loc, const char *what) {
    if (x < 0 || y < 0 || x >= w || y >= h) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "pixels.");
        auk__sb_put_cstr(&m, what);
        auk__sb_put_cstr(&m, ": (");
        auk_sb_int(&m, x);
        auk__sb_put_cstr(&m, ", ");
        auk_sb_int(&m, y);
        auk__sb_put_cstr(&m, ") is outside the ");
        auk_sb_int(&m, w);
        auk__sb_put_cstr(&m, "x");
        auk_sb_int(&m, h);
        auk__sb_put_cstr(&m, " frame");
        auk__panic_sb(loc, &m);
    }
}

/* The color at (x, y). */
AUK_API int64_t auk_frame_get(const AukFrame *f, int64_t x, int64_t y, const char *loc) {
    check(x, y, f->w, f->hgt, loc, "get");
    return f->data[y * f->w + x];
}

/* Set the color at (x, y). */
AUK_API void auk_frame_set(AukFrame **pf, int64_t x, int64_t y, int64_t c, const char *loc) {
    check(x, y, (*pf)->w, (*pf)->hgt, loc, "set");
    uint32_t *px = unique(pf, loc, "set");
    px[y * (*pf)->w + x] = color(c);
}

/* Set a rectangle to c (transparency included). */
AUK_API void auk_frame_fill(AukFrame **pf, int64_t x, int64_t y, int64_t w, int64_t h, int64_t c, const char *loc) {
    PxRect r;
    if (!clip(x, y, w, h, (*pf)->w, (*pf)->hgt, &r)) {
        return;
    }
    uint32_t *px = unique(pf, loc, "fill");
    int64_t fw = (*pf)->w;
    uint32_t v = color(c);
    for (int64_t row = r.y0; row < r.y1; row++) {
        uint32_t *p = px + row * fw;
        for (int64_t i = r.x0; i < r.x1; i++) {
            p[i] = v;
        }
    }
}

/* Are all of p[0..n) opaque? */
static bool all_opaque(const uint32_t *p, int64_t n) {
    for (int64_t i = 0; i < n; i++) {
        if (p[i] >> 24 != 0) {
            return false;
        }
    }
    return true;
}

/* Paint c over a rectangle, as transparent as c is. */
AUK_API void auk_frame_blend(AukFrame **pf, int64_t x, int64_t y, int64_t w, int64_t h, int64_t c64, const char *loc) {
    uint32_t c = color(c64);
    if (c >> 24 == 255) {
        return;
    }
    PxRect r;
    if (!clip(x, y, w, h, (*pf)->w, (*pf)->hgt, &r)) {
        return;
    }
    uint32_t *px = unique(pf, loc, "blend");
    int64_t fw = (*pf)->w;
    uint32_t sa = 255 - (c >> 24);
    int64_t len = r.x1 - r.x0;
    if (sa == 255) {
        for (int64_t row = r.y0; row < r.y1; row++) {
            uint32_t *p = px + row * fw + r.x0;
            for (int64_t i = 0; i < len; i++) {
                p[i] = c;
            }
        }
        return;
    }
    /* over an opaque pixel, with the color's share of each channel worked out once */
    uint32_t ia = 255 - sa;
    uint32_t crb = (c & 0x00ff00ffu) * sa;
    uint32_t cg = ((c >> 8) & 0xff) * sa;
    for (int64_t row = r.y0; row < r.y1; row++) {
        uint32_t *p = px + row * fw + r.x0;
        if (all_opaque(p, len)) {
            /* all opaque, the usual case: a loop without branches */
            for (int64_t i = 0; i < len; i++) {
                p[i] = mix_opaque(p[i], ia, crb, cg);
            }
        } else {
            for (int64_t i = 0; i < len; i++) {
                p[i] = over(p[i], c, 255);
            }
        }
    }
}

/* Copy (or with blend, paint over) the w×h rectangle at (sx, sy) of src to (x, y). */
static void copy_rect(AukFrame **pf, int64_t x, int64_t y, const AukFrame *src, int64_t sx, int64_t sy, int64_t w, int64_t h,
                      bool blend, const char *loc) {
    /* clipped to the source, then the destination */
    PxRect s;
    if (!clip(sx, sy, w, h, src->w, src->hgt, &s)) {
        return;
    }
    int64_t dx = x + (s.x0 - sx);
    int64_t dy = y + (s.y0 - sy);
    PxRect d;
    if (!clip(dx, dy, s.x1 - s.x0, s.y1 - s.y0, (*pf)->w, (*pf)->hgt, &d)) {
        return;
    }
    int64_t ox = s.x0 + (d.x0 - dx);
    int64_t oy = s.y0 + (d.y0 - dy);
    int64_t len = d.x1 - d.x0;
    int64_t rows = d.y1 - d.y0;
    int64_t sw = src->w;
    /* the source may be this very frame: take the rectangle out first, as it may overlap */
    bool same = src == *pf;
    uint32_t *tmp = NULL;
    if (same) {
        tmp = auk__xmalloc((size_t)(len * rows) * 4 + 4);
        for (int64_t r = 0; r < rows; r++) {
            memcpy(tmp + r * len, src->data + (oy + r) * sw + ox, (size_t)len * 4);
        }
    }
    uint32_t *px = unique(pf, loc, blend ? "composite" : "blit");
    int64_t fw = (*pf)->w;
    for (int64_t r = 0; r < rows; r++) {
        const uint32_t *from = same ? tmp + r * len : src->data + (oy + r) * sw + ox;
        uint32_t *to = px + (d.y0 + r) * fw + d.x0;
        if (blend) {
            for (int64_t i = 0; i < len; i++) {
                to[i] = over(to[i], from[i], 255);
            }
        } else {
            memmove(to, from, (size_t)len * 4);
        }
    }
    free(tmp);
}

/* Copy the w×h rectangle at (sx, sy) of src to (x, y). */
AUK_API void auk_frame_blit(AukFrame **pf, int64_t x, int64_t y, const AukFrame *src, int64_t sx, int64_t sy, int64_t w, int64_t h,
                            const char *loc) {
    copy_rect(pf, x, y, src, sx, sy, w, h, false, loc);
}

/* Paint the w×h rectangle at (sx, sy) of src over (x, y), by its transparency. */
AUK_API void auk_frame_composite(AukFrame **pf, int64_t x, int64_t y, const AukFrame *src, int64_t sx, int64_t sy, int64_t w,
                                 int64_t h, const char *loc) {
    copy_rect(pf, x, y, src, sx, sy, w, h, true, loc);
}

/* Paint c through mask (coverage 0..255, mw per row) placed at (x, y): how text glyphs are
 * drawn. */
AUK_API void auk_frame_blit_mask(AukFrame **pf, int64_t x, int64_t y, const AukArr *mask, int64_t mw, int64_t c64, const char *loc) {
    if (mw < 1) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "pixels.blit_mask: mask width ");
        auk_sb_int(&m, mw);
        auk__sb_put_cstr(&m, " (expected at least 1)");
        auk__panic_sb(loc, &m);
    }
    int64_t mn = auk_arr_len(mask);
    if (mn == 0) {
        return;
    }
    uint32_t c = color(c64);
    if (c >> 24 == 255) {
        return;
    }
    const int64_t *m = (const int64_t *)mask->data;
    int64_t mh = mn / mw;
    PxRect r;
    if (!clip(x, y, mw, mh, (*pf)->w, (*pf)->hgt, &r)) {
        return;
    }
    uint32_t *px = unique(pf, loc, "blit_mask");
    int64_t fw = (*pf)->w;
    bool opaque = c >> 24 == 0;
    int64_t len = r.x1 - r.x0;
    uint32_t crb = c & 0x00ff00ffu;
    uint32_t cg = (c >> 8) & 0xff;
    for (int64_t row = r.y0; row < r.y1; row++) {
        const int64_t *mrow = m + (row - y) * mw + (r.x0 - x);
        uint32_t *prow = px + row * fw + r.x0;
        if (opaque && all_opaque(prow, len)) {
            /* the usual case for text: no branches, so it vectorizes. Exact for every coverage:
             * 0 leaves the pixel as it was and 255 gives the color. */
            for (int64_t i = 0; i < len; i++) {
                int64_t a64 = mrow[i];
                uint32_t a = a64 < 0 ? 0 : (a64 > 255 ? 255 : (uint32_t)a64);
                prow[i] = mix_opaque(prow[i], 255 - a, crb * a, cg * a);
            }
            continue;
        }
        for (int64_t i = 0; i < len; i++) {
            int64_t a64 = mrow[i];
            if (a64 <= 0) {
                continue;
            }
            uint32_t a = a64 > 255 ? 255 : (uint32_t)a64;
            uint32_t d = prow[i];
            if (!opaque || d >> 24 != 0) {
                prow[i] = over(d, c, a);
            } else if (a == 255) {
                prow[i] = c;
            } else {
                /* an opaque color over an opaque pixel */
                prow[i] = mix_opaque(d, 255 - a, (c & 0x00ff00ffu) * a, ((c >> 8) & 0xff) * a);
            }
        }
    }
}
