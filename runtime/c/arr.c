/* `[T]`: inline-element arrays with copy-on-write and O(1) slice views. */
#include <stdlib.h>
#include <string.h>

#include "auk_rt.h"

/* Address of element i. */
static uint8_t *elem(const AukArr *a, int64_t i) {
    return a->data + (size_t)i * a->ops->size;
}

static void retain_elem(const AukElemOps *ops, void *e) {
    if (ops->retain != NULL) {
        ops->retain(e);
    }
}

static void release_elem(const AukElemOps *ops, void *e) {
    if (ops->release != NULL) {
        ops->release(e);
    }
}

AUK_API int64_t auk_arr_len(const AukArr *a) {
    return a == NULL ? 0 : a->len;
}

AUK_API const void *auk_arr_data(const AukArr *a) {
    return a == NULL ? NULL : a->data;
}

AUK_API AukArr *auk_arr_new(const AukElemOps *ops, int64_t cap) {
    if (ops == NULL) {
        auk__panic_rt("auk_arr_new: missing element ops");
    }
    AukArr *a = auk__alloc(sizeof(AukArr), AUK_K_ARR);
    a->ops = ops;
    a->cap = cap > 0 ? cap : 0;
    a->data = a->cap != 0 ? auk__xmalloc((size_t)a->cap * ops->size) : NULL;
    return a;
}

AUK_API AukArr *auk_arr_from(const AukElemOps *ops, const void *elems, int64_t n) {
    AukArr *a = auk_arr_new(ops, n);
    if (n != 0) {
        memcpy(a->data, elems, (size_t)n * ops->size);
    }
    a->len = n;
    if (ops->retain != NULL) {
        for (int64_t i = 0; i < n; i++) {
            ops->retain(elem(a, i));
        }
    }
    return a;
}

void auk__arr_free(AukArr *a) {
    if (a->base != NULL) {
        auk_release(a->base);
    } else {
        if (a->ops->release != NULL) {
            for (int64_t i = 0; i < a->len; i++) {
                a->ops->release(elem(a, i));
            }
        }
        free(a->data);
    }
    auk__free_obj(a);
}

static _Noreturn void oob(const char *loc, int64_t i, int64_t len) {
    AukStrBuf b = {0};
    auk__sb_put_cstr(&b, "index ");
    auk_sb_int(&b, i);
    auk__sb_put_cstr(&b, " out of range for length ");
    auk_sb_int(&b, len);
    auk__panic_sb(loc, &b);
}

AUK_API void *auk_arr_at(const AukArr *a, int64_t i, const char *loc) {
    int64_t n = auk_arr_len(a);
    if (i < 0 || i >= n) {
        oob(loc, i, n);
    }
    return elem(a, i);
}

AUK_API bool auk_arr_get_opt(const AukArr *a, int64_t i, void *out) {
    if (i < 0 || i >= auk_arr_len(a)) {
        return false;
    }
    memcpy(out, elem(a, i), a->ops->size);
    retain_elem(a->ops, out);
    return true;
}

/* A fresh owner copy of a with capacity >= cap. */
static AukArr *copy_with_cap(const AukArr *a, int64_t cap) {
    if (cap < a->len) {
        cap = a->len;
    }
    AukArr *c = auk_arr_new(a->ops, cap);
    if (a->len != 0) {
        memcpy(c->data, a->data, (size_t)a->len * a->ops->size);
    }
    c->len = a->len;
    if (a->ops->retain != NULL) {
        for (int64_t i = 0; i < c->len; i++) {
            a->ops->retain(elem(c, i));
        }
    }
    return c;
}

static bool is_unique(const AukArr *a) {
    return a->base == NULL && auk_refcount(a) == 1;
}

static void ensure_unique_cap(AukArr **pa, int64_t need) {
    AukArr *a = *pa;
    if (a == NULL) {
        auk__panic_rt("mutating a NULL array");
    }
    if (!is_unique(a)) {
        AukArr *c = copy_with_cap(a, need > a->len ? need : a->len);
        auk_release(a);
        *pa = c;
        return;
    }
    if (need > a->cap) {
        int64_t cap = a->cap != 0 ? a->cap * 2 : 4;
        while (cap < need) {
            cap *= 2;
        }
        a->data = auk__xrealloc(a->data, (size_t)cap * a->ops->size);
        a->cap = cap;
    }
}

AUK_API void *auk_arr_make_unique(AukArr **pa) {
    ensure_unique_cap(pa, (*pa)->len);
    return (*pa)->data;
}

AUK_API void auk_arr_set(AukArr **pa, int64_t i, const void *e, const char *loc) {
    int64_t n = auk_arr_len(*pa);
    if (i < 0 || i >= n) {
        oob(loc, i, n);
    }
    size_t sz = (*pa)->ops->size;
    /* copy + retain the new value first: e may point into *pa */
    AukTmp tmp;
    uint8_t *t = auk__tmp_get(&tmp, sz);
    memcpy(t, e, sz);
    retain_elem((*pa)->ops, t);
    ensure_unique_cap(pa, n);
    AukArr *a = *pa;
    release_elem(a->ops, elem(a, i));
    memcpy(elem(a, i), t, sz);
    auk__tmp_done(&tmp);
}

AUK_API void auk_arr_push(AukArr **pa, const void *e) {
    AukArr *a = *pa;
    size_t sz = a->ops->size;
    /* e may point into *pa itself: copy before a possible realloc or copy-on-write */
    AukTmp tmp;
    uint8_t *t = auk__tmp_get(&tmp, sz);
    memcpy(t, e, sz);
    retain_elem(a->ops, t);
    ensure_unique_cap(pa, a->len + 1);
    a = *pa;
    memcpy(elem(a, a->len), t, sz);
    a->len++;
    auk__tmp_done(&tmp);
}

AUK_API void auk_arr_push_own(AukArr **pa, const void *e) {
    /* e is the caller's own value (never an element of *pa): moved in, no retain */
    ensure_unique_cap(pa, (*pa)->len + 1);
    AukArr *a = *pa;
    memcpy(elem(a, a->len), e, a->ops->size);
    a->len++;
}

AUK_API bool auk_arr_pop(AukArr **pa, void *out) {
    if (auk_arr_len(*pa) == 0) {
        return false;
    }
    ensure_unique_cap(pa, (*pa)->len);
    AukArr *a = *pa;
    a->len--;
    if (out != NULL) {
        memcpy(out, elem(a, a->len), a->ops->size);
    } else {
        release_elem(a->ops, elem(a, a->len));
    }
    return true;
}

AUK_API void auk_arr_insert(AukArr **pa, int64_t i, const void *e, const char *loc) {
    int64_t n = auk_arr_len(*pa);
    if (i < 0 || i > n) {
        oob(loc, i, n);
    }
    size_t sz = (*pa)->ops->size;
    AukTmp tmp;
    uint8_t *t = auk__tmp_get(&tmp, sz);
    memcpy(t, e, sz);
    retain_elem((*pa)->ops, t);
    ensure_unique_cap(pa, n + 1);
    AukArr *a = *pa;
    memmove(elem(a, i + 1), elem(a, i), (size_t)(n - i) * sz);
    memcpy(elem(a, i), t, sz);
    a->len++;
    auk__tmp_done(&tmp);
}

AUK_API void auk_arr_remove(AukArr **pa, int64_t i, void *out, const char *loc) {
    int64_t n = auk_arr_len(*pa);
    if (i < 0 || i >= n) {
        oob(loc, i, n);
    }
    ensure_unique_cap(pa, n);
    AukArr *a = *pa;
    size_t sz = a->ops->size;
    if (out != NULL) {
        memcpy(out, elem(a, i), sz);
    } else {
        release_elem(a->ops, elem(a, i));
    }
    memmove(elem(a, i), elem(a, i + 1), (size_t)(n - i - 1) * sz);
    a->len--;
}

AUK_API void auk_arr_clear(AukArr **pa) {
    AukArr *a = *pa;
    if (!is_unique(a)) {
        *pa = auk_arr_new(a->ops, 0);
        auk_release(a);
        return;
    }
    if (a->ops->release != NULL) {
        for (int64_t i = 0; i < a->len; i++) {
            a->ops->release(elem(a, i));
        }
    }
    a->len = 0;
}

AUK_API AukArr *auk_arr_slice(AukArr *a, int64_t lo, int64_t hi, const char *loc) {
    int64_t n = auk_arr_len(a);
    if (lo < 0 || hi < lo || hi > n) {
        AukStrBuf b = {0};
        auk__sb_put_cstr(&b, "slice ");
        auk_sb_int(&b, lo);
        auk__sb_put_cstr(&b, "..");
        auk_sb_int(&b, hi);
        auk__sb_put_cstr(&b, " out of range for length ");
        auk_sb_int(&b, n);
        auk__panic_sb(loc, &b);
    }
    if (lo == 0 && hi == n) {
        return auk_retain(a);
    }
    AukArr *root = a->base != NULL ? a->base : a;
    AukArr *v = auk__alloc(sizeof(AukArr), AUK_K_ARR);
    v->ops = a->ops;
    v->base = auk_retain(root);
    v->data = elem(a, lo);
    v->len = hi - lo;
    v->cap = v->len;
    return v;
}

AUK_API AukArr *auk_arr_take(AukArr *a, int64_t n) {
    int64_t len = auk_arr_len(a);
    if (n < 0) {
        n = 0;
    }
    return auk_arr_slice(a, 0, n < len ? n : len, NULL);
}

AUK_API AukArr *auk_arr_skip(AukArr *a, int64_t n) {
    int64_t len = auk_arr_len(a);
    if (n < 0) {
        n = 0;
    }
    return auk_arr_slice(a, n < len ? n : len, len, NULL);
}

AUK_API AukArr *auk_arr_copy(const AukArr *a) {
    return copy_with_cap(a, a->len);
}

AUK_API AukArr *auk_arr_concat(const AukArr *a, const AukArr *b) {
    AukArr *c = copy_with_cap(a, a->len + auk_arr_len(b));
    auk_arr_extend(&c, b);
    return c;
}

AUK_API void auk_arr_extend(AukArr **pa, const AukArr *b) {
    int64_t bn = auk_arr_len(b);
    if (bn == 0) {
        return;
    }
    void *keep = auk_retain((void *)b); /* b may be *pa */
    ensure_unique_cap(pa, (*pa)->len + bn);
    AukArr *a = *pa;
    memcpy(elem(a, a->len), b->data, (size_t)bn * a->ops->size);
    if (a->ops->retain != NULL) {
        for (int64_t i = a->len; i < a->len + bn; i++) {
            a->ops->retain(elem(a, i));
        }
    }
    a->len += bn;
    auk_release(keep);
}

static void reverse_in_place(AukArr *a) {
    size_t sz = a->ops->size;
    AukTmp tmp;
    uint8_t *t = auk__tmp_get(&tmp, sz);
    int64_t i = 0;
    int64_t j = a->len - 1;
    while (i < j) {
        memcpy(t, elem(a, i), sz);
        memcpy(elem(a, i), elem(a, j), sz);
        memcpy(elem(a, j), t, sz);
        i++;
        j--;
    }
    auk__tmp_done(&tmp);
}

AUK_API AukArr *auk_arr_reversed(const AukArr *a) {
    AukArr *c = auk_arr_copy(a);
    reverse_in_place(c);
    return c;
}

AUK_API void auk_arr_reverse(AukArr **pa) {
    auk_arr_make_unique(pa);
    reverse_in_place(*pa);
}

/* ---- sorting ----------------------------------------------------------------------------- */

typedef int (*SortCmpFn)(const void *a, const void *b, void *ctx);

typedef struct SortCtx {
    SortCmpFn cmp;
    void *ctx;
    size_t sz;
} SortCtx;

/* Stable merge sort of n elements at d (tmp: room for n). */
static void merge_sort(uint8_t *d, uint8_t *tmp, int64_t n, const SortCtx *c) {
    size_t sz = c->sz;
    if (n < 2) {
        return;
    }
    if (n <= 8) {
        /* insertion sort */
        for (int64_t i = 1; i < n; i++) {
            memcpy(tmp, d + i * sz, sz);
            int64_t j = i;
            while (j > 0 && c->cmp(d + (j - 1) * sz, tmp, c->ctx) > 0) {
                memcpy(d + j * sz, d + (j - 1) * sz, sz);
                j--;
            }
            memcpy(d + j * sz, tmp, sz);
        }
        return;
    }
    int64_t m = n / 2;
    merge_sort(d, tmp, m, c);
    merge_sort(d + m * sz, tmp, n - m, c);
    if (c->cmp(d + (m - 1) * sz, d + m * sz, c->ctx) <= 0) {
        return;
    }
    memcpy(tmp, d, (size_t)n * sz);
    int64_t i = 0;
    int64_t j = m;
    int64_t k = 0;
    while (i < m && j < n) {
        if (c->cmp(tmp + j * sz, tmp + i * sz, c->ctx) < 0) {
            memcpy(d + k * sz, tmp + j * sz, sz);
            j++;
        } else {
            memcpy(d + k * sz, tmp + i * sz, sz);
            i++;
        }
        k++;
    }
    if (i < m) {
        memcpy(d + k * sz, tmp + i * sz, (size_t)(m - i) * sz);
    }
    if (j < n) {
        memcpy(d + k * sz, tmp + j * sz, (size_t)(n - j) * sz);
    }
}

AUK_API void auk_arr_sort_with(AukArr **pa, SortCmpFn cmp, void *ctx) {
    auk_arr_make_unique(pa);
    AukArr *a = *pa;
    if (a->len < 2) {
        return;
    }
    SortCtx c = {cmp, ctx, a->ops->size};
    uint8_t *tmp = auk__xmalloc((size_t)a->len * c.sz);
    merge_sort(a->data, tmp, a->len, &c);
    free(tmp);
}

/* Ints: equal ints are indistinguishable, so any order among them will do. Short arrays by
 * insertion; longer ones by an LSD radix sort (sign bit flipped) in digits of up to 11 bits over
 * just the bits that vary between keys. It needs a buffer the size of the array while it runs
 * (a comparison sort in place was several times slower). */
static void sort_ints(int64_t *d, int64_t n) {
    if (n <= 32) {
        for (int64_t i = 1; i < n; i++) {
            int64_t x = d[i];
            int64_t j = i;
            while (j > 0 && d[j - 1] > x) {
                d[j] = d[j - 1];
                j--;
            }
            d[j] = x;
        }
        return;
    }
    uint64_t *src = (uint64_t *)d;
    const uint64_t flip = (uint64_t)1 << 63;
    /* the byte positions where keys differ */
    uint64_t all_and = ~(uint64_t)0;
    uint64_t all_or = 0;
    for (int64_t i = 0; i < n; i++) {
        uint64_t k = src[i] ^ flip;
        all_and &= k;
        all_or |= k;
    }
    uint64_t diff = all_and ^ all_or;
    if (diff == 0) {
        return; /* all equal */
    }
    /* digits of up to 11 bits over the bits that vary: [lo, hi] */
    int lo = __builtin_ctzll(diff);
    int hi = 63 - __builtin_clzll(diff);
    int span = hi - lo + 1;
    int passes = (span + 10) / 11;
    int width = (span + passes - 1) / passes;
    int64_t buckets = (int64_t)1 << width;
    uint64_t mask = (uint64_t)buckets - 1;
    int64_t *counts = auk__xcalloc((size_t)(passes * buckets), sizeof(int64_t));
    for (int64_t i = 0; i < n; i++) {
        uint64_t k = (src[i] ^ flip) >> lo;
        for (int p = 0; p < passes; p++) {
            counts[p * buckets + ((k >> (p * width)) & mask)]++;
        }
    }
    uint64_t *buf = auk__xmalloc((size_t)n * sizeof(uint64_t));
    uint64_t *dst = buf;
    for (int p = 0; p < passes; p++) {
        int64_t *c = counts + p * buckets;
        int sh = lo + p * width;
        int64_t sum = 0;
        for (int64_t v = 0; v < buckets; v++) {
            int64_t t = c[v];
            c[v] = sum;
            sum += t;
        }
        for (int64_t i = 0; i < n; i++) {
            uint64_t x = src[i];
            dst[c[((x ^ flip) >> sh) & mask]++] = x;
        }
        uint64_t *t = src;
        src = dst;
        dst = t;
    }
    if (src != (uint64_t *)d) {
        memcpy(d, src, (size_t)n * sizeof(uint64_t));
    }
    free(counts);
    free(buf);
}

/* Floats: stable (0.0 and -0.0 compare equal but print differently), by auk_float_cmp. */
static void merge_floats(double *d, double *tmp, int64_t n) {
    if (n <= 16) {
        for (int64_t i = 1; i < n; i++) {
            double x = d[i];
            int64_t j = i;
            while (j > 0 && auk_float_cmp(d[j - 1], x) > 0) {
                d[j] = d[j - 1];
                j--;
            }
            d[j] = x;
        }
        return;
    }
    int64_t m = n / 2;
    merge_floats(d, tmp, m);
    merge_floats(d + m, tmp, n - m);
    if (auk_float_cmp(d[m - 1], d[m]) <= 0) {
        return;
    }
    memcpy(tmp, d, (size_t)m * sizeof(double));
    int64_t i = 0;
    int64_t j = m;
    int64_t k = 0;
    while (i < m && j < n) {
        if (auk_float_cmp(d[j], tmp[i]) < 0) {
            d[k++] = d[j++];
        } else {
            d[k++] = tmp[i++];
        }
    }
    while (i < m) {
        d[k++] = tmp[i++];
    }
}

/* Other elements: a stable merge sort of their indexes (perm), comparing the elements. */
static void merge_perm(int64_t *p, int64_t *tmp, int64_t n, const uint8_t *data, size_t size, AukCmpFn cmp) {
    if (n <= 8) {
        for (int64_t i = 1; i < n; i++) {
            int64_t x = p[i];
            int64_t j = i;
            while (j > 0 && cmp(data + (size_t)p[j - 1] * size, data + (size_t)x * size) > 0) {
                p[j] = p[j - 1];
                j--;
            }
            p[j] = x;
        }
        return;
    }
    int64_t m = n / 2;
    merge_perm(p, tmp, m, data, size, cmp);
    merge_perm(p + m, tmp, n - m, data, size, cmp);
    if (cmp(data + (size_t)p[m - 1] * size, data + (size_t)p[m] * size) <= 0) {
        return;
    }
    memcpy(tmp, p, (size_t)m * sizeof(int64_t));
    int64_t i = 0;
    int64_t j = m;
    int64_t k = 0;
    while (i < m && j < n) {
        if (cmp(data + (size_t)p[j] * size, data + (size_t)tmp[i] * size) < 0) {
            p[k++] = p[j++];
        } else {
            p[k++] = tmp[i++];
        }
    }
    while (i < m) {
        p[k++] = tmp[i++];
    }
}

/* Sort *pa in place (made unique first), stable, by the elements' cmp (their element ops: the
 * same comparison as Auk's `<`, derived or user-written). Other than ints and floats, elements
 * are sorted through a permutation of their indexes, moved only once it is done, so a user cmp
 * that panics leaves the list as it was. */
AUK_API void auk_arr_sort(AukArr **pa) {
    const AukElemOps *ops = (*pa)->ops;
    if (ops->cmp == NULL) {
        auk__panic_rt("sort: element type has no cmp");
    }
    auk_arr_make_unique(pa);
    AukArr *a = *pa;
    int64_t n = a->len;
    if (n < 2) {
        return;
    }
    if (ops == &auk_ops_int) {
        sort_ints((int64_t *)a->data, n);
        return;
    }
    if (ops == &auk_ops_float) {
        double *tmp = auk__xmalloc((size_t)(n / 2 + 1) * sizeof(double));
        merge_floats((double *)a->data, tmp, n);
        free(tmp);
        return;
    }
    size_t size = ops->size;
    int64_t *perm = auk__xmalloc((size_t)n * sizeof(int64_t));
    int64_t *ptmp = auk__xmalloc((size_t)(n / 2 + 1) * sizeof(int64_t));
    for (int64_t i = 0; i < n; i++) {
        perm[i] = i;
    }
    merge_perm(perm, ptmp, n, a->data, size, ops->cmp);
    uint8_t *sorted = auk__xmalloc((size_t)n * size);
    for (int64_t k = 0; k < n; k++) {
        memcpy(sorted + (size_t)k * size, a->data + (size_t)perm[k] * size, size);
    }
    memcpy(a->data, sorted, (size_t)n * size);
    free(sorted);
    free(ptmp);
    free(perm);
}

AUK_API AukArr *auk_arr_sorted(const AukArr *a) {
    AukArr *c = auk_arr_copy(a);
    auk_arr_sort(&c);
    return c;
}

/* ---- queries ----------------------------------------------------------------------------- */

AUK_API AukOpt_int auk_arr_index_of(const AukArr *a, const void *e) {
    AukOpt_int r = {0};
    for (int64_t i = 0; i < auk_arr_len(a); i++) {
        if (a->ops->eq == NULL) {
            auk__panic_rt("contains: element type has no eq");
        }
        if (a->ops->eq(elem(a, i), e)) {
            r.some = true;
            r.val = i;
            return r;
        }
    }
    return r;
}

AUK_API bool auk_arr_contains(const AukArr *a, const void *e) {
    return auk_arr_index_of(a, e).some;
}

AUK_API bool auk_arr_eq(const AukArr *a, const AukArr *b) {
    if (a == b) {
        return true;
    }
    int64_t n = auk_arr_len(a);
    if (n != auk_arr_len(b)) {
        return false;
    }
    for (int64_t i = 0; i < n; i++) {
        if (a->ops->eq == NULL) {
            auk__panic_rt("element type has no eq");
        }
        if (!a->ops->eq(elem(a, i), elem(b, i))) {
            return false;
        }
    }
    return true;
}

AUK_API int auk_arr_cmp(const AukArr *a, const AukArr *b) {
    int64_t na = auk_arr_len(a);
    int64_t nb = auk_arr_len(b);
    for (int64_t i = 0; i < na && i < nb; i++) {
        if (a->ops->cmp == NULL) {
            auk__panic_rt("element type has no cmp");
        }
        int c = a->ops->cmp(elem(a, i), elem(b, i));
        if (c != 0) {
            return c < 0 ? -1 : 1;
        }
    }
    return (na > nb) - (na < nb);
}

AUK_API uint64_t auk_arr_hash(const AukArr *a) {
    uint64_t h = 0x1234;
    for (int64_t i = 0; i < auk_arr_len(a); i++) {
        if (a->ops->hash == NULL) {
            auk__panic_rt("element type has no hash");
        }
        h = auk_hash_combine(h, a->ops->hash(elem(a, i)));
    }
    return h;
}

AUK_API AukStr *auk_arr_show(const AukArr *a) {
    AukStrBuf b = {0};
    auk_sb_char(&b, '[');
    for (int64_t i = 0; i < auk_arr_len(a) && !auk__show_exhausted(); i++) {
        if (i != 0) {
            auk_sb_lit(&b, ", ");
        }
        if (a->ops->show == NULL) {
            auk__panic_rt("show: element type has no show");
        }
        auk_sb_str_own(&b, a->ops->show(elem(a, i)));
    }
    auk_sb_char(&b, ']');
    return auk_sb_finish(&b);
}

AUK_API AukStr *auk_arr_join(const AukArr *a, const AukStr *sep) {
    AukStrBuf b = {0};
    for (int64_t i = 0; i < auk_arr_len(a); i++) {
        if (i != 0) {
            auk_sb_str(&b, sep);
        }
        const AukElemOps *ops = a->ops;
        if (ops == &auk_ops_str) {
            auk_sb_str(&b, *(AukStr *const *)elem(a, i));
        } else if (ops == &auk_ops_char) {
            auk_sb_char(&b, *(const uint32_t *)elem(a, i));
        } else {
            if (ops->show == NULL) {
                auk__panic_rt("element type has no show");
            }
            auk_sb_str_own(&b, ops->show(elem(a, i)));
        }
    }
    return auk_sb_finish(&b);
}

AUK_API int64_t auk_arr_sum_int(const AukArr *a, const char *loc) {
    int64_t s = 0;
    const int64_t *d = auk_arr_data(a);
    for (int64_t i = 0; i < auk_arr_len(a); i++) {
        s = auk_add(s, d[i], loc);
    }
    return s;
}

AUK_API double auk_arr_sum_float(const AukArr *a) {
    double s = 0.0;
    const double *d = auk_arr_data(a);
    for (int64_t i = 0; i < auk_arr_len(a); i++) {
        s += d[i];
    }
    return s;
}
