/* {K: V}: insertion-ordered hash map (index table + entries), copy-on-write. */
#include "duck_internal.h"

#define KEY(m, i) ((m)->keys + (size_t)(i) * (m)->kops->size)
#define VAL(m, i) ((m)->vals + (size_t)(i) * (m)->vops->size)
#define EMPTY (-1)
#define TOMB (-2)

DuckMap *duck_map_new(const DuckElemOps *kops, const DuckElemOps *vops) {
    if (!kops || !vops) duck_panic("runtime", "duck_map_new: missing ops");
    if (!kops->hash || !kops->eq) duck_panic("runtime", "duck_map_new: key type needs hash and eq");
    DuckMap *m = duck__alloc(sizeof(DuckMap), DUCK_K_MAP);
    m->kops = kops;
    m->vops = vops;
    return m;
}

void duck__map_free(DuckMap *m) {
    for (int64_t i = 0; i < m->n; i++) {
        if (m->dead[i]) continue;
        if (m->kops->release) m->kops->release(KEY(m, i));
        if (m->vops->release) m->vops->release(VAL(m, i));
    }
    free(m->keys);
    free(m->vals);
    free(m->hashes);
    free(m->dead);
    free(m->index);
    duck__free_obj(m);
}

static void rebuild_index(DuckMap *m, int64_t icap) {
    free(m->index);
    m->icap = icap;
    m->index = duck__xmalloc((size_t)icap * sizeof(int64_t));
    for (int64_t i = 0; i < icap; i++) m->index[i] = EMPTY;
    uint64_t mask = (uint64_t)icap - 1;
    for (int64_t e = 0; e < m->n; e++) {
        if (m->dead[e]) continue;
        uint64_t s = m->hashes[e] & mask;
        while (m->index[s] != EMPTY) s = (s + 1) & mask;
        m->index[s] = e;
    }
}

/* Drop dead entries (keeps order). The caller rebuilds the index. */
static void compact(DuckMap *m) {
    int64_t k = 0;
    size_t ks = m->kops->size, vs = m->vops->size;
    for (int64_t e = 0; e < m->n; e++) {
        if (m->dead[e]) continue;
        if (k != e) {
            memcpy(KEY(m, k), KEY(m, e), ks);
            memcpy(VAL(m, k), VAL(m, e), vs);
            m->hashes[k] = m->hashes[e];
            m->dead[k] = false;
        }
        k++;
    }
    m->n = k;
}

static void set_cap(DuckMap *m, int64_t cap) {
    m->keys = duck__xrealloc(m->keys, (size_t)cap * m->kops->size);
    m->vals = duck__xrealloc(m->vals, (size_t)cap * m->vops->size);
    m->hashes = duck__xrealloc(m->hashes, (size_t)cap * sizeof(uint64_t));
    m->dead = duck__xrealloc(m->dead, (size_t)cap * sizeof(bool));
    m->cap = cap;
}

static int64_t icap_for(int64_t cap) {
    int64_t ic = 8;
    while (ic < cap * 2) ic *= 2;
    return ic;
}

/* Returns the index slot holding key, or -1. */
static int64_t find_slot(const DuckMap *m, const void *key, uint64_t h) {
    if (!m || !m->icap) return -1;
    uint64_t mask = (uint64_t)m->icap - 1;
    for (uint64_t s = h & mask;; s = (s + 1) & mask) {
        int64_t e = m->index[s];
        if (e == EMPTY) return -1;
        if (e >= 0 && m->hashes[e] == h && m->kops->eq(KEY(m, e), key)) return (int64_t)s;
    }
}

void *duck_map_find(const DuckMap *m, const void *key) {
    if (!m) return NULL;
    int64_t s = find_slot(m, key, m->kops->hash(key));
    return s < 0 ? NULL : VAL(m, m->index[s]);
}

void *duck_map_at(const DuckMap *m, const void *key, const char *loc) {
    void *v = duck_map_find(m, key);
    if (!v) {
        DuckStr *k = m && m->kops->show ? m->kops->show(key) : duck_str_lit("?");
        duck_panic(loc, "key not found: %s", duck_str_cstr(k));
    }
    return v;
}

bool duck_map_get_opt(const DuckMap *m, const void *key, void *out) {
    void *v = duck_map_find(m, key);
    if (!v) return false;
    memcpy(out, v, m->vops->size);
    if (m->vops->retain) m->vops->retain(out);
    return true;
}

bool duck_map_contains(const DuckMap *m, const void *key) { return duck_map_find(m, key) != NULL; }

DuckMap *duck_map_copy(const DuckMap *m) {
    DuckMap *c = duck_map_new(m->kops, m->vops);
    if (m->len) {
        set_cap(c, m->len);
        for (int64_t e = 0; e < m->n; e++) {
            if (m->dead[e]) continue;
            int64_t k = c->n++;
            memcpy(KEY(c, k), KEY(m, e), m->kops->size);
            memcpy(VAL(c, k), VAL(m, e), m->vops->size);
            if (m->kops->retain) m->kops->retain(KEY(c, k));
            if (m->vops->retain) m->vops->retain(VAL(c, k));
            c->hashes[k] = m->hashes[e];
            c->dead[k] = false;
        }
        c->len = c->n;
        rebuild_index(c, icap_for(c->cap));
    }
    return c;
}

void *duck_map_make_unique(DuckMap **pm) {
    DuckMap *m = *pm;
    if (duck_refcount(m) != 1) {
        *pm = duck_map_copy(m);
        duck_release(m);
    }
    return *pm;
}

void duck_map_set(DuckMap **pm, const void *key, const void *val) {
    DuckMap *m0 = *pm;
    /* Hold copies of key/val (retained) before COW: they may live in *pm. */
    char kt[256], vt[256];
    size_t ks = m0->kops->size, vs = m0->vops->size;
    void *k = ks <= sizeof kt ? kt : duck__xmalloc(ks);
    void *v = vs <= sizeof vt ? vt : duck__xmalloc(vs);
    memcpy(k, key, ks);
    memcpy(v, val, vs);
    if (m0->vops->retain) m0->vops->retain(v);
    duck_map_make_unique(pm);
    DuckMap *m = *pm;
    uint64_t h = m->kops->hash(k);
    int64_t s = find_slot(m, k, h);
    if (s >= 0) {
        int64_t e = m->index[s];
        if (m->vops->release) m->vops->release(VAL(m, e));
        memcpy(VAL(m, e), v, vs);
    } else {
        if (m->kops->retain) m->kops->retain(k);
        if (m->n == m->cap) {
            if (m->n - m->len > m->len / 2 && m->n - m->len > 0) compact(m);
            if (m->n == m->cap) set_cap(m, m->cap ? m->cap * 2 : 4);
            rebuild_index(m, icap_for(m->cap));
        } else if (!m->icap) {
            rebuild_index(m, icap_for(m->cap));
        }
        int64_t e = m->n++;
        memcpy(KEY(m, e), k, ks);
        memcpy(VAL(m, e), v, vs);
        m->hashes[e] = h;
        m->dead[e] = false;
        m->len++;
        uint64_t mask = (uint64_t)m->icap - 1;
        uint64_t slot = h & mask;
        while (m->index[slot] >= 0) slot = (slot + 1) & mask;
        m->index[slot] = e;
    }
    if (k != kt) free(k);
    if (v != vt) free(v);
}

bool duck_map_remove(DuckMap **pm, const void *key, void *out) {
    if (!duck_map_contains(*pm, key)) return false;
    char kt[256];
    size_t ks = (*pm)->kops->size;
    void *k = ks <= sizeof kt ? kt : duck__xmalloc(ks);
    memcpy(k, key, ks);
    if ((*pm)->kops->retain) (*pm)->kops->retain(k);
    duck_map_make_unique(pm);
    DuckMap *m = *pm;
    int64_t s = find_slot(m, k, m->kops->hash(k));
    int64_t e = m->index[s];
    m->index[s] = TOMB;
    m->dead[e] = true;
    m->len--;
    if (m->kops->release) m->kops->release(KEY(m, e));
    if (out) memcpy(out, VAL(m, e), m->vops->size);
    else if (m->vops->release) m->vops->release(VAL(m, e));
    if (m->n - m->len > 16 && m->n - m->len > m->len) {
        compact(m);
        rebuild_index(m, icap_for(m->cap));
    }
    if (m->kops->release) m->kops->release(k);
    if (k != kt) free(k);
    return true;
}

bool duck_map_next(const DuckMap *m, int64_t *it, void **key, void **val) {
    if (!m) return false;
    while (*it < m->n) {
        int64_t e = (*it)++;
        if (m->dead[e]) continue;
        if (key) *key = KEY(m, e);
        if (val) *val = VAL(m, e);
        return true;
    }
    return false;
}

DuckArr *duck_map_keys(const DuckMap *m) {
    DuckArr *a = duck_arr_new(m->kops, m->len);
    int64_t it = 0;
    void *k;
    while (duck_map_next(m, &it, &k, NULL)) duck_arr_push(&a, k);
    return a;
}

DuckArr *duck_map_values(const DuckMap *m) {
    DuckArr *a = duck_arr_new(m->vops, m->len);
    int64_t it = 0;
    void *v;
    while (duck_map_next(m, &it, NULL, &v)) duck_arr_push(&a, v);
    return a;
}

bool duck_map_eq(const DuckMap *a, const DuckMap *b) {
    if (a == b) return true;
    if (duck_map_len(a) != duck_map_len(b)) return false;
    if (!a || !b) return true; /* both empty */
    int64_t it = 0;
    void *k, *v;
    while (duck_map_next(a, &it, &k, &v)) {
        void *w = duck_map_find(b, k);
        if (!w || !a->vops->eq || !a->vops->eq(v, w)) return false;
    }
    return true;
}

DuckStr *duck_map_show(const DuckMap *m) {
    DuckStrBuf b = DUCK_SB_INIT;
    duck_sb_char(&b, '{');
    int64_t it = 0;
    void *k, *v;
    bool first = true;
    while (!duck__show_exhausted() && duck_map_next(m, &it, &k, &v)) {
        if (!first) duck_sb_lit(&b, ", ");
        first = false;
        duck_sb_str_own(&b, m->kops->show(k));
        duck_sb_lit(&b, ": ");
        duck_sb_str_own(&b, m->vops->show(v));
    }
    duck_sb_char(&b, '}');
    return duck_sb_finish(&b);
}
