/* [T]: inline-element arrays with copy-on-write and O(1) slice views. */
#include "duck_internal.h"

#define ELEM(a, i) ((a)->data + (size_t)(i) * (a)->ops->size)

static void retain_elem(const DuckElemOps *ops, void *e) {
    if (ops->retain) ops->retain(e);
}
static void release_elem(const DuckElemOps *ops, void *e) {
    if (ops->release) ops->release(e);
}

DuckArr *duck_arr_new(const DuckElemOps *ops, int64_t cap) {
    if (!ops) duck_panic("runtime", "duck_arr_new: missing element ops");
    DuckArr *a = duck__alloc(sizeof(DuckArr), DUCK_K_ARR);
    a->ops = ops;
    a->cap = cap > 0 ? cap : 0;
    a->data = a->cap ? duck__xmalloc((size_t)a->cap * ops->size) : NULL;
    return a;
}

DuckArr *duck_arr_from(const DuckElemOps *ops, const void *elems, int64_t n) {
    DuckArr *a = duck_arr_new(ops, n);
    if (n) memcpy(a->data, elems, (size_t)n * ops->size);
    a->len = n;
    if (ops->retain)
        for (int64_t i = 0; i < n; i++) ops->retain(ELEM(a, i));
    return a;
}

void duck__arr_free(DuckArr *a) {
    if (a->base) {
        duck_release(a->base);
    } else {
        if (a->ops->release)
            for (int64_t i = 0; i < a->len; i++) a->ops->release(ELEM(a, i));
        free(a->data);
    }
    duck__free_obj(a);
}

static _Noreturn void oob(const char *loc, int64_t i, int64_t len) {
    duck_panic(loc, "index %lld out of range for length %lld", (long long)i, (long long)len);
}

void *duck_arr_at(const DuckArr *a, int64_t i, const char *loc) {
    int64_t n = duck_arr_len(a);
    if (i < 0 || i >= n) oob(loc, i, n);
    return ELEM(a, i);
}

bool duck_arr_get_opt(const DuckArr *a, int64_t i, void *out) {
    if (i < 0 || i >= duck_arr_len(a)) return false;
    memcpy(out, ELEM(a, i), a->ops->size);
    retain_elem(a->ops, out);
    return true;
}

/* A fresh owner copy of a with capacity >= cap. */
static DuckArr *copy_with_cap(const DuckArr *a, int64_t cap) {
    if (cap < a->len) cap = a->len;
    DuckArr *c = duck_arr_new(a->ops, cap);
    if (a->len) memcpy(c->data, a->data, (size_t)a->len * a->ops->size);
    c->len = a->len;
    if (a->ops->retain)
        for (int64_t i = 0; i < c->len; i++) a->ops->retain(ELEM(c, i));
    return c;
}

static bool is_unique(const DuckArr *a) { return !a->base && duck_refcount(a) == 1; }

static void ensure_unique_cap(DuckArr **pa, int64_t need) {
    DuckArr *a = *pa;
    if (!a) duck_panic("runtime", "mutating a NULL array");
    if (!is_unique(a)) {
        int64_t cap = need > a->len ? need : a->len;
        DuckArr *c = copy_with_cap(a, cap);
        duck_release(a);
        *pa = c;
        return;
    }
    if (need > a->cap) {
        int64_t cap = a->cap ? a->cap * 2 : 4;
        while (cap < need) cap *= 2;
        a->data = duck__xrealloc(a->data, (size_t)cap * a->ops->size);
        a->cap = cap;
    }
}

void *duck_arr_make_unique(DuckArr **pa) {
    ensure_unique_cap(pa, (*pa)->len);
    return (*pa)->data;
}

void duck_arr_set(DuckArr **pa, int64_t i, const void *elem, const char *loc) {
    int64_t n = duck_arr_len(*pa);
    if (i < 0 || i >= n) oob(loc, i, n);
    char tmp[256];
    size_t sz = (*pa)->ops->size;
    /* copy + retain the new value first: elem may point into *pa */
    void *t = sz <= sizeof tmp ? tmp : duck__xmalloc(sz);
    memcpy(t, elem, sz);
    retain_elem((*pa)->ops, t);
    ensure_unique_cap(pa, n);
    DuckArr *a = *pa;
    release_elem(a->ops, ELEM(a, i));
    memcpy(ELEM(a, i), t, sz);
    if (t != tmp) free(t);
}

void duck_arr_push(DuckArr **pa, const void *elem) {
    DuckArr *a = *pa;
    size_t sz = a->ops->size;
    /* elem may point into *pa itself; copy before a possible realloc/COW */
    char tmp[256];
    void *t = sz <= sizeof tmp ? tmp : duck__xmalloc(sz);
    memcpy(t, elem, sz);
    retain_elem(a->ops, t);
    ensure_unique_cap(pa, a->len + 1);
    a = *pa;
    memcpy(ELEM(a, a->len), t, sz);
    a->len++;
    if (t != tmp) free(t);
}

bool duck_arr_pop(DuckArr **pa, void *out) {
    if (duck_arr_len(*pa) == 0) return false;
    ensure_unique_cap(pa, (*pa)->len);
    DuckArr *a = *pa;
    a->len--;
    if (out) memcpy(out, ELEM(a, a->len), a->ops->size);
    else release_elem(a->ops, ELEM(a, a->len));
    return true;
}

void duck_arr_insert(DuckArr **pa, int64_t i, const void *elem, const char *loc) {
    int64_t n = duck_arr_len(*pa);
    if (i < 0 || i > n) oob(loc, i, n);
    size_t sz = (*pa)->ops->size;
    char tmp[256];
    void *t = sz <= sizeof tmp ? tmp : duck__xmalloc(sz);
    memcpy(t, elem, sz);
    retain_elem((*pa)->ops, t);
    ensure_unique_cap(pa, n + 1);
    DuckArr *a = *pa;
    memmove(ELEM(a, i + 1), ELEM(a, i), (size_t)(n - i) * sz);
    memcpy(ELEM(a, i), t, sz);
    a->len++;
    if (t != tmp) free(t);
}

void duck_arr_remove(DuckArr **pa, int64_t i, void *out, const char *loc) {
    int64_t n = duck_arr_len(*pa);
    if (i < 0 || i >= n) oob(loc, i, n);
    ensure_unique_cap(pa, n);
    DuckArr *a = *pa;
    size_t sz = a->ops->size;
    if (out) memcpy(out, ELEM(a, i), sz);
    else release_elem(a->ops, ELEM(a, i));
    memmove(ELEM(a, i), ELEM(a, i + 1), (size_t)(n - i - 1) * sz);
    a->len--;
}

void duck_arr_clear(DuckArr **pa) {
    DuckArr *a = *pa;
    if (!is_unique(a)) {
        *pa = duck_arr_new(a->ops, 0);
        duck_release(a);
        return;
    }
    if (a->ops->release)
        for (int64_t i = 0; i < a->len; i++) a->ops->release(ELEM(a, i));
    a->len = 0;
}

DuckArr *duck_arr_slice(DuckArr *a, int64_t lo, int64_t hi, const char *loc) {
    int64_t n = duck_arr_len(a);
    if (lo < 0 || hi < lo || hi > n)
        duck_panic(loc, "slice %lld..%lld out of range for length %lld", (long long)lo, (long long)hi, (long long)n);
    if (lo == 0 && hi == n) return duck_retain(a);
    DuckArr *root = a->base ? a->base : a;
    DuckArr *v = duck__alloc(sizeof(DuckArr), DUCK_K_ARR);
    v->ops = a->ops;
    v->base = duck_retain(root);
    v->data = ELEM(a, lo);
    v->len = hi - lo;
    v->cap = v->len;
    return v;
}

DuckArr *duck_arr_take(DuckArr *a, int64_t n) {
    int64_t len = duck_arr_len(a);
    if (n < 0) n = 0;
    return duck_arr_slice(a, 0, n < len ? n : len, NULL);
}

DuckArr *duck_arr_skip(DuckArr *a, int64_t n) {
    int64_t len = duck_arr_len(a);
    if (n < 0) n = 0;
    return duck_arr_slice(a, n < len ? n : len, len, NULL);
}

DuckArr *duck_arr_copy(const DuckArr *a) { return copy_with_cap(a, a->len); }

DuckArr *duck_arr_concat(const DuckArr *a, const DuckArr *b) {
    DuckArr *c = copy_with_cap(a, a->len + duck_arr_len(b));
    duck_arr_extend(&c, b);
    return c;
}

void duck_arr_extend(DuckArr **pa, const DuckArr *b) {
    int64_t bn = duck_arr_len(b);
    if (!bn) return;
    DuckArr *keep = duck_retain((void *)b); /* b may be *pa */
    ensure_unique_cap(pa, (*pa)->len + bn);
    DuckArr *a = *pa;
    memcpy(ELEM(a, a->len), b->data, (size_t)bn * a->ops->size);
    if (a->ops->retain)
        for (int64_t i = a->len; i < a->len + bn; i++) a->ops->retain(ELEM(a, i));
    a->len += bn;
    duck_release(keep);
}

static void reverse_in_place(DuckArr *a) {
    size_t sz = a->ops->size;
    char tmp[256];
    void *t = sz <= sizeof tmp ? tmp : duck__xmalloc(sz);
    for (int64_t i = 0, j = a->len - 1; i < j; i++, j--) {
        memcpy(t, ELEM(a, i), sz);
        memcpy(ELEM(a, i), ELEM(a, j), sz);
        memcpy(ELEM(a, j), t, sz);
    }
    if (t != tmp) free(t);
}

DuckArr *duck_arr_reversed(const DuckArr *a) {
    DuckArr *c = duck_arr_copy(a);
    reverse_in_place(c);
    return c;
}

void duck_arr_reverse(DuckArr **pa) {
    duck_arr_make_unique(pa);
    reverse_in_place(*pa);
}

/* ---- stable merge sort ------------------------------------------------ */

typedef struct {
    int (*cmp)(const void *, const void *, void *);
    void *ctx;
    size_t sz;
} SortCtx;

static void merge_sort(char *d, char *tmp, int64_t n, const SortCtx *c) {
    if (n < 2) return;
    if (n <= 8) { /* insertion sort */
        for (int64_t i = 1; i < n; i++) {
            memcpy(tmp, d + i * c->sz, c->sz);
            int64_t j = i;
            while (j > 0 && c->cmp(d + (j - 1) * c->sz, tmp, c->ctx) > 0) {
                memcpy(d + j * c->sz, d + (j - 1) * c->sz, c->sz);
                j--;
            }
            memcpy(d + j * c->sz, tmp, c->sz);
        }
        return;
    }
    int64_t m = n / 2;
    merge_sort(d, tmp, m, c);
    merge_sort(d + m * c->sz, tmp, n - m, c);
    if (c->cmp(d + (m - 1) * c->sz, d + m * c->sz, c->ctx) <= 0) return;
    memcpy(tmp, d, (size_t)n * c->sz);
    int64_t i = 0, j = m, k = 0;
    while (i < m && j < n) {
        if (c->cmp(tmp + j * c->sz, tmp + i * c->sz, c->ctx) < 0) memcpy(d + (k++) * c->sz, tmp + (j++) * c->sz, c->sz);
        else memcpy(d + (k++) * c->sz, tmp + (i++) * c->sz, c->sz);
    }
    if (i < m) memcpy(d + k * c->sz, tmp + i * c->sz, (size_t)(m - i) * c->sz);
    if (j < n) memcpy(d + k * c->sz, tmp + j * c->sz, (size_t)(n - j) * c->sz);
}

void duck_arr_sort_with(DuckArr **pa, int (*cmp)(const void *, const void *, void *), void *ctx) {
    duck_arr_make_unique(pa);
    DuckArr *a = *pa;
    if (a->len < 2) return;
    SortCtx c = {cmp, ctx, a->ops->size};
    char *tmp = duck__xmalloc((size_t)a->len * c.sz);
    merge_sort(a->data, tmp, a->len, &c);
    free(tmp);
}

static int ops_cmp(const void *x, const void *y, void *ctx) { return ((const DuckElemOps *)ctx)->cmp(x, y); }

void duck_arr_sort(DuckArr **pa) {
    const DuckElemOps *ops = (*pa)->ops;
    if (!ops->cmp) duck_panic("runtime", "sort: element type has no cmp");
    duck_arr_sort_with(pa, ops_cmp, (void *)ops);
}

DuckArr *duck_arr_sorted(const DuckArr *a) {
    DuckArr *c = duck_arr_copy(a);
    duck_arr_sort(&c);
    return c;
}

/* ---- queries --------------------------------------------------------- */

DuckOpt_int duck_arr_index_of(const DuckArr *a, const void *elem) {
    for (int64_t i = 0; i < duck_arr_len(a); i++) {
        if (!a->ops->eq) duck_panic("runtime", "contains: element type has no eq");
        if (a->ops->eq(ELEM(a, i), elem)) return DUCK_SOME(DuckOpt_int, i);
    }
    return DUCK_NONE(DuckOpt_int);
}

bool duck_arr_contains(const DuckArr *a, const void *elem) { return duck_arr_index_of(a, elem).some; }

bool duck_arr_eq(const DuckArr *a, const DuckArr *b) {
    if (a == b) return true;
    int64_t n = duck_arr_len(a);
    if (n != duck_arr_len(b)) return false;
    for (int64_t i = 0; i < n; i++)
        if (!a->ops->eq(ELEM(a, i), ELEM(b, i))) return false;
    return true;
}

int duck_arr_cmp(const DuckArr *a, const DuckArr *b) {
    int64_t na = duck_arr_len(a), nb = duck_arr_len(b);
    for (int64_t i = 0; i < na && i < nb; i++) {
        int c = a->ops->cmp(ELEM(a, i), ELEM(b, i));
        if (c) return c < 0 ? -1 : 1;
    }
    return (na > nb) - (na < nb);
}

uint64_t duck_arr_hash(const DuckArr *a) {
    uint64_t h = 0x1234;
    for (int64_t i = 0; i < duck_arr_len(a); i++) h = duck_hash_combine(h, a->ops->hash(ELEM(a, i)));
    return h;
}

DuckStr *duck_arr_show(const DuckArr *a) {
    DuckStrBuf b = DUCK_SB_INIT;
    duck_sb_char(&b, '[');
    for (int64_t i = 0; i < duck_arr_len(a) && !duck__show_exhausted(); i++) {
        if (i) duck_sb_lit(&b, ", ");
        if (!a->ops->show) duck_panic("runtime", "show: element type has no show");
        duck_sb_str_own(&b, a->ops->show(ELEM(a, i)));
    }
    duck_sb_char(&b, ']');
    return duck_sb_finish(&b);
}

DuckStr *duck_arr_join(const DuckArr *a, const DuckStr *sep) {
    DuckStrBuf b = DUCK_SB_INIT;
    for (int64_t i = 0; i < duck_arr_len(a); i++) {
        if (i) duck_sb_str(&b, sep);
        if (a->ops == &duck_ops_str) duck_sb_str(&b, *(DuckStr **)ELEM(a, i));
        else if (a->ops == &duck_ops_char) duck_sb_char(&b, *(uint32_t *)ELEM(a, i));
        else duck_sb_str_own(&b, a->ops->show(ELEM(a, i)));
    }
    return duck_sb_finish(&b);
}

int64_t duck_arr_sum_int(const DuckArr *a, const char *loc) {
    int64_t s = 0;
    const int64_t *d = duck_arr_data(a);
    for (int64_t i = 0; i < duck_arr_len(a); i++) s = duck_add(s, d[i], loc);
    return s;
}

double duck_arr_sum_float(const DuckArr *a) {
    double s = 0;
    const double *d = duck_arr_data(a);
    for (int64_t i = 0; i < duck_arr_len(a); i++) s += d[i];
    return s;
}
